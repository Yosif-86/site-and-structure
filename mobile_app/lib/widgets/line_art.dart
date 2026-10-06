import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hand-drawn style line illustration: a padlock with a key leaning on it,
/// standing on a short ground line with grass tufts. Used on the forgot
/// password screen, and rendered to PNG for the password email.
/// [ink] draws the lines, [accent] fills the lock and the sparkles.
class LockKeyArt extends StatelessWidget {
  final double width;
  final Color ink;
  final Color accent;
  final Color hole;
  const LockKeyArt({
    super.key,
    this.width = 220,
    required this.ink,
    this.accent = const Color(0xFFE8622C),
    this.hole = Colors.white,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: width * 0.5,
        child: CustomPaint(
            painter: LockKeyPainter(ink: ink, accent: accent, hole: hole)),
      );
}

class LockKeyPainter extends CustomPainter {
  final Color ink;
  final Color accent;
  final Color hole;
  const LockKeyPainter(
      {required this.ink, required this.accent, required this.hole});

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in a 480 x 240 box, scaled to fit.
    final s = size.width / 480;
    canvas.scale(s, s);
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Ground, broken like a pen line, with grass tufts.
    canvas.drawLine(const Offset(70, 212), const Offset(150, 212), line);
    canvas.drawLine(const Offset(166, 212), const Offset(340, 212), line);
    canvas.drawLine(const Offset(356, 212), const Offset(410, 212), line);
    void tuft(double x) {
      final p = line..strokeWidth = 3.5;
      canvas.drawLine(Offset(x, 212), Offset(x - 7, 198), p);
      canvas.drawLine(Offset(x, 212), Offset(x, 194), p);
      canvas.drawLine(Offset(x, 212), Offset(x + 7, 198), p);
      p.strokeWidth = 5;
    }

    tuft(104);
    tuft(384);

    // Padlock: shackle, then the filled body on top of it.
    final shackle = Path()
      ..moveTo(194, 120)
      ..lineTo(194, 92)
      ..arcToPoint(const Offset(266, 92),
          radius: const Radius.circular(36), clockwise: true)
      ..lineTo(266, 120);
    canvas.drawPath(shackle, line..strokeWidth = 9);
    line.strokeWidth = 5;

    final body = RRect.fromRectAndRadius(
        const Rect.fromLTWH(170, 116, 120, 96), const Radius.circular(16));
    canvas.drawRRect(body, Paint()..color = accent);
    canvas.drawRRect(body, line);

    // Keyhole.
    final holePaint = Paint()..color = hole;
    canvas.drawCircle(const Offset(230, 154), 11, holePaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(225, 158, 10, 26), const Radius.circular(4)),
        holePaint);

    // Key leaning against the lock, head up.
    canvas.save();
    canvas.translate(322, 206);
    canvas.rotate(-math.pi / 2 + 0.38);
    canvas.drawLine(const Offset(0, 0), const Offset(96, 0), line);
    canvas.drawLine(const Offset(14, 0), const Offset(14, 14), line);
    canvas.drawLine(const Offset(30, 0), const Offset(30, 10), line);
    canvas.drawCircle(const Offset(116, 0), 20, line);
    canvas.drawCircle(const Offset(116, 0), 6, Paint()..color = ink);
    canvas.restore();

    // Sparkles.
    final spark = Paint()
      ..color = accent
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    void plus(Offset c, double r) {
      canvas.drawLine(c.translate(-r, 0), c.translate(r, 0), spark);
      canvas.drawLine(c.translate(0, -r), c.translate(0, r), spark);
    }

    plus(const Offset(132, 74), 9);
    plus(const Offset(330, 52), 7);
    canvas.drawCircle(const Offset(150, 112), 4, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant LockKeyPainter old) =>
      old.ink != ink || old.accent != accent || old.hole != hole;
}
