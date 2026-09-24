import 'dart:ui';

import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/brand_title.dart';
import '../widgets/course_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/skeleton_card.dart';
import 'auth_screen.dart';
import 'course_detail_screen.dart';
import 'my_courses_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'verify_phone_screen.dart';

/// Port of loadCatalogue() in index.html.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  List<Course>? _courses;
  String? _error;
  // Only is_teacher is needed here now, to decide whether Settings shows the
  // Payment info entry. is_admin is read by ProfileScreen itself, which is
  // the only place a dashboard is reachable from.
  bool _isTeacher = false;
  // null = not checked yet (or logged out) -- only an explicit false blocks
  // the app, so this never flashes the block screen while still loading.
  bool? _phoneVerified;

  // "Continue learning" row: courses with an active enrollment and at least
  // one completed-but-not-all lecture. Null while loading/logged out (the
  // section just doesn't render) vs empty (also doesn't render) -- there's
  // no error state shown for this since it's a convenience row, not core
  // catalogue data.
  List<_ContinueLearningItem>? _continueLearning;

  // Instagram-style swipe across Home / My Courses / Settings. Profile stays
  // an ordinary tap (it pushes a full route, which doesn't fit as a
  // swipeable page here).
  final _pageController = PageController();
  final _myCoursesKey = GlobalKey<MyCoursesScreenState>();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAdminFlag();
    _loadContinueLearning();
    AppStrings.instance.addListener(_onLangChange);
    SupabaseService.instance.addListener(_onAuthChangeAndAdmin);
    AppTheme.instance.addListener(_onThemeChange);
  }

  Future<void> _loadAdminFlag() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      if (mounted)
        setState(() {
          _isTeacher = false;
          _phoneVerified = null;
        });
      return;
    }
    try {
      final prof = await SupabaseService.instance.client
          .from('profiles')
          .select('is_teacher, phone_verified')
          .eq('id', user.id)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _isTeacher = prof?['is_teacher'] == true;
          _phoneVerified = prof?['phone_verified'] == true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isTeacher = false);
    }
  }

  Future<void> _openVerifyPhone() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const VerifyPhoneScreen()));
    _loadAdminFlag();
  }

  @override
  void dispose() {
    AppStrings.instance.removeListener(_onLangChange);
    SupabaseService.instance.removeListener(_onAuthChangeAndAdmin);
    AppTheme.instance.removeListener(_onThemeChange);
    _pageController.dispose();
    super.dispose();
  }

  void _onLangChange() => setState(() {});
  void _onAuthChangeAndAdmin() {
    setState(() {});
    _loadAdminFlag();
    _loadContinueLearning();
    // The My Courses tab loads its own data once in initState and PageView
    // keeps it alive across swipes, so a login/logout that happens while
    // sitting on the Home tab would otherwise leave it showing stale data.
    _myCoursesKey.currentState?.reload();
  }

  Future<void> _loadContinueLearning() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _continueLearning = []);
      return;
    }
    try {
      final sb = SupabaseService.instance.client;
      final enrollRows = await sb
          .from('enrollments')
          .select('course_slug')
          .eq('user_id', user.id)
          .eq('status', 'active');
      final slugs =
          (enrollRows as List).map((r) => r['course_slug'] as String).toList();
      if (slugs.isEmpty) {
        if (mounted) setState(() => _continueLearning = []);
        return;
      }

      final courseRows = await sb
          .from('courses')
          .select('id, slug, title, thumbnail_url, teacher_name')
          .inFilter('slug', slugs);
      final courses = (courseRows as List).cast<Map<String, dynamic>>();
      if (courses.isEmpty) {
        if (mounted) setState(() => _continueLearning = []);
        return;
      }
      final courseIds = courses.map((c) => c['id'] as String).toList();

      final lectureRows = await sb
          .from('lectures')
          .select('id, course_id')
          .inFilter('course_id', courseIds);
      final lectures = (lectureRows as List).cast<Map<String, dynamic>>();
      if (lectures.isEmpty) {
        if (mounted) setState(() => _continueLearning = []);
        return;
      }
      final lectureCourseId = {
        for (final l in lectures) l['id'] as String: l['course_id'] as String
      };

      final progressRows = await sb
          .from('lesson_progress')
          .select('lecture_id, completed, updated_at')
          .eq('user_id', user.id)
          .inFilter('lecture_id', lectureCourseId.keys.toList());
      final progress = (progressRows as List).cast<Map<String, dynamic>>();

      final totalByCourse = <String, int>{};
      for (final l in lectures) {
        final cid = l['course_id'] as String;
        totalByCourse[cid] = (totalByCourse[cid] ?? 0) + 1;
      }
      final completedByCourse = <String, int>{};
      final lastActiveByCourse = <String, DateTime>{};
      for (final p in progress) {
        final courseId = lectureCourseId[p['lecture_id'] as String];
        if (courseId == null) continue;
        if (p['completed'] == true) {
          completedByCourse[courseId] = (completedByCourse[courseId] ?? 0) + 1;
        }
        final updated = DateTime.tryParse(p['updated_at'] as String? ?? '');
        if (updated != null) {
          final prev = lastActiveByCourse[courseId];
          if (prev == null || updated.isAfter(prev)) {
            lastActiveByCourse[courseId] = updated;
          }
        }
      }

      final items = <_ContinueLearningItem>[];
      for (final c in courses) {
        final id = c['id'] as String;
        final total = totalByCourse[id] ?? 0;
        if (total == 0) continue;
        final completed = completedByCourse[id] ?? 0;
        final percent = completed / total;
        // Only genuinely "in progress" courses -- 0% has nothing to resume,
        // 100% is done, not something to continue.
        if (percent <= 0 || percent >= 1) continue;
        items.add(_ContinueLearningItem(
          slug: c['slug'] as String,
          title: c['title'] as String? ?? '',
          teacher: c['teacher_name'] as String?,
          thumbnailUrl: c['thumbnail_url'] as String?,
          percent: percent,
          lastActive: lastActiveByCourse[id],
        ));
      }
      items.sort((a, b) =>
          (b.lastActive ?? DateTime(0)).compareTo(a.lastActive ?? DateTime(0)));
      if (mounted) {
        setState(() => _continueLearning = items.take(8).toList());
      }
    } catch (_) {
      // Best-effort -- a convenience row on Home, never worth its own error
      // state or blocking the rest of the page.
      if (mounted) setState(() => _continueLearning = []);
    }
  }

  // AppColors' fields are mutable but plain — nothing subscribes to them on
  // its own. Theme.of(context)-based widgets (Scaffold's background, etc.)
  // pick up a new ThemeData automatically via InheritedWidget, but anything
  // reading AppColors.xxx directly (which is most of this app) only shows
  // the new value once ITS OWN build() re-runs — hence this listener, same
  // as the language one just above.
  void _onThemeChange() => setState(() {});

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .select('*')
          .eq('status', 'published')
          // Every course row shares the exact same created_at (bulk-seeded
          // together), so that was never a real sort key — order_index is
          // the actual, deterministic display order.
          .order('order_index', ascending: true);
      if (!mounted) return;
      setState(() {
        _courses = (rows as List)
            .map((r) => Course.fromJson(r as Map<String, dynamic>))
            .toList();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'catalogue'));
    }
  }

  void _openAuth() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  void _goToPage(int index) {
    _pageController.animateToPage(index,
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  // A soft scale + fade + frosted blur riding the page controller's own
  // scroll offset. The blur peaks mid-swipe and clears again once a page
  // settles into (or fully out of) view, so a tab change reads like the
  // page is sliding behind a pane of frosted glass rather than PageView's
  // default flat slide.
  Widget _swipeTransition(int index, Widget child) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        double page = _currentPage.toDouble();
        if (_pageController.hasClients && _pageController.page != null) {
          page = _pageController.page!;
        }
        final delta = (page - index).clamp(-1.0, 1.0).abs();
        final scale = 1 - (delta * 0.08);
        final opacity = (1 - (delta * 0.35)).clamp(0.0, 1.0);
        // Triangular curve: 0 at delta=0 or 1, peaking at delta=0.5.
        final blurSigma = (1 - (delta - 0.5).abs() * 2).clamp(0.0, 1.0) * 5;
        return Opacity(
          opacity: opacity,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final loggedIn = SupabaseService.instance.isLoggedIn;

    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: const BrandTitle()),
        body: kPhoneOtpEnabled && loggedIn && _phoneVerified == false
            ? _buildVerifyPhoneGate(t)
            : PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _swipeTransition(0,
                      RefreshIndicator(
                          onRefresh: () =>
                              Future.wait([_load(), _loadContinueLearning()]),
                          child: _buildBody(t))),
                  _swipeTransition(
                      1,
                      MyCoursesScreen(
                          key: _myCoursesKey, onBrowse: () => _goToPage(0))),
                  _swipeTransition(2, const ProfileScreen()),
                  _swipeTransition(
                      3,
                      SettingsScreen(
                          loggedIn: loggedIn, isTeacher: _isTeacher)),
                ],
              ),
        bottomNavigationBar:
            kPhoneOtpEnabled && loggedIn && _phoneVerified == false
                ? null
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: FloatingBottomNav(items: _navItems(t, loggedIn)),
                  ),
      ),
    );
  }

  Widget _buildVerifyPhoneGate(String Function(String) t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phone_android_outlined,
                size: 42, color: AppColors.muted),
            const SizedBox(height: 14),
            Text(t('verify_phone_title'),
                style: AppFonts.heading(size: 20), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(t('verify_phone_sub'),
                style: AppFonts.body(size: 13, color: AppColors.muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            ElevatedButton(
                onPressed: _openVerifyPhone, child: Text(t('btn_send_code'))),
          ],
        ),
      ),
    );
  }

  List<BottomNavItem> _navItems(String Function(String) t, bool loggedIn) {
    return [
      BottomNavItem(
        icon: Icons.home_rounded,
        tooltip: t('nav_home'),
        active: _currentPage == 0,
        onTap: () => _goToPage(0),
      ),
      BottomNavItem(
        icon: Icons.school_outlined,
        tooltip: t('my_courses'),
        active: _currentPage == 1,
        onTap: () {
          if (loggedIn) {
            _goToPage(1);
          } else {
            _openAuth();
          }
        },
      ),
      BottomNavItem(
        icon: Icons.person_outline,
        tooltip: t('nav_profile'),
        active: _currentPage == 2,
        // A swipeable page now, same as the others, so the bottom nav stays
        // fixed instead of Profile opening what looked like a separate
        // screen. The teacher/admin dashboards are reached from inside it,
        // and only by the accounts that actually have the flag, so they're
        // invisible to regular students.
        onTap: () {
          if (loggedIn) {
            _goToPage(2);
          } else {
            _openAuth();
          }
        },
      ),
      BottomNavItem(
        icon: Icons.settings_outlined,
        tooltip: t('settings'),
        active: _currentPage == 3,
        onTap: () => _goToPage(3),
      ),
    ];
  }

  Widget _buildBody(String Function(String) t) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: TextStyle(color: AppColors.muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_courses == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          const FadeSlideIn(
              delayMs: 0, child: SizedBox(height: 280, child: SkeletonCard())),
          const SizedBox(height: 24),
          for (var i = 0; i < 4; i++) ...[
            FadeSlideIn(
                delayMs: 60 + i * 45,
                child: const SizedBox(height: 96, child: SkeletonCard())),
            const SizedBox(height: 10),
          ],
        ],
      );
    }
    if (_courses!.isEmpty) {
      return Center(
          child:
              Text(t('no_courses'), style: TextStyle(color: AppColors.muted)));
    }

    void open(Course c) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CourseDetailScreen(slug: c.slug)),
        );

    final featured = _courses!.first;
    final rest = _courses!.skip(1).toList();

    // Featured course on top, then a compact list. Bottom padding clears
    // the floating nav pill so the last row is never hidden behind it.
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        if (_continueLearning != null && _continueLearning!.isNotEmpty) ...[
          FadeSlideIn(
            delayMs: 0,
            child: _SectionHeader(title: t('home_continue_learning')),
          ),
          const SizedBox(height: 10),
          FadeSlideIn(
            delayMs: 30,
            child: SizedBox(
              height: 172,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: _continueLearning!.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final item = _continueLearning![i];
                  return ContinueLearningCard(
                    title: item.title,
                    teacher: item.teacher,
                    thumbnailUrl: item.thumbnailUrl,
                    percent: item.percent,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            CourseDetailScreen(slug: item.slug))),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 26),
        ],
        FadeSlideIn(
          delayMs: 0,
          child: _SectionHeader(title: t('home_featured')),
        ),
        const SizedBox(height: 10),
        FadeSlideIn(
          delayMs: 40,
          child:
              FeaturedCourseCard(course: featured, onTap: () => open(featured)),
        ),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: 26),
          FadeSlideIn(
            delayMs: 100,
            child: _SectionHeader(
                title: t('home_all_courses'), count: _courses!.length),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < rest.length; i++) ...[
            FadeSlideIn(
              delayMs: 140 + (i % 8) * 45,
              child: CompactCourseCard(
                  course: rest[i], onTap: () => open(rest[i])),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  const _SectionHeader({required this.title, this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: AppFonts.body(size: 17, weight: FontWeight.w700)),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.panel2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('$count',
                style: AppFonts.code(size: 11.5, color: AppColors.muted)),
          ),
        ],
      ],
    );
  }
}

class _ContinueLearningItem {
  final String slug;
  final String title;
  final String? teacher;
  final String? thumbnailUrl;
  final double percent;
  final DateTime? lastActive;
  const _ContinueLearningItem({
    required this.slug,
    required this.title,
    required this.teacher,
    required this.thumbnailUrl,
    required this.percent,
    required this.lastActive,
  });
}
