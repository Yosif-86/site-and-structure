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
        // One restrained wash in the brand colour, top corner only. The old
        // three-blob red/teal/pink spread made every panel look tinted.
        Positioned(
          top: -160,
          right: -120,
          child: _Blob(color: AppColors.red.withValues(alpha: 0.10), size: 360),
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
