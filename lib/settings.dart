import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'rtl_terminal.dart';

// ---------------------------------------------------------------------------
// فاز K2 — تنظیمات پایدار: اندازهٔ فونت، اسکرول‌بک و تم رنگی.
// مقادیر به‌صورت JSON در Application Support ذخیره می‌شوند (بدون پکیج جدید).
// ---------------------------------------------------------------------------

class TerminalSettings {
  final double fontSize;
  final int scrollback;
  final double lineHeight;
  final String themeId;
  // SOB-GPU-TOGGLE: شتاب گرافیکی VirGL (خاموش = رندر نرم/llvmpipe).
  final bool gpuAccel;
  // SOB-USER: نام کاربری لینوکس (خالی = هنوز انتخاب نشده).
  final String username;
  // SOB-FIRSTRUN: اولین اجرا → پرسیدن توزیع از کاربر.
  final bool firstRun;

  const TerminalSettings({
    this.fontSize = 13.0,
    this.scrollback = 2000,
    this.lineHeight = 1.2,
    this.themeId = 'classic',
    this.gpuAccel = true,
    this.username = '',
    this.firstRun = true,
  });

  TerminalSettings copyWith({
    double? fontSize,
    int? scrollback,
    double? lineHeight,
    String? themeId,
    bool? gpuAccel,
    String? username,
    bool? firstRun,
  }) =>
      TerminalSettings(
        fontSize: fontSize ?? this.fontSize,
        scrollback: scrollback ?? this.scrollback,
        lineHeight: lineHeight ?? this.lineHeight,
        themeId: themeId ?? this.themeId,
        gpuAccel: gpuAccel ?? this.gpuAccel,
        username: username ?? this.username,
        firstRun: firstRun ?? this.firstRun,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'fontSize': fontSize,
        'scrollback': scrollback,
        'lineHeight': lineHeight,
        'themeId': themeId,
        'gpuAccel': gpuAccel,
        'username': username,
        'firstRun': firstRun,
      };

  static TerminalSettings fromJson(Map<String, Object?> j) {
    double asDouble(Object? v, double fallback) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    int asInt(Object? v, int fallback) {
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    bool asBool(Object? v, bool fallback) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final String s = v.trim().toLowerCase();
        if (s == 'true' || s == '1' || s == 'yes' || s == 'on') return true;
        if (s == 'false' || s == '0' || s == 'no' || s == 'off') return false;
      }
      return fallback;
    }

    final double fs = asDouble(j['fontSize'], 13.0).clamp(8.0, 32.0).toDouble();
    final double lh = asDouble(j['lineHeight'], 1.2).clamp(0.8, 2.0).toDouble();
    final int sb = asInt(j['scrollback'], 2000).clamp(200, 50000).toInt();
    final String raw =
        j['themeId'] is String ? (j['themeId'] as String) : 'classic';
    final String id =
        kTerminalThemes.any((TerminalThemePreset t) => t.id == raw)
            ? raw
            : 'classic';
    final bool gpu = asBool(j['gpuAccel'], true);
    final Object? rawUser = j['username'];
    final String uname = rawUser is String
        ? rawUser.trim().toLowerCase()
        : '';
    // اگر فایل تنظیمات از نسخهٔ قدیمی باشد، پیش‌فرض false است.
    final bool firstRun = asBool(j['firstRun'], false);
    return TerminalSettings(
      fontSize: fs,
      scrollback: sb,
      lineHeight: lh,
      themeId: id,
      gpuAccel: gpu,
      username: uname,
      firstRun: firstRun,
    );
  }
}

/// یک تم آمادهٔ ترمینال؛ رنگ‌ها به‌صورت int (ARGB) نگه داشته می‌شوند.
class TerminalThemePreset {
  final String id;
  final String label;
  final int background;
  final int foreground;
  final int cursor;
  final List<int>? palette;

  const TerminalThemePreset({
    required this.id,
    required this.label,
    required this.background,
    required this.foreground,
    required this.cursor,
    this.palette,
  });

  RtlTerminalTheme build(TerminalSettings s) => RtlTerminalTheme(
        background: Color(background),
        foreground: Color(foreground),
        cursor: Color(cursor),
        fontSize: s.fontSize,
        fontFamily: 'monospace',
        lineHeight: s.lineHeight,
        palette: palette == null
            ? kTerminalPalette
            : palette!
                .map((int e) => Color(e))
                .toList(growable: false),
      );
}

const List<TerminalThemePreset> kTerminalThemes = <TerminalThemePreset>[
  TerminalThemePreset(
    id: 'classic',
    label: 'کلاسیک',
    background: 0xFF000000,
    foreground: 0xFFEEEEEE,
    cursor: 0xFF00FF66,
  ),
  TerminalThemePreset(
    id: 'midnight',
    label: 'نیمه‌شب',
    background: 0xFF0B1021,
    foreground: 0xFFD0D8F0,
    cursor: 0xFF7AA2F7,
  ),
  TerminalThemePreset(
    id: 'solarized',
    label: 'سولاریز',
    background: 0xFF002B36,
    foreground: 0xFF93A1A1,
    cursor: 0xFFB58900,
  ),
  TerminalThemePreset(
    id: 'amber',
    label: 'کهربایی',
    background: 0xFF160C00,
    foreground: 0xFFFFB000,
    cursor: 0xFFFFD166,
  ),
  TerminalThemePreset(
    id: 'ice',
    label: 'یخی',
    background: 0xFF071A1F,
    foreground: 0xFFCDEFF5,
    cursor: 0xFF29B8DB,
  ),
  TerminalThemePreset(
    id: 'light',
    label: 'روشن',
    background: 0xFFF7F7F2,
    foreground: 0xFF1B1B1B,
    cursor: 0xFF1B6AC9,
  ),
];

/// ساخت تم نهایی از تنظیمات (اگر id ناشناس بود، «کلاسیک»).
RtlTerminalTheme buildTerminalTheme(TerminalSettings s) {
  final TerminalThemePreset p = kTerminalThemes.firstWhere(
    (TerminalThemePreset t) => t.id == s.themeId,
    orElse: () => kTerminalThemes.first,
  );
  return p.build(s);
}

/// بارگذاری/ذخیرهٔ تنظیمات روی دیسک — JSON ساده، بدون پکیج اضافه.
class TerminalSettingsStore {
  const TerminalSettingsStore._();

  static const String fileName = 'sobhan_settings.json';

  static Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$fileName');
  }

  static Future<TerminalSettings> load() async {
    try {
      final File f = await _file();
      // S1: if the main file is unreadable/corrupt, fall back to the backup
      // left by the last good save instead of silently resetting everything.
      for (final File c in <File>[f, File('${f.path}.bak')]) {
        try {
          if (!c.existsSync()) continue;
          final String raw = await c.readAsString();
          if (raw.trim().isEmpty) continue;
          final Object? decoded = jsonDecode(raw);
          if (decoded is Map) {
            return TerminalSettings.fromJson(
                Map<String, Object?>.from(decoded));
          }
        } catch (e) {
          debugPrint('[TerminalSettings] load failed for ${c.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('[TerminalSettings] load failed: $e');
    }
    return const TerminalSettings();
  }

  /// Returns `false` when saving failed (S2) so callers may tell the user.
  static Future<bool> save(TerminalSettings s) async {
    try {
      final File f = await _file();
      final File tmp = File('${f.path}.tmp');
      // S4: write to a temp file, then rename, so a crash mid-write can't
      // leave a half-written config.
      await tmp.writeAsString(jsonEncode(s.toJson()), flush: true);
      if (f.existsSync()) {
        try {
          await f.copy('${f.path}.bak');
        } catch (_) {}
      }
      await tmp.rename(f.path);
      return true;
    } catch (e) {
      debugPrint('[TerminalSettings] save failed: $e');
      return false;
    }
  }
}
