import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _isFullscreen = false;
  Timer? _progressTimer;

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
          .select('full_name, phone')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      final name = prof?['full_name'] as String?;
      final phone = prof?['phone'] as String?;
      final parts = [
        if (name != null && name.isNotEmpty) name,
        if (phone != null && phone.isNotEmpty) phone,
      ];
      if (!mounted) return;
      setState(() => _watermarkLabel = parts.isNotEmpty ? parts.join(' · ') : (user.email ?? ''));
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
        final resumeAt = await _loadResumePosition();
        if (resumeAt != null && resumeAt < controller.value.duration - const Duration(seconds: 5)) {
          await controller.seekTo(resumeAt);
        }
        controller.play();
        if (!mounted) { controller.dispose(); return; }
        setState(() { _hlsController = controller; _loading = false; });
        _startProgressSaving();
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

  Future<Duration?> _loadResumePosition() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return null;
    try {
      final row = await SupabaseService.instance.client
          .from('lesson_progress')
          .select('position_seconds, completed')
          .eq('user_id', user.id)
          .eq('lecture_id', widget.lectureId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (row == null || row['completed'] == true) return null;
      final seconds = row['position_seconds'] as int?;
      if (seconds == null || seconds <= 0) return null;
      return Duration(seconds: seconds);
    } catch (_) {
      return null;
    }
  }

  void _startProgressSaving() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) => _saveProgress());
  }

  Future<void> _saveProgress() async {
    final controller = _hlsController;
    final user = SupabaseService.instance.currentUser;
    if (controller == null || user == null || !controller.value.isInitialized) return;
    final position = controller.value.position;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final completed = position >= duration - const Duration(seconds: 15);
    try {
      await SupabaseService.instance.client.from('lesson_progress').upsert({
        'user_id': user.id,
        'lecture_id': widget.lectureId,
        'position_seconds': position.inSeconds,
        'duration_seconds': duration.inSeconds,
        'completed': completed,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,lecture_id');
    } catch (_) {
      // Best-effort — resume position is a convenience, not critical data.
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

  Future<void> _toggleFullscreen() async {
    setState(() => _isFullscreen = !_isFullscreen);
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await _restoreSystemUi();
    }
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    unawaited(_saveProgress());
    _hlsController?.dispose();
    ScreenSecurity.disableSecure();
    ScreenSecurity.onCapture(null);
    if (_isFullscreen) _restoreSystemUi();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: AppStrings.instance.isAr ? TextDirection.rtl : TextDirection.ltr,
      child: PopScope(
        canPop: !_isFullscreen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _isFullscreen) _toggleFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: _isFullscreen
              ? null
              : AppBar(backgroundColor: Colors.black, title: Text(widget.title, overflow: TextOverflow.ellipsis)),
          body: Center(child: _buildPlayer()),
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    if (_loading) return const CircularProgressIndicator();
    if (_error != null) return Text(_error!, style: const TextStyle(color: AppColors.muted), textAlign: TextAlign.center);

    final videoArea = AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hlsController != null) VideoPlayer(_hlsController!),
          if (_webController != null) WebViewWidget(controller: _webController!),
          if (_hlsController != null) _TapToToggle(controller: _hlsController!),
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
              left: 0,
              right: 0,
              bottom: 0,
              child: _ControlBar(
                controller: _hlsController!,
                isFullscreen: _isFullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
            ),
        ],
      ),
    );

    return _isFullscreen ? SizedBox.expand(child: videoArea) : videoArea;
  }
}

/// Single tap toggles play/pause. Double-tap the right half to skip forward
/// 10s, left half to skip back 10s — standard video-app convention.
class _TapToToggle extends StatefulWidget {
  final VideoPlayerController controller;
  const _TapToToggle({required this.controller});

  @override
  State<_TapToToggle> createState() => _TapToToggleState();
}

class _TapToToggleState extends State<_TapToToggle> {
  Offset? _lastTapPosition;
  bool _showSeekHint = false;
  bool _seekForward = true;

  void _seek(bool forward) {
    final controller = widget.controller;
    final current = controller.value.position;
    final duration = controller.value.duration;
    var target = forward ? current + const Duration(seconds: 10) : current - const Duration(seconds: 10);
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    controller.seekTo(target);
    setState(() { _showSeekHint = true; _seekForward = forward; });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _showSeekHint = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (widget.controller.value.isPlaying) {
                widget.controller.pause();
              } else {
                widget.controller.play();
              }
            },
            onDoubleTapDown: (details) => _lastTapPosition = details.localPosition,
            onDoubleTap: () {
              if (_lastTapPosition == null) return;
              _seek(_lastTapPosition!.dx > constraints.maxWidth / 2);
            },
            child: _showSeekHint
                ? Align(
                    alignment: _seekForward ? Alignment.centerRight : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Icon(
                        _seekForward ? Icons.forward_10 : Icons.replay_10,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(1, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Bottom playback bar: play/pause, current/duration time, scrub bar,
/// fullscreen toggle — the controls video_player doesn't provide on its own.
class _ControlBar extends StatelessWidget {
  final VideoPlayerController controller;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  const _ControlBar({required this.controller, required this.isFullscreen, required this.onToggleFullscreen});

  bool _hasEnded(VideoPlayerValue value) =>
      value.isInitialized && value.duration > Duration.zero && value.position >= value.duration;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xCC000000)],
        ),
      ),
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final ended = _hasEnded(value);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: EdgeInsets.zero,
                colors: const VideoProgressColors(
                  playedColor: AppColors.red,
                  bufferedColor: Color(0x66FFFFFF),
                  backgroundColor: Color(0x33FFFFFF),
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(ended ? Icons.replay : (value.isPlaying ? Icons.pause : Icons.play_arrow), color: Colors.white),
                    onPressed: () {
                      if (ended) {
                        controller.seekTo(Duration.zero);
                        controller.play();
                      } else if (value.isPlaying) {
                        controller.pause();
                      } else {
                        controller.play();
                      }
                    },
                  ),
                  Text(
                    '${_formatDuration(value.position)} / ${_formatDuration(value.duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  PopupMenuButton<double>(
                    initialValue: value.playbackSpeed,
                    onSelected: controller.setPlaybackSpeed,
                    color: const Color(0xFF1D1A16),
                    itemBuilder: (context) => const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                        .map((speed) => PopupMenuItem<double>(
                              value: speed,
                              child: Text('${speed}x', style: const TextStyle(color: Colors.white)),
                            ))
                        .toList(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      child: Text(
                        '${value.playbackSpeed}x',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                    onPressed: onToggleFullscreen,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
