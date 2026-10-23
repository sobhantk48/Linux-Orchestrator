import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════
//  RTL / Shaping Probe
//  هدف: بفهمیم موتور متن Flutter فارسی را درست می‌کشد یا نه
// ═══════════════════════════════════════════════════════════

class ProbePage extends StatelessWidget {
  const ProbePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RTL / Shaping Probe')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: const [
          ProbeCase(
            title: '۱) run کامل + rtl  ← این حالت درست است',
            text: 'سلام دنیا',
            dir: TextDirection.rtl,
            expect: 'وصل و راست‌به‌چپ',
          ),
          ProbeCase(
            title: '۲) run کامل + ltr  ← شکل‌دهی هست، ترتیب نیست',
            text: 'سلام دنیا',
            dir: TextDirection.ltr,
            expect: 'وصل ولی چپ‌به‌راست (ترتیب غلط)',
          ),
          ProbeCase(
            title: '۳) نیم‌فاصله (ZWNJ)',
            text: 'می‌شود و نمی‌شود',
            dir: TextDirection.rtl,
            expect: '«می‌شود» یک تکه، بدون فاصله‌ی اضافی',
          ),
          ProbeCase(
            title: '۴) لیگاچر «لا»',
            text: 'لا اله الا الله',
            dir: TextDirection.rtl,
            expect: 'لام-الف یک گلیف واحد (ﻻ)',
          ),
          ProbeCase(
            title: '۵) اعراب',
            text: 'کِتابِ من',
            dir: TextDirection.rtl,
            expect: 'کسره روی ک و ب، نه کنارشان',
          ),
          ProbeCase(
            title: '۶) متن مخلوط (BiDi)',
            text: 'echo "سلام دنیا" > out.txt',
            dir: TextDirection.rtl,
            expect: 'فارسی وسط، لاتین و علامت‌ها سر جایشان',
          ),
          ProbeCase(
            title: '۷) اعداد فارسی',
            text: 'فایل ۱۲۳۴۵ خط دارد',
            dir: TextDirection.rtl,
            expect: 'اعداد به ترتیب ۱۲۳۴۵ (نه ۵۴۳۲۱)',
          ),

          SizedBox(height: 20),
          _SectionTitle('شبیه‌سازی گرید سلولی xterm'),
          _Note('اینجا هر کاراکتر جدا کشیده می‌شود — همان کاری که xterm.dart می‌کند'),
          GridSimulation(text: 'سلام', reversed: false),
          GridSimulation(text: 'سلام', reversed: true),

          SizedBox(height: 20),
          _SectionTitle('تست روی Canvas (نزدیک‌ترین حالت به ترمینال)'),
          _Note('بالا: یک TextPainter برای کل run  |  پایین: یک TextPainter برای هر کاراکتر'),
          CanvasProbe(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  یک کارت تست
// ─────────────────────────────────────────────
class ProbeCase extends StatelessWidget {
  final String title;
  final String text;
  final TextDirection dir;
  final String expect;

  const ProbeCase({
    super.key,
    required this.title,
    required this.text,
    required this.dir,
    required this.expect,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0E1014),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                text,
                textDirection: dir,
                textAlign: dir == TextDirection.rtl
                    ? TextAlign.right
                    : TextAlign.left,
                style: const TextStyle(fontSize: 23, color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'انتظار: $expect',
              style: const TextStyle(fontSize: 11.5, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  شبیه‌سازی: هر کاراکتر یک ویجت جدا
// ─────────────────────────────────────────────
class GridSimulation extends StatelessWidget {
  final String text;
  final bool reversed;

  const GridSimulation({
    super.key,
    required this.text,
    required this.reversed,
  });

  @override
  Widget build(BuildContext context) {
    final chars = text.split('');
    final list = reversed ? chars.reversed.toList() : chars;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              reversed ? 'reversed:' : 'logical:',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ),
          ...list.map(
            (c) => Container(
              margin: const EdgeInsets.only(right: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white12),
                color: const Color(0xFF14171D),
              ),
              child: Text(
                c,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 21, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
//  تست Canvas
// ─────────────────────────────────────────────
class CanvasProbe extends StatelessWidget {
  const CanvasProbe({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1014),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
      ),
      child: const Column(
        children: [
          CustomPaint(
            size: Size(double.infinity, 44),
            painter: _LinePainter(text: 'echo "سلام دنیا"', perChar: false),
          ),
          Divider(color: Colors.white12, height: 1),
          CustomPaint(
            size: Size(double.infinity, 44),
            painter: _LinePainter(text: 'echo "سلام دنیا"', perChar: true),
          ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final String text;
  final bool perChar;

  const _LinePainter({required this.text, required this.perChar});

  static const _style = TextStyle(
    fontSize: 19,
    color: Colors.white,
    fontFamily: 'monospace',
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (!perChar) {
      final tp = TextPainter(
        text: const TextSpan(text: 'echo "سلام دنیا"', style: _style),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout(maxWidth: size.width - 8);
      tp.paint(canvas, const Offset(6, 10));
    } else {
      var x = 6.0;
      for (final ch in text.split('')) {
        final tp = TextPainter(
          text: TextSpan(text: ch, style: _style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        tp.paint(canvas, Offset(x, 10));
        x += 11.4;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.text != text || old.perChar != perChar;
}

// ─────────────────────────────────────────────
//  تیتر و توضیح
// ─────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.tealAccent,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11.5, color: Colors.white54),
      ),
    );
  }
}
