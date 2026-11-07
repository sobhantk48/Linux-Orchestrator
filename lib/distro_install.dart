import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;

import 'package:path_provider/path_provider.dart';

import 'distro.dart';

/// Raw result of probing a RootFS through `su`.
class DistroProbe {
  const DistroProbe({
    this.osReleaseText = '',
    this.osRelease = const <String, String>{},
    this.shell,
    this.packageManager,
  });

  final String osReleaseText;
  final Map<String, String> osRelease;
  final String? shell;
  final String? packageManager;
}

/// A distribution inferred from a RootFS (or from an `os-release` file).
class DistroDetection {
  const DistroDetection({
    required this.id,
    required this.label,
    required this.family,
    required this.shell,
    this.packageManager,
  });

  final String id;
  final String label;
  final DistroFamily family;
  final String shell;
  final String? packageManager;
}

class DistroInstallResult {
  const DistroInstallResult({
    required this.ok,
    required this.message,
    this.distro,
  });

  final bool ok;
  final String message;
  final Distro? distro;
}

/// Pure, side-effect free helpers that turn an arbitrary RootFS into a
/// [Distro] preset. Everything here is unit-testable without a device.
class DistroDetector {
  const DistroDetector._();

  static const String _probeTpl = r'''
R="__ROOT__"
echo "__SOB_OSREL_BEGIN__"
cat "$R/etc/os-release" 2>/dev/null
echo "__SOB_OSREL_END__"
for c in bin/bash usr/bin/bash bin/zsh usr/bin/zsh bin/fish usr/bin/fish bin/sh usr/bin/sh bin/ash usr/bin/ash bin/busybox usr/bin/busybox; do
  if [ -x "$R/$c" ]; then echo "__SOB_SHELL__=/$c"; fi
done
for m in apt-get apt dnf yum zypper pacman apk xbps-install eopkg nix-env emerge; do
  for d in usr/bin bin usr/sbin sbin usr/local/bin; do
    if [ -x "$R/$d/$m" ]; then echo "__SOB_PM__=$m"; fi
  done
done
echo "__SOB_PROBE_END__"
exit 0
''';

  static String probeScript(String rootDir) =>
      _probeTpl.replaceAll('__ROOT__', escapeShellDoubleQuoted(rootDir));

  /// Escapes a value so it can be embedded inside a double quoted shell word.
  /// Newlines / carriage returns cannot be escaped inside a double quoted
  /// word, so they are rejected outright (I1). `!` is intentionally NOT
  /// escaped: inside double quotes `\!` stays a literal backslash+bang, and
  /// history expansion never runs in non-interactive `sh -c`.
  static String escapeShellDoubleQuoted(String value) {
    if (value.contains('\n') || value.contains('\r') || value.contains('\x00')) {
      throw ArgumentError.value(value, 'value', 'contains control characters');
    }
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', '\\`');
  }

  /// Minimal `os-release` parser: `KEY=value`, quotes stripped, comments and
  /// blank lines ignored.
  static Map<String, String> parseOsRelease(String text) {
    final map = <String, String>{};
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim();
      var value = line.substring(eq + 1).trim();
      if (value.length >= 2) {
        final first = value[0];
        final last = value[value.length - 1];
        if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
          value = value.substring(1, value.length - 1);
        }
      }
      if (key.isNotEmpty) map[key] = value;
    }
    return map;
  }

  static DistroProbe parseProbe(String output) {
    final relLines = <String>[];
    var inRel = false;
    String? shell;
    String? packageManager;
    for (final raw in output.split('\n')) {
      final line = raw.trimRight();
      if (line.contains('__SOB_OSREL_BEGIN__')) {
        inRel = true;
        continue;
      }
      if (line.contains('__SOB_OSREL_END__')) {
        inRel = false;
        continue;
      }
      if (inRel) {
        relLines.add(line);
        continue;
      }
      if (line.startsWith('__SOB_SHELL__=')) {
        final candidate = line.substring('__SOB_SHELL__='.length).trim();
        if (candidate.isNotEmpty) shell ??= candidate;
      } else if (line.startsWith('__SOB_PM__=')) {
        final candidate = line.substring('__SOB_PM__='.length).trim();
        if (candidate.isEmpty) continue;
        if (packageManager == null ||
            _pmPriority(candidate) < _pmPriority(packageManager)) {
          packageManager = candidate;
        }
      }
    }
    final relText = relLines.join('\n');
    return DistroProbe(
      osReleaseText: relText,
      osRelease: parseOsRelease(relText),
      shell: shell,
      packageManager: packageManager,
    );
  }

  static int _pmPriority(String pm) {
    switch (pm) {
      case 'apt-get':
        return 0;
      case 'apt':
        return 1;
      case 'dnf':
        return 2;
      case 'zypper':
        return 3;
      case 'pacman':
        return 4;
      case 'apk':
        return 5;
      case 'yum':
        return 6;
      case 'rpm':
        return 7;
      default:
        return 9;
    }
  }

  /// Turns arbitrary user text into a safe filesystem/id slug.
  static String sanitizeId(String raw, {String fallback = 'custom'}) {
    final lowered = raw.toLowerCase().trim();
    final buffer = StringBuffer();
    var lastDash = false;
    for (final rune in lowered.runes) {
      final isLower = rune >= 0x61 && rune <= 0x7A;
      final isDigit = rune >= 0x30 && rune <= 0x39;
      if (isLower || isDigit) {
        buffer.write(String.fromCharCode(rune));
        lastDash = false;
      } else if (!lastDash) {
        buffer.write('-');
        lastDash = true;
      }
    }
    var id = buffer.toString();
    while (id.startsWith('-')) {
      id = id.substring(1);
    }
    while (id.endsWith('-')) {
      id = id.substring(0, id.length - 1);
    }
    return id.isEmpty ? fallback : id;
  }

  /// Best effort id from an archive URL, e.g.
  /// `.../kali-linux-2024.1-rootfs-arm64.tar.xz` -> `kali-linux`.
  static String idFromUrl(String url) {
    var name = url.trim();
    final slash = name.lastIndexOf('/');
    if (slash >= 0) name = name.substring(slash + 1);
    final query = name.indexOf('?');
    if (query >= 0) name = name.substring(0, query);
    final hash = name.indexOf('#');
    if (hash >= 0) name = name.substring(0, hash);
    const suffixes = <String>[
      '.tar.gz',
      '.tar.xz',
      '.tar.bz2',
      '.tar.zst',
      '.tar.lz4',
      '.tgz',
      '.txz',
      '.tbz2',
      '.tbz',
      '.tzst',
      '.tar',
      '.zip',
    ];
    final lower = name.toLowerCase();
    for (final suffix in suffixes) {
      if (lower.endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
        break;
      }
    }
    name = name.replaceAll(RegExp(r'[._]'), '-');
    name = name.replaceAll(RegExp(r'-(rootfs|root|fs)(-.*)?$'), '');
    name = name.replaceAll(
        RegExp(r'-(arm64|aarch64|amd64|x86-64|x64|armhf|armv7l?)$'), '');
    var id = sanitizeId(name, fallback: '');
    // `.../debian/trixie/arm64/default/20261106_05:24/rootfs.tar.xz` yields
    // `rootfs`, which says nothing. Walk the path instead and take the first
    // meaningful segment (`debian`).
    if (id.isEmpty || _genericIds.contains(id)) {
      final fromPath = _idFromPathSegments(url);
      if (fromPath != null) id = fromPath;
    }
    return id.isEmpty ? 'custom' : id;
  }

  static const Set<String> _genericIds = <String>{
    'rootfs',
    'root',
    'fs',
    'base',
    'minimal',
    'default',
    'latest',
    'image',
    'images',
    'container',
    'dist',
    'pub',
    'releases',
    'download',
  };

  /// First non-generic directory segment of a URL path (host excluded).
  static String? _idFromPathSegments(String url) {
    var path = url.trim();
    final scheme = path.indexOf('://');
    if (scheme >= 0) path = path.substring(scheme + 3);
    final query = path.indexOf('?');
    if (query >= 0) path = path.substring(0, query);
    final hash = path.indexOf('#');
    if (hash >= 0) path = path.substring(0, hash);
    final parts = path.split('/');
    // parts[0] is the host, the last part is the file name.
    for (var i = 1; i < parts.length - 1; i++) {
      final segment = parts[i];
      if (segment.isEmpty) continue;
      if (RegExp(r'^\d{8}[_-]').hasMatch(segment)) continue;
      if (RegExp(r'^\d+$').hasMatch(segment)) continue;
      final slug = sanitizeId(segment, fallback: '');
      if (slug.isEmpty) continue;
      if (_genericIds.contains(slug)) continue;
      if (_archSegments.contains(slug)) continue;
      return slug;
    }
    return null;
  }

  static const Set<String> _archSegments = <String>{
    'arm64',
    'aarch64',
    'amd64',
    'x86-64',
    'x64',
    'i386',
    'armhf',
    'armv7',
    'armv7l',
  };

  static DistroFamily familyForId(String id, String idLike) {
    final tokens = <String>{
      ...id.toLowerCase().split(RegExp(r'[^a-z0-9]+')),
      ...idLike.toLowerCase().split(RegExp(r'[^a-z0-9]+')),
    }..removeWhere((t) => t.isEmpty);
    const debian = <String>{
      'debian',
      'ubuntu',
      'kali',
      'mint',
      'raspbian',
      'devuan',
      'parrot',
      'pop',
    };
    const redhat = <String>{
      'fedora',
      'rhel',
      'centos',
      'rocky',
      'alma',
      'almalinux',
      'amzn',
      'ol',
    };
    const suse = <String>{'suse', 'opensuse', 'sles'};
    const arch = <String>{
      'arch',
      'archlinux',
      'blackarch',
      'manjaro',
      'endeavouros',
      'garuda',
    };
    const alpine = <String>{'alpine', 'postmarketos'};
    if (tokens.any(debian.contains)) return DistroFamily.debian;
    if (tokens.any(redhat.contains)) return DistroFamily.redhat;
    if (tokens.any(suse.contains)) return DistroFamily.suse;
    if (tokens.any(arch.contains)) return DistroFamily.arch;
    if (tokens.any(alpine.contains)) return DistroFamily.alpine;
    return DistroFamily.generic;
  }

  static String? packageManagerForFamily(DistroFamily family) {
    switch (family) {
      case DistroFamily.debian:
        return 'apt-get';
      case DistroFamily.redhat:
        return 'dnf';
      case DistroFamily.suse:
        return 'zypper';
      case DistroFamily.arch:
        return 'pacman';
      case DistroFamily.alpine:
        return 'apk';
      case DistroFamily.generic:
        return null;
    }
  }

  static DistroFamily familyForPackageManager(String? pm) {
    switch (pm) {
      case 'apt':
      case 'apt-get':
      case 'dpkg':
        return DistroFamily.debian;
      case 'dnf':
      case 'yum':
      case 'rpm':
        return DistroFamily.redhat;
      case 'zypper':
        return DistroFamily.suse;
      case 'pacman':
        return DistroFamily.arch;
      case 'apk':
        return DistroFamily.alpine;
      default:
        return DistroFamily.generic;
    }
  }

  static DistroDetection fromOsRelease(
    String text, {
    String? shellHint,
    String? packageManagerHint,
    String? idHint,
    String? labelHint,
  }) {
    final rel = parseOsRelease(text);
    final rawId = (rel['ID'] ?? '').trim();
    final idLike = (rel['ID_LIKE'] ?? '').trim();
    var id = sanitizeId(idHint ?? '', fallback: '');
    if (id.isEmpty) id = sanitizeId(rawId, fallback: '');
    if (id.isEmpty) id = 'custom';

    final hint = (labelHint ?? '').trim();
    final pretty = (rel['PRETTY_NAME'] ?? rel['NAME'] ?? '').trim();
    final label = hint.isNotEmpty
        ? hint
        : (pretty.isNotEmpty ? pretty : DistroRegistry.labelFor(id));

    var family = familyForId(rawId, idLike);
    if (family == DistroFamily.generic) {
      family = familyForId(idHint ?? '', '');
    }
    if (family == DistroFamily.generic && packageManagerHint != null) {
      family = familyForPackageManager(packageManagerHint);
    }

    final shellHintTrimmed = (shellHint ?? '').trim();
    final shell = shellHintTrimmed.isNotEmpty ? shellHintTrimmed : '/bin/sh';
    final pmHint = (packageManagerHint ?? '').trim();
    final packageManager =
        pmHint.isNotEmpty ? pmHint : packageManagerForFamily(family);

    return DistroDetection(
      id: id,
      label: label,
      family: family,
      shell: shell,
      packageManager: packageManager,
    );
  }

  static Distro buildDistro(DistroDetection detection) => Distro(
        id: detection.id,
        label: detection.label,
        family: detection.family,
        rootDir: DistroRegistry.rootDirFor(detection.id),
        loginScript: DistroRegistry.loginScriptFor(detection.id),
        shell: detection.shell,
        packageManager: detection.packageManager,
        accent: DistroRegistry.accentFor(detection.id),
        isCustom: true,
      );
}

/// Downloads a RootFS archive, unpacks it, detects what it is and remembers it.
class DistroInstaller {
  const DistroInstaller._();

  static const String lockFile = '/data/.install.lock';
  static const String manifestFile = '/data/sobhan-distros.json';

  static String? archiveKind(String url) {
    final lower = url.trim().toLowerCase();
    final path = lower.split('?').first.split('#').first;
    if (path.endsWith('.tar.gz') || path.endsWith('.tgz')) return 'gzip';
    if (path.endsWith('.tar.xz') || path.endsWith('.txz')) return 'xz';
    if (path.endsWith('.tar.bz2') ||
        path.endsWith('.tbz2') ||
        path.endsWith('.tbz')) {
      return 'bzip2';
    }
    if (path.endsWith('.tar.zst') || path.endsWith('.tzst')) return 'zstd';
    if (path.endsWith('.tar')) return 'tar';
    if (path.endsWith('.zip')) return 'zip';
    return null;
  }

  static String suffixFor(String kind) {
    switch (kind) {
      case 'gzip':
        return 'tar.gz';
      case 'xz':
        return 'tar.xz';
      case 'bzip2':
        return 'tar.bz2';
      case 'zstd':
        return 'tar.zst';
      case 'zip':
        return 'zip';
      default:
        return 'tar';
    }
  }

  static String extractCommand(String kind) {
    switch (kind) {
      case 'gzip':
        return 'tar -xzf "\$ARCHIVE" -C "\$ROOT"';
      case 'xz':
        // #SOB-XZ-CHAIN
        // اندروید (toybox) معمولاً xz ندارد؛ پس چند راه پشت سر هم امتحان
        // می‌شود و در صورت شکست با کد ۲ اعلام می‌کنیم تا Dart دیکودر
        // نیتیو را صدا بزند.
        return _xzChain;
      case 'bzip2':
        return 'tar -xjf "\$ARCHIVE" -C "\$ROOT"';
      case 'zstd':
        return '(command -v zstd >/dev/null 2>&1 && zstd -d -c "\$ARCHIVE" | tar -xf - -C "\$ROOT")'
            ' || tar --zstd -xf "\$ARCHIVE" -C "\$ROOT"';
      case 'zip':
        return 'unzip -q -o "\$ARCHIVE" -d "\$ROOT"';
      default:
        return 'tar -xf "\$ARCHIVE" -C "\$ROOT"';
    }
  }

  /// زنجیرهٔ استخراج xz: هر استراتژی در یک پوشهٔ خالی اجرا می‌شود و اگر
  /// خروجی‌اش خالی بود، پوشه پاک و استراتژی بعدی امتحان می‌شود.
  /// در پایان اگر هیچ‌کدام جواب نداد `__SOB_ERR__=no-xz` و `exit 2`.
  static const String _xzChain = r'''
__sobxz_reset() { rm -rf "$ROOT"; mkdir -p "$ROOT"; }
__sobxz_nonempty() {
  [ -n "$(ls -A "$ROOT" 2>/dev/null)" ] && return 0
  return 1
}
__sobxz_busybox() {
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
           /data/adb/ksud/busybox /system/xbin/busybox \
           /system/bin/busybox /data/data/com.termux/files/usr/bin/busybox; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  command -v busybox 2>/dev/null
}
__sobxz_xzbin() {
  for b in /data/data/com.termux/files/usr/bin/xz \
           /data/data/com.termux/files/usr/bin/unxz \
           /system/xbin/xz /system/bin/xz; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  command -v xz 2>/dev/null
}
__sobxz_try() {
  __sobxz_reset
  ( eval "$1" ) >/dev/null 2>&1
  __sobxz_nonempty
}
XZOK=0
if __sobxz_try 'tar -xJf "$ARCHIVE" -C "$ROOT"'; then XZOK=1; fi
if [ "$XZOK" = "0" ]; then
  XZB=$(__sobxz_xzbin)
  if [ -n "$XZB" ]; then
    if __sobxz_try '"$XZB" -dc "$ARCHIVE" | tar -xf - -C "$ROOT"'; then XZOK=1; fi
  fi
fi
if [ "$XZOK" = "0" ]; then
  BB=$(__sobxz_busybox)
  if [ -n "$BB" ]; then
    if __sobxz_try '"$BB" xz -dc "$ARCHIVE" | tar -xf - -C "$ROOT"'; then XZOK=1; fi
  fi
fi
if [ "$XZOK" = "0" ]; then
  if __sobxz_try 'toybox xzcat "$ARCHIVE" | tar -xf - -C "$ROOT"'; then XZOK=1; fi
fi
if [ "$XZOK" = "0" ]; then
  if __sobxz_try 'xzcat "$ARCHIVE" | tar -xf - -C "$ROOT"'; then XZOK=1; fi
fi
if [ "$XZOK" = "0" ]; then
  rm -rf "$ROOT"
  echo "__SOB_ERR__=no-xz"
  exit 2
fi
''';

  static String extractScript({
    required String archivePath,
    required String rootDir,
    required String kind,
  }) {
    const tpl = r'''
ARCHIVE="__ARCHIVE__"
ROOT="__ROOT__"
if [ ! -f "$ARCHIVE" ]; then echo "__SOB_ERR__=archive-missing"; exit 1; fi
rm -rf "$ROOT"
mkdir -p "$ROOT"
__EXTRACT__
if [ ! -e "$ROOT/bin" ] && [ ! -e "$ROOT/etc" ] && [ ! -e "$ROOT/usr" ]; then
  INNER=$(ls -A "$ROOT" 2>/dev/null | head -n 1)
  if [ -n "$INNER" ] && [ -d "$ROOT/$INNER" ]; then
    for f in "$ROOT/$INNER"/* "$ROOT/$INNER"/.[!.]*; do
      [ -e "$f" ] || continue
      mv "$f" "$ROOT/" 2>/dev/null
    done
    rmdir "$ROOT/$INNER" 2>/dev/null
  fi
fi
if [ ! -e "$ROOT/bin" ] && [ ! -e "$ROOT/usr" ] && [ ! -e "$ROOT/etc" ]; then
  echo "__SOB_ERR__=not-a-rootfs"
  exit 1
fi
echo "__SOB_OK__=extracted"
exit 0
''';
    return tpl
        .replaceAll(
            '__ARCHIVE__', DistroDetector.escapeShellDoubleQuoted(archivePath))
        .replaceAll('__ROOT__', DistroDetector.escapeShellDoubleQuoted(rootDir))
        .replaceAll('__EXTRACT__', extractCommand(kind));
  }

  // #SOB-XZ-NATIVE
  /// کانال نیتیو برای دیکود کردن xz روی گوشی (وقتی toybox/busybox ندارند).
  static const MethodChannel _channel =
      MethodChannel('com.sobhan.term/linux_app');

  /// فایل `.tar.xz` را با دیکودر نیتیو (XZInputStream) به `.tar` تبدیل
  /// می‌کند و مسیر فایل tar را برمی‌گرداند. در صورت خطا null.
  static Future<String?> nativeXzToTar(File archive) async {
    try {
      final out = await _channel.invokeMethod<String>(
        'xzDecompress',
        <String, String>{'path': archive.path},
      );
      if (out == null || out.isEmpty) return null;
      final tar = File(out);
      if (!await tar.exists()) return null;
      if (await tar.length() <= 0) return null;
      return out;
    } catch (e) {
      debugPrint('[DistroInstaller] native xz failed: $e');
      return null;
    }
  }

  static Future<bool> acquireLock() async {
    // I3: create atomically with noclobber (`set -C`) instead of the
    // check-then-create sequence, which two callers could both pass.
    const script = 'L=$lockFile; '
        'if [ -f "\$L" ] && [ -n "\$(find "\$L" -mmin +60 2>/dev/null)" ]; '
        'then rm -f "\$L"; fi; '
        'if (set -C; echo ok > "\$L") 2>/dev/null; '
        'then echo "__SOB_LOCK_OK__"; else echo "__SOB_LOCKED__"; fi; exit 0';
    try {
      final r = await Process.run('su', ['-c', script]);
      return r.stdout.toString().contains('__SOB_LOCK_OK__');
    } catch (_) {
      return false;
    }
  }

  static Future<void> releaseLock() async {
    try {
      await Process.run('su', ['-c', 'rm -f $lockFile; exit 0']);
    } catch (_) {}
  }

  /// Max accepted archive size (8 GiB).
  static const int maxDownloadBytes = 8 * 1024 * 1024 * 1024;

  static Future<File> downloadToCache(
    String url,
    String fileName, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final target = File('${dir.path}/$fileName');
    if (await target.exists()) {
      await target.delete();
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    client.autoUncompress = false;
    var ok = false;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'SobhanTerminal/2.0');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} while downloading');
      }
      final total = response.contentLength;
      if (total > maxDownloadBytes) {
        throw HttpException('Archive too large ($total bytes)');
      }
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > maxDownloadBytes) {
            throw const HttpException('Archive exceeds size limit');
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw HttpException('Incomplete download ($received of $total bytes)');
      }
      ok = true;
      return target;
    } finally {
      client.close(force: true);
      if (!ok) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
      }
    }
  }

  /// ONE single `su` round-trip.  For every known distro it verifies that
  /// <rootDir><shell> exists and echoes "<id>:<sizeKb>" (du -sk of the
  /// rootfs).  Returns a map of distroId -> size in *bytes*.
  static Future<Map<String, int>> scanInstalled() async =>
      (await scanInstalledOrNull()) ?? <String, int>{};

  /// Like [scanInstalled] but returns null when the scan itself failed
  /// (su error / non-zero exit), so callers can tell it from "none installed".
  static Future<Map<String, int>?> scanInstalledOrNull() async {
    // #SOB-SCAN-TOLERANT
    // معیار نصب‌بودن «پوستهٔ دقیق» نیست؛ چون آلپاین /bin/bash ندارد و
    // بعضی rootfs ها مسیر پوسته را جابه‌جا می‌کنند. کافی است etc/os-release
    // یا etc به‌همراه یکی از پوسته‌های رایج موجود باشد.
    const tpl = r'''if [ -e "__ROOT__/etc/os-release" ] || { [ -d "__ROOT__/etc" ] && { [ -e "__ROOT__/bin/sh" ] || [ -e "__ROOT__/bin/bash" ] || [ -e "__ROOT__/usr/bin/sh" ] || [ -e "__ROOT__/usr/bin/busybox" ] || [ -e "__ROOT____SHELL__" ]; }; }; then echo "__ID__:$(du -sk "__ROOT__" 2>/dev/null | awk '{print $1}')"; fi''';
    final checks = DistroRegistry.all.map((d) {
      final root = DistroDetector.escapeShellDoubleQuoted(d.rootDir);
      final shell = DistroDetector.escapeShellDoubleQuoted(d.shell);
      return tpl
          .replaceAll('__ROOT__', root)
          .replaceAll('__SHELL__', shell)
          .replaceAll('__ID__', d.id);
    }).join('; ');
    final found = <String, int>{};
    if (checks.isEmpty) return found;
    try {
      final r = await Process.run('su', ['-c', '$checks; exit 0']).timeout(
        const Duration(seconds: 60),
      );
      if (r.exitCode != 0) {
        debugPrint('[DistroInstaller] scan failed: ${r.stderr}');
        return null;
      }
      for (final raw in r.stdout.toString().split('\n')) {
        final line = raw.trim();
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        final id = line.substring(0, idx);
        final kb = int.tryParse(line.substring(idx + 1).trim()) ?? 0;
        if (id.isEmpty) continue;
        found[id] = kb * 1024;
      }
    } catch (e) {
      debugPrint('[DistroInstaller] scan error: $e');
      return null;
    }
    return found;
  }

  // #SOB-UNINSTALL-V2
  /// Removes an installed rootfs.  First every process whose root/exe/cwd
  /// lives inside the rootfs is killed (otherwise bind mounts stay busy),
  /// then every mount under it is discovered dynamically and unmounted
  /// deepest-first (with a lazy-unmount fallback), and finally the directory
  /// is wiped with retries.  It only reports success when the directory is
  /// really gone.
  static Future<bool> uninstall(String id) async {
    final safe = DistroDetector.sanitizeId(id);
    final distro = DistroRegistry.byIdOrNull(id);
    final root = distro?.rootDir ?? DistroRegistry.rootDirFor(safe);
    final login = distro?.loginScript ?? DistroRegistry.loginScriptFor(safe);
    if (!_isSafeRemovalPath(root)) {
      debugPrint('[DistroInstaller] uninstall: refusing unsafe root "$root"');
      return false;
    }
    const tpl = r'''
ROOT="__ROOT__"
LOGIN="__LOGIN__"
cd / || exit 1
case "$ROOT" in
  ""|/|/*/..|*/../*|*/.|/.*|[!/]*) echo "__SOB_OK__=refused"; exit 0 ;;
esac
case "$ROOT" in
  /*/*) ;;
  *) echo "__SOB_OK__=refused"; exit 0 ;;
esac
case "$ROOT" in
  /data|/sdcard|/storage|/system|/vendor|/usr|/etc|/bin|/sbin|/lib|/home|/root|/proc|/dev|/sys|/mnt|/data/data|/data/local|/data/media)
    echo "__SOB_OK__=refused"; exit 0 ;;
esac
SELF=$$
ANCESTORS=" $$ "
pp=$$
while [ -n "$pp" ] && [ "$pp" != "0" ] && [ "$pp" != "1" ]; do
  pp=$(awk '{print $4}' /proc/$pp/stat 2>/dev/null)
  ANCESTORS="$ANCESTORS$pp "
done

kill_tree() {
  HITS=""
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$SELF" ] && continue
    case "$ANCESTORS" in *" $pid "*) continue ;; esac
    [ "$pid" = "1" ] && continue
    r=$(readlink "$p/root" 2>/dev/null)
    e=$(readlink "$p/exe" 2>/dev/null)
    c=$(readlink "$p/cwd" 2>/dev/null)
    hit=0
    case "$r" in "$ROOT"|"$ROOT"/*) hit=1 ;; esac
    case "$e" in "$ROOT"|"$ROOT"/*) hit=1 ;; esac
    case "$c" in "$ROOT"|"$ROOT"/*) hit=1 ;; esac
    if [ "$hit" = "1" ]; then
      kill -TERM "$pid" 2>/dev/null; HITS="$HITS $pid" 2>/dev/null
    fi
  done
  sleep 1
  for pid in $HITS; do
    [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
  done
}

unmount_all() {
  n=0
  while [ "$n" -lt 10 ]; do
    mnts=$(
      { awk -v r="$ROOT" '$2==r || index($2, r"/")==1 {print $2}' /proc/self/mounts 2>/dev/null
        awk -v r="$ROOT" '$2==r || index($2, r"/")==1 {print $2}' /proc/1/mounts 2>/dev/null
        awk -v r="$ROOT" '$2==r || index($2, r"/")==1 {print $2}' /proc/mounts 2>/dev/null
      } | sort -u | awk '{print length($0) " " $0}' | sort -rn | cut -d' ' -f2-
    )
    [ -z "$mnts" ] && break
    for m in $mnts; do
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
    done
    n=$((n + 1))
    sleep 1
  done
}

kill_tree
unmount_all
rm -rf "$ROOT" 2>/dev/null
n=0
while [ -e "$ROOT" ] && [ "$n" -lt 5 ]; do
  kill_tree
  unmount_all
  rm -rf "$ROOT" 2>/dev/null
  n=$((n + 1))
  sleep 1
done
sync 2>/dev/null
rm -f "$LOGIN" 2>/dev/null
# آخرین تلاش: اگر هنوز چیزی مانده، یک‌بار دیگر با unmount اجباری
if [ -e "$ROOT" ]; then
  unmount_all
  rm -rf "$ROOT" 2>/dev/null
  sync 2>/dev/null
fi
if [ -e "$ROOT" ]; then
  echo "__SOB_OK__=failed"
else
  echo "__SOB_OK__=removed"
fi
exit 0
''';
    final script = tpl
        .replaceAll('__ROOT__', DistroDetector.escapeShellDoubleQuoted(root))
        .replaceAll('__LOGIN__', DistroDetector.escapeShellDoubleQuoted(login));
    try {
      final r = await Process.run('su', ['-c', script]).timeout(
        const Duration(minutes: 3),
        onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
      );
      return r.stdout.toString().contains('__SOB_OK__=removed');
    } catch (_) {
      return false;
    }
  }

  // #SOB-NET-SETUP
  /// اینترنت داخل توزیع را بعد از نصب آماده می‌کند:
  /// `/etc/resolv.conf` (DNS)، `/etc/hosts` و `/etc/nsswitch.conf`.
  /// روی همهٔ خانواده‌ها (debian/redhat/alpine/arch/suse) کار می‌کند و
  /// اگر resolv.conf سیم‌لینک باشد (آلپاین) اول حذفش می‌کند.
  static Future<bool> setupNetwork(String rootDir) async {
    const tpl = r'''
R="__ROOT__"
[ -d "$R/etc" ] || mkdir -p "$R/etc" 2>/dev/null
rm -f "$R/etc/resolv.conf" 2>/dev/null
{
  echo "nameserver 8.8.8.8"
  echo "nameserver 8.8.4.4"
  echo "nameserver 1.1.1.1"
  echo "nameserver 9.9.9.9"
  echo "options edns0 timeout:5 attempts:2"
} > "$R/etc/resolv.conf"
chmod 644 "$R/etc/resolv.conf" 2>/dev/null

if [ ! -s "$R/etc/hosts" ]; then
  {
    echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
    echo "127.0.0.1 __HOSTNAME__"
  } > "$R/etc/hosts"
fi
chmod 644 "$R/etc/hosts" 2>/dev/null

if [ ! -s "$R/etc/nsswitch.conf" ]; then
  {
    echo "passwd: files"
    echo "group: files"
    echo "shadow: files"
    echo "hosts: files dns"
    echo "networks: files"
  } > "$R/etc/nsswitch.conf"
fi

# آلپاین و برخی rootfsها /etc/resolv.conf را به /run سیم‌لینک می‌کنند.
if [ -L "$R/etc/resolv.conf" ]; then
  rm -f "$R/etc/resolv.conf"
  echo "nameserver 8.8.8.8" > "$R/etc/resolv.conf"
  echo "nameserver 1.1.1.1" >> "$R/etc/resolv.conf"
fi

mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/tmp" 2>/dev/null
chmod 1777 "$R/tmp" 2>/dev/null
echo "__SOB_NET_OK__"
exit 0
''';
    final script = tpl.replaceAll(
      '__ROOT__',
      DistroDetector.escapeShellDoubleQuoted(rootDir),
    ).replaceAll('__HOSTNAME__', 'localhost');
    try {
      final r = await Process.run('su', ['-c', script]).timeout(
        const Duration(seconds: 30),
        onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
      );
      return r.stdout.toString().contains('__SOB_NET_OK__');
    } catch (_) {
      return false;
    }
  }

  static bool _isSafeRemovalPath(String p) {
    if (!p.startsWith('/') || p.contains('\n') || p.contains('\x00')) {
      return false;
    }
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return false;
    if (parts.any((s) => s == '.' || s == '..')) return false;
    return true;
  }

  static Future<bool> persistAll() async {
    final payload = DistroRegistry.customToJson();
    if (payload.contains('SOB_DISTROS_EOF')) return false;
    final script = "T=$manifestFile.tmp; "
        "cat > \"\$T\" << 'SOB_DISTROS_EOF' && mv -f \"\$T\" $manifestFile && echo __SOB_PERSIST_OK__\n"
        '$payload\n'
        'SOB_DISTROS_EOF\n'
        'exit 0';
    try {
      final r = await Process.run('su', ['-c', script]).timeout(
        const Duration(seconds: 30),
        onTimeout: () => ProcessResult(0, 1, '', 'timeout'),
      );
      final ok = r.stdout.toString().contains('__SOB_PERSIST_OK__');
      if (!ok) debugPrint('[DistroInstaller] persistAll failed: ${r.stderr}');
      return ok;
    } catch (e) {
      debugPrint('[DistroInstaller] persistAll error: $e');
      return false;
    }
  }

  static Future<void> loadPersisted() async {
    const script = 'M=$manifestFile; '
        'if [ -f "\$M" ]; then echo "__SOB_JSON_BEGIN__"; cat "\$M"; echo; '
        'echo "__SOB_JSON_END__"; fi; exit 0';
    try {
      final r = await Process.run('su', ['-c', script]);
      final out = r.stdout.toString();
      final start = out.indexOf('__SOB_JSON_BEGIN__');
      final end = out.indexOf('__SOB_JSON_END__');
      if (start < 0 || end <= start) return;
      final body =
          out.substring(start + '__SOB_JSON_BEGIN__'.length, end).trim();
      DistroRegistry.loadCustomFromJson(body);
    } catch (_) {}
  }

  static Future<DistroInstallResult> installFromUrl({
    required String url,
    String? nameHint,
    void Function(String message)? onLog,
    void Function(int received, int total)? onProgress,
  }) async {
    void log(String message) => onLog?.call(message);

    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const DistroInstallResult(ok: false, message: 'URL is empty.');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const DistroInstallResult(
          ok: false, message: 'Only http(s) URLs are supported.');
    }
    final kind = archiveKind(trimmed);
    if (kind == null) {
      return const DistroInstallResult(
          ok: false,
          message: 'Unsupported archive: use .tar.gz, .tar.xz, .tar.bz2, '
              '.tar.zst, .tar or .zip (raw .img/.raw is not supported).');
    }

    var id = DistroDetector.sanitizeId(nameHint ?? '', fallback: '');
    if (id.isEmpty) id = DistroDetector.idFromUrl(trimmed);
    if (id.isEmpty) id = 'custom';

    final rootDir = DistroRegistry.rootDirFor(id);

    if (!await acquireLock()) {
      return const DistroInstallResult(
          ok: false, message: 'Another install is already running.');
    }
    try {
      log('Downloading $id ...');
      final archive = await downloadToCache(
        trimmed,
        '$id.${suffixFor(kind)}',
        onProgress: onProgress,
      );
      log('Extracting into $rootDir ...');
      var extractOut = await _runExtract(archive.path, rootDir, kind);
      if (!extractOut.contains('__SOB_OK__=extracted') &&
          kind == 'xz' &&
          extractOut.contains('__SOB_ERR__=no-xz')) {
        // #SOB-XZ-NATIVE-FALLBACK
        log('No xz on device — using the built-in decoder ...');
        final tarPath = await nativeXzToTar(archive);
        if (tarPath == null) {
          return const DistroInstallResult(
              ok: false,
              message: 'Extraction failed: this phone has no xz decoder '
                  'and the built-in decoder failed.');
        }
        extractOut = await _runExtract(tarPath, rootDir, 'tar');
        try {
          await File(tarPath).delete();
        } catch (_) {}
      }
      if (!extractOut.contains('__SOB_OK__=extracted')) {
        // #SOB-CLEAN-FAILED: پوشهٔ نیمه‌کاره نماند.
        try {
          await Process.run('su', [
            '-c',
            'rm -rf "${DistroDetector.escapeShellDoubleQuoted(rootDir)}"',
          ]);
        } catch (_) {}
        return DistroInstallResult(
            ok: false, message: 'Extraction failed: ${_lastError(extractOut)}');
      }
      try {
        await archive.delete();
      } catch (_) {}

      log('Setting up network (DNS) ...');
      if (!await setupNetwork(rootDir)) {
        log('Warning: could not write /etc/resolv.conf inside the distro.');
      }

      log('Detecting distribution ...');
      final probeResult = await Process.run('su', ['-c', DistroDetector.probeScript(rootDir)]);
      final probe = DistroDetector.parseProbe(probeResult.stdout.toString());
      final detection = DistroDetector.fromOsRelease(
        probe.osReleaseText,
        shellHint: probe.shell,
        packageManagerHint: probe.packageManager,
        idHint: id,
        labelHint: nameHint,
      );
      final distro = DistroDetector.buildDistro(detection);
      DistroRegistry.registerCustom(distro);
      if (!await persistAll()) {
        log('Warning: could not save the distro list; it may be lost after restart.');
      }
      log('Installed ${distro.label} (${distro.id}) at ${distro.rootDir}');
      return DistroInstallResult(
          ok: true, message: 'Installed ${distro.label}', distro: distro);
    } catch (e) {
      return DistroInstallResult(ok: false, message: 'Install failed: $e');
    } finally {
      await releaseLock();
    }
  }

  /// اجرای اسکریپت استخراج و برگرداندن خروجی ترکیبی.
  static Future<String> _runExtract(
    String archivePath,
    String rootDir,
    String kind,
  ) async {
    try {
      final r = await Process.run('su', [
        '-c',
        extractScript(
            archivePath: archivePath, rootDir: rootDir, kind: kind),
      ]).timeout(const Duration(minutes: 20));
      return '${r.stdout}\n${r.stderr}';
    } catch (e) {
      return '__SOB_ERR__=$e';
    }
  }

  static String _lastError(String output) {
    for (final line in output.split('\n')) {
      final marker = line.indexOf('__SOB_ERR__=');
      if (marker >= 0) {
        return line.substring(marker + '__SOB_ERR__='.length).trim();
      }
    }
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.isEmpty ? 'unknown error' : lines.last;
  }
}
