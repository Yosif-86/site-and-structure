import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Timeline of the sign-in screen's "Blueprint Pour" animation, in seconds.
/// tool/render_sounds.js renders its sound effects against the same times.
class BlueprintTimeline {
  static const guides = [
    (0.35, 0.55), (0.55, 0.45), (0.72, 0.5), (0.9, 0.6), (1.08, 0.4), (1.22, 0.25)
  ];
  static const textTrace = 1.3;
  static const outlineAt = 1.5;
  static const fillAt = 1.9;
  static const fillDur = 1.5;
  static const settle = fillAt + fillDur;
  static const textPour = 3.2;

  /// The logo starts moving up to its slot and the form comes in.
  static const lift = 4.4;
  static const liftDur = 0.9;

  /// Everything has landed; the idle light sweep takes over.
  static const end = lift + liftDur + 0.6;
}

/// The ARC mark and wordmark drawn as a technical drawing that fills with
/// molten orange: construction lines and dimensions are sketched, the A's
/// outline flickers on, the wordmark is traced in pencil, liquid rises inside
/// the A (and then the letters), cools to cream, and the guides fade away.
///
/// Pure function of [t] (seconds into the timeline); pass a value at or past
/// [BlueprintTimeline.end] for the finished logo. [shine] (0..1, negative to
/// hide) is the idle light sweep across the mark.
class BlueprintLogo extends StatelessWidget {
  final double t;
  final double shine;
  final double width;

  const BlueprintLogo(
      {super.key, required this.t, this.shine = -1, this.width = 230});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(width, width * 1.2),
        painter: _BlueprintPainter(t, shine),
      ),
    );
  }
}

const _orange = Color(0xFFE8622C);
const _amber = Color(0xFFF2B544);
const _deep = Color(0xFFC94E1F);
const _cream = Color(0xFFFEE4BF);
const _sheet = Color(0xFF14120F);

final Path _mark = Path()
  ..moveTo(347, 456)
  ..lineTo(399, 320)
  ..quadraticBezierTo(418, 270, 438, 320)
  ..lineTo(540, 575)
  ..cubicTo(552, 605, 530, 618, 505, 598)
  ..lineTo(420, 532)
  ..cubicTo(400, 514, 330, 496, 306, 566)
  ..lineTo(280, 645);

const _clip = Rect.fromLTWH(150, 190, 520, 438);

final List<Path> _guidePaths = [
  Path()..moveTo(190, 628)..lineTo(640, 628),
  Path()..moveTo(321, 524)..lineTo(412, 286),
  Path()..moveTo(417.6, 269)..lineTo(555, 613),
  Path()..addOval(Rect.fromCircle(center: const Offset(418, 300), radius: 62)),
  Path()..moveTo(249, 583)..lineTo(466, 518),
  Path()..moveTo(457, 460)..lineTo(521, 435),
];

class _Bubble {
  final double x, at, v, r;
  const _Bubble(this.x, this.at, this.v, this.r);
}

final List<_Bubble> _bubbles = () {
  final rnd = math.Random(7);
  return List.generate(14, (_) {
    return _Bubble(
      290 + rnd.nextDouble() * 260,
      BlueprintTimeline.fillAt +
          rnd.nextDouble() * (BlueprintTimeline.fillDur - 0.3),
      220 + rnd.nextDouble() * 160,
      2.5 + rnd.nextDouble() * 3,
    );
  });
}();

double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
double _inOutCubic(double x) =>
    x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;
double _inOutSine(double x) => -(math.cos(math.pi * x) - 1) / 2;
double _outCubic(double x) => 1 - math.pow(1 - x, 3).toDouble();

class _BlueprintPainter extends CustomPainter {
  final double t;
  final double shine;
  _BlueprintPainter(this.t, this.shine);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 500);
    canvas.translate(-161, -199);

    _paintGuides(canvas);
    _paintOutline(canvas);
    _paintLiquid(canvas);
    _paintWords(canvas);

    canvas.restore();
  }

  // ---- construction lines, nodes, dimension labels ----
  void _paintGuides(Canvas canvas) {
    const tl = BlueprintTimeline.settle;
    final groupFade = 1 - _clamp01((t - tl) / 0.7);
    if (groupFade <= 0) return;

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = _cream.withValues(alpha: 0.42 * groupFade);

    for (var i = 0; i < _guidePaths.length; i++) {
      final (at, dur) = BlueprintTimeline.guides[i];
      final p = _inOutCubic(_clamp01((t - at) / dur));
      if (p <= 0) continue;
      final metric = _guidePaths[i].computeMetrics().first;
      canvas.drawPath(metric.extractPath(0, metric.length * p), line);
    }

    final nodeA = _clamp01((t - 1.25) / 0.3) * groupFade;
    if (nodeA > 0) {
      final node = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = _cream.withValues(alpha: 0.6 * nodeA);
      canvas.drawLine(const Offset(408, 300), const Offset(428, 300), node);
      canvas.drawLine(const Offset(418, 290), const Offset(418, 310), node);
      for (final c in const [Offset(347, 456), Offset(540, 575), Offset(420, 532)]) {
        canvas.drawCircle(c, 5, node);
      }
      final dot = Paint()..color = _cream.withValues(alpha: 0.6 * nodeA);
      canvas.drawCircle(const Offset(457, 460), 3, dot);
      canvas.drawCircle(const Offset(521, 435), 3, dot);
    }

    const labels = [
      ('R62', Offset(486, 246)),
      ('44', Offset(530, 428)),
      ('69°', Offset(262, 500)),
      ('±0.00', Offset(560, 650)),
    ];
    for (var i = 0; i < labels.length; i++) {
      final a = _clamp01((t - 1.35 - i * 0.06) / 0.4);
      if (a <= 0) continue;
      final (text, at) = labels[i];
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: GoogleFonts.ibmPlexMono(
              fontSize: 15, color: _cream.withValues(alpha: 0.55 * a * groupFade)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final base = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      tp.paint(canvas, at.translate(0, -base + 6 * (1 - a)));
    }
  }

  // ---- the A's outline, flickering on like a light table ----
  void _paintOutline(Canvas canvas) {
    const keys = [(0.0, 0.0), (0.2, 0.7), (0.4, 0.15), (0.65, 0.9), (0.8, 0.4), (1.0, 1.0)];
    final p = _clamp01((t - BlueprintTimeline.outlineAt) / 0.4);
    var a = 0.0;
    for (var i = 1; i < keys.length; i++) {
      if (p <= keys[i].$1) {
        final (o0, v0) = keys[i - 1];
        final (o1, v1) = keys[i];
        a = v0 + (v1 - v0) * ((p - o0) / (o1 - o0));
        break;
      }
    }
    a *= 1 - _clamp01((t - BlueprintTimeline.settle - 0.1) / 0.6);
    if (a <= 0) return;

    canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: a));
    canvas.save();
    canvas.clipRect(_clip);
    canvas.drawPath(
        _mark,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 46
          ..strokeJoin = StrokeJoin.round
          ..color = _cream);
    canvas.drawPath(
        _mark,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 42
          ..strokeJoin = StrokeJoin.round
          ..color = _sheet);
    canvas.restore();
    canvas.drawLine(const Offset(325.5, 447.8), const Offset(368.5, 464.2),
        Paint()
          ..strokeWidth = 2
          ..color = _cream);
    canvas.restore();
  }

  Path _wave(double level, double amp, double ph) {
    final p = Path()..moveTo(150, 710)..lineTo(150, level);
    for (double x = 150; x <= 670; x += 10) {
      p.lineTo(x, level + amp * math.sin(x * 0.035 + ph) +
          amp * 0.4 * math.sin(x * 0.08 - ph * 1.7));
    }
    return p
      ..lineTo(670, 710)
      ..close();
  }

  // ---- molten orange rising inside the A ----
  void _paintLiquid(Canvas canvas) {
    final lt = _clamp01((t - BlueprintTimeline.fillAt) / BlueprintTimeline.fillDur);
    if (lt <= 0) return;
    final level = 652 - (652 - 255) * _inOutSine(lt);
    final amp = t < BlueprintTimeline.settle
        ? 9.0
        : 9 * math.exp(-(t - BlueprintTimeline.settle) * 2.5);
    const bounds = Rect.fromLTWH(150, 190, 520, 520);

    canvas.saveLayer(bounds, Paint());
    canvas.drawPath(_wave(level - 6, amp * 1.2, t * 4 + 2),
        Paint()..color = _orange.withValues(alpha: 0.45));
    canvas.drawPath(
      _wave(level, amp, t * 5),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, level - amp),
          const Offset(0, 640),
          const [_amber, _orange, _deep],
          const [0, 0.22, 1],
        ),
    );
    final bubble = Paint()..color = _cream.withValues(alpha: 0.4);
    for (final b in _bubbles) {
      final y = 640 - (t - b.at) * b.v;
      if (t > b.at && y > level + 6) {
        canvas.drawCircle(
            Offset(b.x + math.sin((t - b.at) * 9) * 3, y), b.r, bubble);
      }
    }
    if (shine >= 0 && shine < 1) {
      canvas.save();
      canvas.translate(300 + 480 * shine, 0);
      canvas.transform(Matrix4.skewX(math.tan(-18 * math.pi / 180)).storage);
      canvas.drawRect(
        const Rect.fromLTWH(0, 240, 90, 420),
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 0),
            const Offset(90, 0),
            [
              _cream.withValues(alpha: 0),
              _cream.withValues(alpha: 0.55),
              _cream.withValues(alpha: 0),
            ],
            const [0, 0.5, 1],
          ),
      );
      canvas.restore();
    }

    // Keep only what falls inside the A's stroke.
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
    canvas.clipRect(_clip);
    canvas.drawPath(
        _mark,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 44
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white);
    canvas.restore();
    canvas.restore();
  }

  // ---- wordmark: pencil trace, then the pour, then it cools to cream ----
  void _paintWords(Canvas canvas) {
    _word(
      canvas,
      text: 'ARC PLATFORM',
      style: GoogleFonts.montserrat(
          fontSize: 38, fontWeight: FontWeight.w300, letterSpacing: 10),
      direction: TextDirection.ltr,
      centerX: 416,
      baseline: 700,
      trimEnd: 10,
      traceAt: BlueprintTimeline.textTrace,
      traceDur: 0.9,
      pourAt: BlueprintTimeline.textPour,
      pourTop: 664,
      pourBottom: 706,
      coolAt: BlueprintTimeline.textPour + 0.7,
    );
    _word(
      canvas,
      text: 'منصة آرك',
      style: const TextStyle(
          fontFamily: 'ArcArabic', fontSize: 44, fontWeight: FontWeight.w300),
      direction: TextDirection.rtl,
      centerX: 416,
      baseline: 772,
      traceAt: BlueprintTimeline.textTrace + 0.2,
      traceDur: 1.0,
      pourAt: BlueprintTimeline.textPour + 0.15,
      pourTop: 720,
      pourBottom: 796,
      coolAt: BlueprintTimeline.textPour + 0.85,
    );
  }

  void _word(
    Canvas canvas, {
    required String text,
    required TextStyle style,
    required TextDirection direction,
    required double centerX,
    required double baseline,
    double trimEnd = 0,
    required double traceAt,
    required double traceDur,
    required double pourAt,
    required double pourTop,
    required double pourBottom,
    required double coolAt,
  }) {
    final trace = _inOutCubic(_clamp01((t - traceAt) / traceDur));
    if (trace <= 0) return;

    TextPainter layout(Paint fg) => TextPainter(
          text: TextSpan(text: text, style: style.copyWith(foreground: fg)),
          textDirection: direction,
        )..layout();

    final traceFade = 1 - _clamp01((t - coolAt) / 0.5);
    final outline = layout(Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = _cream.withValues(alpha: 0.5 * traceFade));
    final w = outline.width - trimEnd;
    final x0 = centerX - w / 2;
    final y0 = baseline -
        outline.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final origin = Offset(x0, y0);

    // Pencil trace: revealed in reading direction.
    if (traceFade > 0) {
      canvas.save();
      final rw = (outline.width + 4) * trace;
      final ltr = direction == TextDirection.ltr;
      canvas.clipRect(Rect.fromLTWH(
          ltr ? x0 - 2 : x0 + outline.width + 2 - rw, y0 - 10, rw,
          outline.height + 20));
      outline.paint(canvas, origin);
      canvas.restore();
    }

    // Pour: orange rises from the bottom, then cools to cream.
    final pour = _inOutSine(_clamp01((t - pourAt) / 0.6));
    if (pour <= 0) return;
    final cool = _outCubic(_clamp01((t - coolAt) / 0.7));
    final fill = layout(Paint()..color = Color.lerp(_orange, _cream, cool)!);
    canvas.save();
    final h = (pourBottom - pourTop) * pour;
    canvas.clipRect(Rect.fromLTWH(x0 - 10, pourBottom - h, fill.width + 20, h));
    fill.paint(canvas, origin);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlueprintPainter old) =>
      old.t != t || old.shine != shine;
}
