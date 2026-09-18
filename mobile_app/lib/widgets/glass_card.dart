import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's standard surface: a flat panel with a hairline border and a
/// soft, low shadow. Kept the `GlassCard` name so every call site stays
/// put, but blur is now opt-in (`glass: true`) and reserved for the few
/// places that sit on top of imagery, where frosted glass actually earns
/// its cost. Everywhere else a flat surface reads cleaner and paints
/// cheaper than a BackdropFilter.
class GlassCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool glass;

  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadius.card)),
    this.glass = false,
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
    final surface = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.glass ? AppColors.glassBg : AppColors.panel,
        borderRadius: widget.borderRadius,
        border: Border.all(
            color: widget.glass ? AppColors.glassBorder : AppColors.line),
      ),
      child: widget.child,
    );

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.985 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: AppTheme.instance.isDark ? 0.22 : 0.06),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: widget.glass
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: surface)
                : surface,
          ),
        ),
      ),
    );
  }
}
