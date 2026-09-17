import 'package:flutter/material.dart';

import '../theme.dart';
import 'glass_card.dart';

/// A shimmering placeholder shaped like [CourseCard] (thumbnail block, a
/// title bar, a shorter subtitle bar), shown while the catalogue loads.
class SkeletonCard extends StatefulWidget {
  const SkeletonCard({super.key});

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
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _bar(radius: 10)),
          const SizedBox(height: 16),
          _bar(height: 16, widthFactor: 0.75),
          const SizedBox(height: 10),
          _bar(height: 12, widthFactor: 0.45),
          const Spacer(),
          const SizedBox(height: 18),
          _bar(height: 20, widthFactor: 0.3),
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
            alignment: Alignment.centerLeft,
            child: bar);
  }
}
