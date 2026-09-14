import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// Net-new teacher dashboard, ported from teacher.html: a dashboard-card
/// landing (Overview) plus My courses / course edit / curriculum / discount
/// codes / profile, all as native Flutter views navigated by an internal
/// _View enum (mirrors admin.html/teacher.html's single-page goView() model).
///
/// Gated behind profiles.is_teacher, same as teacher.html — enforced
/// server-side by RLS on every query below; the guard here just bounces a
/// non-teacher back out quickly.
class TeacherScreen extends StatefulWidget {
  const TeacherScreen({super.key});

  @override
  State<TeacherScreen> createState() => _TeacherScreenState();
}

enum _TView { overview, courses, courseEdit, curriculum, codes, profile }

class _TeacherScreenState extends State<TeacherScreen> {
  bool _checking = true;
  bool _isTeacher = false;
  bool _loading = false;
  String? _error;
  _TView _view = _TView.overview;

  List<Map<String, dynamic>> _myCourses = [];
  Map<String, dynamic>? _activeCourse;
  List<Map<String, dynamic>> _activeLectures = [];
  List<Map<String, dynamic>> _activeCodes = [];

  int _statStudents = 0;
  int _statEarnings = 0;

  // Course edit form state.
  final _cTitle = TextEditingController();
  final _cDescription = TextEditingController();
  final _cPrice = TextEditingController(text: '0');
  XFile? _cThumbFile;
  String? _cFormError;

  // Lecture form state.
  final _lTitle = TextEditingController();
  XFile? _lVideoFile;
  bool _lIsFree = false;
  String? _lFormError;

  // Discount code form state.
  final _dCode = TextEditingController();
  String _dType = 'percent';
  final _dValue = TextEditingController();
  final _dMaxUses = TextEditingController(text: '10');
  DateTime? _dExpires;
  String? _dFormError;

  // Profile form state.
  final _pName = TextEditingController();
  final _pSpecialty = TextEditingController();
  final _pBio = TextEditingController();
  String _pPayMethod = 'zain';
  final _pPayDetail = TextEditingController();
  String? _pPhotoUrl;
  XFile? _pPhotoFile;
  String? _pFormError;
  String? _pSavedMsg;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _cTitle.dispose();
    _cDescription.dispose();
    _cPrice.dispose();
    _lTitle.dispose();
    _dCode.dispose();
    _dValue.dispose();
    _dMaxUses.dispose();
    _pName.dispose();
    _pSpecialty.dispose();
    _pBio.dispose();
    _pPayDetail.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() { _checking = false; _isTeacher = false; });
      return;
    }
    try {
      final prof = await sb.from('profiles').select('is_teacher').eq('id', user.id).maybeSingle();
      final isTeacher = prof?['is_teacher'] == true;
      setState(() { _checking = false; _isTeacher = isTeacher; });
      if (isTeacher) {
        await _loadCourses();
        await _loadProfile();
      }
    } catch (e) {
      setState(() { _checking = false; _isTeacher = false; _error = e.toString(); });
    }
  }

  // ---- My courses ----

  Future<void> _loadCourses() async {
    setState(() => _loading = true);
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final data = await sb.from('courses').select('*').eq('teacher_id', user.id).order('created_at', ascending: false);
      _myCourses = (data as List).cast<Map<String, dynamic>>();
      await _loadOverview();
    } catch (e) {
      _showError('$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOverview() async {
    final slugs = _myCourses.map((c) => c['slug'] as String).toList();
    if (slugs.isEmpty) {
      setState(() { _statStudents = 0; _statEarnings = 0; });
      return;
    }
    final sb = SupabaseService.instance.client;
    final enrollments = await sb.from('enrollments').select('user_id, course_slug, status').inFilter('course_slug', slugs).eq('status', 'active');
    final rows = (enrollments as List).cast<Map<String, dynamic>>();
    final uniqueStudents = {for (final e in rows) e['user_id']}.length;
    final priceBySlug = {for (final c in _myCourses) c['slug'] as String: (num.tryParse('${c['price']}') ?? 0)};
    final earnings = rows.fold<num>(0, (sum, e) => sum + (priceBySlug[e['course_slug']] ?? 0));
    if (!mounted) return;
    setState(() { _statStudents = uniqueStudents; _statEarnings = earnings.round(); });
  }

  String _slugify(String title) {
    var s = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9؀-ۿ]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > 60) s = s.substring(0, 60);
    return s.isEmpty ? 'course' : s;
  }

  void _openNewCourse() {
    _activeCourse = null;
    _cTitle.clear();
    _cDescription.clear();
    _cPrice.text = '0';
    _cThumbFile = null;
    _cFormError = null;
    setState(() => _view = _TView.courseEdit);
  }

  void _openCourseEdit(Map<String, dynamic> c) {
    _activeCourse = c;
    _cTitle.text = c['title'] as String? ?? '';
    _cDescription.text = c['description'] as String? ?? '';
    _cPrice.text = '${c['price'] ?? 0}';
    _cThumbFile = null;
    _cFormError = null;
    setState(() => _view = _TView.courseEdit);
  }

  Future<void> _saveCourse() async {
    final t = AppStrings.instance.t;
    setState(() => _cFormError = null);
    final title = _cTitle.text.trim();
    if (title.isEmpty) {
      setState(() => _cFormError = t('err_title_required'));
      return;
    }
    final description = _cDescription.text.trim();
    final price = num.tryParse(_cPrice.text.trim()) ?? 0;
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      String? thumbnailUrl = _activeCourse?['thumbnail_url'] as String?;
      if (_cThumbFile != null) {
        final path = '${user.id}/${DateTime.now().millisecondsSinceEpoch}-${_cThumbFile!.name}';
        await sb.storage.from('course-thumbnails').upload(path, File(_cThumbFile!.path));
        thumbnailUrl = sb.storage.from('course-thumbnails').getPublicUrl(path);
      }
      if (_activeCourse != null) {
        await sb.from('courses').update({
          'title': title,
          'description': description,
          'price': price,
          'is_free': price == 0,
          'thumbnail_url': thumbnailUrl,
        }).eq('id', _activeCourse!['id']);
      } else {
        final slug = '${_slugify(title)}-${DateTime.now().millisecondsSinceEpoch.toRadixString(36).substring(6)}';
        await sb.from('courses').insert({
          'slug': slug,
          'title': title,
          'description': description,
          'price': price,
          'is_free': price == 0,
          'thumbnail_url': thumbnailUrl,
          'teacher_id': user.id,
          'status': 'draft',
        });
      }
      await _loadCourses();
      if (!mounted) return;
      setState(() => _view = _TView.courses);
    } catch (e) {
      setState(() => _cFormError = '${t('err_save_failed')}$e');
    }
  }

  Future<void> _submitForReview(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_submit_review').replaceAll('{title}', c['title'] as String? ?? ''));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('courses').update({'status': 'pending_review'}).eq('id', c['id']);
      await _loadCourses();
    } catch (e) {
      _showError('${t('alert_generic_failed')}$e');
    }
  }

  Future<void> _deleteCourse(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_delete_course').replaceAll('{title}', c['title'] as String? ?? ''));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('courses').delete().eq('id', c['id']);
      await _loadCourses();
    } catch (e) {
      _showError('${t('alert_generic_failed')}$e');
    }
  }

  // ---- Curriculum ----

  void _openCurriculum(Map<String, dynamic> c) {
    _activeCourse = c;
    _lTitle.clear();
    _lVideoFile = null;
    _lIsFree = false;
    _lFormError = null;
    setState(() => _view = _TView.curriculum);
    _loadLectures();
  }

  Future<void> _loadLectures() async {
    try {
      final data = await SupabaseService.instance.client.from('lectures').select('*').eq('course_id', _activeCourse!['id']).order('order_index');
      if (!mounted) return;
      setState(() => _activeLectures = (data as List).cast<Map<String, dynamic>>());
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _addLecture() async {
    final t = AppStrings.instance.t;
    setState(() => _lFormError = null);
    final title = _lTitle.text.trim();
    if (title.isEmpty) {
      setState(() => _lFormError = t('err_lecture_title_required'));
      return;
    }
    if (_lVideoFile == null) {
      setState(() => _lFormError = t('err_video_required'));
      return;
    }
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final path = '${user.id}/${_activeCourse!['id']}/${DateTime.now().millisecondsSinceEpoch}-${_lVideoFile!.name}';
      await sb.storage.from('lecture-uploads').upload(path, File(_lVideoFile!.path));
      final orderIndex = _activeLectures.isEmpty
          ? 0
          : (_activeLectures.map((l) => (l['order_index'] as num?) ?? 0).reduce((a, b) => a > b ? a : b) + 1);
      await sb.from('lectures').insert({
        'course_id': _activeCourse!['id'],
        'title': title,
        'is_free': _lIsFree,
        'order_index': orderIndex,
        'pending_upload_path': path,
      });
      _lTitle.clear();
      _lVideoFile = null;
      _lIsFree = false;
      await _loadLectures();
    } catch (e) {
      setState(() => _lFormError = '${t('err_save_failed')}$e');
    }
  }

  Future<void> _deleteLecture(String id) async {
    final t = AppStrings.instance.t;
    try {
      await SupabaseService.instance.client.from('lectures').delete().eq('id', id);
      await _loadLectures();
    } catch (e) {
      _showError('${t('alert_generic_failed')}$e');
    }
  }

  // ---- Discount codes ----

  void _openCodes(Map<String, dynamic> c) {
    _activeCourse = c;
    _dCode.clear();
    _dType = 'percent';
    _dValue.clear();
    _dMaxUses.text = '10';
    _dExpires = null;
    _dFormError = null;
    setState(() => _view = _TView.codes);
    _loadCodes();
  }

  Future<void> _loadCodes() async {
    try {
      final data = await SupabaseService.instance.client.from('discount_codes').select('*').eq('course_id', _activeCourse!['id']).order('created_at', ascending: false);
      if (!mounted) return;
      setState(() => _activeCodes = (data as List).cast<Map<String, dynamic>>());
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _addCode() async {
    final t = AppStrings.instance.t;
    setState(() => _dFormError = null);
    final code = _dCode.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _dFormError = t('err_code_required'));
      return;
    }
    final value = num.tryParse(_dValue.text.trim());
    if (value == null || value <= 0) {
      setState(() => _dFormError = t('err_value_required'));
      return;
    }
    final maxUses = int.tryParse(_dMaxUses.text.trim()) ?? 1;
    if (_dExpires == null) {
      setState(() => _dFormError = t('err_expires_required'));
      return;
    }
    if (_dExpires!.isBefore(DateTime.now())) {
      setState(() => _dFormError = t('err_expires_past'));
      return;
    }
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      await sb.from('discount_codes').insert({
        'course_id': _activeCourse!['id'],
        'code': code,
        'discount_type': _dType,
        'discount_value': value,
        'max_uses': maxUses,
        'expires_at': _dExpires!.toIso8601String(),
        'created_by': user.id,
      });
      _dCode.clear();
      _dValue.clear();
      await _loadCodes();
    } catch (e) {
      setState(() => _dFormError = '${t('err_save_failed')}$e');
    }
  }

  Future<void> _stopCode(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_revoke_code').replaceAll('{code}', c['code'] as String? ?? ''));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('discount_codes').update({'is_active': false}).eq('id', c['id']);
      await _loadCodes();
    } catch (e) {
      _showError('${t('alert_generic_failed')}$e');
    }
  }

  // ---- Profile ----

  Future<void> _loadProfile() async {
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final prof = await sb
          .from('profiles')
          .select('full_name, teacher_bio, teacher_specialty, teacher_photo_url, teacher_payment_method, teacher_payment_detail')
          .eq('id', user.id)
          .maybeSingle();
      if (prof == null || !mounted) return;
      setState(() {
        _pName.text = prof['full_name'] as String? ?? '';
        _pSpecialty.text = prof['teacher_specialty'] as String? ?? '';
        _pBio.text = prof['teacher_bio'] as String? ?? '';
        _pPhotoUrl = prof['teacher_photo_url'] as String?;
        _pPayMethod = prof['teacher_payment_method'] as String? ?? 'zain';
        _pPayDetail.text = prof['teacher_payment_detail'] as String? ?? '';
      });
    } catch (e) {
      _showError('$e');
    }
  }

  Future<void> _saveProfile() async {
    final t = AppStrings.instance.t;
    setState(() { _pFormError = null; _pSavedMsg = null; });
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      String? photoUrl;
      if (_pPhotoFile != null) {
        final path = '${user.id}/avatar-${DateTime.now().millisecondsSinceEpoch}-${_pPhotoFile!.name}';
        await sb.storage.from('course-thumbnails').upload(path, File(_pPhotoFile!.path));
        photoUrl = sb.storage.from('course-thumbnails').getPublicUrl(path);
      }
      final update = <String, dynamic>{
        'full_name': _pName.text.trim(),
        'teacher_specialty': _pSpecialty.text.trim(),
        'teacher_bio': _pBio.text.trim(),
        'teacher_payment_method': _pPayMethod,
        'teacher_payment_detail': _pPayDetail.text.trim(),
      };
      if (photoUrl != null) update['teacher_photo_url'] = photoUrl;
      await sb.from('profiles').update(update).eq('id', user.id);
      _pPhotoFile = null;
      await _loadProfile();
      if (!mounted) return;
      setState(() => _pSavedMsg = 'Saved.');
    } catch (e) {
      setState(() => _pFormError = '${t('err_save_failed')}$e');
    }
  }

  // ---- Shared helpers ----

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String message) async {
    final t = AppStrings.instance.t;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        content: Text(message, style: TextStyle(color: AppColors.text)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t('cancel'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t('btn_delete'))),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          leading: _view != _TView.overview
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _view = (_view == _TView.curriculum || _view == _TView.codes || _view == _TView.courseEdit) ? _TView.courses : _TView.overview),
                )
              : null,
          title: Text(t('teacher_dashboard')),
        ),
        body: _buildBody(t),
      ),
    );
  }

  Widget _buildBody(String Function(String) t) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    if (!_isTeacher) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? t('gate_not_teacher'), style: AppFonts.body(color: AppColors.muted), textAlign: TextAlign.center),
        ),
      );
    }
    return switch (_view) {
      _TView.overview => _buildOverview(t),
      _TView.courses => _buildCourses(t),
      _TView.courseEdit => _buildCourseEdit(t),
      _TView.curriculum => _buildCurriculum(t),
      _TView.codes => _buildCodes(t),
      _TView.profile => _buildProfile(t),
    };
  }

  Widget _buildOverview(String Function(String) t) {
    final cards = [
      _StatCardData(Icons.menu_book_outlined, '${_myCourses.length}', t('stat_courses'), AppColors.teal, () => setState(() => _view = _TView.courses)),
      _StatCardData(Icons.groups_outlined, '$_statStudents', t('stat_students'), AppColors.teal, () => setState(() => _view = _TView.courses)),
      _StatCardData(Icons.attach_money, '$_statEarnings', t('stat_earnings'), AppColors.red, () => setState(() => _view = _TView.courses)),
      _StatCardData(Icons.person_outline, '', t('my_profile'), AppColors.teal, () => setState(() => _view = _TView.profile)),
    ];
    return RefreshIndicator(
      onRefresh: () async { await _loadCourses(); await _loadProfile(); },
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.5),
        itemCount: cards.length,
        itemBuilder: (context, i) => _StatCard(data: cards[i]),
      ),
    );
  }

  Widget _buildCourses(String Function(String) t) {
    return RefreshIndicator(
      onRefresh: _loadCourses,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ElevatedButton.icon(onPressed: _openNewCourse, icon: const Icon(Icons.add), label: Text(t('create_course'))),
          const SizedBox(height: 12),
          if (_myCourses.isEmpty)
            Text(t('no_courses_teacher'), style: AppFonts.body(color: AppColors.muted))
          else
            for (final c in _myCourses) ...[
              _CourseCard(
                course: c,
                t: t,
                onEdit: c['status'] == 'draft' ? () => _openCourseEdit(c) : null,
                onCurriculum: () => _openCurriculum(c),
                onCodes: () => _openCodes(c),
                onSubmit: c['status'] == 'draft' ? () => _submitForReview(c) : null,
                onDelete: () => _deleteCourse(c),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _buildCourseEdit(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_activeCourse != null ? t('edit_course') : t('new_course_title'), style: AppFonts.heading(size: 20)),
        const SizedBox(height: 16),
        TextField(controller: _cTitle, decoration: InputDecoration(labelText: t('label_title'))),
        const SizedBox(height: 12),
        TextField(controller: _cDescription, maxLines: 4, decoration: InputDecoration(labelText: t('label_description'))),
        const SizedBox(height: 12),
        TextField(controller: _cPrice, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('label_price'))),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
            if (picked != null) setState(() => _cThumbFile = picked);
          },
          icon: const Icon(Icons.image_outlined),
          label: Text(_cThumbFile?.name ?? t('label_thumbnail')),
        ),
        if (_activeCourse?['thumbnail_url'] != null && _cThumbFile == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${t('current_file')}${_activeCourse!['thumbnail_url']}', style: AppFonts.mono(size: 10.5, color: AppColors.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        if (_cFormError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_cFormError!, style: AppFonts.body(size: 12, color: AppColors.red))),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: ElevatedButton(onPressed: _saveCourse, child: Text(t('save')))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton(onPressed: () => setState(() => _view = _TView.courses), child: Text(t('cancel')))),
        ]),
      ],
    );
  }

  Widget _buildCurriculum(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${t('curriculum')} — ${_activeCourse?['title'] ?? ''}', style: AppFonts.heading(size: 18)),
        const SizedBox(height: 16),
        if (_activeLectures.isEmpty)
          Text(t('no_lectures_teacher'), style: AppFonts.body(color: AppColors.muted))
        else
          for (final l in _activeLectures) ...[
            _AdminCard(children: [
              Text(l['title'] as String? ?? '—', style: AppFonts.body(size: 14, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${(l['bunny_video_id'] != null || l['r2_path'] != null) ? t('status_live') : t('status_pending_upload')}${l['is_free'] == true ? ' · ${t('free_tag')}' : ''}',
                style: AppFonts.mono(size: 10.5, color: AppColors.muted),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => _deleteLecture(l['id'] as String), child: Text(t('btn_delete'))),
            ]),
            const SizedBox(height: 10),
          ],
        const Divider(height: 32),
        Text(t('btn_add'), style: AppFonts.body(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 10),
        TextField(controller: _lTitle, decoration: InputDecoration(labelText: t('label_lecture_title'))),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
            if (picked != null) setState(() => _lVideoFile = picked);
          },
          icon: const Icon(Icons.videocam_outlined),
          label: Text(_lVideoFile?.name ?? t('label_video_file')),
        ),
        Row(children: [
          Checkbox(value: _lIsFree, onChanged: (v) => setState(() => _lIsFree = v ?? false)),
          Expanded(child: Text(t('label_free_lecture'), style: AppFonts.body(size: 12.5, color: AppColors.muted))),
        ]),
        if (_lFormError != null) Text(_lFormError!, style: AppFonts.body(size: 12, color: AppColors.red)),
        const SizedBox(height: 10),
        ElevatedButton(onPressed: _addLecture, child: Text(t('btn_add'))),
      ],
    );
  }

  Widget _buildCodes(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${t('discount_codes')} — ${_activeCourse?['title'] ?? ''}', style: AppFonts.heading(size: 18)),
        const SizedBox(height: 16),
        if (_activeCodes.isEmpty)
          Text(t('no_codes'), style: AppFonts.body(color: AppColors.muted))
        else
          for (final c in _activeCodes) ...[
            _AdminCard(children: [
              Row(children: [
                Expanded(child: Text(c['code'] as String? ?? '—', style: AppFonts.mono(size: 14, weight: FontWeight.w700))),
                Text(c['is_active'] == true ? t('status_active_code') : t('status_inactive'), style: AppFonts.mono(size: 10.5, color: AppColors.teal)),
              ]),
              const SizedBox(height: 4),
              Text(
                '${c['discount_type'] == 'percent' ? '${c['discount_value']}%' : '${c['discount_value']} IQD'} · ${c['used_count']}/${c['max_uses']}',
                style: AppFonts.body(size: 12.5, color: AppColors.muted),
              ),
              if (c['is_active'] == true) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => _stopCode(c), child: Text(t('btn_stop'))),
              ],
            ]),
            const SizedBox(height: 10),
          ],
        const Divider(height: 32),
        Text(t('create_course'), style: AppFonts.body(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 10),
        TextField(controller: _dCode, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: t('label_code'))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _dType,
              decoration: InputDecoration(labelText: t('label_discount_type')),
              items: [
                DropdownMenuItem(value: 'percent', child: Text(t('percent'))),
                DropdownMenuItem(value: 'fixed', child: Text(t('fixed'))),
              ],
              onChanged: (v) => setState(() => _dType = v ?? 'percent'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: _dValue, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('label_discount_value')))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: _dMaxUses, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: t('label_max_uses'))),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.now().add(const Duration(days: 30)),
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
            );
            if (picked != null) setState(() => _dExpires = picked);
          },
          icon: const Icon(Icons.event_outlined),
          label: Text(_dExpires != null ? _dExpires!.toString().split(' ').first : t('label_expires')),
        ),
        if (_dFormError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_dFormError!, style: AppFonts.body(size: 12, color: AppColors.red))),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _addCode, child: Text(t('btn_add'))),
      ],
    );
  }

  Widget _buildProfile(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: GestureDetector(
            onTap: () async {
              final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
              if (picked != null) setState(() => _pPhotoFile = picked);
            },
            child: CircleAvatar(
              radius: 40,
              backgroundColor: AppColors.panel2,
              backgroundImage: _pPhotoFile != null
                  ? FileImage(File(_pPhotoFile!.path))
                  : (_pPhotoUrl != null ? NetworkImage(_pPhotoUrl!) : null) as ImageProvider?,
              child: (_pPhotoFile == null && _pPhotoUrl == null) ? const Icon(Icons.camera_alt_outlined) : null,
            ),
          ),
        ),
        const SizedBox(height: 20),
        TextField(controller: _pName, decoration: InputDecoration(labelText: t('label_full_name'))),
        const SizedBox(height: 12),
        TextField(controller: _pSpecialty, decoration: InputDecoration(labelText: t('label_specialty'))),
        const SizedBox(height: 12),
        TextField(controller: _pBio, maxLines: 4, decoration: InputDecoration(labelText: t('label_bio'))),
        const SizedBox(height: 20),
        Text(t('my_payment_number'), style: AppFonts.body(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: RadioListTile<String>(
              value: 'zain',
              groupValue: _pPayMethod,
              title: Text(t('zain_cash')),
              onChanged: (v) => setState(() => _pPayMethod = v!),
            ),
          ),
          Expanded(
            child: RadioListTile<String>(
              value: 'qi',
              groupValue: _pPayMethod,
              title: Text(t('qi_card')),
              onChanged: (v) => setState(() => _pPayMethod = v!),
            ),
          ),
        ]),
        TextField(controller: _pPayDetail, decoration: const InputDecoration(labelText: '07XX XXX XXXX')),
        if (_pFormError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_pFormError!, style: AppFonts.body(size: 12, color: AppColors.red))),
        if (_pSavedMsg != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_pSavedMsg!, style: AppFonts.body(size: 12, color: AppColors.teal))),
        const SizedBox(height: 18),
        ElevatedButton(onPressed: _saveProfile, child: Text(t('save'))),
      ],
    );
  }
}

class _CourseCard extends StatelessWidget {
  final Map<String, dynamic> course;
  final String Function(String) t;
  final VoidCallback? onEdit;
  final VoidCallback onCurriculum;
  final VoidCallback onCodes;
  final VoidCallback? onSubmit;
  final VoidCallback onDelete;

  const _CourseCard({
    required this.course,
    required this.t,
    required this.onEdit,
    required this.onCurriculum,
    required this.onCodes,
    required this.onSubmit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final status = course['status'] as String? ?? 'draft';
    return _AdminCard(children: [
      Row(children: [
        Expanded(child: Text(course['title'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: AppColors.teal), borderRadius: BorderRadius.circular(999)),
          child: Text(t('status_$status').toUpperCase(), style: AppFonts.mono(size: 9, color: AppColors.teal)),
        ),
      ]),
      const SizedBox(height: 4),
      Text(course['is_free'] == true ? t('card_free') : '${course['price'] ?? '—'}', style: AppFonts.body(size: 13, color: AppColors.muted)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (onEdit != null) OutlinedButton(onPressed: onEdit, child: Text(t('btn_edit'))),
        OutlinedButton(onPressed: onCurriculum, child: Text(t('btn_curriculum'))),
        OutlinedButton(onPressed: onCodes, child: Text(t('btn_codes'))),
        if (onSubmit != null) ElevatedButton(onPressed: onSubmit, child: Text(t('submit_for_review'))),
        OutlinedButton(onPressed: onDelete, child: Text(t('btn_delete'))),
      ]),
    ]);
  }
}

class _StatCardData {
  final IconData icon;
  final String number;
  final String label;
  final Color color;
  final VoidCallback onTap;
  _StatCardData(this.icon, this.number, this.label, this.color, this.onTap);
}

class _StatCard extends StatelessWidget {
  final _StatCardData data;
  const _StatCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: data.onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: data.color.withOpacity(0.16), borderRadius: BorderRadius.circular(10)),
            child: Icon(data.icon, color: data.color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (data.number.isNotEmpty) Text(data.number, style: AppFonts.heading(size: 20)),
                Text(data.label, style: AppFonts.mono(size: 9.5, color: AppColors.muted2), maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _AdminCard extends StatelessWidget {
  final List<Widget> children;
  const _AdminCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.panel2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}
