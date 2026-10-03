import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'ambient_background.dart';
import 'blueprint_logo.dart';

/// Launch splash for a user who is already signed in: the Blueprint Pour
/// drawn at screen centre on the dark sheet, then a fade to Home. (Signed-out
/// users get the same animation on the sign-in screen instead, where it
/// lifts into the form.) Tap skips; reduce-motion skips entirely.
class BlueprintSplash extends StatefulWidget {
  final VoidCallback onDone;
  const BlueprintSplash({super.key, required this.onDone});

  @override
  State<BlueprintSplash> createState() => _BlueprintSplashState();
}

class _BlueprintSplashState extends State<BlueprintSplash>
    with TickerProviderStateMixin {
  /// Stops once the pour has cooled, before the sign-in screen's lift.
  static const _length = BlueprintTimeline.textPour + 1.5;

  late final AnimationController _draw = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (_length * 1000).round()));
  late final AnimationController _fade = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 450));
  final AudioPlayer _sound = AudioPlayer();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone());
      return;
    }
    _draw.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    _start();
  }

  Future<void> _start() async {
    try {
      await GoogleFonts.pendingFonts([
        GoogleFonts.montserrat(fontWeight: FontWeight.w300),
        GoogleFonts.ibmPlexMono(),
      ]).timeout(const Duration(milliseconds: 1200));
    } catch (_) {}
    if (!mounted) return;
    _draw.forward();
    try {
      await _sound.setAudioContext(AudioContextConfig(
        respectSilence: true,
        focus: AudioContextConfigFocus.mixWithOthers,
      ).build());
      await _sound.play(AssetSource('sounds/login_intro.wav'), volume: 0.75);
    } catch (_) {}
  }

  Future<void> _finish() async {
    if (_fade.isAnimating || _fade.value > 0) return;
    await _fade.forward();
    _sound.stop().catchError((_) {});
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _draw.dispose();
    _fade.dispose();
    _sound.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: ReverseAnimation(_fade),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _finish,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const BlueprintBackdrop(dark: true, focus: Alignment(0, -0.1)),
              Center(
                child: AnimatedBuilder(
                  animation: _draw,
                  builder: (context, _) =>
                      BlueprintLogo(t: _draw.value * _length, width: 240),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
