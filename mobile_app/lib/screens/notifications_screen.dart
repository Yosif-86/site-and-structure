import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/learning_service.dart';
import '../services/notification_service.dart';
import '../services/supabase_service.dart';
import '../services/warning_service.dart';
import '../widgets/course_reviews_sheet.dart';
import '../widgets/user_warnings_sheet.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import 'admin_screen.dart';
import 'course_detail_screen.dart';
import 'teacher_screen.dart';

/// Groups shown as filter chips at the top of the bell.
enum _Group { all, security, payments, courses, announcements, other }

/// The bell's list: grouped by type with filter chips, newest first, unread
/// ones tinted with a dot. Tapping one marks it read and opens what it is
/// about; a security alert (admin) opens the send-warning sheet.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  _Group _group = _Group.all;

  /// The security event kind. Newer alerts carry it in data; older ones
  /// are read from the title.
  static String? _securityKind(AppNotification n) {
    final k = n.data['kind'] as String?;
    if (k != null) return k;
    if (n.type != 'security') return null;
    if (n.title.contains('تسجيل الشاشة')) return 'screen_record';
    if (n.title.contains('لقطة شاشة')) return 'screenshot';
    if (n.title.contains('جهاز واحد')) return 'shared_device';
    if (n.title.contains('جهاز آخر')) return 'device_blocked';
    return null;
  }

  static _Group _groupOf(String type) => switch (type) {
        'security' ||
        'warning' ||
        'warning_reply' ||
        'warning_cleared' =>
          _Group.security,
        'payment_request' ||
        'payment_approved' ||
        'payment_rejected' =>
          _Group.payments,
        'course_review' ||
        'course_published' ||
        'course_returned' ||
        'edit_request' ||
        'edit_approved' ||
        'edit_rejected' ||
        'lecture_review' ||
        'lecture_published' ||
        'lecture_rejected' ||
        'course_file' ||
        'course_file_review' ||
        'content_report' ||
        'course_rating' =>
          _Group.courses,
        'announcement' => _Group.announcements,
        _ => _Group.other,
      };

  static String _groupLabel(_Group g) {
    final t = AppStrings.instance.t;
    return switch (g) {
      _Group.all => t('notif_group_all'),
      _Group.security => t('notif_group_security'),
      _Group.payments => t('notif_group_payments'),
      _Group.courses => t('notif_group_courses'),
      _Group.announcements => t('notif_group_announcements'),
      _Group.other => t('notif_group_other'),
    };
  }

  static const _amber = Color(0xFFE0A030);

  /// Icon (Arc glyph, or a Material one when the Arc set lacks it) + colour.
  static (ArcIcon, IconData?, Color) _style(AppNotification n) {
    if (n.type == 'security') {
      return switch (_securityKind(n)) {
        'screen_record' => (ArcIcon.video, Icons.videocam_rounded, AppColors.error),
        'screenshot' => (ArcIcon.image, Icons.photo_camera_rounded, AppColors.error),
        'shared_device' => (ArcIcon.phone, Icons.devices_other_rounded, _amber),
        'device_blocked' => (ArcIcon.phone, Icons.phonelink_lock_rounded, AppColors.error),
        _ => (ArcIcon.shield, null, AppColors.error),
      };
    }
    return switch (n.type) {
      'warning' => (ArcIcon.warning, null, AppColors.error),
      'warning_reply' => (ArcIcon.mail, null, _amber),
      'warning_cleared' => (ArcIcon.check, Icons.verified_user_rounded, AppColors.teal),
      'announcement' => (ArcIcon.bell, Icons.campaign_rounded, AppColors.red),
      'payment_request' => (ArcIcon.money, null, _amber),
      'payment_approved' => (ArcIcon.check, null, AppColors.teal),
      'payment_rejected' => (ArcIcon.alert, null, AppColors.error),
      'course_review' => (ArcIcon.review, null, AppColors.red),
      'course_published' => (ArcIcon.courses, null, AppColors.teal),
      'course_returned' => (ArcIcon.edit, null, _amber),
      'edit_request' => (ArcIcon.edit, null, _amber),
      'edit_approved' => (ArcIcon.check, null, AppColors.teal),
      'edit_rejected' => (ArcIcon.close, null, AppColors.error),
      'lecture_review' => (ArcIcon.video, null, _amber),
      'lecture_published' => (ArcIcon.video, null, AppColors.teal),
      'lecture_rejected' => (ArcIcon.video, null, AppColors.error),
      'course_file_review' => (ArcIcon.download, Icons.description_rounded, _amber),
      'course_file' => (ArcIcon.download, Icons.description_rounded, AppColors.teal),
      'content_report' => (ArcIcon.alert, Icons.flag_rounded, _amber),
      'course_rating' => (ArcIcon.review, Icons.star_rounded, _amber),
      _ => (ArcIcon.bell, null, AppColors.muted),
    };
  }

  static Widget? _target(AppNotification n) {
    final slug = n.data['course_slug'] as String?;
    switch (n.type) {
      case 'payment_request':
        return n.data['for'] == 'teacher'
            ? const TeacherScreen(openView: 'payments')
            : const AdminScreen(openView: 'payments');
      case 'payment_approved':
      case 'payment_rejected':
        return slug == null ? null : CourseDetailScreen(slug: slug);
      case 'course_review':
        return const AdminScreen(openView: 'review');
      case 'edit_request':
        return const AdminScreen(openView: 'editRequests');
      case 'lecture_review':
        return const AdminScreen(openView: 'uploads');
      case 'course_file_review':
        return const AdminScreen(openView: 'files');
      case 'content_report':
        return const AdminScreen(openView: 'reports');
      case 'course_file':
        return const TeacherScreen(openView: 'courses');
      case 'lecture_published':
      case 'lecture_rejected':
        return const TeacherScreen(openView: 'courses');
      case 'course_published':
      case 'course_returned':
      case 'edit_approved':
      case 'edit_rejected':
        return const TeacherScreen(openView: 'courses');
    }
    return null;
  }

  void _onTap(AppNotification n) {
    NotificationService.instance.markRead(n.id);
    // Admin alert about another user: offer a formal warning.
    if (n.type == 'security' && n.data['user_id'] != null) {
      final kind = _securityKind(n);
      if (kind != null) {
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: AppColors.panel,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
          builder: (_) => _SendWarningSheet(notification: n, eventKind: kind),
        );
        return;
      }
    }
    if (n.type == 'warning') {
      WarningService.checkAndShow(context);
      return;
    }
    // Admin: a student replied to a warning; review it.
    if (n.type == 'warning_reply' && n.data['user_id'] != null) {
      showUserWarnings(context,
          userId: '${n.data['user_id']}',
          name: (n.data['name'] as String?));
      return;
    }
    // A low course rating: open that course's private reviews.
    if (n.type == 'course_rating' && n.data['course_id'] != null) {
      showCourseReviews(context,
          courseId: '${n.data['course_id']}',
          title: n.data['course_title'] as String?);
      return;
    }
    final target = _target(n);
    if (target != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => target));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final svc = NotificationService.instance;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: AnimatedBuilder(
        animation: svc,
        builder: (context, _) {
          final all = svc.items;
          // Groups that have something, in a fixed order.
          final present = <_Group>{for (final n in all) _groupOf(n.type)};
          final groups = [
            _Group.all,
            for (final g in _Group.values.skip(1))
              if (present.contains(g)) g,
          ];
          final group = groups.contains(_group) ? _group : _Group.all;
          final items = group == _Group.all
              ? all
              : all.where((n) => _groupOf(n.type) == group).toList();
          int unreadIn(_Group g) => all
              .where((n) =>
                  !n.read && (g == _Group.all || _groupOf(n.type) == g))
              .length;

          return GlassScaffold(
            appBar: AppBar(
              title: Text(t('notifications')),
              actions: [
                if (svc.unread > 0)
                  TextButton(
                      onPressed: svc.markAllRead,
                      child: Text(t('mark_all_read'))),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: svc.refresh,
              child: all.isEmpty
                  ? ListView(children: [
                      DashEmpty(
                          icon: ArcIcon.bell, message: t('no_notifications'))
                    ])
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        if (groups.length > 2)
                          SizedBox(
                            height: 40,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: groups.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (context, i) => _GroupChip(
                                label: _groupLabel(groups[i]),
                                unread: unreadIn(groups[i]),
                                selected: groups[i] == group,
                                onTap: () =>
                                    setState(() => _group = groups[i]),
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        for (var i = 0; i < items.length; i++) ...[
                          FadeSlideIn(
                            delayMs: (i % 12) * 25,
                            child: _NotificationCard(
                              n: items[i],
                              style: _style(items[i]),
                              onTap: () => _onTap(items[i]),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  final String label;
  final int unread;
  final bool selected;
  final VoidCallback onTap;
  const _GroupChip(
      {required this.label,
      required this.unread,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
        child: Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected
                ? AppColors.red.withValues(alpha: 0.16)
                : AppColors.glassBg,
            border: Border.all(
                color: selected
                    ? AppColors.red.withValues(alpha: 0.45)
                    : AppColors.glassBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: AppFonts.body(
                    size: 13,
                    weight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.red : AppColors.text)),
            if (unread > 0) ...[
              const SizedBox(width: 6),
              Container(
                height: 18,
                constraints: const BoxConstraints(minWidth: 18),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                    color: AppColors.error,
                    borderRadius: BorderRadius.circular(9)),
                alignment: Alignment.center,
                child: Text(unread > 99 ? '99+' : '$unread',
                    textScaler: TextScaler.noScaling,
                    textHeightBehavior: const TextHeightBehavior(
                        applyHeightToFirstAscent: false,
                        applyHeightToLastDescent: false),
                    style: AppFonts.body(
                            size: 10.5,
                            weight: FontWeight.w800,
                            color: Colors.white)
                        .copyWith(height: 1)),
              ),
            ],
          ]),
        ),
      ),
    ));
  }
}

class _NotificationCard extends StatelessWidget {
  final AppNotification n;
  final (ArcIcon, IconData?, Color) style;
  final VoidCallback onTap;
  const _NotificationCard(
      {required this.n, required this.style, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (icon, material, color) = style;
    return GlassCard(
      tint: n.read ? null : color.withValues(alpha: 0.10),
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashIconBadge(
              icon: icon, materialIcon: material, accent: color, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.title,
                    style: AppFonts.body(
                        size: 14.5,
                        weight: n.read ? FontWeight.w600 : FontWeight.w800)),
                if (n.body.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(n.body,
                      style: AppFonts.body(size: 13, color: AppColors.muted)),
                ],
                const SizedBox(height: 5),
                Text(LearningService.relativeTime(n.createdAt),
                    style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
              ],
            ),
          ),
          if (!n.read)
            Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
        ],
      ),
    );
  }
}

/// Admin: send a formal warning to the user behind a security alert.
class _SendWarningSheet extends StatefulWidget {
  final AppNotification notification;
  final String eventKind;
  const _SendWarningSheet(
      {required this.notification, required this.eventKind});

  @override
  State<_SendWarningSheet> createState() => _SendWarningSheetState();
}

class _SendWarningSheetState extends State<_SendWarningSheet> {
  int? _count;
  bool _alreadySent = false;
  bool _sending = false;
  String? _error;

  String get _userId => '${widget.notification.data['user_id']}';
  String? get _eventId => widget.notification.data['event_id'] as String?;
  String get _warnKind =>
      widget.eventKind == 'screen_record' || widget.eventKind == 'screenshot'
          ? 'screen_capture'
          : 'account_sharing';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('user_warnings')
          .select('id, event_id, status')
          .eq('user_id', _userId) as List;
      if (!mounted) return;
      setState(() {
        _count = rows.where((r) => r['status'] != 'removed').length;
        _alreadySent =
            _eventId != null && rows.any((r) => r['event_id'] == _eventId);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = ErrorReporter.userMessage(e, page: 'warning'));
      }
    }
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final no = await SupabaseService.instance.client.rpc(
          'admin_issue_warning',
          params: {
            'p_user': _userId,
            'p_kind': _warnKind,
            'p_event_id': _eventId,
          });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(
          content: Text(AppStrings.instance
              .t('warning_sent')
              .replaceAll('{n}', '$no'))));
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
    final n = widget.notification;
    final next = (_count ?? 0) + 1;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(n.title,
                style: AppFonts.body(size: 17, weight: FontWeight.w800)),
            if (n.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(n.body,
                  style: AppFonts.body(size: 13.5, color: AppColors.muted)),
            ],
            const SizedBox(height: 4),
            Text(
                '${n.createdAt.toLocal().toString().substring(0, 16)} · '
                '${_warnKind == 'screen_capture' ? t('warning_kind_screen') : t('warning_kind_account')}',
                style: AppFonts.body(size: 12.5, color: AppColors.muted2)),
            const SizedBox(height: 16),
            if (_count == null && _error == null)
              const Center(child: CircularProgressIndicator())
            else if (_count != null) ...[
              Text(
                  t('warning_count')
                      .replaceAll('{n}', '$_count'),
                  style: AppFonts.body(size: 14, weight: FontWeight.w700)),
              if (next >= 3 && !_alreadySent) ...[
                const SizedBox(height: 6),
                Text(t('warning_last_note'),
                    style: AppFonts.body(size: 13, color: AppColors.error)),
              ],
              const SizedBox(height: 14),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    minimumSize: const Size.fromHeight(48)),
                onPressed: _sending || _alreadySent ? null : _send,
                icon: const Icon(Icons.gpp_maybe_rounded),
                label: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_alreadySent
                        ? t('warning_already_sent')
                        : t('warning_send').replaceAll('{n}', '$next')),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: AppFonts.body(size: 13, color: AppColors.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bell with a live unread badge, for the app's top bar.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = NotificationService.instance;
    // Also the theme: the bell is a const widget, so without this it kept
    // the old mode's colours after switching light / dark.
    return AnimatedBuilder(
      animation: Listenable.merge([svc, AppTheme.instance]),
      builder: (context, _) {
        final count = svc.unread;
        return Semantics(
          button: true,
          label: AppStrings.instance.t('notifications'),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NotificationsScreen())),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.glassBg,
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: Center(
                    child: ArcIconView(ArcIcon.bell,
                        size: 22,
                        color: count > 0 ? AppColors.red : AppColors.text,
                        active: count > 0),
                  ),
                ),
                if (count > 0)
                  PositionedDirectional(
                    top: -3,
                    end: -3,
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 20, minHeight: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.bg, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Text(count > 99 ? '99+' : '$count',
                          style: AppFonts.body(
                              size: 10.5,
                              weight: FontWeight.w800,
                              color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
