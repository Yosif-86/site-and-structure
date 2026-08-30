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
    // Positioned.fill matches this widget's own parent Stack (the video
    // player's Stack). LayoutBuilder sits inside that — fine, since it's not
    // itself a ParentDataWidget. The AnimatedPositioned then needs its own
    // fresh Stack as an immediate ancestor (LayoutBuilder doesn't count,
    // it has its own RenderObject), so it's nested one level deeper here.
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeInOut,
                top: constraints.maxHeight * _top,
                left: constraints.maxWidth * _left,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: Color(0x59FFFFFF), // ~35% white — legible but unobtrusive
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        shadows: [Shadow(blurRadius: 4, color: Color(0x99000000))],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
