import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../i18n/strings.dart';
import '../services/live_refresh.dart';
import '../services/payment_rules.dart';
import '../services/r2_upload.dart';
import '../services/safe_picker.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/arc_icons.dart';
import '../widgets/course_card.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/file_preview.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/payment_requests.dart';
import '../widgets/proof_viewer.dart';

/// Net-new teacher dashboard, ported from teacher.html: a dashboard-card
/// landing (Overview) plus My courses / course edit / curriculum / discount
/// codes / profile, all as native Flutter views navigated by an internal
/// _View enum (mirrors admin.html/teacher.html's single-page goView() model).
///
/// Gated behind profiles.is_teacher, same as teacher.html — enforced
/// server-side by RLS on every query below; the guard here just bounces a
/// non-teacher back out quickly.
class TeacherScreen extends StatefulWidget {
  /// Opens straight on the profile view (which is where the ZainCash / Qi
  /// Card payout fields live) instead of the overview — used by the
  /// Settings > Payment info entry so that flow isn't duplicated there.
  final bool openPaymentInfo;

  /// Payment setup a new teacher can't skip: no back, no discard, and saving
  /// (with at least one method) lands on Home.
  final bool mandatoryPayment;

  /// Opens straight on a section (from a notification): 'payments' or
  /// 'courses'.
  final String? openView;

  const TeacherScreen(
      {super.key,
      this.openPaymentInfo = false,
      this.mandatoryPayment = false,
      this.openView});

  @override
  State<TeacherScreen> createState() => _TeacherScreenState();
}

enum _TView { overview, courses, courseEdit, curriculum, codes, profile, payments }

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

  /// Pending payment requests on this teacher's pay-to-teacher courses
  /// (get_teacher_students). Only these are the teacher's to decide.
  List<Map<String, dynamic>> _paymentRequests = [];

  Future<void> _loadPaymentRequests() async {
    try {
      final rows = await SupabaseService.instance.client
          .rpc('get_teacher_students') as List;
      if (!mounted) return;
      setState(() => _paymentRequests = rows
          .cast<Map<String, dynamic>>()
          .where((r) => r['status'] != 'active' && r['pay_to_teacher'] == true)
          .toList());
    } catch (_) {
      // Leaves the list as it was; the overview tile just shows 0.
    }
  }

  Future<void> _approvePayment(String id) async {
    final t = AppStrings.instance.t;
    try {
      await SupabaseService.instance.client
          .rpc('teacher_approve_enrollment', params: {'p_enrollment_id': id});
      _showError(t('payment_approved'));
      await _loadPaymentRequests();
      await _loadCourses();
    } catch (_) {
      _showError(t('err_generic_failed'));
    }
  }

  Future<void> _rejectPayment(String id) async {
    final t = AppStrings.instance.t;
    final reason = await askRejectReason(context);
    if (reason == null) return;
    try {
      await SupabaseService.instance.client.rpc('reject_enrollment',
          params: {'p_enrollment_id': id, 'p_reason': reason});
      await _loadPaymentRequests();
    } catch (_) {
      _showError(t('err_generic_failed'));
    }
  }

  Widget _buildPayments(String Function(String) t) {
    return RefreshIndicator(
      onRefresh: _loadPaymentRequests,
      child: _paymentRequests.isEmpty
          ? ListView(children: [
              DashEmpty(icon: ArcIcon.check, message: t('no_payment_requests'))
            ])
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: _paymentRequests.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final r = _paymentRequests[i];
                final proof = r['payment_proof_path'] as String?;
                final created =
                    DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal();
                return FadeSlideIn(
                  delayMs: (i % 10) * 30,
                  child: PaymentRequestCard(
                    studentName: r['full_name'] as String? ??
                        r['email'] as String? ??
                        '—',
                    contact: [r['email'], r['phone']]
                        .whereType<String>()
                        .where((s) => s.isNotEmpty)
                        .join(' · '),
                    courseTitle: r['course_title'] as String? ?? '—',
                    price: r['course_price'] as String?,
                    method: r['payment_method'] as String?,
                    detail: r['payment_detail'] as String?,
                    createdAt: created?.toString().substring(0, 16),
                    canDecide: true,
                    onViewProof: proof == null
                        ? null
                        : () => openPaymentProof(context, proof),
                    onApprove: () =>
                        _approvePayment(r['enrollment_id'] as String),
                    onReject: () =>
                        _rejectPayment(r['enrollment_id'] as String),
                  ),
                );
              },
            ),
    );
  }
  int _statEarnings = 0;

  // Course edit form state.
  final _cTitle = TextEditingController();
  final _cDescription = TextEditingController();
  final _cPrice = TextEditingController();
  // "What you'll learn" -- one field per point, stored as
  // courses.learning_points. All optional; empty fields are dropped on save.
  static const _maxPoints = 12;
  static const _minPointRows = 3;
  final List<TextEditingController> _cPoints = [];
  XFile? _cThumbFile;
  // Current cover: the pending edit's if one is waiting, else the live one.
  String? _cThumbUrl;
  String? _cFormError;
  // Guards the save button: a double tap used to create the course twice.
  bool _cSaving = false;

  // Lecture form state.
  final _lTitle = TextEditingController();
  XFile? _lVideoFile;
  bool _lIsFree = false;
  String? _lFormError;
  // 0.0-1.0 while a video is uploading, null the rest of the time — drives
  // the circular progress pill in place of the Add button.
  double? _lUploadProgress;
  R2Upload? _upload;
  String _lUploadPhase = 'upload'; // 'prepare' (downscaling) | 'upload'
  bool _uploadBusy = false;
  bool _uploadCancelled = false;

  // Discount code form state.
  final _dCode = TextEditingController();
  String _dType = 'percent';
  final _dValue = TextEditingController();
  final _dMaxUses = TextEditingController(text: '10');
  DateTime? _dExpires;
  bool _dSaving = false;
  String? _dFormError;

  // Profile form state.
  final _pZaincashPhone = TextEditingController();
  final _pQiAccount = TextEditingController();
  String? _pQiQrUrl;
  XFile? _pQiQrFile;
  String? _pFormError;
  String? _pSavedMsg;

  // Approvals, new payment requests and published lectures show up live.
  late final _live = LiveRefresh(
    tables: const ['enrollments', 'courses', 'lectures'],
    onChange: () async {
      if (!_isTeacher) return;
      await _loadCourses();
      await _loadPaymentRequests();
      if (_view == _TView.curriculum && _activeCourse != null) {
        await _loadLectures();
      }
    },
  );

  @override
  void initState() {
    super.initState();
    _init();
    _live.start();
  }

  @override
  void dispose() {
    _live.stop();
    _cTitle.dispose();
    _cDescription.dispose();
    _cPrice.dispose();
    for (final c in _cPoints) {
      c.dispose();
    }
    _lTitle.dispose();
    _dCode.dispose();
    _dValue.dispose();
    _dMaxUses.dispose();
    _pZaincashPhone.dispose();
    _pQiAccount.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() {
        _checking = false;
        _isTeacher = false;
      });
      return;
    }
    try {
      final prof = await sb
          .from('profiles')
          .select('is_teacher')
          .eq('id', user.id)
          .maybeSingle();
      final isTeacher = prof?['is_teacher'] == true;
      setState(() {
        _checking = false;
        _isTeacher = isTeacher;
        if (isTeacher && widget.openPaymentInfo) _view = _TView.profile;
        if (isTeacher && widget.openView == 'payments') _view = _TView.payments;
        if (isTeacher && widget.openView == 'courses') _view = _TView.courses;
      });
      if (isTeacher) {
        await _loadCourses();
        await _loadProfile();
        await _loadPaymentRequests();
      }
    } catch (e) {
      setState(() {
        _checking = false;
        _isTeacher = false;
        _error = e.toString();
      });
    }
  }

  // ---- My courses ----

  Future<void> _loadCourses() async {
    setState(() => _loading = true);
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final data = await sb
          .from('courses')
          .select('*')
          .eq('teacher_id', user.id)
          .order('created_at', ascending: false);
      _myCourses = (data as List).cast<Map<String, dynamic>>();
      await _loadOverview();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOverview() async {
    final slugs = _myCourses.map((c) => c['slug'] as String).toList();
    if (slugs.isEmpty) {
      setState(() {
        _statStudents = 0;
        _statEarnings = 0;
      });
      return;
    }
    // enrollments RLS only lets a user read their own rows, so a direct
    // select returned nothing here; get_teacher_students (security definer)
    // returns this teacher's enrollments.
    final all = await SupabaseService.instance.client
        .rpc('get_teacher_students') as List;
    final rows = all
        .cast<Map<String, dynamic>>()
        .where((e) => e['status'] == 'active')
        .toList();
    final uniqueStudents = {
      for (final e in rows) e['email'] ?? e['phone'] ?? e['enrollment_id']
    }.length;
    final courseBySlug = {for (final c in _myCourses) c['slug'] as String: c};
    final earnings = rows.fold<num>(0, (sum, e) {
      final c = courseBySlug[e['course_slug']];
      if (c == null || c['is_free'] == true) return sum;
      // Real amounts once stored on the enrollment (discounts, free grants);
      // older rows count the full price.
      final price = (e['list_price'] as num?)?.toInt() ??
          PaymentRules.parsePrice(c['price']);
      final paid = (e['amount_paid'] as num?)?.toInt() ?? price;
      final s = PaymentRules.split(
          price: price,
          paid: paid,
          directToTeacher: c['pay_to_teacher'] == true);
      return sum + (s.teacher < 0 ? 0 : s.teacher);
    });
    if (!mounted) return;
    setState(() {
      _statStudents = uniqueStudents;
      _statEarnings = earnings.round();
    });
  }

  String _slugify(String title) {
    var s = title
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[^a-z0-9؀-ۿ]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > 60) s = s.substring(0, 60);
    return s.isEmpty ? 'course' : s;
  }

  void _openNewCourse() {
    _activeCourse = null;
    _cTitle.clear();
    _cDescription.clear();
    _cPrice.clear();
    _setPoints(const []);
    _cThumbUrl = null;
    _cThumbFile = null;
    _cFormError = null;
    setState(() => _view = _TView.courseEdit);
  }

  void _openCourseEdit(Map<String, dynamic> c) {
    _activeCourse = c;
    // A published course with an edit waiting: reopen the proposed version.
    final pending = c['edit_status'] == 'pending_review'
        ? (c['pending_edit'] as Map?)?.cast<String, dynamic>()
        : null;
    final src = {...c, ...?pending};
    _cTitle.text = src['title'] as String? ?? '';
    _cDescription.text = src['description'] as String? ?? '';
    _cPrice.text = '${src['price'] ?? 0}';
    _setPoints(((src['learning_points'] as List?) ?? const [])
        .whereType<String>()
        .toList());
    _cThumbUrl = src['thumbnail_url'] as String?;
    _cThumbFile = null;
    _cFormError = null;
    setState(() => _view = _TView.courseEdit);
  }

  Future<void> _saveCourse() async {
    if (_cSaving) return;
    final t = AppStrings.instance.t;
    setState(() => _cFormError = null);
    final title = _cTitle.text.trim();
    if (title.isEmpty) {
      setState(() => _cFormError = t('err_title_required'));
      return;
    }
    final description = _cDescription.text.trim();
    // Required, but starts empty so the teacher types it fresh (0 = free).
    if (PaymentRules.digits(_cPrice.text).isEmpty) {
      setState(() => _cFormError = t('err_price_required'));
      return;
    }
    final price = PaymentRules.parsePrice(_cPrice.text);
    // Same caps the DB check constraint enforces (add-course-learning-points
    // .sql): at most 12 points, each at most 200 characters.
    final learningPoints = _cPoints
        .map((c) => c.text.trim())
        .where((l) => l.isNotEmpty)
        .take(12)
        .map((l) => l.length > 200 ? l.substring(0, 200) : l)
        .toList();
    setState(() => _cSaving = true);
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      String? thumbnailUrl = _cThumbUrl;
      if (_cThumbFile != null) {
        final path =
            '${user.id}/${DateTime.now().millisecondsSinceEpoch}-${_cThumbFile!.name}';
        await sb.storage
            .from('course-thumbnails')
            .upload(path, File(_cThumbFile!.path));
        thumbnailUrl = sb.storage.from('course-thumbnails').getPublicUrl(path);
      }
      if (_activeCourse != null && _activeCourse!['status'] == 'published') {
        // Live course: the change waits for the admin; students keep seeing
        // the current version until it's approved.
        await sb.from('courses').update({
          'pending_edit': {
            'title': title,
            'description': description,
            'price': price,
            'thumbnail_url': thumbnailUrl,
            'learning_points': learningPoints,
          },
          'edit_status': 'pending_review',
        }).eq('id', _activeCourse!['id']);
        _showError(t('edit_request_sent'));
      } else if (_activeCourse != null) {
        await sb.from('courses').update({
          'title': title,
          'description': description,
          'price': price,
          'is_free': price == 0,
          'thumbnail_url': thumbnailUrl,
          // Sent when there's something to set, or something to clear (the row
          // already has the column then) -- never otherwise, so saving still
          // works against a database that hasn't run the migration yet.
          if (learningPoints.isNotEmpty ||
              ((_activeCourse!['learning_points'] as List?)?.isNotEmpty ?? false))
            'learning_points': learningPoints,
        }).eq('id', _activeCourse!['id']);
      } else {
        final slug =
            '${_slugify(title)}-${const Uuid().v4().substring(0, 6)}';
        await sb.from('courses').insert({
          'slug': slug,
          'title': title,
          'description': description,
          'price': price,
          'is_free': price == 0,
          'thumbnail_url': thumbnailUrl,
          if (learningPoints.isNotEmpty) 'learning_points': learningPoints,
          'teacher_id': user.id,
          'status': 'draft',
        });
      }
      await _loadCourses();
      if (!mounted) return;
      setState(() => _view = _TView.courses);
    } catch (e) {
      if (mounted) setState(() => _cFormError = ErrorReporter.userMessage(e, page: 'teacher'));
    } finally {
      if (mounted) setState(() => _cSaving = false);
    }
  }

  Future<void> _submitForReview(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(
        t('confirm_submit_review')
            .replaceAll('{title}', c['title'] as String? ?? ''),
        confirmLabel: t('btn_confirm'),
        danger: false);
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('courses')
          .update({'status': 'pending_review'}).eq('id', c['id']);
      await _loadCourses();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _deleteCourse(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    // Students may have paid for a published course; only the admin can
    // take one down (the database enforces the same rule).
    if (c['status'] == 'published') {
      _showError(t('err_published_course_delete'));
      return;
    }
    final confirmed = await _confirm(t('confirm_delete_course')
        .replaceAll('{title}', c['title'] as String? ?? ''));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('courses')
          .delete()
          .eq('id', c['id']);
      await _loadCourses();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
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
      final data = await SupabaseService.instance.client
          .from('lectures')
          .select('*')
          .eq('course_id', _activeCourse!['id'])
          .order('order_index');
      if (!mounted) return;
      setState(
          () => _activeLectures = (data as List).cast<Map<String, dynamic>>());
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
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
    File? compressed;
    try {
      final sb = SupabaseService.instance.client;
      final lectureId = const Uuid().v4();
      setState(() {
        _lUploadProgress = 0;
        _lUploadPhase = 'prepare';
        _uploadBusy = true;
      });
      // Size and runtime off the local file first: the runtime shows on the
      // course page from the start, the size decides whether to downscale.
      final info = await _readVideoInfo(File(_lVideoFile!.path));
      var source = File(_lVideoFile!.path);
      // Lectures stream at up to 1080p: anything larger (4K phone footage)
      // is re-encoded on the phone before upload, which also makes the
      // upload several times smaller.
      if (info.shortSide > 1080) {
        final sub = VideoCompress.compressProgress$.subscribe((p) {
          if (mounted) setState(() => _lUploadProgress = (p / 100).clamp(0, 1));
        });
        try {
          final out = await VideoCompress.compressVideo(
            source.path,
            quality: VideoQuality.Res1920x1080Quality,
            includeAudio: true,
            deleteOrigin: false,
          );
          if (_uploadCancelled) throw const UploadCancelled();
          if (out?.file == null) throw Exception('compress failed');
          compressed = out!.file!;
          source = compressed;
        } finally {
          sub.unsubscribe();
        }
      }
      if (_uploadCancelled) throw const UploadCancelled();
      if (mounted) {
        setState(() {
          _lUploadPhase = 'upload';
          _lUploadProgress = 0;
        });
      }
      final upload = _upload = R2Upload(
        courseId: _activeCourse!['id'] as String,
        lectureId: lectureId,
        file: source,
      );
      await upload.start((p) {
        if (mounted) setState(() => _lUploadProgress = p);
      });
      final orderIndex = _activeLectures.isEmpty
          ? 0
          : (_activeLectures
                  .map((l) => (l['order_index'] as num?) ?? 0)
                  .reduce((a, b) => a > b ? a : b) +
              1);
      // Pending until the admin approves it (only an admin can set r2_path,
      // which is what makes it playable).
      await sb.from('lectures').insert({
        'id': lectureId,
        'course_id': _activeCourse!['id'],
        'title': title,
        'is_free': _lIsFree,
        'order_index': orderIndex,
        'pending_upload_path': 'r2:${upload.key}',
        if (info.seconds != null) 'duration_seconds': info.seconds,
      });
      _lTitle.clear();
      _lVideoFile = null;
      _lIsFree = false;
      _showError(t('lecture_sent_for_review'));
      await _loadLectures();
    } on UploadCancelled {
      if (mounted) _showError(t('upload_cancelled'));
    } catch (e) {
      if (mounted) setState(() => _lFormError = t('err_video_upload_failed'));
    } finally {
      _upload = null;
      _uploadBusy = false;
      _uploadCancelled = false;
      if (compressed != null) {
        compressed.delete().catchError((_) => compressed!);
      }
      if (mounted) setState(() => _lUploadProgress = null);
    }
  }

  /// Local video runtime (seconds) and the shorter side of its frame (the
  /// "1080" in 1080p, whatever the orientation). Never throws.
  Future<({int? seconds, int shortSide})> _readVideoInfo(File file) async {
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
      final seconds = controller.value.duration.inSeconds;
      final size = controller.value.size;
      final short = size.width < size.height ? size.width : size.height;
      return (seconds: seconds > 0 ? seconds : null, shortSide: short.round());
    } catch (_) {
      return (seconds: null, shortSide: 0);
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _deleteLecture(Map<String, dynamic> l) async {
    final t = AppStrings.instance.t;
    final live = l['r2_path'] != null;
    final ok = await _confirm(
        t(live ? 'confirm_delete_live_lecture' : 'confirm_delete_lecture')
            .replaceAll('{title}', l['title'] as String? ?? ''));
    if (!ok) return;
    try {
      await SupabaseService.instance.client
          .from('lectures')
          .delete()
          .eq('id', l['id']);
      await _loadLectures();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
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
      final data = await SupabaseService.instance.client
          .from('discount_codes')
          .select('*')
          .eq('course_id', _activeCourse!['id'])
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(
          () => _activeCodes = (data as List).cast<Map<String, dynamic>>());
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _addCode() async {
    if (_dSaving) return;
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
    final price = PaymentRules.parsePrice(_activeCourse?['price']);
    final tooBig = _dType == 'percent'
        ? value > PaymentRules.maxDiscountRate * 100
        : price > 0 && value > price * PaymentRules.maxDiscountRate;
    if (tooBig) {
      setState(() => _dFormError = t('err_discount_too_large'));
      return;
    }
    final maxUsesText = _dMaxUses.text.trim();
    final maxUses = maxUsesText.isEmpty ? 1 : int.tryParse(maxUsesText);
    if (maxUses == null || maxUses < 1) {
      setState(() => _dFormError = t('err_max_uses_invalid'));
      return;
    }
    if (_dExpires == null) {
      setState(() => _dFormError = t('err_expires_required'));
      return;
    }
    if (_dExpires!.isBefore(DateTime.now())) {
      setState(() => _dFormError = t('err_expires_past'));
      return;
    }
    setState(() => _dSaving = true);
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      await sb.from('discount_codes').insert({
        'course_id': _activeCourse!['id'],
        'code': code,
        'discount_type': _dType,
        'discount_value': value,
        'max_uses': maxUses,
        'expires_at': _dExpires!.toUtc().toIso8601String(),
        'created_by': user.id,
      });
      _dCode.clear();
      _dValue.clear();
      await _loadCodes();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _dFormError = e.code == '23505'
          ? t('err_code_exists')
          : e.message.contains('discount_too_large')
              ? t('err_discount_too_large')
              : ErrorReporter.userMessage(e, page: 'teacher'));
    } catch (e) {
      if (mounted) {
        setState(() => _dFormError = ErrorReporter.userMessage(e, page: 'teacher'));
      }
    } finally {
      if (mounted) setState(() => _dSaving = false);
    }
  }

  Future<void> _stopCode(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_revoke_code')
        .replaceAll('{code}', c['code'] as String? ?? ''));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('discount_codes')
          .update({'is_active': false}).eq('id', c['id']);
      await _loadCodes();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  // ---- Profile ----

  Future<void> _loadProfile() async {
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final prof = await sb
          .from('profiles')
          .select(
              'teacher_zaincash_phone, teacher_qi_account_number, teacher_qi_qr_url')
          .eq('id', user.id)
          .maybeSingle();
      if (prof == null || !mounted) return;
      setState(() {
        _pZaincashPhone.text = prof['teacher_zaincash_phone'] as String? ?? '';
        _pQiAccount.text = prof['teacher_qi_account_number'] as String? ?? '';
        _pQiQrUrl = prof['teacher_qi_qr_url'] as String?;
      });
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _saveProfile() async {
    final t = AppStrings.instance.t;
    setState(() {
      _pFormError = null;
      _pSavedMsg = null;
    });
    final hasMethod = _pZaincashPhone.text.trim().isNotEmpty ||
        _pQiAccount.text.trim().isNotEmpty;
    if (!hasMethod) {
      setState(() => _pFormError = t('err_payment_method_required'));
      return;
    }
    if (_pZaincashPhone.text.trim().isNotEmpty &&
        !PaymentRules.isValidZain(_pZaincashPhone.text)) {
      setState(() => _pFormError = t('err_invalid_zain'));
      return;
    }
    if (_pQiAccount.text.trim().isNotEmpty &&
        !PaymentRules.isValidQi(_pQiAccount.text)) {
      setState(() => _pFormError = t('err_invalid_qi'));
      return;
    }
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      String? qrUrl;
      if (_pQiQrFile != null) {
        final path =
            '${user.id}/${DateTime.now().millisecondsSinceEpoch}-${_pQiQrFile!.name}';
        await sb.storage
            .from('payment-qr')
            .upload(path, File(_pQiQrFile!.path));
        qrUrl = sb.storage.from('payment-qr').getPublicUrl(path);
      }
      final update = <String, dynamic>{
        'teacher_zaincash_phone': _pZaincashPhone.text.trim().isEmpty
            ? null
            : _pZaincashPhone.text.trim(),
        'teacher_qi_account_number':
            _pQiAccount.text.trim().isEmpty ? null : _pQiAccount.text.trim(),
      };
      if (qrUrl != null) update['teacher_qi_qr_url'] = qrUrl;
      await sb.from('profiles').update(update).eq('id', user.id);
      _pQiQrFile = null;
      await _loadProfile();
      if (!mounted) return;
      if (widget.mandatoryPayment) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() => _pSavedMsg = t('saved'));
    } catch (e) {
      setState(() => _pFormError = ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _deletePaymentMethod() async {
    final t = AppStrings.instance.t;
    if (!await _confirm(t('confirm_delete_payment_method'))) return;
    setState(() {
      _pFormError = null;
      _pSavedMsg = null;
    });
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      await sb.from('profiles').update({
        'teacher_zaincash_phone': null,
        'teacher_qi_account_number': null,
        'teacher_qi_qr_url': null,
      }).eq('id', user.id);
      _pQiQrFile = null;
      await _loadProfile();
      if (!mounted) return;
      setState(() => _pSavedMsg = t('payment_method_deleted'));
    } catch (e) {
      setState(() => _pFormError = ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  // ---- Shared helpers ----

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String message,
      {String? confirmLabel, bool danger = true}) async {
    final t = AppStrings.instance.t;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message, style: TextStyle(color: AppColors.text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('cancel'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                  foregroundColor: danger ? AppColors.error : AppColors.red),
              child: Text(confirmLabel ?? t('btn_delete'))),
        ],
      ),
    );
    return result ?? false;
  }

  /// Asks first, then stops the running lecture upload.
  Future<bool> _confirmCancelUpload() async {
    if (!_uploadBusy) return true;
    final t = AppStrings.instance.t;
    final ok = await _confirm(t('confirm_cancel_upload'),
        confirmLabel: t('btn_cancel_upload'));
    if (ok) {
      _uploadCancelled = true;
      VideoCompress.cancelCompression();
      _upload?.cancel();
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
        maxContentWidth: 1100,
        appBar: AppBar(
          automaticallyImplyLeading: !widget.mandatoryPayment,
          leading: widget.mandatoryPayment
              ? null
              : widget.openPaymentInfo
              // This instance was pushed just for Settings > Payment info --
              // there's no dashboard overview to fall back into, so back
              // means leave the screen entirely instead of switching views.
              ? IconButton(
                  icon: ArcIconView(ArcIcon.back, size: 22, color: AppColors.text),
                  onPressed: () => Navigator.of(context).pop(),
                )
              : _view != _TView.overview
                  ? IconButton(
                      icon: ArcIconView(ArcIcon.back, size: 22, color: AppColors.text),
                      onPressed: () async {
                        if (!await _confirmCancelUpload()) return;
                        setState(() => _view = (_view == _TView.curriculum ||
                                _view == _TView.codes ||
                                _view == _TView.courseEdit)
                            ? _TView.courses
                            : _TView.overview);
                      },
                    )
                  : null,
          title: Text(widget.openPaymentInfo
              ? t('settings_payment_info')
              : t('teacher_dashboard')),
        ),
        body: PopScope(
          // System back: blocked during the mandatory payment step, and
          // asks before abandoning a lecture upload.
          // Inside a sub-view, back steps up one level (like the AppBar
          // arrow) instead of closing the whole dashboard.
          canPop: !widget.mandatoryPayment &&
              !_uploadBusy &&
              (_view == _TView.overview || widget.openPaymentInfo),
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop || widget.mandatoryPayment) return;
            if (!await _confirmCancelUpload() || !mounted) return;
            if (_view != _TView.overview && !widget.openPaymentInfo) {
              setState(() => _view = (_view == _TView.curriculum ||
                      _view == _TView.codes ||
                      _view == _TView.courseEdit)
                  ? _TView.courses
                  : _TView.overview);
            } else {
              Navigator.of(context).pop();
            }
          },
          child: _buildBody(t),
        ),
      ),
    );
  }

  Widget _buildBody(String Function(String) t) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    if (!_isTeacher) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? t('gate_not_teacher'),
              style: AppFonts.body(color: AppColors.muted),
              textAlign: TextAlign.center),
        ),
      );
    }
    return switch (_view) {
      _TView.overview => _buildOverview(t),
      _TView.courses => _buildCourses(t),
      _TView.courseEdit => _buildCourseEdit(t),
      _TView.curriculum => _buildCurriculum(t),
      _TView.codes => _buildCodes(t),
      _TView.payments => _buildPayments(t),
      _TView.profile => _buildProfile(t),
    };
  }

  Widget _buildOverview(String Function(String) t) {
    void go(_TView v) => setState(() => _view = v);
    var delay = 0;
    Widget tile(ArcIcon icon, String value, String label, Color accent,
            VoidCallback onTap, {bool alert = false}) =>
        FadeSlideIn(
          delayMs: delay += 40,
          child: DashStatCard(
              icon: icon,
              value: value,
              label: label,
              accent: accent,
              alert: alert,
              onTap: onTap),
        );
    final paymentSet = _pZaincashPhone.text.trim().isNotEmpty ||
        _pQiAccount.text.trim().isNotEmpty ||
        _pQiQrUrl != null;
    return RefreshIndicator(
      onRefresh: () async {
        await _loadCourses();
        await _loadProfile();
        await _loadPaymentRequests();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          FadeSlideIn(
            delayMs: 0,
            child: DashHero(
              title: t('teacher_dashboard'),
              subtitle: t('dash_teacher_sub'),
              stats: [
                ('${_myCourses.length}', t('stat_courses')),
                ('$_statStudents', t('stat_students')),
                ('$_statEarnings', t('stat_earnings')),
              ],
            ),
          ),
          DashSection(t('dash_quick_actions')),
          DashGrid(children: [
            tile(ArcIcon.review, '${_paymentRequests.length}',
                t('payment_requests'), const Color(0xFFE0A030),
                () => go(_TView.payments),
                alert: _paymentRequests.isNotEmpty),
            tile(ArcIcon.courses, '${_myCourses.length}', t('stat_courses'),
                AppColors.teal, () => go(_TView.courses)),
            tile(ArcIcon.users, '$_statStudents', t('stat_students'),
                AppColors.byline, () => go(_TView.courses)),
            tile(ArcIcon.money, '$_statEarnings', t('stat_earnings'),
                AppColors.red, () => go(_TView.courses)),
            tile(ArcIcon.wallet, paymentSet ? '✓' : '—',
                t('settings_payment_info'), AppColors.teal,
                () => go(_TView.profile),
                alert: !paymentSet),
          ]),
          const SizedBox(height: 16),
          FadeSlideIn(
            delayMs: delay + 40,
            child: DashButton(t('create_course'),
                primary: true, icon: ArcIcon.plus, onPressed: _openNewCourse),
          ),
        ],
      ),
    );
  }

  Widget _buildCourses(String Function(String) t) {
    return RefreshIndicator(
      onRefresh: _loadCourses,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          DashButton(t('create_course'),
              primary: true, icon: ArcIcon.plus, onPressed: _openNewCourse),
          const SizedBox(height: 12),
          if (_myCourses.isEmpty)
            DashEmpty(icon: ArcIcon.courses, message: t('no_courses_teacher'))
          else
            for (var i = 0; i < _myCourses.length; i++) ...[
              FadeSlideIn(
                delayMs: (i % 10) * 30,
                child: _CourseCard(
                  course: _myCourses[i],
                  t: t,
                  onEdit: () => _openCourseEdit(_myCourses[i]),
                  onCurriculum: () => _openCurriculum(_myCourses[i]),
                  onCodes: () => _openCodes(_myCourses[i]),
                  onSubmit: _myCourses[i]['status'] == 'draft'
                      ? () => _submitForReview(_myCourses[i])
                      : null,
                  onDelete: _myCourses[i]['status'] == 'published'
                      ? null
                      : () => _deleteCourse(_myCourses[i]),
                ),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _filePicker({
    required ArcIcon icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: AppColors.bg.withValues(alpha: 0.35),
          border: Border.all(color: AppColors.red.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          ArcIconView(icon, size: 22, color: AppColors.red, active: true),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 13.5, color: AppColors.text)),
          ),
          ArcIconView(ArcIcon.plus, size: 18, color: AppColors.muted2),
        ]),
      ),
    );
  }

  /// Rebuilds the point fields from [points], padded to [_minPointRows].
  void _setPoints(List<String> points) {
    for (final c in _cPoints) {
      c.dispose();
    }
    _cPoints
      ..clear()
      ..addAll(points.take(_maxPoints).map((p) => TextEditingController(text: p)));
    while (_cPoints.length < _minPointRows) {
      _cPoints.add(TextEditingController());
    }
  }

  void _addPoint() {
    if (_cPoints.length >= _maxPoints) return;
    setState(() => _cPoints.add(TextEditingController()));
  }

  void _removePoint(int i) {
    setState(() {
      if (_cPoints.length > _minPointRows) {
        _cPoints.removeAt(i).dispose();
      } else {
        _cPoints[i].clear();
      }
    });
  }

  Widget _learningPointsEditor(String Function(String) t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('what_you_learn'),
            style: AppFonts.body(size: 13.5, color: AppColors.text)),
        const SizedBox(height: 2),
        Text(t('learning_points_helper'),
            style: AppFonts.body(size: 11.5, color: AppColors.muted)),
        const SizedBox(height: 8),
        for (var i = 0; i < _cPoints.length; i++)
          Padding(
            key: ObjectKey(_cPoints[i]),
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _cPoints[i],
                  maxLength: 200,
                  textInputAction: i == _cPoints.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '${t('learning_point_n')} ${i + 1}',
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _removePoint(i),
                icon: ArcIconView(ArcIcon.close,
                    size: 18, color: AppColors.muted2),
              ),
            ]),
          ),
        if (_cPoints.length < _maxPoints)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _addPoint,
              icon: ArcIconView(ArcIcon.plus, size: 16, color: AppColors.red),
              label: Text(t('learning_point_add')),
            ),
          ),
      ],
    );
  }

  Widget _formError(String? msg) => msg == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(msg, style: AppFonts.body(size: 12, color: AppColors.error)));

  Widget _buildCourseEdit(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashFormPanel(
          title: _activeCourse != null ? t('edit_course') : t('new_course_title'),
          icon: ArcIcon.edit,
          children: [
            TextField(
                controller: _cTitle,
                decoration: InputDecoration(labelText: t('label_title'))),
            const SizedBox(height: 12),
            TextField(
                controller: _cDescription,
                maxLines: 4,
                decoration: InputDecoration(labelText: t('label_description'))),
            const SizedBox(height: 12),
            _learningPointsEditor(t),
            const SizedBox(height: 12),
            TextField(
                controller: _cPrice,
                keyboardType: TextInputType.number,
                inputFormatters: PaymentRules.numberInput,
                decoration: InputDecoration(labelText: t('label_price'))),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _cPrice,
              builder: (context, v, _) {
                final price = PaymentRules.parsePrice(v.text);
                if (price <= 0) return const SizedBox.shrink();
                final s = PaymentRules.split(price: price, paid: price);
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(
                      child: _SplitChip(
                          label: t('split_platform'),
                          value: s.platform,
                          color: AppColors.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SplitChip(
                          label: t('split_yours'),
                          value: s.teacher,
                          color: AppColors.teal),
                    ),
                  ]),
                );
              },
            ),
            const SizedBox(height: 12),
            FilePickBox(
              file: _cThumbFile,
              existingUrl: _cThumbUrl,
              emptyLabel: t('label_thumbnail'),
              onPick: () async {
                final picked = await SafePicker.image(imageQuality: 85);
                if (picked != null) setState(() => _cThumbFile = picked);
              },
              onRemove: () => setState(() => _cThumbFile = null),
            ),
            _formError(_cFormError),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                  child: ElevatedButton(
                      onPressed: _cSaving ? null : _saveCourse,
                      child: _cSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(t('save')))),
              const SizedBox(width: 10),
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => setState(() => _view = _TView.courses),
                      child: Text(t('cancel')))),
            ]),
          ],
        ),
      ],
    );
  }

  Widget _buildCurriculum(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashSection('${t('curriculum')} · ${_activeCourse?['title'] ?? ''}'),
        if (_activeLectures.isEmpty)
          DashEmpty(icon: ArcIcon.video, message: t('no_lectures_teacher'))
        else
          for (var i = 0; i < _activeLectures.length; i++) ...[
            _lectureRow(i, _activeLectures[i], t),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 14),
        DashFormPanel(
          title: t('btn_add'),
          icon: ArcIcon.video,
          children: [
            TextField(
                controller: _lTitle,
                decoration:
                    InputDecoration(labelText: t('label_lecture_title'))),
            const SizedBox(height: 12),
            FilePickBox(
              file: _lVideoFile,
              video: true,
              emptyLabel: t('label_video_file'),
              onPick: () async {
                if (_uploadBusy) return;
                final picked = await SafePicker.video();
                if (picked != null) setState(() => _lVideoFile = picked);
              },
              onRemove: _uploadBusy
                  ? null
                  : () => setState(() => _lVideoFile = null),
            ),
            const SizedBox(height: 4),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _lIsFree = !_lIsFree),
              child: Row(children: [
                Checkbox(
                    value: _lIsFree,
                    onChanged: (v) => setState(() => _lIsFree = v ?? false)),
                Expanded(
                    child: Text(t('label_free_lecture'),
                        style: AppFonts.body(size: 13, color: AppColors.muted))),
              ]),
            ),
            _formError(_lFormError),
            const SizedBox(height: 10),
            if (_lUploadProgress != null)
              Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _UploadProgressPill(
                        progress: _lUploadProgress!,
                        label: _lUploadPhase == 'prepare'
                            ? t('preparing_video')
                            : t('uploading_video')),
                    DashButton(t('btn_cancel_upload'),
                        danger: true,
                        icon: ArcIcon.close,
                        onPressed: _confirmCancelUpload),
                  ],
                ),
              )
            else
              ElevatedButton(onPressed: _addLecture, child: Text(t('btn_add'))),
          ],
        ),
      ],
    );
  }

  Widget _lectureRow(int i, Map<String, dynamic> l, String Function(String) t) {
    final live = l['r2_path'] != null;
    return DashCard(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: AppColors.bg.withValues(alpha: 0.4),
          border: Border.all(color: AppColors.line),
        ),
        alignment: Alignment.center,
        child: Text((i + 1).toString().padLeft(2, '0'),
            style: AppFonts.code(size: 14, color: AppColors.red)),
      ),
      title: l['title'] as String? ?? '—',
      titleStyle: AppFonts.body(size: 14, weight: FontWeight.w700),
      trailing: StatusPill(
          live ? t('status_live') : t('lecture_pending_review'),
          tone: live ? StatusTone.good : StatusTone.warn),
      meta: [if (l['is_free'] == true) t('free_tag')],
      metaColor: AppColors.teal,
      actions: [
        DashButton(t('btn_delete'),
            danger: true,
            icon: ArcIcon.trash,
            onPressed: () => _deleteLecture(l)),
      ],
    );
  }

  Widget _buildCodes(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashSection('${t('discount_codes')} · ${_activeCourse?['title'] ?? ''}'),
        if (_activeCodes.isEmpty)
          DashEmpty(icon: ArcIcon.tag, message: t('no_codes'))
        else
          for (final c in _activeCodes) ...[
            DashCard(
              leading: DashIconBadge(icon: ArcIcon.tag, accent: AppColors.byline),
              title: c['code'] as String? ?? '—',
              titleStyle: AppFonts.code(size: 15),
              subtitle:
                  '${c['discount_type'] == 'percent' ? '${c['discount_value']}%' : '${c['discount_value']} IQD'} · ${c['used_count']}/${c['max_uses']} ${t('codes_used')}',
              trailing: StatusPill(
                  c['is_active'] == true
                      ? t('status_active_code')
                      : t('status_inactive'),
                  tone: c['is_active'] == true
                      ? StatusTone.good
                      : StatusTone.neutral),
              actions: [
                if (c['is_active'] == true)
                  DashButton(t('btn_stop'),
                      danger: true,
                      icon: ArcIcon.close,
                      onPressed: () => _stopCode(c)),
              ],
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 14),
        DashFormPanel(
          title: t('create_code'),
          icon: ArcIcon.tag,
          children: [
            Text(t('discount_cap_hint'),
                style: AppFonts.body(size: 12, color: AppColors.muted)),
            const SizedBox(height: 12),
            TextField(
                controller: _dCode,
                textCapitalization: TextCapitalization.characters,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: t('label_code'))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _dType,
                  decoration:
                      InputDecoration(labelText: t('label_discount_type')),
                  items: [
                    DropdownMenuItem(
                        value: 'percent', child: Text(t('percent'))),
                    DropdownMenuItem(value: 'fixed', child: Text(t('fixed'))),
                  ],
                  onChanged: (v) => setState(() => _dType = v ?? 'percent'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: TextField(
                      controller: _dValue,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: t('label_discount_value')))),
            ]),
            const SizedBox(height: 12),
            TextField(
                controller: _dMaxUses,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('label_max_uses'))),
            const SizedBox(height: 12),
            _filePicker(
              icon: ArcIcon.calendar,
              label: _dExpires != null
                  ? _dExpires!.toString().split(' ').first
                  : t('label_expires'),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now().add(const Duration(days: 30)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                );
                // End of the picked day: picking today used to count as
                // already expired, and every code ended a day early.
                if (picked != null) {
                  setState(() => _dExpires = DateTime(
                      picked.year, picked.month, picked.day, 23, 59, 59));
                }
              },
            ),
            _formError(_dFormError),
            const SizedBox(height: 14),
            ElevatedButton(
                onPressed: _dSaving ? null : _addCode,
                child: Text(t('btn_add'))),
          ],
        ),
      ],
    );
  }

  Widget _buildProfile(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashFormPanel(
          title: t('my_payment_number'),
          icon: ArcIcon.wallet,
          children: [
            Text(t('payment_required_hint'),
                style: AppFonts.body(size: 12, color: AppColors.muted)),
            const SizedBox(height: 14),
            TextField(
                controller: _pZaincashPhone,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.number,
                inputFormatters: PaymentRules.numberInput,
                decoration: InputDecoration(
                    labelText: t('label_zaincash_phone'),
                    hintText: '07XX XXX XXXX')),
            const SizedBox(height: 12),
            TextField(
                controller: _pQiAccount,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.number,
                inputFormatters: PaymentRules.numberInput,
                decoration: InputDecoration(
                    labelText: t('label_qi_account'),
                    hintText: 'XXXX XXXX XXXX XXXX')),
            const SizedBox(height: 14),
            Text(t('label_qi_qr'),
                style: AppFonts.body(size: 13, weight: FontWeight.w600)),
            const SizedBox(height: 8),
            FilePickBox(
              file: _pQiQrFile,
              existingUrl: _pQiQrUrl,
              emptyLabel: t('pick_qr'),
              height: 200,
              onPick: () async {
                final picked = await SafePicker.image(imageQuality: 90);
                if (picked != null) setState(() => _pQiQrFile = picked);
              },
              onRemove: () => setState(() => _pQiQrFile = null),
            ),
            if (_pFormError != null) _formError(_pFormError),
            if (_pSavedMsg != null)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_pSavedMsg!,
                      style: AppFonts.body(size: 12, color: AppColors.teal))),
            const SizedBox(height: 18),
            if (widget.mandatoryPayment)
              ElevatedButton(
                  onPressed: _saveProfile, child: Text(t('save_and_continue')))
            else
              Row(children: [
                Expanded(
                    child: ElevatedButton(
                        onPressed: _saveProfile, child: Text(t('save')))),
                const SizedBox(width: 10),
                Expanded(
                    child: OutlinedButton(
                        onPressed: () => widget.openPaymentInfo
                            ? Navigator.of(context).pop()
                            : setState(() => _view = _TView.overview),
                        child: Text(t('discard')))),
              ]),
            if (!widget.mandatoryPayment &&
                (_pZaincashPhone.text.trim().isNotEmpty ||
                _pQiAccount.text.trim().isNotEmpty ||
                _pQiQrUrl != null)) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: _deletePaymentMethod,
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                child: Text(t('delete_payment_method')),
              ),
            ],
          ],
        ),
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
  final VoidCallback? onDelete;

  const _CourseCard({
    required this.course,
    required this.t,
    required this.onEdit,
    required this.onCurriculum,
    required this.onCodes,
    required this.onSubmit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final status = course['status'] as String? ?? 'draft';
    final tone = switch (status) {
      'published' => StatusTone.good,
      'pending' || 'pending_review' => StatusTone.warn,
      'rejected' => StatusTone.bad,
      _ => StatusTone.neutral,
    };
    return DashCard(
      leading: SizedBox(
        width: 74,
        height: 56,
        child: CourseThumb(url: course['thumbnail_url'] as String?, radius: 12),
      ),
      title: course['title'] as String? ?? '—',
      subtitle: course['is_free'] == true
          ? t('card_free')
          : '${course['price'] ?? '—'}',
      trailing: StatusPill(t('status_$status'), tone: tone),
      extra: [
        if (course['edit_status'] == 'pending_review') ...[
          const SizedBox(height: 10),
          StatusPill(t('edit_pending'), tone: StatusTone.warn),
        ] else if (course['edit_status'] == 'rejected' &&
            (course['edit_reject_reason'] as String?)?.isNotEmpty == true) ...[
          const SizedBox(height: 10),
          Text('${t('edit_rejected')}: ${course['edit_reject_reason']}',
              style: AppFonts.body(size: 12, color: AppColors.error)),
        ],
      ],
      actions: [
        if (onSubmit != null)
          DashButton(t('submit_for_review'),
              primary: true, icon: ArcIcon.check, onPressed: onSubmit),
        if (onEdit != null)
          DashButton(t('btn_edit'), icon: ArcIcon.edit, onPressed: onEdit),
        DashButton(t('btn_curriculum'),
            icon: ArcIcon.video, onPressed: onCurriculum),
        DashButton(t('btn_codes'), icon: ArcIcon.tag, onPressed: onCodes),
        if (onDelete != null)
          DashButton(t('btn_delete'),
              danger: true, icon: ArcIcon.trash, onPressed: onDelete),
      ],
    );
  }
}

/// Glass pill with a circular progress ring + percentage, shown in place of
/// the Add button while a lecture video is uploading.
class _UploadProgressPill extends StatelessWidget {
  final double progress;
  final String label;
  const _UploadProgressPill({required this.progress, required this.label});

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 22, 12),
          decoration: BoxDecoration(
            color: AppColors.glassBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 18,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3.5,
                  backgroundColor: AppColors.line,
                  valueColor: AlwaysStoppedAnimation(AppColors.teal),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$pct%',
                      style: AppFonts.heading(size: 20, color: AppColors.teal)),
                  Text(label,
                      style: AppFonts.body(size: 12, color: AppColors.muted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Platform 20%: 2,000" / "Your share: 8,000" under the price field.
class _SplitChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _SplitChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppFonts.body(size: 11, color: AppColors.muted)),
          const SizedBox(height: 2),
          Text('$value IQD', style: AppFonts.code(size: 14, color: color)),
        ],
      ),
    );
  }
}
