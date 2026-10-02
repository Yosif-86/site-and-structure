import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The official ARC Platform mark (brand sheet V5): one continuous stroke
/// that rises into an arch, comes down the right leg and loops back across
/// as the crossbar and tail of the A. Geometry copied 1:1 from the design
/// canvas (viewBox 211 249 400 400, stroke 44, round joins, clipped at the
/// bottom so the tail ends flush).
class ArcMarkPainter extends CustomPainter {
  /// 0..1 — how much of the stroke is drawn (1 = the full mark).
  final double progress;
  final Color color;
  final double strokeWidth;

  /// Draws a soft glow at the moving end of the line while it animates.
  final bool showHead;

  ArcMarkPainter({
    this.progress = 1,
    this.color = const Color(0xFFE8622C),
    this.strokeWidth = 44,
    this.showHead = false,
  });

  static final Path _path = Path()
    ..moveTo(347, 456)
    ..lineTo(399, 320)
    ..quadraticBezierTo(418, 270, 438, 320)
    ..lineTo(540, 575)
    ..cubicTo(552, 605, 530, 618, 505, 598)
    ..lineTo(420, 532)
    ..cubicTo(400, 514, 330, 496, 306, 566)
    ..lineTo(280, 645);

  static final ui.PathMetric _metric = _path.computeMetrics().first;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0) return;

    canvas.save();
    canvas.scale(size.width / 400, size.height / 400);
    canvas.translate(-211, -249);
    canvas.clipRect(const Rect.fromLTWH(200, 240, 420, 388));

    final drawn = p >= 1 ? _path : _metric.extractPath(0, _metric.length * p);
    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = p >= 1 ? StrokeCap.butt : StrokeCap.round
        ..color = color,
    );

    if (showHead && p < 1) {
      final tangent = _metric.getTangentForOffset(_metric.length * p);
      if (tangent != null) {
        canvas.drawCircle(
          tangent.position,
          strokeWidth * 0.9,
          Paint()
            ..color = const Color(0xFFF2B544).withValues(alpha: 0.55)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
        );
        canvas.drawCircle(tangent.position, strokeWidth * 0.32,
            Paint()..color = const Color(0xFFFEE4BF));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ArcMarkPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.showHead != showHead;
}

/// The static mark at any size.
class ArcMark extends StatelessWidget {
  final double size;
  final Color color;
  const ArcMark({super.key, this.size = 32, this.color = const Color(0xFFE8622C)});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: ArcMarkPainter(color: color)),
      );
}

/// The mark drawing itself in, like a snake tracing the A from its first
/// point to the tail, then settling. Plays once when it appears; respects
/// the system "reduce motion" setting by showing the finished mark.
class AnimatedArcMark extends StatefulWidget {
  final double size;
  final Color color;
  final Duration duration;
  const AnimatedArcMark({
    super.key,
    this.size = 120,
    this.color = const Color(0xFFE8622C),
    this.duration = const Duration(milliseconds: 1900),
  });

  @override
  State<AnimatedArcMark> createState() => _AnimatedArcMarkState();
}

class _AnimatedArcMarkState extends State<AnimatedArcMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: ArcMarkPainter(
            progress: _t.value,
            color: widget.color,
            showHead: true,
          ),
        ),
      ),
    );
  }
}

/// The primary logo lockup (V5): ARC PLATFORM over منصة آرك, an orange
/// divider, then the mark. In an RTL row the first child sits on the right,
/// so the mark lands on the right and the words on the left, as designed.
class ArcLogo extends StatelessWidget {
  final double height;
  final Color textColor;
  const ArcLogo({
    super.key,
    this.height = 40,
    this.textColor = const Color(0xFFFEE4BF),
  });

  @override
  Widget build(BuildContext context) {
    final latin = height * 0.34;
    final arabic = height * 0.30;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArcMark(size: height),
          SizedBox(width: height * 0.2),
          Container(
              width: 1.5, height: height * 0.84, color: const Color(0xFFE8622C)),
          SizedBox(width: height * 0.2),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ARC PLATFORM',
                  textDirection: TextDirection.ltr,
                  style: GoogleFonts.montserrat(
                      fontSize: latin,
                      fontWeight: FontWeight.w400,
                      letterSpacing: latin * 0.06,
                      height: 1,
                      color: textColor)),
              SizedBox(height: height * 0.08),
              Text('منصة آرك',
                  style: GoogleFonts.alexandria(
                      fontSize: arabic,
                      fontWeight: FontWeight.w400,
                      height: 1.15,
                      color: textColor)),
            ],
          ),
        ],
      ),
    );
  }
}
