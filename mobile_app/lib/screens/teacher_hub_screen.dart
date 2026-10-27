import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/money.dart';
import '../services/supabase_service.dart';
import '../widgets/arc_icons.dart';
import '../widgets/course_card.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/fade_slide_in.dart';
import 'teacher_screen.dart';

/// Teacher-only tab of the bottom bar: the teacher's own courses with
/// shortcuts straight into the course page (info card + curriculum card),
/// either at the top or scrolled to the add-lecture form.
class TeacherHubPage extends StatefulWidget {
  const TeacherHubPage({super.key});

  @override
  State<TeacherHubPage> createState() => _TeacherHubPageState();
}

class _TeacherHubPageState extends State<TeacherHubPage> {
  List<Map<String, dynamic>>? _courses;
  String? _error;

  String _t(String k) => AppStrings.instance.t(k);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .select('id, title, price, is_free, status, thumbnail_url')
          .eq('teacher_id', user.id)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _courses = (rows as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final courses = _courses;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
        children: [
          Row(children: [
            Expanded(
              child: DashButton(t('create_course'),
                  primary: true,
                  icon: ArcIcon.plus,
                  onPressed: () =>
                      _open(const TeacherScreen(openView: 'courses'))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DashButton(t('teacher_dashboard'),
                  icon: ArcIcon.dashboard,
                  onPressed: () => _open(const TeacherScreen())),
            ),
          ]),
          const SizedBox(height: 12),
          if (_error != null)
            DashEmpty(icon: ArcIcon.alert, message: _error!)
          else if (courses == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (courses.isEmpty)
            DashEmpty(icon: ArcIcon.courses, message: t('no_courses_teacher'))
          else
            for (var i = 0; i < courses.length; i++) ...[
              FadeSlideIn(
                delayMs: (i % 10) * 30,
                child: _courseCard(t, courses[i]),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _courseCard(String Function(String) t, Map<String, dynamic> c) {
    final status = c['status'] as String? ?? 'draft';
    final tone = switch (status) {
      'published' => StatusTone.good,
      'pending' || 'pending_review' => StatusTone.warn,
      'rejected' => StatusTone.bad,
      _ => StatusTone.neutral,
    };
    final id = c['id'] as String;
    return DashCard(
      leading: SizedBox(
        width: 74,
        height: 56,
        child: CourseThumb(url: c['thumbnail_url'] as String?, radius: 12),
      ),
      title: c['title'] as String? ?? '—',
      subtitle: c['is_free'] == true ? t('card_free') : Money.text(c['price']),
      trailing: StatusPill(t('status_$status'), tone: tone),
      actions: [
        DashButton(t('btn_edit'),
            icon: ArcIcon.edit,
            primary: true,
            onPressed: () => _open(TeacherScreen(editCourseId: id))),
        DashButton(t('teach_add_lecture'),
            icon: ArcIcon.video,
            onPressed: () => _open(
                TeacherScreen(editCourseId: id, focusCurriculum: true))),
      ],
    );
  }
}
