import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../i18n/strings.dart';
import '../services/error_reporter.dart';
import '../services/payment_rules.dart';
import '../services/signup_rules.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/dashboard_kit.dart';
import '../widgets/glass_scaffold.dart';
import 'verify_phone_screen.dart';

/// Shown once after a Google sign-in (or to any account without a phone):
/// the name comes pre-filled from the Google account and stays editable,
/// and a phone number is required -- one account per number -- then
/// confirmed by the SMS/WhatsApp code on VerifyPhoneScreen. Can't be
/// skipped; signing out is the only other way off this screen.
class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _saving = false;
  String? _error;

  String _t(String k) => AppStrings.instance.t(k);

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    final meta = user.userMetadata ?? const {};
    var name = (meta['full_name'] ?? meta['name'] ?? '') as String;
    var phone = '';
    try {
      final row = await SupabaseService.instance.client
          .from('profiles')
          .select('full_name, phone')
          .eq('id', user.id)
          .maybeSingle();
      final dbName = (row?['full_name'] as String?)?.trim() ?? '';
      if (dbName.isNotEmpty) name = dbName;
      phone = (row?['phone'] as String?) ?? '';
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (_name.text.isEmpty) _name.text = name;
      if (_phone.text.isEmpty) _phone.text = phone;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _name.text.trim();
    final phone = SignupRules.normalizeIraqiPhone(_phone.text);
    if (name.isEmpty) {
      setState(() => _error = _t('err_name_required'));
      return;
    }
    if (phone == null) {
      setState(() => _error = _t('err_phone_format'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final sb = SupabaseService.instance.client;
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() {
        _saving = false;
        _error = _t('session_expired');
      });
      return;
    }
    try {
      final free = await sb.rpc('is_phone_available', params: {'p_phone': phone});
      if (free != true) {
        if (mounted) setState(() => _error = _t('err_phone_taken'));
        return;
      }
      // Upsert: an account whose profile row never got created (sign-up cut
      // off mid-way) gets it here instead of updating nothing.
      await sb
          .from('profiles')
          .upsert({'id': user.id, 'full_name': name, 'phone': phone});
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() => _error =
            _t(e.code == '23505' ? 'err_phone_taken' : 'err_generic_failed'));
      }
      return;
    } catch (e) {
      if (mounted) setState(() => _error = ErrorReporter.userMessage(e));
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const VerifyPhoneScreen()));
    if (verified == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: false,
        child: GlassScaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(_t('complete_profile_title')),
            actions: [
              TextButton(
                onPressed: () async {
                  await SupabaseService.instance.logout();
                  if (context.mounted) Navigator.of(context).pop(false);
                },
                child: Text(_t('log_out')),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              DashFormPanel(
                title: _t('complete_profile_title'),
                icon: ArcIcon.profile,
                children: [
                  Text(_t('complete_profile_sub'),
                      style: AppFonts.body(size: 13, color: AppColors.muted)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration:
                        InputDecoration(labelText: _t('label_fullname')),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phone,
                    textDirection: TextDirection.ltr,
                    keyboardType: TextInputType.phone,
                    inputFormatters: PaymentRules.numberInput,
                    decoration: InputDecoration(
                        labelText: _t('label_phone'), hintText: '07XX XXX XXXX'),
                  ),
                  const SizedBox(height: 6),
                  Text(_t('complete_profile_phone_hint'),
                      style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!,
                        style: AppFonts.body(size: 12.5, color: AppColors.error)),
                  ],
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: _saving ? null : _continue,
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_t('btn_send_code')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
