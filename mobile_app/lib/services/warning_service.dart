import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import 'error_reporter.dart';
import 'supabase_service.dart';

/// Formal warnings from the admin (user_warnings). An unanswered one opens a
/// window the student cannot dismiss until they type the reason, which
/// reaches the admins (submit_warning_reason).
class WarningService {
  WarningService._();

  static bool _showing = false;

  /// Shows the oldest unanswered warning, if any. Safe to call often.
  static Future<void> checkAndShow(BuildContext context) async {
    if (_showing) return;
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    Map<String, dynamic>? w;
    try {
      w = await SupabaseService.instance.client
          .from('user_warnings')
          .select('id, kind, warning_no, title, message, created_at')
          .eq('user_id', user.id)
          .isFilter('acknowledged_at', null)
          // A removed warning never opens the window, answered or not.
          .neq('status', 'removed')
          .order('created_at')
          .limit(1)
          .maybeSingle();
    } catch (_) {
      // Table not there yet, or offline: try again next time.
      return;
    }
    if (w == null || !context.mounted || _showing) return;
    _showing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _WarningDialog(warning: w!),
      );
    } finally {
      _showing = false;
    }
    // Answered: show the next unanswered one, if there is another.
    if (context.mounted) await checkAndShow(context);
  }
}

class _WarningDialog extends StatefulWidget {
  final Map<String, dynamic> warning;
  const _WarningDialog({required this.warning});

  @override
  State<_WarningDialog> createState() => _WarningDialogState();
}

class _WarningDialogState extends State<_WarningDialog> {
  final _reason = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = AppStrings.instance.t;
    final text = _reason.text.trim();
    if (text.length < 3) {
      setState(() => _error = t('warning_reason_required'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await SupabaseService.instance.client.rpc('submit_warning_reason',
          params: {'p_warning_id': widget.warning['id'], 'p_reason': text});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = ErrorReporter.userMessage(e, page: 'warning');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final w = widget.warning;
    final screen = w['kind'] == 'screen_capture';
    return PopScope(
      canPop: false,
      child: Directionality(
        textDirection:
            AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Row(children: [
            ArcIconView(ArcIcon.warning,
                color: AppColors.error, size: 26, active: true),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${w['title'] ?? t('warning_title')}',
                  style: AppFonts.body(
                      size: 18, weight: FontWeight.w800, color: AppColors.error)),
            ),
          ]),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${w['message'] ?? ''}',
                    style: AppFonts.body(size: 14.5, color: AppColors.text)),
                const SizedBox(height: 16),
                Text(
                    screen
                        ? t('warning_reason_screen')
                        : t('warning_reason_account'),
                    style: AppFonts.body(size: 13.5, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                TextField(
                  controller: _reason,
                  maxLines: 4,
                  maxLength: 500,
                  enabled: !_sending,
                  decoration:
                      InputDecoration(hintText: t('warning_reason_hint')),
                ),
                if (_error != null)
                  Text(_error!,
                      style: AppFonts.body(size: 12.5, color: AppColors.error)),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(t('warning_send_reason')),
            ),
          ],
        ),
      ),
    );
  }
}
