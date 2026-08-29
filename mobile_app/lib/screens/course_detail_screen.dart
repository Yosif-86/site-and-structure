import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../i18n/strings.dart';
import '../models/course.dart';
import '../models/lecture.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
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
      final lectureRows = await sb.from('lectures').select('*').eq('course_id', course.id).order('order_index');
      final lectures = (lectureRows as List).map((r) => Lecture.fromJson(r as Map<String, dynamic>)).toList();

      String? status;
      final user = SupabaseService.instance.currentUser;
      if (user != null) {
        final enr = await sb.from('enrollments').select('status').eq('user_id', user.id).eq('course_slug', course.slug).maybeSingle();
        status = enr?['status'] as String?;
      }

      setState(() {
        _course = course;
        _lectures = lectures;
        _enrollmentStatus = status;
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
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPlayerScreen(lectureId: lecture.id, title: lecture.localizedTitle(AppStrings.instance.isAr))));
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
                ? Center(child: Text(_t('course_not_found'), style: const TextStyle(color: AppColors.muted)))
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.muted)))
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

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (tag != null && tag.isNotEmpty)
          Text(tag.toUpperCase(), style: const TextStyle(color: AppColors.red, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(color: AppColors.text, fontSize: 28, fontWeight: FontWeight.w800)),
        if (teacher != null && teacher.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${_t('by')} $teacher', style: const TextStyle(color: Color(0xFFA8496B), fontSize: 13)),
        ],
        if (desc != null && desc.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(desc, style: const TextStyle(color: AppColors.muted, fontSize: 15)),
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
        _buildPriceRow(isActive, isPending, course),
        const SizedBox(height: 32),
        Text(_t('curriculum'), style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (_lectures.isEmpty)
          Text(_t('no_lectures'), style: const TextStyle(color: AppColors.muted))
        else
          ..._lectures.map((l) => _LectureRow(
                lecture: l,
                unlocked: l.isFree || isActive,
                onWatch: () => _watchLecture(l),
              )),
      ],
    );
  }

  Widget _buildPriceRow(bool isActive, bool isPending, Course course) {
    if (isActive) {
      return _StatusBadge(text: _t('status_active'), color: AppColors.teal);
    }
    if (isPending) {
      return _StatusBadge(text: _t('status_pending'), color: AppColors.teal);
    }
    return Row(
      children: [
        course.isFree
            ? Text(_t('card_free'), style: const TextStyle(color: AppColors.teal, fontSize: 26, fontWeight: FontWeight.w800))
            : Text(course.price ?? '', style: const TextStyle(color: AppColors.text, fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(width: 16),
        ElevatedButton(
          onPressed: _openEnroll,
          child: Text(course.isFree ? _t('enroll_free') : _t('enroll')),
        ),
      ],
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
          Text(label.toUpperCase(), style: const TextStyle(color: AppColors.muted2, fontSize: 9.5, letterSpacing: 0.5)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(color: AppColors.text, fontSize: 12.5, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusBadge({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(999)),
      child: Text(text.toUpperCase(), style: TextStyle(color: color, fontSize: 10.5, letterSpacing: 0.5)),
    );
  }
}

class _LectureRow extends StatelessWidget {
  final Lecture lecture;
  final bool unlocked;
  final VoidCallback onWatch;
  const _LectureRow({required this.lecture, required this.unlocked, required this.onWatch});

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(child: Text(lecture.localizedTitle(ar), style: const TextStyle(color: AppColors.text, fontSize: 14))),
                if (lecture.isFree) ...[
                  const SizedBox(width: 8),
                  Text(t('free_tag'), style: const TextStyle(color: AppColors.teal, fontSize: 10, fontWeight: FontWeight.w700)),
                ],
              ],
            ),
          ),
          unlocked
              ? OutlinedButton(onPressed: onWatch, child: Text(t('watch')))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_outline, size: 16, color: AppColors.muted2),
                  const SizedBox(width: 4),
                  Text(t('locked'), style: const TextStyle(color: AppColors.muted2, fontSize: 13)),
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
                Text(t('enrolled'), style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('btn_close'))),
                const SizedBox(height: 12),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.course.localizedTitle(ar), style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(t('free_course_sub'), style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: AppColors.red, fontSize: 12.5)),
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
                  Text(t('submitted'), style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(t('pending_note'), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('btn_close'))),
                  const SizedBox(height: 12),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.course.localizedTitle(ar), style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('${widget.course.price ?? ''}${t('choose_payment_sub')}', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
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
                    Text(_error!, style: const TextStyle(color: AppColors.red, fontSize: 12.5)),
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
          Text(label, style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(color: AppColors.muted2, fontSize: 10)),
        ]),
      ),
    );
  }
}
