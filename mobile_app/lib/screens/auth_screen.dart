import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/brand_title.dart';
import '../widgets/glass_card.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const SizedBox.shrink(),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: AmbientBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const BrandTitle(),
                    const SizedBox(height: 28),
                    GlassCard(
                      glass: true,
                      borderRadius: BorderRadius.circular(20),
                      padding: const EdgeInsets.all(24),
                      child: _buildBody(),
                    ),
                  ],
                ),
              ),
            ),
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

  Widget _loginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('auth_login_title'), style: AppFonts.heading(size: 24)),
        const SizedBox(height: 6),
        Text(_t('auth_login_sub'),
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(
            controller: _emailCtrl,
            decoration: InputDecoration(
                labelText: _t('label_email'), hintText: _t('ph_email')),
            keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 14),
        TextField(
            controller: _passCtrl,
            decoration: InputDecoration(labelText: _t('label_password')),
            obscureText: true),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submitLogin,
          child: _loading ? const _Spinner() : Text(_t('auth_login_title')),
        ),
        _orDivider(),
        _googleButton(),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
              onPressed: () => _switchMode(_AuthMode.forgot),
              child: Text(_t('forgot_password'))),
        ),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              Text(_t('no_account'),
                  style: AppFonts.body(color: AppColors.muted)),
              TextButton(
                  onPressed: () => _switchMode(_AuthMode.signup),
                  child: Text(_t('sign_up'))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _signupForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('auth_signup_title'), style: AppFonts.heading(size: 24)),
        const SizedBox(height: 6),
        Text(_t('auth_signup_sub'),
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
                labelText: _t('label_fullname'), hintText: _t('ph_fullname'))),
        const SizedBox(height: 14),
        TextField(
            controller: _phoneCtrl,
            decoration: InputDecoration(
                labelText: _t('label_phone'), hintText: _t('ph_phone')),
            keyboardType: TextInputType.phone),
        const SizedBox(height: 14),
        TextField(
            controller: _emailCtrl,
            decoration: InputDecoration(
                labelText: _t('label_email'), hintText: _t('ph_email')),
            keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 14),
        TextField(
            controller: _passCtrl,
            decoration: InputDecoration(
                labelText: _t('label_password'), hintText: _t('ph_password')),
            obscureText: true),
        const SizedBox(height: 10),
        if (!_showInvite)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _showInvite = true),
              child: Text(_t('have_invite_code')),
            ),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _inviteCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration:
                      InputDecoration(labelText: _t('label_invite_code')),
                  onChanged: (_) => setState(() => _inviteValid = null),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton(
                  onPressed: _checkingInvite ? null : _checkInvite,
                  child: _checkingInvite
                      ? const _Spinner()
                      : Text(_t('btn_check')),
                ),
              ),
            ],
          ),
          if (_inviteValid == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_t('invite_valid'),
                  style: AppFonts.body(size: 12.5, color: AppColors.teal)),
            ),
          if (_inviteValid == false)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_t('invite_invalid_title'),
                  style: AppFonts.body(size: 12.5, color: AppColors.red)),
            ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submitSignup,
          child: _loading ? const _Spinner() : Text(_t('auth_signup_title')),
        ),
        _orDivider(),
        _googleButton(),
        const SizedBox(height: 14),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              Text(_t('already_account'),
                  style: AppFonts.body(color: AppColors.muted)),
              TextButton(
                  onPressed: () => _switchMode(_AuthMode.login),
                  child: Text(_t('auth_login_title'))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _forgotForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_t('auth_forgot_title'), style: AppFonts.heading(size: 24)),
        const SizedBox(height: 6),
        Text(_t('auth_forgot_sub'),
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(
            controller: _emailCtrl,
            decoration: InputDecoration(
                labelText: _t('label_email'), hintText: _t('ph_email')),
            keyboardType: TextInputType.emailAddress),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submitForgot,
          child: _loading ? const _Spinner() : Text(_t('btn_send_reset')),
        ),
        const SizedBox(height: 14),
        Center(
            child: TextButton(
                onPressed: () => _switchMode(_AuthMode.login),
                child: Text(_t('back_to_login')))),
      ],
    );
  }

  Widget _forgotSentBox() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_outline, color: AppColors.teal, size: 44),
        const SizedBox(height: 16),
        Text(_t('success_email_title'), style: AppFonts.heading(size: 22)),
        const SizedBox(height: 8),
        Text(_t('success_email_sub'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 18),
        OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_t('btn_close'))),
      ],
    );
  }

  Widget _orDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(children: [
        Expanded(child: Divider(color: AppColors.line)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(_t('or_divider'),
              style: AppFonts.body(size: 12, color: AppColors.muted)),
        ),
        Expanded(child: Divider(color: AppColors.line)),
      ]),
    );
  }

  Widget _googleButton() {
    return OutlinedButton(
      onPressed: _loading ? null : _submitGoogle,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _GoogleGlyph(),
          const SizedBox(width: 10),
          Text(_t('continue_with_google')),
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
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}
