import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../models/lecture.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/glass_card.dart';
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
      final courseRow = await sb.from('courses').select('*').eq('slug', widget.slug).eq('status', 'published').maybeSingle();
      if (courseRow == null) {
        setState(() { _loading = false; _error = 'not_found'; });
        return;
      }
      final course = Course.fromJson(courseRow);
      // ascending must be explicit — postgrest's order() defaults it to
      // false, which was silently reversing the curriculum (Episode 2
      // before Episode 1) until this was caught by visual testing.
      final lectureRows =
          await sb.from('lectures').select('*').eq('course_id', course.id).order('order_index', ascending: true);
      final lectures = (lectureRows as List).map((r) => Lecture.fromJson(r as Map<String, dynamic>)).toList();

      String? status;
      var completedIds = <String>{};
      final user = SupabaseService.instance.currentUser;
      if (user != null) {
        final enr = await sb.from('enrollments').select('status').eq('user_id', user.id).eq('course_slug', course.slug).maybeSingle();
        status = enr?['status'] as String?;

        if (lectures.isNotEmpty) {
          final progressRows = await sb
              .from('lesson_progress')
              .select('lecture_id')
              .eq('user_id', user.id)
              .eq('completed', true)
              .inFilter('lecture_id', lectures.map((l) => l.id).toList());
          completedIds = (progressRows as List).map((r) => r['lecture_id'] as String).toSet();
        }
      }

      setState(() {
        _course = course;
        _lectures = lectures;
        _enrollmentStatus = status;
        _completedLectureIds = completedIds;
        _loading = false;
      });
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  String _t(String key) => AppStrings.instance.t(key);

  Future<void> _watchLecture(Lecture lecture) async {
    if (!SupabaseService.instance.isLoggedIn) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn) return;
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
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (!SupabaseService.instance.isLoggedIn || !mounted) return;
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
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error == 'not_found'
                ? Center(child: Text(_t('course_not_found'), style: AppFonts.body(color: AppColors.muted)))
                : _error != null
                    ? Center(child: Text(_error!, style: AppFonts.body(color: AppColors.muted)))
                    : _buildContent(),
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
    final isPending = _enrollmentStatus == 'pending';
    final freeLecture = _lectures.where((l) => l.isFree).isEmpty ? null : _lectures.firstWhere((l) => l.isFree);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _CourseHero(
          tag: tag,
          previewLabel: freeLecture != null ? _t('preview_course') : null,
          onPreview: freeLecture != null ? () => _watchLecture(freeLecture) : null,
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppFonts.heading(size: 30)),
              if (teacher != null && teacher.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('${_t('by')} $teacher', style: AppFonts.mono(size: 12, color: AppColors.byline, letterSpacing: 0.3)),
              ],
              if (desc != null && desc.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(desc, style: AppFonts.body(size: 15, color: AppColors.muted)),
              ],
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 20,
                  runSpacing: 12,
                  children: meta.entries.map((e) => _MetaItem(label: e.key, value: '${e.value}')).toList(),
                ),
              ],
              const SizedBox(height: 24),
              _buildPriceCard(isActive, isPending, course),
              const SizedBox(height: 28),
              if (_lectures.isNotEmpty) _buildFeatureBullets(course, freeLecture),
              const SizedBox(height: 28),
              Text(
                '${_t('curriculum').toUpperCase()} · ${_lectures.length} ${_t('lectures_count')}',
                style: AppFonts.heading(size: 20),
              ),
              const SizedBox(height: 14),
              if (_lectures.isEmpty)
                Text(_t('no_lectures'), style: AppFonts.body(color: AppColors.muted))
              else
                _CurriculumCard(
                  lectures: _lectures,
                  isActive: isActive,
                  completedIds: _completedLectureIds,
                  onWatch: _watchLecture,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureBullets(Course course, Lecture? freeLecture) {
    final freeCount = _lectures.where((l) => l.isFree).length;
    final items = <String>[
      '${_lectures.length} ${_t('feature_video_lectures')}',
      _t('feature_lifetime_access'),
      if (freeCount > 0) '$freeCount ${_t('feature_free_preview')}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map((label) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: AppColors.teal),
                    const SizedBox(width: 10),
                    Expanded(child: Text(label, style: AppFonts.body(size: 13.5))),
                  ],
                ),
              ))
          .toList(),
    );
  }

  Widget _buildPriceCard(bool isActive, bool isPending, Course course) {
    if (isActive) {
      return GlassCard(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.teal, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(_t('status_active').toUpperCase(), style: AppFonts.mono(size: 12, color: AppColors.teal, weight: FontWeight.w700))),
          ],
        ),
      );
    }
    if (isPending) {
      return GlassCard(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.hourglass_top, color: AppColors.teal, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(_t('status_pending').toUpperCase(), style: AppFonts.mono(size: 12, color: AppColors.teal, weight: FontWeight.w700))),
          ],
        ),
      );
    }
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          course.isFree
              ? Text(_t('card_free'), style: AppFonts.heading(size: 32, color: AppColors.teal))
              : Text(course.price ?? '', style: AppFonts.heading(size: 32)),
          const SizedBox(height: 16),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _openEnroll,
              child: Text(course.isFree ? _t('enroll_free') : _t('enroll'), style: AppFonts.body(size: 15, weight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero panel at the top of the course page — a stylized gradient in lieu of
/// a real thumbnail image (no thumbnail_url column exists yet), with the
/// course tag overlaid and, when a free lecture exists, a preview affordance.
class _CourseHero extends StatelessWidget {
  final String? tag;
  final String? previewLabel;
  final VoidCallback? onPreview;
  const _CourseHero({this.tag, this.previewLabel, this.onPreview});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.panel2, AppColors.bg],
              ),
            ),
          ),
          Positioned(
            right: -40,
            top: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [AppColors.red.withValues(alpha: 0.22), Colors.transparent]),
              ),
            ),
          ),
          if (tag != null && tag!.isNotEmpty)
            Positioned(
              left: 16,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.bg.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(999)),
                child: Text(tag!.toUpperCase(), style: AppFonts.eyebrow()),
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
                        boxShadow: [BoxShadow(color: AppColors.red.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 2)],
                      ),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                    ),
                    const SizedBox(height: 10),
                    Text(previewLabel!, style: AppFonts.mono(size: 11, color: AppColors.text, weight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
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
  final void Function(Lecture) onWatch;
  const _CurriculumCard({required this.lectures, required this.isActive, required this.completedIds, required this.onWatch});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        children: [
          for (var i = 0; i < lectures.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            _LectureRow(
              lecture: lectures[i],
              unlocked: lectures[i].isFree || isActive,
              completed: completedIds.contains(lectures[i].id),
              onWatch: () => onWatch(lectures[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  final String label;
  final String value;
  const _MetaItem({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AppFonts.mono(size: 9.5, letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(value, style: AppFonts.body(size: 12.5, weight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _LectureRow extends StatelessWidget {
  final Lecture lecture;
  final bool unlocked;
  final bool completed;
  final VoidCallback onWatch;
  const _LectureRow({required this.lecture, required this.unlocked, required this.completed, required this.onWatch});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (completed) ...[
                  const Icon(Icons.check_circle, size: 15, color: AppColors.teal),
                  const SizedBox(width: 6),
                ],
                Flexible(child: Text(lecture.localizedTitle(ar), style: AppFonts.body(size: 14))),
                if (lecture.isFree) ...[
                  const SizedBox(width: 8),
                  Text(t('free_tag'), style: AppFonts.mono(size: 10, color: AppColors.teal, weight: FontWeight.w700)),
                ],
              ],
            ),
          ),
          unlocked
              ? OutlinedButton(onPressed: onWatch, child: Text(t('watch')))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_outline, size: 16, color: AppColors.muted2),
                  const SizedBox(width: 4),
                  Text(t('locked'), style: AppFonts.body(size: 13, color: AppColors.muted2)),
                ]),
        ],
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
    setState(() { _loading = true; _error = null; });
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser!;
    try {
      await sb.from('enrollments').insert({'user_id': user.id, 'course_slug': widget.course.slug, 'status': 'active'});
      setState(() { _loading = false; _done = true; });
      widget.onDone();
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 24, right: 24, top: 24),
      child: SafeArea(
        child: _done
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle_outline, color: AppColors.teal, size: 44),
                const SizedBox(height: 12),
                Text(t('enrolled'), style: AppFonts.heading(size: 22)),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('btn_close'))),
                const SizedBox(height: 12),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.course.localizedTitle(ar), style: AppFonts.heading(size: 22)),
                const SizedBox(height: 6),
                Text(t('free_course_sub'), style: AppFonts.body(size: 13, color: AppColors.muted)),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(onPressed: _loading ? null : _submit, child: Text(t('enroll_free'))),
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
  XFile? _proof;
  bool _loading = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _detailCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickProof() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
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
    setState(() { _loading = true; _error = null; });
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser!;
    try {
      final fileName = '${user.id}/${DateTime.now().millisecondsSinceEpoch}-${_proof!.name}';
      await sb.storage.from('payment-proofs').upload(fileName, File(_proof!.path));
      await sb.from('enrollments').insert({
        'user_id': user.id,
        'course_slug': widget.course.slug,
        'status': 'pending',
        'payment_method': _method,
        'payment_detail': _detailCtrl.text.trim(),
        'payment_proof_path': fileName,
      });
      setState(() { _loading = false; _done = true; });
      widget.onDone();
    } catch (e) {
      setState(() { _loading = false; _error = t('err_upload_failed') + e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 24, right: 24, top: 24),
      child: SafeArea(
        child: SingleChildScrollView(
          child: _done
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_outline, color: AppColors.teal, size: 44),
                  const SizedBox(height: 12),
                  Text(t('submitted'), style: AppFonts.heading(size: 22)),
                  const SizedBox(height: 8),
                  Text(t('pending_note'), textAlign: TextAlign.center, style: AppFonts.body(size: 13, color: AppColors.muted)),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('btn_close'))),
                  const SizedBox(height: 12),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.course.localizedTitle(ar), style: AppFonts.heading(size: 22)),
                  const SizedBox(height: 4),
                  Text('${widget.course.price ?? ''}${t('choose_payment_sub')}', style: AppFonts.body(size: 13, color: AppColors.muted)),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _PayOption(label: t('zain_cash'), sub: t('zain_sub'), selected: _method == 'zain', onTap: () => setState(() => _method = 'zain'))),
                    const SizedBox(width: 10),
                    Expanded(child: _PayOption(label: t('qi_card'), sub: t('qi_sub'), selected: _method == 'qi', onTap: () => setState(() => _method = 'qi'))),
                  ]),
                  const SizedBox(height: 14),
                  TextField(controller: _detailCtrl, decoration: InputDecoration(labelText: t('pay_label'))),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _pickProof,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(_proof == null ? t('payment_screenshot') : _proof!.name, overflow: TextOverflow.ellipsis),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
                  ],
                  const SizedBox(height: 18),
                  ElevatedButton(onPressed: _loading ? null : _submit, child: Text(t('confirm_payment'))),
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
  const _PayOption({required this.label, required this.sub, required this.selected, required this.onTap});

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
