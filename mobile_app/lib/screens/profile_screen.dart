import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../i18n/strings.dart';
import '../services/deep_links.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_icon_button.dart';
import '../widgets/text_scramble.dart';
import 'admin_screen.dart';
import 'auth_screen.dart';
import 'teacher_screen.dart';

/// The user-facing profile: avatar, name, #public_id badge, bio, a row of
/// outbound social links, and (only for the accounts that have the flag) an
/// entry into the teacher or admin dashboard.
///
/// Identical for students and teachers — a teacher's only extra is the
/// dashboard card, which is exactly how the dashboards stay invisible to
/// everyone else now that the bottom-nav Profile icon no longer routes
/// straight into them.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _avatarBucket = 'avatars';

  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    AppTheme.instance.addListener(_onThemeChange);
  }

  @override
  void dispose() {
    AppTheme.instance.removeListener(_onThemeChange);
    super.dispose();
  }

  void _onThemeChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) {
      setState(() {
        _loading = false;
        _profile = null;
      });
      return;
    }
    try {
      final row = await SupabaseService.instance.client
          .from('profiles')
          .select(
              'full_name, phone, public_id, avatar_url, bio, teacher_photo_url, teacher_bio, teacher_specialty, instagram_username, telegram_username, is_admin, is_teacher')
          .eq('id', user.id)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _profile = row;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool get _isTeacher => _profile?['is_teacher'] == true;

  String? _str(String key) {
    final v = _profile?[key];
    if (v is! String) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  // A teacher already has teacher_bio/teacher_photo_url -- the bio and photo
  // shown to students on their course listings. Reusing those columns here
  // (instead of the generic bio/avatar_url every other account gets) is what
  // keeps a teacher from having two separate, unsynced bios/photos to fill
  // in across this screen and the teacher dashboard's own profile tab.
  String? get _effectiveBio => _isTeacher ? _str('teacher_bio') : _str('bio');
  String? get _effectivePhotoUrl =>
      _isTeacher ? _str('teacher_photo_url') : _str('avatar_url');

  // ---- Avatar upload ----

  Future<void> _changeAvatar() async {
    final t = AppStrings.instance.t;
    final user = SupabaseService.instance.currentUser;
    if (user == null || _uploading) return;

    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      final sb = SupabaseService.instance.client;
      // Same owner-folder convention as the payment-qr bucket: the object is
      // written under a folder named after the caller's auth.uid(), which is
      // what the bucket's storage policy checks.
      final path =
          '${user.id}/avatar-${DateTime.now().millisecondsSinceEpoch}-${picked.name}';
      await sb.storage.from(_avatarBucket).upload(path, File(picked.path));
      final url = sb.storage.from(_avatarBucket).getPublicUrl(path);
      await sb
          .from('profiles')
          .update({_isTeacher ? 'teacher_photo_url' : 'avatar_url': url}).eq(
              'id', user.id);
      await _load();
      _toast(t('profile_saved'));
    } catch (e) {
      _toast('${t('err_avatar_upload_failed')}$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---- Edit sheet ----

  Future<void> _openEditSheet() async {
    final t = AppStrings.instance.t;
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;

    final nameCtrl = TextEditingController(text: _str('full_name') ?? '');
    final bioCtrl = TextEditingController(text: _effectiveBio ?? '');
    final specialtyCtrl =
        TextEditingController(text: _str('teacher_specialty') ?? '');
    final igCtrl =
        TextEditingController(text: _str('instagram_username') ?? '');
    final tgCtrl = TextEditingController(text: _str('telegram_username') ?? '');
    final bioColumn = _isTeacher ? 'teacher_bio' : 'bio';

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EditProfileSheet(
        nameCtrl: nameCtrl,
        bioCtrl: bioCtrl,
        specialtyCtrl: _isTeacher ? specialtyCtrl : null,
        igCtrl: igCtrl,
        tgCtrl: tgCtrl,
        phone: _str('phone'),
        onSave: () async {
          await SupabaseService.instance.client.from('profiles').update({
            'full_name': nameCtrl.text.trim(),
            bioColumn: bioCtrl.text.trim().isEmpty ? null : bioCtrl.text.trim(),
            if (_isTeacher)
              'teacher_specialty': specialtyCtrl.text.trim().isEmpty
                  ? null
                  : specialtyCtrl.text.trim(),
            'instagram_username': igCtrl.text.trim().isEmpty
                ? null
                : DeepLinks.handle(igCtrl.text),
            'telegram_username': tgCtrl.text.trim().isEmpty
                ? null
                : DeepLinks.handle(tgCtrl.text),
          }).eq('id', user.id);
        },
      ),
    );

    nameCtrl.dispose();
    bioCtrl.dispose();
    specialtyCtrl.dispose();
    igCtrl.dispose();
    tgCtrl.dispose();

    if (saved == true) {
      await _load();
      _toast(t('profile_saved'));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openLink(Future<bool> Function() launch) async {
    final ok = await launch();
    if (!ok) _toast(AppStrings.instance.t('err_link_failed'));
  }

  // Embedded as the 4th page of the catalogue PageView (alongside Home/My
  // Courses/Settings) instead of pushed as its own route -- so it shares the
  // same persistent bottom nav rather than opening what looked like a
  // separate screen. No Scaffold/AppBar of its own; the edit action lives
  // inline in the header card instead of an AppBar action.
  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: AmbientBackground(child: SafeArea(child: _buildBody(t))),
    );
  }

  Widget _buildBody(String Function(String) t) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (SupabaseService.instance.currentUser == null) {
      return _CenteredPrompt(
        message: t('profile_sign_in_prompt'),
        actionLabel: t('log_in'),
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AuthScreen()),
        ),
      );
    }

    if (_profile == null) {
      return _CenteredPrompt(
        message: _error ?? t('err_save_failed'),
        actionLabel: t('retry'),
        onAction: _load,
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          FadeSlideIn(delayMs: 0, child: _buildHeaderCard(t)),
          const SizedBox(height: 14),
          FadeSlideIn(delayMs: 90, child: _buildSocialRow(t)),
          if (_profile?['is_teacher'] == true) ...[
            const SizedBox(height: 14),
            FadeSlideIn(
              delayMs: 180,
              child: _DashboardTile(
                icon: Icons.workspace_premium_outlined,
                accent: AppColors.teal,
                title: t('teacher_dashboard'),
                subtitle: t('teacher_dashboard_sub'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TeacherScreen()),
                ),
              ),
            ),
          ],
          if (_profile?['is_admin'] == true) ...[
            const SizedBox(height: 14),
            FadeSlideIn(
              delayMs: 240,
              child: _DashboardTile(
                icon: Icons.shield_outlined,
                accent: AppColors.red,
                title: t('nav_admin'),
                subtitle: t('admin_dashboard_sub'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminScreen()),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderCard(String Function(String) t) {
    final name = _str('full_name') ?? t('profile_no_name');
    final publicId = _str('public_id');
    final specialty = _isTeacher ? _str('teacher_specialty') : null;
    final bio = _effectiveBio;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          PositionedDirectional(
            top: 8,
            end: 8,
            child: GlassIconButton(
              tooltip: t('edit_profile'),
              icon: Icons.edit_outlined,
              onTap: _openEditSheet,
            ),
          ),
          Column(
            children: [
              _AvatarButton(
                url: _effectivePhotoUrl,
                busy: _uploading,
                onTap: _changeAvatar,
              ),
              const SizedBox(height: 14),
              TextScramble(
                name,
                style: AppFonts.body(size: 22, weight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              if (specialty != null) ...[
                const SizedBox(height: 4),
                TextScramble(specialty,
                    textAlign: TextAlign.center,
                    style: AppFonts.body(size: 13.5, color: AppColors.muted)),
              ],
              if (publicId != null) ...[
                const SizedBox(height: 10),
                // public_id is generated by a DB trigger and never writable
                // from the client — shown here purely as an identifier users
                // can quote to support.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.panel2,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('#$publicId',
                      style: AppFonts.code(size: 12, color: AppColors.muted)),
                ),
              ],
              const SizedBox(height: 14),
              GestureDetector(
                onTap: bio == null ? _openEditSheet : null,
                child: TextScramble(
                  bio ?? t('profile_add_bio'),
                  textAlign: TextAlign.center,
                  style: AppFonts.body(
                    size: 13.5,
                    color: bio == null ? AppColors.muted2 : AppColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSocialRow(String Function(String) t) {
    final instagram = _str('instagram_username');
    final telegram = _str('telegram_username');
    final phone = _str('phone');

    final links = <Widget>[
      if (instagram != null)
        _SocialButton(
          icon: Icons.camera_alt_outlined,
          label: t('label_instagram'),
          accent: AppColors.byline,
          onTap: () => _openLink(() => DeepLinks.instagram(instagram)),
        ),
      if (telegram != null)
        _SocialButton(
          icon: Icons.send_outlined,
          label: t('label_telegram'),
          accent: AppColors.teal,
          onTap: () => _openLink(() => DeepLinks.telegram(telegram)),
        ),
      if (phone != null)
        _SocialButton(
          icon: Icons.chat_outlined,
          label: t('label_whatsapp'),
          accent: AppColors.teal,
          onTap: () => _openLink(() => DeepLinks.whatsapp(phone)),
        ),
      if (phone != null)
        _SocialButton(
          icon: Icons.call_outlined,
          label: t('label_call'),
          accent: AppColors.red,
          onTap: () => _openLink(() => DeepLinks.phoneCall(phone)),
        ),
    ];

    // Nothing filled in yet — render nothing rather than an empty glass strip.
    if (links.isEmpty) return const SizedBox.shrink();

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: links,
      ),
    );
  }
}

// ---- Pieces ----

/// Circular avatar with a press-scale animation and a Hero so the image
/// carries across if it is ever shown from another route.
class _AvatarButton extends StatefulWidget {
  final String? url;
  final bool busy;
  final VoidCallback onTap;

  const _AvatarButton(
      {required this.url, required this.busy, required this.onTap});

  @override
  State<_AvatarButton> createState() => _AvatarButtonState();
}

class _AvatarButtonState extends State<_AvatarButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    const size = 108.0;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Hero(
          tag: 'profile-avatar',
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.panel2,
              border: Border.all(color: AppColors.glassBorder, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
              image: widget.url == null
                  ? null
                  : DecorationImage(
                      image: NetworkImage(widget.url!), fit: BoxFit.cover),
            ),
            child: widget.busy
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : widget.url == null
                    ? Icon(Icons.add_a_photo_outlined,
                        color: AppColors.muted2, size: 30)
                    : null,
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  const _SocialButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.panel2,
                border: Border.all(color: AppColors.line),
              ),
              child: Icon(icon, color: AppColors.text, size: 20),
            ),
            const SizedBox(height: 7),
            Text(label,
                style: AppFonts.body(size: 11.5, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}

class _DashboardTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _DashboardTile({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
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
              color: accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AppFonts.body(size: 16, weight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: AppFonts.body(size: 12, color: AppColors.muted)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.muted2),
        ],
      ),
    );
  }
}

class _CenteredPrompt extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _CenteredPrompt({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                style: AppFonts.body(color: AppColors.muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet holding the editable subset of the profile. `phone` is shown
/// read-only: it is captured at signup and isn't editable anywhere else in
/// this app, so exposing a writable field here would be the only path to
/// change it and would need its own verification story.
class _EditProfileSheet extends StatefulWidget {
  final TextEditingController nameCtrl;
  final TextEditingController bioCtrl;
  final TextEditingController? specialtyCtrl;
  final TextEditingController igCtrl;
  final TextEditingController tgCtrl;
  final String? phone;
  final Future<void> Function() onSave;

  const _EditProfileSheet({
    required this.nameCtrl,
    required this.bioCtrl,
    this.specialtyCtrl,
    required this.igCtrl,
    required this.tgCtrl,
    required this.phone,
    required this.onSave,
  });

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '${AppStrings.instance.t('err_save_failed')}$e';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    return Directionality(
      textDirection:
          AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border.all(color: AppColors.glassBorder),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.muted2,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Text(t('edit_profile'), style: AppFonts.heading(size: 22)),
                const SizedBox(height: 16),
                TextField(
                  controller: widget.nameCtrl,
                  decoration: InputDecoration(labelText: t('label_full_name')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: widget.bioCtrl,
                  maxLines: 3,
                  maxLength: 200,
                  decoration: InputDecoration(labelText: t('label_bio')),
                ),
                if (widget.specialtyCtrl != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: widget.specialtyCtrl,
                    decoration:
                        InputDecoration(labelText: t('label_specialty')),
                  ),
                ],
                const SizedBox(height: 4),
                TextField(
                  controller: widget.igCtrl,
                  decoration: InputDecoration(
                    labelText: t('label_instagram'),
                    hintText: t('ph_social_handle'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: widget.tgCtrl,
                  decoration: InputDecoration(
                    labelText: t('label_telegram'),
                    hintText: t('ph_social_handle'),
                  ),
                ),
                if (widget.phone != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    enabled: false,
                    controller: TextEditingController(text: widget.phone),
                    decoration: InputDecoration(labelText: t('label_phone')),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t('profile_phone_readonly'),
                    style: AppFonts.body(size: 11, color: AppColors.muted2),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: AppFonts.body(size: 12, color: AppColors.red)),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: Text(t('discard')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text(t('save')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
