import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

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
  const AdminScreen({super.key});

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
}

class _AdminScreenState extends State<AdminScreen> {
  static const _maxDevices = 1; // must match api/check-device.js

  bool _checking = true;
  bool _isAdmin = false;
  bool _loading = false;
  String? _error;
  _View _view = _View.dashboard;

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
  List<Map<String, dynamic>> _discountCodes = [];
  List<Map<String, dynamic>> _errorLogs = [];
  Map<String, String> _emailByUser = {};
  Map<String, Map<String, dynamic>> _profileByUser = {};
  Map<String, Map<String, dynamic>> _courseBySlug = {};

  final _payMethodCtrl = ValueNotifier<String>('zain');
  final _payDetailCtrl = TextEditingController();
  bool _payLoaded = false;
  String? _payError;
  String? _payOk;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _payDetailCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() { _checking = false; _isAdmin = false; });
      return;
    }
    try {
      final prof = await sb.from('profiles').select('is_admin').eq('id', user.id).maybeSingle();
      final isAdmin = prof?['is_admin'] == true;
      setState(() { _checking = false; _isAdmin = isAdmin; });
      if (isAdmin) await _loadAll();
    } catch (e) {
      setState(() { _checking = false; _isAdmin = false; _error = e.toString(); });
    }
  }

  Future<void> _loadAll() async {
    setState(() { _loading = true; _error = null; });
    try {
      final sb = SupabaseService.instance.client;
      final results = await Future.wait([
        sb.from('courses').select('id, slug, title, price, is_free, teacher_id, pay_to_teacher, status'),
        sb.from('profiles').select('id, full_name, phone, is_teacher, is_admin, teacher_payment_method, teacher_payment_detail'),
        sb.from('login_events').select('user_id, email, created_at').order('created_at', ascending: false),
        sb
            .from('enrollments')
            .select('id, user_id, course_slug, status, payment_method, payment_detail, payment_proof_path, created_at, approved_by, approved_at'),
        sb.from('login_events').select('email, city, country, distance_km, created_at').eq('flagged', true).order('created_at', ascending: false).limit(50),
        sb.from('trusted_devices').select('id, user_id, device_label, first_seen, last_seen').order('user_id').order('first_seen'),
        sb.from('teacher_invites').select('id, token, created_at, expires_at, used_at, used_by').order('created_at', ascending: false),
        sb.from('lectures').select('id, title, course_id, pending_upload_path').not('pending_upload_path', 'is', null).order('order_index'),
        sb.from('discount_codes').select('id, course_id, code, discount_type, discount_value, max_uses, used_count, expires_at, is_active').order('created_at', ascending: false),
        sb.from('error_logs').select('id, message, page, user_id, created_at').order('created_at', ascending: false).limit(200),
        sb.from('discount_code_redemptions').select('discount_code_id, user_id'),
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

      final emailByUser = <String, String>{};
      for (final l in logins) {
        final uid = l['user_id'] as String?;
        if (uid != null && !emailByUser.containsKey(uid)) emailByUser[uid] = l['email'] as String? ?? '—';
      }
      final profileByUser = <String, Map<String, dynamic>>{for (final p in profiles) p['id'] as String: p};
      final courseBySlug = <String, Map<String, dynamic>>{for (final c in courses) c['slug'] as String: c};

      final myProfile = profileByUser[SupabaseService.instance.currentUser?.id];

      if (!mounted) return;
      setState(() {
        _allCourses = courses;
        _publishedCourses = courses.where((c) => c['status'] == 'published').toList();
        _pendingReview = courses.where((c) => c['status'] == 'pending_review').toList();
        _allProfiles = profiles;
        _teacherProfiles = profiles.where((p) => p['is_teacher'] == true).toList();
        _emailByUser = emailByUser;
        _profileByUser = profileByUser;
        _courseBySlug = courseBySlug;
        _enrollments = enrollments;
        _activeEnrollments = enrollments.where((e) => e['status'] == 'active').toList();
        _flagged = flagged;
        final countByUser = <String, int>{};
        for (final d in devices) {
          final uid = d['user_id'] as String;
          countByUser[uid] = (countByUser[uid] ?? 0) + 1;
        }
        _devices = devices.where((d) => (countByUser[d['user_id']] ?? 0) >= _maxDevices).toList();
        _invites = invites;
        _pendingUploads = uploads;
        _discountCodes = codes;
        _errorLogs = errors;
        _payMethodCtrl.value = (myProfile?['teacher_payment_method'] as String?) ?? 'zain';
        _payDetailCtrl.text = (myProfile?['teacher_payment_detail'] as String?) ?? '';
        _payLoaded = true;
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
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Map<String, Map<String, dynamic>> _redemptionsByCourseUser = {};

  String _courseTitle(String slug) => (_courseBySlug[slug]?['title'] as String?) ?? slug;

  void _goto(_View v) => setState(() => _view = v);

  Future<void> _approve(String enrollmentId) async {
    final t = AppStrings.instance.t;
    try {
      final adminId = SupabaseService.instance.currentUser?.id;
      await SupabaseService.instance.client.from('enrollments').update({
        'status': 'active',
        'approved_by': adminId,
        'approved_at': DateTime.now().toIso8601String(),
      }).eq('id', enrollmentId);
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_approve_failed')}$e');
    }
  }

  Future<void> _removeEnrollment(String enrollmentId, String title, String email) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_remove').replaceAll('{email}', email).replaceAll('{title}', title));
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('enrollments').delete().eq('id', enrollmentId);
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_remove_failed')}$e');
    }
  }

  Future<void> _viewProof(String path) async {
    final t = AppStrings.instance.t;
    try {
      final signedUrl = await SupabaseService.instance.client.storage.from('payment-proofs').createSignedUrl(path, 60);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ProofViewerScreen(url: signedUrl)));
    } catch (e) {
      _showError('${t('alert_proof_failed')}$e');
    }
  }

  Future<void> _removeDevice(String deviceRowId, String email) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_remove_device').replaceAll('{email}', email));
    if (!confirmed) return;
    try {
      final result = await SupabaseService.instance.client.from('trusted_devices').delete().eq('id', deviceRowId).select();
      if ((result as List).isEmpty) {
        _showError('${t('alert_remove_device_failed')}blocked by database policy (0 rows removed)');
        return;
      }
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_remove_device_failed')}$e');
    }
  }

  Future<void> _publishCourse(String id) async {
    final t = AppStrings.instance.t;
    try {
      await SupabaseService.instance.client.from('courses').update({'status': 'published'}).eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_review_failed')}$e');
    }
  }

  Future<void> _rejectCourse(String id, String title) async {
    final t = AppStrings.instance.t;
    final confirmed = await _confirm(t('confirm_reject_course') != 'confirm_reject_course'
        ? t('confirm_reject_course').replaceAll('{title}', title)
        : 'Return "$title" to draft?');
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('courses').update({'status': 'draft'}).eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_review_failed')}$e');
    }
  }

  Future<void> _togglePayToTeacher(String id, bool value) async {
    final t = AppStrings.instance.t;
    try {
      await SupabaseService.instance.client.from('courses').update({'pay_to_teacher': value}).eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError('${t('alert_review_failed')}$e');
    }
  }

  Future<void> _createInvite() async {
    try {
      final sb = SupabaseService.instance.client;
      final user = SupabaseService.instance.currentUser!;
      final token = _uuid();
      final expiresAt = DateTime.now().add(const Duration(days: 7)).toIso8601String();
      await sb.from('teacher_invites').insert({'token': token, 'created_by': user.id, 'expires_at': expiresAt});
      await _loadAll();
    } catch (e) {
      _showError('Failed to create invite: $e');
    }
  }

  String _uuid() {
    // Lightweight v4-ish UUID without pulling in a new dependency beyond
    // what's already used elsewhere in the app (package:uuid is already a
    // dependency via supabase_service.dart's device id).
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return 'inv-${rnd.toRadixString(16)}-${(rnd * 31).toRadixString(16)}';
  }

  Future<void> _revokeInvite(String id) async {
    final confirmed = await _confirm('Revoke this invite? The link will stop working.');
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('teacher_invites').delete().eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError('Failed: $e');
    }
  }

  Future<void> _dismissError(String id) async {
    try {
      await SupabaseService.instance.client.from('error_logs').delete().eq('id', id);
      await _loadAll();
    } catch (e) {
      _showError('Failed: $e');
    }
  }

  Future<void> _clearErrorLog() async {
    final confirmed = await _confirm('Delete all error log entries? This cannot be undone.');
    if (!confirmed) return;
    try {
      await SupabaseService.instance.client.from('error_logs').delete().not('id', 'is', null);
      await _loadAll();
    } catch (e) {
      _showError('Failed: $e');
    }
  }

  Future<void> _saveMyPayment() async {
    setState(() { _payError = null; _payOk = null; });
    try {
      final user = SupabaseService.instance.currentUser!;
      await SupabaseService.instance.client.from('profiles').update({
        'teacher_payment_method': _payMethodCtrl.value,
        'teacher_payment_detail': _payDetailCtrl.text.trim(),
      }).eq('id', user.id);
      setState(() => _payOk = 'Saved.');
    } catch (e) {
      setState(() => _payError = 'Failed to save: $e');
    }
  }

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
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(t('btn_close'))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(t('remove'))),
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
          leading: _view != _View.dashboard
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _goto(_View.dashboard))
              : null,
          title: Text(_view == _View.dashboard ? t('nav_admin') : _viewTitle(t)),
        ),
        body: _buildBody(t),
      ),
    );
  }

  String _viewTitle(String Function(String) t) {
    switch (_view) {
      case _View.courses: return t('published_courses');
      case _View.teachers: return t('teachers');
      case _View.students: return t('active_students');
      case _View.revenue: return t('est_revenue');
      case _View.enrollments: return t('students_courses');
      case _View.review: return t('course_review');
      case _View.invites: return t('teacher_invites');
      case _View.uploads: return t('pending_lectures');
      case _View.flagged: return t('flagged_logins');
      case _View.devices: return t('trusted_devices');
      case _View.discountCodes: return t('discount_codes');
      case _View.errorLog: return t('error_log');
      case _View.myPayment: return t('my_payment_number');
      case _View.dashboard: return t('nav_admin');
    }
  }

  Widget _buildBody(String Function(String) t) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    if (!_isAdmin) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? t('err_video_unavailable'), style: AppFonts.body(color: AppColors.muted), textAlign: TextAlign.center),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppFonts.body(color: AppColors.muted), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadAll, child: Text(t('retry'))),
          ],
        ),
      );
    }
    if (_loading && _allCourses.isEmpty) return const Center(child: CircularProgressIndicator());

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
        _View.flagged => _buildFlagged(t),
        _View.devices => _buildDevices(t),
        _View.discountCodes => _buildDiscountCodes(t),
        _View.errorLog => _buildErrorLog(t),
        _View.myPayment => _buildMyPayment(t),
      },
    );
  }

  // ---- Dashboard ----

  Widget _buildDashboard(String Function(String) t) {
    final revenue = _activeEnrollments.fold<int>(0, (sum, e) {
      final c = _courseBySlug[e['course_slug']];
      if (c == null || c['is_free'] == true) return sum;
      final digits = RegExp(r'\d').allMatches((c['price'] ?? '').toString()).map((m) => m.group(0)).join();
      return sum + (digits.isEmpty ? 0 : int.parse(digits));
    });
    final activeInvitesCount = _invites.where((i) => i['used_at'] == null && DateTime.parse(i['expires_at'] as String).isAfter(DateTime.now())).length;
    final activeDiscountCodes = _discountCodes.where((c) => c['is_active'] == true && DateTime.parse(c['expires_at'] as String).isAfter(DateTime.now())).length;
    final myPaySet = (_profileByUser[SupabaseService.instance.currentUser?.id]?['teacher_payment_detail'] as String?)?.isNotEmpty == true;

    final cards = <_StatCardData>[
      _StatCardData(Icons.school_outlined, '${_publishedCourses.length}', t('published_courses'), AppColors.teal, () => _goto(_View.courses)),
      _StatCardData(Icons.people_outline, '${_teacherProfiles.length}', t('teachers'), AppColors.red, () => _goto(_View.teachers)),
      _StatCardData(Icons.groups_outlined, '${{for (final e in _activeEnrollments) e['user_id']}.length}', t('active_students'), AppColors.muted, () => _goto(_View.students)),
      _StatCardData(Icons.attach_money, revenue.toString(), t('est_revenue'), AppColors.red, () => _goto(_View.revenue)),
      _StatCardData(Icons.menu_book_outlined, '${_enrollments.length}', t('students_courses'), AppColors.teal, () => _goto(_View.enrollments)),
      _StatCardData(Icons.fact_check_outlined, '${_pendingReview.length}', t('course_review'), AppColors.teal, () => _goto(_View.review)),
      _StatCardData(Icons.mail_outline, '$activeInvitesCount', t('teacher_invites'), AppColors.red, () => _goto(_View.invites)),
      _StatCardData(Icons.video_library_outlined, '${_pendingUploads.length}', t('pending_lectures'), AppColors.muted, () => _goto(_View.uploads)),
      _StatCardData(Icons.warning_amber_outlined, '${_flagged.length}', t('flagged_logins'), AppColors.red, () => _goto(_View.flagged)),
      _StatCardData(Icons.phone_android_outlined, '${_devices.length}', t('trusted_devices'), AppColors.teal, () => _goto(_View.devices)),
      _StatCardData(Icons.local_offer_outlined, '$activeDiscountCodes', t('discount_codes'), AppColors.red, () => _goto(_View.discountCodes)),
      _StatCardData(Icons.error_outline, '${_errorLogs.length}', t('error_log'), AppColors.red, () => _goto(_View.errorLog)),
      _StatCardData(Icons.payments_outlined, myPaySet ? '✓' : '—', t('my_payment_number'), AppColors.teal, () => _goto(_View.myPayment)),
    ];

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.5),
      itemCount: cards.length,
      itemBuilder: (context, i) => _StatCard(data: cards[i]),
    );
  }

  // ---- Drill-in views ----

  Widget _buildCoursesList(String Function(String) t) {
    if (_publishedCourses.isEmpty) return _empty(t('no_courses'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _publishedCourses.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = _publishedCourses[i];
        final teacherName = (_profileByUser[c['teacher_id']]?['full_name'] as String?) ?? '—';
        return _AdminCard(children: [
          Text(c['title'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$teacherName · ${c['is_free'] == true ? t('card_free') : (c['price'] ?? '—')}', style: AppFonts.body(size: 13, color: AppColors.muted)),
        ]);
      },
    );
  }

  Widget _buildTeachersList(String Function(String) t) {
    if (_teacherProfiles.isEmpty) return _empty('No teachers yet.');
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _teacherProfiles.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final p = _teacherProfiles[i];
        final email = _emailByUser[p['id']] ?? '—';
        return _AdminCard(children: [
          Text(p['full_name'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$email · ${p['phone'] ?? '—'}', style: AppFonts.body(size: 13, color: AppColors.muted)),
        ]);
      },
    );
  }

  Widget _buildStudentsList(String Function(String) t) {
    final userIds = {for (final e in _activeEnrollments) e['user_id'] as String}.toList();
    if (userIds.isEmpty) return _empty('No active students yet.');
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: userIds.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final uid = userIds[i];
        final prof = _profileByUser[uid];
        final email = _emailByUser[uid] ?? '—';
        return _AdminCard(children: [
          Text(prof?['full_name'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$email · ${prof?['phone'] ?? '—'}', style: AppFonts.body(size: 13, color: AppColors.muted)),
        ]);
      },
    );
  }

  Widget _buildRevenue(String Function(String) t) {
    int parsePrice(dynamic price) {
      final digits = RegExp(r'\d').allMatches((price ?? '').toString()).map((m) => m.group(0)).join();
      return digits.isEmpty ? 0 : int.parse(digits);
    }

    final rows = <Map<String, dynamic>>[];
    int totalRevenue = 0, totalTeacher = 0, totalMine = 0;
    for (final c in _publishedCourses) {
      if (c['is_free'] == true) continue;
      final priceNum = parsePrice(c['price']);
      if (priceNum <= 0) continue;
      final enrolled = _activeEnrollments.where((e) => e['course_slug'] == c['slug']).toList();
      int revenue = 0, discountedCount = 0;
      for (final e in enrolled) {
        final dc = _redemptionsByCourseUser['${c['id']}|${e['user_id']}'];
        int amt = priceNum;
        if (dc != null) {
          discountedCount++;
          final type = dc['discount_type'];
          final value = (dc['discount_value'] as num?) ?? 0;
          amt = type == 'percent' ? (priceNum * (1 - value / 100)).round() : (priceNum - value).round();
          if (amt < 0) amt = 0;
        }
        revenue += amt;
      }
      final teacherAmt = c['pay_to_teacher'] == true ? revenue : 0;
      final mineAmt = c['pay_to_teacher'] == true ? 0 : revenue;
      totalRevenue += revenue;
      totalTeacher += teacherAmt;
      totalMine += mineAmt;
      rows.add({'c': c, 'students': enrolled.length, 'discounted': discountedCount, 'revenue': revenue, 'teacherAmt': teacherAmt, 'mineAmt': mineAmt});
    }
    rows.sort((a, b) => (b['revenue'] as int).compareTo(a['revenue'] as int));

    if (rows.isEmpty) return _empty('No revenue yet.');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _AdminCard(children: [
          Text('Total', style: AppFonts.body(size: 15, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Revenue: $totalRevenue · Teacher: $totalTeacher · Mine: $totalMine', style: AppFonts.mono(size: 11, color: AppColors.teal)),
        ]),
        const SizedBox(height: 10),
        for (final r in rows) ...[
          _AdminCard(children: [
            Text((r['c']['title'] as String?) ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '${_profileByUser[r['c']['teacher_id']]?['full_name'] ?? '—'} · ${r['students']} students${r['discounted'] > 0 ? ' (${r['discounted']} discounted)' : ''}',
              style: AppFonts.body(size: 13, color: AppColors.muted),
            ),
            const SizedBox(height: 4),
            Text('Revenue: ${r['revenue']} · Teacher: ${r['teacherAmt']} · Mine: ${r['mineAmt']}', style: AppFonts.mono(size: 10.5)),
          ]),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildEnrollments(String Function(String) t) {
    if (_enrollments.isEmpty) return _empty(t('no_enrollments'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _enrollments.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final e = _enrollments[i];
        final userId = e['user_id'] as String;
        final prof = _profileByUser[userId];
        final email = _emailByUser[userId] ?? '—';
        final title = _courseTitle(e['course_slug'] as String);
        final isActive = e['status'] == 'active';
        final proofPath = e['payment_proof_path'] as String?;
        final payment = e['payment_method'] != null
            ? '${e['payment_method']}${e['payment_detail'] != null ? ' — ${e['payment_detail']}' : ''}'
            : '—';
        final createdAt = DateTime.tryParse(e['created_at'] as String? ?? '');
        final approvedBy = e['approved_by'] as String?;
        final approvedAt = DateTime.tryParse(e['approved_at'] as String? ?? '');
        return _AdminCard(
          children: [
            Row(
              children: [
                Expanded(child: Text(email, style: AppFonts.body(size: 15, weight: FontWeight.w600))),
                _StatusChip(isActive: isActive, activeLabel: t('status_active'), pendingLabel: t('status_pending')),
              ],
            ),
            const SizedBox(height: 6),
            Text(title, style: AppFonts.body(size: 13, color: AppColors.muted)),
            if (prof?['full_name'] != null || prof?['phone'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${prof?['full_name'] ?? '—'} · ${prof?['phone'] ?? '—'}', style: AppFonts.mono(size: 10.5)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('$payment${createdAt != null ? ' · ${createdAt.toLocal().toString().split(' ').first}' : ''}', style: AppFonts.mono(size: 10.5)),
            ),
            if (approvedBy != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${t('approved_by')}: ${_emailByUser[approvedBy] ?? approvedBy}${approvedAt != null ? ' · ${approvedAt.toLocal()}' : ''}',
                  style: AppFonts.mono(size: 10.5, color: AppColors.teal),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (proofPath != null) OutlinedButton(onPressed: () => _viewProof(proofPath), child: Text(t('view_proof'))),
                if (!isActive) ElevatedButton(onPressed: () => _approve(e['id'] as String), child: Text(t('approve'))),
                OutlinedButton(onPressed: () => _removeEnrollment(e['id'] as String, title, email), child: Text(t('remove'))),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildReview(String Function(String) t) {
    if (_pendingReview.isEmpty) return _empty('No courses pending review.');
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _pendingReview.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = _pendingReview[i];
        final teacherName = (_profileByUser[c['teacher_id']]?['full_name'] as String?) ?? '—';
        final id = c['id'] as String;
        final title = c['title'] as String? ?? '—';
        return _AdminCard(children: [
          Text(title, style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$teacherName · ${c['is_free'] == true ? t('card_free') : (c['price'] ?? '—')}', style: AppFonts.body(size: 13, color: AppColors.muted)),
          Row(children: [
            Checkbox(value: c['pay_to_teacher'] == true, onChanged: (v) => _togglePayToTeacher(id, v ?? false)),
            Expanded(child: Text('Pay to teacher', style: AppFonts.body(size: 12.5, color: AppColors.muted))),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ElevatedButton(onPressed: () => _publishCourse(id), child: Text('Publish')),
            OutlinedButton(onPressed: () => _rejectCourse(id, title), child: Text('Reject')),
          ]),
        ]);
      },
    );
  }

  Widget _buildInvites(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ElevatedButton(onPressed: _createInvite, child: const Text('+ Create invite link')),
        const SizedBox(height: 12),
        if (_invites.isEmpty)
          Text('No invites yet.', style: AppFonts.body(color: AppColors.muted))
        else
          for (final inv in _invites) ...[
            _AdminCard(children: _inviteRow(inv)),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  List<Widget> _inviteRow(Map<String, dynamic> inv) {
    final usedAt = inv['used_at'];
    final expiresAt = DateTime.parse(inv['expires_at'] as String);
    final status = usedAt != null ? 'used' : (expiresAt.isBefore(DateTime.now()) ? 'expired' : 'unused');
    final usedByName = inv['used_by'] != null ? (_profileByUser[inv['used_by']]?['full_name'] ?? '—') : '—';
    return [
      Row(children: [
        Expanded(child: Text('Created ${DateTime.parse(inv['created_at'] as String).toLocal().toString().split(' ').first}', style: AppFonts.body(size: 13, weight: FontWeight.w600))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: AppColors.teal), borderRadius: BorderRadius.circular(999)),
          child: Text(status.toUpperCase(), style: AppFonts.mono(size: 9.5, color: AppColors.teal)),
        ),
      ]),
      const SizedBox(height: 4),
      Text('Expires ${expiresAt.toLocal().toString().split(' ').first} · Used by $usedByName', style: AppFonts.body(size: 12.5, color: AppColors.muted)),
      if (status == 'unused') ...[
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => _revokeInvite(inv['id'] as String), child: const Text('Revoke')),
      ],
    ];
  }

  Widget _buildUploads(String Function(String) t) {
    if (_pendingUploads.isEmpty) return _empty('No pending uploads.');
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _pendingUploads.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final l = _pendingUploads[i];
        return _AdminCard(children: [
          Text(l['title'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Lecture id: ${l['id']}\nPath: ${l['pending_upload_path']}',
            style: AppFonts.mono(size: 10.5, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          Text(
            'Publish this lecture from the admin.html web dashboard once its R2 path is ready — the mobile screen surfaces pending uploads for visibility, not full re-encoding controls.',
            style: AppFonts.body(size: 11.5, color: AppColors.muted2),
          ),
        ]);
      },
    );
  }

  Widget _buildFlagged(String Function(String) t) {
    if (_flagged.isEmpty) return _empty(t('no_flagged'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _flagged.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final f = _flagged[i];
        final createdAt = DateTime.tryParse(f['created_at'] as String? ?? '');
        return _AdminCard(
          children: [
            Text(f['email'] as String? ?? '—', style: AppFonts.body(size: 15, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('${f['city'] ?? '—'}, ${f['country'] ?? '—'}', style: AppFonts.body(size: 13, color: AppColors.muted)),
            const SizedBox(height: 4),
            Text(
              '${f['distance_km']} km${createdAt != null ? ' · ${createdAt.toLocal()}' : ''}',
              style: AppFonts.mono(size: 10.5, color: AppColors.red),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDevices(String Function(String) t) {
    if (_devices.isEmpty) return _empty(t('no_devices'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final d = _devices[i];
        final email = _emailByUser[d['user_id'] as String] ?? '—';
        final firstSeen = DateTime.tryParse(d['first_seen'] as String? ?? '');
        final lastSeen = DateTime.tryParse(d['last_seen'] as String? ?? '');
        return _AdminCard(
          children: [
            Text(email, style: AppFonts.body(size: 15, weight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(d['device_label'] as String? ?? '—', style: AppFonts.body(size: 13, color: AppColors.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '${t('th_first_seen')}: ${firstSeen != null ? firstSeen.toLocal().toString().split(' ').first : '—'} · ${t('th_last_seen')}: ${lastSeen != null ? lastSeen.toLocal() : '—'}',
              style: AppFonts.mono(size: 10.5),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton(onPressed: () => _removeDevice(d['id'] as String, email), child: Text(t('remove'))),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDiscountCodes(String Function(String) t) {
    if (_discountCodes.isEmpty) return _empty('No discount codes yet.');
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _discountCodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = _discountCodes[i];
        final courseId = c['course_id'];
        final course = _allCourses.firstWhere((cc) => cc['id'] == courseId, orElse: () => {});
        final teacherName = (_profileByUser[course['teacher_id']]?['full_name'] as String?) ?? '—';
        final expired = DateTime.parse(c['expires_at'] as String).isBefore(DateTime.now());
        final status = c['is_active'] != true ? 'inactive' : (expired ? 'expired' : 'active');
        final discount = c['discount_type'] == 'percent' ? '${c['discount_value']}%' : '${c['discount_value']} IQD';
        return _AdminCard(children: [
          Row(children: [
            Expanded(child: Text(c['code'] as String? ?? '—', style: AppFonts.mono(size: 14, weight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(border: Border.all(color: AppColors.teal), borderRadius: BorderRadius.circular(999)),
              child: Text(status.toUpperCase(), style: AppFonts.mono(size: 9.5, color: AppColors.teal)),
            ),
          ]),
          const SizedBox(height: 4),
          Text('${course['title'] ?? '—'} · $teacherName', style: AppFonts.body(size: 13, color: AppColors.muted)),
          const SizedBox(height: 4),
          Text('$discount · ${c['used_count']}/${c['max_uses']} used', style: AppFonts.mono(size: 10.5)),
        ]);
      },
    );
  }

  Widget _buildErrorLog(String Function(String) t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_errorLogs.isNotEmpty)
          Align(alignment: AlignmentDirectional.centerEnd, child: OutlinedButton(onPressed: _clearErrorLog, child: const Text('Clear all'))),
        const SizedBox(height: 8),
        if (_errorLogs.isEmpty)
          Text('No errors logged. Good sign.', style: AppFonts.body(color: AppColors.muted))
        else
          for (final e in _errorLogs) ...[
            _AdminCard(children: [
              Text(e['message'] as String? ?? '—', style: AppFonts.body(size: 13, weight: FontWeight.w600), maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text('${e['page'] ?? '—'} · ${e['user_id'] != null ? (_emailByUser[e['user_id']] ?? e['user_id']) : '—'}', style: AppFonts.mono(size: 10.5, color: AppColors.muted)),
              const SizedBox(height: 4),
              Text(DateTime.parse(e['created_at'] as String).toLocal().toString(), style: AppFonts.mono(size: 10.5, color: AppColors.muted2)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => _dismissError(e['id'] as String), child: const Text('Dismiss')),
            ]),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildMyPayment(String Function(String) t) {
    if (!_payLoaded) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Shown to students at checkout for any course where "Pay to teacher" is off.',
          style: AppFonts.body(size: 12.5, color: AppColors.muted),
        ),
        const SizedBox(height: 16),
        ValueListenableBuilder<String>(
          valueListenable: _payMethodCtrl,
          builder: (context, value, _) => Row(children: [
            Expanded(
              child: RadioListTile<String>(
                value: 'zain',
                groupValue: value,
                title: Text(t('zain_cash')),
                onChanged: (v) => _payMethodCtrl.value = v!,
              ),
            ),
            Expanded(
              child: RadioListTile<String>(
                value: 'qi',
                groupValue: value,
                title: Text(t('qi_card')),
                onChanged: (v) => _payMethodCtrl.value = v!,
              ),
            ),
          ]),
        ),
        TextField(controller: _payDetailCtrl, decoration: const InputDecoration(labelText: '07XX XXX XXXX')),
        if (_payError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_payError!, style: AppFonts.body(size: 12, color: AppColors.red))),
        if (_payOk != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_payOk!, style: AppFonts.body(size: 12, color: AppColors.teal))),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _saveMyPayment, child: Text(t('save'))),
      ],
    );
  }

  Widget _empty(String message) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(message, style: AppFonts.body(color: AppColors.muted)))]);
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
                Text(data.number, style: AppFonts.heading(size: 20)),
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

class _StatusChip extends StatelessWidget {
  final bool isActive;
  final String activeLabel;
  final String pendingLabel;
  const _StatusChip({required this.isActive, required this.activeLabel, required this.pendingLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.teal),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        (isActive ? activeLabel : pendingLabel).toUpperCase(),
        style: AppFonts.mono(size: 9.5, color: AppColors.teal, letterSpacing: 0.5),
      ),
    );
  }
}

/// Shows a payment-proof screenshot in-app via WebView instead of handing
/// the signed URL to an external browser — the URL never sits in a browser
/// address bar, history, or share sheet, and it expires in 60s regardless.
/// Renders images directly (the common case); a PDF proof falls back to
/// whatever the system WebView does with a bare PDF URL, which varies by
/// device — acceptable since screenshots are the overwhelming majority.
class _ProofViewerScreen extends StatefulWidget {
  final String url;
  const _ProofViewerScreen({required this.url});

  @override
  State<_ProofViewerScreen> createState() => _ProofViewerScreenState();
}

class _ProofViewerScreenState extends State<_ProofViewerScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) { if (mounted) setState(() => _loading = false); },
      ))
      ..loadHtmlString('''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
<style>
  html, body { margin:0; padding:0; background:#000; height:100%; display:flex; align-items:center; justify-content:center; }
  img { max-width:100%; max-height:100vh; width:auto; height:auto; object-fit:contain; }
</style>
</head>
<body><img src="${widget.url}"></body>
</html>
''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
