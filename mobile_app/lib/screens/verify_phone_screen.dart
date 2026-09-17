import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/api_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';
import 'auth_screen.dart';

/// Required after signup (and re-shown on every launch until it succeeds):
/// sends a 6-digit code to the account's phone via OTPIQ (api/send-phone-otp)
/// and confirms it via api/verify-phone-otp, which is also the only thing
/// allowed to flip profiles.phone_verified (service-role only, never a
/// client-writable column).
///
/// The phone number is fixed at signup and shown read-only here (with an
/// "edit" option for a typo) -- the code sends itself as soon as the screen
/// knows the number, straight into a 6-box code entry.
class VerifyPhoneScreen extends StatefulWidget {
  /// Whether this was reached straight out of the signup form -- if so, the
  /// back arrow returns to signup (not wherever else Navigator would pop
  /// to), since that's the only thing behind this screen conceptually.
  final bool fromSignup;

  const VerifyPhoneScreen({super.key, this.fromSignup = false});

  @override
  State<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends State<VerifyPhoneScreen> {
  static const _digitCount = 6;

  String? _phone;
  final _digitCtrls =
      List.generate(_digitCount, (_) => TextEditingController());
  final _digitFocus = List.generate(_digitCount, (_) => FocusNode());

  bool _sending = true;
  bool _verifying = false;
  bool _editingPhone = false;
  final _phoneEditCtrl = TextEditingController();
  String? _error;
  String? _info;

  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final user = SupabaseService.instance.currentUser;
    var phone = user?.userMetadata?['phone'] as String? ?? '';
    if (user != null) {
      try {
        final row = await SupabaseService.instance.client
            .from('profiles')
            .select('phone')
            .eq('id', user.id)
            .maybeSingle();
        final dbPhone = row?['phone'] as String?;
        if (dbPhone != null && dbPhone.isNotEmpty) phone = dbPhone;
      } catch (_) {
        // Metadata fallback above already covers the common case.
      }
    }
    if (!mounted) return;
    setState(() => _phone = phone);
    await _sendCode();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneEditCtrl.dispose();
    for (final c in _digitCtrls) {
      c.dispose();
    }
    for (final f in _digitFocus) {
      f.dispose();
    }
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  String? get _accessToken =>
      SupabaseService.instance.client.auth.currentSession?.accessToken;

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

  Future<void> _sendCode() async {
    final token = _accessToken;
    if (token == null || _cooldownSeconds > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    final result = await ApiService.sendPhoneOtp(token, phone: _phone);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (result.ok) {
        _info = _t('otp_sent');
        _startCooldown();
      } else {
        _error = _t(result.error!);
      }
    });
    if (result.ok) {
      for (final c in _digitCtrls) {
        c.clear();
      }
      _digitFocus.first.requestFocus();
    }
  }

  void _startEditPhone() {
    _phoneEditCtrl.text = _phone ?? '';
    setState(() => _editingPhone = true);
  }

  Future<void> _saveNewPhone() async {
    final newPhone = _phoneEditCtrl.text.trim();
    if (newPhone.isEmpty) return;
    final user = SupabaseService.instance.currentUser;
    if (user != null) {
      try {
        await SupabaseService.instance.client
            .from('profiles')
            .update({'phone': newPhone}).eq('id', user.id);
      } catch (_) {
        // Not fatal -- send-phone-otp is told the corrected number directly
        // below regardless of whether this write succeeds.
      }
    }
    _cooldownTimer?.cancel();
    setState(() {
      _phone = newPhone;
      _editingPhone = false;
      _cooldownSeconds = 0;
    });
    await _sendCode();
  }

  Future<void> _verifyCode() async {
    final token = _accessToken;
    final code = _code;
    if (token == null || _verifying) return;
    if (code.length < _digitCount) {
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

  void _onDigitChanged(int i, String value) {
    if (_error != null) setState(() => _error = null);
    if (value.isNotEmpty && i < _digitCount - 1) {
      _digitFocus[i + 1].requestFocus();
    }
    if (_code.length == _digitCount) _verifyCode();
  }

  void _onDigitBackspace(int i) {
    if (_digitCtrls[i].text.isEmpty && i > 0) {
      _digitFocus[i - 1].requestFocus();
      _digitCtrls[i - 1].clear();
    }
  }

  void _goBack(BuildContext context) {
    if (widget.fromSignup) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
            builder: (_) => const AuthScreen(startInSignup: true)),
      );
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPop = widget.fromSignup || Navigator.of(context).canPop();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: canPop
            ? AppBar(
                title: Text(_t('verify_phone_title')),
                leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => _goBack(context)),
              )
            : null,
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
            child: Icon(Icons.sms_outlined, color: AppColors.teal, size: 26),
          ),
        ),
        const SizedBox(height: 16),
        Text(_t('verify_phone_title'),
            textAlign: TextAlign.center, style: AppFonts.heading(size: 22)),
        const SizedBox(height: 8),
        Text(_t('verify_phone_sub'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 10),
        if (_editingPhone) ...[
          Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: _phoneEditCtrl,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(hintText: _t('ph_phone')),
              autofocus: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => setState(() => _editingPhone = false),
                      child: Text(_t('discard')))),
              const SizedBox(width: 10),
              Expanded(
                  child: ElevatedButton(
                      onPressed: _saveNewPhone, child: Text(_t('save')))),
            ],
          ),
        ] else
          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(_phone ?? '',
                    style: AppFonts.mono(size: 14, color: AppColors.text)),
                TextButton(
                    onPressed: _startEditPhone,
                    child: Text(_t('btn_edit_phone'))),
              ],
            ),
          ),
        const SizedBox(height: 20),
        if (_editingPhone)
          ...[]
        else if (_sending && _info == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: _Spinner(color: null)),
          )
        else ...[
          // Codes are always read/typed left-to-right, even in an RTL app --
          // pinning this row's direction keeps box 0 on the left and typing
          // flowing left-to-right instead of mirroring with the page.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < _digitCount; i++) _digitBox(i),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _cooldownSeconds > 0 || _sending ? null : _sendCode,
              child: Text(
                _cooldownSeconds > 0
                    ? '${_t('btn_resend_code_in')} $_cooldownSeconds${_t('seconds_suffix')}'
                    : _t('btn_resend_code'),
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        if (_info != null && !_sending) ...[
          const SizedBox(height: 6),
          Text(_info!,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: AppColors.teal)),
        ],
        if (!_editingPhone) ...[
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: _verifying || _sending ? null : _verifyCode,
            child: _verifying
                ? const _Spinner(color: Colors.white)
                : Text(_t('btn_verify_code')),
          ),
        ],
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

class _Spinner extends StatelessWidget {
  final Color? color;
  const _Spinner({required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(
          strokeWidth: 2, color: color ?? AppColors.red));
}
