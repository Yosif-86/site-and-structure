import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/strings.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/arc_icons.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import 'auth_screen.dart';
import 'info_screens.dart';
import 'teacher_screen.dart';

/// Settings list, embedded as the third page of the catalogue PageView — so
/// it deliberately has no Scaffold or AppBar of its own.
///
/// Order is fixed: payment info, support, appearance, share, privacy,
/// terms, FAQ, log out.
class SettingsScreen extends StatelessWidget {
  final bool loggedIn;
  final bool isTeacher;

  const SettingsScreen(
      {super.key, required this.loggedIn, required this.isTeacher});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  // A second confirm while the first delete is running is ignored.
  static bool _deleting = false;

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
    if (confirmed != true || _deleting) return;
    _deleting = true;
    final String? error;
    try {
      error = await SupabaseService.instance.deleteAccount();
    } finally {
      _deleting = false;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t(error ?? 'account_deleted'))));
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
        // their ZainCash / Qi Card payout details live), so nobody else
        // sees the row at all.
        if (isTeacher) ...[
          FadeSlideIn(
            delayMs: 0,
            child: _SettingsTile(
              icon: ArcIcon.wallet,
              accent: AppColors.teal,
              title: t('settings_payment_info'),
              subtitle: t('settings_payment_info_sub'),
              // Reuses the teacher dashboard's existing profile view, which
              // already edits teacher_zaincash_phone / teacher_qi_account_number
              // / teacher_qi_qr_url — no second copy of that form.
              onTap: () =>
                  _push(context, const TeacherScreen(openPaymentInfo: true)),
            ),
          ),
          const SizedBox(height: 12),
        ],
        FadeSlideIn(
          delayMs: 60,
          child: _SettingsTile(
            icon: ArcIcon.support,
            accent: AppColors.teal,
            title: t('settings_support'),
            subtitle: t('settings_support_sub'),
            onTap: () => _push(context, const SupportScreen()),
          ),
        ),
        const SizedBox(height: 12),
        const FadeSlideIn(
          delayMs: 120,
          child: _ThemeTile(),
        ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delayMs: 150,
          child: Builder(
            // The share sheet needs an anchor on iPad-sized screens.
            builder: (tileContext) => _SettingsTile(
              icon: ArcIcon.share,
              accent: AppColors.red,
              title: t('settings_share'),
              subtitle: t('settings_share_sub'),
              onTap: () {
                final box = tileContext.findRenderObject() as RenderBox?;
                SharePlus.instance.share(ShareParams(
                  text: t('share_app_text'),
                  sharePositionOrigin: box == null
                      ? null
                      : box.localToGlobal(Offset.zero) & box.size,
                ));
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delayMs: 180,
          child: _SettingsTile(
            icon: ArcIcon.shield,
            accent: AppColors.teal,
            title: t('settings_privacy'),
            subtitle: t('settings_privacy_sub'),
            onTap: () => _push(context, const PrivacyScreen()),
          ),
        ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delayMs: 200,
          child: _SettingsTile(
            icon: ArcIcon.review,
            accent: AppColors.byline,
            title: t('terms_title'),
            subtitle: t('terms_sub'),
            onTap: () => _push(context, const TermsScreen()),
          ),
        ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delayMs: 220,
          child: _SettingsTile(
            icon: ArcIcon.support,
            accent: AppColors.teal,
            title: t('faq_title'),
            subtitle: t('faq_sub'),
            onTap: () => _push(context, const FaqScreen()),
          ),
        ),
        const SizedBox(height: 12),
        FadeSlideIn(
          delayMs: 240,
          child: _SettingsTile(
            icon: loggedIn ? ArcIcon.logout : ArcIcon.login,
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
              icon: ArcIcon.trash,
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
  final ArcIcon icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.24),
                  accent.withValues(alpha: 0.08),
                ],
              ),
              border: Border.all(color: accent.withValues(alpha: 0.30)),
            ),
            child: Center(
                child:
                    ArcIconView(icon, color: accent, size: 22, active: true)),
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
          ArcIconView(ArcIcon.chevron, size: 18, color: AppColors.muted2),
        ],
      ),
    );
  }
}

/// Appearance: Auto (follow the phone), Light or Dark.
class _ThemeTile extends StatelessWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: AppTheme.instance, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final t = AppStrings.instance.t;
    final theme = AppTheme.instance;
    final subtitle = switch (theme.mode) {
      AppThemeMode.system => t('settings_appearance_system'),
      AppThemeMode.light => t('settings_appearance_light'),
      AppThemeMode.dark => t('settings_appearance_dark'),
    };
    final accent = AppColors.byline;
    Widget option(AppThemeMode mode, String label) {
      final on = theme.mode == mode;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => theme.setMode(mode),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? AppColors.red : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: AppFonts.body(
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: on ? Colors.white : AppColors.muted)),
          ),
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.24),
                      accent.withValues(alpha: 0.08),
                    ],
                  ),
                  border: Border.all(color: accent.withValues(alpha: 0.30)),
                ),
                child: Center(
                    child: ArcIconView(
                        theme.isDark ? ArcIcon.moon : ArcIcon.sun,
                        color: accent,
                        size: 22,
                        active: true)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('settings_appearance'),
                        style:
                            AppFonts.body(size: 16, weight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: AppFonts.body(size: 12, color: AppColors.muted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.text.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.text.withValues(alpha: 0.10)),
            ),
            child: Row(children: [
              option(AppThemeMode.system, t('theme_auto')),
              option(AppThemeMode.light, t('theme_light')),
              option(AppThemeMode.dark, t('theme_dark')),
            ]),
          ),
        ],
      ),
    );
  }
}
