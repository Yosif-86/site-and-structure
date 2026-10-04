import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/course_card.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_scaffold.dart';
import 'course_detail_screen.dart';

/// A teacher's page. Students see the public side (photo, bio, published
/// courses, counts). The admin also sees contact and payment details and
/// every course with its status, including drafts.
class TeacherProfileScreen extends StatefulWidget {
  final String teacherId;
  final String? fallbackName;
  final bool adminView;
  final String? email;

  const TeacherProfileScreen({
    super.key,
    required this.teacherId,
    this.fallbackName,
    this.adminView = false,
    this.email,
  });

  @override
  State<TeacherProfileScreen> createState() => _TeacherProfileScreenState();
}

class _TeacherProfileScreenState extends State<TeacherProfileScreen> {
  Map<String, dynamic>? _public;
  Map<String, dynamic>? _private; // admin only
  List<Course> _courses = [];
  bool _loading = true;
  String? _error;

  String _t(String k) => AppStrings.instance.t(k);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sb = SupabaseService.instance.client;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var q = sb.from('courses').select('*').eq('teacher_id', widget.teacherId);
      if (!widget.adminView) q = q.eq('status', 'published');
      final rows = await q.order('created_at', ascending: false);
      Map<String, dynamic>? pub;
      try {
        final r = await sb.rpc('get_teacher_public',
            params: {'p_teacher_id': widget.teacherId});
        if (r is List && r.isNotEmpty) pub = (r.first as Map).cast<String, dynamic>();
      } catch (_) {
        // Function not added yet: name comes from the course rows.
      }
      Map<String, dynamic>? priv;
      if (widget.adminView) {
        priv = await sb
            .from('profiles')
            .select(
                'full_name, phone, teacher_zaincash_phone, teacher_qi_account_number, direct_payment_allowed, created_at')
            .eq('id', widget.teacherId)
            .maybeSingle();
      }
      if (!mounted) return;
      setState(() {
        _courses = (rows as List)
            .map((r) => Course.fromJson(r as Map<String, dynamic>))
            .toList();
        _public = pub;
        _private = priv;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorReporter.userMessage(e, page: 'teacher_profile');
      });
    }
  }

  String get _name {
    final ar = AppStrings.instance.isAr;
    return (_public?['full_name'] as String?) ??
        (_private?['full_name'] as String?) ??
        widget.fallbackName ??
        (_courses.isNotEmpty ? _courses.first.localizedTeacherName(ar) : null) ??
        '—';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
        appBar: AppBar(title: Text(_t('teacher_profile'))),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(children: [
                    DashEmpty(icon: ArcIcon.alert, message: _error!),
                    Center(
                      child: TextButton(
                          onPressed: _load, child: Text(_t('retry'))),
                    ),
                  ])
                : RefreshIndicator(onRefresh: _load, child: _content()),
      ),
    );
  }

  Widget _content() {
    final photo = _public?['photo_url'] as String?;
    final bio = (_public?['bio'] as String?)?.trim();
    final specialty = (_public?['specialty'] as String?)?.trim();
    final insta = (_public?['instagram'] as String?)?.trim();
    final tele = (_public?['telegram'] as String?)?.trim();
    final published = _courses.where((c) => c.status == 'published').length;
    final students = _public?['student_count'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        FadeSlideIn(
          delayMs: 0,
          child: Column(children: [
            const SizedBox(height: 8),
            CircleAvatar(
              radius: 46,
              backgroundColor: AppColors.red.withValues(alpha: 0.2),
              backgroundImage:
                  photo != null && photo.isNotEmpty ? NetworkImage(photo) : null,
              child: photo == null || photo.isEmpty
                  ? Text(_name.characters.first.toUpperCase(),
                      style: AppFonts.body(
                          size: 32, weight: FontWeight.w700, color: AppColors.text))
                  : null,
            ),
            const SizedBox(height: 12),
            Text(_name,
                textAlign: TextAlign.center,
                style: AppFonts.body(size: 22, weight: FontWeight.w800)),
            if (specialty != null && specialty.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(specialty,
                  textAlign: TextAlign.center,
                  style: AppFonts.body(size: 13.5, color: AppColors.muted)),
            ],
          ]),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
              child: _stat('${_public?['course_count'] ?? published}',
                  _t('stat_courses'))),
          const SizedBox(width: 10),
          Expanded(
              child: _stat(students == null ? '—' : '$students',
                  _t('stat_students'))),
        ]),
        if (bio != null && bio.isNotEmpty) ...[
          DashSection(_t('teacher_about')),
          DashCard(title: bio, titleStyle: AppFonts.body(size: 14)),
        ],
        if ((insta != null && insta.isNotEmpty) ||
            (tele != null && tele.isNotEmpty)) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (insta != null && insta.isNotEmpty)
              StatusPill('Instagram: @$insta', tone: StatusTone.neutral),
            if (tele != null && tele.isNotEmpty)
              StatusPill('Telegram: @$tele', tone: StatusTone.neutral),
          ]),
        ],
        if (widget.adminView && _private != null) ...[
          DashSection(_t('teacher_admin_details')),
          DashCard(
            leading: DashIconBadge(icon: ArcIcon.shield, accent: AppColors.byline),
            title: widget.email ?? '—',
            subtitle: (_private!['phone'] as String?) ?? '—',
            meta: [
              '${_t('zain_cash')}: ${_private!['teacher_zaincash_phone'] ?? '—'}',
              '${_t('qi_card')}: ${_private!['teacher_qi_account_number'] ?? '—'}',
              '${_t('direct_payment')}: ${_private!['direct_payment_allowed'] == true ? _t('yes') : _t('no')}',
            ],
          ),
        ],
        DashSection('${_t('stat_courses')} (${_courses.length})'),
        if (_courses.isEmpty)
          DashEmpty(icon: ArcIcon.courses, message: _t('no_courses'))
        else
          for (var i = 0; i < _courses.length; i++) ...[
            FadeSlideIn(
              delayMs: (i % 8) * 35,
              child: Stack(children: [
                CourseRow(
                  course: _courses[i],
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          CourseDetailScreen(slug: _courses[i].slug))),
                ),
                if (widget.adminView && _courses[i].status != 'published')
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: StatusPill(
                        _t(_courses[i].status == 'draft'
                            ? 'attention_draft'
                            : 'status_pending'),
                        tone: StatusTone.warn),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _stat(String value, String label) => DashCard(
        title: value,
        titleStyle: AppFonts.heading(size: 24),
        subtitle: label,
      );
}
