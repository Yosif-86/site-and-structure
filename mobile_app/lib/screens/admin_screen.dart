import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../services/purchase_config.dart';
import '../i18n/strings.dart';
import '../services/live_refresh.dart';
import '../services/money.dart';
import '../services/api_service.dart';
import '../services/payment_rules.dart';
import '../services/r2_upload.dart';
import '../services/safe_picker.dart';
import '../services/text_search.dart';
import '../services/bidi.dart';
import '../services/error_reporter.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/arc_icons.dart';
import '../widgets/course_card.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/file_preview.dart';
import '../widgets/payment_requests.dart';
import '../widgets/proof_viewer.dart';
import 'course_detail_screen.dart';
import 'course_files.dart';
import 'teacher_profile_screen.dart';
import 'video_player_screen.dart';
import '../widgets/glass_scaffold.dart';

/// Port of admin.html's dashboard: a landing view of clickable stat cards,
/// each drilling into its own list/detail view with a back button — mirrors
/// admin.html's goView()/data-view model, just built as native Flutter
/// navigation instead of DOM section toggling.
///
/// Access is gated the same way as the website: profiles.is_admin, checked
/// server-side by RLS on every query below — this screen's is_admin guard is
/// only there to bounce a non-admin back out quickly, not to authorize
/// anything.
class AdminScreen extends StatefulWidget {
  /// Opens straight on a section (from a notification): 'payments',
  /// 'review' or 'editRequests'.
  final String? openView;
  const AdminScreen({super.key, this.openView});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

enum _View {
  dashboard,
  courses,
  teachers,
  students,
  revenue,
  enrollments,
  review,
  invites,
  uploads,
  flagged,
  devices,
  discountCodes,
  errorLog,
  myPayment,
  payments,
  editRequests,
  attention,
  files,
  reports,
}

class _AdminScreenState extends State<AdminScreen> {
  static const _maxDevices = 1; // must match api/check-device.js

  bool _checking = true;
  bool _isAdmin = false;
  bool _loading = false;
  String? _error;
  late _View _view = switch (widget.openView) {
    'payments' => _View.payments,
    'review' => _View.review,
    'editRequests' => _View.editRequests,
    'uploads' => _View.uploads,
    'files' => _View.files,
    'reports' => _View.reports,
    _ => _View.dashboard,
  };

  // Raw data, loaded once and reused across every drill-in view — mirrors
  // admin.html's single IIFE that kicks off every load* function up front.
  List<Map<String, dynamic>> _allCourses = [];
  List<Map<String, dynamic>> _publishedCourses = [];
  List<Map<String, dynamic>> _pendingReview = [];
  List<Map<String, dynamic>> _allProfiles = [];
  List<Map<String, dynamic>> _teacherProfiles = [];
  List<Map<String, dynamic>> _enrollments = [];
  List<Map<String, dynamic>> _activeEnrollments = [];
  List<Map<String, dynamic>> _flagged = [];
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _invites = [];
  List<Map<String, dynamic>> _pendingUploads = [];
  List<Map<String, dynamic>> _pendingFiles = [];
  List<Map<String, dynamic>> _reports = [];
  List<Map<String, dynamic>> _discountCodes = [];
  List<Map<String, dynamic>> _errorLogs = [];
  Map<String, String> _emailByUser = {};
  Map<String, Map<String, dynamic>> _profileByUser = {};
  Map<String, Map<String, dynamic>> _courseBySlug = {};

  final _payZainCtrl = TextEditingController();
  final _payQiCtrl = TextEditingController();
  // Search box shared by the people / enrollment / payment lists.
  final _searchCtrl = TextEditingController();
  String _q = '';
  XFile? _payQrFile;
  String? _payQrUrl;
  bool _payLoaded = false;
  // Actions in flight, keyed by row id: a second tap is ignored instead of
  // running the same approve/upload twice.
  final Set<String> _busy = {};
  // Each _loadAll bumps this; an older load that finishes late is dropped
  // so it can't overwrite newer data.
  int _loadGen = 0;

  Future<void> _once(String key, Future<void> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }
  String? _payError;
  String? _payOk;

  // Payments, course submissions, edits and uploads appear without a pull.
  late final _live = LiveRefresh(
      tables: const ['enrollments', 'courses', 'lectures'], onChange: _loadAll);

  @override
  void initState() {
    super.initState();
    _init();
    _live.start();
  }

  @override
  void dispose() {
    _live.stop();
    _payZainCtrl.dispose();
    _payQiCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() {
        _checking = false;
        _isAdmin = false;
      });
      return;
    }
    try {
      final prof = await sb
          .from('profiles')
          .select('is_admin')
          .eq('id', user.id)
          .maybeSingle();
      final isAdmin = prof?['is_admin'] == true;
      if (!mounted) return;
      setState(() {
        _checking = false;
        _isAdmin = isAdmin;
      });
      if (isAdmin) await _loadAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _isAdmin = false;
        _error = ErrorReporter.userMessage(e, page: 'admin');
      });
    }
  }

  Future<void> _loadAll() async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sb = SupabaseService.instance.client;
      final results = await Future.wait([
        sb.from('courses').select(
            'id, slug, title, description, price, is_free, thumbnail_url, learning_points, teacher_id, pay_to_teacher, status, pending_edit, edit_status'),
        sb.from('profiles').select(
            'id, full_name, phone, public_id, is_teacher, is_admin, teacher_payment_method, teacher_payment_detail, teacher_zaincash_phone, teacher_qi_account_number, teacher_qi_qr_url, direct_payment_allowed'),
        _loadEmails(),
        sb.from('enrollments').select('*'),
        sb
            .from('login_events')
            .select('*')
            .eq('flagged', true)
            .order('created_at', ascending: false)
            .limit(50),
        sb
            .from('trusted_devices')
            .select('id, user_id, device_label, first_seen, last_seen')
            .order('user_id')
            .order('first_seen'),
        sb
            .from('teacher_invites')
            .select('id, token, created_at, expires_at, used_at, used_by')
            .order('created_at', ascending: false),
        sb
            .from('lectures')
            .select('id, title, course_id, pending_upload_path, duration_seconds')
            .not('pending_upload_path', 'is', null)
            .order('order_index'),
        sb
            .from('discount_codes')
            .select(
                'id, course_id, code, discount_type, discount_value, max_uses, used_count, expires_at, is_active')
            .order('created_at', ascending: false),
        sb
            .from('error_logs')
            .select('id, message, page, user_id, created_at')
            .order('created_at', ascending: false)
            .limit(200),
        sb
            .from('discount_code_redemptions')
            .select('discount_code_id, user_id')
            .order('redeemed_at', ascending: true),
      ]);

      final courses = (results[0] as List).cast<Map<String, dynamic>>();
      final profiles = (results[1] as List).cast<Map<String, dynamic>>();
      final logins = (results[2] as List).cast<Map<String, dynamic>>();
      final enrollments = (results[3] as List).cast<Map<String, dynamic>>();
      final flagged = (results[4] as List).cast<Map<String, dynamic>>();
      final devices = (results[5] as List).cast<Map<String, dynamic>>();
      final invites = (results[6] as List).cast<Map<String, dynamic>>();
      final uploads = (results[7] as List).cast<Map<String, dynamic>>();
      final codes = (results[8] as List).cast<Map<String, dynamic>>();
      final errors = (results[9] as List).cast<Map<String, dynamic>>();
      final redemptions = (results[10] as List).cast<Map<String, dynamic>>();
      final securityEvents = await _loadSecurityEvents();
      final pendingFiles = await _loadPendingFiles();
      final reports = await _loadReports();

      final emailByUser = <String, String>{};
      for (final l in logins) {
        final uid = l['user_id'] as String?;
        if (uid != null && !emailByUser.containsKey(uid))
          emailByUser[uid] = l['email'] as String? ?? '—';
      }
      final profileByUser = <String, Map<String, dynamic>>{
        for (final p in profiles) p['id'] as String: p
      };
      final courseBySlug = <String, Map<String, dynamic>>{
        for (final c in courses) c['slug'] as String: c
      };

      final myProfile = profileByUser[SupabaseService.instance.currentUser?.id];

      if (!mounted || gen != _loadGen) return;
      setState(() {
        _allCourses = courses;
        _publishedCourses =
            courses.where((c) => c['status'] == 'published').toList();
        _pendingReview =
            courses.where((c) => c['status'] == 'pending_review').toList();
        _allProfiles = profiles;
        _teacherProfiles =
            profiles.where((p) => p['is_teacher'] == true).toList();
        _emailByUser = emailByUser;
        _profileByUser = profileByUser;
        _courseBySlug = courseBySlug;
        _enrollments = enrollments;
        _activeEnrollments =
            enrollments.where((e) => e['status'] == 'active').toList();
        _flagged = flagged;
        _securityEvents = securityEvents;
        final countByUser = <String, int>{};
        for (final d in devices) {
          final uid = d['user_id'] as String;
          countByUser[uid] = (countByUser[uid] ?? 0) + 1;
        }
        _devices = devices
            .where((d) => (countByUser[d['user_id']] ?? 0) >= _maxDevices)
            .toList();
        _invites = invites;
        _pendingUploads = uploads;
        _pendingFiles = pendingFiles;
        _reports = reports;
        _discountCodes = codes;
        _errorLogs = errors;
        // New three-field details, seeded from the old single method/number
        // pair the first time so nothing already set is lost.
        // Only on the first load: live reloads must not wipe what the admin
        // is typing.
        if (!_payLoaded) {
          final oldMethod = myProfile?['teacher_payment_method'] as String?;
          final oldDetail = myProfile?['teacher_payment_detail'] as String?;
          _payZainCtrl.text =
              (myProfile?['teacher_zaincash_phone'] as String?) ??
                  (oldMethod == 'zain' ? oldDetail ?? '' : '');
          _payQiCtrl.text =
              (myProfile?['teacher_qi_account_number'] as String?) ??
                  (oldMethod == 'qi' ? oldDetail ?? '' : '');
          _payQrUrl = myProfile?['teacher_qi_qr_url'] as String?;
          _payLoaded = true;
        }
        _loading = false;
      });
      // Discount redemptions are only needed by the revenue view's
      // per-student discount lookup; stash separately to keep _loadAll
      // readable.
      _redemptionsByCourseUser = {
        for (final r in redemptions)
          if (codes.any((c) => c['id'] == r['discount_code_id']))
            '${codes.firstWhere((c) => c['id'] == r['discount_code_id'])['course_id']}|${r['user_id']}':
                codes.firstWhere((c) => c['id'] == r['discount_code_id']),
      };
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      final msg = ErrorReporter.userMessage(e, page: 'admin');
      setState(() {
        // Data already on screen stays; only a first load shows the error page.
        if (_allCourses.isEmpty) _error = msg;
        _loading = false;
      });
      if (_allCourses.isNotEmpty) _showError(msg);
    }
  }

  Map<String, Map<String, dynamic>> _redemptionsByCourseUser = {};
  List<Map<String, dynamic>> _securityEvents = [];

  /// Blocked devices, shared devices, screenshot attempts
  /// (add-oct05-fixes.sql). Empty until that migration has run.
  Future<List<Map<String, dynamic>>> _loadSecurityEvents() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('security_events')
          .select('id, user_id, kind, detail, created_at')
          .order('created_at', ascending: false)
          .limit(100);
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// Course files waiting for approval (add-lecture-files-and-review.sql).
  Future<List<Map<String, dynamic>>> _loadPendingFiles() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('course_files')
          .select(
              'id, course_id, lecture_id, title, kind, view_path, view_type, original_name, allow_download, is_free, uploaded_by, created_at, lectures(title)')
          .eq('status', 'pending_review')
          .order('created_at');
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  /// Open content reports (add-reviewer-and-reports.sql).
  Future<List<Map<String, dynamic>>> _loadReports() async {
    try {
      final rows = await SupabaseService.instance.client
          .from('content_reports')
          .select('id, reporter_id, course_id, reason, details, created_at, courses(title, slug, teacher_id)')
          .eq('status', 'open')
          .order('created_at');
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _closeReport(Map<String, dynamic> r, String status) =>
      _once('report-${r['id']}', () async {
    try {
      await SupabaseService.instance.client.from('content_reports').update({
        'status': status,
        'handled_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', r['id']);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _reviewFile(Map<String, dynamic> f, bool approve) =>
      _once('file-${f['id']}', () async {
    final t = AppStrings.instance.t;
    String? reason;
    if (!approve) {
      reason = await askRejectReason(context, title: t('btn_reject'));
      if (reason == null) return;
    }
    try {
      await SupabaseService.instance.client.rpc('admin_review_course_file',
          params: {
            'p_file_id': f['id'],
            'p_approve': approve,
            'p_reason': reason,
          });
      _showError(t(approve ? 'file_approved' : 'file_rejected_done'));
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  int get _suspiciousCount => _flagged.length + _securityEvents.length;

  Future<void> _forceLogout(String userId) => _once('logout-$userId', () async {
    final t = AppStrings.instance.t;
    if (!await _confirm(t('confirm_force_logout'),
        confirmLabel: t('btn_confirm'))) {
      return;
    }
    try {
      await SupabaseService.instance.client
          .rpc('admin_force_logout', params: {'p_user_id': userId});
      _showError(t('force_logout_done'));
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _resetDevices(String userId) => _once('reset-$userId', () async {
    final t = AppStrings.instance.t;
    if (!await _confirm(t('confirm_reset_devices'),
        confirmLabel: t('btn_confirm'))) {
      return;
    }
    try {
      await SupabaseService.instance.client
          .from('trusted_devices')
          .delete()
          .eq('user_id', userId);
      _showError(t('reset_devices_done'));
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  bool _canDelete(String? uid) =>
      uid != null &&
      uid != SupabaseService.instance.currentUser?.id &&
      _profileByUser[uid]?['is_admin'] != true;

  Widget _deleteAccountButton(String uid, String Function(String) t) =>
      DashButton(t('btn_delete_account'),
          danger: true,
          icon: ArcIcon.trash,
          onPressed: _busy.contains('delete-$uid')
              ? null
              : () => _deleteAccount(uid));

  /// Deletes the account for good (a teacher's courses go with it).
  Future<void> _deleteAccount(String uid) => _once('delete-$uid', () async {
    final t = AppStrings.instance.t;
    final name = (_profileByUser[uid]?['full_name'] as String?) ??
        _emailByUser[uid] ??
        '—';
    final courses = _allCourses.where((c) => c['teacher_id'] == uid).length;
    final msg = (courses > 0
            ? t('confirm_admin_delete_teacher').replaceAll('{n}', '$courses')
            : t('confirm_admin_delete_account'))
        .replaceAll('{name}', Bidi.iso(name));
    if (!await _confirm(msg, confirmLabel: t('btn_delete'))) return;
    final err = await SupabaseService.instance.adminDeleteAccount(uid);
    if (err != null) {
      _showError(t(err));
      return;
    }
    _showError(t('account_deleted'));
    await _loadAll();
  });

  Future<void> _deleteCourse(Map<String, dynamic> c) =>
      _once('course-del-${c['id']}', () async {
    final t = AppStrings.instance.t;
    final students =
        _activeEnrollments.where((e) => e['course_slug'] == c['slug']).length;
    final msg = (students > 0
            ? t('confirm_delete_course_students').replaceAll('{n}', '$students')
            : t('confirm_delete_course'))
        .replaceAll('{title}', Bidi.iso(c['title'] as String? ?? ''));
    if (!await _confirm(msg, confirmLabel: t('btn_delete'))) return;
    try {
      final rows = await SupabaseService.instance.client
          .from('courses')
          .delete()
          .eq('id', c['id'])
          .select('id');
      if ((rows as List).isEmpty) {
        _showError(t('err_not_allowed'));
        return;
      }
      _showError(t('course_deleted'));
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _clearSuspicious() => _once('clear-suspicious', () async {
    final t = AppStrings.instance.t;
    if (!await _confirm(t('confirm_clear_suspicious'),
        confirmLabel: t('btn_clear_all'))) {
      return;
    }
    try {
      await SupabaseService.instance.client.rpc('admin_clear_suspicious');
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  /// Every account's email. The function (add-oct05-fixes.sql) isn't capped
  /// like the old login_events read, which stopped at 1000 rows; that read
  /// stays as the fallback until the migration runs.
  Future<List<Map<String, dynamic>>> _loadEmails() async {
    final sb = SupabaseService.instance.client;
    try {
      final rows = await sb.rpc('admin_user_emails');
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      final rows = await sb
          .from('login_events')
          .select('user_id, email, created_at')
          .order('created_at', ascending: false);
      return (rows as List).cast<Map<String, dynamic>>();
    }
  }

  String _courseTitle(String slug) =>
      (_courseBySlug[slug]?['title'] as String?) ?? slug;

  void _goto(_View v) => setState(() {
        _view = v;
        _searchCtrl.clear();
        _q = '';
      });

  /// The account's short public ID as "#2274" (null if it has none).
  String? _idTag(Map<String, dynamic>? profile) {
    final id = profile?['public_id']?.toString();
    return (id == null || id.isEmpty) ? null : '#$id';
  }

  /// Name, email, phone and the #ID are all searchable. "#2274" and "2274"
  /// both find that account.
  bool _hit(Iterable<Object?> fields, Map<String, dynamic>? profile) {
    final tag = _idTag(profile);
    return TextSearch.matches(
        _q.replaceAll('#', ' '), [...fields, if (tag != null) tag]);
  }

  /// Exact ID matches first when the query is a 4-digit ID.
  int _idFirst(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    final q = _q.replaceAll('#', '').trim();
    if (q.length != 4) return 0;
    final ea = a?['public_id']?.toString() == q ? 0 : 1;
    final eb = b?['public_id']?.toString() == q ? 0 : 1;
    return ea.compareTo(eb);
  }

  Widget _searchBar(String Function(String) t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _q = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: t('admin_search_hint'),
            prefixIcon: Padding(
              padding: const EdgeInsets.all(12),
              child: ArcIconView(ArcIcon.search, size: 18, color: AppColors.muted2),
            ),
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    icon: ArcIconView(ArcIcon.close, size: 16, color: AppColors.muted2),
                    onPressed: () => setState(() {
                      _searchCtrl.clear();
                      _q = '';
                    })),
          ),
        ),
      );

  /// A list with the search box above it ("no results" when nothing matches).
  Widget _withSearch(String Function(String) t, bool empty, Widget list) =>
      Column(children: [
        _searchBar(t),
        Expanded(
            child: empty
                ? _empty(t('explore_no_results'), ArcIcon.search)
                : list),
      ]);

  Future<void> _approve(String enrollmentId) => _once(enrollmentId, () async {
    final t = AppStrings.instance.t;
    final e = _enrollments.firstWhere((x) => x['id'] == enrollmentId,
        orElse: () => const {});
    final uid = e['user_id'] as String?;
    final name = (_profileByUser[uid]?['full_name'] as String?) ??
        _emailByUser[uid] ??
        '—';
    final slug = e['course_slug'] as String? ?? '';
    final course = _courseBySlug[slug];
    final ok = await _confirm(
        t('confirm_approve_payment')
            .replaceAll('{name}', Bidi.iso(name))
            .replaceAll('{course}', Bidi.iso(_courseTitle(slug)))
            .replaceAll(
                '{price}',
                course == null
                    ? '—'
                    : () {
                        final r = _paidFor(e, course);
                        return Money.paymentSummary(t,
                            price: r.price,
                            discount: r.discount,
                            paid: r.paid,
                            code: r.code);
                      }()),
        confirmLabel: t('btn_confirm'));
    if (!ok) return;
    try {
      final adminId = SupabaseService.instance.currentUser?.id;
      final updated = await SupabaseService.instance.client.from('enrollments').update({
        'status': 'active',
        'approved_by': adminId,
        // .toUtc() matters here -- see the same fix in video_player_screen's
        // progress save for why a bare local DateTime.now() lands 3 hours
        // ahead of real UTC once Postgres reads it.
        'approved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', enrollmentId).select('id');
      // Nothing updated: someone else rejected it in the meantime.
      _showError(t((updated as List).isEmpty
          ? 'err_request_gone'
          : 'payment_approved'));
      await _loadAll();
    } catch (err) {
      _showError(ErrorReporter.userMessage(err, page: 'admin'));
    }
  });

  Future<void> _removeEnrollment(
      String enrollmentId, String title, String email) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_remove')
        .replaceAll('{email}', Bidi.iso(email))
        .replaceAll('{title}', Bidi.iso(title)));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('enrollments')
          .delete()
          .eq('id', enrollmentId);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  }

  Future<void> _viewProof(String path) => openPaymentProof(context, path);

  Future<void> _removeDevice(String deviceRowId, String email) async {
    final t = AppStrings.instance.t;
    final confirmed =
        await _confirm(t('confirm_remove_device').replaceAll('{email}', Bidi.iso(email)));
    if (!confirmed) return;
    try {
      final result = await SupabaseService.instance.client
          .from('trusted_devices')
          .delete()
          .eq('id', deviceRowId)
          .select();
      if ((result as List).isEmpty) {
        _showError(t('err_not_allowed'));
        return;
      }
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  }

  Future<void> _publishCourse(String id) => _once(id, () async {
    try {
      await SupabaseService.instance.client
          .from('courses')
          .update({'status': 'published'}).eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _rejectCourse(String id, String title) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(
        t('confirm_reject_course').replaceAll('{title}', Bidi.iso(title)),
        confirmLabel: t('btn_confirm'));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('courses')
          .update({'status': 'draft'}).eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  }

  /// The database only lets a course pay its teacher once that teacher is
  /// unlocked for direct payments (and refuses to unlock a teacher with no
  /// payment details) -- otherwise the update is silently reverted, which is
  /// why the box used to spring back. Unlock first, then set, then confirm.
  Future<void> _togglePayToTeacher(Map<String, dynamic> course, bool value) async {
    final t = AppStrings.instance.t;
    final sb = SupabaseService.instance.client;
    try {
      if (value && course['teacher_id'] != null) {
        try {
          await sb.rpc('set_teacher_payment_enabled', params: {
            'p_teacher_id': course['teacher_id'],
            'p_enabled': true,
          });
        } catch (e) {
          _showError(e.toString().contains('payment')
              ? t('err_teacher_no_payment_info')
              : ErrorReporter.userMessage(e, page: 'admin'));
          return;
        }
      }
      final row = await sb
          .from('courses')
          .update({'pay_to_teacher': value})
          .eq('id', course['id'])
          .select('pay_to_teacher')
          .single();
      if (row['pay_to_teacher'] != value) {
        _showError(t('err_teacher_no_payment_info'));
      }
      await _loadAll();
    } catch (e) {
      _showError(t('err_generic_failed'));
    }
  }

  Future<void> _createInvite() => _once('invite', () async {
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      // The token is the whole secret behind a teacher invite link, so it
      // has to be unguessable -- a timestamp-derived id was enumerable.
      final token = const Uuid().v4();
      final expiresAt =
          DateTime.now().add(const Duration(days: 7)).toUtc().toIso8601String();
      await sb.from('teacher_invites').insert(
          {'token': token, 'created_by': user.id, 'expires_at': expiresAt});
      await _loadAll();
    } catch (e) {
      _showError(AppStrings.instance.t('err_create_invite'));
    }
  });

  Future<void> _revokeInvite(String id) async {
    final confirmed = await _confirm(
        AppStrings.instance.t('confirm_revoke_invite'),
        confirmLabel: AppStrings.instance.t('btn_confirm'));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('teacher_invites')
          .delete()
          .eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  }

  Future<void> _dismissError(String id) => _once(id, () async {
    try {
      await SupabaseService.instance.client
          .from('error_logs')
          .delete()
          .eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _clearErrorLog() async {
    final confirmed = await _confirm(
        AppStrings.instance.t('confirm_clear_errors'),
        confirmLabel: AppStrings.instance.t('btn_delete'));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client
          .from('error_logs')
          .delete()
          .not('id', 'is', null);
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  }

  Future<void> _saveMyPayment() => _once('my-payment', () async {
    final t = AppStrings.instance.t;
    setState(() {
      _payError = null;
      _payOk = null;
    });
    final zain = _payZainCtrl.text.trim();
    final qi = _payQiCtrl.text.trim();
    if (zain.isEmpty && qi.isEmpty) {
      setState(() => _payError = t('err_payment_method_required'));
      return;
    }
    if (zain.isNotEmpty && !PaymentRules.isValidZain(zain)) {
      setState(() => _payError = t('err_invalid_zain'));
      return;
    }
    if (qi.isNotEmpty && !PaymentRules.isValidQi(qi)) {
      setState(() => _payError = t('err_invalid_qi'));
      return;
    }
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      String? qrUrl;
      if (_payQrFile != null) {
        final ext = _payQrFile!.name.split('.').last.toLowerCase();
        final path = '${user.id}/${DateTime.now().millisecondsSinceEpoch}.$ext';
        await sb.storage.from('payment-qr').upload(path, File(_payQrFile!.path));
        qrUrl = sb.storage.from('payment-qr').getPublicUrl(path);
      }
      await sb.from('profiles').update({
        'teacher_zaincash_phone': zain.isEmpty ? null : zain,
        'teacher_qi_account_number': qi.isEmpty ? null : qi,
        if (qrUrl != null) 'teacher_qi_qr_url': qrUrl,
      }).eq('id', user.id);
      if (!mounted) return;
      setState(() {
        if (qrUrl != null) _payQrUrl = qrUrl;
        _payQrFile = null;
        _payOk = t('saved');
      });
      await _loadAll();
    } catch (e) {
      if (mounted) {
        setState(() => _payError = ErrorReporter.userMessage(e, page: 'admin'));
      }
    }
  });

  Future<void> _rejectEnrollment(String id) => _once(id, () async {
    final reason = await askRejectReason(context);
    if (reason == null) return;
    try {
      await SupabaseService.instance.client.rpc('reject_enrollment',
          params: {'p_enrollment_id': id, 'p_reason': reason});
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String message, {String? confirmLabel}) async {
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
              child: Text(confirmLabel ?? t('remove'))),
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
      child: GlassScaffold(
        maxContentWidth: 1100,
        appBar: AppBar(
          leading: _view != _View.dashboard
              ? IconButton(
                  icon: ArcIconView(ArcIcon.back, size: 22, color: AppColors.text),
                  onPressed: () => _goto(_View.dashboard))
              : null,
          title:
              Text(_view == _View.dashboard ? t('nav_admin') : _viewTitle(t)),
        ),
        body: PopScope(
          canPop: _view == _View.dashboard,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _goto(_View.dashboard);
          },
          child: _buildBody(t),
        ),
      ),
    );
  }

  String _viewTitle(String Function(String) t) {
    switch (_view) {
      case _View.courses:
        return t('published_courses');
      case _View.attention:
        return t('dash_needs_attention');
      case _View.teachers:
        return t('teachers');
      case _View.students:
        return t('active_students');
      case _View.revenue:
        return t('est_revenue');
      case _View.enrollments:
        return t('students_courses');
      case _View.review:
        return t('course_review');
      case _View.invites:
        return t('teacher_invites');
      case _View.uploads:
        return t('pending_lectures');
      case _View.files:
        return t('pending_files');
      case _View.reports:
        return t('reports_title');
      case _View.flagged:
        return t('flagged_logins');
      case _View.devices:
        return t('trusted_devices');
      case _View.discountCodes:
        return t('discount_codes');
      case _View.errorLog:
        return t('error_log');
      case _View.myPayment:
        return t('my_payment_number');
      case _View.payments:
        return t('payment_requests');
      case _View.editRequests:
        return t('edit_requests');
      case _View.dashboard:
        return t('nav_admin');
    }
  }

  Widget _buildBody(String Function(String) t) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    if (!_isAdmin) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? t('gate_not_admin'),
              style: AppFonts.body(color: AppColors.muted),
              textAlign: TextAlign.center),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: AppFonts.body(color: AppColors.muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadAll, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_loading && _allCourses.isEmpty)
      return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _loadAll,
      child: switch (_view) {
        _View.dashboard => _buildDashboard(t),
        _View.courses => _buildCoursesList(t),
        _View.teachers => _buildTeachersList(t),
        _View.students => _buildStudentsList(t),
        _View.revenue => _buildRevenue(t),
        _View.enrollments => _buildEnrollments(t),
        _View.review => _buildReview(t),
        _View.invites => _buildInvites(t),
        _View.uploads => _buildUploads(t),
        _View.files => _buildPendingFiles(t),
        _View.reports => _buildReports(t),
        _View.flagged => _buildFlagged(t),
        _View.devices => _buildDevices(t),
        _View.discountCodes => _buildDiscountCodes(t),
        _View.errorLog => _buildErrorLog(t),
        _View.myPayment => _buildMyPayment(t),
        _View.payments => _buildPayments(t),
        _View.editRequests => _buildEditRequests(t),
        _View.attention => _buildAttention(t),
      },
    );
  }

  // ---- Dashboard ----

  String _date(String? iso, {bool time = false}) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '—';
    final s = d.toString();
    return time ? s.substring(0, 16) : s.split(' ').first;
  }

  Widget _buildDashboard(String Function(String) t) {
    // The platform's own 20%, computed exactly like the revenue screen it
    // opens (same courses, real amounts paid). Direct-payment courses earn
    // the platform nothing.
    final revenue = _activeEnrollments.fold<int>(0, (sum, e) {
      final c = _courseBySlug[e['course_slug']];
      if (c == null ||
          c['status'] != 'published' ||
          c['is_free'] == true ||
          c['pay_to_teacher'] == true) {
        return sum;
      }
      final r = _paidFor(e, c);
      final cut = PaymentRules.split(price: r.price, paid: r.paid).platform;
      return sum + (cut > r.paid ? r.paid : cut);
    });
    final now = DateTime.now();
    final activeInvitesCount = _invites
        .where((i) =>
            i['used_at'] == null &&
            (DateTime.tryParse(i['expires_at'] as String? ?? '')
                    ?.isAfter(now) ??
                false))
        .length;
    final activeDiscountCodes = _discountCodes
        .where((c) =>
            c['is_active'] == true &&
            (DateTime.tryParse(c['expires_at'] as String? ?? '')
                    ?.isAfter(now) ??
                false))
        .length;
    final me = _profileByUser[SupabaseService.instance.currentUser?.id];
    bool filled(String k) => ((me?[k] as String?)?.trim().isNotEmpty ?? false);
    final myPaySet = filled('teacher_zaincash_phone') ||
        filled('teacher_qi_account_number') ||
        filled('teacher_payment_detail');
    final myPendingPayments = _pendingPayments.where((e) => !_teacherPaid(e)).length;
    final activeStudents = {for (final e in _activeEnrollments) e['user_id']}.length;
    final pendingEnrollments = _pendingPayments.length;

    var delay = 0;
    Widget tile(ArcIcon icon, String value, String label, Color accent,
            _View view, {bool alert = false}) =>
        FadeSlideIn(
          delayMs: delay += 30,
          child: DashStatCard(
              icon: icon,
              value: value,
              label: label,
              accent: accent,
              alert: alert,
              onTap: () => _goto(view)),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        FadeSlideIn(
          delayMs: 0,
          child: DashHero(
            title: t('nav_admin'),
            subtitle: t('dash_admin_sub'),
            stats: [
              (Money.iqd(revenue), t('est_revenue')),
              ('$activeStudents', t('active_students')),
              ('${_pendingReview.length + myPendingPayments + _editRequests.length + _pendingUploads.length + _pendingFiles.length + _reports.length}',
                  t('dash_needs_attention')),
            ],
            statTaps: [
              () => _goto(_View.revenue),
              () => _goto(_View.students),
              () => _goto(_View.attention),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: PurchaseConfig.instance,
          builder: (context, _) {
            final on = PurchaseConfig.instance.setting;
            return GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: on,
                activeThumbColor: Colors.white,
                title: Text(t('purchase_switch_title'),
                    style: AppFonts.body(size: 14.5, weight: FontWeight.w700)),
                subtitle: Text(
                    t(on ? 'purchase_switch_on' : 'purchase_switch_off'),
                    style: AppFonts.body(size: 12, color: AppColors.muted)),
                onChanged: _busy.contains('purchase-switch')
                    ? null
                    : (v) => _once('purchase-switch', () async {
                          try {
                            await PurchaseConfig.instance.set(v);
                          } catch (e) {
                            _showError(ErrorReporter.userMessage(e, page: 'admin'));
                          }
                        }),
              ),
            );
          },
        ),
        if (myPendingPayments > 0) ...[
          const SizedBox(height: 12),
          FadeSlideIn(
            delayMs: 30,
            child: _PendingBanner(
              count: myPendingPayments,
              onTap: () => _goto(_View.payments),
            ),
          ),
        ],
        DashSection(t('dash_sec_content')),
        DashGrid(children: [
          tile(ArcIcon.courses, '${_publishedCourses.length}',
              t('published_courses'), AppColors.teal, _View.courses),
          tile(ArcIcon.review, '${_pendingReview.length}', t('course_review'),
              AppColors.red, _View.review,
              alert: _pendingReview.isNotEmpty),
          tile(ArcIcon.edit, '${_editRequests.length}', t('edit_requests'),
              const Color(0xFFE0A030), _View.editRequests,
              alert: _editRequests.isNotEmpty),
          tile(ArcIcon.video, '${_pendingUploads.length}',
              t('pending_lectures'), AppColors.byline, _View.uploads,
              alert: _pendingUploads.isNotEmpty),
          tile(ArcIcon.lessons, '${_pendingFiles.length}', t('pending_files'),
              AppColors.teal, _View.files,
              alert: _pendingFiles.isNotEmpty),
          tile(ArcIcon.warning, '${_reports.length}', t('reports_title'),
              AppColors.error, _View.reports,
              alert: _reports.isNotEmpty),
        ]),
        DashSection(t('dash_sec_people')),
        DashGrid(children: [
          tile(ArcIcon.award, '${_teacherProfiles.length}', t('teachers'),
              AppColors.red, _View.teachers),
          tile(ArcIcon.users, '$activeStudents', t('active_students'),
              AppColors.teal, _View.students),
          tile(ArcIcon.lessons, '${_enrollments.length}',
              t('students_courses'), AppColors.byline, _View.enrollments,
              alert: pendingEnrollments > 0),
          tile(ArcIcon.mail, '$activeInvitesCount', t('teacher_invites'),
              AppColors.teal, _View.invites),
        ]),
        DashSection(t('dash_sec_money')),
        DashGrid(children: [
          tile(ArcIcon.review, '$myPendingPayments', t('payment_requests'),
              const Color(0xFFE0A030), _View.payments,
              alert: myPendingPayments > 0),
          tile(ArcIcon.money, Money.iqd(revenue), t('est_revenue'), AppColors.red,
              _View.revenue),
          tile(ArcIcon.tag, '$activeDiscountCodes', t('discount_codes'),
              AppColors.byline, _View.discountCodes),
          tile(ArcIcon.wallet, myPaySet ? '✓' : '—', t('my_payment_number'),
              AppColors.teal, _View.myPayment,
              alert: !myPaySet),
        ]),
        DashSection(t('dash_sec_security')),
        DashGrid(children: [
          tile(ArcIcon.warning, '$_suspiciousCount', t('flagged_logins'),
              AppColors.red, _View.flagged,
              alert: _suspiciousCount > 0),
          tile(ArcIcon.phone, '${_devices.length}', t('trusted_devices'),
              AppColors.teal, _View.devices),
          tile(ArcIcon.alert,
              _errorLogs.length >= 200 ? '200+' : '${_errorLogs.length}',
              t('error_log'),
              AppColors.error, _View.errorLog,
              alert: _errorLogs.isNotEmpty),
        ]),
      ],
    );
  }

  // ---- Drill-in views ----

  Widget _list(int count, Widget Function(int) item) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) =>
            FadeSlideIn(delayMs: (i % 10) * 30, child: item(i)),
      );

  String _priceLabel(Map<String, dynamic> c, String Function(String) t) =>
      c['is_free'] == true ? t('card_free') : Money.text(c['price']);

  Widget _buildCoursesList(String Function(String) t) {
    if (_publishedCourses.isEmpty) {
      return _empty(t('no_courses'), ArcIcon.courses);
    }
    final shown = _publishedCourses.where((c) {
      final teacher = _profileByUser[c['teacher_id']];
      return _hit(
          [c['title'], teacher?['full_name'], _emailByUser[c['teacher_id']]],
          teacher);
    }).toList();
    return _withSearch(t, shown.isEmpty, _list(shown.length, (i) {
      final c = shown[i];
      final teacher = _profileByUser[c['teacher_id']];
      final teacherName = (teacher?['full_name'] as String?) ?? '—';
      final tag = _idTag(teacher);
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.courses, accent: AppColors.teal),
        title: c['title'] as String? ?? '—',
        subtitle: tag == null ? teacherName : '$teacherName · $tag',
        trailing: StatusPill(_priceLabel(c, t),
            tone: c['is_free'] == true ? StatusTone.good : StatusTone.neutral),
        onTap: c['slug'] == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CourseDetailScreen(slug: c['slug'] as String))),
        actions: [
          DashButton(t('btn_delete_course'),
              danger: true,
              icon: ArcIcon.trash,
              onPressed: _busy.contains('course-del-${c['id']}')
                  ? null
                  : () => _deleteCourse(c)),
        ],
      );
    }));
  }

  Widget _person(String? name, String? email, String? phone, String? tag,
          {String? uid}) =>
      DashCard(
        leading: DashAvatar(name: name),
        title: name ?? '—',
        subtitle: email ?? '—',
        meta: [
          if (phone != null && phone.isNotEmpty) phone,
          if (tag != null) tag,
        ],
        actions: [
          if (_canDelete(uid))
            _deleteAccountButton(uid!, AppStrings.instance.t),
        ],
      );

  Widget _buildTeachersList(String Function(String) t) {
    if (_teacherProfiles.isEmpty) return _empty(t('no_teachers'), ArcIcon.award);
    final shown = _teacherProfiles
        .where((p) => _hit([p['full_name'], _emailByUser[p['id']], p['phone']], p))
        .toList()
      ..sort(_idFirst);
    return _withSearch(t, shown.isEmpty, _list(shown.length, (i) {
      final p = shown[i];
      final id = p['id'] as String;
      return DashCard(
        leading: DashAvatar(name: p['full_name'] as String?),
        title: (p['full_name'] as String?) ?? '—',
        subtitle: _emailByUser[id] ?? '—',
        meta: [
          if ((p['phone'] as String?)?.isNotEmpty ?? false) p['phone'] as String,
          if (_idTag(p) != null) _idTag(p)!,
          '${_allCourses.where((c) => c['teacher_id'] == id).length} ${t('stat_courses')}',
        ],
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TeacherProfileScreen(
                teacherId: id,
                fallbackName: p['full_name'] as String?,
                adminView: true,
                email: _emailByUser[id]))),
        actions: [if (_canDelete(id)) _deleteAccountButton(id, t)],
      );
    }));
  }

  Widget _buildStudentsList(String Function(String) t) {
    final userIds =
        {for (final e in _activeEnrollments) e['user_id'] as String}.toList();
    if (userIds.isEmpty) return _empty(t('no_students'), ArcIcon.users);
    final shown = userIds
        .where((uid) => _hit([
              _profileByUser[uid]?['full_name'],
              _emailByUser[uid],
              _profileByUser[uid]?['phone']
            ], _profileByUser[uid]))
        .toList()
      ..sort((a, b) => _idFirst(_profileByUser[a], _profileByUser[b]));
    return _withSearch(t, shown.isEmpty, _list(shown.length, (i) {
      final uid = shown[i];
      final prof = _profileByUser[uid];
      return _person(prof?['full_name'] as String?, _emailByUser[uid],
          prof?['phone'] as String?, _idTag(prof),
          uid: uid);
    }));
  }

  /// What one active enrollment actually paid. Uses the amounts stored on
  /// the enrollment (add-oct05-fixes.sql); older rows fall back to the
  /// student's latest redemption on that course.
  ({int price, int paid, int discount, String? code}) _paidFor(
      Map<String, dynamic> e, Map<String, dynamic> c) {
    final price = (e['list_price'] as num?)?.toInt() ??
        PaymentRules.parsePrice(c['price']);
    final stored = (e['amount_paid'] as num?)?.toInt();
    if (stored != null) {
      final codeRow = _discountCodes
          .where((d) => d['id'] == e['discount_code_id'])
          .firstOrNull;
      return (
        price: price,
        paid: stored,
        discount: (e['discount_amount'] as num?)?.toInt() ?? (price - stored),
        code: codeRow?['code'] as String?,
      );
    }
    final dc = _redemptionsByCourseUser['${c['id']}|${e['user_id']}'];
    if (dc == null) return (price: price, paid: price, discount: 0, code: null);
    final value = (dc['discount_value'] as num?) ?? 0;
    var paid = dc['discount_type'] == 'percent'
        ? (price * (1 - value / 100)).round()
        : (price - value).round();
    if (paid < 0) paid = 0;
    return (
      price: price,
      paid: paid,
      discount: price - paid,
      code: dc['code'] as String?,
    );
  }

  Widget _buildRevenue(String Function(String) t) {
    // Per course: what students paid (after discounts), the platform's 20%
    // of the full price on each, and the teacher's share of the rest. A
    // direct-payment course (allowed teachers only) is the teacher's in full.
    final rows = <Map<String, dynamic>>[];
    int totalCollected = 0, totalPlatform = 0, totalTeacher = 0, totalDirect = 0;
    final owedByTeacher = <String, int>{};
    for (final c in _publishedCourses) {
      if (c['is_free'] == true) continue;
      final price = PaymentRules.parsePrice(c['price']);
      if (price <= 0) continue;
      final direct = c['pay_to_teacher'] == true;
      final enrolled = _activeEnrollments
          .where((e) => e['course_slug'] == c['slug'])
          .toList();
      int paidSum = 0, platform = 0, teacher = 0, discountedCount = 0;
      int discountSum = 0;
      final codes = <String>{};
      DateTime? latest;
      for (final e in enrolled) {
        final r = _paidFor(e, c);
        if (r.discount > 0) {
          discountedCount++;
          discountSum += r.discount;
          if (r.code != null) codes.add(r.code!);
        }
        final s = PaymentRules.split(
            price: r.price, paid: r.paid, directToTeacher: direct);
        paidSum += r.paid;
        // Never book more for the platform than was actually collected.
        final cut = s.platform > r.paid ? r.paid : s.platform;
        platform += cut;
        teacher += r.paid - cut;
        final when = DateTime.tryParse(
            (e['approved_at'] ?? e['created_at'])?.toString() ?? '');
        if (when != null && (latest == null || when.isAfter(latest))) {
          latest = when;
        }
      }
      if (direct) {
        totalDirect += paidSum;
      } else {
        totalCollected += paidSum;
        totalPlatform += platform;
        totalTeacher += teacher;
        final tid = c['teacher_id'] as String?;
        if (tid != null && teacher > 0) {
          owedByTeacher[tid] = (owedByTeacher[tid] ?? 0) + teacher;
        }
      }
      rows.add({
        'c': c,
        'price': price,
        'direct': direct,
        'students': enrolled.length,
        'discounted': discountedCount,
        'discountSum': discountSum,
        'codes': codes.join(', '),
        'latest': latest,
        'paid': paidSum,
        'platform': platform,
        'teacher': teacher,
      });
    }
    rows.sort((a, b) {
      final la = a['latest'] as DateTime?, lb = b['latest'] as DateTime?;
      if (la == null && lb == null) {
        return (b['paid'] as int).compareTo(a['paid'] as int);
      }
      if (la == null) return 1;
      if (lb == null) return -1;
      return lb.compareTo(la);
    });

    if (rows.isEmpty) return _empty(t('no_revenue'), ArcIcon.money);
    String name(String? id) =>
        (_profileByUser[id]?['full_name'] as String?) ?? '—';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashHero(
          title: t('rev_total'),
          subtitle: t('rev_rule'),
          stats: [
            (Money.iqd(totalCollected), t('rev_collected')),
            (Money.iqd(totalPlatform), t('rev_platform_cut')),
            (Money.iqd(totalTeacher), t('rev_teacher_payouts')),
          ],
        ),
        if (owedByTeacher.isNotEmpty) ...[
          DashSection(t('rev_owed_to_teachers')),
          for (final e in owedByTeacher.entries) ...[
            DashCard(
              leading: DashAvatar(name: name(e.key)),
              title: name(e.key),
              subtitle: t('rev_owed_sub'),
              trailing: Text(Money.iqd(e.value),
                  style: AppFonts.code(size: 15, color: AppColors.teal)),
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (totalDirect > 0) ...[
          const SizedBox(height: 4),
          Text('${t('rev_direct_note')} ${Money.iqd(totalDirect)}',
              style: AppFonts.body(size: 12, color: AppColors.muted2)),
        ],
        DashSection(t('rev_by_course')),
        for (final r in rows) ...[
          DashCard(
            leading: DashIconBadge(icon: ArcIcon.money, accent: AppColors.red),
            title: (r['c']['title'] as String?) ?? '—',
            subtitle:
                '${name(r['c']['teacher_id'] as String?)} · ${r['students']} ${t('rev_students')}${r['discounted'] > 0 ? ' (${r['discounted']} ${t('rev_discounted')})' : ''}',
            trailing: r['direct'] == true
                ? StatusPill(t('rev_direct'), tone: StatusTone.neutral)
                : Text(Money.iqd(r['paid'] as int),
                    style: AppFonts.code(size: 15, color: AppColors.red)),
            meta: [
              if (r['latest'] != null)
                '${t('rev_last_payment')}: ${_date((r['latest'] as DateTime).toIso8601String(), time: true)}',
              '${t('rev_price')}: ${Money.iqd(r['price'] as int)}',
              if ((r['discountSum'] as int) > 0)
                '${t('rev_discount')}${(r['codes'] as String).isEmpty ? '' : ' ${r['codes']}'}: -${Money.iqd(r['discountSum'] as int)}',
              r['direct'] == true
                  ? '${t('rev_teacher')}: ${Money.iqd(r['teacher'] as int)} (${t('rev_no_cut')})'
                  : '${t('rev_platform_cut')}: ${Money.iqd(r['platform'] as int)} · ${t('rev_teacher')}: ${Money.iqd(r['teacher'] as int)}',
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  List<Map<String, dynamic>> get _editRequests => _allCourses
      .where((c) => c['edit_status'] == 'pending_review' && c['pending_edit'] is Map)
      .toList();

  Future<void> _approveEdit(Map<String, dynamic> c) =>
      _once('edit-${c['id']}', () async {
    final t = AppStrings.instance.t;
    final edit = (c['pending_edit'] as Map).cast<String, dynamic>();
    final price = PaymentRules.parsePrice(edit['price'] ?? c['price']);
    try {
      final updated =
          await SupabaseService.instance.client.from('courses').update({
        if (edit.containsKey('title')) 'title': edit['title'],
        if (edit.containsKey('description')) 'description': edit['description'],
        if (edit.containsKey('price')) 'price': price,
        if (edit.containsKey('price')) 'is_free': price == 0,
        if (edit.containsKey('thumbnail_url')) 'thumbnail_url': edit['thumbnail_url'],
        if (edit.containsKey('learning_points'))
          'learning_points': edit['learning_points'],
        'pending_edit': null,
        'edit_status': 'approved',
        'edit_reject_reason': null,
      })
          .eq('id', c['id'])
          // The teacher may have sent a newer edit since this screen loaded.
          .eq('edit_status', 'pending_review')
          .select('id');
      if ((updated as List).isEmpty) _showError(t('err_request_gone'));
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _rejectEdit(Map<String, dynamic> c) async {
    final t = AppStrings.instance.t;
    final reason = await askRejectReason(context,
        title: t('edit_reject_title'),
        sub: t('edit_reject_sub'),
        presets: [
          t('edit_reject_price'),
          t('edit_reject_content'),
          t('edit_reject_image'),
        ]);
    if (reason == null) return;
    try {
      await SupabaseService.instance.client.from('courses').update({
        'pending_edit': null,
        'edit_status': 'rejected',
        'edit_reject_reason': reason,
      }).eq('id', c['id']);
      await _loadAll();
    } catch (_) {
      _showError(t('err_generic_failed'));
    }
  }

  /// Everything waiting on the admin, in one list. Each item opens the
  /// screen where it's handled.
  Widget _buildAttention(String Function(String) t) {
    final payments =
        _pendingPayments.where((e) => !_teacherPaid(e)).toList();
    final total = payments.length +
        _pendingReview.length +
        _editRequests.length +
        _pendingUploads.length +
        _pendingFiles.length +
        _reports.length;
    if (total == 0) return _empty(t('attention_none'), ArcIcon.check);
    String teacherOf(dynamic id) =>
        (_profileByUser[id]?['full_name'] as String?) ?? '—';
    Widget item(ArcIcon icon, Color accent, String title, String sub,
            String pill, _View go) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DashCard(
            leading: DashIconBadge(icon: icon, accent: accent),
            title: title,
            subtitle: sub,
            trailing: StatusPill(pill, tone: StatusTone.warn),
            onTap: () => _goto(go),
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (payments.isNotEmpty) ...[
          DashSection('${t('payment_requests')} (${payments.length})'),
          for (final e in payments)
            item(
                ArcIcon.money,
                AppColors.teal,
                (_profileByUser[e['user_id']]?['full_name'] as String?) ??
                    _emailByUser[e['user_id']] ??
                    '—',
                '${_courseTitle(e['course_slug'] as String)} · ${_date(e['created_at'] as String?, time: true)}',
                t('attention_payment'),
                _View.payments),
        ],
        if (_pendingUploads.isNotEmpty) ...[
          DashSection('${t('pending_lectures')} (${_pendingUploads.length})'),
          for (final l in _pendingUploads)
            item(
                ArcIcon.video,
                AppColors.red,
                l['title'] as String? ?? '—',
                (_allCourses.where((c) => c['id'] == l['course_id']).firstOrNull?['title']
                        as String?) ??
                    '—',
                t('attention_lecture'),
                _View.uploads),
        ],
        if (_reports.isNotEmpty) ...[
          DashSection('${t('reports_title')} (${_reports.length})'),
          for (final r in _reports)
            item(
                ArcIcon.warning,
                AppColors.error,
                ((r['courses'] as Map?)?['title'] as String?) ?? '—',
                t('report_reason_${r['reason']}'),
                t('attention_report'),
                _View.reports),
        ],
        if (_pendingFiles.isNotEmpty) ...[
          DashSection('${t('pending_files')} (${_pendingFiles.length})'),
          for (final f in _pendingFiles)
            item(
                ArcIcon.lessons,
                AppColors.teal,
                f['title'] as String? ?? '—',
                (_allCourses.where((c) => c['id'] == f['course_id']).firstOrNull?['title']
                        as String?) ??
                    '—',
                t('attention_file'),
                _View.files),
        ],
        if (_pendingReview.isNotEmpty) ...[
          DashSection('${t('course_review')} (${_pendingReview.length})'),
          for (final c in _pendingReview)
            item(ArcIcon.review, AppColors.byline, c['title'] as String? ?? '—',
                teacherOf(c['teacher_id']), t('attention_course'), _View.review),
        ],
        if (_editRequests.isNotEmpty) ...[
          DashSection('${t('edit_requests')} (${_editRequests.length})'),
          for (final c in _editRequests)
            item(ArcIcon.edit, AppColors.byline, c['title'] as String? ?? '—',
                teacherOf(c['teacher_id']), t('attention_edit'), _View.editRequests),
        ],
      ],
    );
  }

  Widget _buildEditRequests(String Function(String) t) {
    final list = _editRequests;
    if (list.isEmpty) return _empty(t('no_edit_requests'), ArcIcon.edit);
    String text(dynamic v) => v is List ? v.join('\n') : '${v ?? ''}';
    return _list(list.length, (i) {
      final c = list[i];
      final edit = (c['pending_edit'] as Map).cast<String, dynamic>();
      final changes = <Widget>[];
      void field(String key, String label) {
        if (!edit.containsKey(key)) return;
        final before = key == 'price'
            ? '${PaymentRules.parsePrice(c[key])}'
            : text(c[key]);
        final after = key == 'price'
            ? '${PaymentRules.parsePrice(edit[key])}'
            : text(edit[key]);
        if (before.trim() == after.trim()) return;
        changes.add(_ChangeRow(label: label, before: before, after: after));
      }
      field('title', t('field_title'));
      field('description', t('field_description'));
      field('price', t('field_price'));
      field('learning_points', t('field_learning_points'));
      final thumbChanged = edit.containsKey('thumbnail_url') &&
          edit['thumbnail_url'] != c['thumbnail_url'];
      if (thumbChanged) {
        changes.add(_ThumbChange(
            label: t('field_thumbnail'),
            before: c['thumbnail_url'] as String?,
            after: edit['thumbnail_url'] as String?));
      }
      return DashCard(
        leading: SizedBox(
          width: 64,
          height: 48,
          child: CourseThumb(url: c['thumbnail_url'] as String?, radius: 10),
        ),
        title: c['title'] as String? ?? '—',
        subtitle:
            (_profileByUser[c['teacher_id']]?['full_name'] as String?) ?? '—',
        trailing: StatusPill(t('edit_pending'), tone: StatusTone.warn),
        extra: [
          const SizedBox(height: 12),
          if (changes.isEmpty)
            Text(t('no_edit_requests'),
                style: AppFonts.body(size: 12, color: AppColors.muted2))
          else
            ...changes,
        ],
        actions: [
          DashButton(t('btn_approve_edit'),
              primary: true, icon: ArcIcon.check, onPressed: () => _approveEdit(c)),
          DashButton(t('btn_reject'),
              danger: true, icon: ArcIcon.close, onPressed: () => _rejectEdit(c)),
        ],
      );
    });
  }

  List<Map<String, dynamic>> get _pendingPayments {
    final list = _enrollments.where((e) => e['status'] != 'active').toList();
    list.sort((a, b) => ((b['created_at'] as String?) ?? '')
        .compareTo((a['created_at'] as String?) ?? ''));
    return list;
  }

  bool _teacherPaid(Map<String, dynamic> e) {
    final c = _courseBySlug[e['course_slug']];
    return c?['pay_to_teacher'] == true && c?['teacher_id'] != null;
  }

  Widget _buildPayments(String Function(String) t) {
    final all = _pendingPayments;
    if (all.isEmpty) return _empty(t('no_payment_requests'), ArcIcon.check);
    final list = all.where((e) {
      final uid = e['user_id'] as String;
      final p = _profileByUser[uid];
      return _hit([
        p?['full_name'],
        _emailByUser[uid],
        p?['phone'],
        _courseTitle(e['course_slug'] as String)
      ], p);
    }).toList()
      ..sort((a, b) => _idFirst(_profileByUser[a['user_id']], _profileByUser[b['user_id']]));
    return _withSearch(t, list.isEmpty, _list(list.length, (i) {
      final e = list[i];
      final uid = e['user_id'] as String;
      final prof = _profileByUser[uid];
      final course = _courseBySlug[e['course_slug']];
      final teacherPaid = _teacherPaid(e);
      final teacherName =
          _profileByUser[course?['teacher_id']]?['full_name'] as String? ?? '—';
      final proof = e['payment_proof_path'] as String?;
      return PaymentRequestCard(
        studentName: prof?['full_name'] as String? ?? _emailByUser[uid] ?? '—',
        contact: [_emailByUser[uid], prof?['phone'], _idTag(prof)]
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .join(' · '),
        courseTitle: _courseTitle(e['course_slug'] as String),
        price: course?['price']?.toString(),
        discount: course == null ? null : _paidFor(e, course).discount,
        paid: course == null ? null : _paidFor(e, course).paid,
        code: course == null ? null : _paidFor(e, course).code,
        method: e['payment_method'] as String?,
        detail: e['payment_detail'] as String?,
        createdAt: _date(e['created_at'] as String?, time: true),
        canDecide: !teacherPaid,
        decidedByNote: teacherPaid
            ? t('decided_by_teacher').replaceAll('{name}', Bidi.iso(teacherName))
            : null,
        onViewProof: proof == null ? null : () => _viewProof(proof),
        onApprove: () => _approve(e['id'] as String),
        onReject: () => _rejectEnrollment(e['id'] as String),
      );
    }));
  }

  Widget _buildEnrollments(String Function(String) t) {
    if (_enrollments.isEmpty) return _empty(t('no_enrollments'), ArcIcon.lessons);
    _enrollments.sort((a, b) => ((b['created_at'] as String?) ?? '')
        .compareTo((a['created_at'] as String?) ?? ''));
    final rows = _enrollments.where((e) {
      final uid = e['user_id'] as String;
      final p = _profileByUser[uid];
      return _hit([
        p?['full_name'],
        _emailByUser[uid],
        p?['phone'],
        _courseTitle(e['course_slug'] as String)
      ], p);
    }).toList()
      ..sort((a, b) => _idFirst(_profileByUser[a['user_id']], _profileByUser[b['user_id']]));
    return _withSearch(t, rows.isEmpty, _list(rows.length, (i) {
      final e = rows[i];
      final userId = e['user_id'] as String;
      final prof = _profileByUser[userId];
      final email = _emailByUser[userId] ?? '—';
      final title = _courseTitle(e['course_slug'] as String);
      final isActive = e['status'] == 'active';
      final proofPath = e['payment_proof_path'] as String?;
      final payment = e['payment_method'] != null
          ? '${e['payment_method']}${e['payment_detail'] != null ? ' — ${e['payment_detail']}' : ''}'
          : '—';
      final approvedBy = e['approved_by'] as String?;
      return DashCard(
        leading: DashAvatar(name: prof?['full_name'] as String? ?? email),
        title: email,
        titleStyle: AppFonts.body(size: 14, weight: FontWeight.w700),
        subtitle: title,
        trailing: StatusPill(
            isActive ? t('status_active') : t('status_pending'),
            tone: isActive ? StatusTone.good : StatusTone.warn),
        meta: [
          if (prof?['full_name'] != null || prof?['phone'] != null)
            '${prof?['full_name'] ?? '—'} · ${prof?['phone'] ?? '—'}${_idTag(prof) != null ? ' · ${_idTag(prof)}' : ''}',
          '$payment · ${_date(e['created_at'] as String?)}',
          if (approvedBy != null)
            '${t('approved_by')}: ${_emailByUser[approvedBy] ?? approvedBy} · ${_date(e['approved_at'] as String?, time: true)}',
        ],
        actions: [
          if (!isActive && !_teacherPaid(e))
            DashButton(t('approve'),
                primary: true,
                icon: ArcIcon.check,
                onPressed: _busy.contains(e['id'])
                    ? null
                    : () => _approve(e['id'] as String)),
          if (proofPath != null)
            DashButton(t('view_proof'),
                icon: ArcIcon.image, onPressed: () => _viewProof(proofPath)),
          DashButton(t('remove'),
              danger: true,
              icon: ArcIcon.trash,
              onPressed: () =>
                  _removeEnrollment(e['id'] as String, title, email)),
        ],
      );
    }));
  }

  Widget _buildReview(String Function(String) t) {
    if (_pendingReview.isEmpty) return _empty(t('no_review'), ArcIcon.review);
    return _list(_pendingReview.length, (i) {
      final c = _pendingReview[i];
      final teacherName =
          (_profileByUser[c['teacher_id']]?['full_name'] as String?) ?? '—';
      final id = c['id'] as String;
      final title = c['title'] as String? ?? '—';
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.review, accent: AppColors.red),
        title: title,
        subtitle: '$teacherName · ${_priceLabel(c, t)}',
        extra: [
          // Direct payment is a per-teacher privilege (direct_payment_allowed).
          if (_profileByUser[c['teacher_id']]?['direct_payment_allowed'] == true) ...[
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _togglePayToTeacher(c, c['pay_to_teacher'] != true),
            child: Row(children: [
              Checkbox(
                  value: c['pay_to_teacher'] == true,
                  onChanged: (v) => _togglePayToTeacher(c, v ?? false)),
              Text(t('pay_to_teacher'),
                  style: AppFonts.body(size: 13, color: AppColors.muted)),
            ]),
          ),
          ],
        ],
        actions: [
          DashButton(t('btn_publish'),
              primary: true,
              icon: ArcIcon.check,
              onPressed: () => _publishCourse(id)),
          DashButton(t('btn_reject'),
              danger: true,
              icon: ArcIcon.close,
              onPressed: () => _rejectCourse(id, title)),
        ],
      );
    });
  }

  Widget _buildInvites(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashButton(t('create_invite'),
            primary: true, icon: ArcIcon.plus, onPressed: _createInvite),
        const SizedBox(height: 12),
        if (_invites.isEmpty)
          DashEmpty(icon: ArcIcon.mail, message: t('no_invites'))
        else
          for (final inv in _invites) ...[
            _inviteRow(inv, t),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _inviteRow(Map<String, dynamic> inv, String Function(String) t) {
    final usedAt = inv['used_at'];
    final expiresAt = DateTime.tryParse(inv['expires_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final status = usedAt != null
        ? 'used'
        : (expiresAt.isBefore(DateTime.now()) ? 'expired' : 'unused');
    final usedByName = inv['used_by'] != null
        ? (_profileByUser[inv['used_by']]?['full_name'] ?? '—')
        : '—';
    return DashCard(
      leading: DashIconBadge(icon: ArcIcon.mail, accent: AppColors.teal),
      title: '${t('invite_created')} ${_date(inv['created_at'] as String?)}',
      titleStyle: AppFonts.body(size: 14, weight: FontWeight.w700),
      subtitle:
          '${t('invite_expires')} ${expiresAt.toLocal().toString().split(' ').first} · ${t('invite_used_by')}: $usedByName',
      trailing: StatusPill(t('st_$status'),
          tone: switch (status) {
            'unused' => StatusTone.good,
            'used' => StatusTone.neutral,
            _ => StatusTone.bad,
          }),
      // The app redeems invites by code (Sign up > "Have an invite code?"),
      // so an open invite shows its code with a one-tap copy; the old web
      // ?invite= links no longer lead anywhere.
      extra: [
        if (status == 'unused' && inv['token'] != null) ...[
          const SizedBox(height: 12),
          _InviteCode(code: inv['token'] as String),
          const SizedBox(height: 6),
          Text(t('invite_code_hint'),
              style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
        ],
      ],
      actions: [
        if (status == 'unused')
          DashButton(t('btn_revoke'),
              danger: true,
              icon: ArcIcon.close,
              onPressed: () => _revokeInvite(inv['id'] as String)),
      ],
    );
  }

  Future<void> _approveLecture(Map<String, dynamic> l) =>
      _once(l['id'] as String, () async {
    final t = AppStrings.instance.t;
    final pending = (l['pending_upload_path'] as String?) ?? '';
    if (!pending.startsWith('r2:')) return;
    try {
      await SupabaseService.instance.client.from('lectures').update({
        'r2_path': pending.substring(3),
        'pending_upload_path': null,
      }).eq('id', l['id']);
      // Live now as the 1080p upload; the multi-quality version replaces
      // it by itself when the background conversion finishes.
      final token =
          SupabaseService.instance.client.auth.currentSession?.accessToken;
      if (token != null) {
        ApiService.startLectureConversion(l['id'] as String, token);
      }
      _showError(t('lecture_published_converting'));
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Future<void> _rejectLecture(Map<String, dynamic> l) =>
      _once(l['id'] as String, () async {
    final t = AppStrings.instance.t;
    final reason = await askRejectReason(context,
        title: t('lecture_reject_title'),
        sub: t('lecture_reject_sub'),
        presets: [
          t('lecture_reject_quality'),
          t('lecture_reject_content'),
          t('lecture_reject_wrong'),
        ]);
    if (reason == null) return;
    try {
      final id = l['id'] as String;
      // Reject first: if it fails the uploaded file must still be there.
      await SupabaseService.instance.client.rpc('reject_lecture',
          params: {'p_lecture_id': id, 'p_reason': reason});
      if (((l['pending_upload_path'] as String?) ?? '').startsWith('r2:')) {
        await R2Upload.deleteObject(id);
      }
      await _loadAll();
    } catch (e) {
      _showError(ErrorReporter.userMessage(e, page: 'admin'));
    }
  });

  Widget _buildUploads(String Function(String) t) {
    if (_pendingUploads.isEmpty) return _empty(t('no_uploads'), ArcIcon.video);
    return _list(_pendingUploads.length, (i) {
      final l = _pendingUploads[i];
      final course = _allCourses.firstWhere((c) => c['id'] == l['course_id'],
          orElse: () => <String, dynamic>{});
      final teacher =
          (_profileByUser[course['teacher_id']]?['full_name'] as String?) ?? '—';
      final isR2 = ((l['pending_upload_path'] as String?) ?? '').startsWith('r2:');
      final secs = (l['duration_seconds'] as num?)?.toInt();
      final dur = secs == null
          ? null
          : '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.video, accent: AppColors.byline),
        title: l['title'] as String? ?? '—',
        subtitle: '${course['title'] ?? '—'} · $teacher',
        trailing: StatusPill(t('lecture_pending_review'), tone: StatusTone.warn),
        meta: [if (dur != null) dur],
        extra: [
          if (!isR2) ...[
            const SizedBox(height: 8),
            Text(t('legacy_upload_hint'),
                style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
          ],
        ],
        actions: [
          if (isR2) ...[
            DashButton(t('btn_approve_publish'),
                primary: true,
                icon: ArcIcon.check,
                onPressed: () => _approveLecture(l)),
            DashButton(t('btn_preview'),
                icon: ArcIcon.play,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => VideoPlayerScreen(
                          lectureId: l['id'] as String,
                          title: l['title'] as String? ?? '',
                          preview: true,
                        )))),
          ],
          DashButton(t('btn_reject'),
              danger: true, icon: ArcIcon.close, onPressed: () => _rejectLecture(l)),
        ],
      );
    });
  }

  Widget _buildReports(String Function(String) t) {
    if (_reports.isEmpty) return _empty(t('no_reports'), ArcIcon.check);
    return _list(_reports.length, (i) {
      final r = _reports[i];
      final course = (r['courses'] as Map?) ?? const {};
      final reporter = _profileByUser[r['reporter_id']];
      final tag = _idTag(reporter);
      final teacher =
          (_profileByUser[course['teacher_id']]?['full_name'] as String?) ?? '—';
      final busy = _busy.contains('report-${r['id']}');
      final details = (r['details'] as String?)?.trim() ?? '';
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.warning, accent: AppColors.error),
        title: course['title'] as String? ?? '—',
        subtitle: teacher,
        trailing: StatusPill(t('report_reason_${r['reason']}'), tone: StatusTone.bad),
        meta: [
          if (details.isNotEmpty) details,
          [
            (reporter?['full_name'] as String?) ?? _emailByUser[r['reporter_id']] ?? '—',
            if (tag != null) tag,
          ].join(' · '),
          _date(r['created_at'] as String?, time: true),
        ],
        actions: [
          if (course['slug'] != null)
            DashButton(t('btn_open_course'),
                icon: ArcIcon.courses,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        CourseDetailScreen(slug: course['slug'] as String)))),
          DashButton(t('btn_resolve'),
              primary: true,
              icon: ArcIcon.check,
              onPressed: busy ? null : () => _closeReport(r, 'resolved')),
          DashButton(t('btn_dismiss_report'),
              icon: ArcIcon.close,
              onPressed: busy ? null : () => _closeReport(r, 'dismissed')),
        ],
      );
    });
  }

  Widget _buildPendingFiles(String Function(String) t) {
    if (_pendingFiles.isEmpty) {
      return _empty(t('no_pending_files'), ArcIcon.lessons);
    }
    return _list(_pendingFiles.length, (i) {
      final f = _pendingFiles[i];
      final course = _allCourses.firstWhere((c) => c['id'] == f['course_id'],
          orElse: () => <String, dynamic>{});
      final teacher =
          (_profileByUser[course['teacher_id']]?['full_name'] as String?) ?? '—';
      final lecture = (f['lectures'] as Map?)?['title'] as String?;
      final busy = _busy.contains('file-${f['id']}');
      final viewable = f['view_type'] == 'pdf' || f['view_type'] == 'image';
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.lessons, accent: AppColors.teal),
        title: f['title'] as String? ?? '—',
        subtitle: '${course['title'] ?? '—'} · $teacher',
        trailing: StatusPill(t('file_pending_review'), tone: StatusTone.warn),
        meta: [
          lecture ?? t('file_whole_course'),
          if ((f['original_name'] as String?)?.isNotEmpty ?? false)
            f['original_name'] as String,
          f['allow_download'] == true
              ? t('file_downloadable')
              : t('file_view_only'),
        ],
        actions: [
          DashButton(t('btn_approve'),
              primary: true,
              icon: ArcIcon.check,
              onPressed: busy ? null : () => _reviewFile(f, true)),
          DashButton(t('btn_preview'),
              icon: viewable ? ArcIcon.image : ArcIcon.download,
              onPressed: () {
                if (viewable) {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CourseFileViewerScreen(file: f)));
                } else {
                  downloadCourseFile(context, f);
                }
              }),
          DashButton(t('btn_reject'),
              danger: true,
              icon: ArcIcon.close,
              onPressed: busy ? null : () => _reviewFile(f, false)),
        ],
      );
    });
  }

  /// Suspicious logins and security events in one timeline, newest first,
  /// each with its reason and quick actions on the account.
  Widget _buildFlagged(String Function(String) t) {
    final items = <Map<String, dynamic>>[
      for (final f in _flagged)
        {
          'user_id': f['user_id'],
          'reason': switch (f['flag_reason']) {
            'outside_iraq' => t('sec_outside_iraq'),
            'travel' => t('sec_travel'),
            _ => t('sec_location_change'),
          },
          'detail': [
            '${f['city'] ?? '—'}, ${f['country'] ?? '—'}',
            if (f['distance_km'] != null) '${f['distance_km']} ${t('km')}',
          ].join(' · '),
          'email': f['email'],
          'at': f['created_at'],
          'icon': ArcIcon.warning,
        },
      for (final e in _securityEvents)
        {
          'user_id': e['user_id'],
          'reason': switch (e['kind']) {
            'device_blocked' => t('sec_device_blocked'),
            'shared_device' => t('sec_shared_device'),
            'screen_record' => t('sec_screen_record'),
            _ => t('sec_screenshot'),
          },
          'detail': ((e['detail'] as Map?)?['device_label'] ??
                  (e['detail'] as Map?)?['screen'] ??
                  '')
              .toString(),
          'email': null,
          'at': e['created_at'],
          'icon': e['kind'] == 'screenshot' || e['kind'] == 'screen_record'
              ? ArcIcon.image
              : ArcIcon.phone,
        },
    ]..sort((a, b) =>
        (b['at']?.toString() ?? '').compareTo(a['at']?.toString() ?? ''));
    if (items.isEmpty) return _empty(t('no_flagged'), ArcIcon.warning);
    final shown = items.where((it) {
      final uid = it['user_id'] as String?;
      final prof = _profileByUser[uid];
      return _hit([
        prof?['full_name'],
        _emailByUser[uid] ?? it['email'],
        prof?['phone'],
        it['reason'],
        it['detail'],
      ], prof);
    }).toList()
      ..sort((a, b) => _idFirst(
          _profileByUser[a['user_id']], _profileByUser[b['user_id']]));
    return _withSearch(
        t,
        shown.isEmpty,
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: DashButton(t('btn_clear_all'),
                  danger: true,
                  icon: ArcIcon.trash,
                  onPressed: _busy.contains('clear-suspicious')
                      ? null
                      : _clearSuspicious),
            ),
            const SizedBox(height: 8),
            for (final it in shown) ...[
              _flaggedCard(it, t),
              const SizedBox(height: 10),
            ],
          ],
        ));
  }

  Widget _flaggedCard(Map<String, dynamic> it, String Function(String) t) {
    final uid = it['user_id'] as String?;
    final prof = _profileByUser[uid];
    final name = (prof?['full_name'] as String?) ??
        (it['email'] as String?) ??
        _emailByUser[uid] ??
        '—';
    final detail = it['detail'] as String;
    final tag = _idTag(prof);
    return DashCard(
      leading:
          DashIconBadge(icon: it['icon'] as ArcIcon, accent: AppColors.error),
      title: name,
      titleStyle: AppFonts.body(size: 14, weight: FontWeight.w700),
      subtitle: _emailByUser[uid] ?? (it['email'] as String?) ?? '—',
      trailing: StatusPill(it['reason'] as String, tone: StatusTone.bad),
      meta: [
        if (tag != null) tag,
        if (detail.isNotEmpty) detail,
        _date(it['at']?.toString(), time: true),
      ],
      actions: uid == null
          ? const []
          : [
              DashButton(t('btn_force_logout'),
                  icon: ArcIcon.logout,
                  onPressed: _busy.contains('logout-$uid')
                      ? null
                      : () => _forceLogout(uid)),
              DashButton(t('btn_reset_devices'),
                  danger: true,
                  icon: ArcIcon.phone,
                  onPressed: _busy.contains('reset-$uid')
                      ? null
                      : () => _resetDevices(uid)),
              if (_canDelete(uid)) _deleteAccountButton(uid, t),
            ],
    );
  }

  Widget _buildDevices(String Function(String) t) {
    if (_devices.isEmpty) return _empty(t('no_devices'), ArcIcon.phone);
    final shown = _devices.where((d) {
      final uid = d['user_id'] as String;
      final prof = _profileByUser[uid];
      return _hit(
          [prof?['full_name'], _emailByUser[uid], prof?['phone'], d['device_label']],
          prof);
    }).toList()
      ..sort((a, b) => _idFirst(
          _profileByUser[a['user_id']], _profileByUser[b['user_id']]));
    return _withSearch(t, shown.isEmpty, _list(shown.length, (i) {
      final d = shown[i];
      final uid = d['user_id'] as String;
      final prof = _profileByUser[uid];
      final email = _emailByUser[uid] ?? '—';
      final tag = _idTag(prof);
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.phone, accent: AppColors.teal),
        title: (prof?['full_name'] as String?) ?? email,
        titleStyle: AppFonts.body(size: 14, weight: FontWeight.w700),
        subtitle: email,
        meta: [
          if (tag != null) tag,
          d['device_label'] as String? ?? '—',
          '${t('th_first_seen')}: ${_date(d['first_seen'] as String?)}',
          '${t('th_last_seen')}: ${_date(d['last_seen'] as String?, time: true)}',
        ],
        actions: [
          DashButton(t('remove'),
              danger: true,
              icon: ArcIcon.trash,
              onPressed: () => _removeDevice(d['id'] as String, email)),
          if (_canDelete(uid)) _deleteAccountButton(uid, t),
        ],
      );
    }));
  }

  Widget _buildDiscountCodes(String Function(String) t) {
    if (_discountCodes.isEmpty) {
      return _empty(t('no_discount_codes'), ArcIcon.tag);
    }
    final codes = _discountCodes.where((c) {
      final course = _allCourses.firstWhere((cc) => cc['id'] == c['course_id'],
          orElse: () => {});
      final teacher = _profileByUser[course['teacher_id']];
      return _hit([c['code'], course['title'], teacher?['full_name']], teacher);
    }).toList();
    return _withSearch(t, codes.isEmpty, _list(codes.length, (i) {
      final c = codes[i];
      final courseId = c['course_id'];
      final course = _allCourses.firstWhere((cc) => cc['id'] == courseId,
          orElse: () => {});
      final teacherName =
          (_profileByUser[course['teacher_id']]?['full_name'] as String?) ??
              '—';
      final expired = DateTime.tryParse(c['expires_at'] as String? ?? '')
              ?.isBefore(DateTime.now()) ??
          true;
      final status = c['is_active'] != true
          ? 'inactive'
          : (expired ? 'expired' : 'active');
      final discount = c['discount_type'] == 'percent'
          ? '${c['discount_value']}%'
          : Money.iqd((c['discount_value'] as num?) ?? 0);
      return DashCard(
        leading: DashIconBadge(icon: ArcIcon.tag, accent: AppColors.byline),
        title: c['code'] as String? ?? '—',
        titleStyle: AppFonts.code(size: 15),
        subtitle: '${course['title'] ?? '—'} · $teacherName',
        trailing: StatusPill(t('st_$status'),
            tone: status == 'active' ? StatusTone.good : StatusTone.bad),
        meta: ['$discount · ${c['used_count']}/${c['max_uses']} ${t('codes_used')}'],
      );
    }));
  }

  Widget _buildErrorLog(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (_errorLogs.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: DashButton(t('btn_clear_all'),
                danger: true, icon: ArcIcon.trash, onPressed: _clearErrorLog),
          ),
        const SizedBox(height: 8),
        if (_errorLogs.isEmpty)
          DashEmpty(icon: ArcIcon.check, message: t('no_errors'))
        else
          for (final e in _errorLogs) ...[
            DashCard(
              leading: DashIconBadge(icon: ArcIcon.alert, accent: AppColors.error),
              title: e['message'] as String? ?? '—',
              titleStyle: AppFonts.body(size: 13, weight: FontWeight.w600),
              meta: [
                '${e['page'] ?? '—'} · ${e['user_id'] != null ? (_emailByUser[e['user_id']] ?? e['user_id']) : '—'}',
                _date(e['created_at'] as String?, time: true),
              ],
              actions: [
                DashButton(t('btn_dismiss'),
                    icon: ArcIcon.check,
                    onPressed: () => _dismissError(e['id'] as String)),
              ],
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildMyPayment(String Function(String) t) {
    if (!_payLoaded) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        DashFormPanel(
          title: t('my_payment_number'),
          icon: ArcIcon.wallet,
          children: [
            Text(t('my_payment_hint'),
                style: AppFonts.body(size: 12.5, color: AppColors.muted)),
            const SizedBox(height: 14),
            TextField(
                controller: _payZainCtrl,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.number,
                inputFormatters: PaymentRules.numberInput,
                decoration: InputDecoration(
                    labelText: t('label_zaincash_phone'),
                    hintText: '07XX XXX XXXX')),
            const SizedBox(height: 12),
            TextField(
                controller: _payQiCtrl,
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
              file: _payQrFile,
              existingUrl: _payQrUrl,
              emptyLabel: t('pick_qr'),
              height: 200,
              onPick: () async {
                final picked = await SafePicker.image(imageQuality: 90);
                if (picked != null) setState(() => _payQrFile = picked);
              },
              onRemove: () => setState(() => _payQrFile = null),
            ),
            if (_payError != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_payError!,
                      style: AppFonts.body(size: 12, color: AppColors.error))),
            if (_payOk != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_payOk!,
                      style: AppFonts.body(size: 12, color: AppColors.teal))),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _saveMyPayment, child: Text(t('save'))),
          ],
        ),
      ],
    );
  }

  Widget _empty(String message, ArcIcon icon) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [DashEmpty(icon: icon, message: message)],
      );
}

/// An invite code in a monospace box with a copy button beside it.
class _InviteCode extends StatelessWidget {
  final String code;
  const _InviteCode({required this.code});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.instance.t('copied')),
        duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.teal.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              code,
              maxLines: 1,
              textDirection: TextDirection.ltr,
              style: AppFonts.code(size: 12.5, color: AppColors.text),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => _copy(context),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              backgroundColor: AppColors.teal,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const ArcIconView(ArcIcon.copy, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(AppStrings.instance.t('btn_copy')),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Amber call-to-action at the top of the dashboard while payment requests
/// are waiting on this admin.
class _PendingBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _PendingBanner({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFE0A030);
    final t = AppStrings.instance.t;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: amber.withValues(alpha: 0.12),
            border: Border.all(color: amber.withValues(alpha: 0.5)),
          ),
          child: Row(children: [
            const DashIconBadge(icon: ArcIcon.review, accent: amber, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      t('pending_payments_banner')
                          .replaceAll('{n}', '$count'),
                      style: AppFonts.body(size: 14.5, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(t('pending_payments_banner_sub'),
                      style: AppFonts.body(size: 12, color: AppColors.muted)),
                ],
              ),
            ),
            ArcIconView(ArcIcon.chevron, size: 18, color: amber),
          ]),
        ),
      ),
    );
  }
}

/// One changed field in an edit request: label, then before (struck,
/// muted) and after (highlighted).
class _ChangeRow extends StatelessWidget {
  final String label;
  final String before;
  final String after;
  const _ChangeRow(
      {required this.label, required this.before, required this.after});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    Widget box(String tag, String text, Color c, {bool strike = false}) =>
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: c.withValues(alpha: 0.08),
            border: Border.all(color: c.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tag,
                  style: AppFonts.body(
                      size: 10.5, weight: FontWeight.w700, color: c)),
              const SizedBox(height: 3),
              Text(text.isEmpty ? '—' : text,
                  style: AppFonts.body(
                          size: 13,
                          color: strike ? AppColors.muted : AppColors.text)
                      .copyWith(
                          decoration:
                              strike ? TextDecoration.lineThrough : null)),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppFonts.body(size: 13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          box(t('before'), before, AppColors.muted, strike: true),
          const SizedBox(height: 6),
          box(t('after'), after, AppColors.teal),
        ],
      ),
    );
  }
}

/// Old and new course image side by side.
class _ThumbChange extends StatelessWidget {
  final String label;
  final String? before;
  final String? after;
  const _ThumbChange({required this.label, this.before, this.after});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    Widget img(String tag, String? url, Color c) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tag,
                  style: AppFonts.body(
                      size: 10.5, weight: FontWeight.w700, color: c)),
              const SizedBox(height: 4),
              AspectRatio(
                aspectRatio: 16 / 10,
                child: CourseThumb(url: url, radius: 12),
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppFonts.body(size: 13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(children: [
            img(t('before'), before, AppColors.muted),
            const SizedBox(width: 10),
            img(t('after'), after, AppColors.teal),
          ]),
        ],
      ),
    );
  }
}
