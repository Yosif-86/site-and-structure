import 'package:flutter/material.dart';

import '../theme.dart';

/// The backdrop every page sits on: a drafting-sheet grid (fine 24 px
/// squares inside bold 96 px ones) fading out toward the edges, with a warm
/// lamp glow in one corner and a cool one in the other. Cream lines on the
/// dark sheet, ink lines on the white one. Same language as the sign-in
/// screen's blueprint animation.
///
/// Frosted glass only reads as glass when there is something varied behind
/// it to blur, which is what the grid and glows give it. Everything here is
/// static and painted once behind a [RepaintBoundary]. The page content is
/// wrapped in a [BackdropGroup] so every [GlassCard] on the page shares one
/// blur pass instead of each paying for its own.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: BlueprintBackdrop(dark: AppTheme.instance.isDark)),
        BackdropGroup(child: child),
      ],
    );
  }
}

/// The grid sheet on its own, for screens that build their own Stack (the
/// always-dark sign-in screen passes `dark: true`).
class BlueprintBackdrop extends StatelessWidget {
  final bool dark;

  /// Where the grid is fully visible before fading out (0..1 of the
  /// shorter side, measured from [focus]).
  final Alignment focus;

  const BlueprintBackdrop(
      {super.key, required this.dark, this.focus = const Alignment(0, -0.3)});

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF14120F) : const Color(0xFFFCFBF9);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BlueprintPainter(dark: dark, bg: bg, focus: focus),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _BlueprintPainter extends CustomPainter {
  final bool dark;
  final Color bg;
  final Alignment focus;
  _BlueprintPainter({required this.dark, required this.bg, required this.focus});

  static const _minor = 24.0;
  static const _major = 96.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = bg);

    // Corner glows under the grid.
    void glow(Alignment a, double r, Color c) {
      final center = a.alongSize(size);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [c, c.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    final shortest = size.shortestSide;
    glow(const Alignment(1.1, -1.05), shortest * 0.95,
        const Color(0xFFE8622C).withValues(alpha: dark ? 0.14 : 0.08));
    glow(const Alignment(-1.2, 0.35), shortest * 0.85,
        const Color(0xFF6FA8A0).withValues(alpha: dark ? 0.09 : 0.07));

    // Grid, centred on the screen so both sides end on the same partial cell.
    final ink = dark ? const Color(0xFFFEE4BF) : const Color(0xFF1E1912);
    final minor = Paint()
      ..color = ink.withValues(alpha: dark ? 0.035 : 0.04)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = ink.withValues(alpha: dark ? 0.075 : 0.075)
      ..strokeWidth = 1;
    final ox = (size.width / 2) % _major;
    final oy = (size.height / 2) % _major;

    canvas.saveLayer(rect, Paint());
    for (double x = ox - _major; x <= size.width; x += _minor) {
      final isMajor = ((x - ox) / _minor).round() % 4 == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), isMajor ? major : minor);
    }
    for (double y = oy - _major; y <= size.height; y += _minor) {
      final isMajor = ((y - oy) / _minor).round() % 4 == 0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), isMajor ? major : minor);
    }

    // Registration crosses on a few major intersections, like a printed sheet.
    final cross = Paint()
      ..color = ink.withValues(alpha: dark ? 0.16 : 0.14)
      ..strokeWidth = 1.2;
    for (double x = ox; x <= size.width; x += _major * 2) {
      for (double y = oy; y <= size.height; y += _major * 3) {
        canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), cross);
        canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), cross);
      }
    }

    // Fade the lines out toward the edges so the sheet never looks busy
    // behind content.
    final c = focus.alongSize(size);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const RadialGradient(
          colors: [Colors.white, Colors.white, Color(0x26FFFFFF)],
          stops: [0, 0.45, 1],
        ).createShader(
            Rect.fromCircle(center: c, radius: size.longestSide * 0.75)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BlueprintPainter old) =>
      old.dark != dark || old.bg != bg || old.focus != focus;
}
