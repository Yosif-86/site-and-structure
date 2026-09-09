import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// Port of admin.html's three sections (enrollments, flagged logins, capped
/// devices) as a tabbed mobile screen. Access is gated the same way as the
/// website: profiles.is_admin, checked server-side by RLS on every query
/// below — this screen's is_admin guard is only there to bounce a non-admin
/// back out quickly, not to authorize anything.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> with SingleTickerProviderStateMixin {
  static const _maxDevices = 2; // must match api/check-device.js

  late final TabController _tabController;
  bool _checking = true;
  bool _isAdmin = false;

  List<Map<String, dynamic>> _enrollments = [];
  List<Map<String, dynamic>> _flagged = [];
  List<Map<String, dynamic>> _cappedDevices = [];
  Map<String, Map<String, dynamic>> _courseBySlug = {};
  Map<String, String> _emailByUser = {};
  Map<String, Map<String, dynamic>> _profileByUser = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabController.dispose();
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
    setState(() => _error = null);
    try {
      final sb = SupabaseService.instance.client;
      final courses = await sb.from('courses').select('slug, title, title_ar');
      final logins = await sb.from('login_events').select('user_id, email, created_at').order('created_at', ascending: false);
      final profiles = await sb.from('profiles').select('id, full_name, phone');
      final enrollments = await sb
          .from('enrollments')
          .select('id, user_id, course_slug, status, payment_method, payment_detail, payment_proof_path, created_at')
          .order('created_at', ascending: false);
      final flagged = await sb
          .from('login_events')
          .select('email, city, country, distance_km, created_at')
          .eq('flagged', true)
          .order('created_at', ascending: false)
          .limit(50);
      final devices = await sb
          .from('trusted_devices')
          .select('id, user_id, device_label, first_seen, last_seen')
          .order('user_id')
          .order('first_seen');

      final emailByUser = <String, String>{};
      for (final l in (logins as List)) {
        final uid = l['user_id'] as String?;
        if (uid != null && !emailByUser.containsKey(uid)) emailByUser[uid] = l['email'] as String? ?? '—';
      }
      final profileByUser = <String, Map<String, dynamic>>{};
      for (final p in (profiles as List)) {
        profileByUser[p['id'] as String] = p as Map<String, dynamic>;
      }
      final courseBySlug = <String, Map<String, dynamic>>{};
      for (final c in (courses as List)) {
        courseBySlug[c['slug'] as String] = c as Map<String, dynamic>;
      }
      final countByUser = <String, int>{};
      for (final d in (devices as List)) {
        final uid = d['user_id'] as String;
        countByUser[uid] = (countByUser[uid] ?? 0) + 1;
      }
      final cappedDevices = (devices).cast<Map<String, dynamic>>().where((d) => (countByUser[d['user_id']] ?? 0) >= _maxDevices).toList();

      if (!mounted) return;
      setState(() {
        _emailByUser = emailByUser;
        _profileByUser = profileByUser;
        _courseBySlug = courseBySlug;
        _enrollments = (enrollments as List).cast<Map<String, dynamic>>();
        _flagged = (flagged as List).cast<Map<String, dynamic>>();
        _cappedDevices = cappedDevices;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  String _courseTitle(String slug) {
    final c = _courseBySlug[slug];
    if (c == null) return slug;
    final ar = AppStrings.instance.isAr;
    final titleAr = c['title_ar'] as String?;
    return (ar && titleAr != null && titleAr.isNotEmpty) ? titleAr : (c['title'] as String? ?? slug);
  }

  Future<void> _approve(String enrollmentId) async {
    final t = AppStrings.instance.t;
    try {
      await SupabaseService.instance.client.from('enrollments').update({'status': 'active'}).eq('id', enrollmentId);
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
      final uri = Uri.parse(signedUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) _showError('${t('alert_proof_failed')}could not open browser');
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
          title: Text(t('nav_admin')),
          bottom: _isAdmin
              ? TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: t('students_courses')),
                    Tab(text: t('flagged_logins')),
                    Tab(text: t('trusted_devices')),
                  ],
                )
              : null,
        ),
        body: _buildBody(t),
      ),
    );
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
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: TabBarView(
        controller: _tabController,
        children: [
          _buildEnrollments(t),
          _buildFlagged(t),
          _buildDevices(t),
        ],
      ),
    );
  }

  Widget _buildEnrollments(String Function(String) t) {
    if (_enrollments.isEmpty) {
      return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(t('no_enrollments'), style: AppFonts.body(color: AppColors.muted)))]);
    }
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

  Widget _buildFlagged(String Function(String) t) {
    if (_flagged.isEmpty) {
      return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(t('no_flagged'), style: AppFonts.body(color: AppColors.muted)))]);
    }
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
    if (_cappedDevices.isEmpty) {
      return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text(t('no_devices'), style: AppFonts.body(color: AppColors.muted)))]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _cappedDevices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final d = _cappedDevices[i];
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
