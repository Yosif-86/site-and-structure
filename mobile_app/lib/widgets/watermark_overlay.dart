import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// Repositioning watermark shown over the video, port of moveWatermark()
/// in course.html — jumps to a random spot every 4s so it can't be cropped
/// out of a photo/recording of the screen.
class WatermarkOverlay extends StatefulWidget {
  final String label;
  const WatermarkOverlay({super.key, required this.label});

  @override
  State<WatermarkOverlay> createState() => _WatermarkOverlayState();
}

class _WatermarkOverlayState extends State<WatermarkOverlay> {
  final _rand = Random();
  double _top = 0.1;
  double _left = 0.1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reposition();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _reposition());
  }

  void _reposition() {
    setState(() {
      _top = 0.1 + _rand.nextDouble() * 0.7;
      _left = 0.1 + _rand.nextDouble() * 0.6;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          top: constraints.maxHeight * _top,
          left: constraints.maxWidth * _left,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                widget.label,
                style: const TextStyle(
                  color: Color(0xE6FFFFFF),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
