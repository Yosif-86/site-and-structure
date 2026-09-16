import 'package:flutter/material.dart';

import '../theme.dart';

/// Soft out-of-focus colour blobs painted behind the page content.
///
/// Frosted glass only reads as glass when there is something varied behind it
/// to blur — over a flat background a BackdropFilter is invisible. These two
/// low-opacity radial washes (brand red + teal) give the Profile and Settings
/// panels something to pick up, and cost nothing to paint since they are
/// plain gradients rather than real blurs.
class AmbientBackground extends StatelessWidget {
  final Widget child;

  const AmbientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
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
          top: -120,
          right: -90,
          child: _Blob(color: AppColors.red.withValues(alpha: 0.30), size: 300),
        ),
        Positioned(
          top: 220,
          left: -110,
          child: _Blob(color: AppColors.teal.withValues(alpha: 0.22), size: 280),
        ),
        Positioned(
          bottom: -100,
          right: -60,
          child: _Blob(color: AppColors.byline.withValues(alpha: 0.18), size: 260),
        ),
        child,
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
