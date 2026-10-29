import 'package:flutter/material.dart';

import '../theme.dart';

/// One step of a vertical timeline (the course editor): a dot on a line and a
/// block that is a glowing card while open, a plain tappable row otherwise.
/// A step with no [child] is locked.
class TimelineStep extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  final String? status;
  final bool done;
  final bool open;
  final bool locked;
  final bool last;
  final VoidCallback onTap;
  final Widget? child;
  const TimelineStep({
    super.key,
    required this.number,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.status,
    this.done = false,
    this.open = false,
    this.locked = false,
    this.last = false,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    const fast = Duration(milliseconds: 280);
    return Stack(
      children: [
        if (!last)
          PositionedDirectional(
            start: 15,
            top: 36,
            bottom: 0,
            width: 2,
            child: TimelineLine(filled: done),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              child: TimelineDot(
                  state: open ? 1 : (done ? 2 : 0), number: number),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Opacity(
                opacity: locked ? 0.55 : 1,
                child: Padding(
                  padding: EdgeInsets.only(bottom: last ? 0 : 20),
                  child: AnimatedContainer(
                    duration: fast,
                    curve: Curves.easeOutCubic,
                    padding: open
                        ? const EdgeInsets.all(14)
                        : const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      color: open
                          ? AppColors.panel.withValues(alpha: 0.72)
                          : Colors.transparent,
                      border: Border.all(
                          color: open
                              ? AppColors.red.withValues(alpha: 0.7)
                              : Colors.transparent,
                          width: 1.2),
                      boxShadow: open
                          ? [
                              BoxShadow(
                                  color: AppColors.red.withValues(alpha: 0.22),
                                  blurRadius: 26)
                            ]
                          : const [],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: locked ? null : onTap,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title,
                                        style: AppFonts.body(
                                            size: 16, weight: FontWeight.w800)),
                                    const SizedBox(height: 2),
                                    Text(subtitle,
                                        style: AppFonts.body(
                                            size: 12.5, color: AppColors.muted)),
                                  ],
                                ),
                              ),
                              if (status != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(status!,
                                      style: AppFonts.body(
                                          size: 12,
                                          weight: FontWeight.w700,
                                          color: done
                                              ? AppColors.teal
                                              : AppColors.muted)),
                                ),
                            ],
                          ),
                        ),
                        AnimatedSize(
                          duration: fast,
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: open && child != null
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: child)
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The dot of a course editor step: a pulsing orange ring while the step is
/// open, a teal check that pops in once it is done, an empty ring before.
class TimelineDot extends StatefulWidget {
  /// 0 = not reached, 1 = open, 2 = done.
  final int state;
  final int number;
  const TimelineDot({super.key, required this.state, required this.number});

  @override
  State<TimelineDot> createState() => TimelineDotState();
}

class TimelineDotState extends State<TimelineDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1700));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TimelineDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.state == 1) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget dot = switch (widget.state) {
      1 => AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final k = _pulse.value;
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 32 + 22 * k,
                  height: 32 + 22 * k,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.red.withValues(alpha: 0.28 * (1 - k)),
                  ),
                ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.red, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.red.withValues(alpha: 0.45),
                          blurRadius: 14)
                    ],
                  ),
                ),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: AppColors.red),
                ),
              ],
            );
          },
        ),
      2 => TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.5, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Container(
            width: 32,
            height: 32,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: AppColors.teal),
            child: Icon(Icons.check_rounded, size: 19, color: AppColors.bg),
          ),
        ),
      _ => Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.muted2, width: 1.6),
          ),
          child: Text('${widget.number}',
              style: AppFonts.body(
                  size: 12.5, weight: FontWeight.w700, color: AppColors.muted)),
        ),
    };
    return SizedBox(
      width: 32,
      height: 32,
      child: OverflowBox(
        maxWidth: 60,
        maxHeight: 60,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOut,
          child: KeyedSubtree(key: ValueKey(widget.state), child: dot),
        ),
      ),
    );
  }
}

/// The line between two step dots: it fills with orange, top to bottom, once
/// the step above is done.
class TimelineLine extends StatelessWidget {
  final bool filled;
  const TimelineLine({super.key, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: ColoredBox(color: AppColors.line)),
      Positioned.fill(
        child: AnimatedFractionallySizedBox(
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          heightFactor: filled ? 1 : 0,
          widthFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.red, const Color(0xFFF2B544)],
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
