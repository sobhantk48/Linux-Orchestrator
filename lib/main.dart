import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'rtl_terminal.dart';
import 'ime_bridge.dart';
import 'terminal_session.dart';
import 'distro.dart';
import 'distro_install.dart';
import 'distro_catalog.dart';
import 'settings.dart';
import 'user_setup.dart';
import 'desktop.dart';
import 'desktop_view.dart';

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

// #SOB-LOGIN-TPL: بدنهٔ اسکریپت ورود، مستقل از init نوشته می‌شود تا اگر init
// نیمه‌کاره بماند، اسکریپت ورود باز هم وجود داشته باشد.
const String _loginScriptTpl = r'''
#!/system/bin/sh
UBUNTU_DIR="__DISTRO_DIR__"

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

# #SOB-CHROOT: PATH میزبان (اندروید) — PATH مهمان را CE می‌سازد.
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH
export TERM=xterm-256color
export TMPDIR=/tmp

# #SOB-SHELL: پوسته و su را در زمان اجرا دوباره بررسی کن.
SHELL_BIN="__SHELL__"
if [ ! -x "$UBUNTU_DIR$SHELL_BIN" ]; then
  for _c in /bin/bash /usr/bin/bash /bin/ash /usr/bin/ash /bin/sh /usr/bin/sh; do
    if [ -x "$UBUNTU_DIR$_c" ]; then SHELL_BIN="$_c"; break; fi
  done
fi
[ -x "$UBUNTU_DIR$SHELL_BIN" ] || SHELL_BIN=/bin/sh

# #SOB-SHELL: آیا پوسته گزینهٔ ورود (-l) را می‌پذیرد؟ busybox ash ممکن است نه.
LOGIN_OPT="-l"
chroot $UBUNTU_DIR "$SHELL_BIN" -lc 'exit 0' >/dev/null 2>&1 || LOGIN_OPT="-i"

SU_BIN=/bin/su
[ -x "$UBUNTU_DIR$SU_BIN" ] || SU_BIN=/usr/bin/su

# #SOB-CLEANENV: محیط تمیز مثل اجرای دستیِ موفق در Termux (env -i ... chroot).
CE="env -i HOME=/root TERM=xterm-256color PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# #SOB-CHROOT: chroot ممکن است در PATH نباشد؛ مسیر مطلق را پیدا کن.
CHROOT_BIN=""
for _c in /system/bin/chroot /system/xbin/chroot /system/bin/toybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ksud/busybox; do
  [ -x "$_c" ] && { CHROOT_BIN="$_c"; break; }
done
command -v chroot >/dev/null 2>&1 && CHROOT_BIN=$(command -v chroot)

do_chroot() {
  case "$CHROOT_BIN" in
    *busybox|*toybox) $CE "$CHROOT_BIN" chroot "$@" ;;
    "") return 127 ;;
    *) $CE "$CHROOT_BIN" "$@" ;;
  esac
}

if [ -z "$CHROOT_BIN" ]; then
  echo "[!] chroot not found on host - cannot start __USER__ shell." >&2
  exit 127
fi

# #SOB-SHELL: آیا پوسته گزینهٔ ورود (-l) را می‌پذیرد؟ busybox ash ممکن است نه.
LOGIN_OPT="-l"
do_chroot $UBUNTU_DIR "$SHELL_BIN" -lc 'exit 0' >/dev/null 2>&1 || LOGIN_OPT="-i"

SU_BIN=/bin/su
[ -x "$UBUNTU_DIR$SU_BIN" ] || SU_BIN=/usr/bin/su

# #SOB-SHELL: بدون exec تا کد خروج دیده شود و هرگز بی‌صدا خارج نشویم.
if grep -q "^__USER__:" $UBUNTU_DIR/etc/passwd 2>/dev/null && [ -x "$UBUNTU_DIR$SU_BIN" ]; then
  do_chroot $UBUNTU_DIR "$SU_BIN" - __USER__
  _rc=$?
  [ "$_rc" = "0" ] && exit 0
  echo "[!] login __USER__ failed ($_rc) - falling back to root." >&2
fi

do_chroot $UBUNTU_DIR "$SHELL_BIN" "$LOGIN_OPT"
_rc=$?
if [ "$_rc" != "0" ]; then
  echo "[!] shell $SHELL_BIN $LOGIN_OPT exited ($_rc) - retry without option." >&2
  do_chroot $UBUNTU_DIR "$SHELL_BIN"
  _rc=$?
  [ "$_rc" = "0" ] || echo "[!] shell failed ($_rc). chroot=$CHROOT_BIN shell=$SHELL_BIN" >&2
fi
''';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  TerminalSettings _settings = const TerminalSettings();
  // SOB-USER: رمز فقط یک‌بار برای chpasswd استفاده و ذخیره نمی‌شود.
  String _pendingPassword = '';
  late RtlTerminalTheme _theme;

  final TerminalManager _manager = TerminalManager();
  TerminalSession get session => _manager.active;
  final Map<int, GlobalKey<RtlTerminalViewState>> _viewKeys =
      <int, GlobalKey<RtlTerminalViewState>>{};
  GlobalKey<RtlTerminalViewState> get _terminalKey =>
      _viewKeys.putIfAbsent(
          session.id, () => GlobalKey<RtlTerminalViewState>());
  final Set<String> _preparedDistros = <String>{};
  // #SOB-LOGIN-TPL: کاربر لینوکسی هر توزیع برای جایگذاری در اسکریپت ورود.
  final Map<String, String> _distroUsers = <String, String>{};
  final Map<String, int> _distroRefs = <String, int>{};
  final Set<String> _desktopReady = <String>{};
  final Set<int> _releasedSessions = <int>{};
  final Set<String> _installedDistros = <String>{};
  final Map<String, int> _distroSizes = <String, int>{};
  bool _installing = false;
  final ValueNotifier<String> _installStatus = ValueNotifier<String>('');
  bool _mountStateReset = false;
  final FocusNode _terminalFocusNode = FocusNode();
  final GlobalKey<ImeBridgeState> _imeKey = GlobalKey<ImeBridgeState>();

  double _cellW = 7.8;
  double _cellH = 17.0;
  bool _measured = false;

  bool _searchVisible = false;
  final TextEditingController _searchController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _theme = buildTerminalTheme(_settings);
    _initForegroundTask();
    if (_manager.sessions.isEmpty) {
      final s = _manager.createSession('ubuntu');
      _viewKeys[s.id] = GlobalKey<RtlTerminalViewState>();
    }
    _manager.activeNotifier.addListener(_onActiveChanged);
    // SOB-FIRSTRUN: توزیع اول را از کاربر می‌پرسیم (قبلاً همیشه ubuntu بود).
    unawaited(_bootFirstSession());
    _initCatalog();
  }

  // SOB-FIRSTRUN: راه‌اندازی سشن اول؛ در اجرای اول توزیع را می‌پرسد.
  Future<void> _bootFirstSession() async {
    await _loadSettings();
    if (!mounted) return;
    await _scanDistros();
    if (!mounted) return;
    var target = 'ubuntu';
    var skipStart = false;
    if (_settings.firstRun) {
      if (_installedDistros.isEmpty) {
        final String? picked = await _askFirstDistro();
        if (!mounted) return;
        if (picked != null && picked.isNotEmpty) {
          final Distro d = DistroRegistry.byId(picked);
          if (d.bundledAsset != null) {
            target = picked;
          } else {
            // rootfs همراه اپ ندارد → باید دانلود شود؛ اوبونتو را نصب نمی‌کنیم.
            skipStart = true;
            unawaited(_showNeedUrl(d));
          }
        }
      }
      _settings = _settings.copyWith(firstRun: false);
      unawaited(TerminalSettingsStore.save(_settings));
    }
    if (!mounted) return;
    if (skipStart) {
      session.log(
          '\x1b[33m[*]\x1b[0m توزیع انتخاب‌شده باید دانلود شود. پس از پایان نصب، از منوی توزیع‌ها یک ترمینال باز کنید.');
      return;
    }
    final TerminalSession current = session;
    if (current.distro != target) {
      // اول سشن جدید ساخته می‌شود تا لیست هیچ‌وقت خالی نشود.
      final TerminalSession s = _manager.createSession(target);
      s.buffer.maxScrollback = _settings.scrollback;
      _viewKeys[s.id] = GlobalKey<RtlTerminalViewState>();
      _manager.sessions.remove(current);
      _viewKeys.remove(current.id);
      current.disposeSession();
      _manager.switchTo(_manager.sessions.indexOf(s));
      setState(() {});
      await _setupAndStartSession(s);
    } else {
      await _setupAndStartSession(current);
    }
  }

  // SOB-FIRSTRUN: انتخاب توزیع در اجرای اول.
  Future<String?> _askFirstDistro() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: const Text('کدام توزیع نصب شود؟',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: DistroRegistry.all.map((Distro d) {
              final DistroLink? link = DistroCatalog.linkFor(d.id);
              final String info = d.bundledAsset != null
                  ? 'همراه اپ (آفلاین)'
                  : (link != null
                      ? '${_formatBytes(link.sizeBytes)} • دانلود آنلاین'
                      : 'نصب با URL');
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.memory, color: d.accent, size: 20),
                title: Text(d.label,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(info,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 10)),
                onTap: () => Navigator.pop(ctx, d.id),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('بعداً'),
          ),
        ],
      ),
    );
  }

  void _onActiveChanged() {
    if (mounted) setState(() {});
  }

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
        channelDescription:
            'Maintains Linux chroot sessions and background daemons active.',
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
        notificationText: 'محیط لینوکس فعال است و در پس‌زمینه اجرا می‌شود',
        callback: startCallback,
      );
    }

    if (mounted) setState(() => session.isServiceRunning = true);
  }

  Future<void> _stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    if (mounted) setState(() => session.isServiceRunning = false);
  }

  // SOB-USER: پرسیدن نام کاربری و رمز در اولین نصب.
  Future<String> _askLinuxUser() async {
    if (!mounted) return '';
    final LinuxUser? u = await showLinuxUserSetup(context);
    if (u == null) return '';
    _pendingPassword = u.password;
    _settings = _settings.copyWith(username: u.username);
    unawaited(TerminalSettingsStore.save(_settings));
    return u.username;
  }

  // SOB-DETECT: اولین کاربر عادی (uid>=1000) داخل rootfs.
  Future<String> _detectExistingUser(String rootDir) async {
    try {
      final ProcessResult pr = await Process.run('su', <String>[
        '-c',
        'cat $rootDir/etc/passwd 2>/dev/null',
      ]);
      if (pr.exitCode != 0) return '';
      final List<String> lines =
          pr.stdout.toString().split('\n');
      for (final String line in lines) {
        final List<String> p = line.split(':');
        if (p.length < 7) continue;
        final String name = p[0].trim();
        final int uid = int.tryParse(p[2].trim()) ?? -1;
        final String sh = p[6].trim();
        if (uid < 1000 || uid >= 60000) continue;
        if (name == 'nobody') continue;
        if (sh.endsWith('nologin') || sh.endsWith('false')) continue;
        if (!LinuxUser.isValidName(name)) continue;
        if (LinuxUser.isReserved(name)) continue;
        return name;
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  Future<void> _setupAndStartSession([TerminalSession? target]) async {
    final session = target ?? this.session;
    final distro = DistroRegistry.byId(session.distro);

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
          '[ -f ${distro.rootDir}${distro.shell} ] && echo "EXISTS" || echo "NOT_EXISTS"',
        ]);
      } catch (e) {
        throw const ProcessException(
            'su', ['-c', '...'], 'Root permission denied or su binary hidden.');
      }

      if (checkBash.exitCode != 0) {
        throw const ProcessException(
            'su', ['-c', '...'], 'Superuser privilege not granted.');
      }

      final exists = checkBash.stdout.toString().trim() == 'EXISTS';

      // SOB-DETECT: کاربر موجود در rootfs را خودکار پیدا می‌کنیم.
      // اگر کاربری نبود، از تنظیمات یا دیالوگ استفاده می‌شود.
      String linuxUser = '';
      if (exists) {
        linuxUser = await _detectExistingUser(distro.rootDir);
      }
      if (linuxUser.isEmpty) {
        final String saved = _settings.username.trim();
        if (LinuxUser.isValidName(saved) && !LinuxUser.isReserved(saved)) {
          linuxUser = saved;
        }
      }
      if (linuxUser.isEmpty) {
        linuxUser = await _askLinuxUser();
        if (linuxUser.isEmpty) {
          session.log(
              '\x1b[33m[*]\x1b[0m Linux user setup cancelled.');
          return;
        }
      } else if (_settings.username != linuxUser) {
        _settings = _settings.copyWith(username: linuxUser);
        unawaited(TerminalSettingsStore.save(_settings));
      }
      session.log(
          '\x1b[33m[*]\x1b[0m Linux user: $linuxUser');
      _distroUsers[distro.id] = linuxUser;

      if (_preparedDistros.contains(distro.id) && exists) {
        await _startDistroSession(session, distro);
        return;
      }

      final tempDir = await getTemporaryDirectory();

      if (!exists) {
        final assetPath = distro.bundledAsset;
        if (assetPath == null) {
          session.log(
              '\x1b[31m[-]\x1b[0m No bundled RootFS for ${distro.label}. Install it from a URL first.');
          return;
        }

        session.log(
            '\x1b[33m[*]\x1b[0m ${distro.label} RootFS not found. Installing from assets...');

        final tempTarPath = '${tempDir.path}/${distro.id}-rootfs.tar.gz';

        session.log('\x1b[33m[*]\x1b[0m Extracting package from APK...');
        final byteData = await rootBundle.load(assetPath);
        final buffer = byteData.buffer;
        await File(tempTarPath).writeAsBytes(
          buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
          flush: true,
        );

        session.log(
            '\x1b[33m[*]\x1b[0m Unpacking RootFS into ${distro.rootDir} (please wait)...');
        final installScript = '''
mkdir -p ${distro.rootDir}
tar -xzf "$tempTarPath" -C ${distro.rootDir}/
rm -f "$tempTarPath"
chmod 755 ${distro.rootDir}
''';

        final installProcess = await Process.run('su', ['-c', installScript]);
        if (installProcess.exitCode != 0) {
          session.log(
              '\x1b[31m[-]\x1b[0m Installation failed: ${installProcess.stderr}');
          return;
        }
        _installedDistros.add(distro.id);
        session.log(
            '\x1b[32m[+]\x1b[0m ${distro.label} RootFS installed successfully!');
      }

      session.log(
          '\x1b[33m[*]\x1b[0m Checking core utilities & system configuration...');

      if (!_mountStateReset) {
        _mountStateReset = true;
        await Process.run('su', [
          '-c',
          'rm -rf /data/.mounts 2>/dev/null; exit 0',
        ]);
      }

      const initTpl = r'''
UBUNTU_DIR="__DISTRO_DIR__"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# #SOB-SHELL: پوسته واقعی موجود در این روت‌فاس را پیدا کن (آلپاین bash ندارد).
SHELL_BIN="__SHELL__"
if [ ! -x "$UBUNTU_DIR$SHELL_BIN" ]; then
  for _c in /bin/bash /usr/bin/bash /bin/ash /usr/bin/ash /bin/sh /usr/bin/sh; do
    if [ -x "$UBUNTU_DIR$_c" ]; then SHELL_BIN="$_c"; break; fi
  done
fi
[ -x "$UBUNTU_DIR$SHELL_BIN" ] || SHELL_BIN=/bin/sh

mountpoint -q $UBUNTU_DIR/dev || mount --bind /dev $UBUNTU_DIR/dev
mountpoint -q $UBUNTU_DIR/dev/pts || mount -t devpts devpts $UBUNTU_DIR/dev/pts -o ptmxmode=0666,mode=620 2>/dev/null || mount --bind /dev/pts $UBUNTU_DIR/dev/pts
mountpoint -q $UBUNTU_DIR/proc || mount -t proc proc $UBUNTU_DIR/proc
mountpoint -q $UBUNTU_DIR/sys || mount -t sysfs sysfs $UBUNTU_DIR/sys

rm -f $UBUNTU_DIR/etc/resolv.conf
echo "nameserver 8.8.8.8" > $UBUNTU_DIR/etc/resolv.conf
echo "nameserver 1.1.1.1" >> $UBUNTU_DIR/etc/resolv.conf

grep -q "aid_inet" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_inet:x:3003:root,__USER__" >> $UBUNTU_DIR/etc/group
grep -q "aid_sdcard_rw" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_sdcard_rw:x:1015:root,__USER__" >> $UBUNTU_DIR/etc/group
grep -q "aid_media_rw" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_media_rw:x:1023:root,__USER__" >> $UBUNTU_DIR/etc/group
grep -q "aid_everybody" $UBUNTU_DIR/etc/group 2>/dev/null || echo "aid_everybody:x:9997:root,__USER__" >> $UBUNTU_DIR/etc/group

if ! grep -q "^__USER__:" $UBUNTU_DIR/etc/passwd 2>/dev/null; then
  chroot $UBUNTU_DIR /usr/sbin/useradd -m -u 1000 -s "$SHELL_BIN" __USER__ 2>/dev/null \
    || chroot $UBUNTU_DIR /sbin/useradd -m -u 1000 -s "$SHELL_BIN" __USER__ 2>/dev/null \
    || chroot $UBUNTU_DIR /usr/sbin/adduser -D -u 1000 -s "$SHELL_BIN" __USER__ 2>/dev/null \
    || chroot $UBUNTU_DIR /sbin/adduser -D -u 1000 -s "$SHELL_BIN" __USER__ 2>/dev/null \
    || chroot $UBUNTU_DIR /bin/adduser -D -u 1000 -s "$SHELL_BIN" __USER__ 2>/dev/null \
    || true
fi

# #SOB-NET-GROUPS: busybox همر usermod ندارد؛ با addgroup هم امتحان کن.
for _g in aid_inet aid_sdcard_rw aid_media_rw aid_everybody; do
  chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && usermod -aG $_g __USER__" 2>/dev/null \
    || chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && addgroup __USER__ $_g" 2>/dev/null \
    || true
done
__PASS_BLOCK__

# #SOB-SHELL: نصب بسته‌ها نباید بلاک شود؛ با timeout اجرا کن.
INSTALL_TO=""
command -v timeout >/dev/null 2>&1 && INSTALL_TO="timeout 300"

if [ -x "$UBUNTU_DIR/usr/bin/apt-get" ]; then
  if [ ! -f "$UBUNTU_DIR/usr/bin/sudo" ] || [ ! -f "$UBUNTU_DIR/usr/bin/curl" ]; then
    chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && $INSTALL_TO apt-get update && $INSTALL_TO apt-get install -y --no-install-recommends sudo curl wget git nano ca-certificates net-tools" || true
  fi
elif [ -x "$UBUNTU_DIR/sbin/apk" ] || [ -x "$UBUNTU_DIR/usr/sbin/apk" ]; then
  if [ ! -x "$UBUNTU_DIR/usr/bin/sudo" ] || [ ! -x "$UBUNTU_DIR/usr/bin/curl" ]; then
    chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && $INSTALL_TO apk update && $INSTALL_TO apk add --no-cache sudo curl wget git nano ca-certificates" 2>/dev/null || true
  fi
fi

if [ -f "$UBUNTU_DIR/usr/bin/sudo" ]; then
  chmod 4755 $UBUNTU_DIR/usr/bin/sudo 2>/dev/null
  chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && usermod -aG sudo __USER__" 2>/dev/null \
    || chroot $UBUNTU_DIR "$SHELL_BIN" -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && addgroup __USER__ sudo" 2>/dev/null \
    || true
  mkdir -p $UBUNTU_DIR/etc/sudoers.d
  echo "__USER__ ALL=(ALL:ALL) NOPASSWD:ALL" > $UBUNTU_DIR/etc/sudoers.d/__USER__
  chmod 0440 $UBUNTU_DIR/etc/sudoers.d/__USER__
fi

mkdir -p $UBUNTU_DIR/home/__USER__
ln -sfn /sdcard $UBUNTU_DIR/home/__USER__/sdcard 2>/dev/null

# #SOB-SHELL: .profile استاندارد POSIX برای همه (busybox ash هم \w و \$ را می‌فهمد).
cat << 'PROFILE_EOF' > $UBUNTU_DIR/home/__USER__/.profile
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
PS1='__USER__@sobhan:\w \$ '
export PS1
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
PROFILE_EOF

if [ "$SHELL_BIN" = "/bin/bash" ] || [ "$SHELL_BIN" = "/usr/bin/bash" ]; then
cat << 'BASHRC_EOF' > $UBUNTU_DIR/home/__USER__/.bashrc
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PS1='\[\033[01;32m\]__USER__\[\033[00m\]@\[\033[01;35m\]sobhan\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
BASHRC_EOF
cat << 'BPR_EOF' > $UBUNTU_DIR/home/__USER__/.bash_profile
if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
BPR_EOF
fi

chown -R __USER__ $UBUNTU_DIR/home/__USER__ 2>/dev/null

''';

      // SOB-USER: تنظیم رمز با chpasswd (base64 برای عبور از کوتیشن).
      String passBlock = '';
      if (_pendingPassword.isNotEmpty) {
        final String b64 = base64Encode(
            utf8.encode('$linuxUser:$_pendingPassword'));
        _pendingPassword = '';
        // SOB-USER-LINT2
        final String pipe =
            'printf %s $b64 | base64 -d | chroot \$UBUNTU_DIR ';
        // SOB-USER-LINT3
        passBlock = '$pipe/usr/sbin/chpasswd 2>/dev/null || '
            '$pipe/usr/bin/chpasswd 2>/dev/null';
      }

      final initSystemScript = initTpl
          .replaceAll('__DISTRO_DIR__', distro.rootDir)
          .replaceAll('__SHELL__', distro.shell)
          .replaceAll('__USER__', linuxUser)
          .replaceAll('__PASS_BLOCK__', passBlock);

      await Process.run('su', ['-c', initSystemScript]);

      _preparedDistros.add(distro.id);
      _installedDistros.add(distro.id);
      await _startDistroSession(session, distro);
    } catch (e) {
      session.log(
          '\x1b[31m[-]\x1b[0m Root access required: Please grant Superuser access to Sobhan Terminal in KernelSU/Magisk!');
      if (mounted) setState(() => session.rootError = true);
    } finally {
      if (mounted) setState(() => session.isInitializing = false);
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
            Text('خروج از نشست',
                style: TextStyle(color: Colors.white, fontSize: 16)),
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
            onPressed: () => SystemNavigator.pop(),
            child: const Text('بستن برنامه',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAll() async {
    final selected = _terminalKey.currentState?.getSelectedText() ?? '';
    final bool hasSel = selected.trim().isNotEmpty;
    final String fullText;
    if (hasSel) {
      fullText = selected;
    } else {
      final cleanRegex = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');
      fullText = session.lines
          .map((l) => l.replaceAll(cleanRegex, ''))
          .join('\n');
    }
    if (fullText.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: fullText));
      _terminalKey.currentState?.clearSelection();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                hasSel ? 'متن انتخاب‌شده کپی شد' : 'کل خروجی کپی شد'),
            duration: const Duration(milliseconds: 600),
            backgroundColor: const Color(0xFF1B5E20),
          ),
        );
      }
    }
  }

  void _sendEnter() {
    session.sendInput('\r');
  }

  void _toggleKeyboard() {
    _imeKey.currentState?.toggleKeyboard();
  }

  Future<void> _pasteText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null && data.text!.isNotEmpty) {
      session.pasteText(data.text!);
    }
  }

  // ── search ──
  void _toggleSearch() {
    if (_searchVisible) {
      _closeSearch();
    } else {
      setState(() => _searchVisible = true);
    }
  }

  void _onSearchChanged(String value) {
    _terminalKey.currentState?.setSearchQuery(value);
    setState(() {});
  }

  void _searchNext() {
    _terminalKey.currentState?.searchNext();
    setState(() {});
  }

  void _searchPrev() {
    _terminalKey.currentState?.searchPrevious();
    setState(() {});
  }

  void _closeSearch() {
    _searchController.clear();
    _terminalKey.currentState?.clearSearch();
    setState(() => _searchVisible = false);
  }

  // ── keyboard ──

  static final Map<LogicalKeyboardKey, String> _escapes =
      <LogicalKeyboardKey, String>{
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

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
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

    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed) {
      final c = ctrlByte(key);
      if (c != null) {
        session.sendInput((hw.isAltPressed ? '\x1b' : '') + c);
        return KeyEventResult.handled;
      }
    }

    final ch = event.character;
    if (ch == null || ch.isEmpty) return KeyEventResult.ignored;

    if (ch.codeUnitAt(0) < 0x20) {
      session.sendInput(hw.isAltPressed ? '\x1b$ch' : ch);
      return KeyEventResult.handled;
    }
    if (hw.isAltPressed) {
      session.sendInput('\x1b$ch');
      return KeyEventResult.handled;
    }

    session.sendInput(ch);
    return KeyEventResult.handled;
  }

  // Ctrl+<key> -> C0 byte, from the logical key id (Android reports
  // no usable character for Ctrl combos).
  static String? ctrlByte(LogicalKeyboardKey key) {
    final int id = key.keyId;
    if (id >= 0x61 && id <= 0x7a) return String.fromCharCode(id - 0x60);
    switch (id) {
      case 0x20: case 0x32: case 0x40: return '\x00';
      case 0x5b: return '\x1b';
      case 0x5c: return '\x1c';
      case 0x5d: return '\x1d';
      case 0x5e: return '\x1e';
      case 0x5f: case 0x2f: return '\x1f';
      case 0x3f: return '\x7f';
      default: return null;
    }
  }

  Widget _hamburgerButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _openMenu,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.menu,
            size: 22,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Future<void> _loadSettings() async {
    final TerminalSettings loaded = await TerminalSettingsStore.load();
    if (!mounted) return;
    _settings = loaded;
    _applySettings();
  }

  /// تم و اسکرول‌بک را روی همهٔ سشن‌ها اعمال می‌کند و اندازهٔ سلول را بازمحاسبه.
  void _applySettings() {
    _theme = buildTerminalTheme(_settings);
    for (final TerminalSession s in _manager.sessions) {
      s.buffer.maxScrollback = _settings.scrollback;
    }
    _measured = false;
    if (mounted) setState(() {});
  }

  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              void commit(TerminalSettings next) {
                _settings = next;
                _applySettings();
                if (ctx.mounted) setSheet(() {}); // A3
                unawaited(TerminalSettingsStore.save(_settings).then((ok) {
                  if (!ok && mounted) {
                    _snack('ذخیرهٔ تنظیمات ناموفق بود', color: const Color(0xFFB71C1C));
                  }
                }));
              }

              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 16, 2),
                      child: Row(
                        children: [
                          Icon(Icons.tune,
                              color: Color(0xFF00E676), size: 20),
                          SizedBox(width: 8),
                          Text(
                            'تنظیمات ترمینال',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      title: const Text('اندازهٔ فونت',
                          style: TextStyle(color: Colors.white, fontSize: 13)),
                      subtitle: Text(
                        '${_settings.fontSize.toStringAsFixed(1)} pt',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ),
                    Slider(
                      value: _settings.fontSize.clamp(8.0, 24.0).toDouble(),
                      min: 8,
                      max: 24,
                      divisions: 32,
                      activeColor: const Color(0xFF00E676),
                      label: _settings.fontSize.toStringAsFixed(1),
                      onChanged: (double v) =>
                          commit(_settings.copyWith(fontSize: v)),
                    ),
                    const ListTile(
                      title: Text('اسکرول‌بک (تعداد خط)',
                          style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    Wrap(
                      spacing: 6,
                      children: <Widget>[
                        for (final int n in const <int>[
                          500,
                          1000,
                          2000,
                          5000,
                          10000
                        ])
                          ChoiceChip(
                            label: Text('$n'),
                            labelStyle: const TextStyle(color: Colors.white),
                            selected: _settings.scrollback == n,
                            onSelected: (_) =>
                                commit(_settings.copyWith(scrollback: n)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const ListTile(
                      title: Text('تم رنگی',
                          style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final TerminalThemePreset t in kTerminalThemes)
                          ChoiceChip(
                            avatar: CircleAvatar(
                              backgroundColor: Color(t.background),
                              radius: 8,
                            ),
                            label: Text(t.label),
                            labelStyle: const TextStyle(color: Colors.white),
                            selected: _settings.themeId == t.id,
                            onSelected: (_) =>
                                commit(_settings.copyWith(themeId: t.id)),
                          ),
                      ],
                    ),
                    // SOB-GPU-TOGGLE: روشن/خاموش‌کردن شتاب گرافیکی VirGL.
                    SwitchListTile(
                      value: _settings.gpuAccel,
                      // SOB-V7: این پارامتر برای SwitchListTile در
                      // Flutter >= 3.31 منسوخ شده است.
                      activeThumbColor: const Color(0xFF00E676),
                      title: const Text('شتاب گرافیکی (VirGL)',
                          style:
                              TextStyle(color: Colors.white, fontSize: 13)),
                      subtitle: const Text(
                          'رندر دسکتاپ با GPU؛ در صورت کندی/لرزش خاموش کنید',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 11)),
                      onChanged: (bool v) =>
                          commit(_settings.copyWith(gpuAccel: v)),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => commit(const TerminalSettings()),
                      child: const Text('بازگردانی پیش‌فرض',
                          style: TextStyle(color: Color(0xFF00E676))),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openMenu() async {
    final double maxH = MediaQuery.of(context).size.height * 0.85;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
              ListTile(
                leading: const Icon(Icons.add, color: Color(0xFF00E676)),
                title: const Text('ترمینال جدید',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                    'سشن فعال: ${session.displayName}  (${_manager.countFor(session.distro)}/${TerminalManager.maxSessionsPerDistro})',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addSession();
                },
              ),
              const Divider(color: Colors.white12, height: 1),
              for (var i = 0; i < _manager.sessions.length; i++)
                _sessionTile(ctx, i, setSheet),
              const Divider(color: Colors.white12, height: 1),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.redAccent),
                title: const Text('بستن ترمینال فعال',
                    style: TextStyle(color: Colors.white)),
                enabled: _manager.sessions.length > 1,
                onTap: () {
                  Navigator.pop(ctx);
                  _closeActiveSession();
                },
              ),
              const Divider(color: Colors.white12, height: 1),
              ListTile(
                leading: const Icon(Icons.tune, color: Color(0xFF00E676)),
                title: const Text('تنظیمات',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text('اندازهٔ فونت • اسکرول‌بک • تم رنگی',
                    style: TextStyle(color: Colors.white54, fontSize: 10)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSettingsSheet();
                },
              ),
              const Divider(color: Colors.white12, height: 1),
              ..._distroTiles(ctx),
              ListTile(
                leading: const Icon(Icons.cloud_download,
                    color: Color(0xFF00E676)),
                title: const Text('نصب توزیع جدید از URL',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                    'آدرس فایل rootfs: tar.gz / tar.xz / tar.bz2 / tar.zst / tar / zip',
                    style: TextStyle(color: Colors.white54, fontSize: 10)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showInstallDialog();
                },
              ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// کاشی هر سشن در منوی سه‌خط: انتخاب، تغییر نام و جابه‌جایی.
  Widget _sessionTile(BuildContext ctx, int i, StateSetter setSheet) {
    final s = _manager.sessions[i];
    final active = i == _manager.activeIndex;
    final position = '${DistroRegistry.byId(s.distro).label}  #${i + 1}';
    final custom = s.customName;
    final hasCustom = custom != null && custom.isNotEmpty;
    return ListTile(
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_off,
        color: active ? const Color(0xFF00E676) : Colors.white38,
        size: 18,
      ),
      title: Text(
        hasCustom ? custom : position,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: hasCustom
          ? Text(position,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 10))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'تغییر نام',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
            onPressed: () {
              Navigator.pop(ctx);
              _renameSession(i);
            },
          ),
          IconButton(
            tooltip: 'انتقال به بالا',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.keyboard_arrow_up,
                color: Colors.white54, size: 20),
            onPressed: i == 0
                ? null
                : () {
                    if (_moveSession(i, -1) && ctx.mounted) setSheet(() {});
                  },
          ),
          IconButton(
            tooltip: 'انتقال به پایین',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.keyboard_arrow_down,
                color: Colors.white54, size: 20),
            onPressed: i == _manager.sessions.length - 1
                ? null
                : () {
                    if (_moveSession(i, 1) && ctx.mounted) setSheet(() {});
                  },
          ),
        ],
      ),
      onTap: () {
        Navigator.pop(ctx);
        _switchSession(i);
      },
    );
  }

  /// تغییر نام نمایشی سشن [index] (رشته‌ی خالی ⇒ بازگشت به پیش‌فرض).
  Future<void> _renameSession(int index) async {
    if (index < 0 || index >= _manager.sessions.length) return;
    final s = _manager.sessions[index];
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameSessionDialog(
        initial: s.customName ?? '',
        fallback: DistroRegistry.byId(s.distro).label,
      ),
    );
    // A4: بعد از await، ویجت و سشن باید هنوز زنده باشند.
    if (!mounted || name == null || !_manager.sessions.contains(s)) return;
    s.customName = name;
    setState(() {});
  }

  /// جابه‌جایی سشن [index] به اندازه‌ی [delta]؛ true اگر انجام شد.
  bool _moveSession(int index, int delta) {
    if (!_manager.moveSession(index, index + delta)) return false;
    setState(() {});
    return true;
  }

  void _addSession() {
    _addSessionFor(session.distro);
  }

  void _switchSession(int index) {
    _manager.switchTo(index);
    setState(() {});
  }

  void _closeActiveSession() {
    if (_manager.sessions.length <= 1) return;
    final s = session;
    _releaseSession(s);
    _manager.closeActive();
    _viewKeys.remove(s.id);
    setState(() {});
  }

  void _snack(String message, {Color color = const Color(0xFF1565C0)}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(milliseconds: 1800),
      ),
    );
  }

  // #SOB-DISTRO-LINK: کاتالوگ لینک‌های دانلود را می‌خواند و در پس‌زمینه
  // نسخهٔ ریموت را تازه می‌کند (بدون بلاک کردن اجرای برنامه).
  Future<void> _initCatalog() async {
    try {
      await DistroCatalog.load();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    unawaited(DistroCatalog.refresh().then((ok) {
      if (ok && mounted) setState(() {});
    }));
  }

  /// توزیع نصب‌نشده: اگر لینک دانلود داشته باشد دیالوگ دانلود/نصب نشان
  /// می‌دهد، وگرنه به ورود دستی URL هدایت می‌کند.
  Future<void> _showNeedUrl(Distro d) async {
    final link = DistroCatalog.linkFor(d.id);
    if (link == null) {
      _snack('«${d.label}» نصب نشده — از «نصب توزیع جدید از URL» استفاده کنید');
      await _showInstallDialog();
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: Row(
          children: [
            Icon(Icons.cloud_download, color: d.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('نصب «${d.label}»',
                  style:
                      const TextStyle(color: Colors.white, fontSize: 15)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'حجم تقریبی: ${_formatBytes(link.sizeBytes)}'
              '${link.version.isEmpty ? '' : '  •  نسخه ${link.version}'}',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 10),
            const Text('لینک دانلود:',
                style: TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                link.url,
                maxLines: 4,
                style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 10,
                    fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'دانلود و نصب خودکار انجام می‌شود؛ اینترنت و دسترسی روت لازم است.',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const Text('کپی لینک',
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'manual'),
            child: const Text('ورود دستی URL',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B5E20),
            ),
            onPressed: () => Navigator.pop(ctx, 'install'),
            child: const Text('دانلود و نصب',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'install':
        await _installFromUrl(link.url, nameHint: d.id);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: link.url));
        if (mounted) _snack('لینک «${d.label}» کپی شد');
        break;
      case 'manual':
        await _showInstallDialog(initial: link.url);
        break;
    }
  }

  List<Widget> _distroTiles(BuildContext ctx) {
    final busy = _manager.sessions.map((s) => s.distro).toSet();
    // #SOB-LIST-FIXED
    // ۵ توزیع داخلی همیشه نمایش داده می‌شوند (نصب‌شده یا نه) و توزیع‌های
    // سفارشی فقط اگر واقعاً روی دیسک باشند.
    final customs = DistroRegistry.custom
        .where((d) => _installedDistros.contains(d.id))
        .toList();
    return <Distro>[...DistroRegistry.builtins, ...customs].map((d) {
      final installed = _installedDistros.contains(d.id) ||
          _preparedDistros.contains(d.id);
      final inUse = busy.contains(d.id);
      final link = installed ? null : DistroCatalog.linkFor(d.id);
      final size = _distroSizes[d.id] ?? link?.sizeBytes ?? 0;
      return ListTile(
        leading: Icon(
          installed ? Icons.check_circle : Icons.download,
          color: installed ? d.accent : Colors.white38,
          size: 20,
        ),
        title: Text(
          d.label + (installed ? '  (نصب‌شده)' : ''),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          installed
              ? '${_formatBytes(size)}  •  ${d.rootDir}'
              : (link != null
                  ? '${_formatBytes(size)}  •  ${d.rootDir}'
                  : d.rootDir),
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!installed && link != null)
              IconButton(
                icon: Icon(Icons.download_for_offline,
                    color: d.accent, size: 20),
                tooltip: 'دانلود و نصب',
                onPressed: () {
                  Navigator.pop(ctx);
                  _showNeedUrl(d);
                },
              ),
            IconButton(
              icon: Icon(Icons.desktop_windows,
                  color: installed ? d.accent : Colors.white38,
                  size: 20),
              tooltip: 'دسکتاپ',
              onPressed: () {
                Navigator.pop(ctx);
                if (installed) {
                  _openDesktop(d);
                } else {
                  _showNeedUrl(d);
                }
              },
            ),
            if (installed)
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.redAccent, size: 20),
                tooltip: inUse
                    ? 'بستن ترمینال‌های باز و حذف توزیع'
                    : 'حذف توزیع',
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmUninstall(d);
                },
              ),
          ],
        ),
        onTap: () {
          Navigator.pop(ctx);
          if (installed) {
            _addSessionFor(d.id);
          } else {
            _showNeedUrl(d);
          }
        },
      );
    }).toList();
  }

  Future<void> _confirmUninstall(Distro d) async {
    final open = _manager.sessions.where((s) => s.distro == d.id).length;
    final size = _distroSizes[d.id] ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        title: Text('حذف «${d.label}»',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
            'تمام فایل‌های این توزیع حذف می‌شود.\n'
            'فضای آزادشده: ${_formatBytes(size)}'
            '${open > 0 ? '\n\n$open ترمینال باز این توزیع بسته می‌شود.' : ''}',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(open > 0 ? 'بستن و حذف' : 'حذف',
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) await _uninstallDistro(d);
  }

  Future<void> _uninstallDistro(Distro d) async {
    _snack('در حال حذف «${d.label}»...');
    await _closeSessionsFor(d.id);
    if (_desktopReady.remove(d.id)) {
      await DesktopSession.stop();
    }
    final ok = await DistroInstaller.uninstall(d.id);
    if (!mounted) return;
    if (!ok) {
      _snack('حذف «${d.label}» ناموفق بود', color: const Color(0xFFB71C1C));
      return;
    }
    DistroRegistry.unregisterCustom(d.id);
    final saved = await DistroInstaller.persistAll();
    if (!mounted) return;
    if (!saved) {
      _snack('فهرست توزیع‌ها ذخیره نشد؛ بعد از ری‌استارت ممکن است برگردد',
          color: const Color(0xFFB71C1C));
    }
    _preparedDistros.remove(d.id);
    _distroRefs.remove(d.id);
    await _scanDistros();
    if (!mounted) return;
    _snack('«${d.label}» حذف شد', color: const Color(0xFF2E7D32));
  }

  // #SOB-UNINSTALL-UX — بستن همهٔ سشن‌های بازِ یک توزیع پیش از حذف آن.
  Future<void> _closeSessionsFor(String distroId) async {
    final doomed = _manager.sessions
        .where((s) => s.distro == distroId)
        .toList(growable: false);
    if (doomed.isEmpty) return;
    for (final s in doomed) {
      _releaseSession(s);
      _viewKeys.remove(s.id);
      _manager.sessions.remove(s);
      s.disposeSession();
    }
    if (_manager.sessions.isEmpty) {
      // TerminalManager باید همیشه حداقل یک سشن داشته باشد.
      final fallback = _manager.createSession(DistroRegistry.defaultDistro.id);
      fallback.buffer.maxScrollback = _settings.scrollback;
      _viewKeys[fallback.id] = GlobalKey<RtlTerminalViewState>();
      if (mounted) unawaited(_setupAndStartSession(fallback));
    } else if (_manager.activeIndex >= _manager.sessions.length) {
      _manager.switchTo(_manager.sessions.length - 1);
    }
    if (mounted) setState(() {});
  }

  /// آماده‌سازی (استخراج باینری‌ها + نصب XFCE) و باز کردن دسکتاپ گرافیکی [d].
  Future<void> _openDesktop(Distro d) async {
    if (_desktopReady.contains(d.id)) {
      final bool up = await DesktopSession.isFrameServerUp() &&
          await DesktopSession.isInputServerUp();
      if (up) {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DesktopView(title: d.label),
          ),
        );
        if (!await DesktopSession.isFrameServerUp()) {
          _desktopReady.remove(d.id);
        }
        return;
      }
      _desktopReady.remove(d.id);
    }
    if (!mounted) return;
    final ValueNotifier<String> status = ValueNotifier<String>('آماده‌سازی...');
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF111111),
            title: Text('دسکتاپ «${d.label}»',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, value, __) => Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF00E676)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(value,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    String fail = '';
    try {
      status.value = 'استخراج فایل‌های دسکتاپ...';
      if (!await DesktopAssets.deploy(gpuAccel: _settings.gpuAccel)) {
        fail = 'استخراج فایل‌های دسکتاپ ناموفق بود';
      } else {
        status.value = 'نصب فایل‌ها در توزیع...';
        if (!await DesktopAssets.installInto(d)) {
          fail = 'نصب فایل‌ها در توزیع ناموفق بود';
        } else {
          status.value = 'بررسی/نصب XFCE (بار اول طول می‌کشد)...';
          if (!await DesktopSession.ensureXfce(d)) {
            fail = 'نصب XFCE/Xvfb ممکن نشد (روت و اینترنت را بررسی کنید)';
          } else {
            status.value = 'راه‌اندازی دسکتاپ...';
            if (!await DesktopSession.start(
                d,
                gpuAccel: _settings.gpuAccel,
                sessionUser: _settings.username)) {
              final String tail = await DesktopSession.logTail(maxLines: 20);
              fail = tail.isEmpty
                  ? 'راه‌اندازی دسکتاپ ناموفق بود'
                  : 'راه‌اندازی دسکتاپ ناموفق بود:\n$tail';
            }
          }
        }
      }
    } catch (e) {
      fail = 'خطا: $e';
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (fail.isNotEmpty) {
      _snack(fail, color: const Color(0xFFB71C1C));
      return;
    }
    _desktopReady.add(d.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopView(title: d.label),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Future<void> _showInstallDialog({String initial = ''}) async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _InstallUrlDialog(initial: initial),
    );
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return;
    await _installFromUrl(trimmed);
  }

  Future<void> _installFromUrl(String url, {String? nameHint}) async {
    if (_installing) {
      _snack('یک نصب در حال اجراست، لطفاً صبر کنید',
          color: const Color(0xFFB71C1C));
      return;
    }
    _installing = true;
    _installStatus.value = 'در حال آماده‌سازی...';
    var dialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF111111),
            title: const Text('نصب توزیع',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            content: ValueListenableBuilder<String>(
              valueListenable: _installStatus,
              builder: (_, status, __) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  const SizedBox(height: 14),
                  Text(status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ),
        );
      },
    ).whenComplete(() => dialogOpen = false);

    DistroInstallResult result;
    try {
      result = await DistroInstaller.installFromUrl(
        url: url,
        nameHint: nameHint,
        onLog: (m) {
          if (dialogOpen && mounted) _installStatus.value = m;
        },
        onProgress: (received, total) {
          if (dialogOpen && mounted && total > 0) {
            final pct = (received * 100 / total).toStringAsFixed(0);
            _installStatus.value = 'در حال دانلود... $pct%';
          }
        },
      );
    } catch (e) {
      result = DistroInstallResult(ok: false, message: 'Install failed: $e');
    }

    // Bail out BEFORE touching anything if the State is already gone:
    // the ValueNotifier has been disposed by our dispose() in that case and
    // setting it would throw "used after being disposed".
    if (!mounted) return;
    if (dialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    _installing = false;
    _installStatus.value = '';

    if (result.ok && result.distro != null) {
      final d = result.distro!;
      await _scanDistros();
      if (!mounted) return;
      _snack('«${d.label}» نصب شد', color: const Color(0xFF2E7D32));
      _addSessionFor(d.id);
    } else {
      _snack(result.message, color: const Color(0xFFB71C1C));
    }
  }

  // #SOB-LOGIN-TPL
  // اسکریپت ورود را مستقل از init از سمت دارت می‌نویسیم؛ اگر init نیمه‌کاره
  // بماند (مثلاً apk update قطع شود) باز هم اسکریپت وجود دارد.
  Future<void> _ensureLoginScript(Distro d, String user) async {
    final String u = user.trim().isEmpty ? 'root' : user.trim();
    final String body = _loginScriptTpl
        .replaceAll('__DISTRO_DIR__', d.rootDir)
        .replaceAll('__SHELL__', d.shell)
        .replaceAll('__USER__', u);
    final String script = 'cat > ${d.loginScript} << \'SOB_LOGIN_EOF\'\n'
        '$body\n'
        'SOB_LOGIN_EOF\n'
        'chmod 755 ${d.loginScript}\n'
        'sync\n'
        'exit 0\n';
    try {
      final r = await Process.run('su', ['-c', script]);
      if (r.exitCode != 0) {
        debugPrint('[login-script] write failed: ${r.stderr}');
      }
    } catch (e) {
      debugPrint('[login-script] write error: $e');
    }
  }

  Future<void> _startDistroSession(TerminalSession s, Distro d) async {
    _distroRefs[d.id] = (_distroRefs[d.id] ?? 0) + 1;
    _releasedSessions.remove(s.id);
    // #SOB-LOGIN-TPL: تضمین وجود اسکریپت ورود پیش از اجرا.
    await _ensureLoginScript(
        d, _distroUsers[d.id] ?? _settings.username);
    s.log('\x1b[32m[+]\x1b[0m Starting ${d.label} session...\r\n');
    s.startPtySession(onExit: () => _onSessionExited(s));
    await _startForegroundService();
  }

  void _onSessionExited(TerminalSession s) {
    _releaseSession(s);
    final anyAlive = _manager.sessions.any((x) => x.isSessionStarted);
    if (!anyAlive) {
      _stopForegroundService();
    }
    if (!_manager.sessions.contains(s)) return;
    if (!mounted) return;
    if (_manager.sessions.length <= 1) {
      _showExitDialog();
    } else {
      setState(() {});
    }
  }

  void _releaseSession(TerminalSession s) {
    if (!_releasedSessions.add(s.id)) return;
    final d = DistroRegistry.byId(s.distro);
    final n = (_distroRefs[d.id] ?? 1) - 1;
    _distroRefs[d.id] = n < 0 ? 0 : n;
    if (n <= 0) {
      _releaseMount(d);
    }
  }

  // #SOB-UMOUNT-DYN
  // آنت‌مانت دینامیک (deepest-first) همهٔ موانت‌های زیر rootfs — سازگار با toybox.
  Future<void> _releaseMount(Distro d) async {
    final script = r'''
R="__ROOT__"
i=0
while [ "$i" -lt 6 ]; do
  M=$(awk -v r="$R" '$2==r || index($2, r"/")==1 {print length($2) " " $2}' /proc/self/mounts 2>/dev/null | sort -rn | cut -d' ' -f2-)
  [ -z "$M" ] && break
  for m in $M; do
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
  done
  i=$((i+1))
  sleep 1
done
exit 0
'''.replaceAll('__ROOT__', d.rootDir);
    try {
      await Process.run('su', ['-c', script]);
    } catch (_) {}
  }

  Future<void> _scanDistros() async {
    try {
      await DistroInstaller.loadPersisted();
    } catch (_) {}
    final found = await DistroInstaller.scanInstalledOrNull();
    if (!mounted) return;
    if (found == null) {
      // اسکن شکست خورد (su رد شد) — لیست را دست نزن.
      debugPrint('[scan] skipped: su unavailable');
      return;
    }
    // #SOB-PRUNE-CUSTOM
    // توزیع سفارشی‌ای که پوشه‌اش نیست از لیست حذف می‌شود؛ توزیع‌های
    // داخلی هرگز حذف نمی‌شوند (فقط «نصب‌نشده» نمایش داده می‌شوند).
    var pruned = false;
    for (final d in DistroRegistry.custom) {
      if (!found.containsKey(d.id)) {
        DistroRegistry.unregisterCustom(d.id);
        pruned = true;
      }
    }
    if (pruned) {
      try {
        await DistroInstaller.persistAll();
      } catch (_) {}
    }
    setState(() {
      _installedDistros
        ..clear()
        ..addAll(found.keys);
      _distroSizes
        ..clear()
        ..addAll(found);
    });
  }

  void _addSessionFor(String distroId) {
    if (!_manager.canAdd(distroId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('حداکثر ۵ ترمینال برای این توزیع مجاز است'),
          backgroundColor: Color(0xFFB71C1C),
          duration: Duration(milliseconds: 900),
        ),
      );
      return;
    }
    final s = _manager.createSession(distroId);
    s.buffer.maxScrollback = _settings.scrollback;
    _viewKeys[s.id] = GlobalKey<RtlTerminalViewState>();
    setState(() {});
    _setupAndStartSession(s);
  }

  Widget _toolbarButton(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: Material(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: Colors.white70),
                const SizedBox(width: 4),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final st = _terminalKey.currentState;
    final count = st?.searchHitCount ?? 0;
    final idx = st?.searchCurrentIndex ?? -1;
    final counter = _searchController.text.isEmpty
        ? ''
        : (count == 0 ? '0/0' : '${idx + 1}/$count');
    return Container(
      height: 44,
      color: const Color(0xFF141414),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.search, color: Colors.white70, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              cursorColor: const Color(0xFF00E676),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'جست‌وجو...',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _searchNext(),
            ),
          ),
          Text(counter,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up,
                color: Colors.white70, size: 20),
            onPressed: _searchPrev,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                color: Colors.white70, size: 20),
            onPressed: _searchNext,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            onPressed: _closeSearch,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildMinimalToolbar() {
    return Container(
      height: 38,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          _toolbarButton(Icons.copy, 'COPY', _copyAll),
          const SizedBox(width: 4),
          _toolbarButton(Icons.paste, 'PASTE', _pasteText),
          const SizedBox(width: 4),
          _toolbarButton(Icons.keyboard_return, 'ENTER', _sendEnter),
          const SizedBox(width: 4),
          _toolbarButton(Icons.search, 'SEARCH', _toggleSearch),
          const SizedBox(width: 4),
          _toolbarButton(Icons.keyboard, 'KEYS', _toggleKeyboard),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _manager.activeNotifier.removeListener(_onActiveChanged);
    _viewKeys.clear(); // A2
    _manager.disposeAll();
    _terminalFocusNode.dispose();
    _searchController.dispose();
    _installStatus.dispose();
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
                  padding: const EdgeInsets.symmetric(
                      vertical: 8, horizontal: 12),
                  color: Colors.red.shade900,
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'دسترسی روت برقرار نشد! لطفاً در KernelSU مجوز Superuser را تایید کنید.',
                          style:
                              TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white12,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: _setupAndStartSession,
                        child: const Text('تلاش مجدد',
                            style: TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              if (_searchVisible) _buildSearchBar(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (!_measured) _measureCells();

                    final cols = (constraints.maxWidth / _cellW)
                        .floor()
                        .clamp(20, 400)
                        .toInt();
                    final rows = (constraints.maxHeight / _cellH)
                        .floor()
                        .clamp(5, 200)
                        .toInt();

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      session.requestGrid(cols, rows);
                    });

                    // [kbfix3] دیگر روی tap کیبورد باز نمی‌شود.
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Focus(
                            focusNode: _terminalFocusNode,
                            autofocus: true,
                            onKeyEvent: _handleKey,
                            child: ValueListenableBuilder<int>(
                              valueListenable: session.lineUpdateNotifier,
                              builder: (context, _, __) {
                                return ImeBridge(
                                  key: _imeKey,
                                  onKeyEvent: _handleKey,
                                  onInput: session.sendInput,
                                  onPaste: session.pasteText,
                                  child: IndexedStack(
                                    index: _manager.activeIndex,
                                    children: [
                                      for (final s in _manager.sessions)
                                        KeyedSubtree(
                                          key: ValueKey<int>(s.id),
                                          child: RtlTerminalView(
                                            key: _viewKeys[s.id],
                                            buffer: s.buffer,
                                            theme: _theme,
                                            onInput: s.sendInput,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: _hamburgerButton(),
                        ),
                      ],
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

class _InstallUrlDialog extends StatefulWidget {
  const _InstallUrlDialog({this.initial = ''});

  final String initial;

  @override
  State<_InstallUrlDialog> createState() => _InstallUrlDialogState();
}

class _InstallUrlDialogState extends State<_InstallUrlDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initial.isNotEmpty) _controller.text = widget.initial;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111111),
      title: const Text('نصب توزیع جدید',
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'آدرس مستقیم فایل rootfs (فقط http/https). پسوندهای مجاز: '
              '.tar.gz، .tar.xz، .tar.bz2، .tar.zst، .tar، .zip',
              style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'https://example.com/kali-rootfs.tar.xz',
              hintStyle: TextStyle(color: Colors.white24, fontSize: 11),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00E676))),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف',
              style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('نصب',
              style: TextStyle(color: Color(0xFF00E676))),
        ),
      ],
    );
  }
}


// ---------------------------------------------------------------------------
// _RenameSessionDialog: دریافت نام سفارشی برای یک سشن.
// ---------------------------------------------------------------------------

class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({required this.initial, required this.fallback});

  final String initial;
  final String fallback;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initial;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111111),
      title: const Text('تغییر نام ترمینال',
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
              'نام پیش‌فرض: «${widget.fallback}»\n'
              'خالی گذاشتن ⇒ بازگشت به نام پیش‌فرض.',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 32,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'مثلاً: سرور اصلی',
              hintStyle: TextStyle(color: Colors.white24, fontSize: 12),
              counterStyle: TextStyle(color: Colors.white38, fontSize: 10),
              enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00E676))),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('انصراف', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: _submit,
          child:
              const Text('ذخیره', style: TextStyle(color: Color(0xFF00E676))),
        ),
      ],
    );
  }
}
