import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'term_buffer.dart';

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

class RtlTerminalView extends StatefulWidget {
  final TermBuffer buffer;
  final RtlTerminalTheme theme;
  final VoidCallback? onTap;
  final ValueChanged<String>? onInput;

  const RtlTerminalView({
    super.key,
    required this.buffer,
    this.theme = const RtlTerminalTheme(),
    this.onTap,
    this.onInput,
  });

  @override
  State<RtlTerminalView> createState() => RtlTerminalViewState();
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

  double get currentScroll => _scroll;

  void scrollToBottom({bool animate = true}) {
    if (_scroll <= 0.0) return;
    _scrollController.stop();
    if (!animate) {
      setState(() {
        _scroll = 0.0;
      });
      return;
    }
    final anim = Tween<double>(begin: _scroll, end: 0.0).animate(
      CurvedAnimation(parent: _scrollController, curve: Curves.easeOutCubic),
    );
    _scrollController.reset();
    anim.addListener(() {
      setState(() {
        _scroll = anim.value;
      });
    });
    _scrollController.duration = const Duration(milliseconds: 200);
    _scrollController.forward(from: 0.0);
  }

  void _openKeyboard() {
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
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
      _textInputConnection!.show();
    } else {
      _textInputConnection!.show();
    }
  }

  void _closeKeyboard() {
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
        _openKeyboard();
      } else {
        _closeKeyboard();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _openKeyboard();
      }
    });
  }

  void _handleScrollTick() {
    if (_scrollSimulation != null) {
      final simTime = _scrollController.lastElapsedDuration?.inMicroseconds ?? 0;
      final t = simTime / 1e6;
      final val = _scrollSimulation!.x(t);
      final maxScroll = widget.buffer.scrollback.length.toDouble();
      setState(() {
        _scroll = val.clamp(0.0, maxScroll);
      });
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
    _closeKeyboard();
    _focusNode.dispose();
    _scrollController.removeListener(_handleScrollTick);
    _scrollController.dispose();
    super.dispose();
  }

  // TextInputClient implementation
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue? get currentTextEditingValue =>
      const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value.text.isNotEmpty) {
      widget.onInput?.call(value.text);
      if (_scroll > 0.5) {
        scrollToBottom();
      }
      _textInputConnection?.setEditingState(
        const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0)),
      );
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline || action == TextInputAction.done) {
      widget.onInput?.call('\n');
      if (_scroll > 0.5) {
        scrollToBottom();
      }
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowsVisible =
            math.max(1, (constraints.maxHeight / _metrics.height).ceil());

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _openKeyboard();
              if (_scroll > 0.5) {
                scrollToBottom();
              }
              widget.onTap?.call();
            },
            onVerticalDragStart: (_) {
              _scrollController.stop();
              _scrollSimulation = null;
            },
            onVerticalDragUpdate: (details) {
              final maxScroll = widget.buffer.scrollback.length.toDouble();
              final deltaLines = details.primaryDelta != null
                  ? details.primaryDelta! / _metrics.height
                  : 0.0;
              setState(() {
                _scroll = (_scroll + deltaLines).clamp(0.0, maxScroll);
              });
            },
            onVerticalDragEnd: (details) {
              final vY = details.primaryVelocity ?? 0.0;
              if (vY.abs() > 50.0) {
                final vLines = vY / _metrics.height;
                _scrollSimulation = FrictionSimulation(
                  0.015,
                  _scroll,
                  vLines,
                );
                _scrollController.reset();
                _scrollController.forward(from: 0.0);
              }
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

  void _paintLine(Canvas canvas, TermLine line, double y, double cw, double ch) {
    final cells = line.cells;
    final n = cells.length;
    if (n == 0) return;

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

  void _paintCursor(
    Canvas canvas,
    int sbLen,
    int first,
    double cw,
    double ch,
    Size size,
  ) {
    if (scroll > 0.5) return;
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
      (size.width - tp.width - 24) / 2,
      12,
      tp.width + 24,
      tp.height + 10,
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