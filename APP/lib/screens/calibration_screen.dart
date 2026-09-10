// ignore_for_file: unused_field

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:photo_view/photo_view.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/services/api_service.dart';
import 'package:surfeye_app/services/calibration_storage.dart';
import 'package:surfeye_app/services/database_service.dart';
import 'package:surfeye_app/theme/app_theme.dart';

enum CalibrationMode {
  auto,     // Fully automatic - no user intervention
  semiAuto, // User draws baseline + droplet region
}

class CalibrationScreen extends StatefulWidget {
  final String imagePath;
  const CalibrationScreen({super.key, required this.imagePath});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  // Calibration mode
  CalibrationMode _mode = CalibrationMode.auto;
  
  // Baseline position (normalized 0-1)
  double _normalizedY = 0.6;
  double? _autoDetectedY; // Store auto-detected position for comparison

  // Droplet bounding box (normalized 0-1)
  Rect? _dropletBoundingBox;

  // Advanced preprocessing parameters
  int _brightness = 0;
  double _contrast = 1.0;
  int _edgeSensitivity = 50;

  // Ellipse fine-tuning parameters
  double _ellipseAngle = 0.0;
  double _ellipseScaleA = 1.0;
  double _ellipseScaleB = 1.0;

  // State flags
  bool _isLoadingBaseline = true;
  bool _isAnalyzing = false;
  bool _autoDetectFailed = false;
  bool _isDrawingMode = false;
  bool _usingSavedDefaults = false;
  bool _isLoadingPreview = false;

  // Preview state
  String? _previewImageUrl;
  Timer? _previewDebounceTimer;

  // Image dimensions
  double? _imageHeight;
  bool _imageLoaded = false;

  // Zoom controls
  late PhotoViewController _photoViewController;
  double _zoomLevel = 1.0;
  bool _showZoomSlider = false;

  // Drawing state for bounding box
  Offset? _drawStart;
  Offset? _drawCurrent;

  @override
  void initState() {
    super.initState();
    _photoViewController = PhotoViewController();
    _photoViewController.outputStateStream.listen((state) {
      if (mounted && state.scale != null) {
        setState(() {
          _zoomLevel = state.scale!;
        });
      }
    });
    _loadImageDimensions();
  }

  @override
  void dispose() {
    _photoViewController.dispose();
    _previewDebounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadImageDimensions() async {
    Uint8List bytes;
    if (kIsWeb) {
      final response = await http.get(Uri.parse(widget.imagePath));
      bytes = response.bodyBytes;
    } else {
      bytes = await File(widget.imagePath).readAsBytes();
    }
    final decoded = await decodeImageFromList(bytes);
    if (!mounted) return;
    setState(() {
      _imageHeight = decoded.height.toDouble();
      _imageLoaded = true;
    });

    // Show mode selection dialog first
    await _showModeSelectionDialog();
    
    // Load initial preview
    if (mounted) {
      _updatePreview();
    }
  }

  /// Show mode selection dialog
  Future<void> _showModeSelectionDialog() async {
    final selectedMode = await showDialog<CalibrationMode>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewPadding.bottom;
        return AlertDialog(
          backgroundColor: NatureColors.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          // Push the dialog away from system bars so it sits in true center
          insetPadding: EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24 + bottomInset,
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: NatureColors.natureGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.tune_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Text(
                'Pilih Mode Kalibrasi',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.bold,
                  color: NatureColors.cardForeground,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Pilih mode analisis untuk mengukur sudut kontak tetesan air',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  color: NatureColors.mutedForeground,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 24),
              _ModeSelectionCard(
                mode: CalibrationMode.auto,
                icon: Icons.auto_awesome_rounded,
                title: 'Auto',
                description: 'Deteksi otomatis penuh tanpa intervensi manual',
                features: const [
                  'Deteksi garis dasar otomatis',
                  'Deteksi tetesan otomatis',
                  'Cepat dan mudah',
                ],
              ),
              const SizedBox(height: 16),
              _ModeSelectionCard(
                mode: CalibrationMode.semiAuto,
                icon: Icons.edit_rounded,
                title: 'Semi-Auto',
                description: 'Kontrol penuh untuk akurasi maksimal',
                features: const [
                  'Gambar garis dasar manual',
                  'Gambar area tetesan manual',
                  'Akurat untuk foto lab',
                ],
                recommended: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'Batal',
                style: GoogleFonts.inter(
                  color: NatureColors.mutedForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (selectedMode != null && mounted) {
      setState(() => _mode = selectedMode);
      
      if (_mode == CalibrationMode.auto) {
        // Check for saved defaults first in auto mode
        final defaults = await CalibrationStorage.loadDefaults();
        if (defaults['useDefaults'] == true && defaults['baselineOffsetY'] != null) {
          setState(() {
            _normalizedY = defaults['baselineOffsetY'];
            _dropletBoundingBox = defaults['dropletBbox'];
            _usingSavedDefaults = true;
            _isLoadingBaseline = false;
            
            // Load advanced settings if available
            if (defaults['brightness'] != null) {
              _brightness = defaults['brightness'];
            }
            if (defaults['contrast'] != null) {
              _contrast = defaults['contrast'];
            }
            if (defaults['edgeSensitivity'] != null) {
              _edgeSensitivity = defaults['edgeSensitivity'];
            }
            if (defaults['ellipseAngle'] != null) {
              _ellipseAngle = defaults['ellipseAngle'];
            }
            if (defaults['ellipseScaleA'] != null) {
              _ellipseScaleA = defaults['ellipseScaleA'];
            }
            if (defaults['ellipseScaleB'] != null) {
              _ellipseScaleB = defaults['ellipseScaleB'];
            }
          });
        } else {
          // Auto-detect baseline
          await _autoDetectBaseline();
        }
      } else {
        // Semi-auto mode: skip auto-detection, let user draw everything
        setState(() => _isLoadingBaseline = false);
      }
    } else if (mounted) {
      // User cancelled - go back
      context.pop();
    }
  }

  /// Auto-detect baseline position from server
  Future<void> _autoDetectBaseline() async {
    setState(() => _isLoadingBaseline = true);
    try {
      final result = await ApiService.detectBaseline(widget.imagePath);
      if (!mounted) return;
      if (result != null && _imageHeight != null) {
        final detectedY = (result['detected_baseline_y'] as num?)?.toInt();
        if (detectedY != null) {
          final normalized = (detectedY / _imageHeight!).clamp(0.05, 0.95);
          setState(() {
            _normalizedY = normalized;
            _autoDetectedY = normalized;
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

  /// Analyze image with current calibration settings
  Future<void> _analyze() async {
    if (!_imageLoaded || _imageHeight == null) return;
    setState(() => _isAnalyzing = true);

    final baselineY = (_normalizedY * _imageHeight!).toInt();

    try {
      final result = await ApiService.analyzeImage(
        widget.imagePath,
        baselineY: baselineY,
        dropletBbox: _dropletBoundingBox,
        brightness: _brightness,
        contrast: _contrast,
        edgeSensitivity: _edgeSensitivity,
        ellipseAngle: _ellipseAngle != 0.0 ? _ellipseAngle : null,
        ellipseScaleA: _ellipseScaleA != 1.0 ? _ellipseScaleA : null,
        ellipseScaleB: _ellipseScaleB != 1.0 ? _ellipseScaleB : null,
      );

      if (result == null) {
        if (mounted) {
          setState(() => _isAnalyzing = false);
          _showErrorDialog(
            'Analisis Gagal',
            'Tidak dapat mendeteksi tetesan atau analisis gagal.',
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Tutup',
                    style: GoogleFonts.inter(
                        color: NatureColors.accent, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        }
        return;
      }

      // Check if manual adjustments were made
      final hasAdjustments = _hasManualAdjustments();

      // Create measurement object
      final angle =
          ((result['average_angle'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 180.0);
      final surface = result['classification'] as String? ?? 'Tidak Diketahui';
      final annotatedPath =
          result['annotated_image_path'] as String? ?? widget.imagePath;
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

      // Prompt to save defaults if manual adjustments were made
      if (hasAdjustments && mounted) {
        await _promptSaveDefaults();
      }

      if (mounted) {
        context.go('/results', extra: {'measurement': saved});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAnalyzing = false);

        // Check for specific error messages
        final errorStr = e.toString();
        if (errorStr.contains('No droplet detected in the specified region')) {
          _showErrorDialog(
            'Tetesan Tidak Terdeteksi',
            'Tidak ada tetesan air terdeteksi di area yang dipilih. Silakan sesuaikan kotak atau gunakan deteksi otomatis.',
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  // Clear bbox and retry
                  setState(() => _dropletBoundingBox = null);
                  _analyze();
                },
                child: Text('Gunakan Otomatis',
                    style: GoogleFonts.inter(
                        color: NatureColors.accent, fontWeight: FontWeight.bold)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  // Re-enter drawing mode
                  setState(() => _isDrawingMode = true);
                },
                child: Text('Coba Lagi',
                    style: GoogleFonts.inter(
                        color: NatureColors.accent, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        } else {
          _showErrorDialog('Analisis Gagal', 'Terjadi kesalahan: $e');
        }
      }
    }
  }

  /// Check if user made manual adjustments compared to auto-detection
  bool _hasManualAdjustments() {
    if (_dropletBoundingBox != null) return true;
    final autoY = _autoDetectedY;
    if (autoY != null && (_normalizedY - autoY).abs() > 0.05) {
      return true;
    }
    // Check if advanced settings were changed from defaults
    if (_brightness != 0 ||
        _contrast != 1.0 ||
        _edgeSensitivity != 50 ||
        _ellipseAngle != 0.0 ||
        _ellipseScaleA != 1.0 ||
        _ellipseScaleB != 1.0) {
      return true;
    }
    return false;
  }

  Widget _buildImagePreviewSection() {
    return Stack(
      children: [
        // Main image display
        Center(
          child: _isDrawingMode
              ? _buildDrawableImage()
              : _buildZoomableImage(),
        ),
        
        // Loading overlay for preview
        if (_isLoadingPreview)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: Colors.blueAccent,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Memperbarui pratinjau...',
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 200.ms),
          ),
      ],
    );
  }

  Widget _buildDrawableImage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            kIsWeb 
                ? Image.network(widget.imagePath, fit: BoxFit.contain)
                : Image.file(File(widget.imagePath), fit: BoxFit.contain),
            Positioned.fill(
              child: _buildDrawingCanvas(constraints),
            ),
            
            // Drawing mode controls overlay
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.crop_free_rounded, color: NatureColors.accent, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Gambar kotak di sekitar tetesan air',
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _dropletBoundingBox = null;
                                _isDrawingMode = false;
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white70),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: Text(
                              'Batal',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        if (_dropletBoundingBox != null) const SizedBox(width: 12),
                        if (_dropletBoundingBox != null)
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _dropletBoundingBox = null;
                                  _drawStart = null;
                                  _drawCurrent = null;
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: Colors.amber.withValues(alpha: 0.7)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(
                                'Hapus',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amber,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _dropletBoundingBox != null
                                ? () {
                                    setState(() => _isDrawingMode = false);
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: NatureColors.accent,
                              disabledBackgroundColor:
                                  NatureColors.accent.withValues(alpha: 0.3),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              elevation: 0,
                            ),
                            child: Text(
                              'Terapkan',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSettingsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        border: Border(
          left: BorderSide(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Settings header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, color: Colors.blueAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Pengaturan',
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          
          // Scrollable settings content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Mode indicator
                  _buildModeIndicator(),
                  const SizedBox(height: 16),
                  
                  // Preprocessing section
                  _buildSectionHeader('PEMROSESAN GAMBAR'),
                  const SizedBox(height: 12),
                  _buildSlider(
                    label: 'Kecerahan',
                    value: _brightness.toDouble(),
                    min: -100,
                    max: 100,
                    divisions: 200,
                    onChanged: (value) {
                      setState(() => _brightness = value.round());
                      _updatePreviewDebounced();
                    },
                    valueLabel: _brightness.toString(),
                  ),
                  _buildSlider(
                    label: 'Kontras',
                    value: _contrast,
                    min: 0.5,
                    max: 3.0,
                    divisions: 50,
                    onChanged: (value) {
                      setState(() => _contrast = value);
                      _updatePreviewDebounced();
                    },
                    valueLabel: _contrast.toStringAsFixed(2),
                  ),
                  _buildSlider(
                    label: 'Sensitivitas Tepi',
                    value: _edgeSensitivity.toDouble(),
                    min: 10,
                    max: 150,
                    divisions: 140,
                    onChanged: (value) {
                      setState(() => _edgeSensitivity = value.round());
                      _updatePreviewDebounced();
                    },
                    valueLabel: _edgeSensitivity.toString(),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Ellipse fine-tuning section
                  _buildSectionHeader('PENYESUAIAN ELIPS'),
                  const SizedBox(height: 12),
                  _buildSlider(
                    label: 'Rotasi (°)',
                    value: _ellipseAngle,
                    min: -45,
                    max: 45,
                    divisions: 180,
                    onChanged: (value) {
                      setState(() => _ellipseAngle = value);
                    },
                    valueLabel: _ellipseAngle.toStringAsFixed(1),
                  ),
                  _buildSlider(
                    label: 'Skala Lebar',
                    value: _ellipseScaleA,
                    min: 0.5,
                    max: 2.0,
                    divisions: 150,
                    onChanged: (value) {
                      setState(() => _ellipseScaleA = value);
                    },
                    valueLabel: _ellipseScaleA.toStringAsFixed(2),
                  ),
                  _buildSlider(
                    label: 'Skala Tinggi',
                    value: _ellipseScaleB,
                    min: 0.5,
                    max: 2.0,
                    divisions: 150,
                    onChanged: (value) {
                      setState(() => _ellipseScaleB = value);
                    },
                    valueLabel: _ellipseScaleB.toStringAsFixed(2),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Reset button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _brightness = 0;
                          _contrast = 1.0;
                          _edgeSensitivity = 50;
                          _ellipseAngle = 0.0;
                          _ellipseScaleA = 1.0;
                          _ellipseScaleB = 1.0;
                        });
                        _updatePreviewDebounced();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(
                        'Reset ke Default',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white38),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white24),
                  const SizedBox(height: 16),
                  
                  // Droplet region button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _isDrawingMode = true;
                        });
                      },
                      icon: Icon(
                        _dropletBoundingBox != null
                            ? Icons.edit_outlined
                            : Icons.crop_free_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _dropletBoundingBox != null
                            ? 'Ubah Area Tetesan'
                            : 'Tentukan Area Tetesan',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: NatureColors.accent,
                        side: BorderSide(
                          color: NatureColors.accent.withValues(alpha: 0.5),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // Analyze button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: (_isAnalyzing ||
                              !_imageLoaded ||
                              _isLoadingBaseline)
                          ? null
                          : _analyze,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: NatureColors.accent,
                        disabledBackgroundColor:
                            NatureColors.accent.withValues(alpha: 0.4),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _isAnalyzing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5))
                          : _isLoadingBaseline
                              ? Text('Mendeteksi...',
                                  style: GoogleFonts.outfit(
                                      fontSize: 14, fontWeight: FontWeight.w600))
                              : Text('Mulai Analisis',
                                  style: GoogleFonts.outfit(
                                      fontSize: 15, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeIndicator() {
    final isSemiAuto = _mode == CalibrationMode.semiAuto;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isSemiAuto
            ? Colors.orange.withValues(alpha: 0.15)
            : NatureColors.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSemiAuto
              ? Colors.orange.withValues(alpha: 0.4)
              : NatureColors.accent.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSemiAuto ? Icons.edit_rounded : Icons.auto_awesome_rounded,
            size: 14,
            color: isSemiAuto ? Colors.orange : NatureColors.accent,
          ),
          const SizedBox(width: 6),
          Text(
            isSemiAuto ? 'Mode Semi-Auto' : 'Mode Auto',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isSemiAuto ? Colors.orange : NatureColors.accent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: Colors.white70,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required String valueLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  valueLabel,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: Colors.blueAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.blueAccent,
              overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// Prompt user to save calibration as defaults
  Future<void> _promptSaveDefaults() async {
    return showModalBottomSheet(
      context: context,
      backgroundColor: NatureColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.save_outlined, color: NatureColors.accent, size: 48),
            const SizedBox(height: 16),
            Text(
              'Simpan Pengaturan?',
              style: GoogleFonts.outfit(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: NatureColors.cardForeground,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Apakah Anda ingin menyimpan pengaturan kalibrasi ini sebagai default untuk pengambilan berikutnya?',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: NatureColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: NatureColors.accent.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      'Tidak, Hanya Sekali Ini',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: NatureColors.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await CalibrationStorage.saveDefaults(
                        _normalizedY,
                        _dropletBoundingBox,
                        brightness: _brightness != 0 ? _brightness : null,
                        contrast: _contrast != 1.0 ? _contrast : null,
                        edgeSensitivity: _edgeSensitivity != 50 ? _edgeSensitivity : null,
                        ellipseAngle: _ellipseAngle != 0.0 ? _ellipseAngle : null,
                        ellipseScaleA: _ellipseScaleA != 1.0 ? _ellipseScaleA : null,
                        ellipseScaleB: _ellipseScaleB != 1.0 ? _ellipseScaleB : null,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NatureColors.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                    child: Text(
                      'Ya, Simpan Default',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showErrorDialog(String title, String message, {List<Widget>? actions}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NatureColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title,
            style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold, color: NatureColors.cardForeground)),
        content: Text(message,
            style: GoogleFonts.inter(color: NatureColors.mutedForeground)),
        actions: actions ??
            [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Tutup',
                    style: GoogleFonts.inter(
                        color: NatureColors.accent, fontWeight: FontWeight.bold)),
              ),
            ],
      ),
    );
  }

  /// Reset to automatic detection
  Future<void> _resetToAuto() async {
    await CalibrationStorage.clearDefaults();
    setState(() {
      _dropletBoundingBox = null;
      _usingSavedDefaults = false;
    });
    await _autoDetectBaseline();
  }

  /// Update preview with debouncing to avoid excessive API calls
  void _updatePreviewDebounced() {
    // Cancel previous timer if it exists
    _previewDebounceTimer?.cancel();

    // Set new timer for 500ms delay
    _previewDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _updatePreview();
    });
  }

  /// Fetch live preview from server
  Future<void> _updatePreview() async {
    if (!_imageLoaded || _imageHeight == null || _isDrawingMode) return;

    setState(() => _isLoadingPreview = true);

    final baselineY = (_normalizedY * _imageHeight!).toInt();

    try {
      final result = await ApiService.getPreview(
        widget.imagePath,
        brightness: _brightness,
        contrast: _contrast,
        edgeSensitivity: _edgeSensitivity,
        baselineY: baselineY,
      );

      if (result != null && mounted) {
        setState(() {
          _previewImageUrl = result['preview_image_path'] as String?;
          _isLoadingPreview = false;
        });
      } else if (mounted) {
        setState(() => _isLoadingPreview = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPreview = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        context.go('/');
      },
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
                    _CircleButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => context.go('/'),
                    ),
                    Text('Kalibrasi',
                        style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        if (_usingSavedDefaults)
                          _CircleButton(
                            icon: Icons.refresh_rounded,
                            onTap: _resetToAuto,
                            tooltip: 'Reset ke Otomatis',
                          ),
                        const SizedBox(width: 8),
                        _CircleButton(
                          icon: _isLoadingBaseline
                              ? Icons.hourglass_empty_rounded
                              : Icons.auto_fix_high_rounded,
                          onTap: _isLoadingBaseline ? null : _autoDetectBaseline,
                          active: !_isLoadingBaseline,
                          tooltip: 'Deteksi Ulang',
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ── Horizontal layout: Image on left, Settings on right ────────
              Expanded(
                child: _imageLoaded
                    ? Row(
                        children: [
                          // Left side: Image preview
                          Expanded(
                            flex: 3,
                            child: _buildImagePreviewSection(),
                          ),
                          
                          // Right side: Scrollable settings panel (always visible)
                          SizedBox(
                            width: 320,
                            child: _buildSettingsPanel(),
                          ),
                        ],
                      )
                    : const Center(
                        child: CircularProgressIndicator(color: NatureColors.accent)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildZoomableImage() {
    // Use preview image if available, otherwise use original
    final imageToDisplay = _previewImageUrl ?? widget.imagePath;
    final isNetworkImage = _previewImageUrl != null;

    return Stack(
      children: [
        // Image layer
        GestureDetector(
          onTap: () {
            setState(() => _showZoomSlider = !_showZoomSlider);
          },
          child: PhotoView.customChild(
            controller: _photoViewController,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            backgroundDecoration:
                const BoxDecoration(color: Colors.transparent),
            child: isNetworkImage || kIsWeb
                ? Image.network(imageToDisplay, fit: BoxFit.contain)
                : Image.file(File(imageToDisplay), fit: BoxFit.contain),
          ),
        ),

        // Baseline overlay
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return IgnorePointer(
                child: _buildBaselineOverlay(constraints.maxHeight),
              );
            },
          ),
        ),

        // Zoom slider
        if (_showZoomSlider)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.zoom_out, color: Colors.white, size: 20),
                  Expanded(
                    child: Slider(
                      value: _zoomLevel.clamp(1.0, 4.0),
                      min: 1.0,
                      max: 4.0,
                      activeColor: NatureColors.accent,
                      inactiveColor: Colors.white.withValues(alpha: 0.3),
                      onChanged: (value) {
                        _photoViewController.scale = value;
                      },
                    ),
                  ),
                  const Icon(Icons.zoom_in, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${_zoomLevel.toStringAsFixed(1)}x',
                    style: GoogleFonts.inter(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 200.ms),
          ),
      ],
    );
  }

  Widget _buildBaselineOverlay(double containerHeight) {
    return Positioned(
      top: _normalizedY * containerHeight - 20,
      left: 0,
      right: 0,
      height: 40,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          setState(() {
            _normalizedY += details.delta.dy / containerHeight;
            _normalizedY = _normalizedY.clamp(0.05, 0.95);
          });
          _updatePreviewDebounced();
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 2.5,
              width: double.infinity,
              color: Colors.yellowAccent,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [_buildGrip(), _buildGrip()],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawingCanvas(BoxConstraints constraints) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {
        final normalized = Offset(
          details.localPosition.dx / constraints.maxWidth,
          details.localPosition.dy / constraints.maxHeight,
        );
        setState(() {
          _drawStart = normalized;
          _drawCurrent = normalized;
        });
      },
      onPanUpdate: (details) {
        final normalized = Offset(
          details.localPosition.dx / constraints.maxWidth,
          details.localPosition.dy / constraints.maxHeight,
        );
        setState(() {
          _drawCurrent = normalized;
        });
      },
      onPanEnd: (details) {
        if (_drawStart != null && _drawCurrent != null) {
          setState(() {
            final left = _drawStart!.dx < _drawCurrent!.dx
                ? _drawStart!.dx
                : _drawCurrent!.dx;
            final top = _drawStart!.dy < _drawCurrent!.dy
                ? _drawStart!.dy
                : _drawCurrent!.dy;
            final right = _drawStart!.dx > _drawCurrent!.dx
                ? _drawStart!.dx
                : _drawCurrent!.dx;
            final bottom = _drawStart!.dy > _drawCurrent!.dy
                ? _drawStart!.dy
                : _drawCurrent!.dy;

            _dropletBoundingBox = Rect.fromLTRB(left, top, right, bottom);
            _drawStart = null;
            _drawCurrent = null;
          });
        }
      },
      child: CustomPaint(
        painter: _DrawingPainter(
          start: _drawStart != null
              ? Offset(_drawStart!.dx * constraints.maxWidth,
                  _drawStart!.dy * constraints.maxHeight)
              : null,
          current: _drawCurrent != null
              ? Offset(_drawCurrent!.dx * constraints.maxWidth,
                  _drawCurrent!.dy * constraints.maxHeight)
              : null,
          existingBox: _dropletBoundingBox,
          containerSize: Size(constraints.maxWidth, constraints.maxHeight),
        ),
        size: Size(constraints.maxWidth, constraints.maxHeight),
      ),
    );
  }

  Widget _buildGrip() {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.yellowAccent.withValues(alpha: 0.25),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
              color: Colors.yellowAccent, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

// ── Circle button widget ───────────────────────────────────────────────────────
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? NatureColors.accent.withValues(alpha: 0.3)
              : NatureColors.muted.withValues(alpha: 0.6),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

// ── Mode selection card ────────────────────────────────────────────────────────
class _ModeSelectionCard extends StatelessWidget {
  const _ModeSelectionCard({
    required this.mode,
    required this.icon,
    required this.title,
    required this.description,
    required this.features,
    this.recommended = false,
  });

  final CalibrationMode mode;
  final IconData icon;
  final String title;
  final String description;
  final List<String> features;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.pop(context, mode),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: recommended
              ? NatureColors.accent.withValues(alpha: 0.08)
              : NatureColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: recommended
                ? NatureColors.accent.withValues(alpha: 0.3)
                : NatureColors.border,
            width: recommended ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: recommended
                        ? NatureColors.natureGradient
                        : LinearGradient(
                            colors: [
                              NatureColors.muted,
                              NatureColors.muted.withValues(alpha: 0.7),
                            ],
                          ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: GoogleFonts.outfit(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: NatureColors.cardForeground,
                            ),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                gradient: NatureColors.natureGradient,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Lab',
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: NatureColors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...features.map((feature) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: recommended
                            ? NatureColors.accent
                            : NatureColors.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          feature,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: NatureColors.cardForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

// ── Drawing painter ────────────────────────────────────────────────────────────
class _DrawingPainter extends CustomPainter {
  final Offset? start;
  final Offset? current;
  final Rect? existingBox;
  final Size containerSize;

  _DrawingPainter({
    this.start,
    this.current,
    this.existingBox,
    required this.containerSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    // Draw existing box if present
    if (existingBox != null) {
      final rect = Rect.fromLTRB(
        existingBox!.left * containerSize.width,
        existingBox!.top * containerSize.height,
        existingBox!.right * containerSize.width,
        existingBox!.bottom * containerSize.height,
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, paint);

      // Draw corner handles
      final handlePaint = Paint()
        ..color = Colors.greenAccent
        ..style = PaintingStyle.fill;
      final handleRadius = 6.0;

      canvas.drawCircle(rect.topLeft, handleRadius, handlePaint);
      canvas.drawCircle(rect.topRight, handleRadius, handlePaint);
      canvas.drawCircle(rect.bottomLeft, handleRadius, handlePaint);
      canvas.drawCircle(rect.bottomRight, handleRadius, handlePaint);
    }

    // Draw current dragging box
    if (start != null && current != null) {
      final rect = Rect.fromPoints(start!, current!);
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_DrawingPainter oldDelegate) {
    return oldDelegate.start != start ||
        oldDelegate.current != current ||
        oldDelegate.existingBox != existingBox;
  }
}
