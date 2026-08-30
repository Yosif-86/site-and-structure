import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/strings.dart';
import '../services/api_service.dart';
import '../services/screen_security.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/watermark_overlay.dart';

/// Port of watchLecture()/moveWatermark() in course.html, plus the
/// screenshot/recording privacy layer discussed with Yosif:
///  - Android: FLAG_SECURE blocks screenshots/recording outright.
///  - iOS: can only detect a capture and react — pause + blank the player,
///    show a brief notice, resume once the capture ends.
class VideoPlayerScreen extends StatefulWidget {
  final String lectureId;
  final String title;
  const VideoPlayerScreen({super.key, required this.lectureId, required this.title});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _hlsController;
  WebViewController? _webController; // fallback for lectures still on Bunny
  bool _loading = true;
  String? _error;
  String _watermarkLabel = '';
  bool _captureNotice = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Android: block screenshots/recording outright for as long as this screen is open.
    await ScreenSecurity.enableSecure();
    // iOS: we can only detect a capture, not block it — react by blanking playback.
    ScreenSecurity.onCapture((_) => _onCaptureDetected());

    // Run in parallel — a slow/hanging watermark fetch must never block video
    // playback from starting. Each has its own timeout so nothing can hang
    // forever without surfacing an error.
    unawaited(_loadWatermarkLabel());
    await _loadVideo();
  }

  Future<void> _loadWatermarkLabel() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    try {
      final prof = await SupabaseService.instance.client
          .from('profiles')
          .select('phone')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      final phone = prof?['phone'] as String?;
      if (!mounted) return;
      setState(() => _watermarkLabel = (phone != null && phone.isNotEmpty) ? phone : (user.email ?? ''));
    } catch (_) {
      if (!mounted) return;
      setState(() => _watermarkLabel = user.email ?? '');
    }
  }

  Future<void> _loadVideo() async {
    final session = SupabaseService.instance.client.auth.currentSession;
    if (session == null) {
      setState(() { _loading = false; _error = AppStrings.instance.t('err_video_unavailable'); });
      return;
    }
    try {
      final result = await ApiService.getVideoUrl(widget.lectureId, session.accessToken)
          .timeout(const Duration(seconds: 15));
      if (result.error != null || result.url == null) {
        setState(() { _loading = false; _error = AppStrings.instance.t(result.error ?? 'err_video_unavailable'); });
        return;
      }

      if (result.type == 'hls') {
        final controller = VideoPlayerController.networkUrl(Uri.parse(result.url!));
        await controller.initialize().timeout(const Duration(seconds: 20));
        controller.play();
        if (!mounted) { controller.dispose(); return; }
        setState(() { _hlsController = controller; _loading = false; });
      } else {
        // Bunny iframe embed — needs a WebView, not the native player.
        final controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..loadRequest(Uri.parse(result.url!));
        setState(() { _webController = controller; _loading = false; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = '${AppStrings.instance.t('err_video_unavailable')}\n($e)'; });
    }
  }

  void _onCaptureDetected() {
    _hlsController?.pause();
    setState(() => _captureNotice = true);
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _captureNotice = false);
      _hlsController?.play();
    });
  }

  @override
  void dispose() {
    _hlsController?.dispose();
    ScreenSecurity.disableSecure();
    ScreenSecurity.onCapture(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.title, overflow: TextOverflow.ellipsis)),
        body: Center(child: _buildPlayer()),
      ),
    );
  }

  Widget _buildPlayer() {
    if (_loading) return const CircularProgressIndicator();
    if (_error != null) return Text(_error!, style: const TextStyle(color: AppColors.muted));

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hlsController != null) VideoPlayer(_hlsController!),
          if (_webController != null) WebViewWidget(controller: _webController!),
          if (_hlsController != null) _PlaybackControls(controller: _hlsController!),
          if (_watermarkLabel.isNotEmpty) WatermarkOverlay(label: _watermarkLabel),
          if (_captureNotice)
            Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: Text(
                AppStrings.instance.t('capture_detected'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          if (_hlsController != null)
            Positioned(
              bottom: 8,
              right: 8,
              left: 8,
              child: VideoProgressIndicator(_hlsController!, allowScrubbing: true),
            ),
        ],
      ),
    );
  }
}

/// Tap-to-toggle play/pause, plus a visible replay button once the video
/// reaches the end (video_player has no built-in controls of its own).
class _PlaybackControls extends StatelessWidget {
  final VideoPlayerController controller;
  const _PlaybackControls({required this.controller});

  bool _hasEnded(VideoPlayerValue value) =>
      value.isInitialized && value.duration > Duration.zero && value.position >= value.duration;

  void _handleTap() {
    final value = controller.value;
    if (_hasEnded(value)) {
      controller.seekTo(Duration.zero);
      controller.play();
    } else if (value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _handleTap,
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final ended = _hasEnded(value);
            final showIcon = ended || !value.isPlaying;
            if (!showIcon) return const SizedBox.shrink();
            return Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), shape: BoxShape.circle),
                child: Icon(
                  ended ? Icons.replay : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
