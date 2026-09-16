import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/brand_title.dart';
import '../widgets/course_card.dart';
import 'admin_screen.dart';
import 'auth_screen.dart';
import 'course_detail_screen.dart';
import 'my_courses_screen.dart';
import 'teacher_screen.dart';

/// Port of loadCatalogue() in index.html.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  List<Course>? _courses;
  String? _error;
  bool _isAdmin = false;
  bool _isTeacher = false;

  // Instagram-style Home<->My Courses swipe, scoped to just these two tabs
  // (Dashboard/Settings stay as ordinary taps — Instagram itself only makes
  // the Home tab's Feed<->Reels pair swipeable, not every bottom-bar icon).
  final _pageController = PageController();
  final _myCoursesKey = GlobalKey<MyCoursesScreenState>();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAdminFlag();
    AppStrings.instance.addListener(_onLangChange);
    SupabaseService.instance.addListener(_onAuthChangeAndAdmin);
    AppTheme.instance.addListener(_onThemeChange);
  }

  Future<void> _loadAdminFlag() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isAdmin = false);
      return;
    }
    try {
      final prof = await SupabaseService.instance.client.from('profiles').select('is_admin, is_teacher').eq('id', user.id).maybeSingle();
      if (mounted) setState(() { _isAdmin = prof?['is_admin'] == true; _isTeacher = prof?['is_teacher'] == true; });
    } catch (_) {
      if (mounted) setState(() { _isAdmin = false; _isTeacher = false; });
    }
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
    // The My Courses tab loads its own data once in initState and PageView
    // keeps it alive across swipes, so a login/logout that happens while
    // sitting on the Home tab would otherwise leave it showing stale data.
    _myCoursesKey.currentState?.reload();
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
      setState(() {
        _courses = (rows as List).map((r) => Course.fromJson(r as Map<String, dynamic>)).toList();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _openAuth() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  void _goToPage(int index) {
    _pageController.animateToPage(index, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final loggedIn = SupabaseService.instance.isLoggedIn;

    return Directionality(
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: const BrandTitle()),
        body: PageView(
          controller: _pageController,
          // Swiping into My Courses while logged out would just show the
          // "no enrollments" empty state instead of the sign-in prompt the
          // equivalent bottom-bar tap gives — simplest fix is to only allow
          // the swipe once there's an account to show courses for.
          physics: loggedIn ? const PageScrollPhysics() : const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _currentPage = i),
          children: [
            RefreshIndicator(onRefresh: _load, child: _buildBody(t)),
            MyCoursesScreen(key: _myCoursesKey),
          ],
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: FloatingBottomNav(items: _navItems(t, loggedIn)),
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
        icon: _isAdmin ? Icons.admin_panel_settings_outlined : Icons.cast_for_education_outlined,
        tooltip: _isAdmin ? t('nav_admin') : t('teacher_dashboard'),
        onTap: () {
          if (!loggedIn) {
            _openAuth();
          } else if (_isAdmin) {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminScreen()));
          } else if (_isTeacher) {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TeacherScreen()));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('dashboard_unavailable'))));
          }
        },
      ),
      BottomNavItem(
        icon: Icons.settings_outlined,
        tooltip: t('settings'),
        onTap: () => _openSettingsSheet(t, loggedIn),
      ),
    ];
  }

  void _openSettingsSheet(String Function(String) t, bool loggedIn) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(AppTheme.instance.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              title: Text(t('toggle_theme')),
              onTap: () {
                AppTheme.instance.toggle();
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: Icon(loggedIn ? Icons.logout : Icons.login),
              title: Text(loggedIn ? t('log_out') : t('log_in')),
              onTap: () async {
                Navigator.of(ctx).pop();
                if (loggedIn) {
                  await SupabaseService.instance.logout();
                } else {
                  _openAuth();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(String Function(String) t) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: AppColors.muted), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_courses == null) {
      return Center(child: Text(t('loading_courses'), style: TextStyle(color: AppColors.muted)));
    }
    if (_courses!.isEmpty) {
      return Center(child: Text(t('no_courses'), style: TextStyle(color: AppColors.muted)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 380,
        // Tall enough for a card with a cover image (thumbnail + text +
        // price row); cards without one just have a bit of empty space
        // above the price row, which the card's own Spacer already handles.
        mainAxisExtent: 400,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: _courses!.length,
      itemBuilder: (context, i) {
        final course = _courses![i];
        return CourseCard(
          course: course,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CourseDetailScreen(slug: course.slug)),
          ),
        );
      },
    );
  }
}
