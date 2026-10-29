import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../theme.dart';
import 'rating_sheet.dart';

/// Full-screen preview of one review as a picture card (for an Instagram post
/// or story) with a share button. The student's name is hidden unless the
/// viewer turns it on.
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

/// The picture itself: fixed size and colours so it looks the same in light
/// and dark mode (4:5, the Instagram feed ratio).
class _ReviewCard extends StatelessWidget {
  final int rating;
  final String comment;
  final String? name;
  final String? courseTitle;
  const _ReviewCard({
    required this.rating,
    required this.comment,
    this.name,
    this.courseTitle,
  });

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFF4EFE8);
    const soft = Color(0xFFB9B0A4);
    final big = comment.length <= 120;
    return Container(
      width: 360,
      height: 450,
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1713), Color(0xFF0E0C0A)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('ARC',
                style: AppFonts.heading(size: 22, color: kStarColor)),
            const Spacer(),
            StarRow(rating: rating, size: 22),
          ]),
          const SizedBox(height: 22),
          Icon(Icons.format_quote_rounded,
              size: 40, color: kStarColor.withValues(alpha: 0.9)),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: comment.isEmpty
                  ? Text('$rating / 5',
                      style: AppFonts.heading(size: 64, color: ink))
                  : Text(comment,
                      maxLines: 9,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                          size: big ? 22 : 16,
                          weight: FontWeight.w600,
                          color: ink)),
            ),
          ),
          const SizedBox(height: 12),
          if (name != null && name!.trim().isNotEmpty)
            Text(name!.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                    size: 15, weight: FontWeight.w800, color: ink)),
          if (courseTitle != null && courseTitle!.trim().isNotEmpty)
            Text(courseTitle!.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 13, color: soft)),
          const SizedBox(height: 14),
          Container(height: 1, color: const Color(0x33FFFFFF)),
          const SizedBox(height: 10),
          Text('arcplatformiq.com',
              style: AppFonts.body(size: 12, color: soft)),
        ],
      ),
    );
  }
}
