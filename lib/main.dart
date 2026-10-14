import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:xterm/xterm.dart';
import 'x11_view.dart';

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
  Future<FutureOr<void>> onDestroy(DateTime timestamp) async {}
}

class TerminalSessionManager {
  static final TerminalSessionManager _instance = TerminalSessionManager._internal();
  factory TerminalSessionManager() => _instance;
  TerminalSessionManager._internal();

  final Terminal terminal = Terminal(maxLines: 10000);
  final TerminalController terminalController = TerminalController();
  final ScrollController terminalScrollController = ScrollController();
  
  Pty? pty;
  bool isSessionStarted = false;
  bool isInitializing = false;
  bool rootError = false;
  bool isServiceRunning = false;

  void log(String message) {
    terminal.write('$message\r\n');
  }

  void startPtySession({required VoidCallback onExit}) {
    if (isSessionStarted && pty != null) return;

    pty = Pty.start(
      'su',
      arguments: ['-c', 'exec /system/bin/sh /data/ubuntu-login.sh'],
      columns: 80,
      rows: 25,
      environment: {
        'TERM': 'xterm-256color',
        'PATH': '/sbin:/system/sbin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin',
      },
    );

    isSessionStarted = true;

    pty!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((data) {
      terminal.write(data);
    });

    terminal.onOutput = (data) {
      pty?.write(Uint8List.fromList(utf8.encode(data)));
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      pty?.resize(height, width);
    };

    pty!.exitCode.then((code) {
      isSessionStarted = false;
      pty = null;
      onExit();
    });
  }

  void sendKey(List<int> bytes) {
    pty?.write(Uint8List.fromList(bytes));
  }

  void pasteText(String text) {
    pty?.write(Uint8List.fromList(utf8.encode(text)));
  }
}

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
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF388E3C),
          surface: Color(0xFF252526),
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
  final session = TerminalSessionManager();
  Timer? _autoScrollTimer;
  bool _ctrlPressed = false;
  bool _altPressed = false;
  bool _hasSelection = false;
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    session.terminalController.addListener(_onSelectionChanged);

    _initForegroundTask();
    if (!session.isSessionStarted) {
      _setupAndStartSession();
    }
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

  void _onSelectionChanged() {
    final hasSel = session.terminalController.selection != null;
    if (hasSel != _hasSelection) {
      setState(() {
        _hasSelection = hasSel;
      });
    }
  }

  Future<void> _extractServerBinaries(String tempPath) async {
    try {
      final binaries = ['frame_server', 'touch_server'];
      for (final bin in binaries) {
        final byteData = await rootBundle.load('assets/bin/$bin');
        final targetFile = File('$tempPath/$bin');
        await targetFile.writeAsBytes(
          byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
          flush: true,
        );
      }

      await Process.run('su', [
        '-c',
        '''
mkdir -p /data/ubuntu/usr/local/bin
cp $tempPath/frame_server /data/ubuntu/usr/local/bin/frame_server
cp $tempPath/touch_server /data/ubuntu/usr/local/bin/touch_server
chmod 755 /data/ubuntu/usr/local/bin/frame_server
chmod 755 /data/ubuntu/usr/local/bin/touch_server
rm -f $tempPath/frame_server $tempPath/touch_server
''',
      ]);
      session.log('\x1B[1;32m[+] X11 bridge binaries installed.\x1B[0m');
    } catch (e) {
      session.log('\x1B[1;33m[!] Warning extracting bridge binaries: $e\x1B[0m');
    }
  }

  Future<void> _extractDesktopBundle(String tempPath) async {
    try {
      final checkDesktop = await Process.run('su', [
        '-c',
        '[ -f /data/ubuntu/usr/bin/startxfce4 ] && echo "INSTALLED" || echo "NOT_INSTALLED"',
      ]);

      if (checkDesktop.stdout.toString().trim() == 'INSTALLED') {
        return;
      }

      session.log('[*] Extracting desktop bundle from assets...');
      final byteData = await rootBundle.load('assets/desktop_bundle.tar.gz');
      final tempBundlePath = '$tempPath/desktop_bundle.tar.gz';
      await File(tempBundlePath).writeAsBytes(
        byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
        flush: true,
      );

      session.log('[*] Installing desktop bundle into /data/ubuntu...');
      final installBundleScript = '''
tar -xzf "$tempBundlePath" -C /data/ubuntu/
rm -f "$tempBundlePath"
''';
      final res = await Process.run('su', ['-c', installBundleScript]);
      if (res.exitCode == 0) {
        session.log('\x1B[1;32m[+] Desktop bundle extracted successfully.\x1B[0m');
      } else {
        session.log('\x1B[1;31m[-] Error extracting desktop bundle: ${res.stderr}\x1B[0m');
      }
    } catch (e) {
      session.log('\x1B[1;33m[!] Desktop bundle asset not found or skipped: $e\x1B[0m');
    }
  }

  Future<void> _setupAndStartSession() async {
    setState(() {
      session.isInitializing = true;
      session.rootError = false;
    });

    try {
      session.log('\x1B[1;36m[+] Initializing Sobhan Terminal...\x1B[0m');

      ProcessResult checkBash;
      try {
        checkBash = await Process.run('su', [
          '-c',
          '[ -f /data/ubuntu/bin/bash ] && echo "EXISTS" || echo "NOT_EXISTS"',
        ]);
      } catch (e) {
        throw const ProcessException('su', ['-c', '...'], 'Root permission denied or su binary hidden by KernelSU.');
      }

      if (checkBash.exitCode != 0) {
        throw const ProcessException('su', ['-c', '...'], 'Superuser privilege not granted.');
      }

      final exists = checkBash.stdout.toString().trim() == 'EXISTS';
      final tempDir = await getTemporaryDirectory();

      if (!exists) {
        session.log('\x1B[1;33m[*] Ubuntu RootFS not found. Installing from assets...\x1B[0m');

        final tempTarPath = '${tempDir.path}/ubuntu-base-arm64.tar.gz';

        session.log('[*] Extracting package from APK...');
        final byteData = await rootBundle.load('assets/rootfs/ubuntu-base-arm64.tar.gz');
        final buffer = byteData.buffer;
        await File(tempTarPath).writeAsBytes(
          buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
          flush: true,
        );

        session.log('[*] Unpacking RootFS into /data/ubuntu (please wait)...');
        final installScript = '''
mkdir -p /data/ubuntu
tar -xzf "$tempTarPath" -C /data/ubuntu/
rm -f "$tempTarPath"
chmod 755 /data/ubuntu
''';

        final installProcess = await Process.run('su', ['-c', installScript]);
        if (installProcess.exitCode != 0) {
          session.log('\x1B[1;31m[-] Installation failed: ${installProcess.stderr}\x1B[0m');
          return;
        }
        session.log('\x1B[1;32m[+] Ubuntu RootFS installed successfully!\x1B[0m');
      }

      await _extractServerBinaries(tempDir.path);
      await _extractDesktopBundle(tempDir.path);

      session.log('[*] Preparing launcher and network config...');
      const launcherScript = r'''
cat << 'LAUNCHER_EOF' > /data/ubuntu-login.sh
#!/system/bin/sh
UBUNTU_DIR="/data/ubuntu"

cleanup() {
  echo ""
  echo "[*] Cleaning up mounts..."
  pkill -f /usr/local/bin/frame_server 2>/dev/null
  pkill -f /usr/local/bin/touch_server 2>/dev/null
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

if [ -d /sdcard ]; then
  mkdir -p $UBUNTU_DIR/sdcard
  mountpoint -q $UBUNTU_DIR/sdcard || mount --bind /sdcard $UBUNTU_DIR/sdcard
fi

if [ ! -s $UBUNTU_DIR/etc/resolv.conf ]; then
  rm -f $UBUNTU_DIR/etc/resolv.conf
  echo "nameserver 8.8.8.8" > $UBUNTU_DIR/etc/resolv.conf
  echo "nameserver 1.1.1.1" >> $UBUNTU_DIR/etc/resolv.conf
fi

if ! grep -q "127.0.0.1 localhost" $UBUNTU_DIR/etc/hosts 2>/dev/null; then
  echo "127.0.0.1 localhost" >> $UBUNTU_DIR/etc/hosts
fi

if ! grep -q "aid_inet" $UBUNTU_DIR/etc/group 2>/dev/null; then
  echo "aid_inet:x:3003:root,sobhan" >> $UBUNTU_DIR/etc/group
fi

chmod 4755 $UBUNTU_DIR/usr/bin/sudo 2>/dev/null

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

      await Process.run('su', ['-c', launcherScript]);

      session.log('\x1B[1;32m[+] Starting terminal session...\x1B[0m\r\n');
      session.startPtySession(onExit: () {
        _stopForegroundService();
        if (mounted) {
          _showExitDialog();
        }
      });
      await _startForegroundService();
    } catch (e) {
      session.log('\x1B[1;31m[-] Root access required: Please grant Superuser access to Sobhan Terminal in KernelSU/Magisk!\x1B[0m');
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
        backgroundColor: const Color(0xFF252526),
        title: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Color(0xFF388E3C)),
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
              backgroundColor: const Color(0xFF388E3C),
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

  Future<void> _copyText() async {
    final selection = session.terminalController.selection;
    String? text;

    if (selection != null) {
      try {
        text = session.terminal.buffer.getText(selection);
      } catch (_) {}
    }

    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      session.terminalController.clearSelection();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('کپی شد'),
            duration: Duration(milliseconds: 600),
            backgroundColor: Color(0xFF388E3C),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('متنی انتخاب نشده است'),
            duration: Duration(milliseconds: 600),
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

  void _scrollRelative(double delta) {
    if (session.terminalScrollController.hasClients) {
      final target = (session.terminalScrollController.offset + delta)
          .clamp(0.0, session.terminalScrollController.position.maxScrollExtent);
      session.terminalScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  void _handlePointerMove(PointerMoveEvent event, BoxConstraints constraints) {
    final y = event.localPosition.dy;
    const threshold = 50.0;

    if (y < threshold) {
      _startAutoScroll(-25.0);
    } else if (y > constraints.maxHeight - threshold) {
      _startAutoScroll(25.0);
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll(double delta) {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = periodicAutoScroll(delta);
  }

  Timer periodicAutoScroll(double delta) {
    return Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (session.terminalScrollController.hasClients) {
        final current = session.terminalScrollController.offset;
        final target = (current + delta).clamp(0.0, session.terminalScrollController.position.maxScrollExtent);
        session.terminalScrollController.jumpTo(target);
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  Widget _buildKeyButton(String label, {VoidCallback? onTap, bool isActive = false, Color? highlightColor, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Material(
        color: isActive 
            ? (highlightColor ?? const Color(0xFF388E3C)) 
            : const Color(0xFF333333),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: isActive ? Colors.white : Colors.white70),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTerminalToolbar() {
    return Container(
      height: 44,
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _buildKeyButton('PASTE', onTap: _pasteText),
          _buildKeyButton(
            'COPY',
            isActive: _hasSelection,
            highlightColor: Colors.green.shade800,
            onTap: _copyText,
          ),
          if (_hasSelection)
            _buildKeyButton('CLEAR', onTap: () => session.terminalController.clearSelection()),
          _buildKeyButton('ESC', onTap: () => session.sendKey([0x1B])),
          _buildKeyButton('TAB', onTap: () => session.sendKey([0x09])),
          _buildKeyButton('CTRL', isActive: _ctrlPressed, onTap: () {
            setState(() {
              _ctrlPressed = !_ctrlPressed;
            });
          }),
          _buildKeyButton('ALT', isActive: _altPressed, onTap: () {
            setState(() {
              _altPressed = !_altPressed;
            });
          }),
          _buildKeyButton('CTRL+C', onTap: () => session.sendKey([0x03])),
          _buildKeyButton('CTRL+Z', onTap: () => session.sendKey([0x1A])),
          _buildKeyButton('CTRL+D', onTap: () => session.sendKey([0x04])),
          _buildKeyButton('PGUP', onTap: () => _scrollRelative(-150)),
          _buildKeyButton('PGDN', onTap: () => _scrollRelative(150)),
          _buildKeyButton('▲', onTap: () => session.sendKey([0x1B, 0x5B, 0x41])),
          _buildKeyButton('▼', onTap: () => session.sendKey([0x1B, 0x5B, 0x42])),
          _buildKeyButton('◀', onTap: () => session.sendKey([0x1B, 0x5B, 0x44])),
          _buildKeyButton('▶', onTap: () => session.sendKey([0x1B, 0x5B, 0x43])),
          
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            width: 1.5,
            color: Colors.white24,
          ),
          
          _buildKeyButton(
            'Desktop',
            icon: Icons.desktop_windows,
            highlightColor: const Color(0xFF388E3C),
            onTap: () => setState(() => _activeTabIndex = 1),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _stopAutoScroll();
    session.terminalController.removeListener(_onSelectionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: SafeArea(
          top: true,
          bottom: true,
          child: IndexedStack(
            index: _activeTabIndex,
            children: [
              Column(
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
                        return Listener(
                          onPointerMove: (e) => _handlePointerMove(e, constraints),
                          onPointerUp: (_) => _stopAutoScroll(),
                          onPointerCancel: (_) => _stopAutoScroll(),
                          child: Scrollbar(
                            controller: session.terminalScrollController,
                            child: TerminalView(
                              session.terminal,
                              controller: session.terminalController,
                              scrollController: session.terminalScrollController,
                              autofocus: true,
                              backgroundOpacity: 1.0,
                              textStyle: const TerminalStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                              autoResize: true,
                              simulateScroll: false,
                              readOnly: session.isInitializing,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  _buildTerminalToolbar(),
                ],
              ),
              X11View(
                onBackToTerminal: () {
                  setState(() => _activeTabIndex = 0);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
