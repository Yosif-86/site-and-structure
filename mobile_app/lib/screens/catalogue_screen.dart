import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/brand_title.dart';
import '../widgets/course_card.dart';
import 'admin_screen.dart';
import 'auth_screen.dart';
import 'course_detail_screen.dart';
import 'my_courses_screen.dart';

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
      final prof = await SupabaseService.instance.client.from('profiles').select('is_admin').eq('id', user.id).maybeSingle();
      if (mounted) setState(() => _isAdmin = prof?['is_admin'] == true);
    } catch (_) {
      if (mounted) setState(() => _isAdmin = false);
    }
  }

  @override
  void dispose() {
    AppStrings.instance.removeListener(_onLangChange);
    SupabaseService.instance.removeListener(_onAuthChangeAndAdmin);
    AppTheme.instance.removeListener(_onThemeChange);
    super.dispose();
  }

  void _onLangChange() => setState(() {});
  void _onAuthChangeAndAdmin() {
    setState(() {});
    _loadAdminFlag();
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

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final loggedIn = SupabaseService.instance.isLoggedIn;

    return Directionality(
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        drawer: _buildDrawer(t, loggedIn),
        appBar: AppBar(
          title: const BrandTitle(),
          actions: [
            IconButton(
              tooltip: 'Toggle theme',
              icon: Icon(AppTheme.instance.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              onPressed: () => AppTheme.instance.toggle(),
            ),
            IconButton(
              tooltip: 'Toggle language',
              icon: Text('AR/EN', style: AppFonts.mono(size: 11, color: AppColors.muted, weight: FontWeight.w700)),
              onPressed: () => AppStrings.instance.toggle(),
            ),
            if (loggedIn)
              IconButton(
                tooltip: t('my_courses'),
                icon: const Icon(Icons.school_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyCoursesScreen())),
              ),
            IconButton(
              tooltip: loggedIn ? t('log_out') : t('log_in'),
              icon: Icon(loggedIn ? Icons.logout : Icons.login),
              onPressed: () async {
                if (loggedIn) {
                  await SupabaseService.instance.logout();
                } else {
                  _openAuth();
                }
              },
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: _buildBody(t),
        ),
      ),
    );
  }

  Widget _buildDrawer(String Function(String) t, bool loggedIn) {
    return Drawer(
      backgroundColor: AppColors.panel,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.line))),
              child: Align(alignment: Alignment.bottomLeft, child: Text(t('menu'), style: AppFonts.heading(size: 20))),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: Text(t('nav_home')),
              onTap: () => Navigator.of(context).pop(),
            ),
            if (loggedIn)
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: Text(t('my_courses')),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyCoursesScreen()));
                },
              ),
            if (loggedIn && _isAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: Text(t('nav_admin')),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminScreen()));
                },
              ),
            const Divider(),
            ListTile(
              leading: Icon(loggedIn ? Icons.logout : Icons.login),
              title: Text(loggedIn ? t('log_out') : t('log_in')),
              onTap: () async {
                Navigator.of(context).pop();
                if (loggedIn) {
                  await SupabaseService.instance.logout();
                } else {
                  _openAuth();
                }
              },
            ),
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
