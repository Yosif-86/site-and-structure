import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/rating_service.dart';
import '../theme.dart';
import 'arc_icons.dart';
import 'dashboard_kit.dart';
import 'glass_card.dart';
import 'rating_sheet.dart';
import 'review_share_sheet.dart';

/// Admin or the course's own teacher: every rating of one course with the
/// student's name and ID, and the private comments. Tapping a review opens a picture card to share. Nobody else
/// can open this; the database refuses anyone who is neither.
Future<void> showCourseReviews(BuildContext context,
    {required String courseId, String? title}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _CourseReviewsSheet(courseId: courseId, title: title),
  );
}

class _CourseReviewsSheet extends StatefulWidget {
  final String courseId;
  final String? title;
  const _CourseReviewsSheet({required this.courseId, this.title});

  @override
  State<_CourseReviewsSheet> createState() => _CourseReviewsSheetState();
}

class _CourseReviewsSheetState extends State<_CourseReviewsSheet> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await RatingService.instance.reviewsFor(widget.courseId);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = ErrorReporter.userMessage(e, page: 'rating'));
      }
    }
  }

  static String _date(Object? iso) {
    final d = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final rows = _rows;
    final count = rows?.length ?? 0;
    final avg = count == 0
        ? 0.0
        : rows!.fold<num>(0, (s, r) => s + (r['rating'] as num)) / count;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                  t('reviews_title').replaceAll('{title}', widget.title ?? '—'),
                  style: AppFonts.body(size: 17, weight: FontWeight.w800)),
            ),
            if (rows != null && count > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: Row(children: [
                  Text(avg.toStringAsFixed(1),
                      style: AppFonts.body(
                          size: 22,
                          weight: FontWeight.w800,
                          color: kStarColor)),
                  const SizedBox(width: 8),
                  StarRow(rating: avg.round(), size: 18),
                  const SizedBox(width: 8),
                  Text(t('rate_count').replaceAll('{n}', '$count'),
                      style: AppFonts.body(size: 13, color: AppColors.muted)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(t('reviews_private_note'),
                  style: AppFonts.body(size: 12, color: AppColors.muted2)),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Text(_error!,
                    style: AppFonts.body(size: 13, color: AppColors.error)),
              ),
            Flexible(
              child: rows == null
                  ? (_error == null
                      ? const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: CircularProgressIndicator()))
                      : const SizedBox(height: 24))
                  : rows.isEmpty
                      ? DashEmpty(
                          icon: ArcIcon.review, message: t('no_reviews'))
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) => _card(rows[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final comment = (r['comment'] as String?)?.trim() ?? '';
    final pid = (r['public_id'] as String?) ?? '';
    return GlassCard(
      onTap: () => showReviewShare(context,
          review: r, courseTitle: widget.title),
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                  pid.isEmpty
                      ? '${r['student_name'] ?? '—'}'
                      : '${r['student_name'] ?? '—'} · #$pid',
                  style: AppFonts.body(size: 14.5, weight: FontWeight.w800)),
            ),
            StarRow(rating: (r['rating'] as num).toInt(), size: 16),
          ]),
          const SizedBox(height: 2),
          Text(_date(r['updated_at']),
              style: AppFonts.body(size: 12, color: AppColors.muted2)),
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(comment, style: AppFonts.body(size: 14)),
          ],
        ],
      ),
    );
  }
}
