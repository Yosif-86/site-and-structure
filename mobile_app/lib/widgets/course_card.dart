import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/learning_service.dart';
import '../theme.dart';
import 'glass_card.dart';

/// Course thumbnail with a consistent fallback, used by every card.
class CourseThumb extends StatelessWidget {
  final String? url;
  final double radius;
  final bool playOverlay;
  const CourseThumb(
      {super.key, required this.url, this.radius = 12, this.playOverlay = false});

  @override
  Widget build(BuildContext context) {
    Widget fallback() => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.panel2, AppColors.bg],
            ),
          ),
          child: Center(
            child: Icon(Icons.play_lesson_outlined,
                color: AppColors.muted2, size: 22),
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url != null)
            Image.network(
              url!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback(),
              loadingBuilder: (_, child, p) => p == null ? child : fallback(),
            )
          else
            fallback(),
          if (playOverlay)
            Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.35),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.85), width: 1.5),
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small icon + text badge for lesson count / duration.
class StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const StatChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.muted),
          const SizedBox(width: 4),
          Text(label,
              style: AppFonts.body(
                  size: 11.5, weight: FontWeight.w600, color: AppColors.muted)),
        ],
      ),
    );
  }
}

Widget _priceText(Course course, {double size = 13}) {
  final t = AppStrings.instance.t;
  return course.isFree
      ? Text(t('card_free'),
          style: AppFonts.body(
              size: size, weight: FontWeight.w700, color: AppColors.teal))
      : Text(course.price ?? '',
          style: AppFonts.code(
              size: size, weight: FontWeight.w700, color: AppColors.red));
}

List<Widget> _statChips(Course course, CourseStats? stats) {
  final t = AppStrings.instance.t;
  final chips = <Widget>[];
  if ((stats?.lectureCount ?? 0) > 0) {
    chips.add(StatChip(
        icon: Icons.play_lesson_outlined,
        label: '${stats!.lectureCount} ${t('lessons_label')}'));
  }
  final dur = LearningService.courseDurationLabel(course, stats);
  if (dur != null) {
    chips.add(StatChip(icon: Icons.schedule_rounded, label: dur));
  }
  return chips;
}

/// Large hero card for the featured course on Home: thumbnail with a bottom
/// gradient, title/teacher/stats on the image, price pill in the corner.
class FeaturedCourseCard extends StatelessWidget {
  final Course course;
  final CourseStats? stats;
  final VoidCallback onTap;
  const FeaturedCourseCard(
      {super.key, required this.course, this.stats, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final title = course.localizedTitle(ar);
    final teacher = course.localizedTeacherName(ar);
    final tag = course.localizedTagLabel(ar);
    final dur = LearningService.courseDurationLabel(course, stats);
    const onImage = Color(0xFFF3EDE4);

    return GlassCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CourseThumb(url: course.thumbnailUrl, radius: 0),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.25, 1],
                  colors: [Colors.transparent, Color(0xEE120F0C)],
                ),
              ),
            ),
            PositionedDirectional(
              top: 12,
              start: 12,
              child: tag != null && tag.isNotEmpty
                  ? GlassChip(label: tag, onImage: true)
                  : const SizedBox.shrink(),
            ),
            PositionedDirectional(
              top: 12,
              end: 12,
              child: GlassChip(
                  label: course.isFree ? t('card_free') : (course.price ?? ''),
                  color: course.isFree ? AppColors.teal : null,
                  onImage: !course.isFree),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: AppFonts.body(
                          size: 20, weight: FontWeight.w700, color: onImage),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (teacher != null && teacher.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(teacher,
                        style: AppFonts.body(
                            size: 13, color: onImage.withValues(alpha: 0.75))),
                  ],
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if ((stats?.lectureCount ?? 0) > 0)
                      GlassChip(
                          icon: Icons.play_lesson_outlined,
                          label: '${stats!.lectureCount} ${t('lessons_label')}',
                          onImage: true),
                    if (dur != null)
                      GlassChip(
                          icon: Icons.schedule_rounded,
                          label: dur,
                          onImage: true),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// List row: thumbnail with play overlay, title, teacher, lesson/duration
/// chips, price.
class CourseRow extends StatelessWidget {
  final Course course;
  final CourseStats? stats;
  final VoidCallback onTap;
  const CourseRow(
      {super.key, required this.course, this.stats, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final title = course.localizedTitle(ar);
    final teacher = course.localizedTeacherName(ar);
    final chips = _statChips(course, stats);

    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          SizedBox(
              width: 108,
              height: 82,
              child: CourseThumb(url: course.thumbnailUrl, playOverlay: true)),
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
                if (teacher != null && teacher.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(teacher,
                      style: AppFonts.body(size: 12.5, color: AppColors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [...chips, _priceText(course)],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right,
              color: AppColors.muted2),
        ],
      ),
    );
  }
}

/// Card for Home's horizontal "Continue learning" row: thumbnail on top with
/// a status chip, title/teacher, a progress bar with the percentage, and a
/// play button that resumes the course.
class ContinueLearningCard extends StatelessWidget {
  final MyCourseProgress item;
  final VoidCallback onTap;
  const ContinueLearningCard(
      {super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final pct = (item.progress * 100).round();
    final teacher = item.course.localizedTeacherName(ar);

    return SizedBox(
      width: 196,
      child: GlassCard(
        onTap: onTap,
        padding: const EdgeInsets.all(10),
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 104,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CourseThumb(url: item.course.thumbnailUrl),
                  PositionedDirectional(
                    bottom: 8,
                    start: 8,
                    child: GlassChip(label: t('status_in_progress'), onImage: true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
            Text(item.course.localizedTitle(ar),
                style: AppFonts.body(size: 14, weight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (teacher != null && teacher.isNotEmpty)
              Text(teacher,
                  style: AppFonts.body(size: 11.5, color: AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: item.progress,
                          minHeight: 5,
                          backgroundColor: AppColors.line,
                          valueColor: AlwaysStoppedAnimation(AppColors.red),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text('$pct% ${t('progress_complete')}',
                          style: AppFonts.body(
                              size: 11, color: AppColors.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.red,
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.red.withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 3)),
                    ],
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 22),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular percentage ring used by the progress summary card.
class ProgressRing extends StatelessWidget {
  final double value; // 0..1
  final double size;
  final double stroke;
  final Widget? center;
  const ProgressRing(
      {super.key,
      required this.value,
      this.size = 96,
      this.stroke = 9,
      this.center});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0),
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: AppColors.line,
              valueColor: AlwaysStoppedAnimation(AppColors.red),
            ),
          ),
          if (center != null) center!,
        ],
      ),
    );
  }
}
