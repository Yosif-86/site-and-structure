import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/strings.dart';
import 'r2_upload.dart';
import 'supabase_service.dart';

enum UploadStatus { uploading, done, failed, cancelled }

class LectureUploadJob {
  final String lectureId;
  final String courseId;
  final String courseTitle;
  final String title;
  final bool isFree;
  final int? durationSeconds;
  final File file;
  double progress = 0;
  UploadStatus status = UploadStatus.uploading;
  R2Upload? _upload;

  LectureUploadJob({
    required this.lectureId,
    required this.courseId,
    required this.courseTitle,
    required this.title,
    required this.isFree,
    required this.durationSeconds,
    required this.file,
  });
}

/// Lecture uploads that keep going while the teacher uses the rest of the
/// app (they used to block the curriculum screen until done). The original
/// file is sent as-is: the server makes the 480p/720p/1080p versions after
/// approval, so shrinking on the phone was slow, duplicated work.
///
/// Uploads stop if the app is fully closed; R2Upload's retries cover short
/// network drops and the phone going idle for a moment.
class UploadManager extends ChangeNotifier {
  UploadManager._();
  static final UploadManager instance = UploadManager._();

  final List<LectureUploadJob> jobs = [];

  /// Set by the app root to show a message wherever the user is.
  void Function(String message)? onMessage;

  bool get busy => jobs.any((j) => j.status == UploadStatus.uploading);

  List<LectureUploadJob> forCourse(String courseId) =>
      jobs.where((j) => j.courseId == courseId).toList();

  /// Starts in the background and returns right away.
  void start(LectureUploadJob job) {
    jobs.add(job);
    notifyListeners();
    unawaited(_run(job));
  }

  void cancel(String lectureId) {
    for (final j in jobs) {
      if (j.lectureId == lectureId && j.status == UploadStatus.uploading) {
        j.status = UploadStatus.cancelled;
        j._upload?.cancel();
      }
    }
    notifyListeners();
  }

  void dismiss(String lectureId) {
    jobs.removeWhere(
        (j) => j.lectureId == lectureId && j.status != UploadStatus.uploading);
    notifyListeners();
  }

  Future<void> _run(LectureUploadJob job) async {
    final t = AppStrings.instance.t;
    final sb = SupabaseService.instance.client;
    final upload = job._upload = R2Upload(
        courseId: job.courseId, lectureId: job.lectureId, file: job.file);
    var lastNotify = DateTime.now();
    try {
      await upload.start((p) {
        job.progress = p;
        // Progress repaints at most ~4 times a second.
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds > 250 || p >= 1) {
          lastNotify = now;
          notifyListeners();
        }
      });
      if (job.status == UploadStatus.cancelled) throw const UploadCancelled();
      // Placed after the course's last lecture at the moment it finishes, so
      // two uploads running together don't share a position.
      final last = await sb
          .from('lectures')
          .select('order_index')
          .eq('course_id', job.courseId)
          .order('order_index', ascending: false)
          .limit(1)
          .maybeSingle();
      final orderIndex = ((last?['order_index'] as num?)?.toInt() ?? -1) + 1;
      // Pending until the admin approves it (only an admin can set r2_path,
      // which is what makes it playable).
      await sb.from('lectures').insert({
        'id': job.lectureId,
        'course_id': job.courseId,
        'title': job.title,
        'is_free': job.isFree,
        'order_index': orderIndex,
        'pending_upload_path': 'r2:${upload.key}',
        if (job.durationSeconds != null)
          'duration_seconds': job.durationSeconds,
      });
      job.status = UploadStatus.done;
      job.progress = 1;
      onMessage?.call(
          t('upload_done').replaceAll('{title}', job.title));
      Timer(const Duration(seconds: 6), () => dismiss(job.lectureId));
    } on UploadCancelled {
      job.status = UploadStatus.cancelled;
      onMessage?.call(t('upload_cancelled'));
      Timer(const Duration(seconds: 3), () => dismiss(job.lectureId));
    } catch (_) {
      job.status = UploadStatus.failed;
      onMessage?.call(
          t('upload_failed_named').replaceAll('{title}', job.title));
    } finally {
      job._upload = null;
      notifyListeners();
    }
  }
}
