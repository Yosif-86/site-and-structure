import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// Second factor for teacher/admin logins (see
/// SupabaseService.login/verifyLoginEmailOtp): password already checked,
/// a one-time code was just emailed to the account, and confirming it here
/// is what actually establishes the session. Closely mirrors
/// VerifyPhoneScreen's 6-box layout for a consistent feel, but for a login
/// step rather than an onboarding one -- no phone editing, and "back" simply
/// abandons the login attempt.
class VerifyLoginOtpScreen extends StatefulWidget {
  final String email;
  const VerifyLoginOtpScreen({super.key, required this.email});

  @override
  State<VerifyLoginOtpScreen> createState() => _VerifyLoginOtpScreenState();
}

class _VerifyLoginOtpScreenState extends State<VerifyLoginOtpScreen> {
  static const _digitCount = 6;

  final _digitCtrls =
      List.generate(_digitCount, (_) => TextEditingController());
  final _digitFocus = List.generate(_digitCount, (_) => FocusNode());

  bool _verifying = false;
  String? _error;
  String? _info;
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
    for (final c in _digitCtrls) {
      c.dispose();
    }
    for (final f in _digitFocus) {
      f.dispose();
    }
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);
  String get _code => _digitCtrls.map((c) => c.text).join();

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cooldownSeconds--);
      if (_cooldownSeconds <= 0) timer.cancel();
    });
  }

  Future<void> _resend() async {
    if (_cooldownSeconds > 0) return;
    setState(() {
      _error = null;
      _info = null;
    });
    final err = await SupabaseService.instance.resendLoginEmailOtp(widget.email);
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    for (final c in _digitCtrls) {
      c.clear();
    }
    _digitFocus.first.requestFocus();
    setState(() => _info = _t('otp_sent'));
    _startCooldown();
  }

  Future<void> _verify() async {
    final code = _code;
    if (_verifying) return;
    if (code.length < _digitCount) {
      setState(() => _error = _t('err_invalid_code'));
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    final result =
        await SupabaseService.instance.verifyLoginEmailOtp(widget.email, code);
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _verifying = false;
        _error = _t(result.error ?? 'err_otp_incorrect');
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  void _onDigitChanged(int i, String value) {
    if (_error != null) setState(() => _error = null);
    if (value.isNotEmpty && i < _digitCount - 1) {
      _digitFocus[i + 1].requestFocus();
    }
    if (_code.length == _digitCount) _verify();
  }

  void _onDigitBackspace(int i) {
    if (_digitCtrls[i].text.isEmpty && i > 0) {
      _digitFocus[i - 1].requestFocus();
      _digitCtrls[i - 1].clear();
    }
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
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (var i = 0; i < _digitCount; i++) _digitBox(i)],
          ),
        ),
        const SizedBox(height: 10),
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
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        if (_info != null) ...[
          const SizedBox(height: 6),
          Text(_info!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.teal)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_t('btn_verify_code')),
        ),
      ],
    );
  }

  Widget _digitBox(int i) {
    return SizedBox(
      width: 46,
      height: 56,
      child: KeyboardListener(
        focusNode: FocusNode(skipTraversal: true),
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace) {
            _onDigitBackspace(i);
          }
        },
        child: TextField(
          controller: _digitCtrls[i],
          focusNode: _digitFocus[i],
          textAlign: TextAlign.center,
          maxLength: 1,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: AppFonts.heading(size: 22),
          decoration: const InputDecoration(counterText: ''),
          onChanged: (v) => _onDigitChanged(i, v),
        ),
      ),
    );
  }
}
