import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'distro.dart';
import 'distro_install.dart';

/// Deploys the pre-compiled desktop helper binaries that ship inside the APK
/// (`assets/desktop/`) onto the device and into a distro's chroot.
///
/// Only *compiled* binaries are bundled - never `.c` sources.  The old
/// Android `MethodChannel`/`LocalSocket` bridge is intentionally not used:
/// the servers listen on TCP so plain `dart:io` sockets are enough.
class DesktopAssets {
  DesktopAssets._();

  /// Neutral staging directory, owned by root, readable before being copied
  /// into a RootFS (which lives under `/data` and is only writable via `su`).
  static const String stagingDir = '/data/sobhan-desktop';

  /// Bundled filenames, in deployment order.
  static const List<String> binaries = <String>[
    'frame_server',
    'touch_server',
  ];

  // SOB-VIRGL: سرور VirGL (virtio-gpu) + کتابخانه‌های Mesa که در
  // `assets/virgl/` همراه APK می‌آیند.  جدا از باینری‌های دسکتاپ استیج
  // می‌شوند تا داخل چروت با `LD_LIBRARY_PATH` پیدا شوند.
  static const String virglStagingDir = '/data/sobhan-desktop/virgl';

  static const List<String> virglBinaries = <String>[
    'bin/virgl_test_server',
    'lib/libvirglrenderer.so',
    'lib/libepoxy.so',
  ];

  static bool _virglDeployed = false;

  static const String _virglDeployTpl = r'''
mkdir -p "__STAGE__/bin" "__STAGE__/lib" || { echo "__SOB_DEPLOY_FAIL__ mkdir"; exit 0; }
f="__NAME__"
if cat > "__STAGE__/$f"; then
  chmod 755 "__STAGE__/$f" 2>/dev/null
  SZ="$(wc -c < "__STAGE__/$f" 2>/dev/null | tr -cd '0-9')"
  echo "__SOB_FILE_OK__ $f $SZ"
else
  echo "__SOB_FILE_ERR__ $f"
fi
exit 0
''';

  /// `null` when the asset is missing from the bundle (B1).
  static Future<ByteData?> _loadAsset(String key) async {
    try {
      return await rootBundle.load(key);
    } catch (_) {
      return null;
    }
  }

  /// `true` when every [names] file still exists in [dir] (B9: the in-memory
  /// "deployed" flags go stale if the staging dir was wiped).
  static Future<bool> _stagedPresent(String dir, List<String> names) async {
    try {
      final String test = names.map((String n) => '[ -f "$dir/$n" ]').join(' && ');
      final ProcessResult r = await Process.run(
        'su',
        <String>['-c', '$test && echo __SOB_STAGED__'],
      );
      return r.stdout.toString().contains('__SOB_STAGED__');
    } catch (_) {
      return false;
    }
  }

  /// استقرار اختیاری VirGL؛ شکست آن اجرای دسکتاپ را متوقف نمی‌کند.
  static Future<bool> deployVirgl({void Function(String line)? log}) async {
    if (_virglDeployed && await _stagedPresent(virglStagingDir, virglBinaries)) {
      return true;
    }
    _virglDeployed = false;
    int ok = 0;
    for (final String name in virglBinaries) {
      final ByteData? data = await _loadAsset('assets/virgl/$name');
      if (data == null) return false;
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final String script = _virglDeployTpl
          .replaceAll('__STAGE__', virglStagingDir)
          .replaceAll('__NAME__', name);
      try {
        final Process p = await Process.start('su', <String>['-c', script]);
        p.stdin.add(bytes);
        await p.stdin.flush();
        await p.stdin.close();
        final Future<String> outF = p.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final Future<void> errF = p.stderr.drain<void>();
        final String out = await outF;
        await errF;
        await p.exitCode;
        log?.call(out.trim());
        if (out.contains('__SOB_FILE_OK__ $name ${bytes.length}')) ok++;
      } catch (_) {
        // Counted as a failure: the caller gets an honest `false`.
      }
    }
    if (ok == virglBinaries.length) {
      _virglDeployed = true;
      return true;
    }
    return false;
  }

  static const String _deployTpl = r'''
mkdir -p "__STAGE__" || { echo "__SOB_DEPLOY_FAIL__ mkdir"; exit 0; }
f="__NAME__"
if cat > "__STAGE__/$f"; then
  chmod 755 "__STAGE__/$f" 2>/dev/null
  SZ="$(wc -c < "__STAGE__/$f" 2>/dev/null | tr -cd '0-9')"
  echo "__SOB_FILE_OK__ $f $SZ"
else
  echo "__SOB_FILE_ERR__ $f"
fi
exit 0
''';

  /// Streams the bundled binaries into [stagingDir] (mode 755).
  ///
  /// The asset bytes are piped straight into `cat` through the `su` process'
  /// stdin instead of being written to the app's temporary directory first:
  /// that sandbox path is not reliably readable by root (SELinux, `07xx`
  /// parent directories), and when the copy silently failed the previous
  /// revision still reported success.  Each file is verified with `wc -c`.
  static bool _deployed = false;

  static Future<bool> deploy({
    void Function(String line)? log,
    bool gpuAccel = true,
  }) async {
    // SOB-GPU-TOGGLE: مسیر سریع هم باید وضعیت VirGL را دوباره اعمال کند،
    // وگرنه خاموش‌کردن و سپس روشن‌کردنِ شتاب بی‌اثر می‌ماند.
    if (_deployed && await _stagedPresent(stagingDir, binaries)) {
      if (gpuAccel) await deployVirgl(log: log);
      return true;
    }
    _deployed = false;
    int ok = 0;
    for (final String name in binaries) {
      final ByteData? data = await _loadAsset('assets/desktop/$name');
      if (data == null) return false;
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final String script = _deployTpl
          .replaceAll('__STAGE__', stagingDir)
          .replaceAll('__NAME__', name);
      try {
        final Process p = await Process.start('su', <String>['-c', script]);
        p.stdin.add(bytes);
        await p.stdin.flush();
        await p.stdin.close();
        final Future<String> outF = p.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final Future<void> errF = p.stderr.drain<void>();
        final String out = await outF;
        await errF;
        await p.exitCode;
        log?.call(out.trim());
        if (out.contains('__SOB_FILE_OK__ $name ${bytes.length}')) ok++;
      } catch (_) {
        // Counted as a failure: the caller gets an honest `false`.
      }
    }
    if (ok != binaries.length) return false;
    _deployed = true;
    // SOB-VIRGL: فایل‌های VirGL هم استیج می‌شوند؛ خطا نادیده گرفته
    // می‌شود تا نبود GPU باعث از کار افتادن دسکتاپ نشود.
    if (gpuAccel) await deployVirgl(log: log);
    return true;
  }

  static const String _installTpl = r'''
BIN="__ROOT__/usr/local/bin"
mkdir -p "$BIN" || { echo "__SOB_INSTALL_FAIL__ mkdir"; exit 0; }
fail=0
for f in __FILES__; do
  SRC="__STAGE__/$f"
  if [ ! -f "$SRC" ]; then
    echo "__SOB_INSTALL_ERR__ $f missing-source"
    fail=1
    continue
  fi
  rm -f "$BIN/$f" 2>/dev/null
  if cp "$SRC" "$BIN/$f"; then
    chmod 755 "$BIN/$f" 2>/dev/null
    A="$(wc -c < "$SRC" 2>/dev/null | tr -cd '0-9')"
    B="$(wc -c < "$BIN/$f" 2>/dev/null | tr -cd '0-9')"
    if [ "$A" = "$B" ]; then
      echo "__SOB_INSTALL_FILE__ $f $B"
    else
      echo "__SOB_INSTALL_ERR__ $f size $A!=$B"
      fail=1
    fi
  else
    echo "__SOB_INSTALL_ERR__ $f copy-failed"
    fail=1
  fi
done
if [ $fail -eq 0 ]; then echo "__SOB_INSTALL_OK__"; else echo "__SOB_INSTALL_FAIL__"; fi
exit 0
''';

  /// Copies the staged binaries into `<rootDir>/usr/local/bin/` of [distro].
  ///
  /// The previous revision echoed `__SOB_INSTALL_OK__` unconditionally, so a
  /// failed `cp` (which left the stale servers on the old ports running) was
  /// reported as success.  Now every file is size-checked and the marker is
  /// only emitted when all of them match.
  static Future<bool> installInto(
    Distro distro, {
    void Function(String line)? log,
  }) async {
    // The size each binary must have once installed - read back from the
    // bundled asset, so a truncated/corrupted copy cannot pass unnoticed.
    final List<String> expect = <String>[];
    for (final String name in binaries) {
      final ByteData? data = await _loadAsset('assets/desktop/$name');
      if (data == null) return false;
      expect.add('__SOB_INSTALL_FILE__ $name ${data.lengthInBytes}');
    }
    final String script = _installTpl
        .replaceAll(
          '__ROOT__',
          DistroDetector.escapeShellDoubleQuoted(distro.rootDir),
        )
        .replaceAll('__STAGE__', stagingDir)
        .replaceAll('__FILES__', binaries.join(' '));
    try {
      final ProcessResult r = await Process.run('su', <String>['-c', script]);
      final String out = r.stdout.toString();
      log?.call(out.trim());
      if (!out.contains('__SOB_INSTALL_OK__')) return false;
      for (final String needle in expect) {
        if (!out.contains(needle)) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Drives the Xvfb + XFCE + frame/touch server stack inside a distro chroot,
/// with an SoC-aware GPU environment injected by [gpuEnv].
class DesktopSession {
  DesktopSession._();

  static const String _androidRunInstaller = r'''
R="__ROOT__"
[ -d "$R" ] || exit 0
mkdir -p "$R/usr/local/bin" "$R/tmp/.X11-unix" "$R/tmp/.virgl_test" "$R/tmp/xvfb_99" "$R/dev/socket/virgl"; chmod 1777 "$R/tmp/.X11-unix" "$R/tmp/.virgl_test"; chmod 1777 "$R/tmp/xvfb_99" 2>/dev/null || true
for d in /proc/[0-9]*; do
 [ -r "$d/cmdline" ] || continue
 case "$(tr '\000' ' ' <"$d/cmdline" 2>/dev/null)" in *seamless-bridge.py*) kill -9 "${d#/proc/}" 2>/dev/null ;; esac
done
sleep 0.2
cat > "$R/usr/local/bin/.seamless-bridge.py.new" <<'PY_EOF'
#!/usr/bin/python3
import os,socket,threading,struct,time,subprocess,ctypes
FB='/tmp/xvfb_99/Xvfb_screen0'; clients=set(); lock=threading.Lock()
try:
 from PIL import Image
 HAVE_PIL=True
except Exception: HAVE_PIL=False
def frame():
 try:
  data=open(FB,'rb').read(); hsize=struct.unpack('>I',data[:4])[0]; w=struct.unpack('>I',data[16:20])[0]; h=struct.unpack('>I',data[20:24])[0]; bpp=struct.unpack('>I',data[44:48])[0]; stride=struct.unpack('>I',data[48:52])[0]; nc=struct.unpack('>I',data[76:80])[0]; off=hsize+nc*12
  if not (0<w<=8192 and 0<h<=8192 and bpp==32 and stride>=w*4 and off+stride*h<=len(data)):return None
  raw=b''.join(data[off+y*stride:off+y*stride+w*4] for y in range(h))
  if HAVE_PIL:
   import io
   im=Image.frombytes('RGB',(w,h),raw,'raw','BGRX'); o=io.BytesIO(); im.save(o,'JPEG',quality=70); return o.getvalue()
  pix=raw; size=len(pix)+54
  return b'BM'+struct.pack('<IHHI',size,0,0,54)+struct.pack('<IiiHHIIiiII',40,w,-h,1,32,0,len(pix),2835,2835,0,0)+pix
 except Exception:return None
def frames():
 last=None; sent=0
 while True:
  b=frame(); now=time.monotonic()
  if b and (b!=last or now-sent>=.5):
   pkt=struct.pack('>I',len(b))+b
   with lock: cs=list(clients)
   for c in cs:
    try:c.sendall(pkt)
    except Exception:
     with lock:clients.discard(c)
     try:c.close()
     except Exception:pass
   last=b;sent=now
  time.sleep(.04)
def frameserver():
 s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',48001));s.listen(32)
 while True:
  c,_=s.accept();c.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
  with lock:clients.add(c)
def screen_size():
 try:
  d=open(FB,'rb').read(24)
  return struct.unpack('>I',d[16:20])[0],struct.unpack('>I',d[20:24])[0]
 except Exception: return 720,1600
def action(line):
 a=line.strip().split()
 if not a:return
 cmd=a[0].upper()
 try:
  env=dict(os.environ,DISPLAY=':99')
  if cmd in ('DOWN','MOVE','UP') and len(a)>=3:
   fx=float(a[1]);fy=float(a[2])
   if 0.0 <= fx <= 1.0 and 0.0 <= fy <= 1.0:
    sw,sh=screen_size()
    x=round(fx*sw);y=round(fy*sh)
   else:
    x=round(fx);y=round(fy)
   subprocess.run(['xdotool','mousemove',str(x),str(y)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   if cmd=='DOWN':subprocess.run(['xdotool','mousedown',a[3] if len(a)>3 else '1'],env=env)
   if cmd=='UP':subprocess.run(['xdotool','mouseup',a[3] if len(a)>3 else '1'],env=env)
  elif cmd=='KEY':subprocess.run(['xdotool','key',' '.join(a[1:])],env=env)
  elif cmd in ('TEXT','TYPE'):subprocess.run(['xdotool','type','--clearmodifiers','--',' '.join(a[1:])],env=env)
  elif cmd=='SCROLL' and len(a)>1:
   n=int(float(a[-1]));subprocess.run(['xdotool','click','--repeat',str(max(1,min(30,abs(n)))),'4' if n>0 else '5'],env=env)
 except Exception:pass
def inputs(c):
 try:
  f=c.makefile('r',encoding='utf8',errors='replace')
  for line in f:action(line)
 finally:c.close()
def inputserver():
 s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',48002));s.listen(32)
 while True:
  c,_=s.accept();threading.Thread(target=inputs,args=(c,),daemon=True).start()
threading.Thread(target=frames,daemon=True).start();threading.Thread(target=frameserver,daemon=True).start();inputserver()

PY_EOF
mv -f "$R/usr/local/bin/.seamless-bridge.py.new" "$R/usr/local/bin/seamless-bridge.py"; chmod 755 "$R/usr/local/bin/seamless-bridge.py"
cat > "$R/usr/local/bin/.seamless-start.new" <<'START_EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LOG=/tmp/seamless-start.log
echo "--- $(date +%H:%M:%S) seamless-start ---" >>"$LOG"
mkdir -p /tmp/.X11-unix /tmp/xvfb_99; chmod 1777 /tmp/xvfb_99 2>/dev/null || true
port_ok(){ python3 -c 'import socket;s=socket.create_connection(("127.0.0.1",48001),0.3);s.close()' >/dev/null 2>&1; }
live99(){ [ -r /tmp/.X99-lock ] || return 1; p=$(tr -cd '0-9' </tmp/.X99-lock); [ -r /proc/$p/cmdline ] || return 1; tr '\000' ' ' </proc/$p/cmdline | grep -E 'Xvfb.*:99' >/dev/null 2>&1; }
res_ok(){ python3 -c 'import struct,sys
try:
 d=open("/tmp/xvfb_99/Xvfb_screen0","rb").read(24)
 w=struct.unpack(">I",d[16:20])[0];h=struct.unpack(">I",d[20:24])[0]
 sys.exit(0 if (w,h)==(720,1600) else 1)
except Exception: sys.exit(1)'; }
if live99 && ! res_ok; then
 echo "Xvfb :99 wrong size -> restart" >>"$LOG"
 for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  case "$(tr '\000' ' ' <"$d/cmdline" 2>/dev/null)" in *"Xvfb :99"*) kill -9 "${d#/proc/}" 2>/dev/null ;; esac
 done
 sleep .3
 rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 /tmp/xvfb_99/Xvfb_screen0
fi
if ! live99; then
 echo "start Xvfb :99 720x1600" >>"$LOG"
 rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 /tmp/xvfb_99/Xvfb_screen0
 Xvfb :99 -screen 0 720x1600x24 -fbdir /tmp/xvfb_99 -ac +extension GLX +render -noreset >/tmp/seamless-xvfb.log 2>&1 &
 for i in $(seq 1 60); do live99 && break; sleep .1; done
fi
live99 && echo "Xvfb ok" >>"$LOG" || echo "Xvfb FAILED" >>"$LOG"
ob=0
for d in /proc/[0-9]*; do
 [ -r "$d/cmdline" ] || continue
 case "$(tr '\000' ' ' <"$d/cmdline" 2>/dev/null)" in *openbox*) ob=1 ;; esac
done
if [ "$ob" = 0 ]; then echo "start openbox" >>"$LOG"; DISPLAY=:99 openbox >/tmp/seamless-openbox.log 2>&1 & sleep .5; fi
if ! port_ok; then
 echo "start bridge 48001" >>"$LOG"
 for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  c=$(tr '\000' ' ' <"$d/cmdline" 2>/dev/null)
  case "$c" in
   *seamless-bridge.py*)
    case "$c" in *--display*) ;; *) p=${d#/proc/}; echo "kill stale bridge $p" >>"$LOG"; kill -9 "$p" 2>/dev/null ;; esac ;;
  esac
 done
 sleep .3
 /usr/local/bin/seamless-bridge.py >>/tmp/seamless-bridge.log 2>&1 &
 bp=$!
 i=0
 while [ $i -lt 60 ]; do port_ok && break; kill -0 $bp 2>/dev/null || break; sleep .1; i=$((i+1)); done
fi
if port_ok; then echo "port48001=1" >>"$LOG"; else echo "port48001=0" >>"$LOG"; fi
exit 0
START_EOF
mv -f "$R/usr/local/bin/.seamless-start.new" "$R/usr/local/bin/seamless-start"; chmod 755 "$R/usr/local/bin/seamless-start"
cat > "$R/usr/local/bin/.android-run.new" <<'RUN_EOF'
#!/usr/bin/python3
import os,sys,subprocess
args=sys.argv[1:]
if not args: print('Usage: android-run <command> [args...]',file=sys.stderr);sys.exit(2)
os.environ.update(DISPLAY=':99',GDK_BACKEND='x11',QT_QPA_PLATFORM='xcb',MOZ_ENABLE_WAYLAND='0',NO_AT_BRIDGE='1',XDG_RUNTIME_DIR='/tmp/runtime-'+str(os.getuid()))
# مسیرهای غیراستاندارد برنامه‌ها را به PATH اضافه کن (وگرنه «code: command not found»).
for _p in ('/usr/share/code','/usr/share/code/bin','/opt/visual-studio-code/bin','/opt/google/chrome','/usr/lib/chromium','/snap/bin'):
 if os.path.isdir(_p) and _p not in os.environ.get('PATH','').split(':'):os.environ['PATH']=_p+':'+os.environ.get('PATH','')
os.makedirs(os.environ['XDG_RUNTIME_DIR'],exist_ok=True);os.chmod(os.environ['XDG_RUNTIME_DIR'],0o700)
subprocess.run(['/usr/local/bin/seamless-start'])
app=os.path.basename(args[0])
if app=='xfce4-terminal':
 args=[a for a in args if a!='--disable-session-manager']
 if '--disable-server' not in args:args.append('--disable-server')
if app in {'google-chrome','google-chrome-stable','chromium','chromium-browser','brave-browser','microsoft-edge','code','electron'}:
 # پروفایل کاربری مجزا: بدون آن کروم/الکترون با کاربر root بالا نمی‌آید.
 _prof='/tmp/linux-app-profile-99'
 os.makedirs(_prof,exist_ok=True)
 if not any(a.startswith('--user-data-dir') for a in args):args+=['--user-data-dir='+_prof]
 args+=['--window-size=720,1600','--window-position=0,0','--start-maximized','--no-first-run','--no-default-browser-check']
 if '--no-sandbox' not in args:args+=['--no-sandbox','--disable-dev-shm-usage','--disable-gpu']
with open('/tmp/seamless_debug.log','a') as f:subprocess.Popen(args,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)

RUN_EOF
mv -f "$R/usr/local/bin/.android-run.new" "$R/usr/local/bin/android-run"; chmod 755 "$R/usr/local/bin/android-run"
for f in android-run seamless-start seamless-bridge.py; do chmod 755 "$R/usr/local/bin/$f"; done
if [ -n "${rootfs:-}" ] && [ "$rootfs" != "$R" ]; then mkdir -p "$rootfs/usr/local/bin"; for f in android-run seamless-start seamless-bridge.py; do cp -f "$R/usr/local/bin/$f" "$rootfs/usr/local/bin/$f"; chmod 755 "$rootfs/usr/local/bin/$f"; done; fi
''';
  /// نسخهٔ نصب‌کننده. اگر محتوای اسکریپت‌های بالا عوض شد این رشته را هم عوض کن.
  static const String installerVersion = 'seamless-20250603';

  /// مسیر نشانگر نسخه داخل chroot (فقط برای گارد شل).
  static const String _versionMarker = '/usr/local/bin/.seamless-version';

  static Future<void>? _installInFlight;

  /// نصب را فقط یک بار انجام می‌دهد.
  ///
  /// قبلاً این تابع در هر بار اجرا (launchApp / openDisplayWindow / refresh)
  /// کل اسکریپت را داخل chroot می‌نوشت و اسکن /proc می‌کرد؛ روی گوشی
  /// ۸ تا ۲۶ ثانیه طول می‌کشید و همان تاخیر شروع برنامه‌ها بود.
  static Future<void> installAndroidRun(Distro distro) {
    final Future<void>? running = _installInFlight;
    if (running != null) return running;
    final Future<void> job = _installAndroidRunOnce(distro);
    _installInFlight = job;
    return job.whenComplete(() { _installInFlight = null; });
  }

  /// مسیر نشانگر نسخه در فضای فایل خودِ اپ (همیشه خواندنی، بدون su).
  ///
  /// نشانگر را داخل chroot نمی‌گذاریم چون `/data/ubuntu` مالک root با حالت
  /// 755 است و اپ اجازهٔ خواندن/نوشتن آن را ندارد؛ در آن حالت «مسیر سریع»
  /// هیچ‌وقت کار نمی‌کرد و هر بار کل نصب تکرار می‌شد.
  static Future<File?> _versionMarkerFile() async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      return File('${dir.path}/seamless-version');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _installAndroidRunOnce(Distro distro) async {
    final String root = DistroDetector.escapeShellDoubleQuoted(distro.rootDir);
    final File? marker = await _versionMarkerFile();

    // مسیر سریع و بدون su: اگر نسخهٔ نصب‌شده همان نسخهٔ فعلی است، تمام.
    if (marker != null) {
      try {
        if (await marker.exists() &&
            (await marker.readAsString()).trim() == installerVersion) {
          return;
        }
      } catch (_) { }
    }

    final String script = r'''
R="__ROOT__"
VER="__VER__"
M="$R__MARKER__"
[ -d "$R" ] || exit 0
if [ -x "$R/usr/local/bin/android-run" ] && [ -x "$R/usr/local/bin/seamless-start" ] && [ -x "$R/usr/local/bin/seamless-bridge.py" ] && [ "$(cat "$M" 2>/dev/null)" = "$VER" ]; then
  exit 0
fi
''' + _androidRunInstaller.replaceAll('__ROOT__', root) + r'''
printf '%s\n' "$VER" > "$M"
chmod 644 "$M" 2>/dev/null || true
''';

    final String full = script
        .replaceAll('__MARKER__', _versionMarker)
        .replaceAll('__VER__', installerVersion);
    try {
      final ProcessResult r = await Process.run('su', <String>['-c', full]);
      if (r.exitCode == 0 && marker != null) {
        try { await marker.writeAsString(installerVersion, flush: true); } catch (_) { }
      }
    } catch (_) { }
  }

  /// JPEG frame stream produced by `frame_server`.
  static const int framePort = 6000;

  /// Touch/keyboard event sink served by `touch_server`.
  static const int inputPort = 6001;

  /// Logical resolution used by both the servers and the Flutter client.
  static const int defaultWidth = 900;
  static const int defaultHeight = 2000;

  /// Where the background desktop log is written.
  static const String logFile = '/data/sobhan-desktop/desktop.log';

  /// Written by the desktop logout shim (`xfce4-session-logout`).
  ///
  /// Its presence means the user asked for "Shut Down": the desktop session
  /// stack must be stopped and the Flutter desktop view popped.
  static const String shutdownFlagFile = '/data/sobhan-desktop/shutdown.flag';

  /// True when the desktop shim requested a shutdown.
  static Future<bool> isShutdownRequested() async {
    try {
      final ProcessResult r = await Process.run(
        'su',
        <String>['-c', '[ -f "$shutdownFlagFile" ] && echo 1 || echo 0'],
      );
      return r.stdout.toString().trim() == '1';
    } catch (_) {
      return false;
    }
  }

  /// Removes the shutdown flag so the next desktop start is clean.
  static Future<void> clearShutdownFlag() async {
    try {
      await Process.run('su', <String>['-c', 'rm -f "$shutdownFlagFile"']);
    } catch (_) {
      // Ignore: the flag is only an advisory IPC marker.
    }
  }

  /// Packages needed by Xvfb + XFCE + dbus plus the helper binaries' deps.
  /// Debian/Ubuntu naming (kept for backwards compatibility).
  static const List<String> xfcePackages = <String>[
    'xvfb',
    'xserver-xorg-core',
    'xserver-xorg-video-fbdev',
    'libgl1-mesa-dri',
    'libglx-mesa0',
    'libegl1',
    'libgbm1',
    'libepoxy0',
    'mesa-utils',
    'xfce4',
    'dbus-x11',
    'libturbojpeg0',
    'libxdamage1',
    'libxext6',
    'libx11-6',
    'libxtst6',
    'x11-utils',
    'x11-xserver-utils',
    'zenity',
    'procps',
    'pulseaudio',
    'pulseaudio-utils',
    'libasound2-plugins',
    'alsa-utils',
  ];

  /// Fedora / RHEL / CentOS / Rocky / Alma (dnf or yum).
  static const List<String> xfcePackagesRpm = <String>[
    'xorg-x11-server-Xvfb',
    'mesa-dri-drivers',
    'mesa-libGL',
    'mesa-libEGL',
    'mesa-libgbm',
    'libepoxy',
    'xfce4-session',
    'xfce4-panel',
    'xfce4-settings',
    'xfwm4',
    'xfdesktop',
    'xfce4-terminal',
    'dbus-x11',
    'turbojpeg',
    'libXdamage',
    'libXext',
    'libX11',
    'libXtst',
    'xorg-x11-utils',
    'xorg-x11-apps',
    'zenity',
    'procps-ng',
    'pulseaudio',
    'pulseaudio-utils',
    'alsa-utils',
    'alsa-plugins-pulseaudio',
  ];

  /// Alpine (apk).
  static const List<String> xfcePackagesApk = <String>[
    'xvfb',
    'mesa-dri-gallium',
    'mesa-gl',
    'mesa-egl',
    'mesa-gbm',
    'libepoxy',
    'xfce4',
    'xfce4-terminal',
    'dbus-x11',
    'libjpeg-turbo',
    'libxdamage',
    'libxext',
    'libx11',
    'libxtst',
    'xsetroot',
    'xwininfo',
    'zenity',
    'procps',
    'pulseaudio',
    'pulseaudio-utils',
    'alsa-utils',
    'alsa-plugins-pulse',
    'bash',
  ];

  /// Arch / Manjaro / BlackArch (pacman).
  static const List<String> xfcePackagesPacman = <String>[
    'xorg-server-xvfb',
    'mesa',
    'libglvnd',
    'libepoxy',
    'xfce4',
    'xfce4-terminal',
    'dbus',
    'libjpeg-turbo',
    'libxdamage',
    'libxext',
    'libx11',
    'libxtst',
    'xorg-xsetroot',
    'xorg-xwininfo',
    'zenity',
    'procps-ng',
    'pulseaudio',
    'alsa-utils',
    'alsa-plugins',
    'bash',
  ];

  /// openSUSE (zypper).
  static const List<String> xfcePackagesZypper = <String>[
    'xorg-x11-server',
    'xfce4-session',
    'xfce4-panel',
    'xfce4-settings',
    'xfwm4',
    'xfdesktop',
    'xfce4-terminal',
    'dbus-1-x11',
    'libjpeg8',
    'libXdamage1',
    'libXext6',
    'libX11-6',
    'libXtst6',
    'xorg-x11-utils',
    'xorg-x11',
    'zenity',
    'procps',
    'pulseaudio',
    'alsa-utils',
    'bash',
  ];

  static const String _ensureTpl = r"""
R="__ROOT__"
have() { [ -x "$R/usr/bin/$1" ] || [ -x "$R/usr/sbin/$1" ] || [ -x "$R/bin/$1" ] || [ -x "$R/sbin/$1" ]; }
pkgmgr() {
  if [ -x "$R/usr/bin/apt-get" ] || [ -x "$R/bin/apt-get" ]; then echo apt; return; fi
  if [ -x "$R/usr/bin/dnf" ] || [ -x "$R/bin/dnf" ]; then echo dnf; return; fi
  if [ -x "$R/usr/bin/yum" ]; then echo yum; return; fi
  if [ -x "$R/usr/bin/pacman" ] || [ -x "$R/bin/pacman" ]; then echo pacman; return; fi
  if [ -x "$R/usr/bin/zypper" ]; then echo zypper; return; fi
  if [ -x "$R/sbin/apk" ]; then echo apk; return; fi
  if [ -x "$R/usr/bin/apk" ]; then echo apk; return; fi
  echo none
}
PM=$(pkgmgr)
if [ "$PM" = "none" ]; then
  echo "__SOB_XFCE_NOAPT__"
  exit 0
fi
echo "__SOB_XFCE_PM__=$PM"

# DNS لازم است تا نصب آنلاین کار کند.
rm -f "$R/etc/resolv.conf" 2>/dev/null
mkdir -p "$R/etc" 2>/dev/null
{
  echo "nameserver 8.8.8.8"
  echo "nameserver 8.8.4.4"
  echo "nameserver 1.1.1.1"
  echo "options edns0 timeout:5 attempts:2"
} > "$R/etc/resolv.conf" 2>/dev/null
chmod 644 "$R/etc/resolv.conf" 2>/dev/null

# bind mountهای لازم برای اسکریپت‌های post-install
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/tmp" 2>/dev/null
chmod 1777 "$R/tmp" 2>/dev/null
BOUND=""
for m in dev proc sys; do
  if ! mountpoint -q "$R/$m" 2>/dev/null; then
    mount --bind "/$m" "$R/$m" 2>/dev/null && BOUND="$BOUND $m"
  fi
done
cleanup_mounts() {
  for m in $BOUND; do umount -l "$R/$m" 2>/dev/null; done
}
trap cleanup_mounts EXIT

if have Xvfb && have xfce4-session && have dbus-launch && have dbus-daemon && have xsetroot && have pulseaudio; then
  echo "__SOB_XFCE_PRESENT__"
  exit 0
fi
echo "__SOB_XFCE_NEEDED__"

run_in() {
  chroot "$R" /bin/sh -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export HOME=/root; export DEBIAN_FRONTEND=noninteractive; $1"
}

PKGS="__PKGS__"
MIN="__MINPKGS__"
case "$PM" in
  apt)
    run_in "apt-get update" >/dev/null 2>&1
    run_in "apt-get install -y --no-install-recommends $PKGS"
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "__SOB_XFCE_RETRY__=minimal"
      run_in "apt-get install -y --no-install-recommends $MIN"
      RC=$?
    fi
    ;;
  dnf|yum)
    run_in "$PM install -y $PKGS"
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "__SOB_XFCE_RETRY__=minimal"
      run_in "$PM install -y $MIN"
      RC=$?
    fi
    ;;
  pacman)
    run_in "pacman -Sy --noconfirm --needed $PKGS"
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "__SOB_XFCE_RETRY__=minimal"
      run_in "pacman -Sy --noconfirm --needed $MIN"
      RC=$?
    fi
    ;;
  zypper)
    run_in "zypper --non-interactive --gpg-auto-import-keys refresh" >/dev/null 2>&1
    run_in "zypper --non-interactive install --no-recommends $PKGS"
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "__SOB_XFCE_RETRY__=minimal"
      run_in "zypper --non-interactive install --no-recommends $MIN"
      RC=$?
    fi
    ;;
  apk)
    run_in "apk update" >/dev/null 2>&1
    run_in "apk add --no-cache $PKGS"
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "__SOB_XFCE_RETRY__=minimal"
      run_in "apk add --no-cache $MIN"
      RC=$?
    fi
    ;;
  *)
    RC=1
    ;;
esac

if [ $RC -eq 0 ]; then echo "__SOB_XFCE_OK__"; else echo "__SOB_XFCE_FAIL__"; fi
exit 0
""";

  /// Minimal fallback sets (used when the full list fails on a distro).
  static const List<String> _minDeb = <String>[
    'xvfb',
    'xfce4',
    'dbus-x11',
    'x11-xserver-utils',
    'pulseaudio',
  ];
  static const List<String> _minRpm = <String>[
    'xorg-x11-server-Xvfb',
    'xfce4-session',
    'xfce4-panel',
    'xfwm4',
    'dbus-x11',
    'xorg-x11-apps',
    'pulseaudio',
  ];
  static const List<String> _minApk = <String>[
    'xvfb',
    'xfce4',
    'dbus-x11',
    'xsetroot',
    'pulseaudio',
  ];
  static const List<String> _minPacman = <String>[
    'xorg-server-xvfb',
    'xfce4',
    'dbus',
    'xorg-xsetroot',
    'pulseaudio',
  ];
  static const List<String> _minZypper = <String>[
    'xorg-x11-server',
    'xfce4-session',
    'xfce4-panel',
    'xfwm4',
    'dbus-1-x11',
    'pulseaudio',
  ];

  /// Installs Xvfb/XFCE/dbus on demand (only on the first desktop launch).
  /// Works on apt, dnf/yum, pacman, zypper and apk based distros.
  /// Returns `true` when everything is available.
  static Future<bool> ensureXfce(
    Distro distro, {
    void Function(String line)? log,
  }) async {
    await installAndroidRun(distro);
    // #SOB-NET-SETUP: قبل از نصب آنلاین، DNS داخل توزیع ست می‌شود.
    await DistroInstaller.repairDistro(distro);
    await DistroInstaller.setupNetwork(distro.rootDir);
    // #SOB-XFCE-MULTI: بسته‌ها بر اساس خانوادهٔ توزیع انتخاب می‌شوند.
    final List<String> pkgs;
    final List<String> minPkgs;
    switch (distro.family) {
      case DistroFamily.redhat:
        pkgs = xfcePackagesRpm;
        minPkgs = _minRpm;
        break;
      case DistroFamily.alpine:
        pkgs = xfcePackagesApk;
        minPkgs = _minApk;
        break;
      case DistroFamily.arch:
        pkgs = xfcePackagesPacman;
        minPkgs = _minPacman;
        break;
      case DistroFamily.suse:
        pkgs = xfcePackagesZypper;
        minPkgs = _minZypper;
        break;
      default:
        pkgs = xfcePackages;
        minPkgs = _minDeb;
    }
    final String script = _ensureTpl
        .replaceAll(
          '__ROOT__',
          DistroDetector.escapeShellDoubleQuoted(distro.rootDir),
        )
        .replaceAll('__PKGS__', pkgs.join(' '))
        .replaceAll('__MINPKGS__', minPkgs.join(' '));
    try {
      final ProcessResult r = await Process.run('su', <String>['-c', script]);
      final String out = '${r.stdout}\n${r.stderr}';
      if (log != null) {
        for (final String line in out.split('\n')) {
          if (line.trim().isNotEmpty) log(line);
        }
      }
      return out.contains('__SOB_XFCE_OK__') ||
          out.contains('__SOB_XFCE_PRESENT__');
    } catch (_) {
      return false;
    }
  }

  static const String _startTpl = r'''
R="__ROOT__"
BIN="$R/usr/local/bin"
mkdir -p "$BIN"
# #SOB-GUEST-SHELL: پوستهٔ واقعیِ موجود در روت‌اف‌اس (آلپاین bash ندارد).
# اسکریپت‌های مهمان با این پوسته اجرا/نوشته می‌شوند، نه با bashِ ثابت.
GSHELL=/bin/sh
for _s in bin/bash usr/bin/bash bin/ash usr/bin/ash bin/sh usr/bin/sh; do
  if [ -x "$R/$_s" ]; then GSHELL="/$_s"; break; fi
done
cat << 'SD_EOF' > "$BIN/start_desktop"
#!/bin/bash
export DISPLAY=:0
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TMPDIR=/tmp
chmod 1777 /tmp 2>/dev/null || true
export XDG_RUNTIME_DIR=/tmp/runtime-$(id -u)
export XDG_CACHE_HOME=/tmp/.cache
export XDG_CONFIG_HOME=/root/.config
export XDG_DATA_HOME=/root/.local/share
export XDG_CONFIG_DIRS=/etc/xdg
export XDG_DATA_DIRS=/usr/local/share:/usr/share
export LANG=C.UTF-8
export USER=root
# #SOB-GUEST-SHELL: داخلِ مهمان هم پوسته را تشخیص می‌دهیم تا روی
# توزیع‌های بدونِ bash (آلپاین) دسکتاپ بالا بیاید.
if [ -x /bin/bash ]; then SHELL_BIN=/bin/bash
elif [ -x /usr/bin/bash ]; then SHELL_BIN=/usr/bin/bash
elif [ -x /bin/ash ]; then SHELL_BIN=/bin/ash
elif [ -x /usr/bin/ash ]; then SHELL_BIN=/usr/bin/ash
else SHELL_BIN=/bin/sh; fi
export SHELL="$SHELL_BIN"
mkdir -p /tmp/runtime-$(id -u) /tmp/.cache /root/.config /root/.local/share 2>/dev/null
chmod 700 /tmp/runtime-$(id -u) 2>/dev/null || true

# SOB-DESK-CLEAN-DBUS: socket/pid کهنهٔ dbus-daemon با مالکِ root باقی
# می‌ماند و کاربرِ بعدی نمی‌تواند از آن استفاده کند.
rm -rf /tmp/runtime-$(id -u)/dbus-1 2>/dev/null
__GPU__
# SOB-V9-VIRGL-GATE: فقط وقتی virpipe را انتخاب می‌کنیم که هم سوکت دیده
# شود و هم هاست «تأییدِ زنده‌بودنِ سرور» (virgl.ok) را نوشته باشد. سوکتِ
# کهنه/مرده = virpipeِ خراب = مرگِ Xvfb/frame_server.
if [ "__VIRGL__" = "1" ] && [ -S /tmp/sobhan-desktop/virgl.sock ] && [ -f /tmp/sobhan-desktop/virgl.ok ]; then
  export GALLIUM_DRIVER=virpipe
  export VIRGL_SERVER_PATH=/tmp/sobhan-desktop/virgl.sock
  unset MESA_LOADER_DRIVER_OVERRIDE 2>/dev/null
  unset LIBGL_ALWAYS_SOFTWARE 2>/dev/null
  echo "__SOB_PHASE__ render=virpipe" >> /tmp/sobhan-desktop/start.log 2>/dev/null
else
  echo "__SOB_PHASE__ render=software" >> /tmp/sobhan-desktop/start.log 2>/dev/null
fi
RES="${1:-__RES__}"
LOG=/tmp/sobhan-desktop/start.log
echo "[$(date +%H:%M:%S)] desktop start script invoked argv=$* DISPLAY=${DISPLAY:-unset}" >> "$LOG" 2>/dev/null
mkdir -p /tmp/sobhan-desktop 2>/dev/null
# SOB-V9-LOCK: تک‌نمونه‌سازیِ مهمان — نمونهٔ زندهٔ قدیمی را اول می‌کشیم تا
# پاک‌سازیِ دیرهنگامش سرورهای تازهٔ همین اجرا را از بین نبرد.
PFD=/tmp/sobhan-desktop/start.pid
if [ -f "$PFD" ]; then
  OLD_PID=$(cat "$PFD" 2>/dev/null | tr -cd '0-9')
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[*] killing stale start_desktop pid $OLD_PID" >> "$LOG"
    kill -9 "$OLD_PID" 2>/dev/null
    sleep 1
  fi
fi
echo $$ > "$PFD" 2>/dev/null
# SOB-DESK-CLEAN-GUESTOP: در چروت هم متنِ کلِ start_desktop داخلِ cmdline است
# ⇒ فقط -x (نامِ فایل) بی‌خطر است.
command -v pkill >/dev/null 2>&1 && pkill -9 -x Xvfb 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x frame_server 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x touch_server 2>/dev/null
for _w in xfce4-session xfce4-panel xfdesktop xfwm4 xfsettingsd xfconfd xfce4-notifyd; do
  command -v pkill >/dev/null 2>&1 && pkill -9 -x "$_w" 2>/dev/null
done
command -v pkill >/dev/null 2>&1 && pkill -9 -x dbus-launch 2>/dev/null
sleep 1
rm -rf /tmp/.X11-unix/X0 /tmp/.X0-lock /tmp/runtime-* 2>/dev/null
echo "[$(date +%H:%M:%S)] desktop startup cleanup complete uid=$(id -u)" >> "$LOG" 2>/dev/null
rm -f /tmp/sobhan_x11_* 2>/dev/null
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp /tmp/.X11-unix 2>/dev/null
mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml 2>/dev/null
cat << 'XFC_EOF' > /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="sync_to_vblank" type="bool" value="false"/>
  </property>
</channel>
XFC_EOF
echo "[*] starting Xvfb $RES" >> "$LOG"
# SOB-V9-XPID: ثبتِ PID برای خودترمیمیِ حلقه.
Xvfb :0 -ac -screen 0 $RES >> "$LOG" 2>&1 &
X_PID=$!
for i in $(seq 1 20); do
  [ -e /tmp/.X11-unix/X0 ] && break
  sleep 1
done
if [ ! -e /tmp/.X11-unix/X0 ]; then
  echo "[!] Xvfb failed to create /tmp/.X11-unix/X0" >> "$LOG"
  echo "__SOB_X_FAIL__"
  exit 1
fi
echo "[*] Xvfb ready (display :0)" >> "$LOG"
# SOB-V9-PHXVFB: نشانهٔ فازی.
echo "__SOB_PHASE__ xvfb" >> "$LOG"
mkdir -p /tmp/runtime-$(id -u)/pulse 2>/dev/null
export PULSE_SERVER="127.0.0.1:4713"
if command -v dbus-daemon >/dev/null 2>&1; then
  mkdir -p /var/lib/dbus /run/dbus 2>/dev/null
  [ -s /etc/machine-id ] || dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null
  [ -s /var/lib/dbus/machine-id ] || cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null
  dbus-daemon --system --fork >> "$LOG" 2>&1 || true
fi
if command -v pulseaudio >/dev/null 2>&1; then
  pulseaudio --check 2>/dev/null || pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=file:/tmp/sobhan-desktop/pulse.log --load="module-null-sink sink_name=sobsink" --load="module-native-protocol-tcp port=4713 auth-ip-acl=127.0.0.1;10.0.0.0/8 auth-anonymous=1" >> "$LOG" 2>&1
  export PULSE_SERVER="127.0.0.1:4713"
  command -v pactl >/dev/null 2>&1 && pactl load-module module-native-protocol-tcp port=4713 auth-ip-acl=127.0.0.1\;10.0.0.0/8 auth-anonymous=1 >> "$LOG" 2>&1
  if [ -e /dev/snd ]; then command -v pactl >/dev/null 2>&1 && pactl load-module module-alsa-sink device=default >> "$LOG" 2>&1; fi
fi
echo "[*] starting frame_server" >> "$LOG"
/usr/local/bin/frame_server >> "$LOG" 2>&1 &
# SOB-V9-FRAMEPID: ثبتِ PIDِ سرورِ فریم برای خودترمیمی.
FRAME_PID=$!
echo "[*] starting touch_server" >> "$LOG"
/usr/local/bin/touch_server -d :0 -p 6001 -w __W__ -h __H__ >> "$LOG" 2>&1 &
# SOB-V9-TOUCHPID: ثبتِ PIDِ سرورِ لمسی برای خودترمیمی.
TOUCH_PID=$!
sleep 1
STAGE=/tmp/sobhan-desktop
mkdir -p "$STAGE" 2>/dev/null
chmod 0777 "$STAGE" 2>/dev/null
rm -f "$STAGE/shutdown.flag" "$STAGE/switch-user" "$STAGE/heal.n" 2>/dev/null
RAPID_N=0
# SOB-NOXREFRESH: حلقهٔ xrefresh هر ۱ ثانیه کل root را invalidate می‌کرد و
# باعث فلیکر/پرش تصویر در Chrome (و کل سشن) می‌شد. frame_server خودش با
# XDamage و IDLE_REFRESH_MS=800 تغییرات را می‌گیرد ⇒ نیازی به این حلقه نیست.
XREFRESH_PID=""
SESSION_USER=__SUSER__
echo "[OK] Desktop started successfully!" >> "$LOG"
echo "__SOB_X_OK__"
while true; do
  if [ -s "$STAGE/switch-user" ]; then
    SESSION_USER=$(head -n 1 "$STAGE/switch-user" | tr -cd 'a-zA-Z0-9._-')
  fi
  rm -f "$STAGE/switch-user" 2>/dev/null
  [ -n "$SESSION_USER" ] || SESSION_USER=root
  UHOME=/root
  if [ "$SESSION_USER" != "root" ]; then
    UHOME="/home/$SESSION_USER"
    if ! id "$SESSION_USER" >/dev/null 2>&1; then
      if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$SHELL_BIN" "$SESSION_USER" >> "$LOG" 2>&1
      else
        grep -q "^$SESSION_USER:" /etc/group 2>/dev/null || echo "$SESSION_USER:x:2000:" >> /etc/group
        grep -q "^$SESSION_USER:" /etc/passwd 2>/dev/null || echo "$SESSION_USER:x:2000:2000:$SESSION_USER:$UHOME:$SHELL_BIN" >> /etc/passwd
      fi
    fi
    mkdir -p "$UHOME" 2>/dev/null
    chown -R "$SESSION_USER":"$SESSION_USER" "$UHOME" 2>/dev/null
  fi
  URUN="/tmp/runtime-$SESSION_USER"
  mkdir -p "$URUN" "$UHOME/.config/xfce4/xfconf/xfce-perchannel-xml" 2>/dev/null
  chmod 700 "$URUN" 2>/dev/null
  chown "$SESSION_USER":"$SESSION_USER" "$URUN" 2>/dev/null
  rm -rf "$URUN/dbus-1" 2>/dev/null
  cat << 'XFC2_EOF' > "$UHOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="sync_to_vblank" type="bool" value="false"/>
  </property>
</channel>
XFC2_EOF
  chown -R "$SESSION_USER":"$SESSION_USER" "$UHOME/.config" 2>/dev/null
  # SOB-V9-PHXFCE: نشانهٔ فازی.
echo "__SOB_PHASE__ xfce" >> "$LOG"
echo "[*] starting xfce4-session as $SESSION_USER" >> "$LOG"
  if [ "$SESSION_USER" = "root" ]; then
    DISPLAY=:0 HOME="$UHOME" USER=root LOGNAME=root XDG_RUNTIME_DIR="$URUN" dbus-launch --exit-with-session xfce4-session >> "$LOG" 2>&1 &
  else
    su - "$SESSION_USER" -c "DISPLAY=:0 XDG_RUNTIME_DIR=$URUN exec dbus-launch --exit-with-session xfce4-session" >> "$LOG" 2>&1 &
  fi
  SESS_PID=$!
  SESS_T0=$(date +%s)
  sleep 3
  xsetroot -solid '#2e3440' >> "$LOG" 2>&1
  # xfce4-session autostarts the panel & desktop from /etc/xdg/autostart.
  # Wait for it; only launch them ourselves as a guarded fallback, otherwise
  # a second panel/desktop appears on Switch User (looks like a 2x image).
  for i in 1 2 3 4 5 6 7 8; do
    pgrep -x xfce4-panel >/dev/null 2>&1 && break
    sleep 1
  done
  if ! pgrep -x xfce4-panel >/dev/null 2>&1; then
    if [ "$SESSION_USER" = "root" ]; then
      command -v xfce4-panel >/dev/null 2>&1 && DISPLAY=:0 xfce4-panel >> "$LOG" 2>&1 &
    else
      su - "$SESSION_USER" -c "DISPLAY=:0 xfce4-panel" >> "$LOG" 2>&1 &
    fi
  fi
  if ! pgrep -x xfdesktop >/dev/null 2>&1; then
    if [ "$SESSION_USER" = "root" ]; then
      command -v xfdesktop >/dev/null 2>&1 && DISPLAY=:0 xfdesktop >> "$LOG" 2>&1 &
    else
      su - "$SESSION_USER" -c "DISPLAY=:0 xfdesktop" >> "$LOG" 2>&1 &
    fi
  fi
  wait "$SESS_PID"
  echo "[*] session for $SESSION_USER exited" >> "$LOG"
  if [ -f "$STAGE/shutdown.flag" ]; then
    echo "[*] shutdown requested" >> "$LOG"
    break
  fi
  # B5: a session that dies right after launch must not respawn forever.
  SESS_DT=$(( $(date +%s) - SESS_T0 ))
  if [ "$SESS_DT" -lt 15 ]; then
    RAPID_N=$((RAPID_N + 1))
    if [ "$RAPID_N" -ge 5 ]; then
      echo "[!] session keeps crashing; giving up" >> "$LOG"
      break
    fi
  else
    RAPID_N=0
    # B4: a long healthy run clears the self-heal budget.
    echo 0 > /tmp/sobhan-desktop/heal.n 2>/dev/null
  fi
  # SOB-V9-HEAL: اگر سرورهای کلیدی از بیرون (LMK/OOM) کشته شده‌اند،
  # پیش از بالا آوردن دوبارهٔ XFCE آن‌ها را برمی‌گردانیم (سقفِ ۵ بار).
  HEAL_N=$(cat /tmp/sobhan-desktop/heal.n 2>/dev/null | tr -cd '0-9')
  [ -n "$HEAL_N" ] || HEAL_N=0
  if [ "$HEAL_N" -lt 5 ]; then
    if [ -n "$X_PID" ] && ! kill -0 "$X_PID" 2>/dev/null; then
      echo "[!] Xvfb died; restarting" >> "$LOG"
      rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null
      Xvfb :0 -ac -screen 0 $RES >> "$LOG" 2>&1 &
      X_PID=$!
      for _x in $(seq 1 20); do [ -e /tmp/.X11-unix/X0 ] && break; sleep 1; done
      HEAL_N=$((HEAL_N + 1))
    fi
    if command -v pgrep >/dev/null 2>&1; then
      if ! pgrep -x frame_server >/dev/null 2>&1; then
        echo "[!] frame_server died; restarting" >> "$LOG"
        /usr/local/bin/frame_server >> "$LOG" 2>&1 & FRAME_PID=$!
        HEAL_N=$((HEAL_N + 1))
      fi
      if ! pgrep -x touch_server >/dev/null 2>&1; then
        echo "[!] touch_server died; restarting" >> "$LOG"
        /usr/local/bin/touch_server -d :0 -p 6001 -w __W__ -h __H__ >> "$LOG" 2>&1 & TOUCH_PID=$!
        HEAL_N=$((HEAL_N + 1))
      fi
    fi
    echo "$HEAL_N" > /tmp/sobhan-desktop/heal.n 2>/dev/null
  fi
  for p in xfce4-panel xfdesktop xfwm4 xfsettingsd xfconfd xfce4-notifyd xfce4-session dbus-launch; do
    command -v pkill >/dev/null 2>&1 && pkill -x "$p" 2>/dev/null
  done
  sleep 1
done
[ -n "$XREFRESH_PID" ] && kill "$XREFRESH_PID" 2>/dev/null
for p in xfce4-panel xfdesktop xfwm4 xfsettingsd xfconfd xfce4-notifyd xfce4-session dbus-launch; do
  command -v pkill >/dev/null 2>&1 && pkill -x "$p" 2>/dev/null
done
# SOB-V9-PHCLEAN: نشانهٔ فازیِ پاک‌سازی.
echo "__SOB_PHASE__ cleanup" >> "$LOG"
# SOB-DESK-CLEAN-GUEST-END: -x امن برای پایانِ سشن.
command -v pkill >/dev/null 2>&1 && pkill -9 -x frame_server 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x touch_server 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x Xvfb 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x pulseaudio 2>/dev/null
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null
echo "[OK] Desktop stopped." >> "$LOG"
exit 0
SD_EOF
chmod 755 "$BIN/start_desktop"
# #SOB-GUEST-SHELL: شبانگ را با پوستهٔ موجود هم‌تراز می‌کنیم.
sed -i "1s|^.*$|#!$GSHELL|" "$BIN/start_desktop" 2>/dev/null
cat << 'LOGOUT_EOF' > "$BIN/xfce4-session-logout"
#!/bin/bash
#SOB-LOGOUT-SHIM
STAGE=/tmp/sobhan-desktop
mkdir -p "$STAGE" 2>/dev/null
chmod 0777 "$STAGE" 2>/dev/null
ACTION=""
for a in "$@"; do
  case "$a" in
    -h|--halt|--shutdown) ACTION=shutdown ;;
    -r|--reboot) ACTION=shutdown ;;
    -s|--suspend|-i|--hibernate|-b|--hybrid-sleep) ACTION=shutdown ;;
    -u|--switch-user) ACTION=switch ;;
    -l|--logout) ACTION=logout ;;
    -f|--fast) : ;;
    -V|--version) echo "xfce4-session-logout 4.18.3 (Sobhan)"; exit 0 ;;
    --help) echo "Usage: xfce4-session-logout [--logout|--halt|--reboot|--switch-user]"; exit 0 ;;
  esac
done
if [ -z "$ACTION" ]; then
  CHOICE=""
  if command -v zenity >/dev/null 2>&1; then
    CHOICE=$(zenity --list --title='Sobhan Desktop' --text='Choose an action' --column='Action' --hide-header 'Log Out' 'Switch User' 'Shut Down' 2>/dev/null)
  fi
  if [ -z "$CHOICE" ] && command -v yad >/dev/null 2>&1; then
    CHOICE=$(yad --list --title='Sobhan Desktop' --text='Choose an action' --column='Action' --no-headers 'Log Out' 'Switch User' 'Shut Down' 2>/dev/null)
    CHOICE=${CHOICE%%|*}
  fi
  if [ -z "$CHOICE" ] && command -v xmessage >/dev/null 2>&1; then
    CHOICE=$(xmessage -center -print -buttons 'Log Out:10,Switch User:11,Shut Down:12' 'Choose an action' 2>/dev/null)
    case "$CHOICE" in
      10) CHOICE='Log Out' ;;
      11) CHOICE='Switch User' ;;
      12) CHOICE='Shut Down' ;;
      *) CHOICE="" ;;
    esac
  fi
  case "$CHOICE" in
    'Log Out') ACTION=logout ;;
    'Switch User') ACTION=switch ;;
    'Shut Down') ACTION=shutdown ;;
    *) exit 0 ;;
  esac
fi
# SOB-DESK-CLEAN-SHIM: ۱) فایلِ IPC را از نو می‌سازیم (پوشه دیگر sticky
# نیست) ۲) اگر zenity/yad نبود از xmessage استفاده می‌کنیم ۳) پیش‌فرض.
case "$ACTION" in
  logout)
    rm -f "$STAGE/switch-user" 2>/dev/null
    : > "$STAGE/switch-user" 2>/dev/null
    ;;
  switch)
    NEWU=""
    if command -v zenity >/dev/null 2>&1; then
      NEWU=$(zenity --entry --title='Switch User' --text='Username:' 2>/dev/null)
    elif command -v yad >/dev/null 2>&1; then
      NEWU=$(yad --entry --title='Switch User' --text='Username:' 2>/dev/null)
    elif command -v xmessage >/dev/null 2>&1; then
      NEWU=$(xmessage -center -print 'Switch to user:' 2>/dev/null)
    fi
    [ -n "$NEWU" ] || NEWU="sobhan"
    rm -f "$STAGE/switch-user" 2>/dev/null
    echo "$NEWU" > "$STAGE/switch-user" 2>/dev/null
    ;;
  shutdown)
    rm -f "$STAGE/shutdown.flag" 2>/dev/null
    : > "$STAGE/shutdown.flag" 2>/dev/null
    ;;
esac
sync 2>/dev/null
for p in xfce4-session xfce4-panel xfdesktop xfwm4 xfsettingsd xfconfd xfce4-notifyd; do
  command -v pkill >/dev/null 2>&1 && pkill -x "$p" 2>/dev/null
done
exit 0
LOGOUT_EOF
chmod 755 "$BIN/xfce4-session-logout"
cat << 'SYSTEMCTL_EOF' > "$BIN/systemctl"
#!/bin/bash
#SOB-SYSTEMCTL-SHIM
# Minimal systemctl shim for the Sobhan chroot desktop.
# systemd cannot be PID 1 here, so map the common verbs onto real actions.
STAGE=/tmp/sobhan-desktop
STATE="$STAGE/services"
SLOG="$STAGE/systemctl.log"
mkdir -p "$STATE" 2>/dev/null
log() { echo "[$(date '+%F %T' 2>/dev/null)] $*" >> "$SLOG" 2>/dev/null; }
case "$1" in
  --version) echo "systemd 255 (sobhan-shim)"; exit 0 ;;
  --help|-h) echo "systemctl (sobhan-shim) - systemd not available in chroot"; exit 0 ;;
esac
VERB=""
UNIT=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) if [ -z "$VERB" ]; then VERB="$a"; elif [ -z "$UNIT" ]; then UNIT="$a"; fi ;;
  esac
done
U="${UNIT%.service}"; U="${U%.socket}"; U="${U##*/}"
[ -n "$VERB" ] || exit 0

unit_bin() {
  case "$U" in
    sshd|ssh) echo /usr/sbin/sshd ;;
    cron|crond) echo /usr/sbin/cron ;;
    NetworkManager|networkmanager) echo /usr/sbin/NetworkManager ;;
    pulseaudio|pulseaudio.socket) echo pulseaudio ;;
    *) echo "" ;;
  esac
}
running_unit() {
  case "$U" in
    dbus|dbus-broker|dbus.socket)
      pgrep -x dbus-daemon >/dev/null 2>&1 || pgrep -x dbus-broker >/dev/null 2>&1 ;;
    *) pgrep -x "$U" >/dev/null 2>&1 ;;
  esac
}
start_unit() {
  local b ex f
  if [ -x "/etc/init.d/$U" ]; then
    "/etc/init.d/$U" start >/dev/null 2>&1 && return 0
  fi
  case "$U" in
    dbus|dbus-broker|dbus.socket)
      running_unit && return 0
      return 0 ;;
    pulseaudio|pulseaudio.socket)
      command -v pulseaudio >/dev/null 2>&1 && pulseaudio --start >/dev/null 2>&1
      return 0 ;;
    sshd|ssh)
      running_unit && return 0
      [ -x /usr/sbin/sshd ] || return 0
      mkdir -p /run/sshd 2>/dev/null
      /usr/sbin/sshd >/dev/null 2>&1
      return 0 ;;
    *)
      b="$(unit_bin)"
      if [ -n "$b" ]; then
        [ -x "${b%% *}" ] && $b >/dev/null 2>&1
        return 0
      fi
      for f in "/lib/systemd/system/$U.service" "/usr/lib/systemd/system/$U.service" "/etc/systemd/system/$U.service"; do
        [ -f "$f" ] || continue
        ex="$(grep -m1 '^ExecStart=' "$f" 2>/dev/null | sed 's/^ExecStart=//')"
        [ -n "$ex" ] || continue
        ex="${ex%% *}"; ex="${ex#-}"
        [ -x "$ex" ] || ex="$(command -v "$(basename "$ex")" 2>/dev/null)"
        [ -n "$ex" ] && "$ex" >/dev/null 2>&1
        return 0
      done
      return 0 ;;
  esac
}
stop_unit() {
  local b
  if [ -x "/etc/init.d/$U" ]; then "/etc/init.d/$U" stop >/dev/null 2>&1; return 0; fi
  case "$U" in
    dbus|dbus-broker|dbus.socket) return 0 ;;
  esac
  b="$(unit_bin)"
  if [ -n "$b" ]; then pkill -x "$(basename "${b%% *}")" 2>/dev/null; fi
  return 0
}

case "$VERB" in
  start)
    : > "$STATE/$U.running" 2>/dev/null
    start_unit; log "start $UNIT"; exit 0 ;;
  stop)
    stop_unit; rm -f "$STATE/$U.running" 2>/dev/null
    log "stop $UNIT"; exit 0 ;;
  restart|reload|force-reload|try-restart|reload-or-restart)
    stop_unit; start_unit; log "$VERB $UNIT"; exit 0 ;;
  enable|reenable|preset)
    : > "$STATE/$U.enabled" 2>/dev/null; log "enable $UNIT"; exit 0 ;;
  disable|mask)
    rm -f "$STATE/$U.enabled" 2>/dev/null; log "disable $UNIT"; exit 0 ;;
  unmask|daemon-reload|daemon-reexec|reset-failed)
    exit 0 ;;
  is-active)
    if running_unit || [ -f "$STATE/$U.running" ]; then echo active; exit 0
    else echo inactive; exit 3; fi ;;
  is-enabled)
    if [ -f "$STATE/$U.enabled" ]; then echo enabled; else echo disabled; fi
    exit 0 ;;
  is-failed)
    echo inactive; exit 1 ;;
  status)
    if running_unit || [ -f "$STATE/$U.running" ]; then
      echo "* $UNIT - active (sobhan-shim)"; exit 0
    else echo "* $UNIT - inactive (sobhan-shim)"; exit 3; fi ;;
  list-units|list-unit-files)
    echo "UNIT LOAD ACTIVE SUB DESCRIPTION"; echo "(systemd unavailable; sobhan-shim)"; exit 0 ;;
  cat)
    for f in "/lib/systemd/system/$U.service" "/usr/lib/systemd/system/$U.service" "/etc/systemd/system/$U.service"; do
      [ -f "$f" ] && { cat "$f"; exit 0; }
    done
    echo "# $UNIT not found (sobhan-shim)"; exit 0 ;;
  *)
    log "ignored verb '$VERB' for '$UNIT'"; exit 0 ;;
esac
SYSTEMCTL_EOF
chmod 755 "$BIN/systemctl"
sed -i "1s|^.*$|#!$GSHELL|" "$BIN/xfce4-session-logout" 2>/dev/null
sed -i "1s|^.*$|#!$GSHELL|" "$BIN/systemctl" 2>/dev/null
cat << 'SERVICE_EOF' > "$BIN/service"
#!/bin/sh
#SOB-SERVICE-SHIM
[ -n "$2" ] || { echo "Usage: service <name> <start|stop|restart|status>"; exit 1; }
exec systemctl "$2" "$1"
SERVICE_EOF
chmod 755 "$BIN/service"
for _p in /usr/bin/systemctl /sbin/systemctl /usr/sbin/service; do
  [ -e "$_p" ] || ln -sf "$BIN/systemctl" "$_p" 2>/dev/null
done
chmod 755 "$BIN/start_desktop"
mkdir -p "__STAGE__"
chmod 0777 "__STAGE__" 2>/dev/null

# SOB-V9-HOSTLOCK: قفلِ تک‌نمونه در سطحِ هاست — دو راه‌اندازیِ هم‌زمان
# (دوبار ضربهٔ سریع) را سریال می‌کند تا پاک‌سازیِ یکی، دسکتاپِ دیگری را
# از بین نبرد. قفلِ کهنه (pidمرده) خودکار شکسته می‌شود.
LOCKD="__STAGE__/.start.lock"
LOCK_OK=0
for _lw in $(seq 1 20); do
  if mkdir "$LOCKD" 2>/dev/null; then
    LOCK_OK=1
    echo $$ > "$LOCKD/pid" 2>/dev/null
    break
  fi
  _lp=$(cat "$LOCKD/pid" 2>/dev/null | tr -cd '0-9')
  if [ -z "$_lp" ] || ! kill -0 "$_lp" 2>/dev/null; then
    rm -rf "$LOCKD" 2>/dev/null
    continue
  fi
  sleep 0.5
done
if [ "$LOCK_OK" != "1" ]; then
  echo "__SOB_LOCK_BUSY__"
  exit 0
fi
trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT

# SOB-VIRGL-UP: سرور VirGL روی «هاست» (اندروید/روت) اجرا می‌شود و سوکتش
# از طریق همان بایندِ __STAGE__ داخل چروت دیده می‌شود.  اگر باینری یا
# کتابخانه‌ها نباشند، بی‌صدا رد می‌شود تا دسکتاپ بدون GPU بالا بیاید.
VIRGL_BIN="__STAGE__/virgl/bin/virgl_test_server"
VIRGL_LIB="__STAGE__/virgl/lib"
VIRGL_SOCK="__STAGE__/virgl.sock"
# SOB-GPU-TOGGLE: کلیدِ روشن/خاموشِ شتاب (1/0) توسط start() جای‌گذاری می‌شود.
if [ "__VIRGL__" = "1" ] && [ -x "$VIRGL_BIN" ] && [ -f "$VIRGL_LIB/libvirglrenderer.so" ] && [ -f "$VIRGL_LIB/libepoxy.so" ]; then
  # SOB-DESK-CLEAN: pkill روی هاست خودِ خطِ فرمانِ su را می‌گرفت.
  # الگوی «مسیر+فلگ» است تا فقط خودِ سرور VirGL کشته شود.
  command -v pkill >/dev/null 2>&1 && pkill -9 -f 'virgl/bin/virgl_test_serve[r] --use-gles' 2>/dev/null
# SOB-V9-VIRGLALIVE: سوکتِ تنها کافی نیست؛ باید سرور زنده بماند. اگر
# پس از انتظار پروسه مرده یا سوکت نیامده باشد، virgl.ok نوشته نمی‌شود
# تا مهمان به llvmpipe برگردد (نه سقوطِ دسکتاپ).
  command -v pkill >/dev/null 2>&1 && pkill -9 -x virgl_test_serv 2>/dev/null
  rm -f "$VIRGL_SOCK" "__STAGE__/virgl.ok" 2>/dev/null
  LD_LIBRARY_PATH="$VIRGL_LIB" setsid nohup "$VIRGL_BIN" --use-gles --use-egl-surfaceless --socket-path "$VIRGL_SOCK" >>"__STAGE__/virgl.log" 2>&1 </dev/null &
  VR_PID=$!
  for _i in $(seq 1 10); do [ -S "$VIRGL_SOCK" ] && break; sleep 0.5; done
  sleep 1
  chmod 0777 "$VIRGL_SOCK" 2>/dev/null
  if [ -S "$VIRGL_SOCK" ] && kill -0 "$VR_PID" 2>/dev/null; then
    : > "__STAGE__/virgl.ok" 2>/dev/null
    chmod 0666 "__STAGE__/virgl.ok" 2>/dev/null
    echo "__SOB_VIRGL_UP__"
  else
    rm -f "__STAGE__/virgl.ok" 2>/dev/null
    echo "__SOB_VIRGL_UP__ (not alive)"
  fi
else
  rm -f "__STAGE__/virgl.ok" 2>/dev/null
  echo "__SOB_VIRGL_UP__ (skipped)"
fi
mkdir -p "$R/tmp/sobhan-desktop"
mountpoint -q "$R/tmp/sobhan-desktop" || mount --bind "__STAGE__" "$R/tmp/sobhan-desktop" 2>/dev/null
chmod 0777 "$R/tmp/sobhan-desktop" 2>/dev/null
mkdir -p "$R/dev" "$R/dev/pts" "$R/proc" "$R/sys" "$R/tmp/.X11-unix" "$R/tmp/.virgl_test" /tmp/.X11-unix /tmp/.virgl_test /dev/socket/virgl 2>/dev/null
chmod 1777 /tmp /tmp/.X11-unix /tmp/.virgl_test "$R/tmp" "$R/tmp/.X11-unix" "$R/tmp/.virgl_test" /dev/socket/virgl 2>/dev/null
mountpoint -q "$R/tmp/.X11-unix" || mount --bind /tmp/.X11-unix "$R/tmp/.X11-unix" 2>/dev/null
mountpoint -q "$R/tmp/.virgl_test" || mount --bind /tmp/.virgl_test "$R/tmp/.virgl_test" 2>/dev/null
mkdir -p "$R/dev/socket/virgl" 2>/dev/null
mountpoint -q "$R/dev/socket/virgl" || mount --bind /dev/socket/virgl "$R/dev/socket/virgl" 2>/dev/null
# Stable machine-id lets dbus-daemon --system start in minimal rootfs images.
if [ ! -s "$R/etc/machine-id" ]; then (cat /proc/sys/kernel/random/uuid 2>/dev/null || od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') | tr -d '-' > "$R/etc/machine-id"; fi
mkdir -p "$R/var/lib/dbus" 2>/dev/null
cp "$R/etc/machine-id" "$R/var/lib/dbus/machine-id" 2>/dev/null
mountpoint -q "$R/dev" || mount --bind /dev "$R/dev" 2>/dev/null
mountpoint -q "$R/dev/pts" || mount --bind /dev/pts "$R/dev/pts" 2>/dev/null
mountpoint -q "$R/proc" || mount -t proc proc "$R/proc" 2>/dev/null
mountpoint -q "$R/sys" || mount -t sysfs sysfs "$R/sys" 2>/dev/null
setsid chroot "$R" "$GSHELL" /usr/local/bin/start_desktop __RES__ >"__LOG__" 2>&1 < /dev/null &
echo "__SOB_START_OK__"
exit 0
''';


  /// Best-effort Android SoC detection (Rooted device).
  ///
  /// Tries `getprop ro.soc.model` first, then `ro.board.platform` /
  /// `ro.hardware`, and finally `/proc/cpuinfo`.  The returned string is
  /// lower-cased and trimmed; empty when nothing could be read.
  static Future<String> detectSoc() async {
    const String tpl = r'''
SOC="$(getprop ro.soc.model 2>/dev/null)"
[ -z "$SOC" ] && SOC="$(getprop ro.board.platform 2>/dev/null)"
[ -z "$SOC" ] && SOC="$(getprop ro.hardware 2>/dev/null)"
[ -z "$SOC" ] && SOC="$(grep -m1 -i -E 'Hardware|Processor' /proc/cpuinfo 2>/dev/null | cut -d: -f2)"
echo "__SOB_SOC__${SOC}"
''';
    try {
      final ProcessResult r = await Process.run('su', <String>['-c', tpl]);
      final String out = r.stdout.toString();
      final int at = out.indexOf('__SOB_SOC__');
      if (at < 0) return '';
      String soc = out.substring(at + '__SOB_SOC__'.length);
      final int nl = soc.indexOf('\n');
      if (nl >= 0) soc = soc.substring(0, nl);
      return soc.trim().toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// Shell `export` lines selecting a GPU stack that matches the device.
  ///
  /// * Qualcomm/Snapdragon => Turnip (Mesa Freedreno Vulkan/GL) + zink.
  /// * Exynos/Mali/MediaTek/other ARM => software rasteriser (llvmpipe),
  ///   which is always safe inside a chroot with no `/dev/dri` guarantees.
  static Future<String> gpuEnv() async {
    final String soc = await detectSoc();
    final bool adreno = soc.contains('qualcomm') ||
        soc.contains('snapdragon') ||
        soc.contains('sm8') ||
        soc.contains('sm7') ||
        soc.contains('msm') ||
        soc.contains('adreno');
    final List<String> lines = <String>[
      if (adreno) ...<String>[
        'export MESA_LOADER_DRIVER_OVERRIDE=zink',
        'export GALLIUM_DRIVER=zink',
        'export TU_DEBUG=noconform',
      ] else ...<String>[
        'export GALLIUM_DRIVER=llvmpipe',
        'export LIBGL_ALWAYS_SOFTWARE=1',
      ],
      'export MESA_GL_VERSION_OVERRIDE=3.3',
      'export MESA_GLSL_VERSION_OVERRIDE=330',
      'export vblank_mode=0',
      'export MESA_NO_ERROR=1',
      'export MESA_GLTHREAD=true',
      'export XDG_SESSION_TYPE=x11',
      'export NO_AT_BRIDGE=1',
      r'export LP_NUM_THREADS=$(grep -c ^processor /proc/cpuinfo '
      r'2>/dev/null || echo 4)',
    ];
    return lines.join('\n');
  }

  /// Writes `start_desktop` and launches the whole stack in the background.
  // SOB-V9-DARTLOCK: نگهبانِ تک‌نمونه — دوبار زدنِ سریعِ «اتصال دسکتاپ»
  // نباید دو راه‌اندازیِ هم‌زمان بسازد (پاک‌سازیِ یکی، دسکتاپِ دیگری را
  // می‌کشت و همان خطای «Killed» را می‌داد).
  static bool _starting = false;

  // SOB-SESSION-USER: فقط حروف/ارقام/نقطه/خط‌تیره مجاز است.
  static String _safeUser(String v) {
    final String t = v.trim();
    if (t.isEmpty) return 'root';
    final String c = t.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '');
    return c.isEmpty ? 'root' : c;
  }

  static Future<bool> start(
    Distro distro, {
    int width = defaultWidth,
    int height = defaultHeight,
    void Function(String line)? log,
    // SOB-GPU-TOGGLE: خاموش‌کردن شتاب، بلوک‌های VirGL را در اسکریپت رد می‌کند.
    bool gpuAccel = true,
    // SOB-SESSION-USER: کاربری که سشن دسکتاپ با آن اجرا می‌شود.
    String sessionUser = 'root',
  }) async {
    if (_starting) return false;
    _starting = true;
    try {
      return await _startLocked(
        distro,
        width: width,
        height: height,
        log: log,
        gpuAccel: gpuAccel,
        sessionUser: sessionUser,
      );
    } finally {
      _starting = false;
    }
  }

  static Future<bool> _startLocked(
    Distro distro, {
    int width = defaultWidth,
    int height = defaultHeight,
    void Function(String line)? log,
    bool gpuAccel = true,
    String sessionUser = 'root',
  }) async {
    await installAndroidRun(distro);
    final String res = '${width}x${height}x24';
    final String gpu = await gpuEnv();
    final String script = _startTpl
        .replaceAll(
          '__ROOT__',
          DistroDetector.escapeShellDoubleQuoted(distro.rootDir),
        )
        .replaceAll('__STAGE__', DesktopAssets.stagingDir)
        .replaceAll('__LOG__', logFile)
        .replaceAll('__W__', '$width')
        .replaceAll('__H__', '$height')
        .replaceAll('__GPU__', gpu)
        .replaceAll('__VIRGL__', gpuAccel ? '1' : '0')
        .replaceAll('__RES__', res)
        .replaceAll('__SUSER__', _safeUser(sessionUser));
    try {
      final ProcessResult r = await Process.run('su', <String>['-c', script]);
      log?.call(r.stdout.toString().trim());
      if (!r.stdout.toString().contains('__SOB_START_OK__')) return false;
    } catch (_) {
      await stop();
      return false;
    }
    // SOB-DESK-CLEAN-WAIT: نمونهٔ قبلی ممکن است در حالِ مرگ باشد و
    // پورت‌ها را هنوز نگه داشته باشد؛ کوتاه صبر می‌کنیم تا آزاد شوند.
    for (int i = 0; i < 6; i++) {
      if (!await isFrameServerUp() && !await isInputServerUp()) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // Wait until frame_server (6000) and touch_server (6001) really accept
    // connections.  Xvfb + XFCE can take a few seconds on a phone.
    // B8: back off gradually (no connection spam) and, because an open port
    // alone can be a stale/foreign listener, also require the real processes.
    // B6: `__SOB_START_OK__` only proves the host script ran, so readiness is
    // confirmed here by process + port checks.
    int delayMs = 250;
    for (int i = 0; i < 40; i++) {
      if (await isFrameServerUp() &&
          await isInputServerUp() &&
          await _coreProcsAlive()) {
        return true;
      }
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (delayMs < 1500) delayMs += 250;
    }
    // B7: timed out - don't leave Xvfb/servers running unattended.
    await stop();
    return false;
  }

  /// Last [maxLines] lines of the desktop log (best effort, for diagnostics).
  static Future<String> logTail({int maxLines = 40}) async {
    try {
      final ProcessResult r = await Process.run(
        'su',
        <String>['-c', 'tail -n $maxLines "$logFile" 2>/dev/null'],
      );
      return r.stdout.toString().trim();
    } catch (_) {
      return '';
    }
  }

  static const String _stopTpl = r'''
command -v pkill >/dev/null 2>&1 && pkill -9 -f 'start[_]desktop' 2>/dev/null
# SOB-DESK-CLEAN-STOP: commِ فرایندها ≤15 کاراکتر است ⇒ -x قابل‌اعتماد است
# (الگوی -f روی متنِ خودِ اسکریپت self-match می‌کرد).
command -v pkill >/dev/null 2>&1 && pkill -9 -x Xvfb 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x frame_server 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x touch_server 2>/dev/null
for _w in xfce4-session xfce4-panel xfdesktop xfwm4 xfsettingsd xfconfd xfce4-notifyd; do
  command -v pkill >/dev/null 2>&1 && pkill -9 -x "$_w" 2>/dev/null
done
# SOB-V9-VIRGL-KILL: الگوی مسیرمحور + commِ کوتاه؛ فایل‌های سوکت/تأییدیه/
# SOB-V9-STOP: قفل هم پاک می‌شوند تا اجرای بعدی دچارِ سوکتِ کهنه نشود.
command -v pkill >/dev/null 2>&1 && pkill -9 -f 'virgl/bin/virgl_test_serve[r]' 2>/dev/null
command -v pkill >/dev/null 2>&1 && pkill -9 -x virgl_test_serv 2>/dev/null
STG=/data/sobhan-desktop
rm -f "$STG/virgl.sock" "$STG/virgl.ok" "$STG/start.pid" 2>/dev/null
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null
echo "__SOB_STOP_OK__"
exit 0
''';

  /// Kills the X stack (Xvfb, servers and the XFCE session).
  static Future<void> stop() async {
    try {
      await Process.run('su', <String>['-c', _stopTpl]);
    } catch (_) {}
  }

  /// `true` when `frame_server` already accepts connections on [framePort].
  static Future<bool> isFrameServerUp() => _portOpen(framePort);

  /// `true` when `touch_server` already accepts connections on [inputPort].
  static Future<bool> isInputServerUp() => _portOpen(inputPort);

  /// `true` when Xvfb, frame_server and touch_server are all running.
  static Future<bool> _coreProcsAlive() async {
    try {
      final ProcessResult r = await Process.run('su', <String>[
        '-c',
        'pgrep -x Xvfb >/dev/null && pgrep -x frame_server >/dev/null && '
            'pgrep -x touch_server >/dev/null && echo __SOB_PROCS_OK__',
      ]);
      return r.stdout.toString().contains('__SOB_PROCS_OK__');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _portOpen(int port) async {
    try {
      final Socket s = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 500),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
