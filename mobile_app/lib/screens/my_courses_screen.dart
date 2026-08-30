import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/enrollment.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'course_detail_screen.dart';

/// Port of my-courses.html.
class MyCoursesScreen extends StatefulWidget {
  const MyCoursesScreen({super.key});

  @override
  State<MyCoursesScreen> createState() => _MyCoursesScreenState();
}

class _MyCoursesScreenState extends State<MyCoursesScreen> {
  List<Enrollment>? _enrollments;
  Map<String, Map<String, dynamic>> _coursesBySlug = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() => _enrollments = []);
      return;
    }
    final rows = await sb
        .from('enrollments')
        .select('id, course_slug, status, created_at')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    final enrollments = (rows as List).map((r) => Enrollment.fromJson(r as Map<String, dynamic>)).toList();

    if (enrollments.isNotEmpty) {
      final slugs = enrollments.map((e) => e.courseSlug).toList();
      final courseRows = await sb.from('courses').select('slug, title, title_ar').inFilter('slug', slugs);
      final map = <String, Map<String, dynamic>>{};
      for (final c in (courseRows as List)) {
        map[c['slug'] as String] = c as Map<String, dynamic>;
      }
      setState(() { _enrollments = enrollments; _coursesBySlug = map; });
    } else {
      setState(() => _enrollments = enrollments);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;

    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: Text(t('my_courses'))),
        body: _enrollments == null
            ? const Center(child: CircularProgressIndicator())
            : _enrollments!.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(t('no_enrollments'), style: AppFonts.body(color: AppColors.muted), textAlign: TextAlign.center),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _enrollments!.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final e = _enrollments![i];
                        final c = _coursesBySlug[e.courseSlug];
                        final title = (ar && c?['title_ar'] != null && (c!['title_ar'] as String).isNotEmpty)
                            ? c['title_ar'] as String
                            : (c?['title'] as String? ?? e.courseSlug);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                          decoration: BoxDecoration(
                            color: AppColors.panel2,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title, style: AppFonts.body(size: 16, weight: FontWeight.w600)),
                                    const SizedBox(height: 4),
                                    Text('${t('enrolled_on')} ${e.createdAt.toLocal().toString().split(' ').first}',
                                        style: AppFonts.mono(size: 10.5, letterSpacing: 0.3)),
                                  ],
                                ),
                              ),
                              OutlinedButton(
                                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CourseDetailScreen(slug: e.courseSlug))),
                                child: Text(e.isActive ? t('watch') : t('view')),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  border: Border.all(color: e.isActive ? AppColors.teal : AppColors.teal),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  (e.isActive ? t('status_active') : t('status_pending')).toUpperCase(),
                                  style: AppFonts.mono(size: 9.5, color: AppColors.teal, letterSpacing: 0.5),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}
