import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/api_service.dart';
import '../services/signup_rules.dart';
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

  // Last code sent, kept across screen instances so leaving and coming back
  // doesn't send (and pay for) another SMS inside the cooldown.
  static String? _lastSentPhone;
  static DateTime? _lastSentAt;

  String? _phone;
  // One hidden field drawn as 6 boxes: paste and SMS autofill fill all of
  // them, and backspace works on every keyboard.
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();

  bool _sending = true;
  bool _inFlight = false;
  bool _savingPhone = false;
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
    _codeFocus.addListener(() {
      if (mounted) setState(() {});
    });
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
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  String? get _accessToken =>
      SupabaseService.instance.client.auth.currentSession?.accessToken;

  String get _code => _codeCtrl.text;

  void _startCooldown([int seconds = 60]) {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cooldownSeconds--);
      if (_cooldownSeconds <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    final token = _accessToken;
    if (_inFlight || _cooldownSeconds > 0) return;
    if (token == null) {
      setState(() {
        _sending = false;
        _error = _t('session_expired');
      });
      return;
    }
    // A code already went to this number moments ago: reuse it.
    final last = _lastSentAt;
    if (last != null && _lastSentPhone == _phone) {
      final left = 60 - DateTime.now().difference(last).inSeconds;
      if (left > 0) {
        setState(() {
          _sending = false;
          _info = _t('otp_sent');
        });
        _startCooldown(left);
        _codeFocus.requestFocus();
        return;
      }
    }
    _inFlight = true;
    setState(() {
      _sending = true;
      _error = null;
      _info = null;
    });
    final result = await ApiService.sendPhoneOtp(token, phone: _phone);
    _inFlight = false;
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (result.ok) {
        _info = _t('otp_sent');
        _lastSentPhone = _phone;
        _lastSentAt = DateTime.now();
        _startCooldown();
      } else {
        _error = _t(result.error!);
      }
    });
    if (result.ok) {
      _codeCtrl.clear();
      _codeFocus.requestFocus();
    }
  }

  void _startEditPhone() {
    _phoneEditCtrl.text = _phone ?? '';
    setState(() => _editingPhone = true);
  }

  Future<void> _saveNewPhone() async {
    if (_savingPhone || _phoneEditCtrl.text.trim().isEmpty) return;
    final newPhone = SignupRules.normalizeIraqiPhone(_phoneEditCtrl.text);
    if (newPhone == null) {
      setState(() => _error = _t('err_phone_format'));
      return;
    }
    setState(() => _savingPhone = true);
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
    if (!mounted) return;
    _cooldownTimer?.cancel();
    setState(() {
      _phone = newPhone;
      _editingPhone = false;
      _cooldownSeconds = 0;
      _savingPhone = false;
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

  void _onCodeChanged(String value) {
    setState(() => _error = null);
    if (value.length == _digitCount) _verifyCode();
  }

  Future<void> _goBack(BuildContext context) async {
    if (widget.fromSignup) {
      // The account already exists and is signed in; reopening the sign-up
      // form would only hit "phone already used". Sign out instead -- the
      // phone check comes back on the next sign-in.
      final nav = Navigator.of(context);
      try {
        await SupabaseService.instance.logout();
      } catch (_) {}
      nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthScreen()),
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
        extendBodyBehindAppBar: true,
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
                      onPressed: _savingPhone ? null : _saveNewPhone,
                      child: Text(_t('save')))),
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
            child: _codeBoxes(),
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

  /// Six boxes over one invisible field. Box width shrinks on narrow phones
  /// (6 x 46px didn't fit a 360dp screen inside the card).
  Widget _codeBoxes() {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 8.0;
      final w = ((constraints.maxWidth - gap * (_digitCount - 1)) / _digitCount)
          .clamp(34.0, 52.0);
      final code = _codeCtrl.text;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _codeFocus.requestFocus();
          SystemChannels.textInput.invokeMethod('TextInput.show');
        },
        child: Stack(alignment: Alignment.center, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _digitCount; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                _box(w, i < code.length ? code[i] : '',
                    active: _codeFocus.hasFocus &&
                        (i == code.length ||
                            (i == _digitCount - 1 &&
                                code.length == _digitCount))),
              ],
            ],
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _codeCtrl,
                focusNode: _codeFocus,
                autofocus: true,
                showCursor: false,
                enableInteractiveSelection: false,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(_digitCount),
                ],
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onChanged: _onCodeChanged,
              ),
            ),
          ),
        ]),
      );
    });
  }

  Widget _box(double width, String digit, {required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: width,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? AppColors.red : AppColors.muted2.withValues(alpha: 0.5),
          width: active ? 1.6 : 1,
        ),
      ),
      child: Text(digit, style: AppFonts.heading(size: 24)),
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
