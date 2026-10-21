import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'arc_icons.dart';
import 'dashboard_kit.dart';
import 'glass_card.dart';

/// Admin: every warning sent to one user, with their reply. A reply can be
/// accepted (the warning is removed and the user notified) or rejected (the
/// warning stays). Removed warnings stay listed here, marked as removed.
Future<void> showUserWarnings(BuildContext context,
    {required String userId, String? name}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.panel,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => _UserWarningsSheet(userId: userId, name: name),
  );
}

class _UserWarningsSheet extends StatefulWidget {
  final String userId;
  final String? name;
  const _UserWarningsSheet({required this.userId, this.name});

  @override
  State<_UserWarningsSheet> createState() => _UserWarningsSheetState();
}

class _UserWarningsSheetState extends State<_UserWarningsSheet> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('user_warnings')
          .select(
              'id, kind, warning_no, title, message, created_at, user_reason, acknowledged_at, status')
          .eq('user_id', widget.userId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _rows = (rows as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = ErrorReporter.userMessage(e, page: 'warning'));
      }
    }
  }

  Future<void> _review(Map<String, dynamic> w, bool accept) async {
    final id = w['id'] as String;
    if (_busy.contains(id)) return;
    final t = AppStrings.instance.t;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(id));
    try {
      await SupabaseService.instance.client.rpc('admin_review_warning',
          params: {'p_warning_id': id, 'p_accept': accept});
      messenger.showSnackBar(SnackBar(
          content: Text(
              accept ? t('warning_removed_ok') : t('warning_rejected_ok'))));
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = ErrorReporter.userMessage(e, page: 'warning'));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
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
    final counted = rows?.where((w) => w['status'] != 'removed').length ?? 0;
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
                  t('warnings_title').replaceAll('{name}', widget.name ?? '—'),
                  style: AppFonts.body(size: 17, weight: FontWeight.w800)),
            ),
            if (rows != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(t('warning_count').replaceAll('{n}', '$counted'),
                    style: AppFonts.body(size: 13, color: AppColors.muted)),
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
                          icon: ArcIcon.shield, message: t('no_warnings'))
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) => _card(rows[i], t),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> w, String Function(String) t) {
    final status = w['status'] as String? ?? 'active';
    final removed = status == 'removed';
    final reason = (w['user_reason'] as String?)?.trim();
    final replied = w['acknowledged_at'] != null;
    final busy = _busy.contains(w['id']);
    final (pillLabel, pillTone) = switch (status) {
      'removed' => (t('warning_status_removed'), StatusTone.good),
      'rejected' => (t('warning_status_rejected'), StatusTone.bad),
      _ => replied
          ? (t('warning_status_active'), StatusTone.warn)
          : (t('warning_awaiting_reply'), StatusTone.neutral),
    };
    return Opacity(
      opacity: removed ? 0.6 : 1,
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              DashIconBadge(
                  icon: ArcIcon.warning,
                  accent: removed ? AppColors.teal : AppColors.error,
                  size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${w['title'] ?? t('warning_title')}',
                        style: AppFonts.body(size: 14.5, weight: FontWeight.w800)
                            .copyWith(
                                decoration: removed
                                    ? TextDecoration.lineThrough
                                    : null)),
                    Text(
                        '${_date(w['created_at'])} · ${w['kind'] == 'screen_capture' ? t('warning_kind_screen') : t('warning_kind_account')}',
                        style:
                            AppFonts.body(size: 12, color: AppColors.muted2)),
                  ],
                ),
              ),
              StatusPill(pillLabel, tone: pillTone),
            ]),
            const SizedBox(height: 10),
            Text('${w['message'] ?? ''}',
                style: AppFonts.body(size: 13, color: AppColors.muted)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.glassBg,
                border: Border.all(color: AppColors.glassBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      replied
                          ? '${t('warning_reply_label')} · ${_date(w['acknowledged_at'])}'
                          : t('warning_awaiting_reply'),
                      style: AppFonts.body(
                          size: 12, weight: FontWeight.w700,
                          color: AppColors.muted2)),
                  if (reason != null && reason.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(reason, style: AppFonts.body(size: 14)),
                  ],
                ],
              ),
            ),
            if (replied && !removed) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                DashButton(t('warning_accept'),
                    primary: true,
                    icon: ArcIcon.check,
                    onPressed: busy ? null : () => _review(w, true)),
                if (status != 'rejected')
                  DashButton(t('warning_reject'),
                      danger: true,
                      icon: ArcIcon.close,
                      onPressed: busy ? null : () => _review(w, false)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
