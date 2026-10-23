import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'rtl_terminal.dart';
import 'term_buffer.dart';
import 'vt_parser.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(TerminalTaskHandler());
}

class TerminalTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// ---------------------------------------------------------------------------
// Session manager: PTY -> UTF-8 stream -> VT parser -> cell buffer -> renderer
// ---------------------------------------------------------------------------

class TerminalSessionManager {
  static final TerminalSessionManager _instance = TerminalSessionManager._internal();
  factory TerminalSessionManager() => _instance;
  TerminalSessionManager._internal();

  /// The single source of truth for screen content.
  final TermBuffer buffer = TermBuffer(cols: 120, rows: 35, maxScrollback: 2000);

  /// Bumped on every repaint so the widget rebuilds.
  final ValueNotifier<int> lineUpdateNotifier = ValueNotifier<int>(0);

  final ValueNotifier<String> terminalTitle = ValueNotifier<String>('');

  Pty? pty;
  StreamSubscription<String>? _outputSub;

  bool isSessionStarted = false;
  bool isInitializing = false;
  bool rootError = false;
  bool isServiceRunning = false;

  int _cols = 120;
  int _rows = 35;
  int _wantCols = 0;
  int _wantRows = 0;
  Timer? _resizeDebounce;

  // ---- chunk batching: one repaint per microtask, not per PTY read --------
  final List<String> _pending = <String>[];
  bool _flushQueued = false;

  late final VtParser _parser = VtParser(
    onPrint: (cp) => buffer.print(cp),
    onExecute: (cp) => buffer.execute(cp),
    onCsi: _onCsi,
    onEsc: (b, i) => buffer.esc(b, i),
    onOsc: _onOsc,
  );

  // ---------------------------------------------------------------- logging

  void log(String message) => appendOutput('$message\r\n');

  /// Everything — PTY output and internal log lines — goes through the parser.
  void appendOutput(String data) {
    if (data.isEmpty) return;
    _parser.write(data);
    _bump();
  }

  void _bump() {
    _linesCache = null;
    lineUpdateNotifier.value++;
  }

  // ------------------------------------------------------------ PTY plumbing

  void startPtySession({required VoidCallback onExit}) {
    if (isSessionStarted && pty != null) return;

    pty = Pty.start(
      'su',
      arguments: ['-c', 'exec /system/bin/sh /data/ubuntu-login.sh'],
      columns: _cols,
      rows: _rows,
      environment: {
        'TERM': 'xterm-256color',
        'PATH': '/sbin:/system/sbin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin',
      },
    );

    isSessionStarted = true;

    // UTF-8 decoding MUST happen on the stream, never per-chunk, otherwise
    // multi-byte Persian letters get shredded at chunk boundaries.
    _outputSub?.cancel();
    _outputSub = pty!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onText, onError: (Object e) {
      log('\x1b[31m[-]\x1b[0m PTY read error: $e');
    });

    pty!.exitCode.then((code) {
      isSessionStarted = false;
      _outputSub?.cancel();
      _outputSub = null;
      pty = null;
      onExit();
    });
  }

  void _onText(String s) {
    _pending.add(s);
    if (_flushQueued) return;
    _flushQueued = true;
    scheduleMicrotask(_flushPending);
  }

  void _flushPending() {
    _flushQueued = false;
    if (_pending.isEmpty) return;
    final sb = StringBuffer();
    for (final p in _pending) {
      sb.write(p);
    }
    _pending.clear();
    _parser.write(sb.toString());
    _bump();
  }

  void _writeRaw(String s) {
    final p = pty;
    if (p == null) return;
    p.write(Uint8List.fromList(utf8.encode(s)));
  }

  void sendInput(String text) {
    if (pty != null && text.isNotEmpty) _writeRaw(text);
  }

  void pasteText(String text) {
    if (text.isEmpty || pty == null) return;
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    _writeRaw('\x1b[200~$normalized\x1b[201~');
  }

  // ------------------------------------------------------- CSI interception

  void _onCsi(CsiSeq s) {
    // DSR 6n: cursor position report. Programs like `nano`, `vim`, `readline`
    // will hang or misdraw forever if this is never answered.
    if (s.finalByte == 0x6E && s.privateMarker == 0 && s.p(0) == 6) {
      _writeRaw('\x1b[${buffer.cursorRow + 1};${buffer.cursorCol + 1}R');
      return;
    }
    // DA: device attributes.
    if (s.finalByte == 0x63 && s.privateMarker == 0) {
      _writeRaw('\x1b[?1;2c');
      return;
    }
    buffer.csi(s);
  }

  void _onOsc(String data) {
    if (data.startsWith('0;') || data.startsWith('2;')) {
      terminalTitle.value = data.substring(2);
    }
  }

  // --------------------------------------------------------------- resizing

  /// Called by the UI with the grid size it can actually display.
  /// Debounced, change-driven, and never derived from rendered text.
  void requestGrid(int cols, int rows) {
    if (cols < 20 || rows < 5) return;
    if (cols == _wantCols && rows == _wantRows) return;
    _wantCols = cols;
    _wantRows = rows;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 200), () {
      if (cols == _cols && rows == _rows) return;
      _cols = cols;
      _rows = rows;
      buffer.resize(cols, rows);
      try {
        // flutter_pty signature: resize(rows, columns)
        pty?.resize(rows, cols);
      } catch (_) {}
      _bump();
    });
  }

  void disposeSession() {
    _resizeDebounce?.cancel();
    _outputSub?.cancel();
    _outputSub = null;
  }

  // ------------------------------------------------- lines for the renderer

  List<String>? _linesCache;

  /// Scrollback + viewport, each line re-serialized with ANSI SGR so the
  /// existing renderer keeps its per-run colours.
  List<String> get lines {
    final cached = _linesCache;
    if (cached != null) return cached;
    final out = <String>[];
    for (final l in buffer.scrollback) {
      out.add(_ansiOfLine(l));
    }
    for (var r = 0; r < buffer.rows; r++) {
      out.add(_ansiOfLine(buffer.lines[r]));
    }
    _linesCache = out;
    return out;
  }

  int get cursorRow => buffer.scrollback.length + buffer.cursorRow;
  int get cursorCol => buffer.cursorCol;

  String _ansiOfLine(TermLine line) {
    // Trim trailing untouched blanks so we don't ship 120 spaces per line.
    var end = line.cells.length;
    while (end > 0) {
      final c = line.cells[end - 1];
      if (c.width != 0 && c.isBlank && c.attr.isPlain) {
        end--;
      } else {
        break;
      }
    }
    if (end == 0) return '';

    final sb = StringBuffer();
    TermAttr? cur;
    for (var i = 0; i < end; i++) {
      final cell = line.cells[i];
      if (cell.width == 0) {
        sb.write(' '); // نیمه‌ی راست کاراکتر پهن: یک ستون فضا نگه دار
        continue;
      }
      if (cell.attr != cur) {
        cur = cell.attr;
        sb.write(_sgrFor(cur));
      }
      sb.write(cell.ch.isEmpty ? ' ' : cell.ch);
    }
    if (cur != null && !cur.isPlain) sb.write('\x1b[0m');
    return sb.toString();
  }

  String _sgrFor(TermAttr a) {
    final b = StringBuffer('\x1b[0');
    if (a.bold) b.write(';1');
    if (a.dim) b.write(';2');
    if (a.italic) b.write(';3');
    if (a.underline) b.write(';4');
    if (a.inverse) b.write(';7');
    if (a.hidden) b.write(';8');
    if (a.strike) b.write(';9');
    b.write(_colorCode(a.fg, true));
    b.write(_colorCode(a.bg, false));
    b.write('m');
    return b.toString();
  }

  String _colorCode(int c, bool fg) {
    if (c == kDefaultColor) return '';
    if (isRgbColor(c)) {
      final r = (c >> 16) & 0xFF;
      final g = (c >> 8) & 0xFF;
      final b = c & 0xFF;
      return ';${fg ? 38 : 48};2;$r;$g;$b';
    }
    if (c < 8) return ';${(fg ? 30 : 40) + c}';
    if (c < 16) return ';${(fg ? 90 : 100) + c - 8}';
    return ';${fg ? 38 : 48};5;$c';
  }
}

// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyTerminalApp());
}

class MyTerminalApp extends StatelessWidget {
  const MyTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sobhan Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E676),
          surface: Colors.black,
        ),
      ),
      home: const TerminalScreen(),
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const double _fontSize = 13;

  // یک تم واحد؛ هم اندازه‌گیری سلول و هم رندر از همین می‌خونن
  static const RtlTerminalTheme _theme = RtlTerminalTheme(
    background: Colors.black,
    foreground: Color(0xFFEEEEEE),
    cursor: Color(0xFF00FF66),
    fontSize: _fontSize,
    fontFamily: 'monospace',
    lineHeight: 1.2,
  );

  final session = TerminalSessionManager();
  final FocusNode _terminalFocusNode = FocusNode();

  double _cellW = 7.8;
  double _cellH = 17.0;
  bool _measured = false;

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    if (!session.isSessionStarted) {
      _setupAndStartSession();
    }
  }

  /// Measure ONE character once. Never derive cell size from output text,
  /// otherwise cols changes -> SIGWINCH -> shell redraws -> cols changes...
  void _measureCells() {
    final m = measureCellMetrics(_theme);
    _cellW = m.width;
    _cellH = m.height;
    _measured = true;
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sobhan_terminal_service',
        channelName: 'Sobhan Terminal Background Service',
        channelDescription: 'Maintains Ubuntu chroot session and background daemons active.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    final notificationStatus = await Permission.notification.status;
    if (notificationStatus.isDenied) {
      await Permission.notification.request();
    }

    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'Sobhan Terminal (Linux Active)',
        notificationText: 'محیط اوبونتو فعال است و در پس‌زمینه اجرا می‌شود',
        callback: startCallback,
      );
    }

    if (mounted) {
      setState(() {
        session.isServiceRunning = true;
      });
    }
  }

  Future<void> _stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    if (mounted) {
      setState(() {
        session.isServiceRunning = false;
      });
    }
  }

  Future<void> _setupAndStartSession() async {
    setState(() {
      session.isInitializing = true;
      session.rootError = false;
    });

    try {
      session.log('\x1b[32m[+]\x1b[0m Initializing Sobhan Terminal...');

      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }

      ProcessResult checkBash;
      try {
        checkBash = await Process.run('su', [
          '-c',
          '[ -f /data/ubuntu/bin/bash ] && echo "EXISTS" || echo "NOT_EXISTS"',
        ]);
      } catch (e) {
        throw const ProcessException('su', ['-c', '...'], 'Root permission denied or su binary hidden.');
      }

      if (checkBash.exitCode != 0) {
        throw const ProcessException('su', ['-c', '...'], 'Superuser privilege not granted.');
      }

      final exists = checkBash.stdout.toString().trim() == 'EXISTS';
      final tempDir = await getTemporaryDirectory();

      if (!exists) {
        session.log('\x1b[33m[*]\x1b[0m Ubuntu RootFS not found. Installing from assets...');

        final tempTarPath = '${tempDir.path}/ubuntu-base-arm64.tar.gz';

        session.log('\x1b[33m[*]\x1b[0m Extracting package from APK...');
        final byteData = await rootBundle.load('assets/rootfs/ubuntu-base-arm64.tar.gz');
        final buffer = byteData.buffer;
        await File(tempTarPath).writeAsBytes(
          buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
          flush: true,
        );

        session.log('\x1b[33m[*]\x1b[0m Unpacking RootFS into /data/ubuntu (please wait)...');
        final installScript = '''
mkdir -p /data/ubuntu
tar -xzf "$tempTarPath" -C /data/ubuntu/
rm -f "$tempTarPath"
chmod 755 /data/ubuntu
''';

        final installProcess = await Process.run('su', ['-c', installScript]);
        if (installProcess.exitCode != 0) {
          session.log('\x1b[31m[-]\x1b[0m Installation failed: ${installProcess.stderr}');
          return;
        }
        session.log('\x1b[32m[+]\x1b[0m Ubuntu RootFS installed successfully!');
      }

      session.log('\x1b[33m[*]\x1b[0m Checking core utilities & system configuration...');

      const initSystemScript = r'''
UBUNTU_DIR="/data/ubuntu"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

mountpoint -q $UBUNTU_DIR/dev || mount --bind /dev $UBUNTU_DIR/dev
mountpoint -q $UBUNTU_DIR/dev/pts || mount -t devpts devpts $UBUNTU_DIR/dev/pts -o ptmxmode=0666,mode=620 2>/dev/null || mount --bind /dev/pts $UBUNTU_DIR/dev/pts
mountpoint -q $UBUNTU_DIR/proc || mount -t proc proc $UBUNTU_DIR/proc
mountpoint -q $UBUNTU_DIR/sys || mount -t sysfs sysfs $UBUNTU_DIR/sys

rm -f $UBUNTU_DIR/etc/resolv.conf
echo "nameserver 8.8.8.8" > $UBUNTU_DIR/etc/resolv.conf
echo "nameserver 1.1.1.1" >> $UBUNTU_DIR/etc/resolv.conf

grep -q "aid_inet" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_inet:x:3003:root,sobhan" >> $UBUNTU_DIR/etc/group
grep -q "aid_sdcard_rw" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_sdcard_rw:x:1015:root,sobhan" >> $UBUNTU_DIR/etc/group
grep -q "aid_media_rw" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_media_rw:x:1023:root,sobhan" >> $UBUNTU_DIR/etc/group
grep -q "aid_everybody" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_everybody:x:9997:root,sobhan" >> $UBUNTU_DIR/etc/group

if ! grep -q "^sobhan:" $UBUNTU_DIR/etc/passwd 2>/dev/null; then
  chroot $UBUNTU_DIR /usr/sbin/useradd -m -u 1000 -s /bin/bash sobhan 2>/dev/null || chroot $UBUNTU_DIR /bin/useradd -m -u 1000 -s /bin/bash sobhan 2>/dev/null
fi

chroot $UBUNTU_DIR /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && usermod -aG aid_inet,aid_sdcard_rw,aid_media_rw,aid_everybody sobhan 2>/dev/null"

if [ ! -f "$UBUNTU_DIR/usr/bin/sudo" ] || [ ! -f "$UBUNTU_DIR/usr/bin/curl" ]; then
  chroot $UBUNTU_DIR /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && apt-get update && apt-get install -y --no-install-recommends sudo curl wget git nano ca-certificates net-tools"
fi

if [ -f "$UBUNTU_DIR/usr/bin/sudo" ]; then
  chmod 4755 $UBUNTU_DIR/usr/bin/sudo 2>/dev/null
  chroot $UBUNTU_DIR /bin/bash -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && usermod -aG sudo sobhan 2>/dev/null"
  mkdir -p $UBUNTU_DIR/etc/sudoers.d
  echo "sobhan ALL=(ALL:ALL) NOPASSWD:ALL" > $UBUNTU_DIR/etc/sudoers.d/sobhan
  chmod 0440 $UBUNTU_DIR/etc/sudoers.d/sobhan
fi

mkdir -p $UBUNTU_DIR/home/sobhan
ln -sfn /sdcard $UBUNTU_DIR/home/sobhan/sdcard 2>/dev/null

cat << 'BASHRC_EOF' > $UBUNTU_DIR/home/sobhan/.bashrc
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PS1='\[\033[01;32m\]sobhan\[\033[00m\]@\[\033[01;35m\]localhost\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
BASHRC_EOF

cat << 'PROFILE_EOF' > $UBUNTU_DIR/home/sobhan/.bash_profile
if [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
PROFILE_EOF

cp $UBUNTU_DIR/home/sobhan/.bash_profile $UBUNTU_DIR/home/sobhan/.profile
chown -R 1000:1000 $UBUNTU_DIR/home/sobhan 2>/dev/null

cat << 'LAUNCHER_EOF' > /data/ubuntu-login.sh
#!/system/bin/sh
UBUNTU_DIR="/data/ubuntu"

cleanup() {
  echo ""
  echo "[*] Cleaning up mounts..."
  umount -l $UBUNTU_DIR/sdcard 2>/dev/null
  umount -l $UBUNTU_DIR/sys 2>/dev/null
  umount -l $UBUNTU_DIR/proc 2>/dev/null
  umount -l $UBUNTU_DIR/dev/pts 2>/dev/null
  umount -l $UBUNTU_DIR/dev 2>/dev/null
  umount -l $UBUNTU_DIR 2>/dev/null
  echo "[+] Unmounted successfully."
}

trap cleanup EXIT INT TERM

mountpoint -q $UBUNTU_DIR || mount --bind $UBUNTU_DIR $UBUNTU_DIR
mount -o remount,suid,dev $UBUNTU_DIR 2>/dev/null

mountpoint -q $UBUNTU_DIR/dev || mount --bind /dev $UBUNTU_DIR/dev
mountpoint -q $UBUNTU_DIR/dev/pts || mount -t devpts devpts $UBUNTU_DIR/dev/pts -o ptmxmode=0666,mode=620 2>/dev/null || mount --bind /dev/pts $UBUNTU_DIR/dev/pts
mountpoint -q $UBUNTU_DIR/proc || mount -t proc proc $UBUNTU_DIR/proc
mountpoint -q $UBUNTU_DIR/sys || mount -t sysfs sysfs $UBUNTU_DIR/sys

mkdir -p $UBUNTU_DIR/sdcard
if [ -d /storage/emulated/0 ]; then
  mountpoint -q $UBUNTU_DIR/sdcard || mount --bind /storage/emulated/0 $UBUNTU_DIR/sdcard
elif [ -d /sdcard ]; then
  mountpoint -q $UBUNTU_DIR/sdcard || mount --bind /sdcard $UBUNTU_DIR/sdcard
fi

if [ ! -s $UBUNTU_DIR/etc/resolv.conf ]; then
  rm -f $UBUNTU_DIR/etc/resolv.conf
  echo "nameserver 8.8.8.8" > $UBUNTU_DIR/etc/resolv.conf
  echo "nameserver 1.1.1.1" >> $UBUNTU_DIR/etc/resolv.conf
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM=xterm-256color
export TMPDIR=/tmp

if grep -q "^sobhan:" $UBUNTU_DIR/etc/passwd 2>/dev/null; then
  exec chroot $UBUNTU_DIR /bin/su - sobhan
else
  exec chroot $UBUNTU_DIR /bin/bash -l
fi
LAUNCHER_EOF
chmod 755 /data/ubuntu-login.sh
''';

      await Process.run('su', ['-c', initSystemScript]);

      session.log('\x1b[32m[+]\x1b[0m Starting terminal session...\r\n');
      session.startPtySession(onExit: () {
        _stopForegroundService();
        if (mounted) {
          _showExitDialog();
        }
      });
      await _startForegroundService();
    } catch (e) {
      session.log('\x1b[31m[-]\x1b[0m Root access required: Please grant Superuser access to Sobhan Terminal in KernelSU/Magisk!');
      if (mounted) {
        setState(() {
          session.rootError = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          session.isInitializing = false;
        });
      }
    }
  }

  Future<void> _showExitDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Color(0xFF00E676)),
            SizedBox(width: 8),
            Text('خروج از نشست', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'نشست ترمینال پایان یافت و آن‌مانت مسیرها با موفقیت انجام شد.\nبرای بستن برنامه دکمه زیر را لمس کنید.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B5E20),
            ),
            onPressed: () {
              SystemNavigator.pop();
            },
            child: const Text('بستن برنامه', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    final cleanRegex = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');
    final fullText = session.lines.map((l) => l.replaceAll(cleanRegex, '')).join('\n');
    if (fullText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: fullText));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('کل خروجی کپی شد'),
            duration: Duration(milliseconds: 600),
            backgroundColor: Color(0xFF1B5E20),
          ),
        );
      }
    }
  }

  Future<void> _pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      session.pasteText(data.text!);
    }
  }

  // ------------------------------------------------------------- keyboard

  static final Map<LogicalKeyboardKey, String> _escapes = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.arrowUp: '\x1b[A',
    LogicalKeyboardKey.arrowDown: '\x1b[B',
    LogicalKeyboardKey.arrowRight: '\x1b[C',
    LogicalKeyboardKey.arrowLeft: '\x1b[D',
    LogicalKeyboardKey.home: '\x1b[H',
    LogicalKeyboardKey.end: '\x1b[F',
    LogicalKeyboardKey.delete: '\x1b[3~',
    LogicalKeyboardKey.insert: '\x1b[2~',
    LogicalKeyboardKey.pageUp: '\x1b[5~',
    LogicalKeyboardKey.pageDown: '\x1b[6~',
    LogicalKeyboardKey.escape: '\x1b',
    LogicalKeyboardKey.f1: '\x1bOP',
    LogicalKeyboardKey.f2: '\x1bOQ',
    LogicalKeyboardKey.f3: '\x1bOR',
    LogicalKeyboardKey.f4: '\x1bOS',
    LogicalKeyboardKey.f5: '\x1b[15~',
    LogicalKeyboardKey.f6: '\x1b[17~',
    LogicalKeyboardKey.f7: '\x1b[18~',
    LogicalKeyboardKey.f8: '\x1b[19~',
    LogicalKeyboardKey.f9: '\x1b[20~',
    LogicalKeyboardKey.f10: '\x1b[21~',
    LogicalKeyboardKey.f11: '\x1b[23~',
    LogicalKeyboardKey.f12: '\x1b[24~',
  };

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      session.sendInput('\r');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      session.sendInput('\x7f');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      session.sendInput('\t');
      return KeyEventResult.handled;
    }

    final seq = _escapes[key];
    if (seq != null) {
      session.sendInput(seq);
      return KeyEventResult.handled;
    }

    final ch = event.character;
    if (ch == null || ch.isEmpty) return KeyEventResult.ignored;

    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed && ch.length == 1) {
      final code = ch.toLowerCase().codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        session.sendInput(String.fromCharCode(code - 0x60));
        return KeyEventResult.handled;
      }
      if (ch == ' ') {
        session.sendInput('\x00');
        return KeyEventResult.handled;
      }
    }

    if (ch.codeUnitAt(0) < 0x20) return KeyEventResult.ignored;

    session.sendInput(ch);
    return KeyEventResult.handled;
  }

  Widget _buildMinimalToolbar() {
    return Container(
      height: 38,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _copyAll,
                child: const Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.copy, size: 14, color: Colors.white70),
                      SizedBox(width: 6),
                      Text(
                        'COPY',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Material(
              color: const Color(0xFF141414),
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _pasteText,
                child: const Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.paste, size: 14, color: Colors.white70),
                      SizedBox(width: 6),
                      Text(
                        'PASTE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    session.disposeSession();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: true,
          bottom: true,
          child: Column(
            children: [
              if (session.rootError)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  color: Colors.red.shade900,
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'دسترسی روت برقرار نشد! لطفاً در KernelSU مجوز Superuser را تایید کنید.',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white12,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _setupAndStartSession,
                        child: const Text('تلاش مجدد', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!_measured) _measureCells();

                    final cols = (constraints.maxWidth / _cellW).floor().clamp(20, 400).toInt();
                    final rows = (constraints.maxHeight / _cellH).floor().clamp(5, 200).toInt();

                    // Never mutate state during build.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      session.requestGrid(cols, rows);
                    });

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _terminalFocusNode.requestFocus();
                        SystemChannels.textInput.invokeMethod('TextInput.show');
                      },
                      child: Focus(
                        focusNode: _terminalFocusNode,
                        autofocus: true,
                        onKeyEvent: _handleKey,
                        child: ValueListenableBuilder<int>(
                          valueListenable: session.lineUpdateNotifier,
                          builder: (context, _, __) {
                            return RtlTerminalView(
                              buffer: session.buffer,
                              theme: _theme,
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              _buildMinimalToolbar(),
            ],
          ),
        ),
      ),
    );
  }
}
