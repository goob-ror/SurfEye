import 'dart:io';
import 'package:flutter/material.dart';
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
  double _normalizedY = 0.6; // Default to 60% down the image
  bool _isAnalyzing = false;
  
  // Image dimension state
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
    final decodedImage = await decodeImageFromList(await file.readAsBytes());
    if (mounted) {
      setState(() {
        _imageWidth = decodedImage.width.toDouble();
        _imageHeight = decodedImage.height.toDouble();
        _imageLoaded = true;
      });
    }
  }

  Future<void> _analyze() async {
    if (!_imageLoaded || _imageHeight == null) return;
    
    setState(() => _isAnalyzing = true);
    
    // Convert normalized Y to actual image pixel Y
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

      final measurement = Measurement(
        id: 0,
        angle: angle,
        surface: surface,
        timestamp: DateTime.now(),
        imagePath: annotatedPath,
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
      builder: (context) => AlertDialog(
        title: Text('Analisis Gagal', style: GoogleFonts.outfit(fontWeight: FontWeight.bold)),
        content: Text(message, style: GoogleFonts.inter()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Tutup', style: GoogleFonts.inter(color: NatureColors.accent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NatureColors.foreground,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
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
                      child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                  Text('Kalibrasi Garis Dasar', 
                    style: GoogleFonts.outfit(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 40), // Balance the title
                ],
              ),
            ),
            
            // Image and Calibration Area
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
                                  _normalizedY += details.delta.dy / constraints.maxHeight;
                                  _normalizedY = _normalizedY.clamp(0.0, 1.0);
                                });
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(File(widget.imagePath), fit: BoxFit.contain),
                                  
                                  // Instructions
                                  Positioned(
                                    top: 16, left: 16, right: 16,
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.6),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        'Geser garis kuning ke bawah tetesan air (garis batas antara tetesan dan permukaan)',
                                        textAlign: TextAlign.center,
                                        style: GoogleFonts.inter(color: Colors.white, fontSize: 13),
                                      ),
                                    ),
                                  ),
                                  
                                  // Baseline indicator
                                  Positioned(
                                    top: _normalizedY * constraints.maxHeight - 20, // Center the touch area
                                    left: 0,
                                    right: 0,
                                    height: 40,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Container(
                                          height: 3,
                                          width: double.infinity,
                                          color: Colors.yellowAccent,
                                        ),
                                        // Grips
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            _buildGrip(),
                                            _buildGrip(),
                                          ],
                                        )
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
                  : const Center(child: CircularProgressIndicator(color: NatureColors.accent)),
            ),
            
            // Bottom Action Bar
            Container(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isAnalyzing || !_imageLoaded ? null : _analyze,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NatureColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: _isAnalyzing
                      ? const SizedBox(
                          width: 24, height: 24,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text('Mulai Analisis', style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrip() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.yellowAccent.withValues(alpha: 0.3),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            color: Colors.yellowAccent,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
