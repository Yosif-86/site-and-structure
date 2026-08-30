import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/brand_title.dart';

enum _AuthMode { login, signup, forgot, forgotSent }

/// Port of renderAuth() in index.html — one screen, three modes.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _AuthMode _mode = _AuthMode.login;
  bool _loading = false;
  String? _error;

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
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
    setState(() { _loading = true; _error = null; });
    final err = await SupabaseService.instance.login(_emailCtrl.text, _passCtrl.text);
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = _t(err));
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _submitSignup() async {
    setState(() { _loading = true; _error = null; });
    final err = await SupabaseService.instance.signUp(
      name: _nameCtrl.text,
      phone: _phoneCtrl.text,
      email: _emailCtrl.text,
      password: _passCtrl.text,
    );
    setState(() => _loading = false);
    if (err != null) {
      setState(() => _error = _t(err));
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _submitForgot() async {
    setState(() { _loading = true; _error = null; });
    final err = await SupabaseService.instance.sendPasswordReset(_emailCtrl.text);
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
      appBar: AppBar(title: const SizedBox.shrink()),
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
        Text(_t('auth_login_sub'), style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(controller: _emailCtrl, decoration: InputDecoration(labelText: _t('label_email'), hintText: _t('ph_email')), keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 14),
        TextField(controller: _passCtrl, decoration: InputDecoration(labelText: _t('label_password')), obscureText: true),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submitLogin,
          child: _loading ? const _Spinner() : Text(_t('auth_login_title')),
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(onPressed: () => _switchMode(_AuthMode.forgot), child: Text(_t('forgot_password'))),
        ),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              Text(_t('no_account'), style: AppFonts.body(color: AppColors.muted)),
              TextButton(onPressed: () => _switchMode(_AuthMode.signup), child: Text(_t('sign_up'))),
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
        Text(_t('auth_signup_sub'), style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: _t('label_fullname'), hintText: _t('ph_fullname'))),
        const SizedBox(height: 14),
        TextField(controller: _phoneCtrl, decoration: InputDecoration(labelText: _t('label_phone'), hintText: _t('ph_phone')), keyboardType: TextInputType.phone),
        const SizedBox(height: 14),
        TextField(controller: _emailCtrl, decoration: InputDecoration(labelText: _t('label_email'), hintText: _t('ph_email')), keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 14),
        TextField(controller: _passCtrl, decoration: InputDecoration(labelText: _t('label_password'), hintText: _t('ph_password')), obscureText: true),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submitSignup,
          child: _loading ? const _Spinner() : Text(_t('auth_signup_title')),
        ),
        const SizedBox(height: 14),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            children: [
              Text(_t('already_account'), style: AppFonts.body(color: AppColors.muted)),
              TextButton(onPressed: () => _switchMode(_AuthMode.login), child: Text(_t('auth_login_title'))),
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
        Text(_t('auth_forgot_sub'), style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 20),
        TextField(controller: _emailCtrl, decoration: InputDecoration(labelText: _t('label_email'), hintText: _t('ph_email')), keyboardType: TextInputType.emailAddress),
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
        Center(child: TextButton(onPressed: () => _switchMode(_AuthMode.login), child: Text(_t('back_to_login')))),
      ],
    );
  }

  Widget _forgotSentBox() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle_outline, color: AppColors.teal, size: 44),
        const SizedBox(height: 16),
        Text(_t('success_email_title'), style: AppFonts.heading(size: 22)),
        const SizedBox(height: 8),
        Text(_t('success_email_sub'), textAlign: TextAlign.center, style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 18),
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(_t('btn_close'))),
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}
