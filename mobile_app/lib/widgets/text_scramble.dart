import 'dart:math';

import 'package:flutter/material.dart';

/// Shows [text] plainly on first build. If it later changes to a different
/// value (e.g. after saving an edit), the old value scrambles through random
/// glyphs and settles into the new one left-to-right, once, then goes back
/// to being a plain Text until the next change.
class TextScramble extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const TextScramble(this.text,
      {super.key, this.style, this.textAlign, this.maxLines, this.overflow});

  @override
  State<TextScramble> createState() => _TextScrambleState();
}

class _TextScrambleState extends State<TextScramble>
    with SingleTickerProviderStateMixin {
  static const _charset =
      'ابتثجحخدذرزسشصضطظعغفقكلمنهويABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final _random = Random();

  late AnimationController _controller;
  late String _settledText;
  String? _fromText;

  @override
  void initState() {
    super.initState();
    _settledText = widget.text;
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..addListener(() {
        if (mounted) setState(() {});
      });
  }

  @override
  void didUpdateWidget(TextScramble old) {
    super.didUpdateWidget(old);
    if (widget.text != _settledText) {
      _fromText = _settledText;
      _settledText = widget.text;
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _frameText() {
    if (!_controller.isAnimating || _fromText == null) return _settledText;
    final from = _fromText!;
    final to = _settledText;
    final maxLen = to.length > from.length ? to.length : from.length;
    final progress = _controller.value;
    final buffer = StringBuffer();
    for (var i = 0; i < maxLen; i++) {
      final settleAt = (i + 1) / maxLen;
      if (progress >= settleAt) {
        buffer.write(i < to.length ? to[i] : '');
      } else if (progress > 0) {
        buffer.write(_charset[_random.nextInt(_charset.length)]);
      } else {
        buffer.write(i < from.length ? from[i] : '');
      }
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _frameText(),
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
