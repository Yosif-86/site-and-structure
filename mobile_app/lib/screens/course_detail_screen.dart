import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../models/lecture.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'auth_screen.dart';
import 'video_player_screen.dart';

/// Port of renderPage() + openEnroll()/submitFree()/submitPay() in course.html.
class CourseDetailScreen extends StatefulWidget {
  final String slug;
  const CourseDetailScreen({super.key, required this.slug});

  @override
  State<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends State<CourseDetailScreen> {
  Course? _course;
  List<Lecture> _lectures = [];
  String? _enrollmentStatus; // 'active' | 'pending' | null
  Set<String> _completedLectureIds = {};
  // lecture_id -> {position_seconds, duration_seconds}, in-progress (not
  // completed) lectures only — drives each row's progress bar plus which
  // lecture (if any) is the "continue watching" one.
  Map<String, Map<String, int>> _progressByLecture = {};
  String? _continueWatchingId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sb = SupabaseService.instance.client;
    try {
      final courseRow = await sb
          .from('courses')
          .select('*')
          .eq('slug', widget.slug)
          .eq('status', 'published')
          .maybeSingle();
      if (courseRow == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'not_found';
        });
        return;
      }
      final course = Course.fromJson(courseRow);
      // ascending must be explicit — postgrest's order() defaults it to
      // false, which was silently reversing the curriculum (Episode 2
      // before Episode 1) until this was caught by visual testing.
      final lectureRows = await sb
          .from('lectures')
          .select('*')
          .eq('course_id', course.id)
          .order('order_index', ascending: true);
      final lectures = (lectureRows as List)
          .map((r) => Lecture.fromJson(r as Map<String, dynamic>))
          .toList();

      String? status;
      var completedIds = <String>{};
      var progressByLecture = <String, Map<String, int>>{};
      String? continueWatchingId;
      final user = SupabaseService.instance.currentUser;
      if (user != null) {
        final enr = await sb
            .from('enrollments')
            .select('status')
            .eq('user_id', user.id)
            .eq('course_slug', course.slug)
            .maybeSingle();
        status = enr?['status'] as String?;

        if (lectures.isNotEmpty) {
          final progressRows = await sb
              .from('lesson_progress')
              .select(
                  'lecture_id, position_seconds, duration_seconds, completed, updated_at')
              .eq('user_id', user.id)
              .inFilter('lecture_id', lectures.map((l) => l.id).toList());

          DateTime? latestUpdate;
          for (final row in (progressRows as List)) {
            final r = row as Map<String, dynamic>;
            final lectureId = r['lecture_id'] as String;
            if (r['completed'] == true) {
              completedIds.add(lectureId);
              continue;
            }
            final position = r['position_seconds'] as int? ?? 0;
            final duration = r['duration_seconds'] as int? ?? 0;
            if (position <= 0 || duration <= 0) continue;
            progressByLecture[lectureId] = {
              'position': position,
              'duration': duration
            };
            final updatedAt =
                DateTime.tryParse(r['updated_at'] as String? ?? '');
            if (updatedAt != null &&
                (latestUpdate == null || updatedAt.isAfter(latestUpdate))) {
              latestUpdate = updatedAt;
              continueWatchingId = lectureId;
            }
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _course = course;
        _lectures = lectures;
        _enrollmentStatus = status;
        _completedLectureIds = completedIds;
        _progressByLecture = progressByLecture;
        _continueWatchingId = continueWatchingId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorReporter.userMessage(e, page: 'course_detail');
      });
    }
  }

  String _t(String key) => AppStrings.instance.t(key);

  Future<void> _watchLecture(Lecture lecture) async {
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
      await _load();
    }
    if (!mounted) return;
    final isActive = _enrollmentStatus == 'active';
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        lectureId: lecture.id,
        title: lecture.localizedTitle(AppStrings.instance.isAr),
        playlist: _lectures,
        isUnlocked: (l) => l.isFree || isActive,
      ),
    ));
    if (mounted) _load();
  }

  Future<void> _openEnroll() async {
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
      // Logging in can reveal an enrollment that already exists under this
      // account (_enrollmentStatus was fetched while logged out, so it's
      // stale null) — reload before showing the enroll sheet, otherwise a
      // free/paid course the user already owns lets them submit again and
      // hit enrollments' unique(user_id, course_slug) constraint.
      await _load();
      if (!mounted) return;
      // Reload can reveal an existing enrollment under this account; if so
      // the page behind already reflects it, so skip the enroll sheet.
      if (_enrollmentStatus != null) return;
    }
    if (!mounted) return;
    final course = _course!;
    if (course.isFree) {
      await showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.panel,
        isScrollControlled: true,
        builder: (_) => _FreeEnrollSheet(course: course, onDone: _load),
      );
    } else {
      await showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.panel,
        isScrollControlled: true,
        builder: (_) => _PaidEnrollSheet(course: course, onDone: _load),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error == 'not_found'
                ? Center(
                    child: Text(_t('course_not_found'),
                        style: AppFonts.body(color: AppColors.muted)))
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: AppFonts.body(color: AppColors.muted)))
                    : _buildContent(),
        // Price + enrol stay reachable no matter how far down the
        // curriculum the reader has scrolled.
        bottomNavigationBar: (_loading || _error != null || _course == null)
            ? null
            : _EnrollBar(
                course: _course!,
                status: _enrollmentStatus,
                onEnroll: _openEnroll,
              ),
      ),
    );
  }

  Widget _buildContent() {
    final ar = AppStrings.instance.isAr;
    final course = _course!;
    final title = course.localizedTitle(ar);
    final desc = course.localizedDescription(ar);
    final teacher = course.localizedTeacherName(ar);
    final tag = course.localizedTagLabel(ar);
    final meta = course.localizedMeta(ar) ?? {};
    final isActive = _enrollmentStatus == 'active';
    final freeLecture = _lectures.where((l) => l.isFree).isEmpty
        ? null
        : _lectures.firstWhere((l) => l.isFree);
    final freeCount = _lectures.where((l) => l.isFree).length;
    // A lecture already in progress takes over the hero from the free
    // preview — there's no point pitching a first-lecture teaser to someone
    // who's already partway through the course.
    final continueMatch =
        _lectures.where((l) => l.id == _continueWatchingId);
    final continueLecture = continueMatch.isEmpty ? null : continueMatch.first;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _CourseHero(
          tag: tag,
          thumbnailUrl: course.thumbnailUrl,
          previewLabel: continueLecture != null
              ? _t('continue_watching')
              : (freeLecture != null ? _t('preview_course') : null),
          onPreview: continueLecture != null
              ? () => _watchLecture(continueLecture)
              : (freeLecture != null ? () => _watchLecture(freeLecture) : null),
        ),
        const SizedBox(height: 18),
        Text(title, style: AppFonts.body(size: 24, weight: FontWeight.w700)),
        if (teacher != null && teacher.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: AppColors.panel2,
              child: Text(teacher.characters.first.toUpperCase(),
                  style: AppFonts.body(size: 12, weight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(teacher,
                    style: AppFonts.body(size: 14, color: AppColors.muted))),
          ]),
        ],
        if (desc != null && desc.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(desc, style: AppFonts.body(size: 15, color: AppColors.muted)),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
                icon: Icons.play_circle_outline,
                label: '${_lectures.length} ${_t('feature_video_lectures')}'),
            _Chip(
                icon: Icons.all_inclusive,
                label: _t('feature_lifetime_access')),
            if (freeCount > 0)
              _Chip(
                  icon: Icons.lock_open_outlined,
                  label: '$freeCount ${_t('feature_free_preview')}'),
            for (final e in meta.entries) _Chip(label: '${e.key}: ${e.value}'),
          ],
        ),
        const SizedBox(height: 28),
        Row(children: [
          Text(_t('curriculum'),
              style: AppFonts.body(size: 17, weight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('${_lectures.length} ${_t('lectures_count')}',
              style: AppFonts.body(size: 13, color: AppColors.muted)),
        ]),
        const SizedBox(height: 12),
        if (_lectures.isEmpty)
          Text(_t('no_lectures'), style: AppFonts.body(color: AppColors.muted))
        else
          _CurriculumCard(
            lectures: _orderedLectures(),
            isActive: isActive,
            completedIds: _completedLectureIds,
            progressByLecture: _progressByLecture,
            continueWatchingId: _continueWatchingId,
            onWatch: _watchLecture,
          ),
      ],
    );
  }

  // The in-progress lecture (if any) is pulled to the top, same as the
  // "continue watching" pattern on the website's course page.
  List<Lecture> _orderedLectures() {
    if (_continueWatchingId == null) return _lectures;
    final match = _lectures.where((l) => l.id == _continueWatchingId);
    if (match.isEmpty) return _lectures;
    final continueLecture = match.first;
    return [
      continueLecture,
      ..._lectures.where((l) => l.id != _continueWatchingId)
    ];
  }
}

/// Sticky footer: price on one side, the enrol action on the other. Once
/// the viewer is enrolled (or waiting on approval) it turns into a quiet
/// status strip instead of disappearing, so the page still explains why
/// there's no button.
class _EnrollBar extends StatelessWidget {
  final Course course;
  final String? status;
  final VoidCallback onEnroll;
  const _EnrollBar(
      {required this.course, required this.status, required this.onEnroll});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final isActive = status == 'active';
    final isPending = status == 'pending';
    final bottomInset = MediaQuery.of(context).padding.bottom;

    Widget content;
    if (isActive || isPending) {
      content = Row(children: [
        Icon(isActive ? Icons.check_circle : Icons.hourglass_top,
            color: AppColors.teal, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            isActive ? t('status_active') : t('pending_note'),
            style: AppFonts.body(
                size: 13.5, color: isActive ? AppColors.teal : AppColors.muted),
          ),
        ),
      ]);
    } else {
      content = Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('price'),
                  style: AppFonts.body(size: 12, color: AppColors.muted)),
              const SizedBox(height: 2),
              course.isFree
                  ? Text(t('card_free'),
                      style: AppFonts.body(
                          size: 20,
                          weight: FontWeight.w700,
                          color: AppColors.teal))
                  : Text(course.price ?? '',
                      style: AppFonts.code(size: 20, weight: FontWeight.w700)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 170,
          child: ElevatedButton(
            onPressed: onEnroll,
            child: Text(course.isFree ? t('enroll_free') : t('enroll')),
          ),
        ),
      ]);
    }

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: content,
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData? icon;
  final String label;
  const _Chip({this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: AppColors.muted),
          const SizedBox(width: 6),
        ],
        Text(label, style: AppFonts.body(size: 12.5, color: AppColors.text)),
      ]),
    );
  }
}

/// Rounded hero image with the course tag and, when a free lecture exists,
/// a preview affordance over it.
class _CourseHero extends StatelessWidget {
  final String? tag;
  final String? thumbnailUrl;
  final String? previewLabel;
  final VoidCallback? onPreview;
  const _CourseHero(
      {this.tag, this.thumbnailUrl, this.previewLabel, this.onPreview});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailUrl != null)
              Image.network(
                thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const _HeroGradientFallback(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _HeroGradientFallback(),
              )
            else
              const _HeroGradientFallback(),
            if (thumbnailUrl == null)
              Positioned(
                right: -40,
                top: -40,
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      AppColors.red.withValues(alpha: 0.22),
                      Colors.transparent
                    ]),
                  ),
                ),
              ),
            if (tag != null && tag!.isNotEmpty)
              Positioned(
                left: 16,
                top: 16,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.bg.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(tag!, style: AppFonts.eyebrow(size: 11)),
                ),
              ),
            if (onPreview != null)
              Center(
                child: GestureDetector(
                  onTap: onPreview,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.red,
                          boxShadow: [
                            BoxShadow(
                                color: AppColors.red.withValues(alpha: 0.4),
                                blurRadius: 24,
                                spreadRadius: 2)
                          ],
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 32),
                      ),
                      const SizedBox(height: 10),
                      Text(previewLabel!,
                          style: AppFonts.body(
                              size: 12.5,
                              color: Colors.white,
                              weight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HeroGradientFallback extends StatelessWidget {
  const _HeroGradientFallback();
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.panel2, AppColors.bg],
        ),
      ),
    );
  }
}

/// Curriculum list grouped inside one card with dividers, instead of
/// separate floating rows — reads as a single structured section.
class _CurriculumCard extends StatelessWidget {
  final List<Lecture> lectures;
  final bool isActive;
  final Set<String> completedIds;
  final Map<String, Map<String, int>> progressByLecture;
  final String? continueWatchingId;
  final void Function(Lecture) onWatch;
  const _CurriculumCard({
    required this.lectures,
    required this.isActive,
    required this.completedIds,
    required this.progressByLecture,
    required this.continueWatchingId,
    required this.onWatch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < lectures.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppColors.line),
            _LectureRow(
              index: i + 1,
              lecture: lectures[i],
              unlocked: lectures[i].isFree || isActive,
              completed: completedIds.contains(lectures[i].id),
              progress: progressByLecture[lectures[i].id],
              isContinueWatching: lectures[i].id == continueWatchingId,
              onWatch: () => onWatch(lectures[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _LectureRow extends StatelessWidget {
  final int index;
  final Lecture lecture;
  final bool unlocked;
  final bool completed;
  final Map<String, int>? progress;
  final bool isContinueWatching;
  final VoidCallback onWatch;
  const _LectureRow({
    required this.index,
    required this.lecture,
    required this.unlocked,
    required this.completed,
    required this.progress,
    required this.isContinueWatching,
    required this.onWatch,
  });

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final pct = progress == null
        ? null
        : (progress!['position']! / progress!['duration']!).clamp(0.0, 1.0);

    Widget leading;
    if (completed) {
      leading = Icon(Icons.check_circle, size: 22, color: AppColors.teal);
    } else if (!unlocked) {
      leading = Icon(Icons.lock_outline, size: 20, color: AppColors.muted2);
    } else {
      leading = Text(index.toString().padLeft(2, '0'),
          style: AppFonts.code(size: 13, color: AppColors.muted));
    }

    return InkWell(
      onTap: unlocked ? onWatch : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(width: 28, child: Center(child: leading)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lecture.localizedTitle(ar),
                        style: AppFonts.body(
                            size: 14.5,
                            weight: FontWeight.w500,
                            color: unlocked ? AppColors.text : AppColors.muted),
                      ),
                      if (isContinueWatching || lecture.isFree)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            isContinueWatching
                                ? t('continue_watching')
                                : t('free_tag'),
                            style: AppFonts.body(
                                size: 11.5,
                                weight: FontWeight.w600,
                                color: isContinueWatching
                                    ? AppColors.red
                                    : AppColors.teal),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (unlocked)
                  Icon(
                    isContinueWatching
                        ? Icons.play_circle_fill
                        : Icons.play_circle_outline,
                    color: isContinueWatching ? AppColors.red : AppColors.muted,
                    size: 24,
                  )
                else
                  Text(t('locked'),
                      style:
                          AppFonts.body(size: 12.5, color: AppColors.muted2)),
              ],
            ),
            if (pct != null) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 38),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 3,
                    backgroundColor: AppColors.line,
                    valueColor: AlwaysStoppedAnimation(AppColors.red),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Free-course enroll confirmation sheet, mirrors openEnroll()'s free branch.
class _FreeEnrollSheet extends StatefulWidget {
  final Course course;
  final VoidCallback onDone;
  const _FreeEnrollSheet({required this.course, required this.onDone});

  @override
  State<_FreeEnrollSheet> createState() => _FreeEnrollSheetState();
}

class _FreeEnrollSheetState extends State<_FreeEnrollSheet> {
  bool _loading = false;
  String? _error;
  bool _done = false;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser!;
    try {
      await sb.from('enrollments').insert({
        'user_id': user.id,
        'course_slug': widget.course.slug,
        'status': 'active'
      });
      if (!mounted) return;
      setState(() {
        _loading = false;
        _done = true;
      });
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorReporter.userMessage(e, page: 'enroll_free');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 24,
          right: 24,
          top: 24),
      child: SafeArea(
        child: _done
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_outline,
                    color: AppColors.teal, size: 44),
                const SizedBox(height: 12),
                Text(t('enrolled'), style: AppFonts.heading(size: 22)),
                const SizedBox(height: 16),
                OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t('btn_close'))),
                const SizedBox(height: 12),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.course.localizedTitle(ar),
                    style: AppFonts.heading(size: 22)),
                const SizedBox(height: 6),
                Text(t('free_course_sub'),
                    style: AppFonts.body(size: 13, color: AppColors.muted)),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: AppFonts.body(size: 12.5, color: AppColors.red)),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      child: Text(t('enroll_free'))),
                ),
                const SizedBox(height: 16),
              ]),
      ),
    );
  }
}

/// Paid-course enroll sheet: payment method + detail + proof screenshot upload,
/// mirrors openEnroll()'s paid branch + submitPay() in course.html.
class _PaidEnrollSheet extends StatefulWidget {
  final Course course;
  final VoidCallback onDone;
  const _PaidEnrollSheet({required this.course, required this.onDone});

  @override
  State<_PaidEnrollSheet> createState() => _PaidEnrollSheetState();
}

class _PaidEnrollSheetState extends State<_PaidEnrollSheet> {
  String? _method; // 'zain' | 'qi'
  final _detailCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  XFile? _proof;
  bool _loading = false;
  String? _error;
  bool _done = false;

  // Payment destination (get_course_payment_info) — who the student sends
  // money to: the course's teacher (if pay_to_teacher) or the admin.
  bool _payInfoLoading = true;
  String? _payZaincashPhone;
  String? _payQiAccountNumber;
  String? _payQiQrUrl;

  // Discount code (redeem_discount_code), applied client-side to the shown
  // price — mirrors course.html's applyDiscountCode().
  String? _discountError;
  String? _discountOk;
  num? _discountedPrice;
  bool _discountApplied = false;

  @override
  void initState() {
    super.initState();
    _loadPaymentInfo();
  }

  Future<void> _loadPaymentInfo() async {
    try {
      final sb = SupabaseService.instance.client;
      final rows = await sb.rpc('get_course_payment_info',
          params: {'p_course_slug': widget.course.slug});
      if (rows is List && rows.isNotEmpty) {
        final row = rows.first as Map<String, dynamic>;
        setState(() {
          _payZaincashPhone = row['zaincash_phone'] as String?;
          _payQiAccountNumber = row['qi_account_number'] as String?;
          _payQiQrUrl = row['qi_qr_url'] as String?;
        });
      }
    } catch (_) {
      // Non-fatal — checkout still works without the send-to box.
    } finally {
      if (mounted) setState(() => _payInfoLoading = false);
    }
  }

  int _parsePrice(dynamic price) {
    final digits = RegExp(r'\d')
        .allMatches(price?.toString() ?? '')
        .map((m) => m.group(0))
        .join();
    return digits.isEmpty ? 0 : int.parse(digits);
  }

  Future<void> _applyDiscount() async {
    final t = AppStrings.instance.t;
    final code = _discountCtrl.text.trim().toUpperCase();
    setState(() {
      _discountError = null;
      _discountOk = null;
    });
    if (code.isEmpty) {
      setState(() => _discountError = t('err_enter_discount_code'));
      return;
    }
    try {
      // Routed through the server (not sb.rpc directly) so the daily
      // attempts cap in api/redeem-discount-code.js actually applies --
      // calling the RPC straight from the client would bypass it.
      final accessToken =
          SupabaseService.instance.client.auth.currentSession?.accessToken;
      if (accessToken == null) {
        setState(() => _discountError = t('err_invalid_discount'));
        return;
      }
      final res = await http.post(
        Uri.parse('$kApiBaseUrl/api/redeem-discount-code'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode(
            {'code': code, 'courseId': widget.course.id}),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || body['ok'] != true) {
        setState(() => _discountError =
            res.statusCode == 429 && body['error'] is String
                ? body['error'] as String
                : t('err_invalid_discount'));
        return;
      }
      final type = body['discountType'] as String?;
      final value = (body['discountValue'] as num?) ?? 0;
      final priceNum = _parsePrice(widget.course.price);
      final discounted = type == 'percent'
          ? (priceNum * (1 - value / 100)).round().clamp(0, priceNum)
          : (priceNum - value).round().clamp(0, priceNum);
      setState(() {
        _discountedPrice = discounted;
        _discountApplied = true;
        _discountOk = '${t('total_after_discount')}: $discounted';
      });
    } catch (e) {
      setState(() => _discountError = t('err_invalid_discount'));
    }
  }

  @override
  void dispose() {
    _detailCtrl.dispose();
    _discountCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) setState(() => _proof = picked);
  }

  Future<void> _submit() async {
    final t = AppStrings.instance.t;
    if (_method == null || _detailCtrl.text.trim().isEmpty) {
      setState(() => _error = t('err_choose_payment'));
      return;
    }
    if (_proof == null) {
      setState(() => _error = t('err_upload_proof'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser!;
    try {
      final fileName =
          '${user.id}/${DateTime.now().millisecondsSinceEpoch}-${_proof!.name}';
      await sb.storage
          .from('payment-proofs')
          .upload(fileName, File(_proof!.path));
      await sb.from('enrollments').insert({
        'user_id': user.id,
        'course_slug': widget.course.slug,
        'status': 'pending',
        'payment_method': _method,
        'payment_detail': _detailCtrl.text.trim(),
        'payment_proof_path': fileName,
      });
      if (!mounted) return;
      setState(() {
        _loading = false;
        _done = true;
      });
      widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorReporter.userMessage(e, page: 'enroll_paid');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 24,
          right: 24,
          top: 24),
      child: SafeArea(
        child: SingleChildScrollView(
          child: _done
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline,
                      color: AppColors.teal, size: 44),
                  const SizedBox(height: 12),
                  Text(t('submitted'), style: AppFonts.heading(size: 22)),
                  const SizedBox(height: 8),
                  Text(t('pending_note'),
                      textAlign: TextAlign.center,
                      style: AppFonts.body(size: 13, color: AppColors.muted)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(t('btn_close'))),
                  const SizedBox(height: 12),
                ])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      Text(widget.course.localizedTitle(ar),
                          style: AppFonts.heading(size: 22)),
                      const SizedBox(height: 4),
                      Text(
                        '${_discountedPrice ?? widget.course.price ?? ''}${t('choose_payment_sub')}',
                        style: AppFonts.body(size: 13, color: AppColors.muted),
                      ),
                      if (_payInfoLoading) ...[
                        const SizedBox(height: 12),
                        const SizedBox(
                            height: 2,
                            width: 60,
                            child: LinearProgressIndicator()),
                      ] else if ((_payZaincashPhone?.isNotEmpty ?? false) ||
                          (_payQiAccountNumber?.isNotEmpty ?? false) ||
                          (_payQiQrUrl?.isNotEmpty ?? false)) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.teal.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: AppColors.teal.withOpacity(0.3)),
                          ),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t('send_payment_to'),
                                    style: AppFonts.body(
                                        size: 11.5, color: AppColors.muted)),
                                const SizedBox(height: 4),
                                if (_payZaincashPhone?.isNotEmpty ?? false)
                                  Text('${t('zain_cash')} — $_payZaincashPhone',
                                      style: AppFonts.body(
                                          size: 14, weight: FontWeight.w700)),
                                if (_payQiAccountNumber?.isNotEmpty ?? false)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                        '${t('qi_card')} — $_payQiAccountNumber',
                                        style: AppFonts.body(
                                            size: 14, weight: FontWeight.w700)),
                                  ),
                                if (_payQiQrUrl?.isNotEmpty ?? false)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(_payQiQrUrl!,
                                          width: 140,
                                          height: 140,
                                          fit: BoxFit.cover),
                                    ),
                                  ),
                              ]),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _discountCtrl,
                            enabled: !_discountApplied,
                            decoration:
                                InputDecoration(labelText: t('discount_code')),
                            textCapitalization: TextCapitalization.characters,
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                            onPressed: _discountApplied ? null : _applyDiscount,
                            child: Text(t('apply'))),
                      ]),
                      if (_discountError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(_discountError!,
                              style: AppFonts.body(
                                  size: 12, color: AppColors.red)),
                        ),
                      if (_discountOk != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(_discountOk!,
                              style: AppFonts.body(
                                  size: 12, color: AppColors.teal)),
                        ),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                            child: _PayOption(
                                label: t('zain_cash'),
                                sub: t('zain_sub'),
                                selected: _method == 'zain',
                                onTap: () => setState(() => _method = 'zain'))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _PayOption(
                                label: t('qi_card'),
                                sub: t('qi_sub'),
                                selected: _method == 'qi',
                                onTap: () => setState(() => _method = 'qi'))),
                      ]),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _detailCtrl,
                          decoration:
                              InputDecoration(labelText: t('pay_label'))),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _pickProof,
                        icon: const Icon(Icons.image_outlined),
                        label: Text(
                            _proof == null
                                ? t('payment_screenshot')
                                : _proof!.name,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(_error!,
                            style: AppFonts.body(
                                size: 12.5, color: AppColors.red)),
                      ],
                      const SizedBox(height: 18),
                      ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          child: Text(t('confirm_payment'))),
                      const SizedBox(height: 16),
                    ]),
        ),
      ),
    );
  }
}

class _PayOption extends StatelessWidget {
  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;
  const _PayOption(
      {required this.label,
      required this.sub,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? AppColors.teal : AppColors.line),
          borderRadius: BorderRadius.circular(10),
          color: selected ? AppColors.teal.withOpacity(0.08) : null,
        ),
        child: Column(children: [
          Text(label, style: AppFonts.body(weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(sub, style: AppFonts.mono(size: 10, letterSpacing: 0.3)),
        ]),
      ),
    );
  }
}
