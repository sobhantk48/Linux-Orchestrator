// lib/rtl_terminal.dart
//
// رندر مستقیم TermBuffer با CustomPainter.
// - بدون regex، بدون بازسازی ANSI: رنگ‌ها از TermAttr خونده می‌شن
// - مکان‌نمای واقعی (بلوک + بازرسم کاراکتر زیرش)
// - اسکرول‌بک با درگ عمودی
// - متریک سلول دقیقاً همون چیزیه که رندر استفاده می‌کنه (بدون اختلاف)

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'term_buffer.dart';

// ---------------------------------------------------------------------------
// پالت پیش‌فرض (همون ۱۶ رنگ VS Code که قبلاً هم داشتی)
// ---------------------------------------------------------------------------

const List<Color> kTerminalPalette = <Color>[
  Color(0xFF000000), // 0  black
  Color(0xFFCD3131), // 1  red
  Color(0xFF0DBC79), // 2  green
  Color(0xFFE5E510), // 3  yellow
  Color(0xFF2472C8), // 4  blue
  Color(0xFFBC3FBC), // 5  magenta
  Color(0xFF11A8CD), // 6  cyan
  Color(0xFFE5E5E5), // 7  white
  Color(0xFF666666), // 8  bright black
  Color(0xFFF14C4C), // 9  bright red
  Color(0xFF23D18B), // 10 bright green
  Color(0xFFF5F543), // 11 bright yellow
  Color(0xFF3B8EEA), // 12 bright blue
  Color(0xFFD670D6), // 13 bright magenta
  Color(0xFF29B8DB), // 14 bright cyan
  Color(0xFFFFFFFF), // 15 bright white
];

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

class RtlTerminalTheme {
  final Color background;
  final Color foreground;
  final Color cursor;
  final double fontSize;
  final String fontFamily;

  /// ارتفاع خط به نسبت fontSize. هم برای اندازه‌گیری سلول و هم برای رندر
  /// استفاده می‌شه، پس هیچ‌وقت واگرا نمی‌شن.
  final double lineHeight;

  final List<Color> palette;

  /// جهت پایه‌ی پاراگراف.
  /// پیش‌فرض LTR است (درست برای پرامپت و ستون‌بندی ترمینال)؛ متن فارسی
  /// داخل همون خط باز هم توسط shaper درست و RTL شکل می‌گیره.
  /// اگه ترمینال تمام‌RTL می‌خوای: TextDirection.rtl
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

  /// کد رنگ بافر (kDefaultColor / 0-15 / 16-255 / RGB) → Color واقعی
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

// ---------------------------------------------------------------------------
// متریک سلول
// ---------------------------------------------------------------------------

class CellMetrics {
  final double width;
  final double height;
  const CellMetrics(this.width, this.height);
}

/// عرض/ارتفاع یک سلول کاراکتری. با همون TextStyle و همون textScaler ای
/// اندازه می‌گیره که رندر استفاده می‌کنه.
CellMetrics measureCellMetrics(RtlTerminalTheme theme) {
  final tp = TextPainter(
    text: TextSpan(text: 'M' * 32, style: theme.textStyle),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
  )..layout();
  return CellMetrics(tp.width / 32.0, tp.height);
}

// ---------------------------------------------------------------------------
// ویو
// ---------------------------------------------------------------------------

class RtlTerminalView extends StatefulWidget {
  final TermBuffer buffer;
  final RtlTerminalTheme theme;
  final VoidCallback? onTap;

  const RtlTerminalView({
    super.key,
    required this.buffer,
    this.theme = const RtlTerminalTheme(),
    this.onTap,
  });

  @override
  State<RtlTerminalView> createState() => _RtlTerminalViewState();
}

class _RtlTerminalViewState extends State<RtlTerminalView> {
  late CellMetrics _metrics;

  /// چند خط از پایین عقب رفته‌ایم (0 = چسبیده به آخرین خروجی)
  double _scroll = 0;
  double _dragAcc = 0;
  int _lastScrollback = 0;

  @override
  void initState() {
    super.initState();
    _metrics = measureCellMetrics(widget.theme);
    _lastScrollback = widget.buffer.scrollback.length;
  }

  @override
  void didUpdateWidget(covariant RtlTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.theme.fontSize != widget.theme.fontSize ||
        oldWidget.theme.fontFamily != widget.theme.fontFamily ||
        oldWidget.theme.lineHeight != widget.theme.lineHeight) {
      _metrics = measureCellMetrics(widget.theme);
    }

    // اگه کاربر عقب رفته و خروجی جدید scrollback رو بزرگ‌تر کرد،
    // همون محتوایی که داشت می‌دید رو نگه دار.
    final sb = widget.buffer.scrollback.length;
    if (_scroll > 0 && sb > _lastScrollback) {
      _scroll += (sb - _lastScrollback).toDouble();
    }
    _lastScrollback = sb;

    final maxScroll = sb.toDouble();
    if (_scroll > maxScroll) _scroll = maxScroll;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowsVisible =
            math.max(1, (constraints.maxHeight / _metrics.height).ceil());

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onVerticalDragStart: (_) => _dragAcc = 0,
          onVerticalDragUpdate: (details) {
            _dragAcc += details.delta.dy;
            final lines = _dragAcc / _metrics.height;
            if (lines.abs() < 1) return;
            final whole = lines.truncate();
            _dragAcc -= whole * _metrics.height;
            final maxScroll = widget.buffer.scrollback.length.toDouble();
            setState(() {
              _scroll = (_scroll + whole).clamp(0.0, maxScroll);
            });
          },
          child: CustomPaint(
            painter: _TerminalPainter(
              buffer: widget.buffer,
              theme: theme,
              metrics: _metrics,
              scroll: _scroll,
              rowsVisible: rowsVisible,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _TerminalPainter extends CustomPainter {
  _TerminalPainter({
    required this.buffer,
    required this.theme,
    required this.metrics,
    required this.scroll,
    required this.rowsVisible,
  });

  final TermBuffer buffer;
  final RtlTerminalTheme theme;
  final CellMetrics metrics;
  final double scroll;
  final int rowsVisible;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = metrics.width;
    final ch = metrics.height;

    canvas.drawRect(Offset.zero & size, Paint()..color = theme.background);

    // در alternate screen (vim/nano/htop) اسکرول‌بک معنی نداره
    final scrollback =
        buffer.isAltScreen ? const <TermLine>[] : buffer.scrollback;
    final screen = buffer.lines;
    final total = scrollback.length + screen.length;

    final bottom = total - scroll.round();
    final first = math.max(0, bottom - rowsVisible);
    final last = math.min(total, bottom);

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (var i = first; i < last; i++) {
      final line = i < scrollback.length
          ? scrollback[i]
          : screen[i - scrollback.length];
      final y = (i - first) * ch;
      _paintLine(canvas, line, y, cw, ch);
    }

    _paintCursor(canvas, scrollback.length, first, cw, ch, size);

    canvas.restore();

    if (scroll > 0.5) _paintScrollBadge(canvas, size);
  }

  // ------------------------------------------------------------ line paint

  void _paintLine(Canvas canvas, TermLine line, double y, double cw, double ch) {
    final cells = line.cells;
    final n = cells.length;
    if (n == 0) return;

    // ۱) پس‌زمینه‌ها (run های هم‌رنگ ادغام می‌شن)
    var i = 0;
    while (i < n) {
      final bg = theme.bgOf(cells[i].attr);
      if (bg == theme.background) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < n && theme.bgOf(cells[j].attr) == bg) {
        j++;
      }
      canvas.drawRect(
        Rect.fromLTWH(i * cw, y, (j - i) * cw, ch),
        Paint()..color = bg,
      );
      i = j;
    }

    // ۲) متن: فاصله‌های خالی انتهاییِ بی‌خاصیت رو نده
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

    final spans = _buildSpans(line, 0, end);
    if (spans.isEmpty) return;

    final tp = TextPainter(
      text: TextSpan(children: spans),
      textDirection: theme.baseDirection,
      maxLines: 1,
      textScaler: TextScaler.noScaling,
    )..layout();
    tp.paint(canvas, Offset(0, y));
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
      if (i == start) i++; // گارد در برابر حلقه‌ی بی‌نهایت
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

  // ----------------------------------------------------------------- cursor

  void _paintCursor(
    Canvas canvas,
    int sbLen,
    int first,
    double cw,
    double ch,
    Size size,
  ) {
    if (scroll > 0.5) return; // در حالت اسکرول، مکان‌نما معنی نداره
    if (!buffer.cursorVisible) return;

    final screen = buffer.lines;
    if (buffer.cursorRow < 0 || buffer.cursorRow >= screen.length) return;

    final line = screen[buffer.cursorRow];
    final y = (sbLen + buffer.cursorRow - first) * ch;
    if (y < -ch || y > size.height) return;

    final col = buffer.cursorCol;
    final x = theme.baseDirection == TextDirection.ltr
        ? _measurePrefix(line, col)
        : col * cw;

    canvas.drawRect(
      Rect.fromLTWH(x, y, cw, ch),
      Paint()..color = theme.cursor.withValues(alpha: 0.7),
    );

    // کاراکتر زیر مکان‌نما رو با رنگ پس‌زمینه دوباره بکش تا خوانا بمونه
    if (col < line.cells.length) {
      final cell = line.cells[col];
      if (cell.ch.isNotEmpty && cell.ch.trim().isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: cell.ch,
            style: theme.textStyle.copyWith(color: theme.background),
          ),
          textDirection: TextDirection.ltr,
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

  // ------------------------------------------------------------------ badge

  void _paintScrollBadge(Canvas canvas, Size size) {
    final n = scroll.round();
    final style = theme.textStyle.copyWith(
      fontSize: theme.fontSize * 0.8,
      color: theme.foreground.withValues(alpha: 0.9),
    );
    final tp = TextPainter(
      text: TextSpan(text: '\u2191 $n', style: style),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromLTWH(
      size.width - tp.width - 20,
      8,
      tp.width + 12,
      tp.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()..color = const Color(0xCC1A1A1A),
    );
    tp.paint(canvas, Offset(rect.left + 6, rect.top + 3));
  }

  // بافر در جا تغییر می‌کنه، پس نمی‌شه از == استفاده کرد
  @override
  bool shouldRepaint(covariant _TerminalPainter oldDelegate) => true;
}
