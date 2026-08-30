import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Port of the website's `.card` glassmorphism style — blurred translucent
/// background, soft border, and a lift/glow feedback on press.
class GlassCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (widget.onTap == null) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _pressed ? -3 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          boxShadow: [
            if (_pressed)
              BoxShadow(color: AppColors.red.withValues(alpha: 0.28), blurRadius: 36, spreadRadius: -6)
            else
              const BoxShadow(color: Color(0x401E1912), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                color: AppColors.glassBg,
                borderRadius: widget.borderRadius,
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
