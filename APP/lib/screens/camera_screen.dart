import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';
import 'package:flutter/services.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  static const _previewChannel = MethodChannel('com.surfeye/preview');

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isCameraActive = false;
  bool _showGrid = true;
  bool _isCapturing = false;
  bool _isLoading = false;
  bool _isCalibrationAuto = true;

  // Zoom state
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0;

  // Focus state
  Offset? _focusPoint;
  Timer? _focusTimer;

  // Live preview state
  bool _isHolding = false;
  Timer? _previewTimer;
  List<Offset>? _liveContour;
  double? _liveAngle;
  double? _liveBaselineY; // in image coords (0..1 normalized)
  bool _previewBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _previewTimer?.cancel();
    _focusTimer?.cancel();
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
      final camera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      _controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);
      await _controller!.initialize();
      
      try {
        _maxZoomLevel = await _controller!.getMaxZoomLevel();
        _minZoomLevel = await _controller!.getMinZoomLevel();
      } catch (_) {
        // Fallbacks if not supported
      }
      
      if (mounted) setState(() => _isCameraActive = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Akses kamera ditolak: $e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Hold-to-preview ──────────────────────────────────────────────────────
  void _onHoldStart(LongPressStartDetails _) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() { _isHolding = true; _liveContour = null; _liveAngle = null; });
    _triggerPreview();
    _previewTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => _triggerPreview());
  }

  void _onHoldEnd(LongPressEndDetails _) {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (_isHolding) {
      setState(() => _isHolding = false);
      _captureImage();
    }
  }

  Future<void> _triggerPreview() async {
    if (_previewBusy || _controller == null || !_controller!.value.isInitialized) return;
    _previewBusy = true;
    try {
      final file = await _controller!.takePicture();
      final args = <String, dynamic>{
        'imagePath': file.path,
        'autoCalibration': _isCalibrationAuto,
      };

      final resStr = await _previewChannel.invokeMethod<String>('previewAnalyze', args);
      if (resStr == null || !mounted) return;

      final res = jsonDecode(resStr) as Map<String, dynamic>;
      final imgW = (res['img_width'] as num).toDouble();
      final imgH = (res['img_height'] as num).toDouble();
      final baselineYImg = (res['baseline_y'] as num).toDouble();
      final approxAngle = (res['approx_angle'] as num?)?.toDouble();

      List<Offset>? contour;
      if (res['contour_points'] != null) {
        final pts = res['contour_points'] as List;
        // Sample every Nth point for performance
        const step = 8;
        contour = [
          for (int i = 0; i < pts.length; i += step)
            Offset((pts[i][0] as num) / imgW, (pts[i][1] as num) / imgH)
        ];
      }

      if (mounted) {
        setState(() {
          _liveContour = contour;
          _liveAngle = approxAngle;
          _liveBaselineY = baselineYImg / imgH;
        });
      }
    } catch (_) {
      // Silent — preview failures are non-fatal
    } finally {
      _previewBusy = false;
    }
  }

  // ── Full capture & analysis ──────────────────────────────────────────────
  Future<void> _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _isCapturing = true);
    try {
      final file = await _controller!.takePicture();
      
      if (mounted) {
        setState(() => _isCapturing = false);
        context.push('/calibration', extra: {'imagePath': file.path});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCapturing = false);
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Kesalahan', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
            content: Text('Terjadi kesalahan saat memproses gambar: $e', style: GoogleFonts.inter()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Tutup', style: GoogleFonts.inter(color: NatureColors.accent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  // Baseline drag removed

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NatureColors.foreground,
      body: Stack(
        children: [
          // ── Camera preview ─────────────────────────────────────────────
          if (_isCameraActive && _controller != null)
            Positioned.fill(
              child: GestureDetector(
                onScaleStart: (details) {
                  _baseZoomLevel = _currentZoomLevel;
                },
                onScaleUpdate: (details) async {
                  if (_controller == null) return;
                  double targetZoom = _baseZoomLevel * details.scale;
                  targetZoom = targetZoom.clamp(_minZoomLevel, _maxZoomLevel);
                  try {
                    await _controller!.setZoomLevel(targetZoom);
                    if (mounted) {
                      setState(() {
                        _currentZoomLevel = targetZoom;
                      });
                    }
                  } catch (e) {
                    // Ignore zoom errors on unsupported devices
                  }
                },
                onTapDown: (details) async {
                  if (_controller == null) return;
                  final RenderBox box = context.findRenderObject() as RenderBox;
                  final Offset localPosition = box.globalToLocal(details.globalPosition);
                  final double dx = localPosition.dx / box.size.width;
                  final double dy = localPosition.dy / box.size.height;
                  
                  if (mounted) {
                    setState(() {
                      _focusPoint = localPosition;
                    });
                    _focusTimer?.cancel();
                    _focusTimer = Timer(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _focusPoint = null);
                    });
                  }

                  try {
                    await _controller!.setFocusPoint(Offset(dx, dy));
                    await _controller!.setFocusMode(FocusMode.auto);
                  } catch (e) {
                    // Ignore focus errors on unsupported devices
                  }
                },
                child: CameraPreview(_controller!),
              ),
            ),

          // ── Visual Focus Indicator ─────────────────────────────────────
          if (_isCameraActive && _focusPoint != null)
            Positioned(
              left: _focusPoint!.dx - 35,
              top: _focusPoint!.dy - 35,
              child: IgnorePointer(
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    border: Border.all(color: NatureColors.accent, width: 2),
                  ),
                ).animate().scale(begin: const Offset(1.2, 1.2), duration: 200.ms, curve: Curves.easeOut),
              ),
            ),

          // ── Pre-camera state ───────────────────────────────────────────
          if (!_isCameraActive)
            Positioned.fill(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      gradient: NatureColors.natureGradient,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 40),
                  ).animate().scale(begin: const Offset(0.8, 0.8), duration: 400.ms),
                  const SizedBox(height: 16),
                  Text(
                    'Posisikan tetesan air pada permukaan datar\ndengan pencahayaan yang baik',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(fontSize: 13, color: Colors.white.withValues(alpha: 0.7), height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  if (_isLoading)
                    const CircularProgressIndicator(color: NatureColors.accent)
                  else
                    GestureDetector(
                      onTap: _startCamera,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: NatureColors.natureGradient,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: NatureColors.natureGlow,
                        ),
                        child: Text('Mulai Kamera',
                            style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),

          // ── Grid overlay (when not holding) ───────────────────────────
          if (_isCameraActive && _showGrid && !_isHolding)
            Positioned.fill(
              child: IgnorePointer(child: CustomPaint(painter: _GridPainter())),
            ).animate().fadeIn(duration: 300.ms),

          // ── Live OpenCV overlay (while holding) ───────────────────────
          if (_isHolding)
            Positioned.fill(
              child: CustomPaint(
                painter: _LiveOverlayPainter(
                  contour: _liveContour,
                  baselineY: _liveBaselineY ?? 0.65,
                ),
              ),
            ),

          // ── Live angle badge ──────────────────────────────────────────
          if (_isHolding && _liveAngle != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: NatureColors.accent.withValues(alpha: 0.7), width: 1.5),
                  ),
                  child: Text(
                    '°',
                    style: GoogleFonts.outfit(
                      fontSize: 32, fontWeight: FontWeight.w700, color: Colors.white,
                    ),
                  ),
                ),
              ).animate().fadeIn(duration: 200.ms),
            ),

          // Drag hint removed

          // ── Flash overlay on capture ───────────────────────────────────
          if (_isCapturing)
            Positioned.fill(
              child: Container(color: Colors.white)
                  .animate()
                  .fadeIn(duration: 100.ms)
                  .fadeOut(delay: 200.ms, duration: 200.ms),
            ),

          if (_isCapturing)
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: NatureColors.accent),
                const SizedBox(height: 16),
                Text('Sedang Menganalisis...', style: GoogleFonts.outfit(color: Colors.white, fontSize: 18)),
              ]),
            ),

          // ── Top bar ────────────────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16, right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _CircleButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () { _controller?.dispose(); context.go('/'); },
                ),
                Row(children: [
                  _CircleButton(
                    icon: _isCalibrationAuto ? Icons.auto_awesome_rounded : Icons.tune_rounded,
                    active: !_isCalibrationAuto,
                    onTap: () => setState(() => _isCalibrationAuto = !_isCalibrationAuto),
                  ),
                  const SizedBox(width: 8),
                  _CircleButton(
                    icon: Icons.grid_on_rounded,
                    active: _showGrid,
                    onTap: () => setState(() => _showGrid = !_showGrid),
                  ),
                  const SizedBox(width: 8),
                  _CircleButton(icon: Icons.flip_rounded, onTap: () {}),
                ]),
              ],
            ),
          ),

          // ── Capture button (tap = instant, hold = live preview) ────────
          if (_isCameraActive)
            Positioned(
              bottom: 100, left: 0, right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _isCapturing ? null : _captureImage,
                  onLongPressStart: _isCapturing ? null : _onHoldStart,
                  onLongPressEnd: _isCapturing ? null : _onHoldEnd,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: _isHolding ? 90 : 80,
                    height: _isHolding ? 90 : 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isHolding
                            ? NatureColors.accent.withValues(alpha: 1.0)
                            : Colors.white.withValues(alpha: 0.8),
                        width: _isHolding ? 5 : 4,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: NatureColors.natureGradient,
                        ),
                      ),
                    ),
                  )
                      .animate(onPlay: (c) => c.repeat())
                      .scaleXY(begin: 0.95, end: 1.0, duration: 1000.ms, curve: Curves.easeInOut)
                      .then()
                      .scaleXY(begin: 1.0, end: 0.95, duration: 1000.ms, curve: Curves.easeInOut),
                ),
              )
                  .animate()
                  .fadeIn(delay: 200.ms)
                  .slideY(begin: 0.3, end: 0, delay: 200.ms),
            ),

          // ── Bottom Nav ─────────────────────────────────────────────────
          Positioned(bottom: 0, left: 0, right: 0, child: const BottomNav(dark: true)),
        ],
      ),
    );
  }
}

// ── Live overlay painter ───────────────────────────────────────────────────────
class _LiveOverlayPainter extends CustomPainter {
  const _LiveOverlayPainter({required this.contour, required this.baselineY});
  final List<Offset>? contour;
  final double baselineY; // 0..1 normalized

  @override
  void paint(Canvas canvas, Size size) {
    // Draw contour
    if (contour != null && contour!.isNotEmpty) {
      final contourPaint = Paint()
        ..color = NatureColors.accent.withValues(alpha: 0.9)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      final path = Path();
      path.moveTo(contour!.first.dx * size.width, contour!.first.dy * size.height);
      for (final pt in contour!.skip(1)) {
        path.lineTo(pt.dx * size.width, pt.dy * size.height);
      }
      path.close();
      canvas.drawPath(path, contourPaint);
    }

    // Draw baseline
    final baseY = baselineY * size.height;
    final baselinePaint = Paint()
      ..color = Colors.yellowAccent.withValues(alpha: 0.9)
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), baselinePaint);

  }

  @override
  bool shouldRepaint(_LiveOverlayPainter old) =>
      old.contour != contour || old.baselineY != baselineY;
}

// ── Circle icon button ─────────────────────────────────────────────────────────
class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap, this.active = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? NatureColors.accent.withValues(alpha: 0.4) : Colors.black.withValues(alpha: 0.3),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

// ── Grid overlay painter ───────────────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()..color = NatureColors.accent.withValues(alpha: 0.2)..strokeWidth = 1;
    final accentPaint = Paint()..color = NatureColors.accent.withValues(alpha: 0.4)..strokeWidth = 1.2;
    final circlePaint = Paint()
      ..color = NatureColors.accent.withValues(alpha: 0.5)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), linePaint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), linePaint);
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), linePaint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), linePaint);
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 32, circlePaint);
    final surfaceY = size.height * 0.6;
    canvas.drawLine(Offset(size.width * 0.1, surfaceY), Offset(size.width * 0.9, surfaceY), accentPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
