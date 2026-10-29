import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/rating_service.dart';
import '../theme.dart';

const Color kStarColor = Color(0xFFE0A030);

/// Five stars; [rating] of them filled. With [onChanged] they are tappable.
class StarRow extends StatelessWidget {
  final int rating;
  final double size;
  final ValueChanged<int>? onChanged;
  const StarRow(
      {super.key, required this.rating, this.size = 18, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: TextDirection.ltr,
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onChanged == null ? null : () => onChanged!(i),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: onChanged == null ? 1 : 4),
              child: Icon(
                i <= rating ? Icons.star_rounded : Icons.star_outline_rounded,
                size: size,
                color: i <= rating ? kStarColor : AppColors.muted2,
              ),
            ),
          ),
      ],
    );
  }
}

/// "Rate this course": 1 to 5 stars, plus a private comment box (it reaches
/// the admins and the course's teacher only). A student who
/// already rated can change the rating or remove it. Resolves to true when
/// the rating changed.
Future<bool?> showRatingSheet(
  BuildContext context, {
  required String courseId,
  required String courseTitle,
  Map<String, dynamic>? existing,
  bool prompt = false,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bg,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: _RatingSheet(
          courseId: courseId,
          courseTitle: courseTitle,
          existing: existing,
          prompt: prompt),
    ),
  );
}

class _RatingSheet extends StatefulWidget {
  final String courseId;
  final String courseTitle;
  final Map<String, dynamic>? existing;
  final bool prompt;
  const _RatingSheet({
    required this.courseId,
    required this.courseTitle,
    required this.existing,
    required this.prompt,
  });

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  late int _rating = (widget.existing?['rating'] as num?)?.toInt() ?? 0;
  late final _comment =
      TextEditingController(text: widget.existing?['comment'] as String? ?? '');
  bool _busy = false;
  String? _error;

  String _t(String k) => AppStrings.instance.t(k);

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_rating < 1) {
      setState(() => _error = _t('rate_pick'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = _comment.text.trim();
      await RatingService.instance.rate(widget.courseId, _rating,
          text.isNotEmpty ? text : null);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(_t('rate_thanks'))));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorReporter.userMessage(e, page: 'rating');
      });
    }
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RatingService.instance.remove(widget.courseId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(_t('rate_removed'))));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorReporter.userMessage(e, page: 'rating');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_t(editing ? 'rate_edit_title' : 'rate_title'),
                style: AppFonts.heading(size: 20)),
            const SizedBox(height: 4),
            Text(widget.courseTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 13, color: AppColors.muted)),
            const SizedBox(height: 18),
            Center(
              child: StarRow(
                rating: _rating,
                size: 40,
                onChanged: _busy ? null : (v) => setState(() => _rating = v),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 20,
              child: Center(
                child: Text(_rating == 0 ? '' : _t('rate_star_$_rating'),
                    style: AppFonts.body(
                        size: 13.5,
                        weight: FontWeight.w700,
                        color: kStarColor)),
              ),
            ),
            if (_rating >= 1) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _comment,
                enabled: !_busy,
                maxLines: 4,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: _t('rate_comment_hint'),
                  helperText: _t('rate_comment_note'),
                  helperMaxLines: 2,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!,
                  style: AppFonts.body(size: 12.5, color: AppColors.error)),
            ],
            const SizedBox(height: 14),
            ElevatedButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_t(editing ? 'rate_save' : 'rate_send')),
            ),
            if (editing)
              TextButton(
                onPressed: _busy ? null : _remove,
                child: Text(_t('rate_remove'),
                    style: AppFonts.body(
                        size: 14,
                        weight: FontWeight.w700,
                        color: AppColors.error)),
              )
            else if (widget.prompt)
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                child: Text(_t('rate_later'),
                    style: AppFonts.body(size: 14, color: AppColors.muted)),
              ),
          ],
        ),
      ),
    );
  }
}
