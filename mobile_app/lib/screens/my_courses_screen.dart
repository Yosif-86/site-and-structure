import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/enrollment.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import 'course_detail_screen.dart';

/// Port of my-courses.html. Embedded as a swipeable tab inside
/// CatalogueScreen's PageView (see FloatingBottomNav) rather than pushed as
/// its own route — nothing else in the app navigates to it directly.
class MyCoursesScreen extends StatefulWidget {
  /// Empty-state CTA: jump to the Home tab (the parent owns the PageView).
  final VoidCallback? onBrowse;
  const MyCoursesScreen({super.key, this.onBrowse});

  @override
  State<MyCoursesScreen> createState() => MyCoursesScreenState();
}

class MyCoursesScreenState extends State<MyCoursesScreen> {
  List<Enrollment>? _enrollments;
  Map<String, Map<String, dynamic>> _coursesBySlug = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Called by CatalogueScreen when this tab becomes visible again, so
  /// switching back to it after logging in (or enrolling in a course) shows
  /// fresh data instead of the stale logged-out/empty state from initState.
  Future<void> reload() => _load();

  Future<void> _load() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() {
        _enrollments = [];
        _error = null;
      });
      return;
    }
    try {
      final rows = await sb
          .from('enrollments')
          .select('id, course_slug, status, created_at')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);
      final enrollments = (rows as List)
          .map((r) => Enrollment.fromJson(r as Map<String, dynamic>))
          .toList();

      if (enrollments.isNotEmpty) {
        final slugs = enrollments.map((e) => e.courseSlug).toList();
        // title_ar isn't an actual column on courses (the migration for it
        // was never run against production) — fetching it explicitly 400s,
        // unlike select('*') elsewhere which just silently omits it.
        final courseRows = await sb
            .from('courses')
            .select('slug, title, thumbnail_url, teacher_name')
            .inFilter('slug', slugs);
        final map = <String, Map<String, dynamic>>{};
        for (final c in (courseRows as List)) {
          map[c['slug'] as String] = c as Map<String, dynamic>;
        }
        if (!mounted) return;
        setState(() {
          _enrollments = enrollments;
          _coursesBySlug = map;
          _error = null;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _enrollments = enrollments;
          _error = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'my_courses'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: AppFonts.body(color: AppColors.muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_enrollments == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_enrollments!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.line),
                ),
                child: Icon(Icons.school_outlined,
                    color: AppColors.muted, size: 28),
              ),
              const SizedBox(height: 16),
              Text(t('no_enrollments'),
                  style: AppFonts.body(size: 15, color: AppColors.muted),
                  textAlign: TextAlign.center),
              if (widget.onBrowse != null) ...[
                const SizedBox(height: 18),
                OutlinedButton(
                    onPressed: widget.onBrowse,
                    child: Text(t('browse_catalogue'))),
              ],
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        itemCount: _enrollments!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final e = _enrollments![i];
          final c = _coursesBySlug[e.courseSlug];
          return FadeSlideIn(
            delayMs: (i % 8) * 45,
            child: _EnrollmentRow(
              title: c?['title'] as String? ?? e.courseSlug,
              teacher: c?['teacher_name'] as String?,
              thumbnailUrl: c?['thumbnail_url'] as String?,
              isActive: e.isActive,
              enrolledOn: e.createdAt,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CourseDetailScreen(slug: e.courseSlug))),
            ),
          );
        },
      ),
    );
  }
}

class _EnrollmentRow extends StatelessWidget {
  final String title;
  final String? teacher;
  final String? thumbnailUrl;
  final bool isActive;
  final DateTime enrolledOn;
  final VoidCallback onTap;
  const _EnrollmentRow({
    required this.title,
    required this.teacher,
    required this.thumbnailUrl,
    required this.isActive,
    required this.enrolledOn,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    final statusColor = isActive ? AppColors.teal : AppColors.muted;
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 96,
              height: 68,
              child: thumbnailUrl != null
                  ? Image.network(
                      thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          ColoredBox(color: AppColors.panel2),
                      loadingBuilder: (_, child, p) => p == null
                          ? child
                          : ColoredBox(color: AppColors.panel2),
                    )
                  : ColoredBox(
                      color: AppColors.panel2,
                      child: Icon(Icons.play_circle_outline,
                          color: AppColors.muted2),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: AppFonts.body(size: 15, weight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (teacher != null && teacher!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(teacher!,
                      style: AppFonts.body(size: 12.5, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 6),
                Row(children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: statusColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(isActive ? t('status_active') : t('status_pending'),
                      style: AppFonts.body(
                          size: 12,
                          weight: FontWeight.w600,
                          color: statusColor)),
                  const SizedBox(width: 8),
                  Text(
                    enrolledOn.toLocal().toString().split(' ').first,
                    style: AppFonts.code(size: 11, color: AppColors.muted2),
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(ar ? Icons.chevron_left : Icons.chevron_right,
              color: AppColors.muted2),
        ],
      ),
    );
  }
}
