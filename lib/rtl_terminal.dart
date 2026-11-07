import 'dart:math' as math;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'term_buffer.dart';
import 'kitty_graphics.dart';

/// یک نتیجهٔ جست‌وجو در متن ترمینال (شمارهٔ خط مطلق + بازهٔ ستون‌ها).
class TerminalSearchHit {
  final int line;
  final int start;
  final int end;
  const TerminalSearchHit(this.line, this.start, this.end);
}

const List<Color> kTerminalPalette = <Color>[
  Color(0xFF000000), Color(0xFFCD3131), Color(0xFF0DBC79), Color(0xFFE5E510),
  Color(0xFF2472C8), Color(0xFFBC3FBC), Color(0xFF11A8CD), Color(0xFFE5E5E5),
  Color(0xFF666666), Color(0xFFF14C4C), Color(0xFF23D18B), Color(0xFFF5F543),
  Color(0xFF3B8EEA), Color(0xFFD670D6), Color(0xFF29B8DB), Color(0xFFFFFFFF),
];

class RtlTerminalTheme {
  final Color background;
  final Color foreground;
  final Color cursor;
  final double fontSize;
  final String fontFamily;
  final double lineHeight;
  final List<Color> palette;
  final TextDirection baseDirection;

  const RtlTerminalTheme({
    this.background = const Color(0xFF000000),
    this.foreground = const Color(0xFFEEEEEE),
    this.cursor = const Color(0xFF00FF66),
    this.fontSize = 13.0,
    this.fontFamily = 'monospace',
    this.lineHeight = 1.2,
    this.palette = kTerminalPalette,
    this.baseDirection = TextDirection.ltr,
  });

  TextStyle get textStyle => TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        height: lineHeight,
        color: foreground,
      );

  Color resolveColor(int c, Color fallback) {
    if (c == kDefaultColor) return fallback;
    if (isRgbColor(c)) return Color(0xFF000000 | (c & 0x00FFFFFF));
    if (c < palette.length) return palette[c];
    if (c < 232) {
      final i = c - 16;
      final r = (i ~/ 36) * 51;
      final g = ((i % 36) ~/ 6) * 51;
      final b = (i % 6) * 51;
      return Color.fromARGB(255, r, g, b);
    }
    if (c < 256) {
      final v = (c - 232) * 10 + 8;
      return Color.fromARGB(255, v, v, v);
    }
    return fallback;
  }

  Color fgOf(TermAttr a) =>
      a.inverse ? resolveColor(a.bg, background) : resolveColor(a.fg, foreground);

  Color bgOf(TermAttr a) =>
      a.inverse ? resolveColor(a.fg, foreground) : resolveColor(a.bg, background);
}

class CellMetrics {
  final double width;
  final double height;
  const CellMetrics(this.width, this.height);
}

CellMetrics measureCellMetrics(RtlTerminalTheme theme) {
  final tp = TextPainter(
    text: TextSpan(text: 'M' * 32, style: theme.textStyle),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
  )..layout();
  return CellMetrics(tp.width / 32.0, tp.height);
}

bool _isRtlRune(int r) =>
    (r >= 0x0590 && r <= 0x08FF) ||
    (r >= 0xFB1D && r <= 0xFDFF) ||
    (r >= 0xFE70 && r <= 0xFEFF);

bool _isLtrRune(int r) =>
    (r >= 0x41 && r <= 0x5A) ||
    (r >= 0x61 && r <= 0x7A) ||
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x00C0 && r <= 0x024F) ||
    (r >= 0x0370 && r <= 0x03FF) ||
    (r >= 0x0400 && r <= 0x04FF) ||
    (r >= 0x0900 && r <= 0x0DFF) ||
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xAC00 && r <= 0xD7AF);

/// first-strong heuristic: جهت خط را اولین کاراکتر قوی تعیین می‌کند.
TextDirection lineDirection(TermLine line, TextDirection fallback) {
  for (final c in line.cells) {
    if (c.width == 0) continue;
    final s = c.ch;
    if (s.isEmpty) continue;
    final rune = s.runes.first;
    if (_isRtlRune(rune)) return TextDirection.rtl;
    if (_isLtrRune(rune)) return TextDirection.ltr;
  }
  return fallback;
}

class RtlTerminalView extends StatefulWidget {
  final TermBuffer buffer;
  final RtlTerminalTheme theme;
  final VoidCallback? onTap;
  final ValueChanged<String>? onInput;
  // کلیدهای سخت‌افزاری (فلش، Ctrl+C و ...) از اینجا میان
  final FocusOnKeyEventCallback? onKeyEvent;

  const RtlTerminalView({
    super.key,
    required this.buffer,
    this.theme = const RtlTerminalTheme(),
    this.onTap,
    this.onInput,
    this.onKeyEvent,
  });

  @override
  State<RtlTerminalView> createState() => RtlTerminalViewState();
}

class _LineGlyphEntry {
  _LineGlyphEntry(this.revision, this.painter);

  final int revision;
  final TextPainter painter;
}

/// cache کوچک خطوط لِی‌اوت‌شده. کلید = هویت [TermLine]، اعتبارسنجی = revision.
class _GlyphCache {
  final Map<TermLine, _LineGlyphEntry> _map =
      <TermLine, _LineGlyphEntry>{};

  static const int _maxEntries = 2048;

  TextPainter? get(TermLine line) {
    final e = _map[line];
    if (e == null) return null;
    if (e.revision != line.revision) {
      _map.remove(line);
      e.painter.dispose();
      return null;
    }
    return e.painter;
  }

  void put(TermLine line, TextPainter painter) {
    if (_map.length >= _maxEntries) clear();
    _map[line] = _LineGlyphEntry(line.revision, painter);
  }

  void clear() {
    for (final e in _map.values) {
      e.painter.dispose();
    }
    _map.clear();
  }
}

class RtlTerminalViewState extends State<RtlTerminalView>
    with SingleTickerProviderStateMixin
    implements TextInputClient {
  late CellMetrics _metrics;
  late AnimationController _scrollController;
  final FocusNode _focusNode = FocusNode();
  TextInputConnection? _textInputConnection;
  Simulation? _scrollSimulation;

  double _scroll = 0.0;
  int _lastScrollback = 0;
  int _rowsVisible = 1;

  final _GlyphCache _glyphCache = _GlyphCache();

  // ── انتخاب متن ──
  int _selAnchorLine = -1;
  int _selAnchorCol = -1;
  int _selFocusLine = -1;
  int _selFocusCol = -1;

  // ── جست‌وجو ──
  String _searchQuery = '';
  List<TerminalSearchHit> _searchHits = const <TerminalSearchHit>[];
  int _searchCurrent = -1;

  bool get hasSelection => _selAnchorLine >= 0 && _selFocusLine >= 0;

  void clearSelection() {
    if (!hasSelection) return;
    setState(() {
      _selAnchorLine = -1;
      _selAnchorCol = -1;
      _selFocusLine = -1;
      _selFocusCol = -1;
    });
  }

  // ── جست‌وجو ──
  int get searchHitCount => _searchHits.length;

  int get searchCurrentIndex => _searchCurrent;

  void setSearchQuery(String q) {
    if (q == _searchQuery) return;
    _searchQuery = q;
    _recomputeSearch();
    setState(() {});
  }

  void clearSearch() {
    if (_searchQuery.isEmpty && _searchHits.isEmpty) return;
    _searchQuery = '';
    _searchHits = const <TerminalSearchHit>[];
    _searchCurrent = -1;
    setState(() {});
  }

  void searchNext() {
    if (_searchHits.isEmpty) return;
    setState(() {
      _searchCurrent = (_searchCurrent + 1) % _searchHits.length;
      _scrollToHit(_searchHits[_searchCurrent]);
    });
  }

  void searchPrevious() {
    if (_searchHits.isEmpty) return;
    setState(() {
      _searchCurrent =
          (_searchCurrent - 1 + _searchHits.length) % _searchHits.length;
      _scrollToHit(_searchHits[_searchCurrent]);
    });
  }

  void _recomputeSearch() {
    _searchHits = const <TerminalSearchHit>[];
    _searchCurrent = -1;
    final q = _searchQuery;
    if (q.isEmpty) return;
    final ql = q.toLowerCase();
    final all = _combinedLines();
    final hits = <TerminalSearchHit>[];
    for (var i = 0; i < all.length; i++) {
      final cells = all[i].cells;
      final buf = StringBuffer();
      for (var c = 0; c < cells.length; c++) {
        final cell = cells[c];
        if (cell.width == 0) continue;
        buf.write(cell.ch.isEmpty ? ' ' : cell.ch);
      }
      final text = buf.toString().toLowerCase();
      var from = 0;
      while (true) {
        final idx = text.indexOf(ql, from);
        if (idx < 0) break;
        hits.add(TerminalSearchHit(i, idx, idx + ql.length));
        from = idx + math.max(1, ql.length);
      }
    }
    _searchHits = hits;
    if (hits.isNotEmpty) {
      _searchCurrent = hits.length - 1;
      _scrollToHit(hits[_searchCurrent]);
    }
  }

  void _scrollToHit(TerminalSearchHit hit) {
    final total = _combinedLines().length;
    final maxScroll = widget.buffer.scrollback.length.toDouble();
    final rows = math.max(1, _rowsVisible);
    var target = (total - rows - hit.line).toDouble();
    if (target < 0) target = 0;
    if (target > maxScroll) target = maxScroll;
    _scroll = target;
  }

  List<TermLine> _combinedLines() {
    final sb = widget.buffer.isAltScreen
        ? const <TermLine>[]
        : widget.buffer.scrollback;
    return <TermLine>[...sb, ...widget.buffer.lines];
  }

  /// اگر انتخاب وجود داشته باشد متن انتخاب‌شده، وگرنه رشتهٔ خالی.
  String getSelectedText() {
    if (!hasSelection) return '';
    final all = _combinedLines();
    if (all.isEmpty) return '';
    var aLine = _selAnchorLine;
    var aCol = _selAnchorCol;
    var fLine = _selFocusLine;
    var fCol = _selFocusCol;
    if (aLine > fLine || (aLine == fLine && aCol > fCol)) {
      final tl = aLine, tc = aCol;
      aLine = fLine;
      aCol = fCol;
      fLine = tl;
      fCol = tc;
    }
    aLine = aLine.clamp(0, all.length - 1);
    fLine = fLine.clamp(0, all.length - 1);
    final out = <String>[];
    for (var i = aLine; i <= fLine; i++) {
      final cells = all[i].cells;
      final from = i == aLine ? aCol.clamp(0, cells.length) : 0;
      var to = i == fLine ? fCol.clamp(0, cells.length) : cells.length;
      if (to < from) to = from;
      final buf = StringBuffer();
      for (var c = from; c < to; c++) {
        final cell = cells[c];
        if (cell.width == 0) continue;
        buf.write(cell.ch.isEmpty ? ' ' : cell.ch);
      }
      out.add(buf.toString().replaceAll(RegExp(r' +$'), ''));
    }
    return out.join('\n');
  }

  ({int line, int col}) _hitTest(Offset local, int sbLen) {
    final rows = math.max(1, _rowsVisible);
    final cw = _metrics.width;
    final ch = _metrics.height;
    final all = _combinedLines();
    if (all.isEmpty) return (line: 0, col: 0);
    final bottom = all.length - _scroll.round();
    var first = bottom - rows;
    if (first < 0) first = 0;
    final lineIdx =
        (first + (local.dy / ch).floor()).clamp(0, all.length - 1);
    final line = all[lineIdx];
    final n = line.cells.length;
    var col = (local.dx / cw).floor();
    if (lineDirection(line, widget.theme.baseDirection) == TextDirection.rtl) {
      col = (n - 1) - col;
    }
    return (line: lineIdx, col: col.clamp(0, n));
  }

  /// نگاشت نقطه‌ی local به خانه‌ی viewport (col, row) صفر-مبنا.
  ({int col, int row}) _viewportCell(Offset local) {
    final cw = _metrics.width;
    final ch = _metrics.height;
    final cols = widget.buffer.cols;
    final rows = math.max(1, _rowsVisible);
    var col = (local.dx / cw).floor();
    final row = (local.dy / ch).floor();
    if (widget.theme.baseDirection == TextDirection.rtl) {
      col = (cols - 1) - col;
    }
    return (
      col: col.clamp(0, math.max(0, cols - 1)),
      row: row.clamp(0, math.max(0, rows - 1)),
    );
  }

  int _buttonFromFlags(int buttons) {
    // PointerEvent.buttons: 0x01=primary, 0x02=secondary, 0x04=middle
    if ((buttons & 0x01) != 0) return 0;
    if ((buttons & 0x02) != 0) return 2;
    if ((buttons & 0x04) != 0) return 1;
    return 0;
  }

  void _reportMouse({
    required int button,
    required Offset local,
    bool release = false,
    bool motion = false,
  }) {
    if (!widget.buffer.mouseReporting) return;
    final p = _viewportCell(local);
    final seq = widget.buffer.encodeMouse(
      button: button,
      col: p.col,
      row: p.row,
      release: release,
      motion: motion,
    );
    if (seq.isNotEmpty) widget.onInput?.call(seq);
  }

  void scrollToBottom({bool animate = true}) {
    if (_scroll <= 0.0) return;
    _scrollController.stop();
    if (!animate) {
      setState(() => _scroll = 0.0);
      return;
    }
    final anim = Tween<double>(begin: _scroll, end: 0.0).animate(
      CurvedAnimation(parent: _scrollController, curve: Curves.easeOutCubic),
    );
    _scrollController.reset();
    anim.addListener(() => setState(() => _scroll = anim.value));
    _scrollController.duration = const Duration(milliseconds: 200);
    _scrollController.forward(from: 0.0);
  }

  /// عمومی — از main.dart قابل فراخوانی‌ه
  void openKeyboard() {
    return; // [kbfix2] disabled (ImeBridge owns the IME)
    // ignore: dead_code
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    if (_textInputConnection == null || !_textInputConnection!.attached) {
      _textInputConnection = TextInput.attach(
        this,
        const TextInputConfiguration(
          inputType: TextInputType.multiline,
          obscureText: false,
          autocorrect: false,
          enableSuggestions: false,
          inputAction: TextInputAction.newline,
        ),
      );
    }
    _textInputConnection!.show();
  }

  void _closeKeyboard() {
    return; // [kbfix2] disabled (ImeBridge owns the IME)
    // ignore: dead_code
    _textInputConnection?.close();
    _textInputConnection = null;
  }

  @override
  void initState() {
    super.initState();
    _metrics = measureCellMetrics(widget.theme);
    _lastScrollback = widget.buffer.scrollback.length;
    _scrollController = AnimationController.unbounded(vsync: this);
    _scrollController.addListener(_handleScrollTick);

    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        openKeyboard();
      } else {
        _closeKeyboard();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) openKeyboard();
    });
  }

  void _handleScrollTick() {
    if (_scrollSimulation != null) {
      final simTime = _scrollController.lastElapsedDuration?.inMicroseconds ?? 0;
      final t = simTime / 1e6;
      final val = _scrollSimulation!.x(t);
      final maxScroll = widget.buffer.scrollback.length.toDouble();
      setState(() => _scroll = val.clamp(0.0, maxScroll));
      if (_scrollSimulation!.isDone(t) || _scroll <= 0.0 || _scroll >= maxScroll) {
        _scrollController.stop();
        _scrollSimulation = null;
      }
    }
  }

  @override
  void didUpdateWidget(covariant RtlTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme.fontSize != widget.theme.fontSize ||
        oldWidget.theme.fontFamily != widget.theme.fontFamily ||
        oldWidget.theme.lineHeight != widget.theme.lineHeight) {
      _metrics = measureCellMetrics(widget.theme);
    }
    if (!identical(oldWidget.theme, widget.theme) ||
        !identical(oldWidget.buffer, widget.buffer)) {
      _glyphCache.clear();
    }
    final sb = widget.buffer.scrollback.length;
    if (_scroll > 0 && sb > _lastScrollback) {
      _scroll += (sb - _lastScrollback).toDouble();
    }
    _lastScrollback = sb;
    final maxScroll = sb.toDouble();
    if (_scroll > maxScroll) _scroll = maxScroll;
  }

  @override
  void dispose() {
    _glyphCache.clear();
    _closeKeyboard();
    _focusNode.dispose();
    _scrollController.removeListener(_handleScrollTick);
    _scrollController.dispose();
    super.dispose();
  }

  // ── TextInputClient ──

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue? get currentTextEditingValue =>
      const TextEditingValue(
          text: '', selection: TextSelection.collapsed(offset: 0));

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value.text.isNotEmpty) {
      widget.onInput?.call(value.text);
      if (_scroll > 0.5) scrollToBottom();
      _textInputConnection?.setEditingState(
        const TextEditingValue(
            text: '', selection: TextSelection.collapsed(offset: 0)),
      );
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline ||
        action == TextInputAction.done) {
      widget.onInput?.call('\r');
      if (_scroll > 0.5) scrollToBottom();
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
  }

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  bool onFocusReceived() => false;

  @override
  void performSelector(String selectorName) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  // ── end TextInputClient ──

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return LayoutBuilder(
      builder: (context, constraints) {
        _rowsVisible =
            math.max(1, (constraints.maxHeight / _metrics.height).floor());
        final rowsVisible = _rowsVisible;

        return Focus(
      canRequestFocus: false,
      focusNode: _focusNode,
          autofocus: true,
          // کلیدهای سخت‌افزاری (فلش، بک‌اسپیس، Ctrl+C و ...) اینجا هندل میشن
          onKeyEvent: widget.onKeyEvent,
          child: Listener(
            onPointerDown: (e) {
              if (!widget.buffer.mouseReporting) return;
              final b = _buttonFromFlags(e.buttons);
              widget.buffer.mousePress(b);
              _reportMouse(button: b, local: e.localPosition);
            },
            onPointerMove: (e) {
              if (!widget.buffer.mouseReporting) return;
              final mode = widget.buffer.mouseMode;
              if (mode != 1002 && mode != 1003) return;
              final b = e.buttons == 0
                  ? (widget.buffer.mouseButtonDown > 0
                      ? widget.buffer.mouseButtonDown - 1
                      : 0)
                  : _buttonFromFlags(e.buttons);
              _reportMouse(button: b, local: e.localPosition, motion: true);
            },
            onPointerUp: (e) {
              if (!widget.buffer.mouseReporting) return;
              final b = widget.buffer.mouseButtonDown > 0
                  ? widget.buffer.mouseButtonDown - 1
                  : _buttonFromFlags(e.buttons);
              _reportMouse(
                  button: b, local: e.localPosition, release: true);
              widget.buffer.mouseRelease();
            },
            onPointerCancel: (e) {
              if (!widget.buffer.mouseReporting) return;
              if (widget.buffer.mouseButtonDown > 0) {
                _reportMouse(
                  button: widget.buffer.mouseButtonDown - 1,
                  local: e.localPosition,
                  release: true,
                );
              }
              widget.buffer.mouseRelease();
            },
            onPointerSignal: (e) {
              if (!widget.buffer.mouseReporting) return;
              if (e is PointerScrollEvent) {
                final dy = e.scrollDelta.dy;
                if (dy == 0) return;
                final b = dy < 0 ? 64 : 65; // wheel up / down
                _reportMouse(button: b, local: e.localPosition);
              }
            },
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (widget.buffer.mouseReporting) return;
              // [kbfix3] دیگر کیبورد را خودکار باز نمی‌کنیم؛ فقط دکمهٔ KEYS.
              clearSelection();
              if (_scroll > 0.5) scrollToBottom();
              widget.onTap?.call();
            },
            onLongPressStart: (details) {
              if (widget.buffer.mouseReporting) return;
              final p = _hitTest(
                  details.localPosition, widget.buffer.scrollback.length);
              setState(() {
                _selAnchorLine = p.line;
                _selAnchorCol = p.col;
                _selFocusLine = p.line;
                _selFocusCol = p.col;
              });
            },
            onLongPressMoveUpdate: (details) {
              if (widget.buffer.mouseReporting) return;
              if (!hasSelection) return;
              final p = _hitTest(
                  details.localPosition, widget.buffer.scrollback.length);
              setState(() {
                _selFocusLine = p.line;
                _selFocusCol = p.col;
              });
            },
            onVerticalDragStart: (_) {
              if (widget.buffer.mouseReporting) return;
              _scrollController.stop();
              _scrollSimulation = null;
            },
            onVerticalDragUpdate: (details) {
              if (widget.buffer.mouseReporting) return;
              final maxScroll = widget.buffer.scrollback.length.toDouble();
              final deltaLines = details.primaryDelta != null
                  ? details.primaryDelta! / _metrics.height
                  : 0.0;
              setState(() {
                _scroll = (_scroll + deltaLines).clamp(0.0, maxScroll);
              });
            },
            onVerticalDragEnd: (details) {
              if (widget.buffer.mouseReporting) return;
              final vY = details.primaryVelocity ?? 0.0;
              if (vY.abs() > 50.0) {
                final vLines = vY / _metrics.height;
                _scrollSimulation = FrictionSimulation(0.015, _scroll, vLines);
                _scrollController.reset();
                _scrollController.forward(from: 0.0);
              }
            },
            child: CustomPaint(
              painter: _TerminalPainter(
                buffer: widget.buffer,
                theme: theme,
                metrics: _metrics,
                cache: _glyphCache,
                scroll: _scroll,
                rowsVisible: rowsVisible,
                selStartLine: _selAnchorLine,
                selStartCol: _selAnchorCol,
                selEndLine: _selFocusLine,
                selEndCol: _selFocusCol,
                searchHits: _searchHits,
                searchCurrent: _searchCurrent,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          ),
        );
      },
    );
  }
}

class _TerminalPainter extends CustomPainter {
  _TerminalPainter({
    required this.buffer,
    required this.theme,
    required this.metrics,
    required this.cache,
    required this.scroll,
    required this.rowsVisible,
    required this.selStartLine,
    required this.selStartCol,
    required this.selEndLine,
    required this.selEndCol,
    required this.searchHits,
    required this.searchCurrent,
  });

  final TermBuffer buffer;
  final RtlTerminalTheme theme;
  final CellMetrics metrics;
  final _GlyphCache cache;
  final double scroll;
  final int rowsVisible;
  final int selStartLine;
  final int selStartCol;
  final int selEndLine;
  final int selEndCol;
  final List<TerminalSearchHit> searchHits;
  final int searchCurrent;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = metrics.width;
    final ch = metrics.height;

    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    final scrollback =
        buffer.isAltScreen ? const <TermLine>[] : buffer.scrollback;
    final screen = buffer.lines;
    final total = scrollback.length + screen.length;

    final bottom = total - scroll.round();
    final first = math.max(0, bottom - rowsVisible);
    final last = math.min(total, bottom);

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    _paintSearchHits(canvas, scrollback, screen, first, cw, ch, size);

    for (var i = first; i < last; i++) {
      final line = i < scrollback.length
          ? scrollback[i]
          : screen[i - scrollback.length];
      final y = (i - first) * ch;
      _paintLine(canvas, line, y, cw, ch);
    }

    _paintSelection(canvas, scrollback, screen, first, cw, ch, size);
    _paintCursor(canvas, scrollback.length, first, cw, ch, size);
    _paintImages(canvas, scrollback, first, cw, ch, size);
    canvas.restore();

    if (scroll > 0.5) _paintScrollBadge(canvas, size);
  }

  void _paintLine(Canvas canvas, TermLine line, double y, double cw, double ch) {
    final cells = line.cells;
    final n = cells.length;
    if (n == 0) return;

    final isRtl = lineDirection(line, theme.baseDirection) ==
        TextDirection.rtl;
    var i = 0;
    while (i < n) {
      final bg = theme.bgOf(cells[i].attr);
      if (bg == theme.background) { i++; continue; }
      var j = i + 1;
      while (j < n && theme.bgOf(cells[j].attr) == bg) {
        j++;
      }
      final double bx = isRtl ? (n - j) * cw : i * cw;
      canvas.drawRect(
        Rect.fromLTWH(bx, y, (j - i) * cw, ch),
        Paint()..color = bg,
      );
      i = j;
    }

    var end = n;
    while (end > 0) {
      final c = cells[end - 1];
      if (c.width != 0 && c.isBlank && c.attr.isPlain) {
        end--;
      } else {
        break;
      }
    }
    if (end == 0) return;

    final cached = cache.get(line);
    final TextPainter tp;
    if (cached != null) {
      tp = cached;
    } else {
      final spans = _buildSpans(line, 0, end);
      if (spans.isEmpty) return;
      final dir = lineDirection(line, theme.baseDirection);
      tp = TextPainter(
        text: TextSpan(children: spans),
        textDirection: dir,
        textAlign:
            dir == TextDirection.rtl ? TextAlign.right : TextAlign.left,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: cw * n);
      cache.put(line, tp);
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, y, cw * n, ch));
    tp.paint(canvas, Offset(0, y));
    canvas.restore();
  }

  List<InlineSpan> _buildSpans(TermLine line, int from, int to) {
    final spans = <InlineSpan>[];
    final cells = line.cells;
    final end = math.min(to, cells.length);
    var i = from;
    while (i < end) {
      final attr = cells[i].attr;
      final buf = StringBuffer();
      final start = i;
      while (i < end && cells[i].attr == attr) {
        final c = cells[i];
        if (c.width != 0) buf.write(c.ch.isEmpty ? ' ' : c.ch);
        i++;
      }
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf.toString(), style: _styleFor(attr)));
      }
      if (i == start) i++;
    }
    return spans;
  }

  TextStyle _styleFor(TermAttr a) {
    var fg = theme.fgOf(a);
    if (a.hidden) fg = theme.bgOf(a);
    if (a.dim) fg = fg.withValues(alpha: 0.55);

    final decos = <TextDecoration>[];
    if (a.underline) decos.add(TextDecoration.underline);
    if (a.strike) decos.add(TextDecoration.lineThrough);

    return theme.textStyle.copyWith(
      color: fg,
      fontWeight: a.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: a.italic ? FontStyle.italic : FontStyle.normal,
      decoration:
          decos.isEmpty ? TextDecoration.none : TextDecoration.combine(decos),
      decorationColor: fg,
    );
  }

  void _paintSearchHits(Canvas canvas, List<TermLine> scrollback,
      List<TermLine> screen, int first, double cw, double ch, Size size) {
    if (searchHits.isEmpty) return;
    final normal = Paint()..color = const Color(0x66FFEB3B);
    final active = Paint()..color = const Color(0xAAFF9800);
    for (var k = 0; k < searchHits.length; k++) {
      final hit = searchHits[k];
      TermLine? line;
      if (hit.line < scrollback.length) {
        line = scrollback[hit.line];
      } else {
        final idx = hit.line - scrollback.length;
        if (idx >= 0 && idx < screen.length) line = screen[idx];
      }
      if (line == null) continue;
      final y = (hit.line - first) * ch;
      if (y < -ch || y > size.height) continue;
      final n = line.cells.length;
      final from = hit.start.clamp(0, n);
      final to = hit.end.clamp(0, n);
      if (to <= from) continue;
      final paint = k == searchCurrent ? active : normal;
      if (lineDirection(line, theme.baseDirection) == TextDirection.rtl) {
        canvas.drawRect(
            Rect.fromLTWH((n - to) * cw, y, (to - from) * cw, ch), paint);
      } else {
        canvas.drawRect(
            Rect.fromLTWH(from * cw, y, (to - from) * cw, ch), paint);
      }
    }
  }

  void _paintCursor(
      Canvas canvas, int sbLen, int first, double cw, double ch, Size size) {
    if (scroll > 0.5) return;
    if (!buffer.cursorVisible) return;

    final screen = buffer.lines;
    if (buffer.cursorRow < 0 || buffer.cursorRow >= screen.length) return;

    final line = screen[buffer.cursorRow];
    final y = (sbLen + buffer.cursorRow - first) * ch;
    if (y < -ch || y > size.height) return;

    final col = buffer.cursorCol;
    final dir = lineDirection(line, theme.baseDirection);
    final x = dir == TextDirection.ltr
        ? _measurePrefix(line, col)
        : (line.cells.length - 1 - col).clamp(0, line.cells.length) * cw;

    canvas.drawRect(
      Rect.fromLTWH(x, y, cw, ch),
      Paint()..color = theme.cursor.withValues(alpha: 0.7),
    );

    if (col < line.cells.length) {
      final cell = line.cells[col];
      if (cell.ch.isNotEmpty && cell.ch.trim().isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
              text: cell.ch,
              style: theme.textStyle.copyWith(color: theme.background)),
          textDirection: dir,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
        )..layout();
        tp.paint(canvas, Offset(x, y));
      }
    }
  }

  double _measurePrefix(TermLine line, int col) {
    if (col <= 0) return 0;
    final spans = _buildSpans(line, 0, math.min(col, line.cells.length));
    if (spans.isEmpty) return 0;
    final tp = TextPainter(
      text: TextSpan(children: spans),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout();
    return tp.width;
  }

  void _paintSelection(Canvas canvas, List<TermLine> scrollback,
      List<TermLine> screen, int first, double cw, double ch, Size size) {
    if (selStartLine < 0 || selEndLine < 0) return;
    var aLine = selStartLine;
    var aCol = selStartCol;
    var fLine = selEndLine;
    var fCol = selEndCol;
    if (aLine > fLine || (aLine == fLine && aCol > fCol)) {
      final tl = aLine, tc = aCol;
      aLine = fLine;
      aCol = fCol;
      fLine = tl;
      fCol = tc;
    }
    final all = <TermLine>[...scrollback, ...screen];
    final paint = Paint()..color = theme.cursor.withValues(alpha: 0.30);
    for (var i = aLine; i <= fLine; i++) {
      if (i < 0 || i >= all.length) continue;
      final y = (i - first) * ch;
      if (y < -ch || y > size.height) continue;
      final n = all[i].cells.length;
      final from = i == aLine ? aCol.clamp(0, n) : 0;
      final to = i == fLine ? fCol.clamp(0, n) : n;
      if (to <= from) continue;
      if (lineDirection(all[i], theme.baseDirection) == TextDirection.rtl) {
        canvas.drawRect(
            Rect.fromLTWH((n - to) * cw, y, (to - from) * cw, ch), paint);
      } else {
        canvas.drawRect(
            Rect.fromLTWH(from * cw, y, (to - from) * cw, ch), paint);
      }
    }
  }

  void _paintImages(Canvas canvas, List<TermLine> scrollback, int first,
      double cw, double ch, Size size) {
    final src = buffer.kitty.placements;
    if (src.isEmpty) return;
    final sbLen = scrollback.length;
    final list = List<KittyPlacement>.of(src)
      ..sort((a, b) => a.z.compareTo(b.z));
    for (final pl in list) {
      final img = buffer.kitty.imageById(pl.imageId);
      if (img == null) continue;
      final x = pl.col * cw;
      final y = (sbLen + pl.row - first) * ch;
      final w = pl.cols > 0 ? pl.cols * cw : img.width.toDouble();
      final h = pl.rows > 0 ? pl.rows * ch : img.height.toDouble();
      if (w <= 0 || h <= 0) continue;
      if (y + h < 0 || y > size.height) continue;
      final srcRect =
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      final dstRect = Rect.fromLTWH(x, y, w, h);
      canvas.drawImageRect(
        img.image,
        srcRect,
        dstRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
  }

  void _paintScrollBadge(Canvas canvas, Size size) {
    final n = scroll.round();
    final style = theme.textStyle.copyWith(
      fontSize: theme.fontSize * 0.85,
      color: theme.foreground.withValues(alpha: 0.95),
      fontWeight: FontWeight.bold,
    );
    final tp = TextPainter(
      text: TextSpan(text: '⬇ $n خط بالاتر (لمس برای پرش به انتها)', style: style),
      textDirection: TextDirection.rtl,
    )..layout();

    final rect = Rect.fromLTWH(
      (size.width - tp.width - 24) / 2, 12,
      tp.width + 24, tp.height + 10,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xDD1E1E2E),
    );
    tp.paint(canvas, Offset(rect.left + 12, rect.top + 5));
  }

  @override
  bool shouldRepaint(covariant _TerminalPainter oldDelegate) => true;
}
