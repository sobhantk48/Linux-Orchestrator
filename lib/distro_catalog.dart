import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One downloadable distro entry of the remote catalog.
class DistroLink {
  const DistroLink({
    required this.id,
    required this.url,
    this.sizeBytes = 0,
    this.version = '',
  });

  final String id;
  final String url;
  final int sizeBytes;
  final String version;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'size': sizeBytes,
        'version': version,
      };

  static DistroLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final id = map['id'];
    final url = map['url'];
    if (id is! String || id.trim().isEmpty) return null;
    if (url is! String || url.trim().isEmpty) return null;
    final rawSize = map['size'];
    final size = rawSize is int ? rawSize : int.tryParse('$rawSize') ?? 0;
    final rawVer = map['version'];
    return DistroLink(
      id: id.trim().toLowerCase(),
      url: url.trim(),
      sizeBytes: size,
      version: rawVer is String ? rawVer.trim() : '',
    );
  }
}

/// Keeps the download links of the distros that are not bundled.
///
/// Links are shipped inside the app as a built in table and can be replaced
/// at runtime by a remote JSON manifest, so the catalog can be updated
/// without publishing a new release. The last fetched manifest is cached on
/// disk and reused when the network is unavailable.
///
/// آدرس‌هایی که «نسخه» در مسیرشان هست (اسنپ‌شات‌های تاریخ‌دارِ
/// images.linuxcontainers.org و پوشهٔ نسخه‌های Kali NetHunter) به‌صورت
/// داینامیک حل می‌شوند: فهرست پوشه خوانده می‌شود و جدیدترین نسخه انتخاب
/// می‌شود، تا با هر بار پاک‌شدنِ اسنپ‌شاتِ قدیمی روی سرور، لینک نشکند.
/// نتیجه در دیسک کش می‌شود و اگر شبکه نبود، آخرین مقدارِ سالم استفاده
/// می‌شود (و در نهایت لینکِ ثابتِ داخلی).
class DistroCatalog {
  const DistroCatalog._();

  /// Remote manifest: a JSON array of objects shaped like
  /// id / url / size / version. See [DistroLink].
  static const String manifestUrl =
      'https://raw.githubusercontent.com/sobhan-term/distro-catalog/main/catalog.json';

  static const String _cacheName = 'distro_catalog.json';
  static const String _resolvedCacheName = 'distro_resolved.json';

  /// Built in links. Every URL is a direct archive of a rootfs for arm64
  /// (aarch64). They are only used when the remote manifest has no entry and
  /// the dynamic resolution could not run.
  static const Map<String, String> _builtinUrls = <String, String>{
    'alpine':
        'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz',
    'kali':
        'https://artifacts.kali.org/images-nethunter/nethunter-fs/kali-2026.3/kali-nethunter-2026.3-rootfs-minimal-arm64.tar.xz',
    'debian':
        'https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20261106_05%3A24/rootfs.tar.xz',
    'fedora':
        'https://images.linuxcontainers.org/images/fedora/44/arm64/default/20261105_20%3A33/rootfs.tar.xz',
    'arch':
        'https://geo.mirror.pkgbuild.com/images/latest/ArchLinuxARM-aarch64-latest.tar.gz',
  };

  static const Map<String, int> _builtinSizes = <String, int>{
    'alpine': 3 * 1024 * 1024,
    'kali': 125846088,
    'debian': 90404996,
    'fedora': 93331624,
    'arch': 210 * 1024 * 1024,
  };

  // #SOB-DYN-RELEASE
  /// پوشهٔ پایهٔ نسخه‌ها روی linuxcontainers.org (نسخه داینامیک پیدا می‌شود).
  static const Map<String, String> _releaseBases = <String, String>{
    'debian': 'https://images.linuxcontainers.org/images/debian/',
    'fedora': 'https://images.linuxcontainers.org/images/fedora/',
  };

  /// ترتیب ترجیح نسخه‌ها. برای دبیان لازم است چون هر سه نسخه
  /// (trixie/bookworm/forky) تاریخ اسنپ‌شات یکسانی دارند و «جدیدترین
  /// تاریخ» نمی‌تواند بین‌شان تفکیک کند.
  static const Map<String, List<String>> _releasePreference =
      <String, List<String>>{
    'debian': <String>['trixie', 'bookworm', 'forky', 'sid'],
    'fedora': <String>[],
  };

  /// فالبک آفلاین وقتی فهرست سرور در دسترس نیست.
  static const Map<String, List<String>> _fallbackReleases =
      <String, List<String>>{
    'debian': <String>['trixie', 'bookworm'],
    'fedora': <String>['44', '43'],
  };

  /// فهرستِ پوشهٔ نسخه‌های Kali NetHunter rootfs.
  static const String _kaliIndex =
      'https://artifacts.kali.org/images-nethunter/nethunter-fs/';

  /// نامِ فایلِ rootfs سبکِ NetHunter برای arm64.
  static const String _kaliSuffix = '-rootfs-minimal-arm64.tar.xz';

  static final Map<String, DistroLink> _live = <String, DistroLink>{};

  /// لینک‌های حل‌شدهٔ داینامیک (id → link).
  static final Map<String, DistroLink> _resolved = <String, DistroLink>{};

  static bool _loaded = false;

  static Future<File> _cacheFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File(dir.path + Platform.pathSeparator + name);
  }

  /// Reads the cached manifest. Safe to call many times.
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _cacheFile(_cacheName);
      if (await file.exists()) {
        _merge(await file.readAsString());
      }
    } catch (e) {
      debugPrint('[DistroCatalog] cache read failed: $e');
    }
    try {
      final file = await _cacheFile(_resolvedCacheName);
      if (await file.exists()) {
        _mergeResolved(await file.readAsString());
      }
    } catch (e) {
      debugPrint('[DistroCatalog] resolved cache read failed: $e');
    }
  }

  /// Downloads the remote manifest, refreshes the dynamic links and caches
  /// them. Returns true when at least one of the two steps succeeded.
  static Future<bool> refresh() async {
    var manifestOk = false;
    try {
      final body = await _httpGet(manifestUrl);
      if (body != null && body.trim().isNotEmpty) {
        final count = _merge(body);
        if (count > 0) {
          manifestOk = true;
          try {
            final file = await _cacheFile(_cacheName);
            await file.writeAsString(body);
          } catch (e) {
            debugPrint('[DistroCatalog] cache write failed: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('[DistroCatalog] refresh failed: $e');
    }
    final resolveOk = await _refreshDynamic();
    return manifestOk || resolveOk;
  }

  /// جدیدترین نسخهٔ لینک‌های داینامیک را پیدا و کش می‌کند.
  static Future<bool> _refreshDynamic() async {
    var changed = false;
    for (final entry in _releaseBases.entries) {
      try {
        final release = await _resolveRelease(entry.key);
        if (release == null) continue;
        final index = '${entry.value}$release/arm64/default/';
        final url = await _resolveSnapshot(index);
        if (url == null) continue;
        _resolved[entry.key] = DistroLink(
          id: entry.key,
          url: url,
          sizeBytes: await _headSize(url) ?? (_builtinSizes[entry.key] ?? 0),
          version: release,
        );
        changed = true;
      } catch (e) {
        debugPrint('[DistroCatalog] release resolve failed (${entry.key}): $e');
      }
    }
    try {
      final kali = await _resolveKali();
      if (kali != null) {
        _resolved['kali'] = kali;
        changed = true;
      }
    } catch (e) {
      debugPrint('[DistroCatalog] kali resolve failed: $e');
    }
    if (changed) {
      try {
        final file = await _cacheFile(_resolvedCacheName);
        final list = _resolved.values.map((l) => l.toJson()).toList();
        await file.writeAsString(jsonEncode(list));
      } catch (e) {
        debugPrint('[DistroCatalog] resolved cache write failed: $e');
      }
    }
    return changed;
  }

  /// پوشهٔ نسخه‌ها را می‌خواند و مناسب‌ترین نسخه را برمی‌گرداند.
  /// اولویت: ترتیب ترجیح → بیشترین شمارهٔ نسخه → فالبک آفلاین.
  static Future<String?> _resolveRelease(String id) async {
    final base = _releaseBases[id];
    if (base == null) return null;
    final releases = <String>[];
    final html = await _httpGet(base);
    if (html != null) {
      for (final m
          in RegExp(r'href="([a-z0-9][a-z0-9._-]*)/"').allMatches(html)) {
        final r = m.group(1)!;
        if (r == '.' || r == '..') continue;
        if (!releases.contains(r)) releases.add(r);
      }
    }
    final pref = _releasePreference[id] ?? const <String>[];
    for (final p in pref) {
      if (releases.contains(p)) return p;
    }
    final numeric = releases
        .where((r) => RegExp(r'^\d+$').hasMatch(r))
        .toList()
      ..sort((a, b) => int.parse(a) - int.parse(b));
    if (numeric.isNotEmpty) return numeric.last;
    final fb = _fallbackReleases[id] ?? const <String>[];
    for (final f in fb) {
      if (releases.isEmpty || releases.contains(f)) return f;
    }
    return null;
  }

  /// فهرستِ پوشهٔ اسنپ‌شات را می‌خواند و آدرسِ جدیدترین تاریخ را می‌سازد.
  static Future<String?> _resolveSnapshot(String index) async {
    final html = await _httpGet(index);
    if (html == null) return null;
    final dates = <String>{};
    for (final m in RegExp(r'href="(\d{8}_\d{2}(?:%3A|:)\d{2})/"').allMatches(html)) {
      dates.add(m.group(1)!.replaceAll(':', '%3A'));
    }
    if (dates.isEmpty) return null;
    final sorted = dates.toList()..sort();
    return '$index${sorted.last}/rootfs.tar.xz';
  }

  /// جدیدترین پوشهٔ نسخهٔ Kali را پیدا و فایلِ rootfs سبک را برمی‌گرداند.
  static Future<DistroLink?> _resolveKali() async {
    final html = await _httpGet(_kaliIndex);
    if (html == null) return null;
    String? best;
    for (final m in RegExp(r'href="(kali-(\d{4})\.(\d+))/"').allMatches(html)) {
      final dir = m.group(1)!;
      if (best == null || _cmpVer(dir, best) > 0) best = dir;
    }
    if (best == null) return null;
    final listing = await _httpGet('$_kaliIndex$best/');
    if (listing == null) return null;
    final fre = RegExp('href="([^"]*${RegExp.escape(_kaliSuffix)})"');
    final fm = fre.firstMatch(listing);
    if (fm == null) return null;
    final url = '$_kaliIndex$best/${fm.group(1)!}';
    return DistroLink(
      id: 'kali',
      url: url,
      sizeBytes: await _headSize(url) ?? (_builtinSizes['kali'] ?? 0),
      version: best,
    );
  }

  /// مقایسهٔ نسخه‌های `kali-YYYY.N`.
  static int _cmpVer(String a, String b) {
    final pa = RegExp(r'(\d{4})\.(\d+)').firstMatch(a);
    final pb = RegExp(r'(\d{4})\.(\d+)').firstMatch(b);
    if (pa == null || pb == null) return a.compareTo(b);
    final ya = int.parse(pa.group(1)!);
    final yb = int.parse(pb.group(1)!);
    if (ya != yb) return ya - yb;
    return int.parse(pa.group(2)!) - int.parse(pb.group(2)!);
  }

  static int _merge(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return 0;
      var added = 0;
      for (final item in decoded) {
        final link = DistroLink.fromJson(item);
        if (link == null) continue;
        _live[link.id] = link;
        added++;
      }
      return added;
    } catch (e) {
      debugPrint('[DistroCatalog] manifest parse failed: $e');
      return 0;
    }
  }

  static int _mergeResolved(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return 0;
      var added = 0;
      for (final item in decoded) {
        final link = DistroLink.fromJson(item);
        if (link == null) continue;
        _resolved[link.id] = link;
        added++;
      }
      return added;
    } catch (e) {
      debugPrint('[DistroCatalog] resolved parse failed: $e');
      return 0;
    }
  }

  static Future<String?> _httpGet(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'SobhanTerminal/2.0');
      final res = await req.close();
      if (res.statusCode != 200) {
        debugPrint('[DistroCatalog] HTTP ${res.statusCode} for $url');
        return null;
      }
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  /// اندازهٔ فایل از هدرِ Content-Length (خطا → null).
  static Future<int?> _headSize(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.headUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'SobhanTerminal/2.0');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final len = res.contentLength;
      return len > 0 ? len : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Download link for [id], or null when the distro must be bundled.
  static String? urlFor(String id) {
    final key = id.toLowerCase().trim();
    final live = _live[key];
    if (live != null && live.url.isNotEmpty) return live.url;
    final resolved = _resolved[key];
    if (resolved != null && resolved.url.isNotEmpty) return resolved.url;
    return _builtinUrls[key];
  }

  /// کامل‌ترین اطلاعات لینک دانلود برای [id] (یا null اگر لینکی نباشد).
  static DistroLink? linkFor(String id) {
    final key = id.toLowerCase().trim();
    final live = _live[key];
    if (live != null && live.url.isNotEmpty) return live;
    final resolved = _resolved[key];
    if (resolved != null && resolved.url.isNotEmpty) return resolved;
    final builtin = _builtinUrls[key];
    if (builtin == null || builtin.isEmpty) return null;
    return DistroLink(
      id: key,
      url: builtin,
      sizeBytes: _builtinSizes[key] ?? 0,
    );
  }
}
