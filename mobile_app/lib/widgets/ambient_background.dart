import 'package:flutter/material.dart';

import '../theme.dart';

/// The backdrop every page sits on: the base colour plus two soft,
/// out-of-focus colour washes.
///
/// Frosted glass only reads as glass when there is something varied behind
/// it to blur -- over a flat background a BackdropFilter is invisible. The
/// washes are plain gradients (free to paint), and the page content is
/// wrapped in a [BackdropGroup] so every [GlassCard] on the page shares one
/// blur pass instead of each paying for its own -- that's what keeps a long
/// list of glass cards scrolling smoothly on cheaper phones.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.instance.isDark;
    // StackFit.expand (plus the content as an ordinary, non-positioned last
    // child) is deliberate: a Stack whose children are ALL positioned sizes
    // itself from its incoming constraints alone, which is the same class of
    // silent zero-height collapse this app already hit once in
    // Scaffold.bottomNavigationBar. Being explicit costs nothing.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: ColoredBox(color: AppColors.bg)),
        Positioned(
          top: -140,
          right: -110,
          child: _Blob(
              color: AppColors.red.withValues(alpha: dark ? 0.16 : 0.12),
              size: 380),
        ),
        Positioned(
          top: 260,
          left: -150,
          child: _Blob(
              color: AppColors.teal.withValues(alpha: dark ? 0.12 : 0.10),
              size: 340),
        ),
        Positioned(
          bottom: -120,
          right: -60,
          child: _Blob(
              color: AppColors.byline.withValues(alpha: dark ? 0.08 : 0.06),
              size: 300),
        ),
        BackdropGroup(child: child),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
