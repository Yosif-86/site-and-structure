import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../i18n/strings.dart';
import '../theme.dart';
import 'arc_icons.dart';

/// Picker for one image or video: an inviting empty box until something is
/// chosen, then a preview of the picture (or the video's first frame) with
/// change / remove buttons -- never the raw file name.
class FilePickBox extends StatelessWidget {
  final XFile? file;
  final bool video;
  final String emptyLabel;

  /// Shown when nothing new is picked but something is already saved.
  final String? existingUrl;
  final VoidCallback onPick;
  final VoidCallback? onRemove;
  final double height;

  const FilePickBox({
    super.key,
    required this.file,
    required this.emptyLabel,
    required this.onPick,
    this.onRemove,
    this.video = false,
    this.existingUrl,
    this.height = 170,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final hasFile = file != null;
    final hasExisting = !hasFile && (existingUrl?.isNotEmpty ?? false);

    if (!hasFile && !hasExisting) {
      return InkWell(
        onTap: onPick,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: height * 0.62,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: AppColors.bg.withValues(alpha: 0.35),
            border: Border.all(color: AppColors.red.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.red.withValues(alpha: 0.14),
                ),
                child: Center(
                  child: ArcIconView(video ? ArcIcon.video : ArcIcon.image,
                      size: 24, color: AppColors.red, active: true),
                ),
              ),
              const SizedBox(height: 8),
              Text(emptyLabel,
                  style: AppFonts.body(size: 13.5, weight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    Widget media;
    if (hasFile && video) {
      media = _VideoFrame(path: file!.path);
    } else if (hasFile) {
      media = Image.file(File(file!.path), fit: BoxFit.cover);
    } else {
      media = Image.network(existingUrl!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => ColoredBox(color: AppColors.panel2));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: media),
            if (video)
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.4),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.8), width: 1.5),
                  ),
                  child: const Center(
                      child: ArcIconView(ArcIcon.play,
                          color: Colors.white, size: 22)),
                ),
              ),
            PositionedDirectional(
              bottom: 10,
              end: 10,
              child: Row(children: [
                _chip(t('btn_change'), ArcIcon.edit, onPick),
                if (onRemove != null && hasFile) ...[
                  const SizedBox(width: 8),
                  _chip(t('remove'), ArcIcon.trash, onRemove!),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, ArcIcon icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: StadiumBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.25))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ArcIconView(icon, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: AppFonts.body(
                    size: 12, weight: FontWeight.w600, color: Colors.white)),
          ]),
        ),
      ),
    );
  }
}

/// First frame of a local video, without playing it.
class _VideoFrame extends StatefulWidget {
  final String path;
  const _VideoFrame({required this.path});

  @override
  State<_VideoFrame> createState() => _VideoFrameState();
}

class _VideoFrameState extends State<_VideoFrame> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _VideoFrame old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _c?.dispose();
      _c = null;
      _init();
    }
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(File(widget.path));
    try {
      await c.initialize();
      await c.seekTo(const Duration(milliseconds: 300));
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (_) {
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return Center(
          child: ArcIconView(ArcIcon.video,
              size: 34, color: Colors.white.withValues(alpha: 0.5)));
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
