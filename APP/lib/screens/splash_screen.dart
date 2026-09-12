import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import 'package:surfeye_app/theme/app_theme.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();

    if (kIsWeb) {
      // video_player does not support asset videos reliably on web.
      // Navigate directly after a brief delay so the app still loads fast.
      Future.delayed(const Duration(milliseconds: 1800), _goHome);
    } else {
      _controller =
          VideoPlayerController.asset('assets/images/PKM2026_Intro.mp4')
            ..initialize().then((_) {
              setState(() {});
              _controller!.play();

              // Navigate when video finishes
              _controller!.addListener(() {
                if (_controller!.value.position >=
                        _controller!.value.duration &&
                    !_controller!.value.isPlaying) {
                  _goHome();
                }
              });
            });
    }
  }

  void _goHome() {
    if (mounted) context.go('/');
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ── Web: simple branded loading screen ──────────────────────────────────
    if (kIsWeb) {
      return Scaffold(
        backgroundColor: NatureColors.foreground,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/images/logopkm26.png',
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.energy_savings_leaf,
                    color: Colors.white,
                    size: 96,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  color: NatureColors.accent,
                  strokeWidth: 3,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ── Mobile: video splash ─────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: NatureColors.background,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _goHome,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: (_controller?.value.isInitialized ?? false)
                  ? AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    )
                  : const CircularProgressIndicator(),
            ),
            // Skip hint
            const Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Ketuk untuk lewati',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
