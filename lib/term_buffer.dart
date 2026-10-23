// lib/term_buffer.dart
//
// گرید سلولی ترمینال: scrollback، alternate screen، SGR کامل، عرض کاراکتر،
// و رندر مجدد هر خط به ANSI برای RtlTerminalView فعلی.

import 'vt_parser.dart';

/// رنگ پیش‌فرض = «همون چیزی که تم می‌گه»
const int kDefaultColor = -1;

const int _kRgbFlag = 0x1000000;

bool isRgbColor(int c) => c >= _kRgbFlag;

int rgbColor(int r, int g, int b) =>
    _kRgbFlag | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);

int _clampi(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

// ---------------------------------------------------------------------------

class TermAttr {
  final int fg;
  final int bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool inverse;
  final bool hidden;
  final bool strike;

  const TermAttr({
    this.fg = kDefaultColor,
    this.bg = kDefaultColor,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.inverse = false,
    this.hidden = false,
    this.strike = false,
  });

  static const TermAttr plain = TermAttr();

  bool get isPlain =>
      fg == kDefaultColor &&
      bg == kDefaultColor &&
      !bold &&
      !dim &&
      !italic &&
      !underline &&
      !inverse &&
      !hidden &&
      !strike;

  @override
  bool operator ==(Object other) =>
      other is TermAttr &&
      other.fg == fg &&
      other.bg == bg &&
      other.bold == bold &&
      other.dim == dim &&
      other.italic == italic &&
      other.underline == underline &&
      other.inverse == inverse &&
      other.hidden == hidden &&
      other.strike == strike;

  @override
  int get hashCode => Object.hash(
        fg, bg, bold, dim, italic, underline, inverse, hidden, strike,
      );

  @override
  String toString() => 'TermAttr(fg=$fg, bg=$bg, b=$bold, u=$underline)';
}

// ---------------------------------------------------------------------------

class TermCell {
  /// متن سلول؛ برای سلول دنباله‌ی کاراکتر پهن خالی است.
  String ch;

  /// width: 0 = دنباله/ردی که باید رد بشه، 1 = معمولی، 2 = سرِ کاراکتر پهن
  int width;

  TermAttr attr;

  TermCell({this.ch = ' ', this.width = 1, this.attr = TermAttr.plain});

  bool get isBlank => ch.isEmpty || ch == ' ';

  void reset() {
    ch = ' ';
    width = 1;
    attr = TermAttr.plain;
  }

  void set(String c, TermAttr a, int w) {
    ch = c;
    attr = a;
    width = w;
  }

  void copyFrom(TermCell o) {
    ch = o.ch;
    width = o.width;
    attr = o.attr;
  }
}

// ---------------------------------------------------------------------------

class TermLine {
  final List<TermCell> cells;

  TermLine(int cols)
      : cells = List<TermCell>.generate(cols, (_) => TermCell(), growable: true);

  int get length => cells.length;

  void clearAll(TermAttr attr) {
    for (final c in cells) {
      c.ch = ' ';
      c.width = 1;
      c.attr = attr;
    }
  }

  void clearRange(int from, int to, TermAttr attr) {
    final a = _clampi(from, 0, cells.length);
    final b = _clampi(to, 0, cells.length);
    for (var i = a; i < b; i++) {
      cells[i].ch = ' ';
      cells[i].width = 1;
      cells[i].attr = attr;
    }
  }

  void resize(int newCols) {
    if (newCols == cells.length) return;
    if (newCols < cells.length) {
      cells.removeRange(newCols, cells.length);
      if (cells.isNotEmpty && cells.last.width == 0) {
        cells.last
          ..ch = ' '
          ..width = 1;
      }
    } else {
      final add = newCols - cells.length;
      for (var i = 0; i < add; i++) {
        cells.add(TermCell());
      }
    }
  }

  void shiftRight(int from, int n) {
    if (from < 0 || from >= cells.length || n <= 0) return;
    n = _clampi(n, 0, cells.length - from);
    for (var i = cells.length - 1; i >= from + n; i--) {
      cells[i].copyFrom(cells[i - n]);
    }
    for (var i = from; i < from + n; i++) {
      cells[i].reset();
    }
  }

  void shiftLeft(int from, int n) {
    if (from < 0 || from >= cells.length || n <= 0) return;
    n = _clampi(n, 0, cells.length - from);
    for (var i = from; i + n < cells.length; i++) {
      cells[i].copyFrom(cells[i + n]);
    }
    for (var i = cells.length - n; i < cells.length; i++) {
      cells[i].reset();
    }
  }
}

// ---------------------------------------------------------------------------

class TermBuffer {
  int cols;
  int rows;
  int maxScrollback;

  final List<TermLine> _scrollback = <TermLine>[];

  late List<TermLine> _normal;
  late List<TermLine> _alt;
  bool _altMode = false;

  List<TermLine> get _lines => _altMode ? _alt : _normal;

  /// viewport (به طول rows)
  List<TermLine> get lines => _lines;

  /// آیا در alternate screen هستیم (vim/nano/htop)
  bool get isAltScreen => _altMode;

  /// خطوطی که از بالا بیرون رفته‌اند (قدیمی‌ترین اول)
  List<TermLine> get scrollback => _scrollback;

  int cursorRow = 0;
  int cursorCol = 0;
  bool cursorVisible = true;

  TermAttr _attr = TermAttr.plain;
  bool _autoWrap = true;
  bool _insertMode = false;
  bool _wrapPending = false;

  int _scrollTop = 0;
  int _scrollBottom = 0;

  int _savedRow = 0;
  int _savedCol = 0;
  TermAttr _savedAttr = TermAttr.plain;

  int _lastPrinted = 0;

  TermBuffer({
    required this.cols,
    required this.rows,
    this.maxScrollback = 1000,
  }) {
    _normal = _makeScreen(cols, rows);
    _alt = _makeScreen(cols, rows);
    _scrollBottom = rows - 1;
  }

  static List<TermLine> _makeScreen(int c, int r) =>
      List<TermLine>.generate(r, (_) => TermLine(c), growable: true);

  // ------------------------------------------------------------------ print

  void print(int cp) {
    final w = _charWidth(cp);
    if (w < 0) return; // کنترل
    if (w == 0) {
      _appendCombining(cp);
      return;
    }

    if (_wrapPending) {
      if (_autoWrap) {
        cursorCol = 0;
        _lineFeed();
      }
      _wrapPending = false;
    }

    if (cursorCol + w > cols) {
      if (_autoWrap) {
        cursorCol = 0;
        _lineFeed();
      } else {
        cursorCol = _clampi(cols - w, 0, cols - 1);
      }
    }

    final line = _lines[cursorRow];
    if (_insertMode) line.shiftRight(cursorCol, w);

    line.cells[cursorCol].set(String.fromCharCode(cp), _attr, w);
    if (w == 2 && cursorCol + 1 < cols) {
      line.cells[cursorCol + 1].set('', _attr, 0);
    }

    _lastPrinted = cp;
    cursorCol += w;
    if (cursorCol >= cols) {
      cursorCol = cols - 1;
      _wrapPending = true;
    }
  }

  void _appendCombining(int cp) {
    final line = _lines[cursorRow];
    var idx = _wrapPending ? cols - 1 : cursorCol - 1;
    idx = _clampi(idx, 0, cols - 1);
    while (idx > 0 && line.cells[idx].width == 0) {
      idx--;
    }
    final cell = line.cells[idx];
    cell.ch = cell.ch + String.fromCharCode(cp);
  }

  // -------------------------------------------------------------- execute

  void execute(int cp) {
    switch (cp) {
      case 0x0A:
      case 0x0B:
      case 0x0C:
        _lineFeed();
        break;
      case 0x0D:
        cursorCol = 0;
        _wrapPending = false;
        break;
      case 0x08:
        if (cursorCol > 0) cursorCol--;
        _wrapPending = false;
        break;
      case 0x09:
        final next = ((cursorCol ~/ 8) + 1) * 8;
        cursorCol = next >= cols ? cols - 1 : next;
        _wrapPending = false;
        break;
      default:
        // BEL و بقیه: بی‌اثر
        break;
    }
  }

  // --------------------------------------------------------------- escapes

  void esc(int finalByte, int intermediate) {
    switch (finalByte) {
      case 0x44: // D  IND
        _lineFeed();
        break;
      case 0x45: // E  NEL
        cursorCol = 0;
        _lineFeed();
        break;
      case 0x4D: // M  RI
        _reverseIndex();
        break;
      case 0x37: // 7  DECSC
        _saveCursor();
        break;
      case 0x38: // 8  DECRC
        _restoreCursor();
        break;
      case 0x63: // c  RIS
        reset();
        break;
      default:
        // HTS, charset designators (\x1b(B), keypad modes ... → بی‌اثر
        break;
    }
  }

  // ------------------------------------------------------------------- CSI

  void csi(CsiSeq s) {
    if (s.privateMarker == 0x3F) {
      if (s.finalByte == 0x68) {
        _setPrivateModes(s, true);
      } else if (s.finalByte == 0x6C) {
        _setPrivateModes(s, false);
      }
      return;
    }
    if (s.privateMarker != 0) return; // '>' '=' '<' → نادیده

    switch (s.finalByte) {
      case 0x40: // @  ICH
        _lines[cursorRow].shiftRight(cursorCol, s.p(0, 1));
        break;
      case 0x41: // A  CUU
        _moveCursor(0, -s.p(0, 1));
        break;
      case 0x42: // B  CUD
        _moveCursor(0, s.p(0, 1));
        break;
      case 0x43: // C  CUF
        _moveCursor(s.p(0, 1), 0);
        break;
      case 0x44: // D  CUB
        _moveCursor(-s.p(0, 1), 0);
        break;
      case 0x45: // E  CNL
        cursorCol = 0;
        _moveCursor(0, s.p(0, 1));
        break;
      case 0x46: // F  CPL
        cursorCol = 0;
        _moveCursor(0, -s.p(0, 1));
        break;
      case 0x47: // G  CHA
        cursorCol = _clampi(s.p(0, 1) - 1, 0, cols - 1);
        _wrapPending = false;
        break;
      case 0x48: // H  CUP
      case 0x66: // f  HVP
        cursorRow = _clampi(s.p(0, 1) - 1, 0, rows - 1);
        cursorCol = _clampi(s.p(1, 1) - 1, 0, cols - 1);
        _wrapPending = false;
        break;
      case 0x4A: // J  ED
        _eraseDisplay(s.p(0, 0));
        break;
      case 0x4B: // K  EL
        _eraseLine(s.p(0, 0));
        break;
      case 0x4C: // L  IL
        _insertLines(s.p(0, 1));
        break;
      case 0x4D: // M  DL
        _deleteLines(s.p(0, 1));
        break;
      case 0x50: // P  DCH
        _lines[cursorRow].shiftLeft(cursorCol, s.p(0, 1));
        _wrapPending = false;
        break;
      case 0x53: // S  SU
        _scrollUp(s.p(0, 1));
        break;
      case 0x54: // T  SD
        _scrollDown(s.p(0, 1));
        break;
      case 0x58: // X  ECH
        _lines[cursorRow].clearRange(
          cursorCol,
          _clampi(cursorCol + s.p(0, 1), 0, cols),
          _blankAttr(),
        );
        _wrapPending = false;
        break;
      case 0x62: // b  REP
        _repeat(s.p(0, 1));
        break;
      case 0x64: // d  VPA
        cursorRow = _clampi(s.p(0, 1) - 1, 0, rows - 1);
        _wrapPending = false;
        break;
      case 0x6D: // m  SGR
        _sgr(s);
        break;
      case 0x72: // r  DECSTBM
        _setScrollRegion(s);
        break;
      case 0x73: // s  SCOSC
        _saveCursor();
        break;
      case 0x75: // u  SCORC
        _restoreCursor();
        break;
      default:
        // h/l غیر-private، n، c، t، q، g ... → بی‌اثر
        break;
    }
  }

  void _setPrivateModes(CsiSeq s, bool on) {
    for (var i = 0; i < s.params.length; i++) {
      final m = s.params[i];
      switch (m) {
        case 7:
          _autoWrap = on;
          break;
        case 25:
          cursorVisible = on;
          break;
        case 47:
        case 1047:
        case 1049:
          if (on) {
            _enterAlt();
          } else {
            _leaveAlt();
          }
          break;
        default:
          // 1, 12, 1000-1006 (mouse), 2004 (bracketed paste), 2026 ...
          break;
      }
    }
  }

  // ----------------------------------------------------------- SGR handling

  void _sgr(CsiSeq s) {
    final p = s.params;
    if (p.isEmpty) {
      _attr = TermAttr.plain;
      return;
    }

    var fg = _attr.fg;
    var bg = _attr.bg;
    var bold = _attr.bold;
    var dim = _attr.dim;
    var italic = _attr.italic;
    var underline = _attr.underline;
    var inverse = _attr.inverse;
    var hidden = _attr.hidden;
    var strike = _attr.strike;

    var i = 0;
    while (i < p.length) {
      final code = p[i] < 0 ? 0 : p[i];

      if (code == 0) {
        fg = kDefaultColor;
        bg = kDefaultColor;
        bold = false;
        dim = false;
        italic = false;
        underline = false;
        inverse = false;
        hidden = false;
        strike = false;
      } else if (code == 1) {
        bold = true;
      } else if (code == 2) {
        dim = true;
      } else if (code == 3) {
        italic = true;
      } else if (code == 4 || code == 21) {
        underline = true;
      } else if (code == 7) {
        inverse = true;
      } else if (code == 8) {
        hidden = true;
      } else if (code == 9) {
        strike = true;
      } else if (code == 22) {
        bold = false;
        dim = false;
      } else if (code == 23) {
        italic = false;
      } else if (code == 24) {
        underline = false;
      } else if (code == 27) {
        inverse = false;
      } else if (code == 28) {
        hidden = false;
      } else if (code == 29) {
        strike = false;
      } else if (code >= 30 && code <= 37) {
        fg = code - 30;
      } else if (code == 39) {
        fg = kDefaultColor;
      } else if (code >= 40 && code <= 47) {
        bg = code - 40;
      } else if (code == 49) {
        bg = kDefaultColor;
      } else if (code >= 90 && code <= 97) {
        fg = code - 90 + 8;
      } else if (code >= 100 && code <= 107) {
        bg = code - 100 + 8;
      } else if (code == 38 || code == 48) {
        final isFg = code == 38;
        if (i + 1 < p.length) {
          final mode = p[i + 1] < 0 ? 0 : p[i + 1];
          if (mode == 5 && i + 2 < p.length) {
            final idx = _clampi(p[i + 2] < 0 ? 0 : p[i + 2], 0, 255);
            if (isFg) {
              fg = idx;
            } else {
              bg = idx;
            }
            i += 2;
          } else if (mode == 2 && i + 4 < p.length) {
            final r = _clampi(p[i + 2] < 0 ? 0 : p[i + 2], 0, 255);
            final g = _clampi(p[i + 3] < 0 ? 0 : p[i + 3], 0, 255);
            final b = _clampi(p[i + 4] < 0 ? 0 : p[i + 4], 0, 255);
            final c = rgbColor(r, g, b);
            if (isFg) {
              fg = c;
            } else {
              bg = c;
            }
            i += 4;
          }
        }
      }
      i++;
    }

    _attr = TermAttr(
      fg: fg,
      bg: bg,
      bold: bold,
      dim: dim,
      italic: italic,
      underline: underline,
      inverse: inverse,
      hidden: hidden,
      strike: strike,
    );
  }

  // ------------------------------------------------------- cursor / screen

  void _lineFeed() {
    _wrapPending = false;
    if (cursorRow == _scrollBottom) {
      _scrollUp(1);
    } else if (cursorRow < rows - 1) {
      cursorRow++;
    }
  }

  void _reverseIndex() {
    _wrapPending = false;
    if (cursorRow == _scrollTop) {
      _scrollDown(1);
    } else if (cursorRow > 0) {
      cursorRow--;
    }
  }

  void _scrollUp(int n) {
    if (n <= 0) return;
    final height = _scrollBottom - _scrollTop + 1;
    if (n > height) n = height;
    final fullScreen = _scrollTop == 0 && _scrollBottom == rows - 1;
    for (var i = 0; i < n; i++) {
      final removed = _lines.removeAt(_scrollTop);
      if (fullScreen && !_altMode) {
        _scrollback.add(removed);
        while (_scrollback.length > maxScrollback) {
          _scrollback.removeAt(0);
        }
      }
      _lines.insert(_scrollBottom, TermLine(cols));
    }
  }

  void _scrollDown(int n) {
    if (n <= 0) return;
    final height = _scrollBottom - _scrollTop + 1;
    if (n > height) n = height;
    for (var i = 0; i < n; i++) {
      _lines.removeAt(_scrollBottom);
      _lines.insert(_scrollTop, TermLine(cols));
    }
  }

  void _moveCursor(int dx, int dy) {
    if (dy != 0) {
      var r = cursorRow + dy;
      r = _clampi(r, _scrollTop, _scrollBottom);
      cursorRow = r;
    }
    if (dx != 0) {
      var c = cursorCol + dx;
      c = _clampi(c, 0, cols - 1);
      cursorCol = c;
    }
    _wrapPending = false;
  }

  void _setScrollRegion(CsiSeq s) {
    final top = _clampi(s.p(0, 1) - 1, 0, rows - 1);
    final bottom = _clampi(s.p(1, rows) - 1, 0, rows - 1);
    if (top < bottom) {
      _scrollTop = top;
      _scrollBottom = bottom;
      cursorRow = 0;
      cursorCol = 0;
      _wrapPending = false;
    }
  }

  void _insertLines(int n) {
    if (n <= 0) return;
    if (cursorRow < _scrollTop || cursorRow > _scrollBottom) return;
    for (var i = 0; i < n; i++) {
      _lines.removeAt(_scrollBottom);
      _lines.insert(cursorRow, TermLine(cols));
    }
    cursorCol = 0;
    _wrapPending = false;
  }

  void _deleteLines(int n) {
    if (n <= 0) return;
    if (cursorRow < _scrollTop || cursorRow > _scrollBottom) return;
    for (var i = 0; i < n; i++) {
      _lines.removeAt(cursorRow);
      _lines.insert(_scrollBottom, TermLine(cols));
    }
    cursorCol = 0;
    _wrapPending = false;
  }

  TermAttr _blankAttr() =>
      _attr.bg == kDefaultColor ? TermAttr.plain : TermAttr(bg: _attr.bg);

  void _eraseLine(int mode) {
    final a = _blankAttr();
    final line = _lines[cursorRow];
    switch (mode) {
      case 0:
        line.clearRange(cursorCol, cols, a);
        break;
      case 1:
        line.clearRange(0, cursorCol + 1, a);
        break;
      case 2:
        line.clearRange(0, cols, a);
        break;
      default:
        break;
    }
    _wrapPending = false;
  }

  void _eraseDisplay(int mode) {
    final a = _blankAttr();
    switch (mode) {
      case 0:
        _eraseLine(0);
        for (var r = cursorRow + 1; r < rows; r++) {
          _lines[r].clearAll(a);
        }
        break;
      case 1:
        _eraseLine(1);
        for (var r = 0; r < cursorRow; r++) {
          _lines[r].clearAll(a);
        }
        break;
      case 2:
      case 3:
        for (var r = 0; r < rows; r++) {
          _lines[r].clearAll(a);
        }
        if (mode == 3) _scrollback.clear();
        break;
      default:
        break;
    }
    _wrapPending = false;
  }

  void _repeat(int n) {
    if (_lastPrinted == 0 || n <= 0) return;
    for (var i = 0; i < n; i++) {
      print(_lastPrinted);
    }
  }

  void _saveCursor() {
    _savedRow = cursorRow;
    _savedCol = cursorCol;
    _savedAttr = _attr;
  }

  void _restoreCursor() {
    cursorRow = _clampi(_savedRow, 0, rows - 1);
    cursorCol = _clampi(_savedCol, 0, cols - 1);
    _attr = _savedAttr;
    _wrapPending = false;
  }

  // ------------------------------------------------------------ alt screen

  void _enterAlt() {
    if (_altMode) return;
    _altMode = true;
    _alt = _makeScreen(cols, rows);
    cursorRow = 0;
    cursorCol = 0;
    _wrapPending = false;
    _scrollTop = 0;
    _scrollBottom = rows - 1;
  }

  void _leaveAlt() {
    if (!_altMode) return;
    _altMode = false;
    cursorRow = _clampi(cursorRow, 0, rows - 1);
    cursorCol = _clampi(cursorCol, 0, cols - 1);
    _wrapPending = false;
    _scrollTop = 0;
    _scrollBottom = rows - 1;
  }

  // ------------------------------------------------------------------ reset

  void reset() {
    _attr = TermAttr.plain;
    _savedAttr = TermAttr.plain;
    _savedRow = 0;
    _savedCol = 0;
    _lastPrinted = 0;
    cursorRow = 0;
    cursorCol = 0;
    cursorVisible = true;
    _autoWrap = true;
    _insertMode = false;
    _wrapPending = false;
    _scrollTop = 0;
    _scrollBottom = rows - 1;
    _altMode = false;
    _normal = _makeScreen(cols, rows);
    _alt = _makeScreen(cols, rows);
    _scrollback.clear();
  }

  // ----------------------------------------------------------------- resize

  void resize(int newCols, int newRows) {
    newCols = _clampi(newCols, 1, 1000);
    newRows = _clampi(newRows, 1, 500);
    if (newCols == cols && newRows == rows) return;

    for (final l in _normal) {
      l.resize(newCols);
    }
    for (final l in _alt) {
      l.resize(newCols);
    }

    if (newRows != rows) {
      var start = 0;
      if (newRows < rows) {
        start = cursorRow - (newRows - 1);
        if (start < 0) start = 0;
        if (start > rows - newRows) start = rows - newRows;
      }
      _normal = _reshape(_normal, newRows, newCols, start);
      _alt = _reshape(_alt, newRows, newCols, start);
      cursorRow -= start;
    }

    cols = newCols;
    rows = newRows;
    cursorRow = _clampi(cursorRow, 0, rows - 1);
    cursorCol = _clampi(cursorCol, 0, cols - 1);
    _scrollTop = 0;
    _scrollBottom = rows - 1;
    _wrapPending = false;
  }

  List<TermLine> _reshape(
    List<TermLine> old,
    int newRows,
    int newCols,
    int start,
  ) {
    final out = _makeScreen(newCols, newRows);
    if (newRows >= old.length) {
      for (var i = 0; i < old.length; i++) {
        out[i] = old[i];
      }
    } else {
      for (var i = 0; i < newRows; i++) {
        out[i] = old[start + i];
      }
    }
    return out;
  }

  // --------------------------------------------------------- char widths

  static int _charWidth(int cp) {
    if (cp == 0) return 0;
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return -1;
    if (_isZeroWidth(cp)) return 0;
    if (_isWide(cp)) return 2;
    return 1;
  }

  static bool _isZeroWidth(int cp) {
    return (cp >= 0x0300 && cp <= 0x036F) ||
        (cp >= 0x0483 && cp <= 0x0489) ||
        (cp >= 0x0591 && cp <= 0x05BD) ||
        cp == 0x05BF ||
        (cp >= 0x05C1 && cp <= 0x05C2) ||
        (cp >= 0x05C4 && cp <= 0x05C5) ||
        cp == 0x05C7 ||
        (cp >= 0x0610 && cp <= 0x061A) ||
        (cp >= 0x064B && cp <= 0x065F) ||
        cp == 0x0670 ||
        (cp >= 0x06D6 && cp <= 0x06DC) ||
        (cp >= 0x06DF && cp <= 0x06E4) ||
        (cp >= 0x06E7 && cp <= 0x06E8) ||
        (cp >= 0x06EA && cp <= 0x06ED) ||
        cp == 0x0711 ||
        (cp >= 0x0730 && cp <= 0x074A) ||
        (cp >= 0x07A6 && cp <= 0x07B0) ||
        (cp >= 0x07EB && cp <= 0x07F3) ||
        (cp >= 0x0816 && cp <= 0x082D) ||
        (cp >= 0x0859 && cp <= 0x085B) ||
        (cp >= 0x08D3 && cp <= 0x08E1) ||
        (cp >= 0x08E3 && cp <= 0x0903) ||
        (cp >= 0x093A && cp <= 0x093C) ||
        (cp >= 0x0941 && cp <= 0x0948) ||
        (cp >= 0x094D && cp <= 0x0951) ||
        (cp >= 0x1AB0 && cp <= 0x1AFF) ||
        (cp >= 0x1DC0 && cp <= 0x1DFF) ||
        (cp >= 0x200B && cp <= 0x200F) ||
        (cp >= 0x20D0 && cp <= 0x20F0) ||
        (cp >= 0xFE00 && cp <= 0xFE0F) ||
        (cp >= 0xFE20 && cp <= 0xFE2F) ||
        (cp >= 0xE0100 && cp <= 0xE01EF);
  }

  static bool _isWide(int cp) {
    return (cp >= 0x1100 && cp <= 0x115F) ||
        cp == 0x2329 ||
        cp == 0x232A ||
        (cp >= 0x2E80 && cp <= 0x303E) ||
        (cp >= 0x3041 && cp <= 0x33FF) ||
        (cp >= 0x3400 && cp <= 0x4DBF) ||
        (cp >= 0x4E00 && cp <= 0x9FFF) ||
        (cp >= 0xA000 && cp <= 0xA4CF) ||
        (cp >= 0xA960 && cp <= 0xA97F) ||
        (cp >= 0xAC00 && cp <= 0xD7A3) ||
        (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0xFE10 && cp <= 0xFE19) ||
        (cp >= 0xFE30 && cp <= 0xFE6F) ||
        (cp >= 0xFF00 && cp <= 0xFF60) ||
        (cp >= 0xFFE0 && cp <= 0xFFE6) ||
        (cp >= 0x1F300 && cp <= 0x1F64F) ||
        (cp >= 0x1F900 && cp <= 0x1F9FF) ||
        (cp >= 0x1F000 && cp <= 0x1F0FF) ||
        (cp >= 0x20000 && cp <= 0x2FFFD) ||
        (cp >= 0x30000 && cp <= 0x3FFFD);
  }
}
