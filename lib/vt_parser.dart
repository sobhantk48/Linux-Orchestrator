// lib/vt_parser.dart
//
// یک پارسر جریانی VT500-ish: ورودی کدپوینت، خروجی callback معنایی.
// هیچ‌وقت به صفحه دست نمی‌زنه؛ TermBuffer این کار رو می‌کنه.
// همین جداسازی باعث می‌شه escape sequence هایی که وسط read PTY نصف می‌شن،
// سالم بمونن.

class CsiSeq {
  /// 0x3C..0x3F برای '<' '=' '>' '?' — وگرنه 0
  final int privateMarker;

  /// 0x20..0x2F (مثل '!' در CSI ! p) — وگرنه 0
  final int intermediate;

  /// پارامترها؛ -1 یعنی «صریحاً خالی» (مثل `\x1b[;5H`)
  final List<int> params;

  /// بایت پایانی، مثل 0x6D برای 'm'
  final int finalByte;

  const CsiSeq({
    required this.privateMarker,
    required this.intermediate,
    required this.params,
    required this.finalByte,
  });

  /// پارامتر i، یا [def] وقتی غایب/خالی است.
  int p(int i, [int def = 0]) {
    if (i < 0 || i >= params.length) return def;
    final v = params[i];
    return v < 0 ? def : v;
  }

  int get count => params.length;

  @override
  String toString() =>
      'CSI(priv=$privateMarker, inter=$intermediate, params=$params, '
      'final=${String.fromCharCode(finalByte)})';
}

class VtParser {
  VtParser({
    required this.onPrint,
    required this.onExecute,
    required this.onCsi,
    required this.onEsc,
    required this.onOsc,
  });

  final void Function(int codepoint) onPrint;
  final void Function(int codepoint) onExecute;
  final void Function(CsiSeq seq) onCsi;
  final void Function(int finalByte, int intermediate) onEsc;
  final void Function(String data) onOsc;

  static const int _sGround = 0;
  static const int _sEscape = 1;
  static const int _sEscInt = 2;
  static const int _sCsi = 3;
  static const int _sOsc = 4;
  static const int _sOscEsc = 5;
  static const int _sStr = 6;
  static const int _sStrEsc = 7;

  int _state = _sGround;
  final List<int> _params = <int>[];
  int _cur = -1;
  int _priv = 0;
  int _inter = 0;
  final StringBuffer _osc = StringBuffer();
  final List<int> _printBuf = <int>[];
  int _pendingHigh = 0;

  /// فقط برای تست/ریست دستی؛ در جریان عادی لازم نیست.
  void reset() {
    _state = _sGround;
    _params.clear();
    _cur = -1;
    _priv = 0;
    _inter = 0;
    _osc.clear();
    _printBuf.clear();
    _pendingHigh = 0;
  }

  /// ورودی متنی (بعد از UTF-8 decode). می‌تونه هر جایی بریده باشه.
  void write(String data) {
    if (data.isEmpty) return;
    final units = data.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final cu = units[i];

      if (_pendingHigh != 0) {
        final high = _pendingHigh;
        _pendingHigh = 0;
        if (cu >= 0xDC00 && cu <= 0xDFFF) {
          _feed(0x10000 + ((high - 0xD800) << 10) + (cu - 0xDC00));
          continue;
        }
        // سوروگیت تنها: همون رو رد کن، بعد ادامه بده
        _feed(high);
      }

      if (cu >= 0xD800 && cu <= 0xDBFF) {
        _pendingHigh = cu;
        continue;
      }
      if (cu >= 0xDC00 && cu <= 0xDFFF) continue; // سوروگیت پایین سرگردان
      _feed(cu);
    }
    _flushPrint();
  }

  // ------------------------------------------------------------------ core

  void _feed(int cp) {
    switch (_state) {
      case _sGround:
        _ground(cp);
        break;
      case _sEscape:
        _escape(cp);
        break;
      case _sEscInt:
        _escInt(cp);
        break;
      case _sCsi:
        _csi(cp);
        break;
      case _sOsc:
        _oscFeed(cp);
        break;
      case _sOscEsc:
        _oscEsc(cp);
        break;
      case _sStr:
        _str(cp);
        break;
      case _sStrEsc:
        _strEsc(cp);
        break;
      default:
        _state = _sGround;
    }
  }

  void _flushPrint() {
    if (_printBuf.isEmpty) return;
    for (final cp in _printBuf) {
      onPrint(cp);
    }
    _printBuf.clear();
  }

  void _resetSeq() {
    _params.clear();
    _cur = -1;
    _priv = 0;
    _inter = 0;
  }

  // ---------------------------------------------------------------- ground

  void _ground(int cp) {
    if (cp == 0x1B) {
      _flushPrint();
      _resetSeq();
      _state = _sEscape;
      return;
    }
    if (cp == 0x18 || cp == 0x1A) {
      // CAN / SUB
      _flushPrint();
      _resetSeq();
      _state = _sGround;
      return;
    }
    if (cp < 0x20 || cp == 0x7F) {
      _flushPrint();
      if (cp != 0x7F) onExecute(cp);
      return;
    }
    _printBuf.add(cp);
  }

  // ---------------------------------------------------------------- escape

  void _escape(int cp) {
    if (cp == 0x1B) {
      _resetSeq();
      _state = _sEscape;
      return;
    }
    if (cp == 0x18 || cp == 0x1A) {
      _resetSeq();
      _state = _sGround;
      return;
    }
    if (cp < 0x20) {
      onExecute(cp);
      return;
    }
    if (cp >= 0x20 && cp <= 0x2F) {
      _inter = cp;
      _state = _sEscInt;
      return;
    }
    if (cp == 0x5B) {
      _resetSeq();
      _state = _sCsi;
      return;
    }
    if (cp == 0x5D) {
      _osc.clear();
      _state = _sOsc;
      return;
    }
    if (cp == 0x50 || cp == 0x58 || cp == 0x5E || cp == 0x5F) {
      // DCS / SOS / PM / APC: تا ST دور ریخته می‌شن
      _state = _sStr;
      return;
    }
    if (cp >= 0x30 && cp <= 0x7E) {
      onEsc(cp, 0);
      _state = _sGround;
      return;
    }
    _state = _sGround;
  }

  void _escInt(int cp) {
    if (cp == 0x1B) {
      _resetSeq();
      _state = _sEscape;
      return;
    }
    if (cp >= 0x20 && cp <= 0x2F) {
      _inter = cp;
      return;
    }
    if (cp < 0x20) {
      onExecute(cp);
      return;
    }
    if (cp >= 0x30 && cp <= 0x7E) {
      onEsc(cp, _inter);
      _resetSeq();
      _state = _sGround;
      return;
    }
    _resetSeq();
    _state = _sGround;
  }

  // ------------------------------------------------------------------- CSI

  void _csi(int cp) {
    if (cp == 0x1B) {
      _resetSeq();
      _state = _sEscape;
      return;
    }
    if (cp == 0x18 || cp == 0x1A) {
      _resetSeq();
      _state = _sGround;
      return;
    }
    if (cp < 0x20) {
      onExecute(cp);
      return;
    }
    if (cp == 0x7F) return;

    if (cp >= 0x30 && cp <= 0x39) {
      if (_cur < 0) _cur = 0;
      if (_cur < 100000) _cur = _cur * 10 + (cp - 0x30);
      return;
    }
    if (cp == 0x3B) {
      _params.add(_cur);
      _cur = -1;
      return;
    }
    if (cp >= 0x3C && cp <= 0x3F) {
      _priv = cp;
      return;
    }
    if (cp >= 0x20 && cp <= 0x2F) {
      _inter = cp;
      return;
    }
    if (cp >= 0x40 && cp <= 0x7E) {
      if (_cur >= 0 || _params.isNotEmpty) _params.add(_cur);
      final seq = CsiSeq(
        privateMarker: _priv,
        intermediate: _inter,
        params: List<int>.unmodifiable(_params),
        finalByte: cp,
      );
      _resetSeq();
      _state = _sGround;
      onCsi(seq);
      return;
    }
  }

  // ------------------------------------------------------------------- OSC

  void _oscFeed(int cp) {
    if (cp == 0x07) {
      _emitOsc();
      return;
    }
    if (cp == 0x1B) {
      _state = _sOscEsc;
      return;
    }
    if (cp == 0x18 || cp == 0x1A) {
      _osc.clear();
      _state = _sGround;
      return;
    }
    if (_osc.length < 8192) _osc.writeCharCode(cp);
  }

  void _oscEsc(int cp) {
    if (cp == 0x5C) {
      // ST
      _emitOsc();
      return;
    }
    if (cp == 0x1B) return;
    _osc.writeCharCode(0x1B);
    _state = _sOsc;
    _oscFeed(cp);
  }

  void _emitOsc() {
    final s = _osc.toString();
    _osc.clear();
    _state = _sGround;
    onOsc(s);
  }

  // ------------------------------------------------------------ DCS/SOS/PM

  void _str(int cp) {
    if (cp == 0x1B) {
      _state = _sStrEsc;
      return;
    }
    if (cp == 0x07 || cp == 0x18 || cp == 0x1A) {
      _state = _sGround;
    }
  }

  void _strEsc(int cp) {
    if (cp == 0x5C) {
      _state = _sGround;
      return;
    }
    if (cp == 0x1B) return;
    _state = _sStr;
  }
}
