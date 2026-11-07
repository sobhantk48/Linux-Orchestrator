import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop.dart';

/// حلقه‌ی بافر برای فریم‌های JPEG با پیشوند طول ۴ بایتی (frame_server).
class _ByteRing {
  Uint8List _buf = Uint8List(1 << 20);
  int _start = 0, _end = 0;

  int get length => _end - _start;

  void add(Uint8List data) {
    final int need = length + data.length;
    if (_end + data.length > _buf.length) {
      if (need > _buf.length) {
        final Uint8List nb = Uint8List(need * 2);
        nb.setRange(0, length, _buf, _start);
        _buf = nb;
      } else {
        _buf.setRange(0, length, _buf, _start);
      }
      _end = length;
      _start = 0;
    }
    _buf.setRange(_end, _end + data.length, data);
    _end += data.length;
  }

  int u8(int i) => _buf[_start + i];

  Uint8List take(int n) {
    final Uint8List copy = Uint8List.fromList(
      Uint8List.sublistView(_buf, _start, _start + n),
    );
    _start += n;
    if (_start == _end) _start = _end = 0;
    return copy;
  }
}

/// کلاینت دسکتاپ گرافیکی: تصویر زنده از پورت ۶۰۰۰ و ارسال لمس/کیبورد به ۶۰۰۱.
class DesktopView extends StatefulWidget {
  const DesktopView({super.key, required this.title});

  /// برچسب توزیع برای نمایش در نوار وضعیت.
  final String title;

  @override
  State<DesktopView> createState() => _DesktopViewState();
}

class _DesktopViewState extends State<DesktopView> {
  /// رزولوشن منطقی؛ باید با `-w`/`-h` سرور لمس و `start_desktop` یکی باشد.
  static const int desktopWidth = 900;
  static const int desktopHeight = 2000;
  static const int framePort = 6000;
  static const int inputPort = 6001;

  Socket? _frameSocket;
  Socket? _touchSocket;
  bool _connected = false;
  bool _connecting = false;
  Timer? _watchdog;
  Timer? _shutdownPoll;
  int _lastFrameMs = 0;
  String _status = 'در حال اتصال به دسکتاپ...';
  bool _decoding = false;
  bool _keyboardVisible = false;
  ui.Image? _frame;
  Uint8List? _pending;

  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onKey);
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _connect();
    _shutdownPoll = Timer.periodic(const Duration(seconds: 2), (Timer t) async {
      if (!mounted) return;
      final bool req = await DesktopSession.isShutdownRequested();
      if (!req || !mounted) return;
      t.cancel();
      Navigator.of(context).maybePop();
      unawaited(DesktopSession.clearShutdownFlag());
    });
  }

  @override
  void dispose() {
    _shutdownPoll?.cancel();
    _watchdog?.cancel();
    _frameSocket?.destroy();
    _touchSocket?.destroy();
    _frame?.dispose();
    _focusNode.dispose();
    _textController.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    int attempts = 0;
    try {
      while (mounted && !_connected) {
        try {
          final Socket fs = await Socket.connect('127.0.0.1', framePort);
          fs.setOption(SocketOption.tcpNoDelay, true);
          _frameSocket = fs;
          if (_touchSocket == null) {
            final Socket ts = await Socket.connect('127.0.0.1', inputPort);
            ts.setOption(SocketOption.tcpNoDelay, true);
            _touchSocket = ts;
            ts.listen(
              (_) {},
              onError: (_) => _touchSocket = null,
              onDone: () => _touchSocket = null,
            );
          }
          _lastFrameMs = DateTime.now().millisecondsSinceEpoch;
          if (mounted) setState(() => _connected = true);
          _listenFrames(fs);
          _watchdogStart();
          return;
        } catch (_) {
          _frameSocket?.destroy();
          _frameSocket = null;
          attempts++;
          if (attempts >= 30) {
            final String tail = await DesktopSession.logTail(maxLines: 12);
            if (mounted) {
              setState(() {
                _status = tail.isEmpty
                    ? 'اتصال به سرور دسکتاپ برقرار نشد. دوباره تلاش کنید.'
                    : 'اتصال برقرار نشد:\n$tail';
              });
            }
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    } finally {
      _connecting = false;
    }
  }

  /// نگهبان فریم: سرور فقط با damage فعال می‌فرستد و XDamage فرزندان root را
  /// نمی‌بیند؛ پس در نبود فریم، سوکت را بی‌صدا تازه می‌کنیم (هر accept ⇒ فریم).
  void _watchdogStart() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(milliseconds: 800), (Timer t) {
      if (!mounted || !_connected) return;
      final int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastFrameMs > 1500) {
        _lastFrameMs = now;
        _frameSocket?.destroy();
        _frameSocket = null;
        _connected = false;
        _connect();
      }
    });
  }

  void _listenFrames(Socket s) {
    final _ByteRing ring = _ByteRing();
    int frameSize = 0;

    s.listen(
      (Uint8List data) {
        ring.add(data);
        while (true) {
          if (frameSize == 0) {
            if (ring.length < 4) break;
            frameSize = ring.u8(0) |
                (ring.u8(1) << 8) |
                (ring.u8(2) << 16) |
                (ring.u8(3) << 24);
            ring.take(4);
            if (frameSize < 100 || frameSize > (8 << 20)) {
              // SOB-FRAMEGUARD: طول قاب معتبر نیست (استریم خراب) ⇒
              // به‌جای خواندن داده‌های بی‌ربط به‌عنوان JPEG، اتصال را نو کن.
              frameSize = 0;
              _reconnect();
              return;
            }
          }
          if (ring.length < frameSize) break;
          final Uint8List jpg = ring.take(frameSize);
          frameSize = 0;
          _decodeLatest(jpg);
        }
      },
      onError: (_) {
        if (!identical(s, _frameSocket)) return;
        _reconnect();
      },
      onDone: () {
        if (!identical(s, _frameSocket)) return;
        _reconnect();
      },
    );
  }

  Future<void> _decodeLatest(Uint8List jpg) async {
    _pending = jpg;
    _lastFrameMs = DateTime.now().millisecondsSinceEpoch;
    if (_decoding) return;
    _decoding = true;
    while (_pending != null && mounted) {
      final Uint8List bytes = _pending!;
      _pending = null;
      try {
        final ui.ImmutableBuffer buf =
            await ui.ImmutableBuffer.fromUint8List(bytes);
        final ui.ImageDescriptor desc = await ui.ImageDescriptor.encoded(buf);
        final ui.Codec codec = await desc.instantiateCodec();
        final ui.FrameInfo info = await codec.getNextFrame();
        codec.dispose();
        desc.dispose();
        buf.dispose();
        if (!mounted) {
          info.image.dispose();
          break;
        }
        final ui.Image? old = _frame;
        setState(() => _frame = info.image);
        old?.dispose();
      } catch (_) {}
    }
    _decoding = false;
  }

  void _reconnect() {
    _frameSocket?.destroy();
    _touchSocket?.destroy();
    _frameSocket = null;
    _touchSocket = null;
    if (mounted) {
      setState(() => _connected = false);
      Future<void>.delayed(const Duration(seconds: 1), _connect);
    }
  }

  void _sendTouch(int type, Offset pos, Size size) {
    if (_touchSocket == null || size.width == 0 || size.height == 0) return;
    final int x = (pos.dx * desktopWidth / size.width)
        .clamp(0, desktopWidth - 1)
        .toInt();
    final int y = (pos.dy * desktopHeight / size.height)
        .clamp(0, desktopHeight - 1)
        .toInt();
    final Uint8List p = Uint8List(9);
    p[0] = type;
    p.buffer.asByteData().setInt32(1, x, Endian.little);
    p.buffer.asByteData().setInt32(5, y, Endian.little);
    try {
      _touchSocket?.add(p);
    } catch (_) {}
  }

  static final Map<LogicalKeyboardKey, int> _ks = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.enter: 0xFF0D,
    LogicalKeyboardKey.numpadEnter: 0xFF0D,
    LogicalKeyboardKey.backspace: 0xFF08,
    LogicalKeyboardKey.tab: 0xFF09,
    LogicalKeyboardKey.escape: 0xFF1B,
    LogicalKeyboardKey.delete: 0xFFFF,
    LogicalKeyboardKey.insert: 0xFF63,
    LogicalKeyboardKey.home: 0xFF50,
    LogicalKeyboardKey.end: 0xFF57,
    LogicalKeyboardKey.pageUp: 0xFF55,
    LogicalKeyboardKey.pageDown: 0xFF56,
    LogicalKeyboardKey.arrowLeft: 0xFF51,
    LogicalKeyboardKey.arrowUp: 0xFF52,
    LogicalKeyboardKey.arrowRight: 0xFF53,
    LogicalKeyboardKey.arrowDown: 0xFF54,
    LogicalKeyboardKey.shiftLeft: 0xFFE1,
    LogicalKeyboardKey.shiftRight: 0xFFE2,
    LogicalKeyboardKey.controlLeft: 0xFFE3,
    LogicalKeyboardKey.controlRight: 0xFFE4,
    LogicalKeyboardKey.capsLock: 0xFFE5,
    LogicalKeyboardKey.altLeft: 0xFFE9,
    LogicalKeyboardKey.altRight: 0xFFEA,
    LogicalKeyboardKey.metaLeft: 0xFFEB,
    LogicalKeyboardKey.metaRight: 0xFFEC,
    LogicalKeyboardKey.f1: 0xFFBE,
    LogicalKeyboardKey.f2: 0xFFBF,
    LogicalKeyboardKey.f3: 0xFFC0,
    LogicalKeyboardKey.f4: 0xFFC1,
    LogicalKeyboardKey.f5: 0xFFC2,
    LogicalKeyboardKey.f6: 0xFFC3,
    LogicalKeyboardKey.f7: 0xFFC4,
    LogicalKeyboardKey.f8: 0xFFC5,
    LogicalKeyboardKey.f9: 0xFFC6,
    LogicalKeyboardKey.f10: 0xFFC7,
    LogicalKeyboardKey.f11: 0xFFC8,
    LogicalKeyboardKey.f12: 0xFFC9,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    int? sym = _ks[e.logicalKey];
    if (sym == null) {
      final String l = e.logicalKey.keyLabel;
      if (l.length == 1) {
        final int c = l.toLowerCase().codeUnitAt(0);
        if (c >= 0x20 && c <= 0x7E) sym = c;
      }
    }
    if (sym == null) return KeyEventResult.ignored;
    if (e is KeyUpEvent) {
      _sendKeyType(12, sym);
    } else {
      _sendKeyType(11, sym);
    }
    return KeyEventResult.handled;
  }

  void _sendKeyType(int type, int sym) {
    if (_touchSocket == null) return;
    final Uint8List p = Uint8List(9);
    p[0] = type;
    p.buffer.asByteData().setInt32(1, sym, Endian.little);
    try {
      _touchSocket?.add(p);
    } catch (_) {}
  }

  int? _ptr;
  int _mode = 0; // 0 pending, 1 drag, 2 scroll, 3 right
  Offset _downPos = Offset.zero;
  Offset _lastPos = Offset.zero;
  Offset _lastTapPos = Offset.zero;
  DateTime _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
  bool _second = false;
  double _scrollAcc = 0;
  Timer? _lpTimer;

  void _sendRaw(int type, int a, int b) {
    if (_touchSocket == null) return;
    final Uint8List p = Uint8List(9);
    p[0] = type;
    p.buffer.asByteData().setInt32(1, a, Endian.little);
    p.buffer.asByteData().setInt32(5, b, Endian.little);
    try {
      _touchSocket?.add(p);
    } catch (_) {}
  }

  void _gDown(PointerDownEvent e, Size size) {
    if (_ptr != null) return;
    _ptr = e.pointer;
    _downPos = _lastPos = e.localPosition;
    _mode = 0;
    _scrollAcc = 0;
    _second = DateTime.now().difference(_lastTapUp).inMilliseconds < 400 &&
        (e.localPosition - _lastTapPos).distance < 40;
    _lpTimer?.cancel();
    _lpTimer = Timer(const Duration(milliseconds: 450), () {
      if (_mode != 0) return;
      if (_second) {
        _mode = 3;
        _sendTouch(4, _downPos, size);
      } else {
        _mode = 1;
        _sendTouch(1, _downPos, size);
      }
      HapticFeedback.mediumImpact();
    });
  }

  void _gMove(PointerMoveEvent e, Size size) {
    if (e.pointer != _ptr) return;
    final Offset p = e.localPosition;
    if (_mode == 1) {
      _sendTouch(2, p, size);
    } else if (_mode == 0 && (p - _downPos).distance > 12) {
      _lpTimer?.cancel();
      _mode = 2;
      _sendTouch(2, _downPos, size);
    }
    if (_mode == 2) {
      _scrollAcc += p.dy - _lastPos.dy;
      const double step = 24;
      while (_scrollAcc.abs() >= step) {
        final int dir = _scrollAcc > 0 ? 1 : -1;
        _sendRaw(5, dir, 0);
        _scrollAcc -= dir * step;
      }
    }
    _lastPos = p;
  }

  void _gUp(PointerEvent e, Size size) {
    if (e.pointer != _ptr) return;
    _lpTimer?.cancel();
    if (_mode == 0) {
      _sendTouch(1, _downPos, size);
      _sendTouch(3, _downPos, size);
      _lastTapUp = DateTime.now();
      _lastTapPos = _downPos;
    } else if (_mode == 1) {
      _sendTouch(3, e.localPosition, size);
      _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      _lastTapUp = DateTime.fromMillisecondsSinceEpoch(0);
    }
    _ptr = null;
    _mode = 0;
  }

  void _sendKey(int sym) {
    if (_touchSocket == null) return;
    final Uint8List p = Uint8List(9);
    p[0] = 10;
    p.buffer.asByteData().setInt32(1, sym, Endian.little);
    try {
      _touchSocket?.add(p);
    } catch (_) {}
  }

  void _toggleKeyboard() {
    _focusNode.requestFocus();
    if (_keyboardVisible) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      setState(() => _keyboardVisible = false);
    } else {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      setState(() => _keyboardVisible = true);
    }
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF00E676).withValues(alpha: 0.92)
              : const Color(0xFF1A1A2E).withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? const Color(0xFF00E676) : const Color(0xFF3A3A5C),
            width: 1.5,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: active ? Colors.black87 : const Color(0xFF8888AA),
          size: 24,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final Size size = Size(constraints.maxWidth, constraints.maxHeight);
          final double fitScale = (size.width / desktopWidth) <
                  (size.height / desktopHeight)
              ? (size.width / desktopWidth)
              : (size.height / desktopHeight);
          final Size fitSize =
              Size(desktopWidth * fitScale, desktopHeight * fitScale);
          return Stack(
            children: <Widget>[
              Positioned(
                left: (size.width - fitSize.width) / 2,
                top: (size.height - fitSize.height) / 2,
                width: fitSize.width,
                height: fitSize.height,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    _gDown(e, size);
                    _focusNode.requestFocus();
                    if (_keyboardVisible) {
                      SystemChannels.textInput.invokeMethod<void>(
                        'TextInput.show',
                      );
                    }
                  },
                  onPointerMove: (e) => _gMove(e, size),
                  onPointerUp: (e) => _gUp(e, size),
                  onPointerCancel: (e) => _gUp(e, size),
                  child: _frame == null
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF00E676),
                          ),
                        )
                      : RawImage(
                          image: _frame,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.low,
                        ),
                ),
              ),
              if (!_connected || _frame == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 78,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111111).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _roundButton(
                      icon: Icons.arrow_back,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                    _roundButton(
                      icon: _keyboardVisible
                          ? Icons.keyboard_hide_rounded
                          : Icons.keyboard_rounded,
                      active: _keyboardVisible,
                      onTap: _toggleKeyboard,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: -200,
                top: -200,
                width: 1,
                height: 1,
                child: TextField(
                  focusNode: _focusNode,
                  controller: _textController,
                  onChanged: (text) {
                    if (text.isNotEmpty) {
                      for (final int code in text.codeUnits) {
                        _sendKey(code);
                      }
                      _textController.clear();
                    }
                  },
                  onSubmitted: (_) {
                    _sendKey(0xFF0D);
                    _textController.clear();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
