import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../services/deep_links.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// TODO(Yosif): fill in the real support contact details.
///
/// Deliberately left empty rather than filled with a plausible-looking
/// placeholder — a wrong phone number or email shipped in a release is worse
/// than an honest "not set up yet". While these are empty the Support screen
/// says so and offers no dead tap target; set either one (or both) and the
/// matching button appears automatically, no other code change needed.
const String kSupportWhatsappPhone = '';
const String kSupportEmail = '';

/// Support contact screen, reached from Settings.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final hasWhatsapp = kSupportWhatsappPhone.trim().isNotEmpty;
    final hasEmail = kSupportEmail.trim().isNotEmpty;

    return _InfoScaffold(
      title: t('support_title'),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('support_intro'), style: AppFonts.body(size: 13.5, color: AppColors.muted)),
              if (!hasWhatsapp && !hasEmail) ...[
                const SizedBox(height: 16),
                Text(
                  t('support_no_contact'),
                  style: AppFonts.body(size: 13, color: AppColors.muted2),
                ),
              ],
              if (hasWhatsapp) ...[
                const SizedBox(height: 16),
                _ContactButton(
                  icon: Icons.chat_outlined,
                  label: t('label_whatsapp'),
                  onTap: () => DeepLinks.whatsapp(kSupportWhatsappPhone),
                ),
              ],
              if (hasEmail) ...[
                const SizedBox(height: 10),
                _ContactButton(
                  icon: Icons.mail_outline,
                  label: kSupportEmail,
                  onTap: () => DeepLinks.email(kSupportEmail, subject: t('support_title')),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ContactButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ContactButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}

/// Plain-language summary of what the app does with user data.
///
/// PLACEHOLDER COPY — pending real legal review. Every claim below is
/// deliberately written to match what the app actually does today (single
/// device per account, login-event geolocation, screenshot blocking and
/// watermarking on video screens, manual payment screenshots), but this is a
/// summary for users, not a reviewed privacy policy. Replace before any
/// store submission that requires one.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return _InfoScaffold(
      title: t('privacy_title'),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: AppColors.red),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  t('privacy_draft_notice'),
                  style: AppFonts.body(size: 12, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('privacy_intro'), style: AppFonts.body(size: 13.5, color: AppColors.muted)),
              _section(t, 'privacy_h_collect', 'privacy_b_collect'),
              _section(t, 'privacy_h_courses', 'privacy_b_courses'),
              _section(t, 'privacy_h_devices', 'privacy_b_devices'),
              _section(t, 'privacy_h_protection', 'privacy_b_protection'),
              _section(t, 'privacy_h_sharing', 'privacy_b_sharing'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _section(String Function(String) t, String headingKey, String bodyKey) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t(headingKey), style: AppFonts.heading(size: 18)),
          const SizedBox(height: 6),
          Text(t(bodyKey), style: AppFonts.body(size: 13, color: AppColors.muted)),
        ],
      ),
    );
  }
}

/// Shared chrome for the two static screens above.
class _InfoScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _InfoScaffold({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: AppColors.bg,
        appBar: AppBar(backgroundColor: Colors.transparent, title: Text(title)),
        body: AmbientBackground(
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
