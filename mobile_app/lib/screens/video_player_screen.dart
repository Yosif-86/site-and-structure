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

    await _loadWatermarkLabel();
    await _loadVideo();
  }

  Future<void> _loadWatermarkLabel() async {
    final user = SupabaseService.instance.currentUser;
    if (user == null) return;
    try {
      final prof = await SupabaseService.instance.client.from('profiles').select('phone').eq('id', user.id).maybeSingle();
      final phone = prof?['phone'] as String?;
      setState(() => _watermarkLabel = (phone != null && phone.isNotEmpty) ? phone : (user.email ?? ''));
    } catch (_) {
      setState(() => _watermarkLabel = user.email ?? '');
    }
  }

  Future<void> _loadVideo() async {
    final session = SupabaseService.instance.client.auth.currentSession;
    if (session == null) {
      setState(() { _loading = false; _error = AppStrings.instance.t('err_video_unavailable'); });
      return;
    }
    final result = await ApiService.getVideoUrl(widget.lectureId, session.accessToken);
    if (result.error != null || result.url == null) {
      setState(() { _loading = false; _error = AppStrings.instance.t(result.error ?? 'err_video_unavailable'); });
      return;
    }

    if (result.type == 'hls') {
      final controller = VideoPlayerController.networkUrl(Uri.parse(result.url!));
      await controller.initialize();
      controller.play();
      setState(() { _hlsController = controller; _loading = false; });
    } else {
      // Bunny iframe embed — needs a WebView, not the native player.
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse(result.url!));
      setState(() { _webController = controller; _loading = false; });
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
