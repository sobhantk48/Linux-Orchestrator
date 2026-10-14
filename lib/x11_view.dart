import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class X11View extends StatefulWidget {
  final VoidCallback? onBackToTerminal;

  const X11View({super.key, this.onBackToTerminal});

  @override
  State<X11View> createState() => _X11ViewState();
}

class _X11ViewState extends State<X11View> {
  static const _method = MethodChannel('com.sobhan.term/x11_display');
  static const _frames = EventChannel('com.sobhan.term/x11_frames');

  StreamSubscription<dynamic>? _sub;
  ui.Image? _frame;
  int _w = 0;
  int _h = 0;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    _connectTouch();
    _listenFrames();
  }

  Future<void> _connectTouch() async {
    try {
      await _method.invokeMethod<bool>('connectTouch');
    } catch (e) {
      debugPrint('[X11View] touch socket: $e');
    }
  }

  void _listenFrames() {
    _sub = _frames.receiveBroadcastStream().listen(
      (data) {
        if (_decoding) return;
        final map   = Map<String, dynamic>.from(data as Map);
        final w     = map['width']  as int;
        final h     = map['height'] as int;
        final bytes = map['bytes']  as Uint8List;
        _decoding = true;
        ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, (img) {
          if (!mounted) { img.dispose(); return; }
          setState(() {
            _frame?.dispose();
            _frame = img;
            _w = w;
            _h = h;
          });
          _decoding = false;
        });
      },
      onError: (e) => debugPrint('[X11View] frame stream: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _method.invokeMethod<bool>('disconnectTouch');
    _frame?.dispose();
    super.dispose();
  }

  void _sendTouch(int type, Offset pos) {
    _method.invokeMethod<bool>('sendTouchEvent', {
      'type': type,
      'x': pos.dx.toInt(),
      'y': pos.dy.toInt(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown:   (d) => _sendTouch(0, d.localPosition),
      onTapUp:     (d) => _sendTouch(1, d.localPosition),
      onPanUpdate: (d) => _sendTouch(2, d.localPosition),
      child: _frame == null
          ? const ColoredBox(
              color: Colors.black,
              child: Center(
                child: CircularProgressIndicator(color: Colors.white54),
              ),
            )
          : LayoutBuilder(builder: (ctx, constraints) {
              return CustomPaint(
                size: constraints.biggest,
                painter: _FramePainter(_frame!, _w, _h),
              );
            }),
    );
  }
}

class _FramePainter extends CustomPainter {
  final ui.Image image;
  final int srcW;
  final int srcH;

  _FramePainter(this.image, this.srcW, this.srcH);

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.image != image;
}
