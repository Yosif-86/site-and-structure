import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// "Report this course" form (content_reports, add-reviewer-and-reports.sql).
/// The admins are notified and handle it in the admin screen.
Future<void> showReportSheet(BuildContext context, String courseId) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bg,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: _ReportSheet(courseId: courseId),
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  final String courseId;
  const _ReportSheet({required this.courseId});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  static const _reasons = ['inappropriate', 'copyright', 'misleading', 'other'];
  String? _reason;
  final _details = TextEditingController();
  bool _busy = false;
  String? _error;

  String _t(String k) => AppStrings.instance.t(k);

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    if (_reason == null) {
      setState(() => _error = _t('report_pick_reason'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = _details.text.trim();
      await SupabaseService.instance.client.from('content_reports').insert({
        'course_id': widget.courseId,
        'reason': _reason,
        if (text.isNotEmpty) 'details': text.length > 1000 ? text.substring(0, 1000) : text,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(_t('report_sent'))));
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Unique index: this person already has an open report on the course.
        _error = e.code == '23505'
            ? _t('report_already')
            : ErrorReporter.userMessage(e, page: 'report');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ErrorReporter.userMessage(e, page: 'report');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_t('report_title'), style: AppFonts.heading(size: 20)),
            const SizedBox(height: 6),
            Text(_t('report_sub'),
                style: AppFonts.body(size: 13, color: AppColors.muted)),
            const SizedBox(height: 10),
            RadioGroup<String>(
              groupValue: _reason,
              onChanged: (v) {
                if (!_busy) setState(() => _reason = v);
              },
              child: Column(children: [
                for (final r in _reasons)
                  RadioListTile<String>(
                    value: r,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_t('report_reason_$r'),
                        style: AppFonts.body(size: 14)),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _details,
              enabled: !_busy,
              maxLines: 3,
              maxLength: 1000,
              decoration: InputDecoration(labelText: _t('report_details')),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!,
                  style: AppFonts.body(size: 12.5, color: AppColors.error)),
            ],
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _busy ? null : _send,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_t('report_send')),
            ),
          ],
        ),
      ),
    );
  }
}
