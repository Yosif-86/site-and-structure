import 'dart:ui';

import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/error_reporter.dart';
import '../services/learning_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/brand_title.dart';
import '../widgets/course_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/skeleton_card.dart';
import 'auth_screen.dart';
import 'course_detail_screen.dart';
import 'explore_screen.dart';
import 'my_courses_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'verify_phone_screen.dart';

/// App shell: a fixed glass top bar (logo + avatar), the swipeable tabs
/// (Home / My Courses / Profile / Settings), and the floating glass bottom
/// bar whose center button opens Explore. Home itself is built here.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  List<Course>? _courses;
  Map<String, CourseStats> _stats = {};
  String? _error;
  // Only is_teacher is needed here, to decide whether Settings shows the
  // Payment info entry. is_admin is read by ProfileScreen itself, which is
  // the only place a dashboard is reachable from.
  bool _isTeacher = false;
  // null = not checked yet (or logged out) -- only an explicit false blocks
  // the app, so this never flashes the block screen while still loading.
  bool? _phoneVerified;
  String? _fullName;
  String? _avatarUrl;

  // Signed-in user's enrollments with progress; drives the progress card
  // and Continue learning. Null while loading, empty when logged out.
  List<MyCourseProgress>? _myLearning;

  final _pageController = PageController();
  final _myCoursesKey = GlobalKey<MyCoursesScreenState>();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadProfile();
    _loadMyLearning();
    AppStrings.instance.addListener(_onLangChange);
    SupabaseService.instance.addListener(_onAuthChange);
    AppTheme.instance.addListener(_onThemeChange);
  }

  @override
  void dispose() {
    AppStrings.instance.removeListener(_onLangChange);
    SupabaseService.instance.removeListener(_onAuthChange);
    AppTheme.instance.removeListener(_onThemeChange);
    _pageController.dispose();
    super.dispose();
  }

  void _onLangChange() => setState(() {});

  void _onAuthChange() {
    setState(() {});
    _loadProfile();
    _loadMyLearning();
    // The My Courses tab loads its own data once in initState and PageView
    // keeps it alive across swipes, so a login/logout that happens while
    // sitting on the Home tab would otherwise leave it showing stale data.
    _myCoursesKey.currentState?.reload();
  }

  // AppColors' fields are mutable but plain -- nothing subscribes to them on
  // its own. Anything reading AppColors.xxx directly (most of this app) only
  // shows the new value once ITS OWN build() re-runs -- hence this listener.
  void _onThemeChange() => setState(() {});

  Future<void> _loadProfile() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _isTeacher = false;
          _phoneVerified = null;
          _fullName = null;
          _avatarUrl = null;
        });
      }
      return;
    }
    try {
      final prof = await SupabaseService.instance.client
          .from('profiles')
          .select(
              'is_teacher, phone_verified, full_name, avatar_url, teacher_photo_url')
          .eq('id', user.id)
          .maybeSingle();
      if (!mounted) return;
      final isTeacher = prof?['is_teacher'] == true;
      setState(() {
        _isTeacher = isTeacher;
        _phoneVerified = prof?['phone_verified'] == true;
        _fullName = prof?['full_name'] as String?;
        // Teachers edit their public teacher photo, not avatar_url -- same
        // split ProfileScreen uses.
        final photoKey = isTeacher ? 'teacher_photo_url' : 'avatar_url';
        _avatarUrl = prof?[photoKey] as String?;
      });
    } catch (_) {
      if (mounted) setState(() => _isTeacher = false);
    }
  }

  Future<void> _openVerifyPhone() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const VerifyPhoneScreen()));
    _loadProfile();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .select('*')
          .eq('status', 'published')
          // Every course row shares the exact same created_at (bulk-seeded
          // together), so that was never a real sort key -- order_index is
          // the actual, deterministic display order.
          .order('order_index', ascending: true);
      final courses = (rows as List)
          .map((r) => Course.fromJson(r as Map<String, dynamic>))
          .toList();
      Map<String, CourseStats> stats = {};
      try {
        stats = await LearningService.fetchCourseStats(
            courses.map((c) => c.id).toList());
      } catch (_) {
        // Lesson/duration chips are decoration -- never fail the catalogue
        // over them.
      }
      if (!mounted) return;
      setState(() {
        _courses = courses;
        _stats = stats;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'catalogue'));
    }
  }

  Future<void> _loadMyLearning() async {
    try {
      final items = await LearningService.fetchMyLearning();
      if (mounted) setState(() => _myLearning = items);
    } catch (_) {
      // Best-effort -- the progress card and Continue learning are
      // conveniences, never worth an error state that blocks Home.
      if (mounted) setState(() => _myLearning = []);
    }
  }

  Future<void> _refresh() => Future.wait([_load(), _loadMyLearning()]);

  void _openAuth() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  Future<void> _openCourse(String slug) async {
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CourseDetailScreen(slug: slug)));
    // Watching or enrolling changes progress -- refresh on the way back.
    if (mounted) _loadMyLearning();
  }

  void _openExplore() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExploreScreen(
            initialCourses: _courses, initialStats: _stats)));
  }

  void _goToPage(int index) {
    _pageController.animateToPage(index,
        duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  // A soft scale + fade + frosted blur riding the page controller's own
  // scroll offset. The blur peaks mid-swipe and clears again once a page
  // settles, so a tab change reads like the page slides behind a pane of
  // frosted glass rather than PageView's default flat slide. The blur layer
  // is disabled entirely at rest so the settled page's own glass cards keep
  // their real backdrop.
  Widget _swipeTransition(int index, Widget child) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        double page = _currentPage.toDouble();
        if (_pageController.hasClients && _pageController.page != null) {
          page = _pageController.page!;
        }
        final delta = (page - index).clamp(-1.0, 1.0).abs();
        final scale = 1 - (delta * 0.06);
        final opacity = (1 - (delta * 0.35)).clamp(0.0, 1.0);
        // Triangular curve: 0 at delta=0 or 1, peaking at delta=0.5.
        final blurSigma = (1 - (delta - 0.5).abs() * 2).clamp(0.0, 1.0) * 5;
        return Opacity(
          opacity: opacity,
          child: ImageFiltered(
            enabled: blurSigma > 0.05,
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
    final gated = kPhoneOtpEnabled && loggedIn && _phoneVerified == false;

    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
        body: Column(
          children: [
            _TopBar(
              name: _fullName,
              avatarUrl: _avatarUrl,
              loggedIn: loggedIn,
              onAvatarTap: () => loggedIn ? _goToPage(2) : _openAuth(),
            ),
            Expanded(
              child: gated
                  ? _buildVerifyPhoneGate(t)
                  : PageView(
                      controller: _pageController,
                      onPageChanged: (i) => setState(() => _currentPage = i),
                      children: [
                        _swipeTransition(
                            0,
                            RefreshIndicator(
                                onRefresh: _refresh, child: _buildHome(t))),
                        _swipeTransition(
                            1,
                            MyCoursesScreen(
                                key: _myCoursesKey,
                                onBrowse: () => _goToPage(0))),
                        _swipeTransition(
                            2, ProfileScreen(onProfileChanged: _loadProfile)),
                        _swipeTransition(
                            3,
                            SettingsScreen(
                                loggedIn: loggedIn, isTeacher: _isTeacher)),
                      ],
                    ),
            ),
          ],
        ),
        bottomNavigationBar: gated
            ? null
            : FloatingBottomNav(
                items: _navItems(t, loggedIn),
                center: BottomNavItem(
                  icon: Icons.explore_rounded,
                  tooltip: t('nav_explore'),
                  onTap: _openExplore,
                ),
              ),
      ),
    );
  }

  Widget _buildVerifyPhoneGate(String Function(String) t) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_android_outlined,
                  size: 42, color: AppColors.muted),
              const SizedBox(height: 14),
              Text(t('verify_phone_title'),
                  style: AppFonts.heading(size: 20),
                  textAlign: TextAlign.center),
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
      ),
    );
  }

  List<BottomNavItem> _navItems(String Function(String) t, bool loggedIn) {
    return [
      BottomNavItem(
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
        tooltip: t('nav_home'),
        active: _currentPage == 0,
        onTap: () => _goToPage(0),
      ),
      BottomNavItem(
        icon: Icons.school_outlined,
        activeIcon: Icons.school_rounded,
        tooltip: t('my_courses'),
        active: _currentPage == 1,
        onTap: () => loggedIn ? _goToPage(1) : _openAuth(),
      ),
      BottomNavItem(
        icon: Icons.person_outline_rounded,
        activeIcon: Icons.person_rounded,
        tooltip: t('nav_profile'),
        active: _currentPage == 2,
        onTap: () => loggedIn ? _goToPage(2) : _openAuth(),
      ),
      BottomNavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
        tooltip: t('settings'),
        active: _currentPage == 3,
        onTap: () => _goToPage(3),
      ),
    ];
  }

  // ---- Home ----

  Widget _buildHome(String Function(String) t) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 140),
        children: [
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(_error!,
                    style: AppFonts.body(color: AppColors.muted),
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _load, child: Text(t('retry'))),
              ],
            ),
          ),
        ],
      );
    }

    final loggedIn = SupabaseService.instance.isLoggedIn;
    final courses = _courses;
    final learning = _myLearning ?? const <MyCourseProgress>[];
    final active = learning.where((m) => m.isActive && m.totalLectures > 0);
    final continueItems = learning
        .where((m) => m.isInProgress && m.hasStarted)
        .toList()
      ..sort((a, b) => b.lastWatched!.compareTo(a.lastWatched!));

    var delay = 0;
    int next() => delay += 40;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
      children: [
        FadeSlideIn(delayMs: 0, child: _Greeting(name: _fullName, loggedIn: loggedIn)),
        const SizedBox(height: 16),
        if (loggedIn && active.isNotEmpty) ...[
          FadeSlideIn(delayMs: next(), child: _ProgressSummary(items: active.toList())),
          const SizedBox(height: 24),
        ],
        if (continueItems.isNotEmpty) ...[
          FadeSlideIn(
            delayMs: next(),
            child: _SectionHeader(
              title: t('home_continue_learning'),
              actionLabel: t('view_all'),
              onAction: () => _goToPage(1),
            ),
          ),
          const SizedBox(height: 10),
          FadeSlideIn(
            delayMs: next(),
            child: SizedBox(
              height: 238,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: continueItems.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) => ContinueLearningCard(
                  item: continueItems[i],
                  onTap: () => _openCourse(continueItems[i].course.slug),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
        if (courses == null) ...[
          const FadeSlideIn(
              delayMs: 0, child: SizedBox(height: 230, child: SkeletonCard())),
          const SizedBox(height: 14),
          for (var i = 0; i < 3; i++) ...[
            FadeSlideIn(
                delayMs: 60 + i * 45,
                child: const SizedBox(height: 104, child: SkeletonCard())),
            const SizedBox(height: 10),
          ],
        ] else if (courses.isEmpty)
          GlassCard(
            padding: const EdgeInsets.all(24),
            child: Text(t('no_courses'),
                textAlign: TextAlign.center,
                style: AppFonts.body(color: AppColors.muted)),
          )
        else ...[
          FadeSlideIn(
              delayMs: next(),
              child: _SectionHeader(title: t('home_featured'))),
          const SizedBox(height: 10),
          FadeSlideIn(
            delayMs: next(),
            child: FeaturedCourseCard(
              course: courses.first,
              stats: _stats[courses.first.id],
              onTap: () => _openCourse(courses.first.slug),
            ),
          ),
          if (courses.length > 1) ...[
            const SizedBox(height: 24),
            FadeSlideIn(
              delayMs: next(),
              child: _SectionHeader(
                title: t('home_all_courses'),
                count: courses.length,
                actionLabel: t('view_all'),
                onAction: _openExplore,
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 1; i < courses.length; i++) ...[
              FadeSlideIn(
                delayMs: 140 + (i % 8) * 45,
                child: CourseRow(
                  course: courses[i],
                  stats: _stats[courses[i].id],
                  onTap: () => _openCourse(courses[i].slug),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ],
    );
  }
}

/// Fixed top bar across every tab: the brand on one side, the user's avatar
/// on the other (tap to open Profile, or sign in when logged out).
class _TopBar extends StatelessWidget {
  final String? name;
  final String? avatarUrl;
  final bool loggedIn;
  final VoidCallback onAvatarTap;
  const _TopBar({
    required this.name,
    required this.avatarUrl,
    required this.loggedIn,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final initial = (name != null && name!.trim().isNotEmpty)
        ? name!.trim().characters.first.toUpperCase()
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          const BrandTitle(),
          const Spacer(),
          Semantics(
            button: true,
            label: loggedIn ? t('nav_profile') : t('log_in'),
            child: GestureDetector(
              onTap: onAvatarTap,
              child: Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [AppColors.red, AppColors.teal],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: ClipOval(
                  child: ColoredBox(
                    color: AppColors.panel2,
                    child: avatarUrl != null && avatarUrl!.isNotEmpty
                        ? Image.network(avatarUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _AvatarFallback(initial: initial))
                        : _AvatarFallback(initial: initial),
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

class _AvatarFallback extends StatelessWidget {
  final String? initial;
  const _AvatarFallback({required this.initial});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: initial != null
          ? Text(initial!,
              style: AppFonts.body(size: 17, weight: FontWeight.w700))
          : Icon(Icons.person_outline_rounded, color: AppColors.muted, size: 22),
    );
  }
}

/// "صباح الخير / مساء الخير، <first name>" by the device clock (before noon
/// is morning, from noon on is afternoon/evening).
class _Greeting extends StatelessWidget {
  final String? name;
  final bool loggedIn;
  const _Greeting({required this.name, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final morning = DateTime.now().hour < 12;
    final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
    final hello = !loggedIn
        ? t('greeting_guest')
        : '${morning ? t('greeting_morning') : t('greeting_evening')}${first.isNotEmpty ? '، $first' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(hello,
                  style: AppFonts.body(size: 24, weight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Icon(morning ? Icons.wb_sunny_rounded : Icons.nights_stay_rounded,
                color: morning ? const Color(0xFFF2B33D) : AppColors.teal,
                size: 22),
          ],
        ),
        const SizedBox(height: 4),
        Text(loggedIn ? t('greeting_sub') : t('greeting_guest_sub'),
            style: AppFonts.body(size: 13.5, color: AppColors.muted)),
      ],
    );
  }
}

/// Overall progress across the student's active courses, weighted by
/// lecture count so a 30-lecture course counts for more than a 3-lecture one.
class _ProgressSummary extends StatelessWidget {
  final List<MyCourseProgress> items;
  const _ProgressSummary({required this.items});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    var weighted = 0.0;
    var total = 0;
    for (final m in items) {
      weighted += m.progress * m.totalLectures;
      total += m.totalLectures;
    }
    final overall = total == 0 ? 0.0 : weighted / total;
    final pct = (overall * 100).round();
    final inProgress = items.where((m) => m.isInProgress).length;

    return GlassCard(
      padding: const EdgeInsets.all(20),
      borderRadius: BorderRadius.circular(22),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('progress_title'),
                    style: AppFonts.eyebrow(size: 11.5)),
                const SizedBox(height: 8),
                Text('$pct% ${t('progress_complete')}',
                    style: AppFonts.body(size: 26, weight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  '$inProgress ${t('progress_courses_in_progress')}',
                  style: AppFonts.body(size: 12.5, color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: overall,
                    minHeight: 6,
                    backgroundColor: AppColors.line,
                    valueColor: AlwaysStoppedAnimation(AppColors.red),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          ProgressRing(
            value: overall,
            size: 96,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$pct%',
                    style: AppFonts.body(size: 20, weight: FontWeight.w800)),
                Text(t('progress_overall'),
                    style: AppFonts.body(size: 9.5, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _SectionHeader(
      {required this.title, this.count, this.actionLabel, this.onAction});

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
              color: AppColors.glassBg,
              border: Border.all(color: AppColors.glassBorder),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('$count',
                style: AppFonts.code(size: 11.5, color: AppColors.muted)),
          ),
        ],
        const Spacer(),
        if (actionLabel != null && onAction != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 6)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(actionLabel!),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
      ],
    );
  }
}
