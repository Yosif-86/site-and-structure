import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/blueprint_logo.dart';
import 'teacher_screen.dart';
import 'verify_login_otp_screen.dart';
import 'verify_phone_screen.dart';

enum _AuthMode { login, signup, forgot, forgotSent }

/// Port of renderAuth() in index.html — one screen, three modes.
class AuthScreen extends StatefulWidget {
  final bool startInSignup;

  const AuthScreen({super.key, this.startInSignup = false});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with TickerProviderStateMixin {
  /// The full Blueprint Pour plays the first time the sign-in screen opens
  /// in an app session; after that it opens already settled.
  static bool _introPlayed = false;

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: Duration(
        milliseconds: (BlueprintTimeline.end * 1000).round()),
  );
  late final AnimationController _idle = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 5500));
  final _logoSlotKey = GlobalKey();
  double _logoLift = 0; // px from the logo's slot up to screen centre
  bool _introStarted = false;
  final AudioPlayer _introSound = AudioPlayer();
  final AudioPlayer _tapSound = AudioPlayer();

  double get _introT => _intro.value * BlueprintTimeline.end;
  late _AuthMode _mode =
      widget.startInSignup ? _AuthMode.signup : _AuthMode.login;
  bool _loading = false;
  String? _error;
  bool _rememberLogin = false;

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();

  // Teacher invite: the app is now the only way to redeem one (the website's
  // ?invite=<token> flow is being retired) -- "Have an invite code?" reveals
  // this field, and checking it validates against is_teacher_invite_valid()
  // before the rest of the form is even filled, same courtesy the website
  // gave by pre-checking the token from the URL on page load.
  bool _showInvite = false;
  bool _checkingInvite = false;
  bool? _inviteValid;

  @override
  void initState() {
    super.initState();
    _loadSavedLogin();
    _intro.addStatusListener((s) {
      if (s == AnimationStatus.completed) _idle.repeat();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_introStarted) return;
    _introStarted = true;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_introPlayed || reduceMotion || _mode != _AuthMode.login) {
      _intro.value = 1;
      _idle.repeat();
      return;
    }
    _introPlayed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureLift());
    _startIntro();
  }

  /// How far the logo has to travel: it starts at screen centre and lands
  /// in its slot above the form.
  void _measureLift() {
    final box = _logoSlotKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !mounted) return;
    final slotCenter = box.localToGlobal(box.size.center(Offset.zero)).dy;
    final target = MediaQuery.of(context).size.height * 0.44;
    setState(() => _logoLift = target - slotCenter);
  }

  Future<void> _startIntro() async {
    // Draw with the real typefaces from the first frame.
    try {
      await GoogleFonts.pendingFonts([
        GoogleFonts.montserrat(fontWeight: FontWeight.w300),
        GoogleFonts.ibmPlexMono(),
      ]).timeout(const Duration(milliseconds: 1200));
    } catch (_) {}
    if (!mounted) return;
    _intro.forward();
    _playSound(_introSound, 'sounds/login_intro.wav', 0.75);
  }

  /// Sound effects follow the phone's silent mode and never interrupt the
  /// user's music; any audio failure is ignored (sound is decoration).
  Future<void> _playSound(AudioPlayer player, String asset, double volume) async {
    try {
      await player.setAudioContext(AudioContextConfig(
        respectSilence: true,
        focus: AudioContextConfigFocus.mixWithOthers,
      ).build());
      await player.play(AssetSource(asset), volume: volume);
    } catch (_) {}
  }

  void _skipIntro() {
    if (_intro.value >= 1) return;
    _intro.value = 1;
    _introSound.stop().catchError((_) {});
  }

  Future<void> _loadSavedLogin() async {
    final saved = await SupabaseService.instance.getSavedLogin();
    if (saved == null || !mounted) return;
    // Don't overwrite anything the user already started typing.
    if (_emailCtrl.text.isNotEmpty || _passCtrl.text.isNotEmpty) return;
    setState(() {
      _emailCtrl.text = saved.email;
      if (_mode == _AuthMode.login) _passCtrl.text = saved.password;
      _rememberLogin = true;
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    _idle.dispose();
    _introSound.dispose();
    _tapSound.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  void _switchMode(_AuthMode mode) {
    setState(() {
      _mode = mode;
      _error = null;
    });
    if (mode == _AuthMode.login) _loadSavedLogin();
    // A remembered login password shouldn't silently become the new
    // account's password.
    if (mode == _AuthMode.signup) _passCtrl.clear();
  }

  Future<void> _submitLogin() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result =
        await SupabaseService.instance.login(_emailCtrl.text, _passCtrl.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (result.error != null) {
      setState(() => _error = _t(result.error!));
      return;
    }
    // Password was accepted (even if an email step follows), so it's safe
    // to remember -- or forget it if the box was unticked.
    if (_rememberLogin) {
      await SupabaseService.instance
          .saveLogin(_emailCtrl.text, _passCtrl.text);
    } else {
      await SupabaseService.instance.clearSavedLogin();
    }
    if (!mounted) return;
    if (result.needsEmailOtp) {
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => VerifyLoginOtpScreen(email: result.email!),
        ),
      );
      if (verified == true && mounted) Navigator.of(context).pop();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _submitSignup() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await SupabaseService.instance.signUp(
      name: _nameCtrl.text,
      phone: _phoneCtrl.text,
      email: _emailCtrl.text,
      password: _passCtrl.text,
    );
    if (err != null) {
      setState(() {
        _loading = false;
        _error = _t(err);
      });
      return;
    }
    final inviteToken = _inviteCtrl.text.trim().toLowerCase();
    if (inviteToken.isNotEmpty) {
      await SupabaseService.instance.redeemTeacherInvite(inviteToken);
    }
    setState(() => _loading = false);
    if (!mounted) return;
    if (!kPhoneOtpEnabled) {
      if (inviteToken.isNotEmpty) {
        // Straight to payment setup instead of just closing -- a teacher
        // account is no good to anyone (including its own owner) until
        // there's somewhere to send their earnings.
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => const TeacherScreen(openPaymentInfo: true)));
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    // Replaces this route (rather than pushing) so VerifyPhoneScreen's own
    // pop-on-success goes straight back to whatever opened AuthScreen —
    // the signup form itself is done and shouldn't still be on the stack.
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => const VerifyPhoneScreen(fromSignup: true)));
  }

  Future<void> _checkInvite() async {
    final token = _inviteCtrl.text.trim().toLowerCase();
    if (token.isEmpty) return;
    setState(() {
      _checkingInvite = true;
      _inviteValid = null;
    });
    final valid = await SupabaseService.instance.checkTeacherInviteValid(token);
    if (!mounted) return;
    setState(() {
      _checkingInvite = false;
      _inviteValid = valid;
    });
  }

  Future<void> _submitGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await SupabaseService.instance.signInWithGoogle();
    if (!mounted) return;
    setState(() => _loading = false);
    if (result.error != null) {
      setState(() => _error = _t(result.error!));
      return;
    }
    if (result.needsEmailOtp) {
      final verified = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => VerifyLoginOtpScreen(email: result.email!),
        ),
      );
      if (verified == true && mounted) Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _submitForgot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final err =
        await SupabaseService.instance.sendPasswordReset(_emailCtrl.text);
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = _t(err));
      return;
    }
    _switchMode(_AuthMode.forgotSent);
  }

  // The sign-in screens are always dark (a branded entry screen with a warm
  // glow, whatever the app theme), so they use their own fixed palette
  // rather than AppColors, which flips with the light/dark setting.
  static const _bg = Color(0xFF0E0C0A);
  static const _glow = Color(0xFFE8622C);
  static const _amber = Color(0xFFF2B544);
  static const _fieldBg = Color(0xFF1A1714);
  static const _fieldLine = Color(0x1FFFFFFF);
  static const _ink = Color(0xFFFEE4BF);
  static const _soft = Color(0xFFA79D8F);
  static const _faint = Color(0xFF6E665B);
  static const _danger = Color(0xFFFF7A59);

  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _bg,
          body: Stack(
            children: [
              const Positioned.fill(
                  child: BlueprintBackdrop(
                      dark: true, focus: Alignment(0, -0.4))),
              SafeArea(
                child: Column(
                  children: [
                    _reveal(0, Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded),
                            color: _ink,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    )),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: _buildBody(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Any tap while the logo is still being drawn skips to the form.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _intro,
                  builder: (context, _) => IgnorePointer(
                    ignoring: _introT >= BlueprintTimeline.lift,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _skipIntro,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fades and lifts a piece of the form in after the logo lands; the
  /// [order] staggers them top to bottom.
  Widget _reveal(int order, Widget child) {
    return AnimatedBuilder(
      animation: _intro,
      child: child,
      builder: (context, child) {
        final start = BlueprintTimeline.lift + 0.35 + order * 0.07;
        final raw = ((_introT - start) / 0.6).clamp(0.0, 1.0);
        if (raw >= 1) return child!;
        final p = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: p,
          child: Transform.translate(
              offset: Offset(0, 14 * (1 - p)), child: child),
        );
      },
    );
  }

  static const _logoW = 230.0;
  static const _slotW = 150.0;

  /// The Blueprint Pour logo: drawn large at screen centre, then lifted and
  /// shrunk into its slot above the form.
  Widget _blueprintHeader() {
    return SizedBox(
      key: _logoSlotKey,
      width: _slotW,
      height: _slotW * 1.2,
      child: OverflowBox(
        maxWidth: _logoW,
        maxHeight: _logoW * 1.2,
        child: AnimatedBuilder(
          animation: Listenable.merge([_intro, _idle]),
          builder: (context, _) {
            final t = _introT;
            final lp = Curves.easeInOutCubic.transform(
                ((t - BlueprintTimeline.lift) / BlueprintTimeline.liftDur)
                    .clamp(0.0, 1.0));
            return Transform.translate(
              offset: Offset(0, _logoLift * (1 - lp)),
              child: Transform.scale(
                scale: 1 + (_slotW / _logoW - 1) * lp,
                child: BlueprintLogo(
                    t: t, shine: _shinePhase(), width: _logoW),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Idle light sweep: 1.3 s across the mark, then a 4.2 s rest.
  double _shinePhase() {
    if (_intro.value < 1) return -1;
    final s = _idle.value * 5.5;
    return s < 1.3 ? s / 1.3 : -1;
  }

  Widget _staticLogo() => AnimatedBuilder(
        animation: _idle,
        builder: (context, _) => BlueprintLogo(
            t: BlueprintTimeline.end, shine: _shinePhase(), width: 120),
      );

  Widget _buildBody() {
    switch (_mode) {
      case _AuthMode.login:
        return _loginForm();
      case _AuthMode.signup:
        return _signupForm();
      case _AuthMode.forgot:
        return _forgotForm();
      case _AuthMode.forgotSent:
        return _forgotSentBox();
    }
  }

  // ---- building blocks ----

  Widget _header(String title, {String? sub}) {
    return Column(
      children: [
        _mode == _AuthMode.login ? _blueprintHeader() : _staticLogo(),
        const SizedBox(height: 18),
        _reveal(1, Column(children: [
          Text(title,
              textAlign: TextAlign.center,
              style: AppFonts.body(
                  size: 24, color: _ink, weight: FontWeight.w700)),
          if (sub != null) ...[
            const SizedBox(height: 6),
            Text(sub,
                textAlign: TextAlign.center,
                style: AppFonts.body(size: 13.5, color: _soft)),
          ],
        ])),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
        child: Text(text,
            style:
                AppFonts.body(size: 13.5, color: _ink, weight: FontWeight.w500)),
      );

  InputDecoration _decoration(String hint, {Widget? suffix}) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: AppFonts.body(size: 14, color: _faint),
      filled: true,
      fillColor: _fieldBg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: border(_fieldLine),
      border: border(_fieldLine),
      focusedBorder: border(_glow.withValues(alpha: 0.8), 1.4),
      suffixIcon: suffix,
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String hint = '',
    bool ltr = false,
    bool password = false,
    TextInputType? keyboard,
    List<String>? autofill,
    TextCapitalization caps = TextCapitalization.none,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(label),
        TextField(
          controller: controller,
          textDirection: ltr ? TextDirection.ltr : null,
          obscureText: password && _obscure,
          keyboardType: keyboard,
          autofillHints: autofill,
          textCapitalization: caps,
          onChanged: onChanged,
          cursorColor: _glow,
          style: AppFonts.body(size: 15, color: _ink),
          decoration: _decoration(
            hint,
            suffix: password
                ? IconButton(
                    icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                        color: _soft),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _errorText() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!,
              style: AppFonts.body(size: 13, color: _danger)),
        );

  Widget _primaryButton(String label, VoidCallback onPressed) {
    final enabled = !_loading;
    return Opacity(
      opacity: enabled ? 1 : 0.7,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: const LinearGradient(
            begin: AlignmentDirectional.centerEnd,
            end: AlignmentDirectional.centerStart,
            colors: [_glow, _amber],
          ),
          boxShadow: [
            BoxShadow(
                color: _glow.withValues(alpha: 0.45),
                blurRadius: 28,
                offset: const Offset(0, 10)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: enabled
                ? () {
                    _playSound(_tapSound, 'sounds/tap.wav', 0.6);
                    onPressed();
                  }
                : null,
            child: SizedBox(
              height: 54,
              child: Center(
                child: _loading
                    ? const _Spinner(color: Color(0xFF2A1406))
                    : Text(label,
                        style: AppFonts.body(
                            size: 16,
                            color: const Color(0xFF2A1406),
                            weight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _darkPillButton(
      {required Widget child, required VoidCallback? onPressed}) {
    return Material(
      color: const Color(0xFF181512),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: const BorderSide(color: _fieldLine),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: SizedBox(height: 52, child: Center(child: child)),
      ),
    );
  }

  Widget _googleButton() => _darkPillButton(
        onPressed: _loading ? null : _submitGoogle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _GoogleGlyph(),
            const SizedBox(width: 10),
            Text(_t('continue_with_google'),
                style: AppFonts.body(
                    size: 14.5, color: _ink, weight: FontWeight.w600)),
          ],
        ),
      );

  Widget _orDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(children: [
        const Expanded(child: Divider(color: _fieldLine)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(_t('or_divider'),
              style: AppFonts.body(size: 12.5, color: _faint)),
        ),
        const Expanded(child: Divider(color: _fieldLine)),
      ]),
    );
  }

  Widget _textLink(String label, VoidCallback onTap,
      {Color color = _soft, double size = 13.5}) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onTap,
      child: Text(label, style: AppFonts.body(size: size, color: color)),
    );
  }

  /// "No account? Create one" / "Have an account? Sign in" under the form.
  Widget _switchLine(String prompt, String action, _AuthMode target) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(prompt, style: AppFonts.body(size: 14, color: _soft)),
          const SizedBox(width: 6),
          _textLink(action, () => _switchMode(target),
              color: _amber, size: 14.5),
        ],
      ),
    );
  }

  // ---- forms ----

  Widget _loginForm() {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(_t('auth_login_title'), sub: _t('auth_login_heading_sub')),
          _reveal(2, _field(
            label: _t('label_email'),
            controller: _emailCtrl,
            hint: _t('ph_email_enter'),
            ltr: true,
            keyboard: TextInputType.emailAddress,
            autofill: const [AutofillHints.email],
          )),
          const SizedBox(height: 18),
          _reveal(3, _field(
            label: _t('label_password'),
            controller: _passCtrl,
            hint: _t('ph_password_enter'),
            ltr: true,
            password: true,
            autofill: const [AutofillHints.password],
          )),
          const SizedBox(height: 10),
          _reveal(4, Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _rememberLogin = !_rememberLogin),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: _rememberLogin,
                          onChanged: (v) =>
                              setState(() => _rememberLogin = v ?? false),
                          activeColor: _glow,
                          checkColor: Colors.white,
                          side: const BorderSide(color: _soft, width: 1.4),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5)),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_t('remember_login'),
                          style: AppFonts.body(size: 13.5, color: _soft)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _textLink(_t('forgot_password'),
                  () => _switchMode(_AuthMode.forgot)),
            ],
          )),
          _errorText(),
          const SizedBox(height: 22),
          _reveal(5, _primaryButton(_t('auth_login_title'), _submitLogin)),
          _reveal(6, _orDivider()),
          _reveal(7, _googleButton()),
          _reveal(8, _switchLine(_t('no_account'), _t('sign_up'), _AuthMode.signup)),
        ],
      ),
    );
  }

  Widget _signupForm() {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(_t('auth_signup_title'), sub: _t('auth_signup_sub')),
          _field(
            label: _t('label_fullname'),
            controller: _nameCtrl,
            hint: _t('ph_fullname'),
            autofill: const [AutofillHints.name],
          ),
          const SizedBox(height: 16),
          _field(
            label: _t('label_phone'),
            controller: _phoneCtrl,
            hint: _t('ph_phone'),
            ltr: true,
            keyboard: TextInputType.phone,
            autofill: const [AutofillHints.telephoneNumber],
          ),
          const SizedBox(height: 16),
          _field(
            label: _t('label_email'),
            controller: _emailCtrl,
            hint: _t('ph_email_enter'),
            ltr: true,
            keyboard: TextInputType.emailAddress,
            autofill: const [AutofillHints.email],
          ),
          const SizedBox(height: 16),
          _field(
            label: _t('label_password'),
            controller: _passCtrl,
            hint: _t('ph_password'),
            ltr: true,
            password: true,
            autofill: const [AutofillHints.newPassword],
          ),
          const SizedBox(height: 8),
          if (!_showInvite)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _textLink(_t('have_invite_code'),
                  () => setState(() => _showInvite = true),
                  color: _amber),
            )
          else ...[
            const SizedBox(height: 8),
            _label(_t('label_invite_code')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inviteCtrl,
                    autocorrect: false,
                    textDirection: TextDirection.ltr,
                    cursorColor: _glow,
                    style: AppFonts.body(size: 15, color: _ink),
                    decoration: _decoration(''),
                    onChanged: (_) => setState(() => _inviteValid = null),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 92,
                  child: _darkPillButton(
                    onPressed: _checkingInvite ? null : _checkInvite,
                    child: _checkingInvite
                        ? const _Spinner()
                        : Text(_t('btn_check'),
                            style: AppFonts.body(
                                size: 14,
                                color: _ink,
                                weight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
            if (_inviteValid == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_t('invite_valid'),
                    style: AppFonts.body(
                        size: 13, color: const Color(0xFF7CC4B8))),
              ),
            if (_inviteValid == false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_t('invite_invalid_title'),
                    style: AppFonts.body(size: 13, color: _danger)),
              ),
          ],
          _errorText(),
          const SizedBox(height: 22),
          _primaryButton(_t('auth_signup_title'), _submitSignup),
          _orDivider(),
          _googleButton(),
          _switchLine(_t('have_account'), _t('auth_login_title'), _AuthMode.login),
        ],
      ),
    );
  }

  Widget _forgotForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(_t('auth_forgot_title'), sub: _t('auth_forgot_sub')),
        _field(
          label: _t('label_email'),
          controller: _emailCtrl,
          hint: _t('ph_email_enter'),
          ltr: true,
          keyboard: TextInputType.emailAddress,
          autofill: const [AutofillHints.email],
        ),
        _errorText(),
        const SizedBox(height: 22),
        _primaryButton(_t('btn_send_reset'), _submitForgot),
        const SizedBox(height: 14),
        Center(
            child: _textLink(
                _t('back_to_login'), () => _switchMode(_AuthMode.login))),
      ],
    );
  }

  Widget _forgotSentBox() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _staticLogo(),
        const SizedBox(height: 26),
        const Icon(Icons.mark_email_read_outlined, color: _amber, size: 40),
        const SizedBox(height: 14),
        Text(_t('success_email_title'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 22, color: _ink, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(_t('success_email_sub'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13.5, color: _soft)),
        const SizedBox(height: 24),
        _primaryButton(_t('back_to_login'), () => _switchMode(_AuthMode.login)),
      ],
    );
  }
}

/// The Google "G" mark, drawn rather than shipped as an image asset — four
/// arcs in Google's brand colors is the one piece of this button Google's
/// branding guidelines actually require, everything else (label, button
/// shape) follows the app's own style.
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(painter: _GoogleGlyphPainter()),
    );
  }
}

class _GoogleGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final stroke = size.width * 0.22;
    final rect = Rect.fromCircle(center: center, radius: r - stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    void arc(double startDeg, double sweepDeg, Color color) {
      paint.color = color;
      canvas.drawArc(rect, startDeg * 3.1415926535 / 180,
          sweepDeg * 3.1415926535 / 180, false, paint);
    }

    // Four quarter-ish arcs matching Google's mark proportions closely
    // enough at 18px that the classic red/blue/green/yellow ring reads
    // instantly without shipping an actual asset file.
    arc(-90, 90, const Color(0xFF4285F4)); // blue, top-right
    arc(0, 90, const Color(0xFF34A853)); // green, bottom-right
    arc(90, 90, const Color(0xFFFBBC05)); // yellow, bottom-left
    arc(180, 90, const Color(0xFFEA4335)); // red, top-left
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Spinner extends StatelessWidget {
  final Color color;
  const _Spinner({this.color = Colors.white});
  @override
  Widget build(BuildContext context) => SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color));
}
