import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/services/api_service.dart';
import 'package:surfeye_app/services/database_service.dart';
import 'package:surfeye_app/theme/app_theme.dart';

class CalibrationScreen extends StatefulWidget {
  final String imagePath;
  const CalibrationScreen({super.key, required this.imagePath});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  // normalizedY drives the yellow line (0 = top, 1 = bottom of image)
  double _normalizedY = 0.6;

  bool _isLoadingBaseline = true; // auto-detection in progress
  bool _isAnalyzing = false;
  bool _autoDetectFailed = false;

  double? _imageWidth;
  double? _imageHeight;
  bool _imageLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadImageDimensions();
  }

  Future<void> _loadImageDimensions() async {
    final file = File(widget.imagePath);
    final decoded = await decodeImageFromList(await file.readAsBytes());
    if (!mounted) return;
    setState(() {
      _imageWidth = decoded.width.toDouble();
      _imageHeight = decoded.height.toDouble();
      _imageLoaded = true;
    });
    // Now auto-detect the baseline
    await _autoDetectBaseline();
  }

  /// Calls the API with no baseline override to get the auto-detected position,
  /// then positions the yellow line there so the user can fine-tune.
  Future<void> _autoDetectBaseline() async {
    setState(() => _isLoadingBaseline = true);
    try {
      final result = await ApiService.detectBaseline(widget.imagePath);
      if (!mounted) return;
      if (result != null && _imageHeight != null) {
        final detectedY = (result['detected_baseline_y'] as num?)?.toInt();
        if (detectedY != null) {
          setState(() {
            _normalizedY = (detectedY / _imageHeight!).clamp(0.05, 0.95);
            _autoDetectFailed = false;
          });
        } else {
          setState(() => _autoDetectFailed = true);
        }
      } else {
        setState(() => _autoDetectFailed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _autoDetectFailed = true);
    } finally {
      if (mounted) setState(() => _isLoadingBaseline = false);
    }
  }

  Future<void> _analyze() async {
    if (!_imageLoaded || _imageHeight == null) return;
    setState(() => _isAnalyzing = true);

    final baselineY = (_normalizedY * _imageHeight!).toInt();

    try {
      final result = await ApiService.analyzeImage(widget.imagePath, baselineY: baselineY);

      if (result == null) {
        if (mounted) {
          setState(() => _isAnalyzing = false);
          _showErrorDialog('Tidak dapat mendeteksi tetesan atau analisis gagal.');
        }
        return;
      }

      final angle = ((result['average_angle'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 180.0);
      final surface = result['classification'] as String? ?? 'Tidak Diketahui';
      final annotatedPath = result['annotated_image_path'] as String? ?? widget.imagePath;
      final edgePath = result['edge_image_path'] as String?;

      final measurement = Measurement(
        id: 0,
        angle: angle,
        surface: surface,
        timestamp: DateTime.now(),
        imagePath: annotatedPath,
        edgeImagePath: edgePath,
        leftAngle: (result['left_angle'] as num?)?.toDouble(),
        rightAngle: (result['right_angle'] as num?)?.toDouble(),
        bondNumber: (result['bond_number'] as num?)?.toDouble(),
        method: result['method'] as String?,
        dropletWidthPx: (result['droplet_width_px'] as num?)?.toDouble(),
        dropletHeightPx: (result['droplet_height_px'] as num?)?.toDouble(),
        fitResidualRms: (result['fit_residual_rms_px'] as num?)?.toDouble(),
      );

      final saved = await DatabaseService.instance.insertMeasurement(measurement);

      if (mounted) {
        context.go('/results', extra: {'measurement': saved});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAnalyzing = false);
        _showErrorDialog('Terjadi kesalahan: $e');
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NatureColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Analisis Gagal',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold, color: NatureColors.cardForeground)),
        content: Text(message,
            style: GoogleFonts.inter(color: NatureColors.mutedForeground)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Tutup',
                style: GoogleFonts.inter(color: NatureColors.accent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true, // allow normal back
      child: Scaffold(
        backgroundColor: NatureColors.foreground,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top bar ────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: () => context.pop(),
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: NatureColors.muted),
                        child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    Text('Kalibrasi Garis Dasar',
                        style: GoogleFonts.outfit(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                    // Re-detect button
                    GestureDetector(
                      onTap: _isLoadingBaseline ? null : _autoDetectBaseline,
                      child: Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isLoadingBaseline
                              ? NatureColors.muted.withValues(alpha: 0.4)
                              : NatureColors.accent.withValues(alpha: 0.2),
                        ),
                        child: _isLoadingBaseline
                            ? const Padding(
                                padding: EdgeInsets.all(10),
                                child: CircularProgressIndicator(
                                    color: NatureColors.accent, strokeWidth: 2),
                              )
                            : const Icon(Icons.auto_fix_high_rounded,
                                color: NatureColors.accent, size: 20),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Image + draggable baseline ─────────────────────────────────
              Expanded(
                child: _imageLoaded
                    ? Center(
                        child: AspectRatio(
                          aspectRatio: _imageWidth! / _imageHeight!,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return GestureDetector(
                                onPanUpdate: (details) {
                                  setState(() {
                                    _normalizedY +=
                                        details.delta.dy / constraints.maxHeight;
                                    _normalizedY = _normalizedY.clamp(0.05, 0.95);
                                  });
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.file(File(widget.imagePath),
                                        fit: BoxFit.contain),

                                    // ── Instruction banner ──────────────────
                                    Positioned(
                                      top: 12, left: 12, right: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.6),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              _autoDetectFailed
                                                  ? Icons.warning_amber_rounded
                                                  : Icons.auto_fix_high_rounded,
                                              color: _autoDetectFailed
                                                  ? Colors.amber
                                                  : NatureColors.accent,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                _autoDetectFailed
                                                    ? 'Deteksi otomatis gagal. Geser garis kuning secara manual.'
                                                    : 'Garis kuning diposisikan otomatis. Geser untuk menyesuaikan.',
                                                style: GoogleFonts.inter(
                                                    color: Colors.white, fontSize: 12),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ).animate().fadeIn(duration: 300.ms),
                                    ),

                                    // ── Baseline line ───────────────────────
                                    Positioned(
                                      top: _normalizedY * constraints.maxHeight - 20,
                                      left: 0,
                                      right: 0,
                                      height: 40,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Container(
                                            height: 2.5,
                                            width: double.infinity,
                                            color: Colors.yellowAccent,
                                          ),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              _buildGrip(),
                                              _buildGrip(),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      )
                    : const Center(
                        child: CircularProgressIndicator(color: NatureColors.accent)),
              ),

              // ── Analyze button ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: (_isAnalyzing || !_imageLoaded || _isLoadingBaseline)
                        ? null
                        : _analyze,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NatureColors.accent,
                      disabledBackgroundColor:
                          NatureColors.accent.withValues(alpha: 0.4),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: _isAnalyzing
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5))
                        : _isLoadingBaseline
                            ? Text('Mendeteksi garis dasar...',
                                style: GoogleFonts.outfit(
                                    fontSize: 15, fontWeight: FontWeight.w600))
                            : Text('Mulai Analisis',
                                style: GoogleFonts.outfit(
                                    fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrip() {
    return Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color: Colors.yellowAccent.withValues(alpha: 0.25),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 10, height: 10,
          decoration: const BoxDecoration(
              color: Colors.yellowAccent, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
