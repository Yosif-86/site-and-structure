import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/learning_service.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import 'admin_screen.dart';
import 'course_detail_screen.dart';
import 'teacher_screen.dart';

/// The bell's list: newest first, unread ones tinted with a dot, tapping one
/// marks it read and opens the screen it's about.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  static (ArcIcon, Color) _style(String type) => switch (type) {
        'payment_request' => (ArcIcon.money, const Color(0xFFE0A030)),
        'payment_approved' => (ArcIcon.check, AppColors.teal),
        'payment_rejected' => (ArcIcon.alert, AppColors.error),
        'course_review' => (ArcIcon.review, AppColors.red),
        'course_published' => (ArcIcon.courses, AppColors.teal),
        'course_returned' => (ArcIcon.edit, const Color(0xFFE0A030)),
        'edit_request' => (ArcIcon.edit, const Color(0xFFE0A030)),
        'edit_approved' => (ArcIcon.check, AppColors.teal),
        'edit_rejected' => (ArcIcon.close, AppColors.error),
        _ => (ArcIcon.bell, AppColors.muted),
      };

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
      case 'course_published':
      case 'course_returned':
      case 'edit_approved':
      case 'edit_rejected':
        return const TeacherScreen(openView: 'courses');
    }
    return null;
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
        builder: (context, _) => GlassScaffold(
          appBar: AppBar(
            title: Text(t('notifications')),
            actions: [
              if (svc.unread > 0)
                TextButton(
                    onPressed: svc.markAllRead,
                    child: Text(t('mark_all_read'))),
            ],
          ),
          body: svc.items.isEmpty
              ? ListView(children: [
                  DashEmpty(icon: ArcIcon.bell, message: t('no_notifications'))
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: svc.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final n = svc.items[i];
                    final (icon, color) = _style(n.type);
                    return FadeSlideIn(
                      delayMs: (i % 12) * 25,
                      child: GlassCard(
                        tint: n.read ? null : color.withValues(alpha: 0.10),
                        padding: const EdgeInsets.all(14),
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          svc.markRead(n.id);
                          final target = _target(n);
                          if (target != null) {
                            Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => target));
                          }
                        },
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DashIconBadge(icon: icon, accent: color, size: 42),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(n.title,
                                      style: AppFonts.body(
                                          size: 14.5,
                                          weight: n.read
                                              ? FontWeight.w600
                                              : FontWeight.w800)),
                                  if (n.body.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(n.body,
                                        style: AppFonts.body(
                                            size: 13, color: AppColors.muted)),
                                  ],
                                  const SizedBox(height: 5),
                                  Text(LearningService.relativeTime(n.createdAt),
                                      style: AppFonts.body(
                                          size: 11.5, color: AppColors.muted2)),
                                ],
                              ),
                            ),
                            if (!n.read)
                              Container(
                                width: 9,
                                height: 9,
                                margin: const EdgeInsets.only(top: 6),
                                decoration: BoxDecoration(
                                    shape: BoxShape.circle, color: color),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
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
    return AnimatedBuilder(
      animation: svc,
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
