import 'package:flutter/material.dart';

/// Swipe in from the screen's start edge (the right edge in Arabic) to go
/// back, like the arrow in the top bar. Pushed routes already get this from
/// iOS; this is for screens that switch views inside one route (the teacher
/// and admin dashboards), where the route's own gesture is switched off.
class EdgeSwipeBack extends StatefulWidget {
  final bool enabled;
  final VoidCallback onBack;
  final Widget child;

  const EdgeSwipeBack({
    super.key,
    required this.enabled,
    required this.onBack,
    required this.child,
  });

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> {
  static const _edgeWidth = 28.0;
  static const _distance = 64.0;
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Stack(
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _travel = 0,
            onHorizontalDragUpdate: (d) {
              // Inward = away from the edge: left in Arabic, right in English.
              _travel += rtl ? -d.delta.dx : d.delta.dx;
            },
            onHorizontalDragEnd: (_) {
              final done = _travel >= _distance;
              _travel = 0;
              if (done) widget.onBack();
            },
            onHorizontalDragCancel: () => _travel = 0,
          ),
        ),
      ],
    );
  }
}
