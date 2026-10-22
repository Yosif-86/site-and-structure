import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'supabase_service.dart';

/// Public average of a course (only courses with 5 or more ratings have one).
class CourseRatingSummary {
  final double average;
  final int count;
  const CourseRatingSummary(this.average, this.count);
}

/// Course ratings (add-course-ratings.sql): 1 to 5 stars, a private comment
/// for 1 to 3 stars, readable only by the admins and the course's teacher.
class RatingService extends ChangeNotifier {
  RatingService._();
  static final RatingService instance = RatingService._();

  final _storage = const FlutterSecureStorage();
  Map<String, CourseRatingSummary> _summaries = {};

  CourseRatingSummary? summaryFor(String courseId) => _summaries[courseId];

  /// Public averages for every course that has one. Offline or table not
  /// added yet: keeps whatever was loaded before.
  Future<void> load() async {
    try {
      final rows = await SupabaseService.instance.client
          .rpc('course_rating_summaries');
      final next = <String, CourseRatingSummary>{};
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final id = r['course_id'] as String?;
        final avg = (r['avg_rating'] as num?)?.toDouble();
        final n = (r['rating_count'] as num?)?.toInt();
        if (id != null && avg != null && n != null) {
          next[id] = CourseRatingSummary(avg, n);
        }
      }
      _summaries = next;
      notifyListeners();
    } catch (_) {}
  }

  /// The signed-in student's own rating of a course: {rating, comment}.
  Future<Map<String, dynamic>?> myRating(String courseId) async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return null;
    try {
      return await SupabaseService.instance.client
          .from('course_ratings')
          .select('rating, comment')
          .eq('course_id', courseId)
          .eq('user_id', user.id)
          .maybeSingle();
    } catch (_) {
      return null;
    }
  }

  Future<void> rate(String courseId, int rating, String? comment) async {
    await SupabaseService.instance.client.rpc('rate_course', params: {
      'p_course': courseId,
      'p_rating': rating,
      'p_comment': comment,
    });
    await load();
  }

  Future<void> remove(String courseId) async {
    await SupabaseService.instance.client
        .rpc('remove_course_rating', params: {'p_course': courseId});
    await load();
  }

  /// Admin or the course's teacher: every rating with the student's name and ID.
  Future<List<Map<String, dynamic>>> reviewsFor(String courseId) async {
    final rows = await SupabaseService.instance.client
        .rpc('course_reviews', params: {'p_course': courseId});
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Which ask a student is due for: 0 none, 1 at 25% of the lectures
  /// finished, 2 at 75%. At least one lecture must be finished.
  static int dueStage(int completed, int total) {
    if (total <= 0 || completed <= 0) return 0;
    final at25 = (total * 0.25).ceil().clamp(1, total);
    final at75 = (total * 0.75).ceil().clamp(1, total);
    if (completed >= at75) return 2;
    if (completed >= at25) return 1;
    return 0;
  }

  String _promptKey(String userId, String courseId) =>
      'rate_prompt_${userId}_$courseId';

  /// The last stage already shown to this student for this course.
  Future<int> shownStage(String userId, String courseId) async {
    try {
      final v = await _storage.read(key: _promptKey(userId, courseId));
      return int.tryParse(v ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> markShown(String userId, String courseId, int stage) async {
    try {
      await _storage.write(
          key: _promptKey(userId, courseId), value: '$stage');
    } catch (_) {}
  }
}
