import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../i18n/strings.dart';
import '../services/deep_links.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_card.dart';

/// Support contact. The email forwards to the Arc support inbox (Cloudflare
/// Email Routing). TODO(Yosif): add the support WhatsApp number (planned for
/// about a month after 2026-10-06; also SUPPORT_WHATSAPP in site.js).
///
/// An empty value hides its button rather than showing a placeholder — a
/// wrong number shipped in a release is worse than none. Fill it in and the
/// button appears automatically, no other code change needed.
const String kSupportWhatsappPhone = '';
const String kSupportEmail = 'support@arcplatformiq.com';

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
                  brand: FontAwesomeIcons.whatsapp,
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
  /// A Material icon, or [brand] for a platform logo (Font Awesome).
  final IconData? icon;
  final FaIconData? brand;
  final String label;
  final VoidCallback onTap;

  const _ContactButton({this.icon, this.brand, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: brand != null ? FaIcon(brand, size: 18) : Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}

/// The full policies live on the website (privacy, terms, refund).
const String kSiteUrl = 'https://arcplatformiq.com';

/// Button that opens one of the full policy pages on the website.
class _FullTextButton extends StatelessWidget {
  final String label;
  final String path;
  const _FullTextButton(this.label, this.path);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => DeepLinks.web('$kSiteUrl/$path'),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(label),
        ),
      );
}

/// Plain-language summary of what the app does with user data; the full
/// policy is on the website (privacy.html).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return _InfoScaffold(
      title: t('privacy_title'),
      children: [
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
        const SizedBox(height: 14),
        _FullTextButton(t('btn_full_privacy'), 'privacy.html'),
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

// Arabic-only app: the long texts live here rather than in strings.dart.
const List<(String, String)> _termsSections = [
  ('القبول',
      'باستخدامك منصة آرك وإنشاء حساب فيها فإنك توافق على هذه الشروط. إذا لم توافق عليها فلا تستخدم المنصة.'),
  ('الحساب',
      'لكل شخص حساب واحد برقم هاتف واحد وبريد إلكتروني واحد. أنت مسؤول عن صحة معلوماتك وعن حماية كلمة المرور.'),
  ('الأجهزة',
      'يعمل الحساب على جهاز واحد فقط. محاولة فتح الحساب من جهاز آخر تُمنع وتُسجَّل، وتكرارها قد يؤدي إلى إيقاف الحساب.'),
  ('حماية المحتوى',
      'يُمنع مشاركة الحساب، أو تصوير المحاضرات والملفات أو تسجيلها أو نسخها أو نشرها بأي شكل. المحتوى يحمل علامة مائية باسمك ورقم هاتفك، وأي تسريب يعرّض صاحب الحساب لإيقافه نهائيًا وللمساءلة القانونية.'),
  ('الدفع والاسترداد',
      'يتم الدفع عبر زين كاش أو كي كارد، ويُفعَّل الاشتراك بعد التحقق من الدفعة. يمكنك طلب استرجاع المبلغ خلال 7 أيام من التفعيل إذا لم تشاهد أكثر من 25% من محاضرات الدورة، وفق سياسة الاسترجاع.'),
  ('المدرّسون',
      'المدرّس مسؤول عن محتوى دوراته وصحته. تراجع الإدارة الدورات والمحاضرات والملفات قبل نشرها، وتحتفظ المنصة بنسبة 20% من السعر الكامل لكل اشتراك، والخصومات تُخصم من حصة المدرّس.'),
  ('الملكية الفكرية',
      'جميع المحاضرات والملفات ملك لأصحابها ولمنصة آرك، والاشتراك يمنحك حق المشاهدة الشخصية داخل التطبيق فقط.'),
  ('إيقاف الحساب',
      'يحق للمنصة إيقاف أي حساب يخالف هذه الشروط دون استرداد المبلغ.'),
  ('القانون',
      'تخضع هذه الشروط لقوانين جمهورية العراق.'),
  ('التعديلات',
      'قد نحدّث هذه الشروط، وسنُعلم المستخدمين بأي تغيير مهم.'),
];

const List<(String, String)> _faqItems = [
  ('ما هي منصة آرك؟',
      'منصة تعليمية هندسية تقدّم دورات مسجّلة يقدّمها مهندسون ومدرّسون مختصون.'),
  ('كيف أشترك في دورة؟',
      'افتح الدورة واضغط اشترك، ثم حوّل المبلغ عبر زين كاش أو كي كارد إلى الرقم الظاهر، واكتب رقم حسابك الذي دفعت منه وأرسل صورة إثبات التحويل. يُفعَّل اشتراكك بعد التحقق.'),
  ('متى يُفعَّل اشتراكي؟',
      'بعد مراجعة الدفعة، وسيصلك إشعار عند الموافقة أو الرفض.'),
  ('رُفض طلب الدفع، ماذا أفعل؟',
      'يظهر سبب الرفض في الإشعارات وفي صفحة الدورة. صحّح المشكلة وأرسل الطلب من جديد.'),
  ('هل يمكنني استخدام حسابي على أكثر من جهاز؟',
      'لا، الحساب يعمل على جهاز واحد فقط.'),
  ('هل يمكن استرداد المبلغ؟',
      'نعم، خلال 7 أيام من تفعيل الاشتراك إذا لم تشاهد أكثر من 25% من محاضرات الدورة. راسلنا من صفحة الدعم، والتفاصيل في سياسة الاسترجاع من الإعدادات ثم شروط الاستخدام.'),
  ('الفيديو لا يعمل أو يتقطع؟',
      'تأكد من اتصالك بالإنترنت، وجرّب جودة أقل من زر الجودة في المشغّل.'),
  ('لماذا لا أستطيع أخذ لقطة شاشة؟',
      'لحماية المحتوى، التصوير والتسجيل محظوران داخل التطبيق.'),
  ('كيف أتواصل مع الدعم؟',
      'من الإعدادات ثم الدعم.'),
];

/// Terms of use (also linked from the sign-up checkbox).
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return _InfoScaffold(
      title: t('terms_title'),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _termsSections.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i + 1}. ${_termsSections[i].$1}',
                          style: AppFonts.heading(size: 18)),
                      const SizedBox(height: 6),
                      Text(_termsSections[i].$2,
                          style: AppFonts.body(
                              size: 13.5, color: AppColors.muted)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _FullTextButton(t('btn_full_terms'), 'terms.html'),
        const SizedBox(height: 10),
        _FullTextButton(t('btn_refund_policy'), 'refund.html'),
      ],
    );
  }
}

/// Frequently asked questions, tap a question to open its answer.
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return _InfoScaffold(
      title: t('faq_title'),
      children: [
        for (final item in _faqItems) ...[
          GlassCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                iconColor: AppColors.red,
                collapsedIconColor: AppColors.muted2,
                title: Text(item.$1,
                    style: AppFonts.body(size: 14.5, weight: FontWeight.w700)),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.$2,
                      style: AppFonts.body(size: 13.5, color: AppColors.muted)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
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
