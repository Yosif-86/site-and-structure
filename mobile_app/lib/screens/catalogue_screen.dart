import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/brand_title.dart';
import '../widgets/course_card.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
    AppStrings.instance.addListener(_onLangChange);
    SupabaseService.instance.addListener(_onAuthChange);
  }

  @override
  void dispose() {
    AppStrings.instance.removeListener(_onLangChange);
    SupabaseService.instance.removeListener(_onAuthChange);
    super.dispose();
  }

  void _onLangChange() => setState(() {});
  void _onAuthChange() => setState(() {});

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .select('*')
          .eq('status', 'published')
          .order('created_at');
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
        appBar: AppBar(
          title: const BrandTitle(),
          actions: [
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

  Widget _buildBody(String Function(String) t) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppColors.muted), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_courses == null) {
      return Center(child: Text(t('loading_courses'), style: const TextStyle(color: AppColors.muted)));
    }
    if (_courses!.isEmpty) {
      return Center(child: Text(t('no_courses'), style: const TextStyle(color: AppColors.muted)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 380,
        mainAxisExtent: 220,
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
