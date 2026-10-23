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

const pureBlackTerminalTheme = TerminalTheme(
  cursor: Color(0xFF00FF66),
  selection: Color(0x5500FF66),
  foreground: Color(0xFFEEEEEE),
  background: Color(0xFF000000),
  black: Color(0xFF000000),
  red: Color(0xFFFF5252),
  green: Color(0xFF00E676),
  yellow: Color(0xFFFFEA00),
  blue: Color(0xFF40C4FF),
  magenta: Color(0xFFE040FB),
  cyan: Color(0xFF18FFFF),
  white: Color(0xFFFFFFFF),
  brightBlack: Color(0xFF555555),
  brightRed: Color(0xFFFF8A80),
  brightGreen: Color(0xFFB9F6CA),
  brightYellow: Color(0xFFFFFF8D),
  brightBlue: Color(0xFF80D8FF),
  brightMagenta: Color(0xFFFF80AB),
  brightCyan: Color(0xFFA7FFEB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFEA00),
  searchHitBackgroundCurrent: Color(0xFFFF9100),
  searchHitForeground: Color(0xFF000000),
);

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
    final safeText = text.replaceAll(RegExp(r'[\r\n\x00-\x1F\x7F]+'), ' ').trim();
    if (safeText.isNotEmpty) {
      pty?.write(Uint8List.fromList(utf8.encode(safeText)));
    }
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
  final session = TerminalSessionManager();
  Timer? _autoScrollTimer;
  bool _hasSelection = false;

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

  Future<void> _setupAndStartSession() async {
    setState(() {
      session.isInitializing = true;
      session.rootError = false;
    });

    try {
      session.log('\x1B[1;36m[+] Initializing Sobhan Terminal...\x1B[0m');

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

      session.log('[*] Checking core utilities & system configuration...');

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
export PS1='\[\033[01;32m\]\u\[\033[00m\]@\[\033[01;35m\]localhost\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
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
            backgroundColor: Color(0xFF1B5E20),
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

  Widget _buildMinimalToolbar() {
    return Container(
      height: 38,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: _hasSelection ? const Color(0xFF1B5E20) : const Color(0xFF141414),
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _copyText,
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
    _stopAutoScroll();
    session.terminalController.removeListener(_onSelectionChanged);
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
                    return Listener(
                      onPointerMove: (e) => _handlePointerMove(e, constraints),
                      onPointerUp: (_) => _stopAutoScroll(),
                      onPointerCancel: (_) => _stopAutoScroll(),
                      child: Container(
                        color: Colors.black,
                        child: Scrollbar(
                          controller: session.terminalScrollController,
                          child: TerminalView(
                            session.terminal,
                            controller: session.terminalController,
                            scrollController: session.terminalScrollController,
                            theme: pureBlackTerminalTheme,
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
