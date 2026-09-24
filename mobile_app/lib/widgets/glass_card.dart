import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// The app's standard surface: frosted glass. A translucent tint, a hairline
/// light border, a soft sheen along the top edge, and a backdrop blur.
///
/// The blur uses [BackdropFilter.grouped], so when the card sits inside an
/// [AmbientBackground] (which provides a [BackdropGroup]) every card on the
/// page shares a single blur pass. Outside a group -- a sheet, a dialog --
/// it silently falls back to an ordinary per-card blur.
///
/// `glass: false` gives the old flat panel, for the rare surface that must
/// stay opaque.
class GlassCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool glass;
  final Color? tint;

  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadius.card)),
    this.glass = true,
    this.tint,
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
    final dark = AppTheme.instance.isDark;
    final surface = Container(
      decoration: BoxDecoration(
        color: widget.tint ??
            (widget.glass ? AppColors.glassBg : AppColors.panel),
        borderRadius: widget.borderRadius,
        border: Border.all(
            color: widget.glass ? AppColors.glassBorder : AppColors.line),
        gradient: widget.glass
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: dark ? 0.07 : 0.30),
                  Colors.white.withValues(alpha: 0),
                ],
                stops: const [0, 0.55],
              )
            : null,
      ),
      padding: widget.padding,
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
                color: Colors.black.withValues(alpha: dark ? 0.22 : 0.06),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: widget.borderRadius,
            child: widget.glass
                ? BackdropFilter.grouped(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: surface)
                : surface,
          ),
        ),
      ),
    );
  }
}

/// Glass pill used for small status/category labels over imagery or glass.
class GlassChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;
  final bool onImage;

  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.onImage = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? (onImage ? const Color(0xFFF3EDE4) : AppColors.text);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: onImage
                ? const Color(0xFF14120F).withValues(alpha: 0.45)
                : (color?.withValues(alpha: 0.14) ?? AppColors.glassBg),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: onImage
                    ? const Color(0xFFF3EDE4).withValues(alpha: 0.22)
                    : (color?.withValues(alpha: 0.35) ?? AppColors.glassBorder)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: AppFonts.body(
                      size: 11.5, weight: FontWeight.w600, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted container for modal bottom sheets. Pair with
/// `showModalBottomSheet(backgroundColor: Colors.transparent, ...)`.
class GlassSheet extends StatelessWidget {
  final Widget child;
  const GlassSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(top: Radius.circular(24));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.panel.withValues(alpha: 0.82),
            borderRadius: radius,
            border: Border(top: BorderSide(color: AppColors.glassBorder)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted2.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
