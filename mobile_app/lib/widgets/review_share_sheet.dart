import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../theme.dart';

/// Full-screen preview of one review as a picture card (for an Instagram post
/// or story). The teacher or admin picks the card's colours and whether the
/// student's name shows, then shares it as an image.
Future<void> showReviewShare(
  BuildContext context, {
  required Map<String, dynamic> review,
  String? courseTitle,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _ReviewShareScreen(review: review, courseTitle: courseTitle),
  ));
}

/// Fixed colours of one card theme, so the picture looks the same whatever
/// theme the app itself is in.
class _CardTheme {
  final String label;
  final Color base, ink, soft, mark, accent, onAccent, glow, glow2, line, star,
      starOff;
  final double glowAlpha, glow2Alpha, dotAlpha;
  const _CardTheme({
    required this.label,
    required this.base,
    required this.ink,
    required this.soft,
    required this.mark,
    required this.accent,
    required this.onAccent,
    required this.glow,
    required this.glow2,
    required this.line,
    required this.star,
    required this.starOff,
    required this.glowAlpha,
    required this.glow2Alpha,
    required this.dotAlpha,
  });
}

const _themes = <_CardTheme>[
  _CardTheme(
    label: 'review_theme_dark',
    base: Color(0xFF14120F),
    ink: Color(0xFFFFF6EA),
    soft: Color(0xFFB9B0A4),
    mark: Color(0xFFE8622C),
    accent: Color(0xFFE8622C),
    onAccent: Color(0xFFFFFFFF),
    glow: Color(0xFFE8622C),
    glow2: Color(0xFFF2B544),
    line: Color(0xFFFEE4BF),
    star: Color(0xFFF2B544),
    starOff: Color(0xFF4A423A),
    glowAlpha: 0.32,
    glow2Alpha: 0.2,
    dotAlpha: 0.13,
  ),
  _CardTheme(
    label: 'review_theme_cream',
    base: Color(0xFFFEE4BF),
    ink: Color(0xFF14120F),
    soft: Color(0xFF5B4D3A),
    mark: Color(0xFF14120F),
    accent: Color(0xFF14120F),
    onAccent: Color(0xFFFEE4BF),
    glow: Color(0xFFC94E1F),
    glow2: Color(0xFFFFFAF0),
    line: Color(0xFF14120F),
    star: Color(0xFF14120F),
    starOff: Color(0xFFC9B08A),
    glowAlpha: 0.26,
    glow2Alpha: 0.5,
    dotAlpha: 0.2,
  ),
  _CardTheme(
    label: 'review_theme_light',
    base: Color(0xFFFCFBF9),
    ink: Color(0xFF1E1912),
    soft: Color(0xFF6B5F4D),
    mark: Color(0xFFC94E1F),
    accent: Color(0xFFC94E1F),
    onAccent: Color(0xFFFFFFFF),
    glow: Color(0xFFC94E1F),
    glow2: Color(0xFFF2B544),
    line: Color(0xFF1E1912),
    star: Color(0xFFE0A030),
    starOff: Color(0xFFD8D0C3),
    glowAlpha: 0.26,
    glow2Alpha: 0.5,
    dotAlpha: 0.2,
  ),
];

class _ReviewShareScreen extends StatefulWidget {
  final Map<String, dynamic> review;
  final String? courseTitle;
  const _ReviewShareScreen({required this.review, this.courseTitle});

  @override
  State<_ReviewShareScreen> createState() => _ReviewShareScreenState();
}

class _ReviewShareScreenState extends State<_ReviewShareScreen> {
  final _boundary = GlobalKey();
  bool _showName = false;
  bool _busy = false;
  int _theme = 0;

  String _t(String k) => AppStrings.instance.t(k);

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final box =
          _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('png');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/arc-review.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      Rect? origin;
      if (mounted) {
        final b = context.findRenderObject() as RenderBox?;
        if (b != null && b.hasSize) origin = b.localToGlobal(Offset.zero) & b.size;
      }
      await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          sharePositionOrigin: origin));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(ErrorReporter.userMessage(e, page: 'rating'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review;
    final name = _showName ? (r['student_name'] as String?) : null;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(_t('review_share_title')),
          backgroundColor: AppColors.bg,
        ),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FittedBox(
                    child: RepaintBoundary(
                      key: _boundary,
                      child: _ReviewCard(
                        theme: _themes[_theme],
                        rating: (r['rating'] as num).toInt(),
                        comment: (r['comment'] as String?)?.trim() ?? '',
                        name: name,
                        courseTitle: widget.courseTitle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (var i = 0; i < _themes.length; i++)
                    _Swatch(
                      theme: _themes[i],
                      label: _t(_themes[i].label),
                      selected: i == _theme,
                      onTap: () => setState(() => _theme = i),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              title: Text(_t('review_share_name'),
                  style: AppFonts.body(size: 14, weight: FontWeight.w700)),
              value: _showName,
              onChanged: (v) => setState(() => _showName = v),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _share,
                  icon: const Icon(Icons.ios_share_rounded, size: 20),
                  label: Text(_t('review_share_btn')),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final _CardTheme theme;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.base,
              border: Border.all(
                  color: selected ? AppColors.red : AppColors.line,
                  width: selected ? 3 : 1.5),
            ),
            child: Center(
              child: Container(
                width: 14,
                height: 14,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: theme.accent),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: AppFonts.body(
                  size: 12,
                  weight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected ? AppColors.text : AppColors.muted)),
        ]),
      ),
    );
  }
}

/// The picture itself (4:5, the Instagram feed ratio): a soft glow and a
/// fading dot grid behind the comment, the ARC lockup on top.
class _ReviewCard extends StatelessWidget {
  final _CardTheme theme;
  final int rating;
  final String comment;
  final String? name;
  final String? courseTitle;
  const _ReviewCard({
    required this.theme,
    required this.rating,
    required this.comment,
    this.name,
    this.courseTitle,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final big = comment.length <= 120;
    return SizedBox(
      width: 360,
      height: 450,
      child: Stack(children: [
        Positioned.fill(child: ColoredBox(color: t.base)),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.7, -0.64),
                radius: 0.67,
                colors: [
                  t.glow2.withValues(alpha: t.glow2Alpha),
                  t.glow2.withValues(alpha: 0)
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-1, 1),
                radius: 0.78,
                colors: [
                  t.glow.withValues(alpha: t.glowAlpha),
                  t.glow.withValues(alpha: 0)
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
              painter: _DotsPainter(t.line.withValues(alpha: t.dotAlpha))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: _Lockup(theme: t),
                  ),
                ),
                const SizedBox(width: 8),
                _Stars(theme: t, rating: rating),
              ]),
              const SizedBox(height: 18),
              Text('“',
                  style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 64,
                      height: 0.8,
                      fontWeight: FontWeight.w900,
                      color: t.accent)),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: comment.isEmpty
                      ? Row(
                          textDirection: TextDirection.ltr,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$rating',
                                style: AppFonts.heading(
                                    size: 104, color: t.ink)),
                            Text('/5',
                                style: AppFonts.heading(
                                    size: 54, color: t.accent)),
                          ],
                        )
                      : Text(comment,
                          maxLines: 9,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.body(
                              size: big ? 22 : 16,
                              weight: FontWeight.w700,
                              color: t.ink)),
                ),
              ),
              const SizedBox(height: 10),
              if (name != null && name!.trim().isNotEmpty)
                Text(name!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                        size: 15, weight: FontWeight.w800, color: t.ink)),
              if (courseTitle != null && courseTitle!.trim().isNotEmpty)
                Text(courseTitle!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(size: 13, color: t.soft)),
              const SizedBox(height: 12),
              Container(height: 1, color: t.line.withValues(alpha: 0.2)),
              const SizedBox(height: 10),
              Row(children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('arcplatformiq.com',
                        textDirection: TextDirection.ltr,
                        style: AppFonts.body(
                            size: 12, weight: FontWeight.w600, color: t.soft)),
                  ),
                ),
                const SizedBox(width: 8),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: BorderRadius.circular(99)),
                  child: Text(AppStrings.instance.t('review_tag'),
                      style: AppFonts.body(
                          size: 11, weight: FontWeight.w800, color: t.onAccent)),
                ),
              ]),
            ],
          ),
        ),
      ]),
    );
  }
}

class _Stars extends StatelessWidget {
  final _CardTheme theme;
  final int rating;
  const _Stars({required this.theme, required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: TextDirection.ltr,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 20, color: i <= rating ? theme.star : theme.starOff),
      ],
    );
  }
}

/// The ARC mark, a divider and the two-line wordmark, as in the real logo.
class _Lockup extends StatelessWidget {
  final _CardTheme theme;
  const _Lockup({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      CustomPaint(size: const Size(32, 35), painter: _MarkPainter(theme.mark)),
      const SizedBox(width: 9),
      Container(width: 1.5, height: 32, color: theme.mark),
      const SizedBox(width: 9),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('ARC PLATFORM',
              textDirection: TextDirection.ltr,
              style: GoogleFonts.montserrat(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 3,
                  color: theme.ink)),
          Text('منصة آرك',
              style: TextStyle(
                  fontFamily: 'ArcArabic',
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  color: theme.ink)),
        ],
      ),
    ]);
  }
}

/// The A of the logo (same path as the sign-in screen's), in one colour.
class _MarkPainter extends CustomPainter {
  final Color color;
  _MarkPainter(this.color);

  static final Path _mark = Path()
    ..moveTo(347, 456)
    ..lineTo(399, 320)
    ..quadraticBezierTo(418, 270, 438, 320)
    ..lineTo(540, 575)
    ..cubicTo(552, 605, 530, 618, 505, 598)
    ..lineTo(420, 532)
    ..cubicTo(400, 514, 330, 496, 306, 566)
    ..lineTo(280, 645);

  @override
  void paint(Canvas canvas, Size size) {
    // View box 236,262 .. 576,634 of the logo's drawing space.
    canvas.scale(size.width / 340, size.height / 372);
    canvas.translate(-236, -262);
    canvas.clipRect(const Rect.fromLTWH(150, 190, 520, 438));
    canvas.drawPath(
        _mark,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 44
          ..strokeJoin = StrokeJoin.round
          ..color = color);
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.color != color;
}

/// A dot grid that fades in from the middle of the card down to the bottom.
class _DotsPainter extends CustomPainter {
  final Color color;
  _DotsPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (double y = 8; y < size.height; y += 16) {
      final k = ((y / size.height) - 0.3) / 0.7;
      if (k <= 0) continue;
      paint.color = color.withValues(alpha: color.a * k.clamp(0.0, 1.0));
      for (double x = 8; x < size.width; x += 16) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => old.color != color;
}
