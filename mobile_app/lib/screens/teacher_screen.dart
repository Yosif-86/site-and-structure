import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../i18n/strings.dart';
import '../services/live_refresh.dart';
import '../services/money.dart';
import '../services/notification_service.dart';
import '../services/payment_rules.dart';
import '../services/upload_manager.dart';
import '../services/safe_picker.dart';
import '../services/bidi.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/arc_icons.dart';
import '../widgets/course_card.dart';
import '../widgets/course_reviews_sheet.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/file_preview.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/payment_requests.dart';
import '../widgets/proof_viewer.dart';
import 'course_files.dart';

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

  /// Opens straight on this course's editor (from the course page's Edit
  /// button); leaving the editor closes the screen.
  final String? editCourseId;

  /// With [editCourseId]: scroll the course page down to the curriculum card
  /// (the add-lecture shortcut).
  final bool focusCurriculum;

  const TeacherScreen(
      {super.key,
      this.openPaymentInfo = false,
      this.mandatoryPayment = false,
      this.openView,
      this.editCourseId,
      this.focusCurriculum = false});

  @override
  State<TeacherScreen> createState() => _TeacherScreenState();
}

enum _TView { overview, courses, courseEdit, curriculum, codes, profile, payments, attention, students, courseStudents, earnings, freeRequests }

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
  // Every enrollment in this teacher's courses, newest first.
  List<Map<String, dynamic>> _teacherRows = [];

  Future<void> _loadPaymentRequests() async {
    try {
      final rows = await SupabaseService.instance.client
          .rpc('get_teacher_students') as List;
      if (!mounted) return;
      final all = rows.cast<Map<String, dynamic>>();
      setState(() {
        _teacherRows = all;
        _paymentRequests = all
            .where((r) => r['status'] != 'active' && r['pay_to_teacher'] == true)
            .toList();
      });
    } catch (_) {
      // Leaves the list as it was; the overview tile just shows 0.
    }
  }

  /// Free-enrollment requests an admin sent for this teacher's courses
  /// (add-free-enrollment-requests.sql). Empty until that migration runs.
  List<Map<String, dynamic>> _freeRequests = [];

  Future<void> _loadFreeRequests() async {
    try {
      final rows = await SupabaseService.instance.client
          .rpc('get_free_enrollment_requests') as List;
      if (!mounted) return;
      // The RPC also returns every request to an admin; here only the ones
      // this teacher can decide (approving someone else's would fail).
      final me = SupabaseService.instance.currentUser?.id;
      setState(() => _freeRequests = rows
          .cast<Map<String, dynamic>>()
          .where((r) => r['teacher_id'] == me)
          .toList());
    } catch (_) {
      // Leaves the list as it was.
    }
  }

  Future<void> _decideFree(Map<String, dynamic> r, bool approve) async {
    final t = AppStrings.instance.t;
    final id = r['id'] as String;
    if (_decidingFree.contains(id)) return;
    String? reason;
    if (approve) {
      final ok = await _confirm(
          t('free_add_confirm_approve')
              .replaceAll('{name}', Bidi.iso((r['student_name'] as String?) ?? '—'))
              .replaceAll(
                  '{course}', Bidi.iso((r['course_title'] as String?) ?? '—')),
          confirmLabel: t('btn_confirm'),
          danger: false);
      if (!ok) return;
    } else {
      reason = await askRejectReason(context,
          title: t('free_add_reject'), sub: t('free_add_reason'), presets: []);
      if (reason == null) return;
    }
    setState(() => _decidingFree.add(id));
    try {
      await SupabaseService.instance.client.rpc('teacher_decide_free_enrollment',
          params: {
            'p_request_id': id,
            'p_approve': approve,
            'p_reason': reason,
          });
      _showError(
          t(approve ? 'free_add_approved_done' : 'free_add_rejected_done'));
      await _loadFreeRequests();
      await _loadPaymentRequests();
      await _loadCourses();
    } catch (e) {
      final gone = e.toString().contains('no longer waiting');
      _showError(t(gone ? 'free_add_err_gone' : 'err_generic_failed'));
      await _loadFreeRequests();
    } finally {
      if (mounted) setState(() => _decidingFree.remove(id));
    }
  }

  final Set<String> _decidingFree = {};

  Widget _buildFreeRequests(String Function(String) t) {
    String status(String s) => switch (s) {
          'approved' => t('free_add_approved'),
          'rejected' => t('free_add_rejected'),
          'cancelled' => t('free_add_cancelled'),
          _ => t('free_add_pending'),
        };
    StatusTone tone(String s) => switch (s) {
          'approved' => StatusTone.good,
          'rejected' => StatusTone.bad,
          'cancelled' => StatusTone.neutral,
          _ => StatusTone.warn,
        };
    return RefreshIndicator(
      onRefresh: _loadFreeRequests,
      child: _freeRequests.isEmpty
          ? ListView(children: [
              DashEmpty(icon: ArcIcon.users, message: t('free_add_none'))
            ])
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: _freeRequests.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final r = _freeRequests[i];
                final pending = r['status'] == 'pending';
                final created =
                    DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal();
                return FadeSlideIn(
                  delayMs: (i % 10) * 30,
                  child: DashCard(
                    leading: DashAvatar(name: r['student_name'] as String?),
                    title: (r['student_name'] as String?) ?? '—',
                    subtitle: r['course_title'] as String?,
                    trailing: StatusPill(status('${r['status']}'),
                        tone: tone('${r['status']}')),
                    meta: [
                      if (r['student_public_id'] != null)
                        '#${r['student_public_id']}',
                      '${t('free_add_by')}: ${r['requested_by_name'] ?? '—'}'
                          '${created == null ? '' : ' · ${created.toString().substring(0, 16)}'}',
                      if (r['status'] == 'rejected' &&
                          ((r['reject_reason'] as String?)?.isNotEmpty ?? false))
                        '${t('free_add_reason')}: ${r['reject_reason']}',
                    ],
                    actions: [
                      if (pending) ...[
                        DashButton(t('free_add_approve'),
                            primary: true,
                            icon: ArcIcon.check,
                            onPressed: _decidingFree.contains(r['id'])
                                ? null
                                : () => _decideFree(r, true)),
                        DashButton(t('free_add_reject'),
                            danger: true,
                            icon: ArcIcon.close,
                            onPressed: _decidingFree.contains(r['id'])
                                ? null
                                : () => _decideFree(r, false)),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  ({int price, int discount, int paid}) _amountsOf(Map<String, dynamic> r) {
    final price =
        (r['list_price'] as num?)?.toInt() ?? Money.digitsOf(r['course_price']) ?? 0;
    final paid = (r['amount_paid'] as num?)?.toInt() ?? price;
    final discount =
        (r['discount_amount'] as num?)?.toInt() ?? (price > paid ? price - paid : 0);
    return (price: price, discount: discount, paid: paid);
  }

  Future<void> _approvePayment(String id) async {
    final t = AppStrings.instance.t;
    final row = _paymentRequests.firstWhere((r) => r['enrollment_id'] == id,
        orElse: () => const {});
    final a = _amountsOf(row);
    final ok = await _confirm(
        t('confirm_approve_payment')
            .replaceAll(
                '{name}',
                Bidi.iso((row['full_name'] as String?) ??
                    (row['email'] as String?) ??
                    '—'))
            .replaceAll('{course}',
                Bidi.iso((row['course_title'] as String?) ?? '—'))
            .replaceAll(
                '{price}',
                Money.paymentSummary(t,
                    price: a.price, discount: a.discount, paid: a.paid)),
        confirmLabel: t('btn_confirm'),
        danger: false);
    if (!ok) return;
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
                    price: r['course_price']?.toString(),
                    discount: _amountsOf(r).discount,
                    paid: _amountsOf(r).paid,
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

  /// Bumped when a point row is added or removed so the open editor sheet
  /// rebuilds.
  final ValueNotifier<int> _pointsTick = ValueNotifier(0);
  final GlobalKey _curriculumKey = GlobalKey();
  // Which step of the course editor timeline is open (-1 = all closed).
  int _openStep = 0;

  /// This teacher's platform share as a fraction; set by the admin.
  double _myRate = PaymentRules.platformRate;
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
  // Chapters of the open course and the one the next upload goes into.
  List<Map<String, dynamic>> _activeChapters = [];
  String? _lChapterId;
  bool get _chaptersOn => _activeCourse?['uses_chapters'] == true;

  Future<void> _setChaptersOn(bool on) async {
    final id = _activeCourse?['id'];
    if (id == null) return;
    try {
      await SupabaseService.instance.client
          .from('courses')
          .update({'uses_chapters': on}).eq('id', id);
      if (!mounted) return;
      setState(() {
        _activeCourse = {..._activeCourse!, 'uses_chapters': on};
        if (!on) _lChapterId = null;
      });
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }
  String? _lFormError;
  // Reading the picked video's length before handing it to the uploader.
  bool _lPreparing = false;

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
  // Course students list: search by account number or name.
  final _studentSearch = TextEditingController();
  String _studentQ = '';
  final _pQiAccount = TextEditingController();
  String? _pQiQrUrl;
  XFile? _pQiQrFile;
  String? _pFormError;
  String? _pSavedMsg;

  // Approvals, new payment requests and published lectures show up live.
  late final _live = LiveRefresh(
    tables: const [
      'enrollments',
      'courses',
      'lectures',
      'free_enrollment_requests'
    ],
    onChange: () async {
      if (!_isTeacher) return;
      await _loadCourses();
      await _loadPaymentRequests();
      await _loadFreeRequests();
      if ((_view == _TView.courseEdit || _view == _TView.curriculum) &&
          _activeCourse != null) {
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
    _pointsTick.dispose();
    for (final c in _cPoints) {
      c.dispose();
    }
    _lTitle.dispose();
    _dCode.dispose();
    _dValue.dispose();
    _dMaxUses.dispose();
    _pZaincashPhone.dispose();
    _studentSearch.dispose();
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
        if (isTeacher && widget.openView == 'freeRequests') {
          _view = _TView.freeRequests;
        }
      });
      if (isTeacher) {
        await _loadCourses();
        final editId = widget.editCourseId;
        if (editId != null && mounted) {
          final c = _myCourses.where((c) => c['id'] == editId).firstOrNull;
          if (c != null) {
            _openCourseEdit(c);
          } else if (mounted) {
            Navigator.of(context).pop();
            return;
          }
        }
        await _loadProfile();
        await _loadPaymentRequests();
        await _loadFreeRequests();
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
    _openStep = 0;
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
    _cPrice.text = Money.group(Money.digitsOf(src['price']) ?? 0);
    _setPoints(((src['learning_points'] as List?) ?? const [])
        .whereType<String>()
        .toList());
    _cThumbUrl = src['thumbnail_url'] as String?;
    _cThumbFile = null;
    _cFormError = null;
    _lTitle.clear();
    _lVideoFile = null;
    _lIsFree = false;
    _lFormError = null;
    _openStep = widget.focusCurriculum && widget.editCourseId == c['id'] ? 1 : 0;
    setState(() => _view = _TView.courseEdit);
    _loadLectures();
    if (widget.focusCurriculum && widget.editCourseId == c['id']) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _curriculumKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut);
        }
      });
    }
  }

  /// Leaves the course editor: back to the course list, or out of the screen
  /// when it was opened straight from a course page.
  void _leaveEditor() {
    if (widget.editCourseId != null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _view = _TView.courses);
    }
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
    Map<String, dynamic>? created;
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
        created = await sb.from('courses').insert({
          'slug': slug,
          'title': title,
          'description': description,
          'price': price,
          'is_free': price == 0,
          'thumbnail_url': thumbnailUrl,
          if (learningPoints.isNotEmpty) 'learning_points': learningPoints,
          'teacher_id': user.id,
          'status': 'draft',
        }).select().single();
      }
      await _loadCourses();
      if (!mounted) return;
      if (created != null) {
        // New course: keep going, the lectures step is next.
        setState(() {
          _activeCourse = created;
          _openStep = 1;
        });
        _loadLectures();
        return;
      }
      _leaveEditor();
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
            .replaceAll('{title}', Bidi.iso(c['title'] as String?)),
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
    final title = c['title'] as String? ?? '';
    // A course with paying students gets a much stronger warning.
    var students = 0;
    if (c['status'] == 'published') {
      try {
        final rows = await SupabaseService.instance.client
            .rpc('get_teacher_students') as List;
        students = rows
            .cast<Map<String, dynamic>>()
            .where((r) =>
                r['course_slug'] == c['slug'] && r['status'] == 'active')
            .length;
      } catch (_) {}
    }
    final confirmed = await _confirm(
        (students > 0
                ? t('confirm_delete_course_students')
                    .replaceAll('{n}', '$students')
                : t('confirm_delete_course'))
            .replaceAll('{title}', Bidi.iso(title)));
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

  Future<void> _loadLectures() async {
    try {
      final data = await SupabaseService.instance.client
          .from('lectures')
          .select('*')
          .eq('course_id', _activeCourse!['id'])
          .order('order_index')
          .order('created_at');
      var chapters = <Map<String, dynamic>>[];
      try {
        final rows = await SupabaseService.instance.client
            .from('course_chapters')
            .select('*')
            .eq('course_id', _activeCourse!['id'])
            .order('order_index')
            .order('created_at');
        chapters = (rows as List).cast<Map<String, dynamic>>();
      } catch (_) {
        // Chapters not set up yet: the course just has none.
      }
      if (!mounted) return;
      setState(() {
        _activeLectures = (data as List).cast<Map<String, dynamic>>();
        _activeChapters = chapters;
        if (!chapters.any((c) => c['id'] == _lChapterId)) _lChapterId = null;
      });
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  // ---- Chapters ----

  /// A one-field dialog; null when cancelled or left empty.
  Future<String?> _askName(String label, {String initial = ''}) async {
    final t = AppStrings.instance.t;
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 120,
            decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t('cancel'))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: Text(t('save'))),
        ],
      ),
    );
    ctrl.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  /// Asks for a name and adds the chapter at the end; returns its id.
  Future<String?> _createChapter() async {
    final t = AppStrings.instance.t;
    final name = await _askName(t('chapter_name_label'));
    if (name == null) return null;
    try {
      final next = _activeChapters.isEmpty
          ? 0
          : _activeChapters
                  .map((c) => (c['order_index'] as num?)?.toInt() ?? 0)
                  .reduce((a, b) => a > b ? a : b) +
              1;
      final row = await SupabaseService.instance.client
          .from('course_chapters')
          .insert({
            'course_id': _activeCourse!['id'],
            'title': name,
            'order_index': next,
          })
          .select()
          .single();
      await _loadLectures();
      return row['id'] as String?;
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
      return null;
    }
  }

  Future<void> _renameChapter(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final name = await _askName(t('chapter_name_label'),
        initial: c['title'] as String? ?? '');
    if (name == null || name == c['title']) return;
    try {
      await SupabaseService.instance.client
          .from('course_chapters')
          .update({'title': name}).eq('id', c['id']);
      await _loadLectures();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  Future<void> _deleteChapter(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final ok = await _confirm(t('confirm_delete_chapter')
        .replaceAll('{title}', Bidi.iso(c['title'] as String?)));
    if (!ok) return;
    try {
      await SupabaseService.instance.client
          .from('course_chapters')
          .delete()
          .eq('id', c['id']);
      await _loadLectures();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  /// Picks a chapter (or none) for an existing lecture.
  Future<void> _moveToChapter(Map<String, dynamic> l) async {
    final t = AppStrings.instance.t;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassSheet(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(t('chapter_none')),
              trailing: l['chapter_id'] == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(ctx).pop('')),
          for (final c in _activeChapters)
            ListTile(
                title: Text(c['title'] as String? ?? ''),
                trailing: l['chapter_id'] == c['id']
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(ctx).pop(c['id'] as String)),
        ]),
      ),
    );
    if (picked == null) return;
    try {
      await SupabaseService.instance.client
          .from('lectures')
          .update({'chapter_id': picked.isEmpty ? null : picked}).eq(
              'id', l['id']);
      await _loadLectures();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
    }
  }

  bool _reordering = false;

  /// Moves a lecture one place up (-1) or down (+1) and saves the new order.
  /// Every lecture is renumbered 0..n-1, which also fixes equal positions.
  Future<void> _moveLecture(int i, int delta) async {
    final j = i + delta;
    if (_reordering || j < 0 || j >= _activeLectures.length) return;
    _reordering = true;
    final list = [..._activeLectures];
    final moved = list.removeAt(i);
    list.insert(j, moved);
    setState(() => _activeLectures = [
          for (var k = 0; k < list.length; k++) {...list[k], 'order_index': k}
        ]);
    try {
      final sb = SupabaseService.instance.client;
      for (var k = 0; k < list.length; k++) {
        // `list` still holds the rows as stored, so this skips only rows
        // already saved at position k.
        if (list[k]['order_index'] == k) continue;
        await sb
            .from('lectures')
            .update({'order_index': k}).eq('id', list[k]['id']);
      }
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'teacher'));
      await _loadLectures();
    } finally {
      _reordering = false;
    }
  }

  Future<void> _addLecture() async {
    if (_lPreparing) return;
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
    setState(() => _lPreparing = true);
    // Runtime off the local file so it shows on the course page from the
    // start.
    final file = File(_lVideoFile!.path);
    final info = await _readVideoInfo(file);
    if (!mounted) return;
    UploadManager.instance.start(LectureUploadJob(
      lectureId: const Uuid().v4(),
      courseId: _activeCourse!['id'] as String,
      courseTitle: _activeCourse!['title'] as String? ?? '',
      title: title,
      isFree: _lIsFree,
      durationSeconds: info.seconds,
      file: file,
      chapterId: _chaptersOn ? _lChapterId : null,
    ));
    setState(() {
      _lPreparing = false;
      _lTitle.clear();
      _lVideoFile = null;
      _lIsFree = false;
    });
    _showError(t('upload_started'));
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
            .replaceAll('{title}', Bidi.iso(l['title'] as String?)));
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

  // ---- Students of one course ----

  void _openCourseStudents(Map<String, dynamic> c) {
    _activeCourse = c;
    _studentSearch.clear();
    _studentQ = '';
    setState(() => _view = _TView.courseStudents);
    _loadPaymentRequests();
  }

  Future<void> _removeStudent(Map<String, dynamic> row) async {
    final t = AppStrings.instance.t;
    final id = row['enrollment_id'];
    if (id == null) return;
    final name = (row['full_name'] as String?) ?? (row['email'] as String?) ?? '—';
    final ok = await _confirm(
        t('remove_student_confirm')
            .replaceAll('{name}', Bidi.iso(name))
            .replaceAll('{course}', Bidi.iso((row['course_title'] as String?) ?? '—')),
        confirmLabel: t('btn_remove_student'));
    if (!ok) return;
    try {
      await SupabaseService.instance.client
          .rpc('teacher_remove_student', params: {'p_enrollment_id': id});
      _showError(t('student_removed'));
      await _loadPaymentRequests();
      await _loadCourses();
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
    final maxShare = PaymentRules.maxDiscountFor(_myRate);
    final tooBig = _dType == 'percent'
        ? value > maxShare * 100
        : price > 0 && value > price * maxShare;
    if (tooBig) {
      setState(() => _dFormError = _capText(t('err_discount_too_large')));
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
        .replaceAll('{code}', Bidi.iso(c['code'] as String?)));
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
              'teacher_zaincash_phone, teacher_qi_account_number, teacher_qi_qr_url, platform_rate')
          .eq('id', user.id)
          .maybeSingle();
      if (prof == null || !mounted) return;
      setState(() {
        _myRate = PaymentRules.rateFrom(prof['platform_rate']);
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

  /// Uploads now run in the background, so leaving a view never needs
  /// confirming.
  Future<bool> _confirmCancelUpload() async => true;

  /// Back from a sub-view: one level up, or out of the screen. Used by the
  /// system back button and the edge swipe.
  Future<void> _handleBack() async {
    if (widget.mandatoryPayment) return;
    if (!await _confirmCancelUpload() || !mounted) return;
    if (_view == _TView.courseEdit && widget.editCourseId != null) {
      Navigator.of(context).pop();
      return;
    }
    if (_view != _TView.overview && !widget.openPaymentInfo) {
      setState(() => _view = (_view == _TView.curriculum ||
              _view == _TView.codes ||
              _view == _TView.courseStudents ||
              _view == _TView.courseEdit)
          ? _TView.courses
          : _TView.overview);
    } else {
      Navigator.of(context).pop();
    }
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
                        if (_view == _TView.courseEdit &&
                            widget.editCourseId != null) {
                          if (mounted) Navigator.of(context).pop();
                          return;
                        }
                        setState(() => _view = (_view == _TView.curriculum ||
                                _view == _TView.codes ||
                                _view == _TView.courseStudents ||
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
        body: EdgeSwipeBack(
          // The route's own swipe-back is off in a sub-view (PopScope below),
          // so the edge swipe does the same as the top arrow.
          enabled: !widget.mandatoryPayment &&
              !(_view == _TView.overview || widget.openPaymentInfo),
          onBack: _handleBack,
          child: PopScope(
            // System back: blocked during the mandatory payment step.
            // Inside a sub-view, back steps up one level (like the AppBar
            // arrow) instead of closing the whole dashboard.
            canPop: !widget.mandatoryPayment &&
                (_view == _TView.overview || widget.openPaymentInfo),
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _handleBack();
            },
            child: _buildBody(t),
          ),
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
      _TView.curriculum => _buildCourseEdit(t),
      _TView.codes => _buildCodes(t),
      _TView.payments => _buildPayments(t),
      _TView.attention => _buildAttention(t),
      _TView.students => _buildStudents(t),
      _TView.courseStudents => _buildCourseStudents(t),
      _TView.earnings => _buildEarnings(t),
      _TView.freeRequests => _buildFreeRequests(t),
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
        await _loadFreeRequests();
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
                (Money.iqd(_statEarnings), t('stat_earnings')),
                ('${_attentionCount(paymentSet)}', t('dash_needs_attention')),
              ],
              statTaps: [
                () => go(_TView.courses),
                () => go(_TView.students),
                () => go(_TView.earnings),
                () => go(_TView.attention),
              ],
            ),
          ),
          DashSection(t('dash_quick_actions')),
          DashGrid(children: [
            tile(ArcIcon.review, '${_paymentRequests.length}',
                t('payment_requests'), const Color(0xFFE0A030),
                () => go(_TView.payments),
                alert: _paymentRequests.isNotEmpty),
            tile(
                ArcIcon.users,
                '${_freeRequests.where((r) => r['status'] == 'pending').length}',
                t('free_add_requests'),
                AppColors.teal,
                () => go(_TView.freeRequests),
                alert: _freeRequests.any((r) => r['status'] == 'pending')),
            tile(ArcIcon.courses, '${_myCourses.length}', t('stat_courses'),
                AppColors.teal, () => go(_TView.courses)),
            tile(ArcIcon.users, '$_statStudents', t('stat_students'),
                AppColors.byline, () => go(_TView.students)),
            tile(ArcIcon.money, Money.iqd(_statEarnings), t('stat_earnings'),
                AppColors.red, () => go(_TView.earnings)),
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
                  onCodes: () => _openCodes(_myCourses[i]),
                  onStudents: () => _openCourseStudents(_myCourses[i]),
                  onReviews: () => showCourseReviews(context,
                      courseId: _myCourses[i]['id'] as String,
                      title: _myCourses[i]['title'] as String?),
                  onSubmit: _myCourses[i]['status'] == 'draft'
                      ? () => _submitForReview(_myCourses[i])
                      : null,
                  onDelete: () => _deleteCourse(_myCourses[i]),
                ),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  String _when(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    return d == null ? '—' : d.toString().substring(0, 16);
  }

  /// Every student in this teacher's courses, newest first, with what each
  /// one paid.
  Widget _buildStudents(String Function(String) t) {
    final rows = _teacherRows;
    final distinct = {
      for (final r in rows) (r['email'] ?? r['phone'] ?? r['enrollment_id'])
    }.length;
    return RefreshIndicator(
      onRefresh: _loadPaymentRequests,
      child: rows.isEmpty
          ? ListView(children: [
              DashEmpty(icon: ArcIcon.users, message: t('no_students'))
            ])
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                DashSection('${t('stat_students')} ($distinct)'),
                for (var i = 0; i < rows.length; i++) ...[
                  FadeSlideIn(
                    delayMs: (i % 10) * 30,
                    child: Builder(builder: (context) {
                      final r = rows[i];
                      final active = r['status'] == 'active';
                      final name = (r['full_name'] as String?) ??
                          (r['email'] as String?) ??
                          '—';
                      return DashCard(
                        leading: DashAvatar(name: name),
                        title: name,
                        subtitle: r['course_title'] as String? ?? '—',
                        trailing: StatusPill(
                            active ? t('status_active') : t('status_pending'),
                            tone: active ? StatusTone.good : StatusTone.warn),
                        meta: [
                          [r['email'], r['phone']]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · '),
                          '${_when(r['created_at'])} · ${Money.iqd(_amountsOf(r).paid)}',
                        ].where((s) => s.isNotEmpty).toList(),
                      );
                    }),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
    );
  }

  /// Students enrolled in the one course the teacher opened: name, account
  /// number, date, price paid, and a button to remove the student.
  Widget _buildCourseStudents(String Function(String) t) {
    final slug = _activeCourse?['slug'];
    final all = _teacherRows.where((r) => r['course_slug'] == slug).toList();
    // "#2274", "2274" or part of the name.
    final q = _studentQ.replaceAll('#', '').trim().toLowerCase();
    final rows = q.isEmpty
        ? all
        : all.where((r) {
            final pid = '${r['public_id'] ?? ''}';
            final name = '${r['full_name'] ?? ''}'.toLowerCase();
            return pid.contains(q) || name.contains(q);
          }).toList();
    // An exact account number goes first.
    if (q.isNotEmpty) {
      final exact = rows.where((r) => '${r['public_id']}' == q).toList();
      rows
        ..removeWhere((r) => '${r['public_id']}' == q)
        ..insertAll(0, exact);
    }
    return RefreshIndicator(
      onRefresh: _loadPaymentRequests,
      child: all.isEmpty
          ? ListView(children: [
              DashEmpty(icon: ArcIcon.users, message: t('no_students'))
            ])
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                DashSection(
                    '${_activeCourse?['title'] ?? ''} · ${t('stat_students')} (${all.length})'),
                TextField(
                  controller: _studentSearch,
                  onChanged: (v) => setState(() => _studentQ = v),
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: t('student_search_hint'),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(12),
                      child: ArcIconView(ArcIcon.search,
                          size: 18, color: AppColors.muted2),
                    ),
                    suffixIcon: _studentQ.isEmpty
                        ? null
                        : IconButton(
                            icon: ArcIconView(ArcIcon.close,
                                size: 16, color: AppColors.muted2),
                            onPressed: () => setState(() {
                                  _studentSearch.clear();
                                  _studentQ = '';
                                })),
                  ),
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  DashEmpty(
                      icon: ArcIcon.search, message: t('explore_no_results')),
                for (var i = 0; i < rows.length; i++) ...[
                  FadeSlideIn(
                    delayMs: (i % 10) * 30,
                    child: Builder(builder: (context) {
                      final r = rows[i];
                      final active = r['status'] == 'active';
                      final name = (r['full_name'] as String?) ??
                          (r['email'] as String?) ??
                          '—';
                      final pid = (r['public_id'] as String?) ?? '—';
                      return DashCard(
                        leading: DashAvatar(name: name),
                        title: name,
                        subtitle: '${t('student_account_no')} #$pid',
                        trailing: StatusPill(
                            active ? t('status_active') : t('status_pending'),
                            tone: active ? StatusTone.good : StatusTone.warn),
                        meta: [
                          '${_when(r['created_at'])} · ${Money.iqd(_amountsOf(r).paid)}',
                        ],
                        actions: [
                          DashButton(t('btn_remove_student'),
                              danger: true,
                              icon: ArcIcon.trash,
                              onPressed: () => _removeStudent(r)),
                        ],
                      );
                    }),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
    );
  }

  /// Fills {max}, {cut}, {mine} and {pct} in a rate-dependent message.
  String _capText(String s) => s
      .replaceAll('{max}', PaymentRules.pct(PaymentRules.maxDiscountFor(_myRate)))
      .replaceAll('{cut}', PaymentRules.pct(_myRate))
      .replaceAll('{mine}', PaymentRules.pct(1 - _myRate));

  /// Totals, then each course with every payment: date, student, price,
  /// discount, amount paid and this teacher's share.
  Widget _buildEarnings(String Function(String) t) {
    final active = _teacherRows.where((r) => r['status'] == 'active').toList();
    // Share per enrollment: the platform keeps this teacher's share of the full price (never
    // more than was paid); a direct-payment course is the teacher's in full.
    ({int platform, int mine}) share(Map<String, dynamic> r) {
      final a = _amountsOf(r);
      if (r['pay_to_teacher'] == true) return (platform: 0, mine: a.paid);
      final cut = PaymentRules.split(
              price: a.price, paid: a.paid, rate: _myRate)
          .platform;
      final platform = cut > a.paid ? a.paid : cut;
      return (platform: platform, mine: a.paid - platform);
    }

    var collected = 0, platform = 0, mine = 0;
    final byCourse = <String, List<Map<String, dynamic>>>{};
    for (final r in active) {
      final s = share(r);
      collected += _amountsOf(r).paid;
      platform += s.platform;
      mine += s.mine;
      byCourse.putIfAbsent('${r['course_slug']}', () => []).add(r);
    }
    return RefreshIndicator(
      onRefresh: _loadPaymentRequests,
      child: active.isEmpty
          ? ListView(children: [
              DashEmpty(icon: ArcIcon.money, message: t('earnings_none'))
            ])
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                DashHero(
                  title: t('stat_earnings'),
                  subtitle: t('earnings_sub'),
                  stats: [
                    (Money.iqd(collected), t('rev_collected')),
                    (Money.iqd(platform), t('rev_platform_cut')),
                    (Money.iqd(mine), t('earnings_yours')),
                  ],
                ),
                for (final entry in byCourse.entries) ...[
                  DashSection(
                      '${entry.value.first['course_title'] ?? '—'} (${entry.value.length})'),
                  DashCard(
                    leading: DashIconBadge(
                        icon: ArcIcon.money, accent: AppColors.teal),
                    title: t('earnings_course_total'),
                    trailing: Text(
                        Money.iqd(entry.value
                            .fold<int>(0, (s, r) => s + share(r).mine)),
                        style: AppFonts.code(size: 15, color: AppColors.teal)),
                  ),
                  const SizedBox(height: 10),
                  for (final r in entry.value) ...[
                    Builder(builder: (context) {
                      final a = _amountsOf(r);
                      final s = share(r);
                      final name = (r['full_name'] as String?) ??
                          (r['email'] as String?) ??
                          '—';
                      return DashCard(
                        leading: DashAvatar(name: name),
                        title: name,
                        subtitle: _when(r['created_at']),
                        trailing: Text(Money.iqd(s.mine),
                            style:
                                AppFonts.code(size: 14, color: AppColors.teal)),
                        meta: [
                          '${t('pay_lbl_price')}: ${Money.iqd(a.price)}',
                          if (a.discount > 0)
                            '${t('pay_lbl_discount')}: -${Money.iqd(a.discount)}',
                          '${t('pay_lbl_paid')}: ${Money.iqd(a.paid)}',
                          if (s.platform > 0)
                            '${t('rev_platform_cut')}: ${Money.iqd(s.platform)}',
                        ],
                      );
                    }),
                    const SizedBox(height: 8),
                  ],
                ],
              ],
            ),
    );
  }

  List<Map<String, dynamic>> get _rejectedEdits => _myCourses
      .where((c) => c['edit_status'] == 'rejected')
      .toList();
  List<Map<String, dynamic>> get _drafts =>
      _myCourses.where((c) => c['status'] == 'draft').toList();
  // Rejected lectures are deleted; their unread notification is the record.
  List<AppNotification> get _rejectedLectures => NotificationService
      .instance.items
      .where((n) => n.type == 'lecture_rejected' && !n.read)
      .toList();

  int _attentionCount(bool paymentSet) =>
      _paymentRequests.length +
      _rejectedEdits.length +
      _drafts.length +
      _rejectedLectures.length +
      (paymentSet ? 0 : 1);

  /// Everything waiting on the teacher, in one list.
  Widget _buildAttention(String Function(String) t) {
    final paymentSet = _pZaincashPhone.text.trim().isNotEmpty ||
        _pQiAccount.text.trim().isNotEmpty ||
        _pQiQrUrl != null;
    if (_attentionCount(paymentSet) == 0) {
      return ListView(children: [
        DashEmpty(icon: ArcIcon.check, message: t('attention_none'))
      ]);
    }
    Widget item(ArcIcon icon, Color accent, String title, String sub,
            String pill, VoidCallback onTap) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DashCard(
            leading: DashIconBadge(icon: icon, accent: accent),
            title: title,
            subtitle: sub,
            trailing: StatusPill(pill, tone: StatusTone.warn),
            onTap: onTap,
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (!paymentSet) ...[
          DashSection(t('settings_payment_info')),
          item(ArcIcon.wallet, AppColors.teal, t('settings_payment_info'),
              t('teacher_attention_payment_info'), t('attention_setup'),
              () => setState(() => _view = _TView.profile)),
        ],
        if (_paymentRequests.isNotEmpty) ...[
          DashSection('${t('payment_requests')} (${_paymentRequests.length})'),
          for (final r in _paymentRequests)
            item(
                ArcIcon.money,
                AppColors.teal,
                (r['full_name'] as String?) ?? (r['email'] as String?) ?? '—',
                r['course_title'] as String? ?? '—',
                t('attention_payment'),
                () => setState(() => _view = _TView.payments)),
        ],
        if (_rejectedLectures.isNotEmpty) ...[
          DashSection(t('rejected_lectures')),
          for (final n in _rejectedLectures)
            item(ArcIcon.video, AppColors.red, n.title, n.body,
                t('attention_rejected'), () {
              NotificationService.instance.markRead(n.id);
              final slug = n.data['course_slug'];
              final c = _myCourses.where((x) => x['slug'] == slug).firstOrNull;
              if (c != null) {
                _openCourseEdit(c);
              } else {
                setState(() {});
              }
            }),
        ],
        if (_rejectedEdits.isNotEmpty) ...[
          DashSection(t('edit_requests')),
          for (final c in _rejectedEdits)
            item(ArcIcon.edit, AppColors.red, c['title'] as String? ?? '—',
                (c['edit_reject_reason'] as String?) ?? '—',
                t('attention_rejected'), () => _openCourseEdit(c)),
        ],
        if (_drafts.isNotEmpty) ...[
          DashSection(t('attention_draft')),
          for (final c in _drafts)
            item(ArcIcon.courses, AppColors.byline, c['title'] as String? ?? '—',
                t('teacher_attention_draft_sub'), t('attention_draft'),
                () => setState(() => _view = _TView.courses)),
        ],
      ],
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
    _pointsTick.value++;
  }

  void _removePoint(int i) {
    setState(() {
      if (_cPoints.length > _minPointRows) {
        _cPoints.removeAt(i).dispose();
      } else {
        _cPoints[i].clear();
      }
    });
    _pointsTick.value++;
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

  /// One labelled box of the course info grid.
  Widget _infoBox(String label, Widget child) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppColors.bg.withValues(alpha: 0.28),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: AppFonts.body(size: 12, color: AppColors.muted)),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );

  Widget _infoRow(Widget a, Widget b) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: a),
          const SizedBox(width: 10),
          Expanded(child: b),
        ]),
      );

  Future<void> _editPoints(String Function(String) t) async {
    final ar = AppStrings.instance.isAr;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Directionality(
        textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 18, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: ValueListenableBuilder<int>(
              valueListenable: _pointsTick,
              builder: (_, __, ___) => _learningPointsEditor(t),
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _buildCourseEdit(String Function(String) t) {
    final filled = _cPoints
        .map((c) => c.text.trim())
        .where((x) => x.isNotEmpty)
        .toList();
    // A plain scroll view (not a lazy list) so the curriculum card exists
    // and can be scrolled to as soon as the page opens.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          child: Text(
              _activeCourse != null ? t('edit_course') : t('new_course_title'),
              style: AppFonts.body(size: 18, weight: FontWeight.w800)),
        ),
        _tlStep(t, 0, t('step_info'), t('step_info_sub'),
          done: _activeCourse != null,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _infoRow(
              _infoBox(
                t('label_title'),
                TextField(
                    controller: _cTitle,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(isDense: true)),
              ),
              _infoBox(
                t('what_you_learn'),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _editPoints(t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            filled.isEmpty
                                ? t('learning_point_add')
                                : '${filled.length} / $_maxPoints',
                            style: AppFonts.body(
                                size: 14,
                                weight: FontWeight.w700,
                                color: AppColors.red)),
                        if (filled.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(filled.take(2).join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.body(
                                  size: 11.5, color: AppColors.muted)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _infoRow(
              _infoBox(
                t('label_thumbnail'),
                FilePickBox(
                  file: _cThumbFile,
                  existingUrl: _cThumbUrl,
                  emptyLabel: t('label_thumbnail'),
                  height: 130,
                  onPick: () async {
                    final picked = await SafePicker.image(imageQuality: 85);
                    if (picked != null) setState(() => _cThumbFile = picked);
                  },
                  onRemove: () => setState(() => _cThumbFile = null),
                ),
              ),
              _infoBox(
                t('label_price'),
                TextField(
                    controller: _cPrice,
                    keyboardType: TextInputType.number,
                    inputFormatters: Money.inputFormatters,
                    decoration: const InputDecoration(isDense: true)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: _cDescription,
                maxLines: 4,
                decoration: InputDecoration(labelText: t('label_description'))),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _cPrice,
              builder: (context, v, _) {
                final price = PaymentRules.parsePrice(v.text);
                if (price <= 0) return const SizedBox.shrink();
                final s = PaymentRules.split(
                    price: price, paid: price, rate: _myRate);
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    Expanded(
                      child: _SplitChip(
                          label: _capText(t('split_platform'))
                              .replaceAll('{pct}', PaymentRules.pct(_myRate)),
                          value: s.platform,
                          color: AppColors.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SplitChip(
                          label: t('split_yours').replaceAll(
                              '{pct}', PaymentRules.pct(1 - _myRate)),
                          value: s.teacher,
                          color: AppColors.teal),
                    ),
                  ]),
                );
              },
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
                      onPressed: _leaveEditor, child: Text(t('cancel')))),
            ]),
          ],
        )),
        _tlStep(
          t,
          1,
          t('step_lectures'),
          t('chapter_count').replaceAll('{n}', '${_activeLectures.length}'),
          key: _curriculumKey,
          done: _activeLectures.isNotEmpty,
          child: _activeCourse == null ? null : _curriculumBody(t),
        ),
        _tlStep(
          t,
          2,
          t('step_files'),
          t('step_files_sub'),
          last: true,
          child: _activeCourse == null
              ? null
              : TeacherCourseFiles(
                  key: ValueKey(_activeCourse!['id']),
                  courseId: _activeCourse!['id'] as String,
                  lectures: _activeLectures),
        ),
      ],
      ),
    );
  }

  /// One step of the course editor timeline: a numbered dot, a line down to
  /// the next step, and a card that opens and closes around the step's
  /// content. A step with no [child] is locked (the course is not saved yet).
  Widget _tlStep(String Function(String) t, int index, String title, String sub,
      {Widget? child, bool done = false, bool last = false, Key? key}) {
    final locked = child == null;
    final open = !locked && _openStep == index;
    final lit = done || open;
    const fast = Duration(milliseconds: 260);
    return Stack(
      key: key,
      children: [
        if (!last)
          PositionedDirectional(
            start: 15,
            top: 34,
            bottom: 0,
            width: 2,
            child: AnimatedContainer(
                duration: fast,
                color: done ? AppColors.red : AppColors.line),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              child: AnimatedContainer(
                duration: fast,
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lit ? AppColors.red : AppColors.panel2,
                  border: Border.all(
                      color: lit ? AppColors.red : AppColors.line, width: 1.5),
                ),
                alignment: Alignment.center,
                child: done && !open
                    ? const Icon(Icons.check_rounded,
                        size: 18, color: Colors.white)
                    : Text('${index + 1}',
                        style: AppFonts.code(
                            size: 13,
                            color: open ? Colors.white : AppColors.muted)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: last ? 0 : 14),
                child: GlassCard(
                  padding: const EdgeInsets.all(14),
                  borderRadius: BorderRadius.circular(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: locked
                            ? null
                            : () =>
                                setState(() => _openStep = open ? -1 : index),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title,
                                    style: AppFonts.body(
                                        size: 15, weight: FontWeight.w800)),
                                const SizedBox(height: 2),
                                Text(locked ? t('step_locked') : sub,
                                    style: AppFonts.body(
                                        size: 12, color: AppColors.muted)),
                              ],
                            ),
                          ),
                          if (!locked)
                            AnimatedRotation(
                              turns: open ? 0.5 : 0,
                              duration: fast,
                              child: Icon(Icons.expand_more_rounded,
                                  color: AppColors.muted),
                            ),
                        ]),
                      ),
                      AnimatedSize(
                        duration: fast,
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: open
                            ? Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: child)
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Step 2 body: uploads in progress, the chapters switch, the lectures
  /// (grouped by chapter when chapters are on) and the add buttons.
  Widget _curriculumBody(String Function(String) t) {
    final chapterIds = {for (final c in _activeChapters) c['id']};
    List<Widget> rowsFor(bool Function(Map<String, dynamic>) test) => [
          for (var i = 0; i < _activeLectures.length; i++)
            if (test(_activeLectures[i])) ...[
              _lectureRow(i, _activeLectures[i], t),
              const SizedBox(height: 10),
            ],
        ];
    Widget addButton(String? chapterId) => Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => _addLectureSheet(chapterId),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(t('btn_add_lecture')),
          ),
        );
    Widget block({required String title, required String meta,
        required List<Widget> rows, String? chapterId,
        Map<String, dynamic>? chapter}) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: AppColors.bg.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppFonts.body(
                            size: 14.5, weight: FontWeight.w800)),
                    Text(meta,
                        style:
                            AppFonts.body(size: 12, color: AppColors.muted)),
                  ],
                ),
              ),
              if (chapter != null)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz_rounded, color: AppColors.muted),
                  onSelected: (v) =>
                      v == 'rename' ? _renameChapter(chapter) : _deleteChapter(chapter),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'rename', child: Text(t('btn_rename'))),
                    PopupMenuItem(
                        value: 'delete', child: Text(t('btn_delete'))),
                  ],
                ),
            ]),
            const SizedBox(height: 10),
            ...rows,
            addButton(chapterId),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedBuilder(
          animation: UploadManager.instance,
          builder: (context, _) {
            final jobs = UploadManager.instance
                .forCourse(_activeCourse?['id'] as String? ?? '');
            if (jobs.isEmpty) return const SizedBox.shrink();
            return Column(children: [
              for (final j in jobs) ...[
                DashCard(
                  leading: _UploadProgressPill(
                      progress: j.progress, label: ''),
                  title: j.title,
                  subtitle: switch (j.status) {
                    UploadStatus.uploading =>
                      '${t('uploading_video')} ${(j.progress * 100).round()}%',
                    UploadStatus.done => t('lecture_sent_for_review'),
                    UploadStatus.failed => t('err_video_upload_failed'),
                    UploadStatus.cancelled => t('upload_cancelled'),
                  },
                  actions: [
                    if (j.status == UploadStatus.uploading)
                      DashButton(t('btn_cancel_upload'),
                          danger: true,
                          icon: ArcIcon.close,
                          onPressed: () async {
                            if (await _confirm(t('confirm_cancel_upload'),
                                confirmLabel: t('btn_cancel_upload'))) {
                              UploadManager.instance.cancel(j.lectureId);
                            }
                          })
                    else
                      DashButton(t('btn_hide'),
                          icon: ArcIcon.close,
                          onPressed: () =>
                              UploadManager.instance.dismiss(j.lectureId)),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ]);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('chapters_switch'),
              style: AppFonts.body(size: 14, weight: FontWeight.w700)),
          subtitle: Text(t('chapters_switch_sub'),
              style: AppFonts.body(size: 12, color: AppColors.muted)),
          value: _chaptersOn,
          onChanged: _setChaptersOn,
        ),
        const SizedBox(height: 6),
        if (!_chaptersOn) ...[
          if (_activeLectures.isEmpty)
            DashEmpty(icon: ArcIcon.video, message: t('no_lectures_teacher')),
          ...rowsFor((_) => true),
          addButton(null),
        ] else ...[
          for (final c in _activeChapters)
            block(
              title: c['title'] as String? ?? '—',
              meta: t('chapter_count').replaceAll('{n}',
                  '${_activeLectures.where((l) => l['chapter_id'] == c['id']).length}'),
              rows: rowsFor((l) => l['chapter_id'] == c['id']),
              chapterId: c['id'] as String,
              chapter: c,
            ),
          if (_activeLectures.any((l) => !chapterIds.contains(l['chapter_id'])) ||
              _activeChapters.isEmpty)
            block(
              title: t('chapter_none'),
              meta: t('chapter_count').replaceAll('{n}',
                  '${_activeLectures.where((l) => !chapterIds.contains(l['chapter_id'])).length}'),
              rows: rowsFor((l) => !chapterIds.contains(l['chapter_id'])),
            ),
          OutlinedButton.icon(
            onPressed: () async {
              await _createChapter();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(t('chapter_new').replaceFirst('+ ', '')),
          ),
        ],
        const SizedBox(height: 8),
        Text(t('upload_background_hint'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
      ],
    );
  }

  /// The add-lecture form, as a sheet opened from a chapter (or from the
  /// plain list when chapters are off).
  Future<void> _addLectureSheet(String? chapterId) async {
    final t = AppStrings.instance.t;
    setState(() {
      _lChapterId = chapterId;
      _lFormError = null;
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Directionality(
        textDirection:
            AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
        child: StatefulBuilder(builder: (ctx, setSheet) {
          void both(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
                20, 18, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t('add_lecture_title'),
                      style: AppFonts.body(size: 18, weight: FontWeight.w800)),
                  if (_chaptersOn && chapterId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                          _activeChapters
                                  .where((c) => c['id'] == chapterId)
                                  .map((c) => c['title'] as String? ?? '')
                                  .firstOrNull ??
                              '',
                          style: AppFonts.body(
                              size: 13, color: AppColors.muted)),
                    ),
                  const SizedBox(height: 14),
                  TextField(
                      controller: _lTitle,
                      decoration: InputDecoration(
                          labelText: t('label_lecture_title'))),
                  const SizedBox(height: 12),
                  FilePickBox(
                    file: _lVideoFile,
                    video: true,
                    emptyLabel: t('label_video_file'),
                    onPick: () async {
                      final picked = await SafePicker.video();
                      if (picked != null) both(() => _lVideoFile = picked);
                    },
                    onRemove: () => both(() => _lVideoFile = null),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('label_free_lecture'),
                        style: AppFonts.body(size: 14)),
                    value: _lIsFree,
                    onChanged: (v) => both(() => _lIsFree = v),
                  ),
                  _formError(_lFormError),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: _lPreparing
                        ? null
                        : () async {
                            final run = _addLecture();
                            setSheet(() {});
                            await run;
                            if (!ctx.mounted) return;
                            if (_lFormError == null && _lTitle.text.isEmpty) {
                              Navigator.of(ctx).pop();
                            } else {
                              setSheet(() {});
                            }
                          },
                    child: _lPreparing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(t('btn_add')),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
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
      meta: [
        if (l['is_free'] == true) t('free_tag'),
        if (_chaptersOn)
          ..._activeChapters
            .where((c) => c['id'] == l['chapter_id'])
            .map((c) => c['title'] as String? ?? ''),
      ],
      metaColor: AppColors.teal,
      actions: [
        if (_chaptersOn && _activeChapters.isNotEmpty)
          DashButton(t('btn_move_chapter'), onPressed: () => _moveToChapter(l)),
        if (i > 0)
          DashButton(t('btn_move_up'), onPressed: () => _moveLecture(i, -1)),
        if (i < _activeLectures.length - 1)
          DashButton(t('btn_move_down'), onPressed: () => _moveLecture(i, 1)),
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
                  '${c['discount_type'] == 'percent' ? '${c['discount_value']}%' : Money.iqd((c['discount_value'] as num?) ?? 0)} · ${c['used_count']}/${c['max_uses']} ${t('codes_used')}',
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
            Text(_capText(t('discount_cap_hint')),
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
  final VoidCallback onCodes;
  final VoidCallback onStudents;
  final VoidCallback onReviews;
  final VoidCallback? onSubmit;
  final VoidCallback? onDelete;

  const _CourseCard({
    required this.course,
    required this.t,
    required this.onEdit,
    required this.onCodes,
    required this.onStudents,
    required this.onReviews,
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
          : Money.text(course['price']),
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
        DashButton(t('btn_students'), icon: ArcIcon.users, onPressed: onStudents),
        if (course['status'] == 'published')
          DashButton(t('btn_reviews'), icon: ArcIcon.review, onPressed: onReviews),
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
          Text(Money.iqd(value), style: AppFonts.code(size: 14, color: color)),
        ],
      ),
    );
  }
}
