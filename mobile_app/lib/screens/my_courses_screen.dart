import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/learning_service.dart';
import '../theme.dart';
import '../widgets/course_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import 'course_detail_screen.dart';

enum _Tab { inProgress, completed, pending }

/// The student's enrollments split into In progress / Completed / Pending,
/// each row showing real progress. Embedded as a swipeable tab inside
/// CatalogueScreen's PageView, so it has no Scaffold of its own.
class MyCoursesScreen extends StatefulWidget {
  /// Empty-state CTA: jump to the Home tab (the parent owns the PageView).
  final VoidCallback? onBrowse;
  const MyCoursesScreen({super.key, this.onBrowse});

  @override
  State<MyCoursesScreen> createState() => MyCoursesScreenState();
}

class MyCoursesScreenState extends State<MyCoursesScreen> {
  List<MyCourseProgress>? _items;
  String? _error;
  _Tab _tab = _Tab.inProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Called by CatalogueScreen on login/logout so this tab never shows
  /// another session's data.
  Future<void> reload() => _load();

  Future<void> _load() async {
    try {
      final items = await LearningService.fetchMyLearning();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'my_courses'));
    }
  }

  List<MyCourseProgress> _itemsFor(_Tab tab) {
    final all = _items ?? const <MyCourseProgress>[];
    switch (tab) {
      case _Tab.inProgress:
        return all.where((m) => m.isInProgress).toList()
          ..sort((a, b) => (b.lastWatched ?? b.enrolledAt)
              .compareTo(a.lastWatched ?? a.enrolledAt));
      case _Tab.completed:
        return all.where((m) => m.isCompleted).toList();
      case _Tab.pending:
        return all.where((m) => m.isPending).toList();
    }
  }

  Future<void> _open(String slug) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CourseDetailScreen(slug: slug)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final list = _itemsFor(_tab);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
        children: [
          Text(t('my_courses'),
              style: AppFonts.body(size: 26, weight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(t('my_courses_sub'),
              style: AppFonts.body(size: 13.5, color: AppColors.muted)),
          const SizedBox(height: 16),
          _Segmented(
            tabs: [
              (t('status_in_progress'), _itemsFor(_Tab.inProgress).length),
              (t('status_completed'), _itemsFor(_Tab.completed).length),
              (t('status_pending'), _itemsFor(_Tab.pending).length),
            ],
            selected: _tab.index,
            onSelect: (i) => setState(() => _tab = _Tab.values[i]),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            GlassCard(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: AppFonts.body(color: AppColors.muted)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _load, child: Text(t('retry'))),
              ]),
            )
          else if (_items == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (list.isEmpty)
            _EmptyState(tab: _tab, onBrowse: widget.onBrowse)
          else
            for (var i = 0; i < list.length; i++) ...[
              FadeSlideIn(
                delayMs: (i % 8) * 45,
                child: _EnrollmentRow(
                    item: list[i], onTap: () => _open(list[i].course.slug)),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

/// Glass segmented control with a count badge per segment.
class _Segmented extends StatelessWidget {
  final List<(String, int)> tabs;
  final int selected;
  final ValueChanged<int> onSelect;
  const _Segmented(
      {required this.tabs, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(4),
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: i == selected
                          ? AppColors.red.withValues(alpha: 0.16)
                          : Colors.transparent,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(tabs[i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.body(
                                  size: 13,
                                  weight: i == selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: i == selected
                                      ? AppColors.red
                                      : AppColors.muted)),
                        ),
                        if (tabs[i].$2 > 0) ...[
                          const SizedBox(width: 5),
                          Text('${tabs[i].$2}',
                              style: AppFonts.code(
                                  size: 11,
                                  color: i == selected
                                      ? AppColors.red
                                      : AppColors.muted2)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final _Tab tab;
  final VoidCallback? onBrowse;
  const _EmptyState({required this.tab, required this.onBrowse});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final (icon, text) = switch (tab) {
      _Tab.inProgress => (Icons.school_outlined, t('no_enrollments')),
      _Tab.completed => (Icons.emoji_events_outlined, t('empty_completed')),
      _Tab.pending => (Icons.hourglass_empty_rounded, t('empty_pending')),
    };
    return GlassCard(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.glassBg,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Icon(icon, color: AppColors.muted, size: 28),
          ),
          const SizedBox(height: 14),
          Text(text,
              style: AppFonts.body(size: 14.5, color: AppColors.muted),
              textAlign: TextAlign.center),
          if (tab == _Tab.inProgress && onBrowse != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: onBrowse, child: Text(t('browse_catalogue'))),
          ],
        ],
      ),
    );
  }
}

class _EnrollmentRow extends StatelessWidget {
  final MyCourseProgress item;
  final VoidCallback onTap;
  const _EnrollmentRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    final teacher = item.course.localizedTeacherName(ar);
    final pct = (item.progress * 100).round();

    final (chipLabel, chipColor) = item.isPending
        ? (t('status_pending'), AppColors.muted)
        : item.isCompleted
            ? (t('status_completed'), AppColors.teal)
            : (t('status_in_progress'), AppColors.red);

    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 96,
              height: 96,
              child: CourseThumb(url: item.course.thumbnailUrl)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GlassChip(label: chipLabel, color: chipColor),
                    const Spacer(),
                    if (item.isCompleted)
                      Icon(Icons.emoji_events_outlined,
                          color: AppColors.teal, size: 20),
                  ],
                ),
                const SizedBox(height: 6),
                Text(item.course.localizedTitle(ar),
                    style: AppFonts.body(size: 15, weight: FontWeight.w700),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (teacher != null && teacher.isNotEmpty)
                  Text(teacher,
                      style: AppFonts.body(size: 12, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                if (item.isPending) ...[
                  const SizedBox(height: 6),
                  Text(t('pending_note'),
                      style: AppFonts.body(size: 12, color: AppColors.muted)),
                ] else ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: item.progress,
                          minHeight: 5,
                          backgroundColor: AppColors.line,
                          valueColor: AlwaysStoppedAnimation(
                              item.isCompleted ? AppColors.teal : AppColors.red),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$pct%',
                        style: AppFonts.code(
                            size: 12,
                            color: item.isCompleted
                                ? AppColors.teal
                                : AppColors.red)),
                  ]),
                  const SizedBox(height: 6),
                  _MetaLine(
                    icon: Icons.play_lesson_outlined,
                    text:
                        '${item.completedLectures} / ${item.totalLectures} ${t('lessons_completed')}',
                  ),
                  if (item.lastWatched != null)
                    _MetaLine(
                      icon: item.isCompleted
                          ? Icons.event_available_outlined
                          : Icons.schedule_rounded,
                      text:
                          '${item.isCompleted ? t('completed_on') : t('last_watched')} ${LearningService.relativeTime(item.lastWatched!)}',
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Icon(icon, size: 13, color: AppColors.muted2),
        const SizedBox(width: 5),
        Expanded(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(size: 11.5, color: AppColors.muted)),
        ),
      ]),
    );
  }
}
