import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../i18n/strings.dart';
import '../models/lecture.dart';
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
  /// Sibling lectures in this course (in order), for the prev/next buttons
  /// and the episode list. Pass an empty list if this lecture is being
  /// watched outside a course context.
  final List<Lecture> playlist;
  /// Whether a given playlist entry is accessible (free, or the viewer has
  /// an active enrollment) — governs whether prev/next/episode-list entries
  /// are tappable.
  final bool Function(Lecture) isUnlocked;
  const VideoPlayerScreen({
    super.key,
    required this.lectureId,
    required this.title,
    this.playlist = const [],
    this.isUnlocked = _alwaysUnlocked,
  });

  static bool _alwaysUnlocked(Lecture _) => true;

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
  String? _hlsMasterUrl;
  String _currentQuality = 'auto';
  static const _qualities = ['auto', '480p', '720p', '1080p'];

  // Controls overlay: a tap shows/hides it (YouTube-style), it never toggles
  // playback directly — that's what was making a double-tap-to-skip also
  // pause/resume the video, since a single tap and the first half of a
  // double tap look identical to the gesture recognizer. Only the explicit
  // play/pause button changes playback state now.
  bool _controlsVisible = true;
  bool _showEpisodeList = false;
  Timer? _hideControlsTimer;

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
        _hlsMasterUrl = result.url!;
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
        _scheduleAutoHide();
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

  // Derived client-side from the master playlist URL rather than requested
  // from the server — the Worker authorizes by folder prefix, not by file,
  // so the same token already covers every rendition's playlist. Swapping
  // straight to a quality's own index.m3u8 (instead of master.m3u8, which
  // lets ExoPlayer's adaptive logic pick) is what makes a manual quality
  // pick actually stick rather than getting overridden by ABR.
  String _urlForQuality(String quality) {
    final master = _hlsMasterUrl!;
    if (quality == 'auto') return master;
    return master.replaceFirst('master.m3u8', '$quality/index.m3u8');
  }

  Future<void> _switchQuality(String quality) async {
    if (quality == _currentQuality || _hlsMasterUrl == null) return;
    final old = _hlsController;
    final position = old?.value.position ?? Duration.zero;
    final wasPlaying = old?.value.isPlaying ?? true;
    setState(() => _loading = true);
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(_urlForQuality(quality)));
      await controller.initialize().timeout(const Duration(seconds: 20));
      await controller.seekTo(position);
      if (wasPlaying) controller.play();
      if (!mounted) { controller.dispose(); return; }
      setState(() { _hlsController = controller; _currentQuality = quality; _loading = false; });
      await old?.dispose();
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

  // Controls fade out automatically while playing (matches YouTube), but
  // stay put while paused or while the episode list is open, so the viewer
  // always has something to tap to bring them back or act on.
  void _scheduleAutoHide() {
    _hideControlsTimer?.cancel();
    if (_hlsController?.value.isPlaying != true) return;
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _showEpisodeList) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControlsVisible() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (!_controlsVisible) _showEpisodeList = false;
    });
    if (_controlsVisible) _scheduleAutoHide();
  }

  void _togglePlayback() {
    final controller = _hlsController;
    if (controller == null) return;
    final ended = controller.value.duration > Duration.zero && controller.value.position >= controller.value.duration;
    if (ended) {
      controller.seekTo(Duration.zero);
      controller.play();
    } else if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    setState(() {}); // isPlaying flips synchronously on the controller's value
    _scheduleAutoHide();
  }

  int get _currentIndex => widget.playlist.indexWhere((l) => l.id == widget.lectureId);
  Lecture? get _prevLecture {
    final i = _currentIndex;
    return i > 0 ? widget.playlist[i - 1] : null;
  }
  Lecture? get _nextLecture {
    final i = _currentIndex;
    return (i >= 0 && i < widget.playlist.length - 1) ? widget.playlist[i + 1] : null;
  }

  void _playLecture(Lecture lecture) {
    if (!widget.isUnlocked(lecture)) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        lectureId: lecture.id,
        title: lecture.localizedTitle(AppStrings.instance.isAr),
        playlist: widget.playlist,
        isUnlocked: widget.isUnlocked,
      ),
    ));
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _hideControlsTimer?.cancel();
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
    if (_error != null) return Text(_error!, style: TextStyle(color: AppColors.muted), textAlign: TextAlign.center);

    final videoArea = AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hlsController != null) VideoPlayer(_hlsController!),
          if (_webController != null) WebViewWidget(controller: _webController!),
          if (_hlsController != null)
            _GestureLayer(
              controller: _hlsController!,
              onSingleTap: _toggleControlsVisible,
            ),
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
          if (_hlsController != null && _controlsVisible) ...[
            // Dim scrim so the center controls stay legible over bright video.
            IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Colors.transparent, Colors.transparent, Color(0x66000000)],
                    stops: [0, 0.3, 0.7, 1],
                  ),
                ),
              ),
            ),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SideButton(
                    icon: Icons.skip_previous_rounded,
                    enabled: _prevLecture != null && widget.isUnlocked(_prevLecture!),
                    onTap: _prevLecture == null ? null : () => _playLecture(_prevLecture!),
                  ),
                  const SizedBox(width: 28),
                  // Wrapped in its own ValueListenableBuilder — this icon
                  // must reflect live controller state, not just state set
                  // by tapping this same button. Without it, pressing the
                  // bottom bar's separate play/pause button changed actual
                  // playback but left this icon showing the stale, opposite
                  // state until something else happened to rebuild it.
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _hlsController!,
                    builder: (context, value, _) {
                      final ended = value.duration > Duration.zero && value.position >= value.duration;
                      return GestureDetector(
                        onTap: _togglePlayback,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.45)),
                          child: Icon(
                            ended ? Icons.replay : (value.isPlaying ? Icons.pause : Icons.play_arrow),
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 28),
                  _SideButton(
                    icon: Icons.skip_next_rounded,
                    enabled: _nextLecture != null && widget.isUnlocked(_nextLecture!),
                    onTap: _nextLecture == null ? null : () => _playLecture(_nextLecture!),
                  ),
                ],
              ),
            ),
            if (!_hlsController!.value.isPlaying && widget.playlist.isNotEmpty)
              Positioned(
                right: 8,
                top: 8,
                child: _EpisodeListButton(
                  open: _showEpisodeList,
                  onTap: () => setState(() => _showEpisodeList = !_showEpisodeList),
                ),
              ),
            if (_showEpisodeList)
              Positioned(
                right: 8,
                top: 48,
                child: _EpisodeList(
                  playlist: widget.playlist,
                  currentLectureId: widget.lectureId,
                  isUnlocked: widget.isUnlocked,
                  onSelect: _playLecture,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ControlBar(
                controller: _hlsController!,
                isFullscreen: _isFullscreen,
                onToggleFullscreen: _toggleFullscreen,
                currentQuality: _currentQuality,
                qualities: _qualities,
                onQualityChanged: _switchQuality,
                // Any bottom-bar interaction can change playback state (the
                // play/pause button most directly), and this parent widget
                // has other bits — the episode-list button's visibility,
                // notably — that read _hlsController.value directly rather
                // than through a listener, so they only ever see fresh state
                // when something forces this widget to rebuild. Cheap to
                // always do; wrong not to.
                onInteract: () { setState(() {}); _scheduleAutoHide(); },
              ),
            ),
          ],
        ],
      ),
    );

    return _isFullscreen ? SizedBox.expand(child: videoArea) : videoArea;
  }
}

/// Owns tap-to-show/hide-controls and double-tap-to-skip. Deliberately does
/// NOT touch playback on a single tap — that was the bug: a plain single
/// tap and the first half of a double tap are indistinguishable to Flutter's
/// gesture arena, so a single-tap-toggles-play handler would pause and then
/// immediately resume on every double-tap skip.
class _GestureLayer extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onSingleTap;
  const _GestureLayer({required this.controller, required this.onSingleTap});

  @override
  State<_GestureLayer> createState() => _GestureLayerState();
}

class _GestureLayerState extends State<_GestureLayer> {
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
            onTap: widget.onSingleTap,
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

class _SideButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  const _SideButton({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.25 : (enabled ? 1 : 0.4),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.35)),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}

class _EpisodeListButton extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _EpisodeListButton({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(open ? Icons.close : Icons.playlist_play, color: Colors.white, size: 18),
            const SizedBox(width: 4),
            Text(AppStrings.instance.t('episodes'), style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// Small "up next"-style list shown bottom-left while paused, mirroring the
/// mobile YouTube pattern the request asked to match.
class _EpisodeList extends StatelessWidget {
  final List<Lecture> playlist;
  final String currentLectureId;
  final bool Function(Lecture) isUnlocked;
  final void Function(Lecture) onSelect;
  const _EpisodeList({
    required this.playlist,
    required this.currentLectureId,
    required this.isUnlocked,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final ar = AppStrings.instance.isAr;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: playlist.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
          itemBuilder: (context, i) {
            final lecture = playlist[i];
            final isCurrent = lecture.id == currentLectureId;
            final unlocked = isUnlocked(lecture);
            return InkWell(
              onTap: unlocked ? () => onSelect(lecture) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      isCurrent ? Icons.play_arrow : (unlocked ? Icons.play_circle_outline : Icons.lock_outline),
                      color: isCurrent ? AppColors.red : Colors.white70,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lecture.localizedTitle(ar),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? AppColors.red : (unlocked ? Colors.white : Colors.white38),
                          fontSize: 12.5,
                          fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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
  final String currentQuality;
  final List<String> qualities;
  final ValueChanged<String> onQualityChanged;
  final VoidCallback onInteract;
  const _ControlBar({
    required this.controller,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.currentQuality,
    required this.qualities,
    required this.onQualityChanged,
    required this.onInteract,
  });

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
                // Generous vertical padding, not just visual spacing — the
                // package wraps this padding inside the same GestureDetector
                // that handles drag/tap, so it directly enlarges how much of
                // a touch target the bar has. Zero padding here previously
                // meant the draggable area matched the (very thin) visual
                // bar almost exactly, so touches routinely missed it and
                // landed on the tap-to-skip layer behind instead.
                padding: const EdgeInsets.symmetric(vertical: 14),
                colors: VideoProgressColors(
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
                      onInteract();
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
                    onSelected: (v) { onInteract(); controller.setPlaybackSpeed(v); },
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
                  PopupMenuButton<String>(
                    initialValue: currentQuality,
                    onSelected: (q) { onInteract(); onQualityChanged(q); },
                    color: const Color(0xFF1D1A16),
                    itemBuilder: (context) => qualities
                        .map((q) => PopupMenuItem<String>(
                              value: q,
                              child: Text(q == 'auto' ? 'Auto' : q, style: const TextStyle(color: Colors.white)),
                            ))
                        .toList(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      child: Text(
                        currentQuality == 'auto' ? 'Auto' : currentQuality,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white),
                    onPressed: () { onInteract(); onToggleFullscreen(); },
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
