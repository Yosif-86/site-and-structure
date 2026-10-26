import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/bidi.dart';
import '../services/error_reporter.dart';
import '../services/money.dart';
import '../services/payment_rules.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';

/// Admin view of one student: contact details (each with a copy button),
/// every course with what was paid and how, registered devices and recent
/// logins. Reads are covered by the admin RLS policies; the email comes from
/// the admin-only admin_user_emails() function, passed in by the caller.
class AdminStudentProfileScreen extends StatefulWidget {
  final String userId;
  final String? email;
  final String? fallbackName;

  /// Deletes this account and says whether it is gone (null = no button).
  final Future<bool> Function()? onDelete;
  const AdminStudentProfileScreen(
      {super.key,
      required this.userId,
      this.email,
      this.fallbackName,
      this.onDelete});

  @override
  State<AdminStudentProfileScreen> createState() =>
      _AdminStudentProfileScreenState();
}

/// "google,email" -> "Google، البريد الإلكتروني" (null when unknown).
String? signInLabel(String Function(String) t, String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return raw
      .split(',')
      .map((p) => switch (p) {
            'google' => t('sp_signin_google'),
            'apple' => t('sp_signin_apple'),
            'email' => t('sp_signin_email'),
            _ => p,
          })
      .join('، ');
}

class _AdminStudentProfileScreenState extends State<AdminStudentProfileScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _enrollments = [];
  Map<String, Map<String, dynamic>> _courseBySlug = {};
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _logins = [];
  String? _signIn;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sb = SupabaseService.instance.client;
      final id = widget.userId;
      final results = await Future.wait([
        sb
            .from('profiles')
            .select('id, full_name, phone, public_id, created_at, is_teacher')
            .eq('id', id)
            .maybeSingle(),
        sb
            .from('enrollments')
            .select('*')
            .eq('user_id', id)
            .order('created_at', ascending: false),
        sb
            .from('trusted_devices')
            .select('device_label, first_seen, last_seen')
            .eq('user_id', id)
            .order('last_seen', ascending: false),
        sb
            .from('login_events')
            .select('created_at, city, country, flagged')
            .eq('user_id', id)
            .order('created_at', ascending: false)
            .limit(8),
      ]);
      final enrollments = (results[1] as List).cast<Map<String, dynamic>>();
      final slugs = {for (final e in enrollments) e['course_slug'] as String}
          .toList();
      final courses = slugs.isEmpty
          ? <Map<String, dynamic>>[]
          : (await sb
                  .from('courses')
                  .select('slug, title, price, is_free')
                  .inFilter('slug', slugs) as List)
              .cast<Map<String, dynamic>>();
      String? signIn;
      try {
        signIn = await sb.rpc('admin_user_sign_in_method',
            params: {'p_user': id}) as String?;
      } catch (_) {
        // Function not added yet: the row is simply left out.
      }
      if (!mounted) return;
      setState(() {
        _signIn = signIn;
        _profile = results[0] as Map<String, dynamic>?;
        _enrollments = enrollments;
        _courseBySlug = {for (final c in courses) c['slug'] as String: c};
        _devices = (results[2] as List).cast<Map<String, dynamic>>();
        _logins = (results[3] as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorReporter.userMessage(e, page: 'admin');
        _loading = false;
      });
    }
  }

  String _date(String? iso, {bool time = false}) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '—';
    final s = d.toString();
    return time ? s.substring(0, 16) : s.split(' ').first;
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppStrings.instance.t('copied')),
        duration: const Duration(seconds: 2)));
  }

  /// What one enrollment paid. Stored amounts first; older rows without them
  /// count the course's full price.
  int _paid(Map<String, dynamic> e) {
    if (e['status'] != 'active') return 0;
    final stored = (e['amount_paid'] as num?)?.toInt();
    if (stored != null) return stored;
    final listed = (e['list_price'] as num?)?.toInt();
    if (listed != null) return listed;
    final c = _courseBySlug[e['course_slug']];
    if (c == null || c['is_free'] == true) return 0;
    return PaymentRules.parsePrice(c['price']);
  }

  String _method(String Function(String) t, Map<String, dynamic> e) =>
      switch (e['payment_method']) {
        'free_add' => t('sp_method_free'),
        'wayl' => t('sp_method_wayl'),
        'apple' => t('sp_method_apple'),
        'zain' => t('zain_cash'),
        'qi' => t('qi_card'),
        null => '—',
        final m => '$m',
      };

  Widget _field(String label, String? value) {
    final v = (value ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: AppFonts.body(size: 12, color: AppColors.muted)),
            const SizedBox(height: 2),
            SelectableText(v.isEmpty ? '—' : v,
                textDirection: TextDirection.ltr,
                style: AppFonts.body(size: 15, weight: FontWeight.w600)),
          ]),
        ),
        if (v.isNotEmpty)
          IconButton(
            tooltip: AppStrings.instance.t('btn_copy'),
            icon: ArcIconView(ArcIcon.copy, size: 18, color: AppColors.teal),
            onPressed: () => _copy(v),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: GlassScaffold(
        appBar: AppBar(title: Text(t('student_profile'))),
        body: _body(t),
      ),
    );
  }

  Widget _body(String Function(String) t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!,
              style: AppFonts.body(color: AppColors.muted),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: Text(t('retry'))),
        ]),
      );
    }
    final p = _profile;
    final name = (p?['full_name'] as String?) ?? widget.fallbackName;
    final idTag = p?['public_id']?.toString();
    final phone = p?['phone'] as String?;
    final email = widget.email;
    final total = _enrollments.fold<int>(0, (s, e) => s + _paid(e));
    final summary = [
      '${t('sp_name')}: ${name ?? '—'}',
      '${t('sp_email')}: ${email ?? '—'}',
      '${t('sp_phone')}: ${phone ?? '—'}',
      '${t('sp_id')}: ${idTag ?? '—'}',
    ].join('\n');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                DashAvatar(name: name, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name ?? '—',
                      style: AppFonts.body(size: 18, weight: FontWeight.w800)),
                ),
                IconButton(
                  tooltip: t('sp_copy_all'),
                  icon: ArcIconView(ArcIcon.copy, size: 20, color: AppColors.red),
                  onPressed: () => _copy(summary),
                ),
              ]),
              const SizedBox(height: 6),
              _field(t('sp_name'), name),
              _field(t('sp_email'), email),
              _field(t('sp_phone'), phone),
              _field(t('sp_id'), idTag),
              _field(t('sp_joined'), _date(p?['created_at'] as String?)),
              _field(t('sp_signin'), signInLabel(t, _signIn)),
            ]),
          ),
          DashSection(t('sp_courses')),
          if (_enrollments.isEmpty)
            DashEmpty(icon: ArcIcon.lessons, message: t('sp_no_courses'))
          else ...[
            DashCard(
              leading: DashIconBadge(icon: ArcIcon.money, accent: AppColors.teal),
              title: t('sp_total_paid'),
              subtitle: Money.iqd(total),
            ),
            for (final e in _enrollments) ...[
              const SizedBox(height: 10),
              _enrollmentCard(t, e),
            ],
          ],
          DashSection(t('sp_devices')),
          if (_devices.isEmpty)
            DashEmpty(icon: ArcIcon.phone, message: t('sp_no_devices'))
          else
            for (final d in _devices) ...[
              DashCard(
                leading: DashIconBadge(icon: ArcIcon.phone, accent: AppColors.byline),
                title: (d['device_label'] as String?) ?? '—',
                subtitle:
                    '${t('sp_last_seen')}: ${_date(d['last_seen'] as String?, time: true)}',
              ),
              const SizedBox(height: 10),
            ],
          DashSection(t('sp_logins')),
          if (_logins.isEmpty)
            DashEmpty(icon: ArcIcon.shield, message: t('sp_no_logins'))
          else
            for (final l in _logins) ...[
              DashCard(
                leading: DashIconBadge(
                    icon: ArcIcon.shield,
                    accent: l['flagged'] == true ? AppColors.error : AppColors.teal),
                title: _date(l['created_at'] as String?, time: true),
                subtitle: [l['city'], l['country']]
                    .whereType<String>()
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
              ),
              const SizedBox(height: 10),
            ],
          if (widget.onDelete != null) ...[
            const SizedBox(height: 14),
            DashButton(t('btn_delete_account'),
                danger: true,
                icon: ArcIcon.trash,
                onPressed: () async {
                  final deleted = await widget.onDelete!();
                  if (deleted && mounted) Navigator.of(context).pop();
                }),
          ],
        ],
      ),
    );
  }

  Widget _enrollmentCard(
      String Function(String) t, Map<String, dynamic> e) {
    final slug = e['course_slug'] as String;
    final c = _courseBySlug[slug];
    final active = e['status'] == 'active';
    final paid = _paid(e);
    final listed = (e['list_price'] as num?)?.toInt() ??
        (c == null ? 0 : PaymentRules.parsePrice(c['price']));
    final discount = (e['discount_amount'] as num?)?.toInt() ?? 0;
    return DashCard(
      leading: DashIconBadge(icon: ArcIcon.courses, accent: AppColors.teal),
      title: Bidi.iso((c?['title'] as String?) ?? slug),
      subtitle: _method(t, e),
      trailing: StatusPill(
          active ? t('sp_status_active') : t('sp_status_pending'),
          tone: active ? StatusTone.good : StatusTone.warn),
      meta: [
        '${t('pay_lbl_paid')}: ${Money.iqd(paid)}',
        if (listed > 0 && e['payment_method'] != 'free_add')
          '${t('pay_lbl_price')}: ${Money.iqd(listed)}',
        if (discount > 0 && e['payment_method'] != 'free_add')
          '${t('pay_lbl_discount')}: -${Money.iqd(discount)}',
        _date(e['created_at'] as String?, time: true),
      ],
    );
  }
}
