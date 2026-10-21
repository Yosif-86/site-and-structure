import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/apple_iap.dart';
import '../services/purchase_config.dart';
import '../i18n/strings.dart';
import '../models/course.dart';
import '../models/lecture.dart';
import '../services/error_reporter.dart';
import '../services/live_refresh.dart';
import '../services/learning_service.dart';
import '../services/money.dart';
import '../services/net_status.dart';
import '../services/safe_picker.dart';
import '../services/supabase_service.dart';
import '../services/tap_guard.dart';
import '../theme.dart';
import '../widgets/report_sheet.dart';
import '../widgets/course_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_pay_button.dart';
import '../widgets/arc_icons.dart';
import '../widgets/file_preview.dart';
import '../widgets/glass_scaffold.dart';
import 'auth_screen.dart';
import 'course_files.dart';
import 'teacher_profile_screen.dart';
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
  List<Map<String, dynamic>> _files = [];
  String? _enrollmentStatus; // 'active' | 'pending' | null
  /// Why the student's last payment for this course was rejected (shown
  /// until they submit again).
  String? _rejectionReason;
  // iPhone: Apple's price for this course (In-App Purchase), when it loaded.
  String? _applePrice;
  bool _buyingApple = false;
  Set<String> _completedLectureIds = {};
  // lecture_id -> {position_seconds, duration_seconds}, in-progress (not
  // completed) lectures only -- drives each row's progress bar plus which
  // lecture (if any) is the "continue watching" one.
  Map<String, Map<String, int>> _progressByLecture = {};
  String? _continueWatchingId;
  bool _loading = true;
  String? _error;
  int _tab = 0; // 0 = curriculum, 1 = files
  final Map<String, GlobalKey> _fileGroupKeys = {};

  /// Opens the Files tab, scrolled to [lectureId]'s files.
  void _openFiles(String lectureId) {
    setState(() => _tab = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _fileGroupKeys[lectureId]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 300), alignment: 0.05);
      }
    });
  }

  // An approved payment unlocks the course on screen the moment it happens.
  late final _live = LiveRefresh(
      tables: const ['enrollments', 'lectures', 'courses'], onChange: _load);

  @override
  void initState() {
    super.initState();
    _load();
    _live.start();
  }

  @override
  void dispose() {
    _live.stop();
    super.dispose();
  }

  Future<void> _load() async {
    // Only the first load shows the full-page spinner; later reloads (after
    // watching or enrolling) refresh in place instead of blanking the page.
    if (_course == null) setState(() => _loading = true);
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
      // ascending must be explicit -- postgrest's order() defaults it to
      // false, which was silently reversing the curriculum (Episode 2
      // before Episode 1) until this was caught by visual testing.
      final lectureRows = await sb
          .from('lectures')
          .select('*')
          .eq('course_id', course.id)
          .order('order_index', ascending: true);
      await PurchaseConfig.instance.load();
      final lectures = (lectureRows as List)
          .map((r) => Lecture.fromJson(r as Map<String, dynamic>))
          .toList();
      var files = <Map<String, dynamic>>[];
      try {
        final fileRows = await sb
            .from('course_files')
            .select(
                'id, title, kind, view_path, view_type, is_free, allow_download, original_name, status, lecture_id')
            .eq('course_id', course.id)
            .eq('status', 'published')
            .order('order_index');
        files = (fileRows as List).cast<Map<String, dynamic>>();
      } catch (_) {
        // course_files not added yet: no files section.
      }

      String? status;
      String? rejection;
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
        // Store-review account: every course opens without an enrollment.
        if (status != 'active') {
          try {
            final me = await sb
                .from('profiles')
                .select('is_reviewer')
                .eq('id', user.id)
                .maybeSingle();
            // Android only: Apple's reviewer must be able to test the
            // In-App Purchase, so on iPhone paid courses stay locked.
            if (me?['is_reviewer'] == true && !AppleIap.instance.available) {
              status = 'active';
            }
          } catch (_) {
            // Column not added yet (add-reviewer-and-reports.sql).
          }
        }
        if (status == null) {
          try {
            final rej = await sb
                .from('enrollment_rejections')
                .select('reason')
                .eq('user_id', user.id)
                .eq('course_slug', course.slug)
                .order('created_at', ascending: false)
                .limit(1)
                .maybeSingle();
            rejection = rej?['reason'] as String?;
          } catch (_) {}
        }

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

      String? applePrice;
      if (AppleIap.instance.available && !course.isFree && status != 'active') {
        applePrice = await AppleIap.instance.priceLabel(course.price);
      }

      if (!mounted) return;
      setState(() {
        _course = course;
        _lectures = lectures;
        _files = files;
        _applePrice = applePrice;
        _enrollmentStatus = status;
        _rejectionReason = rejection;
        _completedLectureIds = completedIds;
        _progressByLecture = progressByLecture;
        _continueWatchingId = continueWatchingId;
        _loading = false;
        _error = null;
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

  bool get _isActive => _enrollmentStatus == 'active';

  /// iPhone: buy this course with Apple In-App Purchase.
  Future<void> _buyWithApple() async {
    if (_buyingApple || !TapGuard.allow()) return;
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
      await _load();
      if (!mounted || _isActive) return;
    }
    final course = _course;
    if (course == null) return;
    setState(() => _buyingApple = true);
    final result = await AppleIap.instance
        .buy(courseSlug: course.slug, coursePrice: course.price);
    if (!mounted) return;
    setState(() => _buyingApple = false);
    if (result == 'cancelled') return;
    final key = switch (result) {
      'enrolled' => 'iap_success',
      'pending' => 'iap_pending',
      'iap_retry_later' => 'iap_retry_later',
      'iap_rejected' => 'iap_rejected',
      'iap_unavailable' => 'iap_unavailable',
      _ => 'iap_failed',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_t(key))));
    if (result == 'enrolled') await _load();
  }

  Future<void> _watchLecture(Lecture lecture) async {
    if (!TapGuard.allow()) return;
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
      await _load();
    }
    if (!mounted) return;
    final isActive = _isActive;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        lectureId: lecture.id,
        title: lecture.localizedTitle(AppStrings.instance.isAr),
        playlist: _lectures,
        isUnlocked: (l) => l.isFree || isActive,
        files: _files,
        filesUnlocked: isActive,
      ),
    ));
    if (mounted) _load();
  }

  Future<void> _openEnroll() async {
    if (!TapGuard.allow()) return;
    // Review switch: paid courses can't be bought in the app right now.
    if (!(_course?.isFree ?? true) && !PurchaseConfig.instance.enabled) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_t('course_subscribers_only'))));
      return;
    }
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
      // Logging in can reveal an enrollment that already exists under this
      // account (_enrollmentStatus was fetched while logged out, so it's
      // stale null) -- reload before showing the enroll sheet, otherwise a
      // free/paid course the user already owns lets them submit again and
      // hit enrollments' unique(user_id, course_slug) constraint.
      await _load();
      if (!mounted) return;
      if (_enrollmentStatus != null) return;
    }
    if (!mounted) return;
    final course = _course!;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => GlassSheet(
        child: course.isFree
            ? _FreeEnrollSheet(course: course, onDone: _load)
            : kWaylPayments
                ? _WaylEnrollSheet(course: course, onDone: _load)
                : _PaidEnrollSheet(course: course, onDone: _load),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassCard(
            padding: const EdgeInsets.all(20),
            child: Text(
                _error == 'not_found' ? _t('course_not_found') : _error!,
                textAlign: TextAlign.center,
                style: AppFonts.body(color: AppColors.muted)),
          ),
        ),
      );
    } else {
      body = _buildContent();
    }
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
          appBar: AppBar(actions: [
            if (_course != null && SupabaseService.instance.currentUser != null)
              IconButton(
                tooltip: _t('report_tooltip'),
                icon: const Icon(Icons.outlined_flag_rounded),
                onPressed: () => showReportSheet(context, _course!.id),
              ),
          ]),
          body: body),
    );
  }

  Widget _buildContent() {
    final ar = AppStrings.instance.isAr;
    final course = _course!;
    final teacher = course.localizedTeacherName(ar);
    final tag = course.localizedTagLabel(ar);
    final freeLecture = _lectures.where((l) => l.isFree).firstOrNull;
    final freeCount = _lectures.where((l) => l.isFree).length;
    // A lecture already in progress takes over the hero from the free
    // preview -- there's no point pitching a first-lecture teaser to someone
    // who's already partway through the course.
    final continueLecture =
        _lectures.where((l) => l.id == _continueWatchingId).firstOrNull;
    // An enrolled student who hasn't started gets "start" on lecture 1.
    final startLecture =
        (_isActive && _lectures.isNotEmpty) ? _lectures.first : null;
    final heroLecture = continueLecture ?? startLecture ?? freeLecture;
    final heroLabel = continueLecture != null
        ? _t('continue_watching')
        : startLecture != null
            ? _t('start_course')
            : freeLecture != null
                ? _t('preview_course')
                : null;

    final totalSeconds =
        _lectures.fold<int>(0, (s, l) => s + (l.durationSeconds ?? 0));
    final durationLabel = LearningService.courseDurationLabel(
        course,
        CourseStats(
            lectureCount: _lectures.length, totalSeconds: totalSeconds));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
      children: [
        FadeSlideIn(
          delayMs: 0,
          child: _CourseHero(
            tag: tag,
            thumbnailUrl: course.thumbnailUrl,
            playLabel: heroLabel,
            onPlay:
                heroLecture == null ? null : () => _watchLecture(heroLecture),
          ),
        ),
        const SizedBox(height: 16),
        Text(course.localizedTitle(ar),
            style: AppFonts.body(size: 23, weight: FontWeight.w800)),
        if (teacher != null && teacher.isNotEmpty) ...[
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: course.teacherId == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => TeacherProfileScreen(
                        teacherId: course.teacherId!, fallbackName: teacher))),
            child: Row(children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      colors: [AppColors.red, AppColors.teal],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight),
                ),
                child: Text(teacher.characters.first.toUpperCase(),
                    style: AppFonts.body(
                        size: 15,
                        weight: FontWeight.w700,
                        color: Colors.white)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(teacher,
                        style:
                            AppFonts.body(size: 15, weight: FontWeight.w600)),
                    Text(_t('instructor'),
                        style: AppFonts.body(size: 12, color: AppColors.muted)),
                  ],
                ),
              ),
              if (course.teacherId != null)
                ArcIconView(ArcIcon.chevron, size: 16, color: AppColors.muted2),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        if (_enrollmentStatus == null && _rejectionReason != null) ...[
          _RejectedBanner(reason: _rejectionReason!),
          const SizedBox(height: 12),
        ],
        FadeSlideIn(
          delayMs: 60,
          child: _EnrollPanel(
            course: course,
            status: _enrollmentStatus,
            purchasesOn: PurchaseConfig.instance.enabled,
            appleIap: AppleIap.instance.available &&
                AppleIap.productForPrice(course.price) != null,
            applePrice: _applePrice,
            buyingApple: _buyingApple,
            onBuyApple: _buyWithApple,
            onEnroll: _openEnroll,
            onContinue: heroLecture == null || !_isActive
                ? null
                : () => _watchLecture(heroLecture),
            continueLabel: heroLabel,
          ),
        ),
        const SizedBox(height: 14),
        // The lesson/duration numbers as their own glass tiles -- the most
        // scannable facts about a course, so they get the most visual weight.
        FadeSlideIn(
          delayMs: 100,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _StatTile(
                    icon: ArcIcon.lessons,
                    value: '${_lectures.length}',
                    label: _t('lessons_label'),
                    color: AppColors.red,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    icon: ArcIcon.review,
                    value: '${_files.length}',
                    label: _t('files_label'),
                    color: const Color(0xFFE0A030),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    icon: ArcIcon.clock,
                    value: durationLabel ?? '—',
                    label: _t('duration_label'),
                    color: AppColors.teal,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    icon: ArcIcon.play,
                    value: '$freeCount',
                    label: _t('feature_free_preview'),
                    color: AppColors.byline,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        // Only two tabs: Curriculum (shown first) and Files.
        _Tabs(
          labels: [
            _t('curriculum'),
            _files.isEmpty
                ? _t('tab_files')
                : '${_t('tab_files')} (${_files.length})',
          ],
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 14),
        if (_tab == 1 && _files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(_t('no_course_files'),
                  style: AppFonts.body(size: 14, color: AppColors.muted)),
            ),
          )
        else if (_tab == 1)
          CourseFilesTab(
            files: _files,
            lectures: [
              for (final l in _lectures)
                (id: l.id, title: l.localizedTitle(AppStrings.instance.isAr)),
            ],
            unlocked: _isActive,
            onLocked: _openEnroll,
            groupKeys: {
              for (final l in _lectures)
                l.id: _fileGroupKeys.putIfAbsent(l.id, () => GlobalKey()),
            },
          )
        else
          ..._buildCurriculum(),
      ],
    );
  }

  List<Widget> _buildCurriculum() {
    if (_lectures.isEmpty) {
      return [
        GlassCard(
          padding: const EdgeInsets.all(20),
          child: Text(_t('no_lectures'),
              textAlign: TextAlign.center,
              style: AppFonts.body(color: AppColors.muted)),
        ),
      ];
    }
    return [
      _CurriculumCard(
        lectures: _orderedLectures(),
        isActive: _isActive,
        completedIds: _completedLectureIds,
        progressByLecture: _progressByLecture,
        continueWatchingId: _continueWatchingId,
        onWatch: _watchLecture,
        files: _files,
        onOpenFiles: _openFiles,
      ),
    ];
  }

  // The in-progress lecture (if any) is pulled to the top, same as the
  // "continue watching" pattern on the website's course page. Numbering
  // stays tied to the real order (see _CurriculumCard).
  List<Lecture> _orderedLectures() {
    if (_continueWatchingId == null) return _lectures;
    final match = _lectures.where((l) => l.id == _continueWatchingId);
    if (match.isEmpty) return _lectures;
    return [
      match.first,
      ..._lectures.where((l) => l.id != _continueWatchingId)
    ];
  }
}

/// Price + Enroll, or -- once enrolled -- a status strip with a Continue
/// button (active) or the approval note (pending).
class _EnrollPanel extends StatelessWidget {
  final Course course;
  final String? status;
  final bool purchasesOn;
  final bool appleIap;
  final String? applePrice;
  final bool buyingApple;
  final VoidCallback onBuyApple;
  final VoidCallback onEnroll;
  final VoidCallback? onContinue;
  final String? continueLabel;
  const _EnrollPanel({
    required this.course,
    required this.status,
    required this.purchasesOn,
    required this.appleIap,
    required this.applePrice,
    required this.buyingApple,
    required this.onBuyApple,
    required this.onEnroll,
    required this.onContinue,
    required this.continueLabel,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final Widget content;
    if (status == 'active') {
      content = Row(children: [
        Icon(Icons.verified_rounded, color: AppColors.teal, size: 24),
        const SizedBox(width: 10),
        Expanded(
          child: Text(t('status_enrolled'),
              style: AppFonts.body(
                  size: 14.5, weight: FontWeight.w700, color: AppColors.teal)),
        ),
        if (onContinue != null)
          SizedBox(
            width: 150,
            child: ElevatedButton.icon(
              onPressed: onContinue,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(continueLabel ?? t('continue_watching'),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ]);
    } else if (status == 'pending') {
      content = Row(children: [
        Icon(Icons.hourglass_top_rounded, color: AppColors.teal, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(t('pending_note'),
              style: AppFonts.body(size: 13.5, color: AppColors.muted)),
        ),
      ]);
    } else if (!course.isFree && !purchasesOn) {
      // No outside buying in the apps: Android shows the course locked,
      // iPhone sells it with Apple In-App Purchase (no website link, 3.1.1).
      final locked = Row(children: [
        Icon(Icons.lock_outline_rounded, color: AppColors.muted, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(t('course_subscribers_only'),
              style: AppFonts.body(size: 13.5, color: AppColors.muted)),
        ),
      ]);
      // iPhone: Apple In-App Purchase at Apple's price (every country). The
      // button shows even if Apple's price hasn't loaded yet; tapping it
      // loads the product again.
      content = !appleIap
          ? locked
          : Row(children: [
              Expanded(
                child: applePrice == null
                    ? locked
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(t('price'),
                              style: AppFonts.body(
                                  size: 12, color: AppColors.muted)),
                          const SizedBox(height: 2),
                          Text(applePrice!,
                              textDirection: TextDirection.ltr,
                              style: AppFonts.code(
                                  size: 22,
                                  weight: FontWeight.w700,
                                  color: AppColors.red)),
                        ],
                      ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 170,
                child: GlassPayButton(
                  label: t('buy_course'),
                  icon: Icons.shopping_bag_outlined,
                  loading: buyingApple,
                  onPressed: buyingApple ? null : onBuyApple,
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
                          size: 24,
                          weight: FontWeight.w800,
                          color: AppColors.teal))
                  : Text(Money.text(course.price, fallback: ''),
                      style: AppFonts.code(
                          size: 22,
                          weight: FontWeight.w700,
                          color: AppColors.red)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Sized to its label (the theme's buttons are full-width by default).
        ElevatedButton(
          onPressed: onEnroll,
          style: ElevatedButton.styleFrom(
              minimumSize: const Size(150, 48),
              padding: const EdgeInsets.symmetric(horizontal: 18)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(course.isFree ? t('enroll_free') : t('enroll'), maxLines: 1),
              const SizedBox(width: 8),
              const ArcIconView(ArcIcon.chevron,
                  size: 18, color: Colors.white, stroke: 2.2),
            ],
          ),
        ),
      ]);
    }
    return GlassCard(
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(18),
      child: content,
    );
  }
}

class _StatTile extends StatelessWidget {
  final ArcIcon icon;
  final String value;
  final String label;
  final Color color;
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.16),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Center(
                child: ArcIconView(icon, color: color, size: 21, active: true)),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                maxLines: 1,
                style: AppFonts.body(size: 16, weight: FontWeight.w800)),
          ),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 11, color: AppColors.muted)),
        ],
      ),
    );
  }
}

/// Glass underline tabs (Curriculum / Files).
class _Tabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  const _Tabs(
      {required this.labels, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(4),
      borderRadius: BorderRadius.circular(16),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                child: InkWell(
                  onTap: () => onSelect(i),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: i == selected
                          ? AppColors.red.withValues(alpha: 0.16)
                          : Colors.transparent,
                    ),
                    child: Text(labels[i],
                        style: AppFonts.body(
                            size: 14,
                            weight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: i == selected
                                ? AppColors.red
                                : AppColors.muted)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rounded hero image with the course tag and a play affordance (continue /
/// start / preview) when there's something the viewer can watch.
class _CourseHero extends StatelessWidget {
  final String? tag;
  final String? thumbnailUrl;
  final String? playLabel;
  final VoidCallback? onPlay;
  const _CourseHero({this.tag, this.thumbnailUrl, this.playLabel, this.onPlay});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(22),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CourseThumb(url: thumbnailUrl, radius: 0),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.4, 1],
                  colors: [Colors.transparent, Color(0xAA120F0C)],
                ),
              ),
            ),
            if (tag != null && tag!.isNotEmpty)
              PositionedDirectional(
                top: 14,
                start: 14,
                child:
                    GlassChip(label: tag!, icon: ArcIcon.award, onImage: true),
              ),
            if (onPlay != null)
              Center(
                child: Semantics(
                  button: true,
                  label: playLabel,
                  child: GestureDetector(
                    onTap: onPlay,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 66,
                          height: 66,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.92),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6)),
                            ],
                          ),
                          child: Icon(Icons.play_arrow_rounded,
                              color: AppColors.red, size: 38),
                        ),
                        if (playLabel != null) ...[
                          const SizedBox(height: 10),
                          GlassChip(label: playLabel!, onImage: true),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Curriculum list grouped inside one glass card with dividers.
class _CurriculumCard extends StatelessWidget {
  final List<Lecture> lectures;
  final bool isActive;
  final Set<String> completedIds;
  final Map<String, Map<String, int>> progressByLecture;
  final String? continueWatchingId;
  final void Function(Lecture) onWatch;
  final List<Map<String, dynamic>> files;
  final void Function(String lectureId) onOpenFiles;
  const _CurriculumCard({
    required this.lectures,
    required this.isActive,
    required this.completedIds,
    required this.progressByLecture,
    required this.continueWatchingId,
    required this.onWatch,
    required this.files,
    required this.onOpenFiles,
  });

  @override
  Widget build(BuildContext context) {
    // Number by real order, not display order -- the continue-watching
    // lecture is pulled to the top but keeps its own episode number.
    final sorted = [...lectures]
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    final numberOf = {
      for (var i = 0; i < sorted.length; i++) sorted[i].id: i + 1
    };
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < lectures.length; i++) ...[
            if (i > 0) Divider(height: 1, color: AppColors.line),
            _LectureRow(
              index: numberOf[lectures[i].id] ?? i + 1,
              lecture: lectures[i],
              unlocked: lectures[i].isFree || isActive,
              completed: completedIds.contains(lectures[i].id),
              progress: progressByLecture[lectures[i].id],
              isContinueWatching: lectures[i].id == continueWatchingId,
              onWatch: () => onWatch(lectures[i]),
              fileCount:
                  files.where((f) => f['lecture_id'] == lectures[i].id).length,
              onOpenFiles: () => onOpenFiles(lectures[i].id),
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
  final int fileCount;
  final VoidCallback onOpenFiles;
  const _LectureRow({
    required this.index,
    required this.lecture,
    required this.unlocked,
    required this.completed,
    required this.progress,
    required this.isContinueWatching,
    required this.onWatch,
    required this.fileCount,
    required this.onOpenFiles,
  });

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final pct = progress == null
        ? null
        : (progress!['position']! / progress!['duration']!).clamp(0.0, 1.0);
    final dur = LearningService.formatDuration(lecture.durationSeconds ?? 0);

    Widget leading;
    if (completed) {
      leading =
          Icon(Icons.check_circle_rounded, size: 24, color: AppColors.teal);
    } else if (!unlocked) {
      leading =
          Icon(Icons.lock_outline_rounded, size: 20, color: AppColors.muted2);
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
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isContinueWatching
                        ? AppColors.red.withValues(alpha: 0.14)
                        : AppColors.glassBg,
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: leading,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lecture.localizedTitle(ar),
                        style: AppFonts.body(
                            size: 14.5,
                            weight: FontWeight.w600,
                            color: unlocked ? AppColors.text : AppColors.muted),
                      ),
                      const SizedBox(height: 3),
                      Row(children: [
                        if (dur != null) ...[
                          Icon(Icons.schedule_rounded,
                              size: 12, color: AppColors.muted2),
                          const SizedBox(width: 3),
                          Text(dur,
                              style: AppFonts.body(
                                  size: 11.5, color: AppColors.muted2)),
                          const SizedBox(width: 8),
                        ],
                        if (isContinueWatching)
                          Text(t('continue_watching'),
                              style: AppFonts.body(
                                  size: 11.5,
                                  weight: FontWeight.w700,
                                  color: AppColors.red))
                        else if (lecture.isFree)
                          Text(t('free_tag'),
                              style: AppFonts.body(
                                  size: 11.5,
                                  weight: FontWeight.w700,
                                  color: AppColors.teal)),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (unlocked)
                  Icon(
                    isContinueWatching
                        ? Icons.play_circle_fill_rounded
                        : Icons.play_circle_outline_rounded,
                    color: isContinueWatching ? AppColors.red : AppColors.muted,
                    size: 28,
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
                padding: const EdgeInsetsDirectional.only(start: 48),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 4,
                    backgroundColor: AppColors.line,
                    valueColor: AlwaysStoppedAnimation(AppColors.red),
                  ),
                ),
              ),
            ],
            LectureFilesLink(count: fileCount, onTap: onOpenFiles),
          ],
        ),
      ),
    );
  }
}

/// Free-course enroll confirmation sheet, mirrors openEnroll()'s free branch.
/// Paid courses go through Wayl (online payment). false brings back the
/// manual transfer + screenshot flow below.
const bool kWaylPayments = true;

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

/// Wayl checkout: the server prices the course (and an optional discount
/// code) and returns a Wayl payment page, opened in the browser (Zain Cash,
/// Qi Card, FIB...). When the student comes back, the server confirms the
/// payment with Wayl before the course turns on (api/wayl-webhook.js).
class _WaylEnrollSheet extends StatefulWidget {
  final Course course;
  final VoidCallback onDone;
  const _WaylEnrollSheet({required this.course, required this.onDone});

  @override
  State<_WaylEnrollSheet> createState() => _WaylEnrollSheetState();
}

class _WaylEnrollSheetState extends State<_WaylEnrollSheet>
    with WidgetsBindingObserver {
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  bool _checking = false;
  String? _error;
  String? _reference; // set once the payment page was opened
  bool _paid = false;
  // A code checked with preview_discount_code; only an applied code is sent
  // to checkout, so the student sees the final price before paying.
  bool _applying = false;
  String? _appliedCode;
  int? _finalPrice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeCtrl.dispose();
    super.dispose();
  }

  // Back from the browser: see if the payment went through.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _reference != null && !_paid) {
      _check(quiet: true);
    }
  }

  String _messageFor(String? code) {
    final t = AppStrings.instance.t;
    return switch (code) {
      'code_invalid' => t('err_invalid_discount'),
      'already_enrolled' => t('wayl_already_enrolled'),
      'amount_too_low' => t('wayl_amount_too_low'),
      'payments_not_configured' => t('wayl_unavailable'),
      'payment_provider_error' => t('wayl_provider_error'),
      _ => t('err_generic'),
    };
  }

  /// Same rule as the server (wayl_prepare_payment): percent of the list
  /// price, rounded, never more than the price.
  Future<void> _applyCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    final price = Money.digitsOf(widget.course.price) ?? 0;
    if (code.isEmpty || _applying) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final rows = await SupabaseService.instance.client.rpc(
          'preview_discount_code',
          params: {'p_code': code, 'p_course_id': widget.course.id});
      final list = (rows as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _applying = false;
          _appliedCode = null;
          _finalPrice = null;
          _error = AppStrings.instance.t('err_invalid_discount');
        });
        return;
      }
      final value = (list.first['discount_value'] as num).toDouble();
      final off = list.first['discount_type'] == 'percent'
          ? (price * value / 100).round()
          : value.round();
      setState(() {
        _applying = false;
        _appliedCode = code;
        _finalPrice = price - (off > price ? price : off);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = ErrorReporter.userMessage(e, page: 'course');
      });
    }
  }

  Future<void> _pay() async {
    final token =
        SupabaseService.instance.client.auth.currentSession?.accessToken;
    if (token == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .post(Uri.parse('$kApiBaseUrl/api/wayl-checkout'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'courseSlug': widget.course.slug,
                if (_appliedCode != null) 'code': _appliedCode,
              }))
          .timeout(const Duration(seconds: 25));
      Map<String, dynamic> body = {};
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {}
      final url = body['url'] as String?;
      if (res.statusCode != 200 || url == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = _messageFor(body['error'] as String?);
        });
        return;
      }
      _reference = body['referenceId'] as String?;
      final opened =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!opened) _error = AppStrings.instance.t('wayl_provider_error');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = NetStatus.isOffline(e)
            ? AppStrings.instance.t('err_offline')
            : AppStrings.instance.t('err_generic');
      });
    }
  }

  Future<void> _check({bool quiet = false}) async {
    final ref = _reference;
    if (ref == null || _checking) return;
    setState(() {
      _checking = true;
      if (!quiet) _error = null;
    });
    try {
      final res = await http
          .get(Uri.parse(
              '$kApiBaseUrl/api/wayl-webhook?ref=${Uri.encodeQueryComponent(ref)}'))
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      final status = body['status'] as String?;
      setState(() {
        _checking = false;
        if (status == 'paid') {
          _paid = true;
        } else if (!quiet) {
          _error = AppStrings.instance
              .t(status == 'failed' ? 'wayl_failed' : 'wayl_pending');
        }
      });
      if (status == 'paid') widget.onDone();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (!quiet) _error = AppStrings.instance.t('wayl_pending');
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
          child: _paid
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline,
                      color: AppColors.teal, size: 44),
                  const SizedBox(height: 12),
                  Text(t('wayl_paid'), style: AppFonts.heading(size: 22)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(t('btn_close'))),
                  const SizedBox(height: 12),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.course.localizedTitle(ar),
                      textAlign: TextAlign.center,
                      style: AppFonts.heading(size: 22)),
                  const SizedBox(height: 6),
                  if (_finalPrice != null) ...[
                    Text(Money.text(widget.course.price, fallback: ''),
                        style: AppFonts.body(size: 14, color: AppColors.muted)
                            .copyWith(decoration: TextDecoration.lineThrough)),
                    Text(Money.iqd(_finalPrice!),
                        style: AppFonts.body(
                            size: 18,
                            weight: FontWeight.w700,
                            color: AppColors.teal)),
                    Text(t('discount_applied'),
                        style: AppFonts.body(size: 12, color: AppColors.teal)),
                  ] else
                    Text(Money.text(widget.course.price, fallback: ''),
                        style: AppFonts.body(
                            size: 18,
                            weight: FontWeight.w700,
                            color: AppColors.teal)),
                  const SizedBox(height: 6),
                  Text(t('wayl_methods'),
                      textAlign: TextAlign.center,
                      style: AppFonts.body(size: 13, color: AppColors.muted)),
                  if (_reference == null) ...[
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _codeCtrl,
                          textCapitalization: TextCapitalization.characters,
                          // Editing the code drops the applied discount.
                          onChanged: (_) {
                            if (_appliedCode != null) {
                              setState(() {
                                _appliedCode = null;
                                _finalPrice = null;
                              });
                            }
                          },
                          decoration: InputDecoration(
                              labelText: t('discount_code_optional')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                          onPressed: _applying || _appliedCode != null
                              ? null
                              : _applyCode,
                          child: _applying
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : Text(t('btn_apply_code'))),
                    ]),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: AppFonts.body(size: 12.5, color: AppColors.red)),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                        onPressed: _loading ? null : _pay,
                        child: Text(_loading
                            ? t('wayl_opening')
                            : (_reference == null
                                ? t('wayl_pay')
                                : t('wayl_pay_again')))),
                  ),
                  if (_reference != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                          onPressed: _checking ? null : () => _check(),
                          child: Text(_checking
                              ? t('wayl_checking')
                              : t('wayl_check'))),
                    ),
                  ],
                  const SizedBox(height: 16),
                ]),
        ),
      ),
    );
  }
}

/// Paid-course enroll sheet: payment method + proof screenshot upload,
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
          if (_hasZain != _hasQi) _method = _hasZain ? 'zain' : 'qi';
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

  bool _applying = false;

  Future<void> _applyDiscount() async {
    if (_applying) return;
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
    setState(() => _applying = true);
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
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/redeem-discount-code'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({'code': code, 'courseId': widget.course.id}),
          )
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic> body = const {};
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {}
      if (res.statusCode >= 500) {
        setState(() => _discountError = t('err_generic'));
        return;
      }
      if (res.statusCode != 200 || body['ok'] != true) {
        setState(() => _discountError =
            res.statusCode == 429 && body['error'] is String
                ? t(body['error'] as String)
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
        _appliedCode = code;
        _discountOk = '${t('total_after_discount')}: ${Money.iqd(discounted)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _discountError = NetStatus.isOffline(e)
          ? t('err_offline')
          : t('err_invalid_discount'));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  void dispose() {
    _discountCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    try {
      final picked = await SafePicker.image(imageQuality: 85);
      if (picked != null && mounted) setState(() => _proof = picked);
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppStrings.instance.t('err_photo_permission'));
      }
    }
  }

  bool get _hasZain => _payZaincashPhone?.trim().isNotEmpty ?? false;
  bool get _hasQi =>
      (_payQiAccountNumber?.trim().isNotEmpty ?? false) ||
      (_payQiQrUrl?.trim().isNotEmpty ?? false);

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.instance.t('copied')),
        duration: const Duration(seconds: 2)));
  }

  bool _savingQr = false;
  String? _appliedCode;

  Future<void> _saveQr() async {
    final t = AppStrings.instance.t;
    final url = _payQiQrUrl;
    if (url == null || _savingQr) return;
    setState(() => _savingQr = true);
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) throw Exception('download failed');
      await Gal.putImageBytes(res.bodyBytes,
          name: 'arc-payment-qr-${DateTime.now().millisecondsSinceEpoch}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
        const ArcIconView(ArcIcon.check, size: 18, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(child: Text(t('qr_saved'))),
      ])));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('qr_save_failed'))));
    } finally {
      if (mounted) setState(() => _savingQr = false);
    }
  }

  Future<void> _submit() async {
    final t = AppStrings.instance.t;
    if (_method == null) {
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
    // Our own name only: picked files can have Arabic or spaced names that
    // storage rejects.
    final ext = _proof!.name.contains('.')
        ? _proof!.name.split('.').last.toLowerCase()
        : 'jpg';
    final fileName = '${user.id}/${DateTime.now().millisecondsSinceEpoch}.$ext';
    var uploaded = false;
    try {
      await sb.storage
          .from('payment-proofs')
          .upload(fileName, File(_proof!.path));
      uploaded = true;
      try {
        // Records the request, the price, and the discount code together;
        // the code is only used up here (add-oct05-fixes.sql).
        await sb.rpc('submit_paid_enrollment', params: {
          'p_course_slug': widget.course.slug,
          'p_method': _method,
          'p_detail': null,
          'p_proof_path': fileName,
          'p_code': _discountApplied ? _appliedCode : null,
        });
      } on PostgrestException catch (e) {
        if (e.code != 'PGRST202') rethrow;
        // Migration not run yet: the old direct insert.
        await sb.from('enrollments').insert({
          'user_id': user.id,
          'course_slug': widget.course.slug,
          'status': 'pending',
          'payment_method': _method,
          'payment_proof_path': fileName,
        });
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _done = true;
      });
      widget.onDone();
    } catch (e) {
      // The request didn't go through: don't leave the screenshot behind.
      if (uploaded) {
        sb.storage.from('payment-proofs').remove([fileName]).ignore();
      }
      if (!mounted) return;
      final code = e is PostgrestException ? e.code : null;
      setState(() {
        _loading = false;
        if (code == 'P0002') {
          // Drop the dead code so the full price shows and they can resend.
          _discountApplied = false;
          _discountedPrice = null;
          _appliedCode = null;
          _discountOk = null;
        }
        _error = code == '23505'
            ? t('err_already_requested')
            : code == 'P0002'
                ? t('err_discount_now_invalid')
                : ErrorReporter.userMessage(e, page: 'enroll_paid');
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
                          style:
                              AppFonts.body(size: 20, weight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Row(children: [
                        Text(t('amount_to_pay'),
                            style: AppFonts.body(
                                size: 13, color: AppColors.muted)),
                        const SizedBox(width: 6),
                        Text(
                            _discountedPrice != null
                                ? Money.iqd(_discountedPrice!)
                                : Money.text(widget.course.price, fallback: ''),
                            style:
                                AppFonts.code(size: 15, color: AppColors.red)),
                      ]),
                      const SizedBox(height: 18),
                      if (_payInfoLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (!_hasZain && !_hasQi)
                        _NoPayInfo(text: t('no_payment_info'))
                      else ...[
                        _StepLabel(n: 1, text: t('step_choose_method')),
                        Row(children: [
                          if (_hasZain)
                            Expanded(
                                child: _PayOption(
                                    label: t('zain_cash'),
                                    sub: t('zain_sub'),
                                    selected: _method == 'zain',
                                    onTap: () =>
                                        setState(() => _method = 'zain'))),
                          if (_hasZain && _hasQi) const SizedBox(width: 10),
                          if (_hasQi)
                            Expanded(
                                child: _PayOption(
                                    label: t('qi_card'),
                                    sub: t('qi_sub'),
                                    selected: _method == 'qi',
                                    onTap: () =>
                                        setState(() => _method = 'qi'))),
                        ]),
                        if (_method != null) ...[
                          const SizedBox(height: 18),
                          _StepLabel(n: 2, text: t('step_send_to')),
                          _SendToCard(
                            label: _method == 'zain'
                                ? t('label_zaincash_phone')
                                : t('label_qi_account'),
                            number: _method == 'zain'
                                ? _payZaincashPhone
                                : _payQiAccountNumber,
                            qrUrl: _method == 'qi' ? _payQiQrUrl : null,
                            savingQr: _savingQr,
                            onCopy: _copy,
                            onSaveQr: _saveQr,
                          ),
                        ],
                        const SizedBox(height: 18),
                        _StepLabel(
                            n: _method == null ? 2 : 3,
                            text: t('step_confirm')),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _discountCtrl,
                              enabled: !_discountApplied,
                              decoration: InputDecoration(
                                  labelText: t('discount_code')),
                              textCapitalization: TextCapitalization.characters,
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                              onPressed:
                                  _discountApplied ? null : _applyDiscount,
                              child: Text(t('apply'))),
                        ]),
                        if (_discountError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(_discountError!,
                                style: AppFonts.body(
                                    size: 12, color: AppColors.error)),
                          ),
                        if (_discountOk != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(_discountOk!,
                                style: AppFonts.body(
                                    size: 12, color: AppColors.teal)),
                          ),
                        const SizedBox(height: 12),
                        FilePickBox(
                          file: _proof,
                          emptyLabel: t('payment_screenshot'),
                          height: 220,
                          onPick: _pickProof,
                          onRemove: () => setState(() => _proof = null),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(_error!,
                              style: AppFonts.body(
                                  size: 12.5, color: AppColors.error)),
                        ],
                        const SizedBox(height: 18),
                        ElevatedButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text(t('confirm_payment'))),
                      ],
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

/// "01  Choose a payment method" -- numbered step label in the checkout.
class _StepLabel extends StatelessWidget {
  final int n;
  final String text;
  const _StepLabel({required this.n, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: AppColors.red.withValues(alpha: 0.14),
            border: Border.all(color: AppColors.red.withValues(alpha: 0.4)),
          ),
          child: Text(n.toString().padLeft(2, '0'),
              style: AppFonts.code(size: 11.5, color: AppColors.red)),
        ),
        const SizedBox(width: 10),
        Text(text, style: AppFonts.body(size: 14.5, weight: FontWeight.w700)),
      ]),
    );
  }
}

/// Where to send the money: the number with a copy button, and the Qi Card
/// QR with a save-to-gallery button when there is one.
class _SendToCard extends StatelessWidget {
  final String label;
  final String? number;
  final String? qrUrl;
  final bool savingQr;
  final void Function(String) onCopy;
  final VoidCallback onSaveQr;
  const _SendToCard({
    required this.label,
    required this.number,
    required this.qrUrl,
    required this.savingQr,
    required this.onCopy,
    required this.onSaveQr,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final hasNumber = number?.trim().isNotEmpty ?? false;
    final hasQr = qrUrl?.trim().isNotEmpty ?? false;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppColors.teal.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.teal.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasNumber) ...[
            Text(label, style: AppFonts.body(size: 12, color: AppColors.muted)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(number!.trim(),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.start,
                    style: AppFonts.code(size: 19, color: AppColors.text)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => onCopy(number!.trim()),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  backgroundColor: AppColors.teal,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const ArcIconView(ArcIcon.copy,
                      size: 17, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(t('btn_copy')),
                ]),
              ),
            ]),
          ],
          if (hasQr) ...[
            if (hasNumber) const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 6)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(qrUrl!,
                      width: 190, height: 190, fit: BoxFit.contain),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Gradient pill: the one "fun" control in the sheet.
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: const LinearGradient(
                      colors: [Color(0xFFE8622C), Color(0xFFF2B544)]),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFFE8622C).withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 5)),
                  ],
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: savingQr ? null : onSaveQr,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 11),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (savingQr)
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF2A1406)))
                        else
                          const ArcIconView(ArcIcon.download,
                              size: 19, color: Color(0xFF2A1406), stroke: 2.2),
                        const SizedBox(width: 8),
                        Text(t('btn_save_qr'),
                            style: AppFonts.body(
                                size: 14,
                                weight: FontWeight.w700,
                                color: const Color(0xFF2A1406))),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoPayInfo extends StatelessWidget {
  final String text;
  const _NoPayInfo({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFFE0A030).withValues(alpha: 0.12),
        border:
            Border.all(color: const Color(0xFFE0A030).withValues(alpha: 0.45)),
      ),
      child: Row(children: [
        const ArcIconView(ArcIcon.warning,
            size: 22, color: Color(0xFFE0A030), active: true),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: AppFonts.body(size: 13))),
      ]),
    );
  }
}

/// Shown on the course page after a payment was rejected, with the reason.
class _RejectedBanner extends StatelessWidget {
  final String reason;
  const _RejectedBanner({required this.reason});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppColors.error.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ArcIconView(ArcIcon.alert,
              size: 22, color: AppColors.error, active: true),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('payment_rejected_title'),
                    style: AppFonts.body(
                        size: 14,
                        weight: FontWeight.w700,
                        color: AppColors.error)),
                const SizedBox(height: 4),
                Text(reason, style: AppFonts.body(size: 13)),
                const SizedBox(height: 6),
                Text(t('payment_rejected_retry'),
                    style: AppFonts.body(size: 12, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
