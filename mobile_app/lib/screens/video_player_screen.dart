import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../i18n/strings.dart';
import '../models/lecture.dart';
import '../services/api_service.dart';
import '../services/error_reporter.dart';
import '../services/net_status.dart';
import '../services/screen_security.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/arc_icons.dart';
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

  /// Admin previewing an uploaded lecture before approving it.
  final bool preview;
  const VideoPlayerScreen({
    super.key,
    required this.lectureId,
    required this.title,
    this.playlist = const [],
    this.isUnlocked = _alwaysUnlocked,
    this.preview = false,
  });

  static bool _alwaysUnlocked(Lecture _) => true;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _hlsController;
  bool _loading = true;
  String? _error;
  String _watermarkLabel = '';
  bool _captureNotice = false;
  bool _isFullscreen = false;
  // Fullscreen chosen with the button (locked to landscape) rather than by
  // turning the device. Leaving it with the button locks portrait so the
  // screen doesn't flip straight back.
  bool _manualFullscreen = false;
  Timer? _progressTimer;
  bool _autoplayTriggered = false;
  String? _hlsMasterUrl;
  // Lectures uploaded from the teacher app are one 1080p MP4 (no renditions).
  bool _isMp4 = false;
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
    WidgetsBinding.instance.addObserver(this);
    // Let the player follow the device: turning it sideways goes fullscreen
    // (respects the phone's own rotation lock).
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    ScreenSecurity.currentScreen = widget.title;
    // Already held sideways when the lecture opens.
    WidgetsBinding.instance.addPostFrameCallback((_) => didChangeMetrics());
    _init();
  }

  bool get _deviceLandscape {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final size = views.first.physicalSize;
    return size.width > size.height;
  }

  @override
  void didChangeMetrics() {
    if (!mounted || _manualFullscreen) return;
    final landscape = _deviceLandscape;
    if (landscape && !_isFullscreen) {
      setState(() => _isFullscreen = true);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (!landscape && _isFullscreen) {
      setState(() => _isFullscreen = false);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
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
      var result = await ApiService.getVideoUrl(widget.lectureId, session.accessToken,
              preview: widget.preview)
          .timeout(const Duration(seconds: 15));
      // An access token that expired while this screen was sitting idle (or
      // was minted just before a session refresh elsewhere in the app)
      // shows up here as a 401 "Invalid session" -- mirrors the retry
      // course.html already does on the website rather than dead-ending on
      // a raw, untranslated server error string.
      if (result.statusCode == 401) {
        final refreshed = await SupabaseService.instance.client.auth.refreshSession();
        final newSession = refreshed.session;
        if (newSession != null) {
          result = await ApiService.getVideoUrl(widget.lectureId, newSession.accessToken,
                  preview: widget.preview)
              .timeout(const Duration(seconds: 15));
        }
      }
      if (result.error != null || result.url == null) {
        if (!mounted) return;
        // Keep the server's reason when it's one we can explain (other
        // device, signed in elsewhere, not enrolled yet).
        final reason = switch (result.error) {
          'err_untrusted_device' => 'err_untrusted_device',
          'err_session_kicked' => 'err_session_kicked',
          'Not enrolled or access not yet approved' => 'err_video_not_enrolled',
          'Too many requests, try again shortly.' =>
            'Too many requests, try again shortly.',
          _ => 'err_video_unavailable',
        };
        setState(() { _loading = false; _error = AppStrings.instance.t(reason); });
        return;
      }

      _hlsMasterUrl = result.url!;
      _isMp4 = result.type == 'mp4';
      final controller = VideoPlayerController.networkUrl(Uri.parse(result.url!));
      await controller.initialize().timeout(const Duration(seconds: 20));
      final resumeAt = await _loadResumePosition();
      if (resumeAt != null && resumeAt < controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(resumeAt);
      }
      controller.play();
      if (!mounted) { controller.dispose(); return; }
      controller.addListener(_checkAutoplayNext);
      setState(() { _hlsController = controller; _loading = false; });
      _startProgressSaving();
      _scheduleAutoHide();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = NetStatus.isOffline(e)
            ? AppStrings.instance.t('err_offline')
            : AppStrings.instance.t('err_video_unavailable');
      });
      if (!NetStatus.isOffline(e)) ErrorReporter.report(e, null, page: 'video');
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
    if (widget.preview) return;
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
        // .toUtc() matters: DateTime.now() is local time, and
        // toIso8601String() on a local DateTime carries no offset marker, so
        // Postgres read it as UTC outright -- every save landed 3 hours
        // ahead of real UTC (Baghdad is UTC+3).
        'updated_at': DateTime.now().toUtc().toIso8601String(),
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
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(Uri.parse(_urlForQuality(quality)));
      await controller.initialize().timeout(const Duration(seconds: 20));
      await controller.seekTo(position);
      if (wasPlaying) controller.play();
      if (!mounted) { controller.dispose(); return; }
      old?.removeListener(_checkAutoplayNext);
      controller.addListener(_checkAutoplayNext);
      setState(() { _hlsController = controller; _currentQuality = quality; _loading = false; });
      await old?.dispose();
    } catch (e) {
      // That quality isn't available: keep playing the current one.
      controller?.dispose();
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppStrings.instance.t('err_quality_unavailable'))));
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
    final enter = !_isFullscreen;
    setState(() {
      _isFullscreen = enter;
      _manualFullscreen = enter;
    });
    if (enter) {
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

  void _seekBy(Duration delta) {
    final controller = _hlsController;
    if (controller == null) return;
    final duration = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    controller.seekTo(target);
    setState(() {});
    _scheduleAutoHide();
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

  // Fires on every controller tick, not just at the very end, so it must
  // stay cheap and self-guarding — _autoplayTriggered stops it firing
  // repeatedly once the end condition is reached (position doesn't strictly
  // stop advancing at duration, and this listener keeps getting called).
  void _checkAutoplayNext() {
    if (_autoplayTriggered) return;
    final controller = _hlsController;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized || value.isBuffering) return;
    final ended = value.duration > Duration.zero && value.position >= value.duration - const Duration(milliseconds: 400);
    if (!ended) return;
    final next = _nextLecture;
    if (next == null || !widget.isUnlocked(next)) return;
    _autoplayTriggered = true;
    unawaited(_saveProgress());
    _playLecture(next);
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
    _hlsController?.removeListener(_checkAutoplayNext);
    _hlsController?.dispose();
    ScreenSecurity.disableSecure();
    ScreenSecurity.onCapture(null);
    WidgetsBinding.instance.removeObserver(this);
    ScreenSecurity.currentScreen = null;
    _restoreSystemUi();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      // Player controls (prev/next order, fullscreen icon, scrub bar) are a
      // universal convention, not translated UI — keep them LTR regardless
      // of app language instead of mirroring like Arabic text does.
      textDirection: TextDirection.ltr,
      child: PopScope(
        // Always intercepted (never true canPop) so the pending progress
        // save can be awaited first — the course page behind this route
        // reloads the instant Navigator.pop() returns, and dispose() can
        // only fire an unawaited save, which routinely lost the race and
        // left the progress bar/checkmark showing stale data until the
        // course page was left and reopened.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (_isFullscreen) { _toggleFullscreen(); return; }
          await _saveProgress();
          if (mounted) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: _isFullscreen ? Colors.black : const Color(0xFF14120F),
          body: _isFullscreen ? Center(child: _buildPlayer()) : _buildPortrait(),
        ),
      ),
    );
  }

  /// Portrait layout: the blueprint sheet, a glass header with the lesson
  /// number and title, the framed video, and the course's lessons below.
  Widget _buildPortrait() {
    final ar = AppStrings.instance.isAr;
    final t = AppStrings.instance.t;
    final idx = widget.playlist.indexWhere((l) => l.id == widget.lectureId);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Stack(
        children: [
          const Positioned.fill(
              child: BlueprintBackdrop(dark: true, focus: Alignment(0, -0.6))),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  children: [
                    Directionality(
                      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                        child: Row(
                          children: [
                            _GlassCircleButton(
                              icon: ArcIcon.back,
                              size: 42,
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (idx >= 0)
                                    Text(
                                      t('lesson_of')
                                          .replaceAll('{n}', '${idx + 1}')
                                          .replaceAll('{total}', '${widget.playlist.length}'),
                                      style: AppFonts.eyebrow(color: const Color(0xFFF2B544)),
                                    ),
                                  Text(widget.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppFonts.body(
                                          size: 16,
                                          weight: FontWeight.w700,
                                          color: const Color(0xFFFEE4BF))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                          boxShadow: [
                            BoxShadow(
                                color: const Color(0xFFE8622C).withValues(alpha: 0.16),
                                blurRadius: 36,
                                offset: const Offset(0, 10)),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: _buildPlayer(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (widget.playlist.isNotEmpty)
                      Expanded(
                        child: Directionality(
                          textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
                          child: _LessonPanel(
                            playlist: widget.playlist,
                            currentLectureId: widget.lectureId,
                            isUnlocked: widget.isUnlocked,
                            onSelect: _playLecture,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    if (_loading || _error != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: _loading
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!,
                        style: TextStyle(color: AppColors.muted),
                        textAlign: TextAlign.center),
                  ),
          ),
        ),
      );
    }

    final videoArea = AspectRatio(
      aspectRatio: _hlsController?.value.aspectRatio ?? 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hlsController != null) VideoPlayer(_hlsController!),
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
                    icon: ArcIcon.skipPrev,
                    enabled: _prevLecture != null && widget.isUnlocked(_prevLecture!),
                    onTap: _prevLecture == null ? null : () => _playLecture(_prevLecture!),
                  ),
                  const SizedBox(width: 18),
                  _SideButton(
                    icon: ArcIcon.rewind,
                    enabled: true,
                    onTap: () => _seekBy(const Duration(seconds: -10)),
                  ),
                  const SizedBox(width: 18),
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
                          width: 66,
                          height: 66,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFF2B544), Color(0xFFE8622C), Color(0xFFB8461A)],
                            ),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1.2),
                            boxShadow: [
                              BoxShadow(color: const Color(0xFFE8622C).withValues(alpha: 0.5), blurRadius: 22),
                            ],
                          ),
                          child: Center(
                            child: ArcIconView(
                              ended ? ArcIcon.replay : (value.isPlaying ? ArcIcon.pause : ArcIcon.play),
                              color: Colors.white,
                              size: 30,
                              stroke: 2.2,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 18),
                  _SideButton(
                    icon: ArcIcon.forward,
                    enabled: true,
                    onTap: () => _seekBy(const Duration(seconds: 10)),
                  ),
                  const SizedBox(width: 18),
                  _SideButton(
                    icon: ArcIcon.skipNext,
                    enabled: _nextLecture != null && widget.isUnlocked(_nextLecture!),
                    onTap: _nextLecture == null ? null : () => _playLecture(_nextLecture!),
                  ),
                ],
              ),
            ),
            // Portrait lists the lessons under the video; the overlay list
            // is only needed when the video fills the screen.
            if (_isFullscreen && !_hlsController!.value.isPlaying && widget.playlist.isNotEmpty)
              Positioned(
                right: 8,
                top: 8,
                child: _EpisodeListButton(
                  open: _showEpisodeList,
                  onTap: () => setState(() => _showEpisodeList = !_showEpisodeList),
                ),
              ),
            if (_showEpisodeList && _isFullscreen)
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
                qualities: _isMp4 ? const [] : _qualities,
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

    // Center (not SizedBox.expand) so AspectRatio keeps room to size itself
    // within the available space instead of being forced to fill it and
    // stretch — SizedBox.expand imposes tight constraints that AspectRatio
    // can't reconcile with the video's real ratio.
    return Center(child: videoArea);
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
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.4),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                        ),
                        child: Center(
                          child: ArcIconView(
                            _seekForward ? ArcIcon.forward : ArcIcon.rewind,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
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
  final ArcIcon icon;
  final bool enabled;
  final VoidCallback? onTap;
  const _SideButton({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.25 : (enabled ? 1 : 0.4),
        child: _GlassCircleButton(icon: icon, size: 46, onTap: null),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ArcIconView(open ? ArcIcon.close : ArcIcon.playlist, color: Colors.white, size: 17),
                const SizedBox(width: 4),
                Text(AppStrings.instance.t('episodes'), style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
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
                    ArcIconView(
                      isCurrent ? ArcIcon.play : (unlocked ? ArcIcon.lessons : ArcIcon.lock),
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
                    icon: ArcIconView(ended ? ArcIcon.replay : (value.isPlaying ? ArcIcon.pause : ArcIcon.play), color: Colors.white, size: 22),
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
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
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
                    child: _Pill('${value.playbackSpeed}x'),
                  ),
                  if (qualities.isNotEmpty)
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
                    child: _Pill(currentQuality == 'auto' ? 'Auto' : currentQuality),
                  ),
                  IconButton(
                    icon: ArcIconView(isFullscreen ? ArcIcon.fullscreenExit : ArcIcon.fullscreen, color: Colors.white, size: 22),
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

/// Frosted round button used for the player's side controls and the back
/// button above the video.
class _GlassCircleButton extends StatelessWidget {
  final ArcIcon icon;
  final double size;
  final VoidCallback? onTap;
  const _GlassCircleButton({required this.icon, this.size = 44, this.onTap});

  @override
  Widget build(BuildContext context) {
    final button = ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.32),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: Center(
              child: ArcIconView(icon, color: Colors.white, size: size * 0.5)),
        ),
      ),
    );
    return onTap == null
        ? button
        : GestureDetector(onTap: onTap, child: button);
  }
}

/// Small glass label for the speed / quality menus.
class _Pill extends StatelessWidget {
  final String label;
  const _Pill(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
    );
  }
}

/// The course's lessons under the video (portrait): numbered rows, the
/// current one highlighted, locked ones dimmed.
class _LessonPanel extends StatelessWidget {
  final List<Lecture> playlist;
  final String currentLectureId;
  final bool Function(Lecture) isUnlocked;
  final void Function(Lecture) onSelect;
  const _LessonPanel({
    required this.playlist,
    required this.currentLectureId,
    required this.isUnlocked,
    required this.onSelect,
  });

  static const _cream = Color(0xFFFEE4BF);
  static const _orange = Color(0xFFE8622C);
  static const _soft = Color(0xFFAFA492);

  String? _dur(int? s) {
    if (s == null || s <= 0) return null;
    final m = s ~/ 60, r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppStrings.instance.t;
    final ar = AppStrings.instance.isAr;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0x80262218),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0x29F3EDE4)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(children: [
                    Container(
                      width: 4,
                      height: 16,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFFF2B544), _orange],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(t('course_lessons'),
                        style: AppFonts.body(
                            size: 15, weight: FontWeight.w700, color: _cream)),
                    const Spacer(),
                    Text('${playlist.length}',
                        style: AppFonts.code(size: 12, color: _soft)),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    itemCount: playlist.length,
                    itemBuilder: (context, i) => _row(context, i, t, ar),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, String Function(String) t, bool ar) {
    final l = playlist[i];
    final current = l.id == currentLectureId;
    final unlocked = isUnlocked(l);
    final dur = _dur(l.durationSeconds);
    final sub = current ? t('now_playing') : dur;
    return Opacity(
      opacity: unlocked ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: unlocked && !current ? () => onSelect(l) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: current ? _orange.withValues(alpha: 0.16) : Colors.transparent,
            border: Border.all(
                color: current ? _orange.withValues(alpha: 0.4) : Colors.transparent),
          ),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: current ? _orange : Colors.white.withValues(alpha: 0.06),
              ),
              child: current
                  ? const ArcIconView(ArcIcon.play, color: Colors.white, size: 16)
                  : Text((i + 1).toString().padLeft(2, '0'),
                      style: AppFonts.code(size: 12.5, color: _soft)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.localizedTitle(ar),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                          size: 13.5,
                          weight: current ? FontWeight.w700 : FontWeight.w500,
                          color: current ? _orange : _cream)),
                  if (sub != null)
                    Text(sub,
                        style: AppFonts.body(
                            size: 11.5, color: const Color(0xFF7D7362))),
                ],
              ),
            ),
            if (!unlocked)
              const ArcIconView(ArcIcon.lock, color: _soft, size: 18)
            else if (l.isFree && !current)
              Text(t('free_tag'),
                  style: AppFonts.body(size: 11, color: const Color(0xFF6FA8A0))),
          ]),
        ),
      ),
    );
  }
}
