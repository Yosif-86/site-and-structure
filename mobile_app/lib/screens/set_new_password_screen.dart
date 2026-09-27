import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// Shown when a password-reset link is opened (see
/// SupabaseService.listenForPasswordRecovery). The recovery session is only
/// good for setting the password: leaving this screen any other way signs
/// it out, and success signs out everywhere so the user logs in normally.
class SetNewPasswordScreen extends StatefulWidget {
  const SetNewPasswordScreen({super.key});

  @override
  State<SetNewPasswordScreen> createState() => _SetNewPasswordScreenState();
}

class _SetNewPasswordScreenState extends State<SetNewPasswordScreen> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _done = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  String _t(String key) => AppStrings.instance.t(key);

  Future<void> _submit() async {
    final pass = _passCtrl.text.trim();
    if (pass.isEmpty || _confirmCtrl.text.trim().isEmpty) {
      setState(() => _error = _t('err_fill_fields'));
      return;
    }
    if (pass != _confirmCtrl.text.trim()) {
      setState(() => _error = _t('err_pass_mismatch'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final err = await SupabaseService.instance.setNewPassword(pass);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (err == null) {
        _done = true;
      } else {
        _error = _t(err);
      }
    });
  }

  Future<void> _leave() async {
    if (!_done) await SupabaseService.instance.endPasswordRecovery();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            title: Text(_t('new_password_title')),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _loading ? null : _leave,
            ),
          ),
          body: AmbientBackground(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: GlassCard(
                      padding: const EdgeInsets.all(24),
                      child: _done ? _successBody() : _formBody(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _formBody() {
    final email = SupabaseService.instance.currentUser?.email;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_t('new_password_title'), style: AppFonts.heading(size: 22)),
        const SizedBox(height: 6),
        Text(
          email == null
              ? _t('new_password_sub')
              : '${_t('new_password_sub')}\n$email',
          style: AppFonts.body(size: 13, color: AppColors.muted),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _passCtrl,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: _t('label_new_password'),
            hintText: _t('ph_password'),
            suffixIcon: IconButton(
              icon: Icon(_obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmCtrl,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(labelText: _t('label_confirm_password')),
          onSubmitted: (_) => _loading ? null : _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: AppFonts.body(size: 12.5, color: AppColors.red)),
        ],
        const SizedBox(height: 18),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_t('btn_update_password')),
        ),
      ],
    );
  }

  Widget _successBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_outline, color: AppColors.teal, size: 44),
        const SizedBox(height: 16),
        Text(_t('password_updated_title'), style: AppFonts.heading(size: 22)),
        const SizedBox(height: 8),
        Text(_t('password_updated_sub'),
            textAlign: TextAlign.center,
            style: AppFonts.body(size: 13, color: AppColors.muted)),
        const SizedBox(height: 18),
        ElevatedButton(onPressed: _leave, child: Text(_t('btn_close'))),
      ],
    );
  }
}
