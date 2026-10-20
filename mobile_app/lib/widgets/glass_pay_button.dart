import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'arc_mark.dart';

/// Pay button in light matte glass: frosted backdrop, soft top highlight,
/// a slow band of light sweeping across, and a small press-in. [accent]
/// tints the glass orange (main buy action); otherwise it is neutral glass.
/// [showMark] lays a faint Arc mark on the left edge (website button).
/// Respects the system "reduce motion" setting (no sweep).
class GlassPayButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool accent;
  final bool showMark;
  final double height;

  const GlassPayButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.accent = true,
    this.showMark = false,
    this.height = 52,
  });

  @override
  State<GlassPayButton> createState() => _GlassPayButtonState();
}

class _GlassPayButtonState extends State<GlassPayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3400));
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _sweep.stop();
      _sweep.value = 0;
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _setPressed(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final accent = AppColors.accent;
    final fg = widget.accent ? Colors.white : AppColors.text;
    final fill = widget.accent
        ? [accent.withValues(alpha: 0.92), accent.withValues(alpha: 0.72)]
        : [
            AppColors.text.withValues(alpha: 0.10),
            AppColors.text.withValues(alpha: 0.04),
          ];
    final border = widget.accent
        ? Colors.white.withValues(alpha: 0.28)
        : AppColors.text.withValues(alpha: 0.16);

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: () => _setPressed(false),
        onTap: _enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: widget.onPressed == null && !widget.loading ? 0.5 : 1,
            duration: const Duration(milliseconds: 160),
            child: DecoratedBox(
              // Soft coloured glow under the accent glass.
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: widget.accent
                    ? [
                        BoxShadow(
                            color: accent.withValues(alpha: 0.30),
                            blurRadius: 22,
                            offset: const Offset(0, 8)),
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    height: widget.height,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(color: border, width: 1),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: fill,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Matte top highlight.
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.center,
                              colors: [
                                Colors.white.withValues(
                                    alpha: widget.accent ? 0.22 : 0.10),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                        if (widget.showMark)
                          Positioned(
                            left: 10,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: Opacity(
                                opacity: 0.22,
                                child: ArcMark(
                                    size: widget.height * 0.62,
                                    color: widget.accent
                                        ? Colors.white
                                        : AppColors.accent),
                              ),
                            ),
                          ),
                        // Band of light sweeping across, then a pause.
                        IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _sweep,
                            builder: (context, _) {
                              final t = (_sweep.value / 0.55).clamp(0.0, 1.0);
                              if (t <= 0 || t >= 1) {
                                return const SizedBox.shrink();
                              }
                              final x = -1.6 + 3.2 * Curves.easeInOut.transform(t);
                              return DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment(x - 0.5, -1),
                                    end: Alignment(x + 0.5, 1),
                                    colors: [
                                      Colors.white.withValues(alpha: 0),
                                      Colors.white.withValues(
                                          alpha: widget.accent ? 0.26 : 0.14),
                                      Colors.white.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Center(
                          child: widget.loading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: fg),
                                )
                              : Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 18),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (widget.icon != null) ...[
                                        Icon(widget.icon, size: 20, color: fg),
                                        const SizedBox(width: 8),
                                      ],
                                      Flexible(
                                        child: Text(
                                          widget.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppFonts.body(
                                              size: 15,
                                              weight: FontWeight.w700,
                                              color: fg),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
