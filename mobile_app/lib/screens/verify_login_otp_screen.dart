import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// Second factor for teacher/admin logins (see
/// SupabaseService.login/awaitEmailLoginLink): password already checked,
/// and a sign-in link was just emailed to the account. Supabase's own
/// "Magic link or OTP" template in this project only ever sends a link
/// (no typed code -- that needs custom SMTP, which isn't set up), so this
/// screen just waits for that link to be opened on this device rather than
/// collecting a code.
class VerifyLoginOtpScreen extends StatefulWidget {
  final String email;
  const VerifyLoginOtpScreen({super.key, required this.email});

  @override
  State<VerifyLoginOtpScreen> createState() => _VerifyLoginOtpScreenState();
}

class _VerifyLoginOtpScreenState extends State<VerifyLoginOtpScreen> {
  bool _waiting = true;
  String? _error;
  Timer? _cooldownTimer;
  int _cooldownSeconds = 60;

  @override
  void initState() {
    super.initState();
    _startCooldown();
    _awaitLink();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cooldownSeconds--);
      if (_cooldownSeconds <= 0) timer.cancel();
    });
  }

  Future<void> _awaitLink() async {
    final result = await SupabaseService.instance.awaitEmailLoginLink();
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _waiting = false;
        _error = _t(result.error ?? 'err_oauth_cancelled');
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0) return;
    setState(() => _error = null);
    final err = await SupabaseService.instance.resendLoginEmailOtp(widget.email);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    _startCooldown();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(_t('login_otp_title'))),
        body: AmbientBackground(
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: GlassCard(
                    padding: const EdgeInsets.all(24),
                    child: _buildBody(),
                  ),
                ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.teal.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.teal.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.mark_email_read_outlined,
                color: AppColors.teal, size: 26),
          ),
        ),
        const SizedBox(height: 16),
        Text(_t('login_otp_title'),
            textAlign: TextAlign.center, style: AppFonts.heading(size: 22)),
        const SizedBox(height: 8),
        Text('${_t('login_otp_sub')} ${widget.email}',
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        if (_waiting)
          const Center(
            child: SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: _cooldownSeconds > 0 ? null : _resend,
            child: Text(
              _cooldownSeconds > 0
                  ? '${_t('btn_resend_code_in')} $_cooldownSeconds${_t('seconds_suffix')}'
                  : _t('btn_resend_code'),
            ),
          ),
        ),
      ],
    );
  }
}
