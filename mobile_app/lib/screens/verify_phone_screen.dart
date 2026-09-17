import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/api_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/brand_title.dart';

/// Required after signup (and re-shown on every launch until it succeeds):
/// sends a 6-digit code to the account's phone via OTPIQ (api/send-phone-otp)
/// and confirms it via api/verify-phone-otp, which is also the only thing
/// allowed to flip profiles.phone_verified (service-role only, never a
/// client-writable column).
class VerifyPhoneScreen extends StatefulWidget {
  const VerifyPhoneScreen({super.key});

  @override
  State<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends State<VerifyPhoneScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  bool _codeSent = false;
  bool _sending = false;
  bool _verifying = false;
  String? _error;
  String? _info;

  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;

  @override
  void initState() {
    super.initState();
    _phoneCtrl.text = SupabaseService
            .instance.currentUser?.userMetadata?['phone'] as String? ??
        '';
    _loadPhoneFromProfile();
  }

  Future<void> _loadPhoneFromProfile() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    try {
      final row = await SupabaseService.instance.client
          .from('profiles')
          .select('phone')
          .eq('id', user.id)
          .maybeSingle();
      final phone = row?['phone'] as String?;
      if (mounted &&
          phone != null &&
          phone.isNotEmpty &&
          _phoneCtrl.text.isEmpty) {
        setState(() => _phoneCtrl.text = phone);
      }
    } catch (_) {
      // Metadata fallback above already covers the common case.
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  String? get _accessToken =>
      SupabaseService.instance.client.auth.currentSession?.accessToken;

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cooldownSeconds--);
      if (_cooldownSeconds <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    final token = _accessToken;
    if (token == null || _sending || _cooldownSeconds > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    final result =
        await ApiService.sendPhoneOtp(token, phone: _phoneCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (result.ok) {
        _codeSent = true;
        _info = _t('otp_sent');
        _startCooldown();
      } else {
        _error = _t(result.error!);
      }
    });
  }

  Future<void> _verifyCode() async {
    final token = _accessToken;
    final code = _codeCtrl.text.trim();
    if (token == null || _verifying) return;
    if (code.length < 4) {
      setState(() => _error = _t('err_invalid_code'));
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    final result = await ApiService.verifyPhoneOtp(token, code);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _verifying = false;
        _error = _t(result.error!);
      });
      return;
    }
    setState(() {
      _verifying = false;
      _info = _t('otp_verified');
    });
    // Brief confirmation before leaving so "verified" doesn't just flash by.
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandTitle(),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.panel2,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: _buildBody(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('verify_phone_title'), style: AppFonts.heading(size: 24)),
        const SizedBox(height: 6),
        Text(_t('verify_phone_sub'),
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(
          controller: _phoneCtrl,
          enabled: !_codeSent,
          decoration: InputDecoration(
              labelText: _t('label_phone'), hintText: _t('ph_phone')),
          keyboardType: TextInputType.phone,
        ),
        if (_codeSent) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _codeCtrl,
            decoration: InputDecoration(
                labelText: _t('label_otp_code'), hintText: _t('ph_otp_code')),
            keyboardType: TextInputType.number,
            maxLength: 6,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        if (_info != null) ...[
          const SizedBox(height: 10),
          Text(_info!, style: AppFonts.body(size: 12.5, color: AppColors.teal)),
        ],
        const SizedBox(height: 18),
        if (!_codeSent)
          ElevatedButton(
            onPressed: _sending ? null : _sendCode,
            child: _sending ? const _Spinner() : Text(_t('btn_send_code')),
          )
        else ...[
          ElevatedButton(
            onPressed: _verifying ? null : _verifyCode,
            child: _verifying ? const _Spinner() : Text(_t('btn_verify_code')),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: _cooldownSeconds > 0 || _sending ? null : _sendCode,
              child: Text(
                _cooldownSeconds > 0
                    ? '${_t('btn_resend_code_in')} $_cooldownSeconds'
                    : _t('btn_resend_code'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}
