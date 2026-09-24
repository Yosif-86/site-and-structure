import '../i18n/strings.dart';
import '../models/course.dart';
import 'supabase_service.dart';

/// Lecture count and known total runtime for one course.
class CourseStats {
  final int lectureCount;
  final int totalSeconds;
  const CourseStats({required this.lectureCount, required this.totalSeconds});

  static const empty = CourseStats(lectureCount: 0, totalSeconds: 0);
}

/// One of the signed-in student's enrollments plus how far through it they
/// are. Progress counts part-watched lectures fractionally (position /
/// duration), so a course you've started shows real movement instead of
/// sitting at 0% until a whole lecture is finished.
class MyCourseProgress {
  final Course course;
  final String status; // 'active' | 'pending'
  final DateTime enrolledAt;
  final int totalLectures;
  final int completedLectures;
  final double progress; // 0..1
  final DateTime? lastWatched;

  const MyCourseProgress({
    required this.course,
    required this.status,
    required this.enrolledAt,
    required this.totalLectures,
    required this.completedLectures,
    required this.progress,
    required this.lastWatched,
  });

  bool get isActive => status == 'active';
  bool get isPending => status == 'pending';
  bool get isCompleted =>
      isActive && totalLectures > 0 && completedLectures >= totalLectures;
  bool get isInProgress => isActive && !isCompleted;
  bool get hasStarted => lastWatched != null;
}

class LearningService {
  LearningService._();

  /// Lecture counts and summed durations per course id. Lectures are
  /// readable anonymously for published courses, so this works logged out.
  static Future<Map<String, CourseStats>> fetchCourseStats(
      List<String> courseIds) async {
    if (courseIds.isEmpty) return {};
    final rows = await SupabaseService.instance.client
        .from('lectures')
        .select('course_id, duration_seconds')
        .inFilter('course_id', courseIds);
    final counts = <String, int>{};
    final seconds = <String, int>{};
    for (final r in (rows as List)) {
      final id = r['course_id'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
      seconds[id] = (seconds[id] ?? 0) + ((r['duration_seconds'] as int?) ?? 0);
    }
    return {
      for (final id in counts.keys)
        id: CourseStats(lectureCount: counts[id]!, totalSeconds: seconds[id]!),
    };
  }

  /// The signed-in user's enrollments with progress, newest enrollment
  /// first. Empty when logged out.
  static Future<List<MyCourseProgress>> fetchMyLearning() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) return [];

    final enrollRows = await sb
        .from('enrollments')
        .select('course_slug, status, created_at')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    final enrollments = (enrollRows as List).cast<Map<String, dynamic>>();
    if (enrollments.isEmpty) return [];

    final slugs = enrollments.map((e) => e['course_slug'] as String).toList();
    final courseRows = await sb.from('courses').select('*').inFilter('slug', slugs);
    final coursesBySlug = <String, Course>{
      for (final c in (courseRows as List))
        c['slug'] as String: Course.fromJson(c as Map<String, dynamic>),
    };
    if (coursesBySlug.isEmpty) return [];

    final courseIds = coursesBySlug.values.map((c) => c.id).toList();
    final lectureRows = await sb
        .from('lectures')
        .select('id, course_id')
        .inFilter('course_id', courseIds);
    final lectureCourse = <String, String>{
      for (final l in (lectureRows as List))
        l['id'] as String: l['course_id'] as String,
    };
    final totalByCourse = <String, int>{};
    for (final cid in lectureCourse.values) {
      totalByCourse[cid] = (totalByCourse[cid] ?? 0) + 1;
    }

    final completedByCourse = <String, int>{};
    final partialByCourse = <String, double>{};
    final lastByCourse = <String, DateTime>{};
    if (lectureCourse.isNotEmpty) {
      final progressRows = await sb
          .from('lesson_progress')
          .select(
              'lecture_id, position_seconds, duration_seconds, completed, updated_at')
          .eq('user_id', user.id)
          .inFilter('lecture_id', lectureCourse.keys.toList());
      for (final p in (progressRows as List)) {
        final cid = lectureCourse[p['lecture_id'] as String];
        if (cid == null) continue;
        if (p['completed'] == true) {
          completedByCourse[cid] = (completedByCourse[cid] ?? 0) + 1;
        } else {
          final pos = (p['position_seconds'] as int?) ?? 0;
          final dur = (p['duration_seconds'] as int?) ?? 0;
          if (pos > 0 && dur > 0) {
            partialByCourse[cid] =
                (partialByCourse[cid] ?? 0) + (pos / dur).clamp(0.0, 1.0);
          }
        }
        final updated = DateTime.tryParse(p['updated_at'] as String? ?? '');
        if (updated != null &&
            (lastByCourse[cid] == null || updated.isAfter(lastByCourse[cid]!))) {
          lastByCourse[cid] = updated;
        }
      }
    }

    final result = <MyCourseProgress>[];
    for (final e in enrollments) {
      final course = coursesBySlug[e['course_slug'] as String];
      if (course == null) continue;
      final total = totalByCourse[course.id] ?? 0;
      final done = completedByCourse[course.id] ?? 0;
      final partial = partialByCourse[course.id] ?? 0;
      result.add(MyCourseProgress(
        course: course,
        status: e['status'] as String? ?? 'pending',
        enrolledAt: DateTime.tryParse(e['created_at'] as String? ?? '') ??
            DateTime.now(),
        totalLectures: total,
        completedLectures: done,
        progress: total == 0 ? 0 : ((done + partial) / total).clamp(0.0, 1.0),
        lastWatched: lastByCourse[course.id],
      ));
    }
    return result;
  }

  /// "3س 20د" / "45د" style runtime. Null when there's nothing to show.
  static String? formatDuration(int seconds) {
    if (seconds <= 0) return null;
    final t = AppStrings.instance.t;
    final h = seconds ~/ 3600;
    final m = ((seconds % 3600) / 60).round();
    if (h == 0) return '${m < 1 ? 1 : m} ${t('dur_min')}';
    if (m == 0) return '$h ${t('dur_hr')}';
    return '$h ${t('dur_hr')} $m ${t('dur_min')}';
  }

  /// Best available runtime label for a course: the real sum of lecture
  /// durations when any are known, else the hand-typed estimate teachers
  /// put in the course's meta ("Duration": "~3.5 hrs").
  static String? courseDurationLabel(Course course, CourseStats? stats) {
    final real = formatDuration(stats?.totalSeconds ?? 0);
    if (real != null) return real;
    final meta = course.localizedMeta(AppStrings.instance.isAr) ?? course.meta;
    if (meta == null) return null;
    for (final key in const ['Duration', 'duration', 'المدة']) {
      final v = meta[key];
      // Hand-typed estimates are English ("~3.5 hrs"); wrapped in a
      // left-to-right isolate so the Arabic RTL layout doesn't scramble
      // them into "hrs 3.5~".
      if (v is String && v.trim().isNotEmpty) return '⁦${v.trim()}⁩';
    }
    return null;
  }

  /// "Today, 9:15" / "Yesterday" / "3 days ago" / a date, in Arabic.
  static String relativeTime(DateTime when) {
    final t = AppStrings.instance.t;
    final local = when.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    if (diff <= 0) return '${t('time_today')} $hh:$mm';
    if (diff == 1) return t('time_yesterday');
    if (diff < 7) return '$diff ${t('time_days_ago')}';
    return '${local.year}/${local.month}/${local.day}';
  }
}
