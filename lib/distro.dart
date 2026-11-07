import 'dart:convert';

import 'package:flutter/material.dart';

/// Families only matter for the package manager used by the installer.
enum DistroFamily { debian, redhat, suse, arch, alpine, generic }

/// A Linux distribution preset.
///
/// [rootDir] / [loginScript] are explicit (not derived) so that the original
/// Ubuntu layout (`/data/ubuntu`, `/data/ubuntu-login.sh`) is preserved
/// byte-for-byte for existing installs, while new distros live under
/// `/data/rootfs/<id>`.
class Distro {
  const Distro({
    required this.id,
    required this.label,
    required this.family,
    required this.rootDir,
    required this.loginScript,
    required this.shell,
    this.bundledAsset,
    this.defaultUrl,
    this.packageManager,
    this.accent = const Color(0xFF00E676),
    this.isCustom = false,
  });

  final String id;
  final String label;
  final DistroFamily family;
  final String rootDir;
  final String loginScript;
  final String shell;
  final String? bundledAsset;
  final String? defaultUrl;
  final String? packageManager;
  final Color accent;

  /// True when the distro was registered from a user supplied RootFS archive.
  final bool isCustom;

  Distro copyWith({
    String? label,
    DistroFamily? family,
    String? rootDir,
    String? loginScript,
    String? shell,
    String? bundledAsset,
    String? defaultUrl,
    String? packageManager,
    Color? accent,
    bool? isCustom,
  }) {
    return Distro(
      id: id,
      label: label ?? this.label,
      family: family ?? this.family,
      rootDir: rootDir ?? this.rootDir,
      loginScript: loginScript ?? this.loginScript,
      shell: shell ?? this.shell,
      bundledAsset: bundledAsset ?? this.bundledAsset,
      defaultUrl: defaultUrl ?? this.defaultUrl,
      packageManager: packageManager ?? this.packageManager,
      accent: accent ?? this.accent,
      isCustom: isCustom ?? this.isCustom,
    );
  }

  /// Only portable fields are persisted; [accent] is recomputed from the id
  /// by [DistroRegistry.accentFor] so no `Color` encoding is required.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'family': family.name,
        'rootDir': rootDir,
        'loginScript': loginScript,
        'shell': shell,
        'bundledAsset': bundledAsset,
        'defaultUrl': defaultUrl,
        'packageManager': packageManager,
        'isCustom': isCustom,
      };

  static DistroFamily familyFromName(String? name) {
    for (final f in DistroFamily.values) {
      if (f.name == name) return f;
    }
    return DistroFamily.generic;
  }

  static Distro? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final rawId = map['id'];
    if (rawId is! String || rawId.trim().isEmpty) return null;
    final id = rawId.trim();
    // D5: reject ids that could cause path traversal
    if (!DistroRegistry.isValidId(id)) return null;
    final rawLabel = map['label'];
    final label = rawLabel is String && rawLabel.trim().isNotEmpty
        ? rawLabel.trim()
        : DistroRegistry.labelFor(id);
    final rawRoot = map['rootDir'];
    final rootDir = rawRoot is String && rawRoot.trim().isNotEmpty
        ? rawRoot.trim()
        : DistroRegistry.rootDirFor(id);
    final rawLogin = map['loginScript'];
    final loginScript = rawLogin is String && rawLogin.trim().isNotEmpty
        ? rawLogin.trim()
        : DistroRegistry.loginScriptFor(id);
    final rawShell = map['shell'];
    final shell = rawShell is String && rawShell.trim().isNotEmpty
        ? rawShell.trim()
        : '/bin/sh';
    final rawPm = map['packageManager'];
    final packageManager =
        rawPm is String && rawPm.trim().isNotEmpty ? rawPm.trim() : null;
    final rawFamily = map['family'];
    final rawBundled = map['bundledAsset'];
    final bundledAsset = rawBundled is String && rawBundled.trim().isNotEmpty
        ? rawBundled.trim()
        : null;
    final rawUrl = map['defaultUrl'];
    final defaultUrl =
        rawUrl is String && rawUrl.trim().isNotEmpty ? rawUrl.trim() : null;
    return Distro(
      id: id,
      label: label,
      family: familyFromName(rawFamily is String ? rawFamily : null),
      rootDir: rootDir,
      loginScript: loginScript,
      shell: shell,
      bundledAsset: bundledAsset,
      defaultUrl: defaultUrl,
      packageManager: packageManager,
      accent: DistroRegistry.accentFor(id),
      isCustom: map['isCustom'] == true,
    );
  }
}

class DistroRegistry {
  const DistroRegistry._();

  static const Distro ubuntu = Distro(
    id: 'ubuntu',
    label: 'Ubuntu',
    family: DistroFamily.debian,
    rootDir: '/data/ubuntu',
    loginScript: '/data/ubuntu-login.sh',
    shell: '/bin/bash',
    bundledAsset: 'assets/rootfs/ubuntu-base-arm64.tar.gz',
    packageManager: 'apt-get',
    accent: Color(0xFFE95420),
  );

  static const Distro kali = Distro(
    id: 'kali',
    label: 'Kali Linux',
    family: DistroFamily.debian,
    rootDir: '/data/rootfs/kali',
    loginScript: '/data/login-kali.sh',
    shell: '/bin/bash',
    packageManager: 'apt-get',
    accent: Color(0xFF557C94),
  );

  static const Distro fedora = Distro(
    id: 'fedora',
    label: 'Fedora',
    family: DistroFamily.redhat,
    rootDir: '/data/rootfs/fedora',
    loginScript: '/data/login-fedora.sh',
    shell: '/bin/bash',
    packageManager: 'dnf',
    accent: Color(0xFF51A2DA),
  );

  static const Distro debian = Distro(
    id: 'debian',
    label: 'Debian',
    family: DistroFamily.debian,
    rootDir: '/data/rootfs/debian',
    loginScript: '/data/login-debian.sh',
    shell: '/bin/bash',
    packageManager: 'apt-get',
    accent: Color(0xFFD70A53),
  );

  static const Distro alpine = Distro(
    id: 'alpine',
    label: 'Alpine',
    family: DistroFamily.alpine,
    rootDir: '/data/rootfs/alpine',
    loginScript: '/data/login-alpine.sh',
    shell: '/bin/sh',
    packageManager: 'apk',
    accent: Color(0xFF0D597F),
  );

  static const List<Distro> _builtins = <Distro>[
    ubuntu,
    kali,
    fedora,
    debian,
    alpine,
  ];

  static final List<Distro> _custom = <Distro>[];

  static const Distro defaultDistro = ubuntu;

  /// Every known distro: bundled presets first, user installed ones after.
  static List<Distro> get all => <Distro>[..._builtins, ..._custom];

  static List<Distro> get custom => List<Distro>.unmodifiable(_custom);

  /// #SOB-BUILTINS
  /// توزیع‌های داخلی همیشه در لیست نمایش داده می‌شوند (نصب‌شده یا نه).
  static List<Distro> get builtins => List<Distro>.unmodifiable(_builtins);

  static String rootDirFor(String id) => '/data/rootfs/$id';

  static String loginScriptFor(String id) => '/data/login-$id.sh';

  /// D5: only allow ids that are safe to embed in filesystem paths.
  static bool isValidId(String id) {
    if (id.isEmpty || id.length > 64) return false;
    if (id == '.' || id == '..') return false;
    if (id.contains('/') || id.contains('\\') || id.contains('..')) {
      return false;
    }
    return RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(id);
  }

  static Distro? byIdOrNull(String id) {
    for (final d in _builtins) {
      if (d.id == id) return d;
    }
    for (final d in _custom) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// D3: prefer [byIdOrNull] when a nullable result is needed.
  static Distro byId(String id) {
    final found = byIdOrNull(id);
    if (found == null) {
      debugPrint(
          '[DistroRegistry] byId("$id") not found — falling back to ubuntu');
    }
    return found ?? defaultDistro;
  }

  /// D4 + D5: rejects invalid ids and ids that shadow built-ins.
  /// Returns true if accepted.
  static bool registerCustom(Distro distro) {
    if (!isValidId(distro.id)) {
      debugPrint(
          '[DistroRegistry] registerCustom: invalid id "${distro.id}" — rejected');
      return false;
    }
    if (_builtins.any((d) => d.id == distro.id)) {
      debugPrint(
          '[DistroRegistry] registerCustom: "${distro.id}" conflicts with a built-in — rejected');
      return false;
    }
    _custom.removeWhere((d) => d.id == distro.id);
    _custom.add(distro);
    return true;
  }

  static void unregisterCustom(String id) {
    _custom.removeWhere((d) => d.id == id);
  }

  static void loadCustomFromJson(String raw) {
    if (raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final distro = Distro.fromJson(item);
        if (distro != null) registerCustom(distro);
      }
    } catch (e, st) {
      debugPrint('[DistroRegistry] loadCustomFromJson error: $e\n$st');
    }
  }

  static String customToJson() =>
      jsonEncode(_custom.map((d) => d.toJson()).toList());

  static const Map<String, String> _labels = <String, String>{
    'ubuntu': 'Ubuntu',
    'kali': 'Kali Linux',
    'fedora': 'Fedora',
    'debian': 'Debian',
    'alpine': 'Alpine',
    'arch': 'Arch Linux',
    'archlinux': 'Arch Linux',
    'blackarch': 'BlackArch',
    'manjaro': 'Manjaro',
    'endeavouros': 'EndeavourOS',
    'garuda': 'Garuda Linux',
    'opensuse': 'openSUSE',
    'opensuse-leap': 'openSUSE Leap',
    'opensuse-tumbleweed': 'openSUSE Tumbleweed',
    'suse': 'SUSE',
    'sles': 'SUSE Linux Enterprise',
    'centos': 'CentOS',
    'rocky': 'Rocky Linux',
    'almalinux': 'AlmaLinux',
    'rhel': 'Red Hat Enterprise Linux',
    'oracle': 'Oracle Linux',
    'amzn': 'Amazon Linux',
    'void': 'Void Linux',
    'gentoo': 'Gentoo',
    'nixos': 'NixOS',
    'parrot': 'Parrot OS',
    'linuxmint': 'Linux Mint',
    'pop': 'Pop!_OS',
    'devuan': 'Devuan',
    'raspbian': 'Raspbian',
    'solus': 'Solus',
    'slackware': 'Slackware',
    'photon': 'Photon OS',
    'postmarketos': 'postmarketOS',
  };

  static const Map<String, Color> _accents = <String, Color>{
    'ubuntu': Color(0xFFE95420),
    'kali': Color(0xFF557C94),
    'fedora': Color(0xFF51A2DA),
    'debian': Color(0xFFD70A53),
    'alpine': Color(0xFF0D597F),
    'arch': Color(0xFF1793D1),
    'archlinux': Color(0xFF1793D1),
    'blackarch': Color(0xFFB71C1C),
    'manjaro': Color(0xFF35BF5C),
    'opensuse': Color(0xFF73BA25),
    'centos': Color(0xFF932279),
    'rocky': Color(0xFF10B981),
    'almalinux': Color(0xFF1B9E4B),
    'void': Color(0xFF478061),
    'gentoo': Color(0xFF54487A),
    'nixos': Color(0xFF5277C3),
    'parrot': Color(0xFF00B4E6),
    'linuxmint': Color(0xFF87CF3E),
  };

  /// Human readable name for an unknown id ("black-arch" -> "Black Arch").
  static String labelFor(String id) {
    final key = id.toLowerCase().trim();
    final known = _labels[key];
    if (known != null) return known;
    final parts = key
        .split(RegExp(r'[^a-z0-9]+'))
        .where((p) => p.isNotEmpty)
        .map((p) =>
            p.length == 1 ? p.toUpperCase() : '${p[0].toUpperCase()}${p.substring(1)}')
        .toList();
    return parts.isEmpty ? id : parts.join(' ');
  }

  /// Deterministic accent colour: a curated palette when known, otherwise a
  /// stable hash derived hue so every distro keeps its own colour.
  static Color accentFor(String id) {
    final key = id.toLowerCase().trim();
    final known = _accents[key];
    if (known != null) return known;
    var hash = 0;
    for (final rune in key.runes) {
      hash = (hash * 31 + rune) & 0x7FFFFFFF;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, 0.52).toColor();
  }
}
