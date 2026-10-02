import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'arc_mark.dart';

/// Animated opening of the official ARC Platform lockup (brand sheet V5),
/// laid over the app on launch while Home loads underneath. One controller
/// drives every part on its own interval so the motion reads as one
/// sequence:
///   mark draws in like a snake -> divider grows from its centre ->
///   ARC PLATFORM rises letter by letter -> منصة آرك sweeps out from the
///   divider -> a glow pulse on the mark -> the overlay fades to Home.
/// Tap skips it; "reduce motion" skips it entirely.
class IntroOverlay extends StatefulWidget {
  const IntroOverlay({super.key});

  @override
  State<IntroOverlay> createState() => _IntroOverlayState();
}

class _IntroOverlayState extends State<IntroOverlay>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFF14120F);
  static const _orange = Color(0xFFE8622C);
  static const _cream = Color(0xFFFEE4BF);
  static const _word = 'ARC PLATFORM';

  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3400));
  bool _gone = false;

  Animation<double> _iv(double a, double b, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _c, curve: Interval(a, b, curve: curve));

  late final _mark = _iv(0.0, 0.50, Curves.easeInOutCubic);
  late final _divider = _iv(0.30, 0.48);
  late final _arabic = _iv(0.55, 0.75);
  late final _pulse = _iv(0.72, 0.86, Curves.easeInOut);
  late final _fade = _iv(0.86, 1.0, Curves.easeInCubic);

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _gone = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _gone = true;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _skip() {
    if (_c.value < 0.86) _c.animateTo(1, duration: const Duration(milliseconds: 260));
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final opacity = 1 - _fade.value;
          // Material gives the texts a real DefaultTextStyle: this overlay
          // sits above the navigator, outside any Scaffold, and would
          // otherwise get Flutter's yellow "missing text style" underline.
          return Opacity(
            opacity: opacity,
            child: Material(
              color: _bg,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Transform.scale(
                      scale: 1 + 0.04 * _fade.value,
                      child: _lockup(context),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _lockup(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final h = (w * 0.27).clamp(84.0, 132.0);
    final latin = h * 0.30;
    final arabic = h * 0.30;

    // Glow pulse rises and falls once after the text settles.
    final pulse = Curves.easeInOut.transform(
        _pulse.value < 0.5 ? _pulse.value * 2 : (1 - _pulse.value) * 2);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mark (rightmost in RTL), drawing itself in.
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _orange.withValues(alpha: 0.35 * pulse),
                  blurRadius: 40 * pulse + 1,
                  spreadRadius: 6 * pulse,
                ),
              ],
            ),
            child: SizedBox(
              width: h,
              height: h,
              child: CustomPaint(
                painter: ArcMarkPainter(
                  progress: _mark.value,
                  color: _orange,
                  showHead: true,
                ),
              ),
            ),
          ),
          SizedBox(width: h * 0.22),
          // Divider growing from its centre.
          SizedBox(
            height: h * 0.84,
            child: Align(
              alignment: Alignment.center,
              child: Container(
                width: 1.6,
                height: h * 0.84 * _divider.value,
                color: _orange,
              ),
            ),
          ),
          SizedBox(width: h * 0.22),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _letters(latin),
              SizedBox(height: h * 0.10),
              // Arabic sweeps out from the divider (right edge) leftwards.
              ClipRect(
                child: Align(
                  alignment: Alignment.centerRight,
                  widthFactor: _arabic.value,
                  child: Opacity(
                    opacity: _arabic.value,
                    child: Text('منصة آرك',
                        style: GoogleFonts.alexandria(
                            fontSize: arabic,
                            fontWeight: FontWeight.w300,
                            height: 1.15,
                            color: _cream)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// ARC PLATFORM, each letter rising and fading in on a staggered
  /// interval, read left to right.
  Widget _letters(double size) {
    const start = 0.40, span = 0.30, each = 0.10;
    final chars = _word.split('');
    final step = (span - each) / (chars.length - 1);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chars.length; i++)
            Builder(builder: (_) {
              final a = start + step * i;
              final t = Curves.easeOutCubic
                  .transform(((_c.value - a) / each).clamp(0.0, 1.0));
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * size * 0.6),
                  child: Text(chars[i],
                      style: GoogleFonts.montserrat(
                          fontSize: size,
                          fontWeight: FontWeight.w300,
                          letterSpacing: size * 0.06,
                          height: 1,
                          color: _cream)),
                ),
              );
            }),
        ],
      ),
    );
  }
}
