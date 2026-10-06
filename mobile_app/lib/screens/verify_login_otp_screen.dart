import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// Second factor for teacher/admin logins (see SupabaseService.login and
/// verifyLoginEmailCode): the password (or Google) is already checked and a
/// 6-digit code was just emailed to the account. Pops true once signed in.
class VerifyLoginOtpScreen extends StatefulWidget {
  final String email;
  const VerifyLoginOtpScreen({super.key, required this.email});

  @override
  State<VerifyLoginOtpScreen> createState() => _VerifyLoginOtpScreenState();
}

class _VerifyLoginOtpScreenState extends State<VerifyLoginOtpScreen> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  Timer? _cooldownTimer;
  int _cooldownSeconds = 60;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _codeCtrl.dispose();
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

  Future<void> _verify() async {
    if (_busy) return;
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = _t('err_otp_incorrect'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result =
        await SupabaseService.instance.verifyLoginEmailCode(widget.email, code);
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = _t(result.error ?? 'err_otp_incorrect');
    });
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0 || _busy) return;
    setState(() => _error = null);
    final err = await SupabaseService.instance.resendLoginEmailOtp(widget.email);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = _t(err));
      return;
    }
    _codeCtrl.clear();
    _startCooldown();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        extendBodyBehindAppBar: true,
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
        Text(_t('login_otp_sub'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 4),
        Text(widget.email,
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: AppFonts.body(size: 13, weight: FontWeight.w600)),
        const SizedBox(height: 20),
        Directionality(
          textDirection: TextDirection.ltr,
          child: TextField(
            controller: _codeCtrl,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppFonts.code(size: 26).copyWith(letterSpacing: 10),
            decoration: InputDecoration(
              counterText: '',
              hintText: _t('login_otp_hint'),
              hintStyle: AppFonts.body(size: 14, color: AppColors.muted2),
            ),
            onChanged: (v) {
              if (v.length == 6) _verify();
            },
            onSubmitted: (_) => _verify(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_t('btn_verify_code')),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: _cooldownSeconds > 0 || _busy ? null : _resend,
            child: Text(
              _cooldownSeconds > 0
                  ? '${_t('btn_resend_code_in')} $_cooldownSeconds${_t('seconds_suffix')}'
                  : _t('btn_resend_code'),
            ),
          ),
        ),
        Text(_t('login_otp_spam'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 11.5, color: AppColors.muted2)),
      ],
    );
  }
}
