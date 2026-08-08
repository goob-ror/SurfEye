import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isCameraActive = false;
  bool _showGrid = true;
  bool _isCapturing = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  Future<void> _startCamera() async {
    setState(() => _isLoading = true);
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      // Prefer rear camera
      final camera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _controller!.initialize();

      if (mounted) setState(() => _isCameraActive = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera access denied: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _isCapturing = true);

    try {
      final file = await _controller!.takePicture();
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted) {
        final angle =
            double.parse((Random().nextDouble() * 140 + 10).toStringAsFixed(1));
        context.go('/results', extra: {
          'imagePath': file.path,
          'angle': angle,
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HydroColors.foreground,
      body: Stack(
        children: [
          // ── Camera preview ───────────────────────────────────────────────
          if (_isCameraActive && _controller != null)
            Positioned.fill(
              child: CameraPreview(_controller!),
            ),

          // ── Pre-camera state ─────────────────────────────────────────────
          if (!_isCameraActive)
            Positioned.fill(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: HydroColors.hydroGradient,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.bolt_rounded,
                        color: Colors.white, size: 40),
                  )
                      .animate()
                      .scale(begin: const Offset(0.8, 0.8), duration: 400.ms),
                  const SizedBox(height: 16),
                  Text(
                    'Position the water droplet on a flat\nsurface with good lighting',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.7),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (_isLoading)
                    const CircularProgressIndicator(
                        color: HydroColors.accent)
                  else
                    GestureDetector(
                      onTap: _startCamera,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: HydroColors.hydroGradient,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: HydroColors.hydroGlow,
                        ),
                        child: Text(
                          'Start Camera',
                          style: GoogleFonts.outfit(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // ── Grid overlay ─────────────────────────────────────────────────
          if (_isCameraActive && _showGrid)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GridPainter(),
                ),
              ),
            ).animate().fadeIn(duration: 300.ms),

          // ── Flash overlay on capture ─────────────────────────────────────
          if (_isCapturing)
            Positioned.fill(
              child: Container(color: Colors.white)
                  .animate()
                  .fadeIn(duration: 100.ms)
                  .fadeOut(delay: 200.ms, duration: 200.ms),
            ),

          // ── Top bar ──────────────────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _CircleButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () {
                    _controller?.dispose();
                    context.go('/');
                  },
                ),
                Row(
                  children: [
                    _CircleButton(
                      icon: Icons.grid_on_rounded,
                      active: _showGrid,
                      onTap: () => setState(() => _showGrid = !_showGrid),
                    ),
                    const SizedBox(width: 8),
                    _CircleButton(
                      icon: Icons.flip_rounded,
                      onTap: () {},
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Capture button ───────────────────────────────────────────────
          if (_isCameraActive)
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _isCapturing ? null : _captureImage,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.8), width: 4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: HydroColors.hydroGradient,
                        ),
                      ),
                    ),
                  )
                      .animate(onPlay: (c) => c.repeat())
                      .scaleXY(
                          begin: 0.95,
                          end: 1.0,
                          duration: 1000.ms,
                          curve: Curves.easeInOut)
                      .then()
                      .scaleXY(
                          begin: 1.0,
                          end: 0.95,
                          duration: 1000.ms,
                          curve: Curves.easeInOut),
                ),
              )
                  .animate()
                  .fadeIn(delay: 200.ms)
                  .slideY(begin: 0.3, end: 0, delay: 200.ms),
            ),

          // ── Bottom Nav ───────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: const BottomNav(dark: true),
          ),
        ],
      ),
    );
  }
}

// ── Circle icon button ────────────────────────────────────────────────────────
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? HydroColors.accent.withValues(alpha: 0.4)
              : Colors.black.withValues(alpha: 0.3),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

// ── Grid overlay painter ──────────────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = HydroColors.accent.withValues(alpha: 0.2)
      ..strokeWidth = 1;

    final accentPaint = Paint()
      ..color = HydroColors.accent.withValues(alpha: 0.4)
      ..strokeWidth = 1.2;

    final circlePaint = Paint()
      ..color = HydroColors.accent.withValues(alpha: 0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Cross lines
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), linePaint);
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), linePaint);

    // Center circle crosshair
    canvas.drawCircle(
        Offset(size.width / 2, size.height / 2), 32, circlePaint);

    // Surface line at 40% from bottom
    final surfaceY = size.height * 0.6;
    canvas.drawLine(
      Offset(size.width * 0.1, surfaceY),
      Offset(size.width * 0.9, surfaceY),
      accentPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
