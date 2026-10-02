import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
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

class _AuthScreenState extends State<AuthScreen> {
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
    final inviteToken = _inviteCtrl.text.trim();
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
    final token = _inviteCtrl.text.trim();
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
  static const _ink = Color(0xFFF6F1EA);
  static const _soft = Color(0xFFA79D8F);
  static const _faint = Color(0xFF6E665B);
  static const _danger = Color(0xFFFF7A59);

  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final linkLabel = _mode == _AuthMode.signup
        ? _t('auth_login_title')
        : _t('sign_up');
    final showTopLink =
        _mode == _AuthMode.login || _mode == _AuthMode.signup;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _bg,
          body: Stack(
            children: [
              const Positioned.fill(child: _WarmBackdrop()),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_rounded),
                            color: _ink,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Spacer(),
                          if (showTopLink)
                            TextButton(
                              onPressed: () => _switchMode(
                                  _mode == _AuthMode.signup
                                      ? _AuthMode.login
                                      : _AuthMode.signup),
                              child: Text(linkLabel,
                                  style: AppFonts.body(
                                          size: 14,
                                          color: _ink,
                                          weight: FontWeight.w600)
                                      .copyWith(
                                          decoration: TextDecoration.underline,
                                          decorationColor: _ink)),
                            ),
                        ],
                      ),
                    ),
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
            ],
          ),
        ),
      ),
    );
  }

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
        const _GlowLogo(),
        const SizedBox(height: 26),
        Text(title,
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 24, color: _ink, weight: FontWeight.w700)),
        if (sub != null) ...[
          const SizedBox(height: 6),
          Text(sub,
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 13.5, color: _soft)),
        ],
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
            onTap: enabled ? onPressed : null,
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

  // ---- forms ----

  Widget _loginForm() {
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(_t('auth_login_title'), sub: _t('auth_login_heading_sub')),
          _field(
            label: _t('label_email'),
            controller: _emailCtrl,
            hint: _t('ph_email_enter'),
            ltr: true,
            keyboard: TextInputType.emailAddress,
            autofill: const [AutofillHints.email],
          ),
          const SizedBox(height: 18),
          _field(
            label: _t('label_password'),
            controller: _passCtrl,
            hint: _t('ph_password_enter'),
            ltr: true,
            password: true,
            autofill: const [AutofillHints.password],
          ),
          const SizedBox(height: 10),
          Row(
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
          ),
          _errorText(),
          const SizedBox(height: 22),
          _primaryButton(_t('auth_login_title'), _submitLogin),
          _orDivider(),
          _googleButton(),
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
                    textCapitalization: TextCapitalization.characters,
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
        const _GlowLogo(),
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

/// Warm light falling from the top of the screen into near-black, like a
/// work lamp over a dark drafting table.
class _WarmBackdrop extends StatelessWidget {
  const _WarmBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0, 0.38, 0.72],
          colors: [Color(0xFF5A2C12), Color(0xFF20130B), Color(0xFF0E0C0A)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.6, -1.1),
            radius: 1.1,
            colors: [Color(0x55F2B544), Color(0x00F2B544)],
          ),
        ),
      ),
    );
  }
}

/// The brand mark (A, until the final logo) on a glowing tile, with a second frosted tile stacked
/// beneath it.
class _GlowLogo extends StatelessWidget {
  const _GlowLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 118,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // lower, frosted layer
          Positioned(
            top: 22,
            child: Transform.rotate(
              angle: 0.785398, // 45 degrees
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: const Color(0x14FFFFFF),
                  border: Border.all(color: const Color(0x1FFFFFFF)),
                ),
              ),
            ),
          ),
          // top tile
          Positioned(
            top: 4,
            child: Transform.rotate(
              angle: 0.785398,
              child: Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF3A2416), Color(0xFF1B120C)],
                  ),
                  border: Border.all(color: const Color(0x33FFFFFF)),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFFE8622C).withValues(alpha: 0.35),
                        blurRadius: 36,
                        spreadRadius: 2),
                  ],
                ),
                child: Transform.rotate(
                  angle: -0.785398,
                  child: Center(
                    child: ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFF2B544), Color(0xFFE8622C)],
                      ).createShader(r),
                      child: Text('A',
                          style: AppFonts.heading(
                              size: 40, color: Colors.white)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
