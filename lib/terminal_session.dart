import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'term_buffer.dart';
import 'vt_parser.dart';
import 'distro.dart';

// ---------------------------------------------------------------------------
// TerminalSession: یک PTY مستقل + بافر + پارسر + نوتیفایرها.
// هر سشن یک ترمینال مجزا است که می‌تواند روی RootFS مشترک اجرا شود.
// ---------------------------------------------------------------------------

class TerminalSession {
  TerminalSession({required this.id, required this.distro}) {
    buffer.kitty.onChanged = _bump;
    buffer.kitty.onResponse = _writeRaw;
  }

  /// شناسه‌ی یکتای سشن (برای GlobalKey/ValueKey در UI).
  final int id;

  /// نام توزیع این سشن (نام نمایشی/منبع RootFS).
  final String distro;

  /// نام نمایشی سفارشی (null ⇒ نام پیش‌فرض توزیع).
  String? _customName;

  String? get customName => _customName;

  /// تنظیم نام نمایشی؛ خالی/فقط‌فاصله ⇒ بازگشت به پیش‌فرض، سقف ۳۲ کاراکتر.
  set customName(String? value) {
    final t = value?.trim() ?? '';
    _customName =
        t.isEmpty ? null : (t.length > 32 ? t.substring(0, 32) : t);
  }

  /// نام نمایشی مؤثر (نام سفارشی، وگرنه نام توزیع).
  String get displayName {
    final n = _customName;
    if (n != null && n.isNotEmpty) return n;
    return DistroRegistry.byId(distro).label;
  }

  final TermBuffer buffer = TermBuffer(cols: 120, rows: 35, maxScrollback: 2000);
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

  final List<String> _pending = <String>[];
  bool _flushQueued = false;

  late final VtParser _parser = VtParser(
    onPrint: (cp) => buffer.print(cp),
    onExecute: (cp) => buffer.execute(cp),
    onCsi: _onCsi,
    onEsc: (b, i) => buffer.esc(b, i),
    onOsc: _onOsc,
    onApc: (s) => buffer.handleApc(s),
  );

  void log(String message) => appendOutput('$message\r\n');

  void appendOutput(String data) {
    if (data.isEmpty) return;
    _parser.write(data);
    _bump();
  }

  void _bump() {
    if (_disposed) return;
    _linesCache = null;
    lineUpdateNotifier.value++;
  }

  void startPtySession({required VoidCallback onExit}) {
    if (_disposed) return;
    if (isSessionStarted && pty != null) return;
    // T7: توزیع ناشناس نباید بی‌صدا به Ubuntu برگردد و rootfs اشتباه بالا بیاید.
    if (DistroRegistry.byIdOrNull(distro) == null) {
      log('\x1b[31m[-]\x1b[0m unknown distro "$distro"; not starting.');
      onExit();
      return;
    }

    pty = Pty.start(
      'su',
      arguments: [
        '-c',
        'exec /system/bin/sh ${DistroRegistry.byId(distro).loginScript}',
      ],
      columns: _cols,
      rows: _rows,
      environment: {
        'TERM': 'xterm-256color',
        'PATH':
            '/sbin:/system/sbin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin',
      },
    );

    isSessionStarted = true;

    _outputSub?.cancel();
    _outputSub = pty!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onText, onError: (Object e) {
      log('\x1b[31m[-]\x1b[0m PTY read error: $e');
    });

    pty!.exitCode.then((code) {
      // T1: سشن dispose شده؛ هیچ callback ای به UI نزن.
      if (_disposed) return;
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
    if (_disposed) {
      _pending.clear();
      return;
    }
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
    if (p == null || _disposed) return;
    try {
      p.write(Uint8List.fromList(utf8.encode(s)));
    } catch (e) {
      debugPrint('[TerminalSession] write failed: $e');
    }
  }

  void sendInput(String text) {
    if (pty != null && text.isNotEmpty) _writeRaw(text);
  }

  void pasteText(String text) {
    if (text.isEmpty || pty == null) return;
    final normalized =
        text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (buffer.bracketedPaste) {
      _writeRaw('\x1b[200~$normalized\x1b[201~');
    } else {
      _writeRaw(normalized);
    }
  }

  void _onCsi(CsiSeq s) {
    if (s.finalByte == 0x6E && s.privateMarker == 0 && s.intermediate == 0 && s.p(0) == 6) {
      _writeRaw('\x1b[${buffer.cursorRow + 1};${buffer.cursorCol + 1}R');
      return;
    }
    // T6: DA1 فقط با پارامتر خالی/۰ پاسخ داده می‌شود (نه `CSI > c` و غیره).
    if (s.finalByte == 0x63 && s.privateMarker == 0 && s.intermediate == 0 && s.p(0) <= 0) {
      _writeRaw('\x1b[?1;2c');
      return;
    }
    buffer.csi(s);
  }

  void _onOsc(String data) {
    if (_disposed) return;
    if (data.startsWith('0;') || data.startsWith('2;')) {
      terminalTitle.value = data.substring(2);
    }
  }

  void requestGrid(int cols, int rows) {
    if (cols < 20 || rows < 5) return;
    if (cols == _wantCols && rows == _wantRows) return;
    _wantCols = cols;
    _wantRows = rows;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 200), () {
      if (_disposed) return;
      if (cols == _cols && rows == _rows) return;
      final oldCols = _cols, oldRows = _rows;
      _cols = cols;
      _rows = rows;
      buffer.resize(cols, rows);
      try {
        pty?.resize(rows, cols);
      } catch (e) {
        // اجازهٔ تلاش مجدد: اندازهٔ PTY با بافر هم‌خوان نشد.
        _cols = oldCols;
        _rows = oldRows;
        _wantCols = oldCols;
        _wantRows = oldRows;
        // T5: شکست resize نباید بی‌صدا بماند.
        debugPrint('[TerminalSession] pty resize failed: $e');
      }
      _bump();
    });
  }

  bool _disposed = false;

  void disposeSession() {
    _disposed = true;
    buffer.kitty.onChanged = null;
    buffer.kitty.onResponse = null;
    _resizeDebounce?.cancel();
    _pending.clear();
    _outputSub?.cancel();
    _outputSub = null;
    try {
      pty?.kill();
    } catch (_) {}
    pty = null;
    isSessionStarted = false;
    // T3: notifierها با تأخیر dispose می‌شوند تا listenerهای UI فرصت حذف شدن داشته باشند.
    Future<void>.delayed(const Duration(seconds: 2), () {
      lineUpdateNotifier.dispose();
      terminalTitle.dispose();
    });
  }

  List<String>? _linesCache;

  List<String> get lines {
    final cached = _linesCache;
    if (cached != null) return cached;
    final out = <String>[];
    for (final l in buffer.scrollback) {
      out.add(_ansiOfLine(l));
    }
    // T4: وسط resize ممکن است rows و lines.length ناهماهنگ باشند.
    final int visible =
        buffer.rows < buffer.lines.length ? buffer.rows : buffer.lines.length;
    for (var r = 0; r < visible; r++) {
      out.add(_ansiOfLine(buffer.lines[r]));
    }
    _linesCache = out;
    return out;
  }

  int get cursorRow => buffer.scrollback.length + buffer.cursorRow;
  int get cursorCol => buffer.cursorCol;

  String _ansiOfLine(TermLine line) {
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
        sb.write(' ');
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
// TerminalManager: مالک لیست سشن‌ها، ایندکس فعال و نوتیفایر تغییر سشن.
// ---------------------------------------------------------------------------

class TerminalManager {
  /// حداکثر ترمینال هم‌زمان برای هر توزیع (مستقل از بقیه توزیع‌ها).
  static const int maxSessionsPerDistro = 5;

  final List<TerminalSession> sessions = <TerminalSession>[];
  final ValueNotifier<int> activeNotifier = ValueNotifier<int>(0);

  int _activeIndex = 0;
  int _nextId = 1;

  int get activeIndex => _activeIndex;
  bool get isEmpty => sessions.isEmpty;
  TerminalSession get active => sessions[_activeIndex];

  /// تعداد سشن‌های بازِ توزیع [distroId].
  int countFor(String distroId) {
    var n = 0;
    for (final s in sessions) {
      if (s.distro == distroId) n++;
    }
    return n;
  }

  /// آیا اجازهٔ ساخت سشن جدید برای توزیع [distroId] هست؟
  bool canAdd(String distroId) => countFor(distroId) < maxSessionsPerDistro;

  TerminalSession createSession(String distro) {
    final s = TerminalSession(id: _nextId++, distro: distro);
    sessions.add(s);
    _activeIndex = sessions.length - 1;
    activeNotifier.value = _activeIndex;
    return s;
  }

  void switchTo(int index) {
    if (index < 0 || index >= sessions.length) return;
    _activeIndex = index;
    activeNotifier.value = index;
  }

  /// جابه‌جایی سشن از مکان [from] به [to] و حفظ سشنِ فعال (بر اساس id).
  bool moveSession(int from, int to) {
    if (from == to) return false;
    if (from < 0 || from >= sessions.length) return false;
    if (to < 0 || to >= sessions.length) return false;
    final activeId = sessions[_activeIndex].id;
    final moved = sessions.removeAt(from);
    sessions.insert(to, moved);
    final idx = sessions.indexWhere((TerminalSession e) => e.id == activeId);
    _activeIndex = idx < 0 ? 0 : idx;
    activeNotifier.value = _activeIndex;
    return true;
  }

  void closeActive() {
    if (sessions.length <= 1) return;
    final s = sessions.removeAt(_activeIndex);
    s.disposeSession();
    if (_activeIndex >= sessions.length) _activeIndex = sessions.length - 1;
    activeNotifier.value = _activeIndex;
  }

  void disposeAll() {
    for (final s in sessions) {
      s.disposeSession();
    }
    sessions.clear();
  }
}
