// lib/kitty_graphics.dart
//
// زیرمجموعه‌ای از Kitty Graphics Protocol:
//   ESC _ G <control> ; <base64> ESC \
//
// پشتیبانی: a=t / a=T / a=p / a=d / a=q، فرمت‌های f=100 (PNG)،
// f=32 (RGBA)، f=24 (RGB)، انتقال چندتکه‌ای (m=1)، پاسخ OK/EINVAL.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// یک تصویر decode‌شده که با شناسه‌ی عددی نگهداری می‌شود.
class KittyImage {
  KittyImage(this.id, this.image, this.width, this.height);

  final int id;
  final ui.Image image;
  final int width;
  final int height;

  void dispose() {
    image.dispose();
  }
}

/// محل رسم یک تصویر روی صفحه‌ی سلولی.
class KittyPlacement {
  KittyPlacement({
    required this.imageId,
    required this.col,
    required this.row,
    this.cols = 0,
    this.rows = 0,
    this.z = 0,
  });

  final int imageId;
  int col;
  int row;

  /// عرض/ارتفاع بر حسب سلول؛ صفر یعنی «بر اساس پیکسل تصویر».
  int cols;
  int rows;

  /// ترتیب رسم
  int z;
}

class KittyGraphics {
  KittyGraphics({this.onChanged, this.onResponse});

  /// پس از هر تغییر (افزودن/حذف تصویر یا placement) صدا زده می‌شود.
  void Function()? onChanged;

  /// پاسخ‌های پروتکل به سمت برنامه‌ی مهمان نوشته می‌شوند.
  void Function(String)? onResponse;

  final Map<int, KittyImage> _images = <int, KittyImage>{};
  final List<KittyPlacement> placements = <KittyPlacement>[];

  // وضعیت انتقال چندتکه‌ای
  bool _pending = false;
  final StringBuffer _pendingData = StringBuffer();
  Map<String, String> _pendingMeta = <String, String>{};

  int _nextId = 1;

  /// K2: bumped on clear so in-flight async decodes are discarded.
  int _generation = 0;

  /// K5: resource limits.
  static const int _maxPendingChars = 96 * 1024 * 1024;
  static const int _maxPixels = 64 * 1024 * 1024;
  static const int _maxTotalPixels = 256 * 1024 * 1024;
  static const int _maxPlacements = 2048;

  int _totalPixels() {
    var n = 0;
    for (final i in _images.values) {
      n += i.width * i.height;
    }
    return n;
  }

  KittyImage? imageById(int id) => _images[id];

  /// پاک‌سازی کامل (مثلاً هنگام reset ترمینال).
  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    placements.clear();
    _generation++;
    _pending = false;
    _pendingData.clear();
    _pendingMeta = <String, String>{};
  }

  void _removePlacements(int imageId) {
    placements.removeWhere((p) => p.imageId == imageId);
  }

  void _removeImage(int imageId) {
    final img = _images.remove(imageId);
    img?.dispose();
    _removePlacements(imageId);
  }

  // -------------------------------------------------------------- entry

  /// یک دنباله‌ی APC (بدون ESC _ و بدون ESC \) را پردازش می‌کند.
  void handle(String payload, {int cursorCol = 0, int cursorRow = 0}) {
    final semi = payload.indexOf(';');
    final control = semi < 0 ? payload : payload.substring(0, semi);
    final data = semi < 0 ? '' : payload.substring(semi + 1);

    final meta = <String, String>{};
    if (control.isNotEmpty) {
      for (final part in control.split(',')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        if (eq < 0) {
          meta[part] = '';
        } else {
          meta[part.substring(0, eq)] = part.substring(eq + 1);
        }
      }
    }

    if (!_pending) {
      _pendingMeta = meta;
      _pendingData.clear();
      _pending = true;
    }
    if (data.isNotEmpty) _pendingData.write(data);
    if (_pendingData.length > _maxPendingChars) {
      final id = _idFrom(_pendingMeta);
      final q = int.tryParse(_pendingMeta['q'] ?? '') ?? 0;
      _pending = false;
      _pendingData.clear();
      _pendingMeta = <String, String>{};
      _respond(id, 'EINVAL:data too large', q);
      return;
    }

    final more = _pendingMeta['m'] ?? '0';
    if (more == '1') return;

    _pending = false;
    final full = _pendingMeta;
    final b64 = _pendingData.toString();
    _pendingData.clear();
    _pendingMeta = <String, String>{};
    _dispatch(full, b64, cursorCol, cursorRow);
  }

  // ------------------------------------------------------------- dispatch

  void _dispatch(
      Map<String, String> meta, String b64, int col, int row) {
    final action = meta['a'] ?? 't';
    final quiet = int.tryParse(meta['q'] ?? '') ?? 0;

    switch (action) {
      case 't':
      case 'T':
        unawaited(_transmit(meta, b64, col, row,
            display: action == 'T', quiet: quiet));
        break;
      case 'p':
        _put(meta, col, row, quiet);
        break;
      case 'd':
        _delete(meta, quiet);
        break;
      case 'q':
        _respond(_idFrom(meta), 'OK', quiet);
        break;
      default:
        _respond(_idFrom(meta), 'EINVAL:unknown action', quiet);
    }
  }

  int _idFrom(Map<String, String> meta) {
    final i = int.tryParse(meta['i'] ?? '');
    if (i != null && i > 0) return i;
    final n = int.tryParse(meta['I'] ?? '');
    if (n != null && n > 0) return n;
    return 0;
  }

  int _resolveId(Map<String, String> meta) {
    final id = _idFrom(meta);
    if (id > 0) return id;
    return _nextId++;
  }

  Future<void> _transmit(Map<String, String> meta, String b64, int col,
      int row, {required bool display, required int quiet}) async {
    final id = _resolveId(meta);
    final format = int.tryParse(meta['f'] ?? '32') ?? 32;
    final w = int.tryParse(meta['s'] ?? '') ?? 0;
    final h = int.tryParse(meta['v'] ?? '') ?? 0;

    if (b64.isEmpty) {
      _respond(id, 'EINVAL:empty data', quiet);
      return;
    }
    Uint8List bytes;
    try {
      bytes = base64.decode(b64);
    } catch (_) {
      _respond(id, 'EINVAL:bad base64', quiet);
      return;
    }

    final gen = _generation;
    if (format != 100) {
      if (w <= 0 || h <= 0 || w * h > _maxPixels) {
        _respond(id, 'EINVAL:bad size', quiet);
        return;
      }
      final expected = w * h * (format == 24 ? 3 : 4);
      if ((format == 32 || format == 24) && bytes.length != expected) {
        _respond(id, 'EINVAL:data size mismatch', quiet);
        return;
      }
    }

    ui.Image image;
    try {
      if (format == 100) {
        image = await _decodePng(bytes);
      } else if (format == 32) {
        if (w <= 0 || h <= 0) {
          _respond(id, 'EINVAL:missing size', quiet);
          return;
        }
        image = await _decodeRaw(bytes, w, h);
      } else if (format == 24) {
        if (w <= 0 || h <= 0) {
          _respond(id, 'EINVAL:missing size', quiet);
          return;
        }
        image = await _decodeRaw(_expandRgb(bytes), w, h);
      } else {
        _respond(id, 'EINVAL:unsupported format', quiet);
        return;
      }
    } catch (_) {
      _respond(id, 'EBADIMAGE', quiet);
      return;
    }
    if (gen != _generation) {
      image.dispose();
      return;
    }
    if (image.width * image.height > _maxPixels ||
        _totalPixels() + image.width * image.height > _maxTotalPixels) {
      image.dispose();
      _respond(id, 'ENOMEM:image too large', quiet);
      return;
    }
    final old = _images.remove(id);
    old?.dispose();
    _images[id] = KittyImage(id, image, image.width, image.height);

    if (display) _place(id, meta, col, row);
    _respond(id, 'OK', quiet);
    onChanged?.call();
  }

  void _put(Map<String, String> meta, int col, int row, int quiet) {
    final id = _idFrom(meta);
    if (id <= 0 || !_images.containsKey(id)) {
      _respond(id, 'ENOENT:no image', quiet);
      return;
    }
    _place(id, meta, col, row);
    _respond(id, 'OK', quiet);
    onChanged?.call();
  }

  void _delete(Map<String, String> meta, int quiet) {
    // K3: lowercase deletes placements only; uppercase also frees image data.
    final raw = meta['d'] ?? 'a';
    final free = raw == raw.toUpperCase() && raw != raw.toLowerCase();
    final what = raw.toLowerCase();
    final id = _idFrom(meta);
    if (what == 'a') {
      if (free) {
        clear();
      } else {
        placements.clear();
      }
    } else if (what == 'i' || what == 'n') {
      if (free) {
        _removeImage(id);
      } else {
        _removePlacements(id);
      }
    } else {
      _removePlacements(id);
    }
    _respond(id, 'OK', quiet);
    onChanged?.call();
  }

  void _place(int imageId, Map<String, String> meta, int col, int row) {
    final cols = int.tryParse(meta['c'] ?? '') ?? 0;
    final rows = int.tryParse(meta['r'] ?? '') ?? 0;
    final z = int.tryParse(meta['z'] ?? '') ?? 0;
    if (placements.length >= _maxPlacements) placements.removeAt(0);
    placements.add(KittyPlacement(
      imageId: imageId,
      col: col,
      row: row,
      cols: cols,
      rows: rows,
      z: z,
    ));
  }

  // -------------------------------------------------------------- decode

  Future<ui.Image> _decodePng(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  Future<ui.Image> _decodeRaw(Uint8List rgba, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    ui.Codec? codec;
    try {
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Uint8List _expandRgb(Uint8List rgb) {
    final n = rgb.length ~/ 3;
    final out = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      out[i * 4] = rgb[i * 3];
      out[i * 4 + 1] = rgb[i * 3 + 1];
      out[i * 4 + 2] = rgb[i * 3 + 2];
      out[i * 4 + 3] = 255;
    }
    return out;
  }

  // ------------------------------------------------------------- response

  void _respond(int id, String message, int quiet) {
    if (quiet >= 2) return;
    if (quiet >= 1 && message == 'OK') return;
    final head = id > 0 ? 'i=$id' : '';
    onResponse?.call('\x1b_G$head;$message\x1b\\');
  }
}
