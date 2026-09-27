import 'package:flutter/material.dart';

import '../theme.dart';
import 'glass_card.dart';

/// A shimmering placeholder shown while the catalogue loads. Needs a bounded
/// height from its parent (Home wraps it in a SizedBox).
///
/// Default: shaped like the featured card (thumbnail filling the space left
/// after a title and subtitle bar). [row]: shaped like a course list row
/// (square thumbnail beside two bars), for the short list slots -- the full
/// shape can't fit those and overflowed.
class SkeletonCard extends StatefulWidget {
  final bool row;
  const SkeletonCard({super.key, this.row = false});

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.row) {
      return GlassCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            AspectRatio(aspectRatio: 1, child: _bar(radius: 10)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(height: 14, widthFactor: 0.8),
                  const SizedBox(height: 10),
                  _bar(height: 10, widthFactor: 0.5),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _bar(radius: 10)),
          const SizedBox(height: 16),
          _bar(height: 16, widthFactor: 0.75),
          const SizedBox(height: 10),
          _bar(height: 12, widthFactor: 0.45),
        ],
      ),
    );
  }

  Widget _bar({double height = 100, double? widthFactor, double radius = 6}) {
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: widthFactor == null ? null : height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            return ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (rect) => LinearGradient(
                colors: [
                  AppColors.panel2,
                  AppColors.glassBorder,
                  AppColors.panel2
                ],
                stops: const [0.35, 0.5, 0.65],
                begin: Alignment(-1 - 2 * t, 0),
                end: Alignment(1 - 2 * t, 0),
              ).createShader(rect),
              child: Container(color: AppColors.panel2),
            );
          },
        ),
      ),
    );
    return widthFactor == null
        ? bar
        : FractionallySizedBox(
            widthFactor: widthFactor,
            alignment: AlignmentDirectional.centerStart,
            child: bar);
  }
}
