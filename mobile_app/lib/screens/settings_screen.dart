import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import 'auth_screen.dart';
import 'info_screens.dart';
import 'teacher_screen.dart';

/// Settings list, embedded as the third page of the catalogue PageView — so
/// it deliberately has no Scaffold or AppBar of its own.
///
/// Order is fixed: payment info, support, appearance, privacy, log out.
class SettingsScreen extends StatelessWidget {
  final bool loggedIn;
  final bool isTeacher;

  const SettingsScreen(
      {super.key, required this.loggedIn, required this.isTeacher});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final t = AppStrings.instance.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t('confirm_delete_account'),
            style: TextStyle(color: AppColors.text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('cancel'))),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t('settings_delete_account'),
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await SupabaseService.instance.deleteAccount();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t(error ?? 'account_deleted'))));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;

    // No backdrop of its own -- it sits on the shell's shared glass
    // backdrop, which stays put while the tabs swipe over it.
    return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
          children: [
            Text(t('settings'),
                style: AppFonts.body(size: 26, weight: FontWeight.w800)),
            const SizedBox(height: 16),
            // Payment info only means anything for teachers (it is where
            // their ZainCash / Qi Card payout details live). For everyone
            // else it renders disabled with a one-line explanation rather
            // than being a tap target that leads to a teacher-gated screen.
            FadeSlideIn(
              delayMs: 0,
              child: _SettingsTile(
                icon: Icons.account_balance_wallet_outlined,
                accent: AppColors.teal,
                title: t('settings_payment_info'),
                subtitle: isTeacher
                    ? t('settings_payment_info_sub')
                    : t('settings_payment_teacher_only'),
                enabled: isTeacher,
                // Reuses the teacher dashboard's existing profile view, which
                // already edits teacher_zaincash_phone / teacher_qi_account_number
                // / teacher_qi_qr_url — no second copy of that form.
                onTap: () =>
                    _push(context, const TeacherScreen(openPaymentInfo: true)),
              ),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delayMs: 60,
              child: _SettingsTile(
                icon: Icons.support_agent_outlined,
                accent: AppColors.teal,
                title: t('settings_support'),
                subtitle: t('settings_support_sub'),
                onTap: () => _push(context, const SupportScreen()),
              ),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delayMs: 120,
              child: _SettingsTile(
                icon: AppTheme.instance.isDark
                    ? Icons.dark_mode_outlined
                    : Icons.light_mode_outlined,
                accent: AppColors.byline,
                title: t('settings_appearance'),
                subtitle: AppTheme.instance.isDark
                    ? t('settings_appearance_dark')
                    : t('settings_appearance_light'),
                trailing: Switch(
                  value: AppTheme.instance.isDark,
                  activeThumbColor: AppColors.red,
                  onChanged: (_) => AppTheme.instance.toggle(),
                ),
                onTap: () => AppTheme.instance.toggle(),
              ),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delayMs: 180,
              child: _SettingsTile(
                icon: Icons.privacy_tip_outlined,
                accent: AppColors.teal,
                title: t('settings_privacy'),
                subtitle: t('settings_privacy_sub'),
                onTap: () => _push(context, const PrivacyScreen()),
              ),
            ),
            const SizedBox(height: 12),
            FadeSlideIn(
              delayMs: 240,
              child: _SettingsTile(
                icon: loggedIn ? Icons.logout : Icons.login,
                accent: AppColors.red,
                title: loggedIn ? t('log_out') : t('log_in'),
                onTap: () async {
                  if (loggedIn) {
                    await SupabaseService.instance.logout();
                  } else {
                    _push(context, const AuthScreen());
                  }
                },
              ),
            ),
            if (loggedIn) ...[
              const SizedBox(height: 12),
              FadeSlideIn(
                delayMs: 300,
                child: _SettingsTile(
                  icon: Icons.delete_outline,
                  accent: AppColors.error,
                  title: t('settings_delete_account'),
                  subtitle: t('settings_delete_account_sub'),
                  onTap: () => _confirmDeleteAccount(context),
                ),
              ),
            ],
          ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool enabled;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    this.trailing,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dim = enabled ? 1.0 : 0.45;
    return Opacity(
      opacity: dim,
      child: GlassCard(
        onTap: enabled ? onTap : null,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
              ),
              child: Icon(icon, color: accent, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppFonts.body(size: 16, weight: FontWeight.w600)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!,
                        style: AppFonts.body(size: 12, color: AppColors.muted)),
                  ],
                ],
              ),
            ),
            trailing ?? Icon(Icons.chevron_right, color: AppColors.muted2),
          ],
        ),
      ),
    );
  }
}
