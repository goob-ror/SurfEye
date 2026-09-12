// ignore_for_file: unused_field

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/services/api_service.dart';
import 'package:surfeye_app/services/calibration_storage.dart';
import 'package:surfeye_app/services/database_service.dart';

// ── Design tokens ──────────────────────────────────────────────────────────────
class _C {
  static const bg       = Color(0xFF0A0F1A);
  static const surface  = Color(0xFF111827);
  static const surface2 = Color(0xFF1C2333);
  static const border   = Color(0xFF1F2937);
  static const blue     = Color(0xFF3B82F6);
  static const blueD    = Color(0xFF2563EB);
  static const green    = Color(0xFF10B981);
  static const yellow   = Color(0xFFFACC15);
  static const text     = Color(0xFFF9FAFB);
  static const muted    = Color(0xFF9CA3AF);
  static const dim      = Color(0xFF374151);
}

// ── Which bottom sheet is open ─────────────────────────────────────────────────
enum _Sheet { none, image, baseline, more }

// ── WCA computation result ─────────────────────────────────────────────────────
class _WcaResult {
  final double leftAngle;
  final double rightAngle;
  /// Contact point on baseline (normalised 0-1 of image)
  final Offset leftContact;
  final Offset rightContact;
  /// Tangent unit vectors pointing upward into the droplet
  final Offset leftTangent;
  final Offset rightTangent;

  const _WcaResult({
    required this.leftAngle,
    required this.rightAngle,
    required this.leftContact,
    required this.rightContact,
    required this.leftTangent,
    required this.rightTangent,
  });

  double get avgAngle => (leftAngle + rightAngle) / 2;
}

// ══════════════════════════════════════════════════════════════════════════════
//  Screen
// ══════════════════════════════════════════════════════════════════════════════

class CalibrationScreen extends StatefulWidget {
  final String imagePath;
  const CalibrationScreen({super.key, required this.imagePath});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen>
    with TickerProviderStateMixin {

  // ── Image meta ────────────────────────────────────────────────────────────
  double? _imageWidth;
  double? _imageHeight;
  bool _imageLoaded = false;

  // ── Baseline ──────────────────────────────────────────────────────────────
  double _baselinePxY = 0;
  bool _isDetectingBaseline = false;
  bool _isBaselineLocked = false;

  // ── Droplet bounding box (normalised 0-1) ─────────────────────────────────
  Rect? _dropletBox;
  bool _isDrawingRegion = false;
  Offset? _drawStart;
  Offset? _drawCurrent;

  // ── Ellipse (normalised 0-1 of image size) ────────────────────────────────
  // [cx, cy, semi_a, semi_b, angle_deg]
  List<double>? _ellipse;
  double _ellipseBaseA = 1.0;
  double _ellipseBaseB = 1.0;
  bool _isDetectingEllipse = false;
  bool _isAnalyzing = false;

  // ── WCA overlay computed client-side after detect ─────────────────────────
  _WcaResult? _wcaResult;

  // Ellipse drag
  int? _dragHandle;
  Offset? _dragOrigin;
  List<double>? _ellipseSnap;

  // ── Image settings ────────────────────────────────────────────────────────
  int    _brightness      = 0;     // [-100, 100]
  double _contrast        = 1.0;   // [0.5, 3.0]
  int    _sharpness       = 0;     // [-50, 50]
  int    _edgeSensitivity = 50;    // sent to server

  // Ellipse fine-tune
  double _ellipseAngle  = 0.0;
  double _ellipseScaleA = 1.0;
  double _ellipseScaleB = 1.0;

  // Manual pixel inputs
  final _bxCtrl   = TextEditingController();
  final _byCtrl   = TextEditingController();
  final _bsaCtrl  = TextEditingController();
  final _bsbCtrl  = TextEditingController();
  final _bangCtrl = TextEditingController();
  final _blCtrl   = TextEditingController();

  // ── UI state ──────────────────────────────────────────────────────────────
  _Sheet _openSheet = _Sheet.none;
  late AnimationController _sheetAnim;

  final _baselineInputCtrl = TextEditingController();

  // ── Processed image bytes for client-side rendering ───────────────────────
  // Null = still loading; not-null = ready to display
  Uint8List? _rawImageBytes;

  @override
  void initState() {
    super.initState();
    _sheetAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _loadImage();
  }

  @override
  void dispose() {
    _sheetAnim.dispose();
    for (final c in [_bxCtrl, _byCtrl, _bsaCtrl, _bsbCtrl, _bangCtrl,
                     _blCtrl, _baselineInputCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Load & decode image ────────────────────────────────────────────────────

  Future<void> _loadImage() async {
    try {
      Uint8List bytes;
      if (kIsWeb) {
        final r = await http.get(Uri.parse(widget.imagePath));
        bytes = r.bodyBytes;
      } else {
        bytes = await File(widget.imagePath).readAsBytes();
      }
      final decoded = await decodeImageFromList(bytes);
      if (!mounted) return;
      setState(() {
        _rawImageBytes   = bytes;
        _imageWidth      = decoded.width.toDouble();
        _imageHeight     = decoded.height.toDouble();
        _baselinePxY     = _imageHeight! * 0.65;
        _imageLoaded     = true;
      });
      _detectBaseline();
    } catch (_) {
      if (mounted) setState(() => _imageLoaded = true);
    }
  }

  Future<void> _detectBaseline() async {
    if (_imageHeight == null) return;
    setState(() => _isDetectingBaseline = true);
    try {
      final r = await ApiService.detectBaseline(widget.imagePath);
      if (!mounted) return;
      final py = (r?['detected_baseline_y'] as num?)?.toDouble();
      if (py != null) {
        setState(() {
          _baselinePxY = py.clamp(0, _imageHeight! - 1);
          _blCtrl.text = _baselinePxY.toStringAsFixed(0);
        });
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isDetectingBaseline = false);
    }
  }

  // ── Client-side colour matrix ──────────────────────────────────────────────
  /// Builds a 4×5 RGBA colour matrix that applies:
  ///   • grayscale conversion
  ///   • brightness offset  (–100 … +100, mapped to –1 … +1 in 0-1 space)
  ///   • contrast multiplier (0.5 … 3.0)
  ///   • sharpness is handled separately via an [ImageFilter.blur] trick
  ///     (negative blur = unsharp mask, approximated with the convolution below)
  List<double> _buildColorMatrix() {
    // Grayscale weights (luminance)
    const rl = 0.2126, gl = 0.7152, bl = 0.0722;

    // Contrast: scale each channel around 0.5 mid-point
    final c  = _contrast;
    final t  = (1.0 - c) / 2.0;

    // Brightness: add as a constant offset in [0..1] space
    final b  = _brightness / 255.0;

    // Combined: gray * contrast + brightness_offset
    // Row order: [R, G, B, A, offset]
    return [
      rl*c, gl*c, bl*c, 0, t + b,
      rl*c, gl*c, bl*c, 0, t + b,
      rl*c, gl*c, bl*c, 0, t + b,
      0,    0,    0,    1, 0,
    ];
  }

  // ── Droplet detection ──────────────────────────────────────────────────────

  Future<void> _detectDroplet() async {
    if (!_imageLoaded || _imageHeight == null || _imageWidth == null) return;
    _closeSheet();
    setState(() { _isDetectingEllipse = true; _wcaResult = null; });

    Rect? pixelBbox;
    if (_dropletBox != null) {
      pixelBbox = Rect.fromLTRB(
        _dropletBox!.left   * _imageWidth!,
        _dropletBox!.top    * _imageHeight!,
        _dropletBox!.right  * _imageWidth!,
        _dropletBox!.bottom * _imageHeight!,
      );
    }

    try {
      final r = await ApiService.detectDroplet(
        widget.imagePath,
        baselineY:       _baselinePxY.toInt(),
        dropletBbox:     pixelBbox,
        brightness:      _brightness,
        contrast:        _contrast,
        edgeSensitivity: _edgeSensitivity,
      );
      if (!mounted) return;
      if (r == null) {
        _showSnack('Tetesan tidak terdeteksi. Sesuaikan pengaturan.');
        return;
      }

      final cx = (r['cx'] as num?)?.toDouble();
      final cy = (r['cy'] as num?)?.toDouble();
      final sa = (r['semi_a'] as num?)?.toDouble();
      final sb = (r['semi_b'] as num?)?.toDouble();
      final ag = (r['angle_deg'] as num?)?.toDouble() ?? 0.0;

      if (cx == null || cy == null || sa == null || sb == null) {
        _showSnack('Server tidak mengembalikan parameter elips yang valid.');
        return;
      }

      final nA = sa / _imageWidth!;
      final nB = sb / _imageHeight!;

      // Build normalised ellipse and compute WCA immediately
      final ellipse = [cx / _imageWidth!, cy / _imageHeight!, nA, nB, ag];
      final wca = _computeWca(ellipse, _baselinePxY);

      setState(() {
        _ellipse      = ellipse;
        _ellipseBaseA = nA;
        _ellipseBaseB = nB;
        _ellipseAngle = ag;
        _ellipseScaleA = 1.0;
        _ellipseScaleB = 1.0;
        _wcaResult    = wca;
        // Sync manual text fields
        _bxCtrl.text   = cx.toStringAsFixed(1);
        _byCtrl.text   = cy.toStringAsFixed(1);
        _bsaCtrl.text  = sa.toStringAsFixed(1);
        _bsbCtrl.text  = sb.toStringAsFixed(1);
        _bangCtrl.text = ag.toStringAsFixed(1);
      });

      if (wca == null) {
        _showSnack('Tetesan terdeteksi tetapi WCA tidak dapat dihitung. Sesuaikan baseline.');
      }
    } catch (e) {
      if (mounted) _showSnack('Kesalahan: $e');
    } finally {
      if (mounted) setState(() => _isDetectingEllipse = false);
    }
  }

  // ── WCA computation (port of test2.py compute_wca) ─────────────────────────
  /// [ellipse] = [cx_norm, cy_norm, semi_a_norm, semi_b_norm, angle_deg]
  ///   All spatial values are normalised to [0..1] of the IMAGE dimensions.
  /// [baselinePxY] is the absolute pixel row in the original image.
  _WcaResult? _computeWca(List<double> ellipse, double baselinePxY) {
    if (_imageWidth == null || _imageHeight == null) return null;

    // Convert normalised ellipse back to pixel coords for the calculation
    final cx = ellipse[0] * _imageWidth!;
    final cy = ellipse[1] * _imageHeight!;
    final a  = ellipse[2] * _imageWidth!;
    final b  = ellipse[3] * _imageHeight!;
    final ar = ellipse[4] * math.pi / 180.0;

    final cosA = math.cos(ar);
    final sinA = math.sin(ar);

    // ── 1. Find intersections of the ellipse with y = baselinePxY ─────────
    const int n = 4000;
    final List<_CrossPoint> crossings = [];

    double prevDy = double.nan;
    for (int i = 0; i <= n; i++) {
      final t = 2 * math.pi * i / n;
      final ey = cy + a * math.cos(t) * sinA + b * math.sin(t) * cosA;
      final dy = ey - baselinePxY;
      if (!prevDy.isNaN && prevDy * dy < 0) {
        // Linear interpolation
        final t0 = 2 * math.pi * (i - 1) / n;
        final t1 = 2 * math.pi * i / n;
        final dy0 = prevDy;
        final frac = dy0 / (dy0 - dy);
        final ti = t0 + frac * (t1 - t0);
        final xi = cx + a * math.cos(ti) * cosA - b * math.sin(ti) * sinA;
        crossings.add(_CrossPoint(x: xi, y: baselinePxY, t: ti));
      }
      prevDy = dy;
    }

    if (crossings.length < 2) return null;

    // Keep outermost left / right
    crossings.sort((a, b) => a.x.compareTo(b.x));
    final lp = crossings.first;
    final rp = crossings.last;

    // ── 2. Tangent vectors at each crossing ───────────────────────────────
    Offset tangentAt(double t) {
      final dx = -a * math.sin(t) * cosA - b * math.cos(t) * sinA;
      final dy = -a * math.sin(t) * sinA + b * math.cos(t) * cosA;
      return Offset(dx, dy);
    }

    // Orient tangent to point upward into the droplet (dy < 0 in image coords)
    Offset orientInto(Offset v) => v.dy > 0 ? Offset(-v.dx, -v.dy) : v;

    final lt = orientInto(tangentAt(lp.t));
    final rt = orientInto(tangentAt(rp.t));

    // ── 3. Contact angle ──────────────────────────────────────────────────
    double contactAngle(Offset tangent, String side) {
      final mag = tangent.distance;
      final ndx = tangent.dx / mag;
      final cosTheta = side == 'left' ? ndx : -ndx;
      return math.acos(cosTheta.clamp(-1.0, 1.0)) * 180.0 / math.pi;
    }

    final leftDeg  = contactAngle(lt, 'left');
    final rightDeg = contactAngle(rt, 'right');

    // Convert contact points and tangents to normalised coords
    return _WcaResult(
      leftAngle:    leftDeg,
      rightAngle:   rightDeg,
      leftContact:  Offset(lp.x / _imageWidth!, lp.y / _imageHeight!),
      rightContact: Offset(rp.x / _imageWidth!, rp.y / _imageHeight!),
      leftTangent:  Offset(lt.dx / lt.distance, lt.dy / lt.distance),
      rightTangent: Offset(rt.dx / rt.distance, rt.dy / rt.distance),
    );
  }

  // ── Full analysis ──────────────────────────────────────────────────────────

  Future<void> _analyze() async {
    if (!_imageLoaded || _imageHeight == null) return;
    setState(() => _isAnalyzing = true);
    try {
      // If the user already detected / dragged the ellipse, send those pixel
      // coords so the server skips auto-detection (avoids 422 on good images).
      double? ellipseCxPx, ellipseCyPx, ellipseSemiAPx, ellipseSemiBPx;
      if (_ellipse != null && _imageWidth != null && _imageHeight != null) {
        ellipseCxPx    = _ellipse![0] * _imageWidth!;
        ellipseCyPx    = _ellipse![1] * _imageHeight!;
        ellipseSemiAPx = _ellipse![2] * _imageWidth!;
        ellipseSemiBPx = _ellipse![3] * _imageHeight!;
      }

      final r = await ApiService.analyzeImage(
        widget.imagePath,
        baselineY:       _baselinePxY.toInt(),
        dropletBbox:     _dropletBox,
        brightness:      _brightness,
        contrast:        _contrast,
        edgeSensitivity: _edgeSensitivity,
        cx:              ellipseCxPx,
        cy:              ellipseCyPx,
        semiA:           ellipseSemiAPx,
        semiB:           ellipseSemiBPx,
        ellipseAngle:    _ellipseAngle  != 0.0 ? _ellipseAngle  : null,
        ellipseScaleA:   _ellipseScaleA != 1.0 ? _ellipseScaleA : null,
        ellipseScaleB:   _ellipseScaleB != 1.0 ? _ellipseScaleB : null,
      );
      if (!mounted) return;
      if (r == null) {
        setState(() => _isAnalyzing = false);
        _showSnack('Analisis gagal. Coba deteksi ulang tetesan.');
        return;
      }

      final angle    = ((r['average_angle'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 180.0);
      final surface  = r['classification'] as String? ?? 'Tidak Diketahui';
      final annPath  = r['annotated_image_path'] as String? ?? widget.imagePath;
      final edgePath = r['edge_image_path'] as String?;

      final m = Measurement(
        id: 0, angle: angle, surface: surface,
        timestamp: DateTime.now(), imagePath: annPath,
        edgeImagePath: edgePath,
        leftAngle:       (r['left_angle']          as num?)?.toDouble(),
        rightAngle:      (r['right_angle']         as num?)?.toDouble(),
        bondNumber:      (r['bond_number']         as num?)?.toDouble(),
        method:          r['method']               as String?,
        dropletWidthPx:  (r['droplet_width_px']   as num?)?.toDouble(),
        dropletHeightPx: (r['droplet_height_px']  as num?)?.toDouble(),
        fitResidualRms:  (r['fit_residual_rms_px'] as num?)?.toDouble(),
      );

      final saved = await DatabaseService.instance.insertMeasurement(m);

      if (mounted) {
        final router = GoRouter.of(context);
        await _promptSaveDefaults();
        if (mounted) router.go('/results', extra: {'measurement': saved});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAnalyzing = false);
        _showSnack('Terjadi kesalahan: $e');
      }
    }
  }

  // ── Ellipse handle drag ────────────────────────────────────────────────────

  static const double _kHR = 14.0;

  List<Offset> _handlePositions(Size sz) {
    if (_ellipse == null) return [];
    final cx = _ellipse![0] * sz.width;
    final cy = _ellipse![1] * sz.height;
    final a  = _ellipse![2] * sz.width;
    final b  = _ellipse![3] * sz.height;
    final ar = _ellipse![4] * math.pi / 180.0;
    final c  = math.cos(ar), s = math.sin(ar);
    return [
      Offset(cx, cy),
      Offset(cx + a*c, cy + a*s),
      Offset(cx - a*c, cy - a*s),
      Offset(cx - b*s, cy + b*c),
      Offset(cx + b*s, cy - b*c),
    ];
  }



  void _ellipsePanUpdateDelta(Offset delta, Size sz) {
    if (_dragHandle == null || _ellipseSnap == null) return;
    final base = _ellipseSnap!;
    final dx   = delta.dx / sz.width;
    final dy   = delta.dy / sz.height;
    final ar   = base[4] * math.pi / 180.0;
    final c    = math.cos(ar), s = math.sin(ar);
    setState(() {
      switch (_dragHandle) {
        case 0:
          _ellipse![0] = (_ellipse![0] + dx).clamp(0.0, 1.0);
          _ellipse![1] = (_ellipse![1] + dy).clamp(0.0, 1.0);
          _ellipseSnap = List.from(_ellipse!);
        case 1:
        case 2:
          final sign = _dragHandle == 1 ? 1.0 : -1.0;
          final newA = (_ellipse![2] + (dx*c + dy*s)*sign).clamp(0.02, 1.0);
          _ellipse![2] = newA;
          _ellipseBaseA = newA;
          _ellipseScaleA = 1.0;
          _bsaCtrl.text = (newA * _imageWidth!).toStringAsFixed(1);
          _ellipseSnap = List.from(_ellipse!);
        case 3:
        case 4:
          final sign = _dragHandle == 4 ? 1.0 : -1.0;
          final newB = (_ellipse![3] + (-dx*s + dy*c)*sign).clamp(0.02, 1.0);
          _ellipse![3] = newB;
          _ellipseBaseB = newB;
          _ellipseScaleB = 1.0;
          _bsbCtrl.text = (newB * _imageHeight!).toStringAsFixed(1);
          _ellipseSnap = List.from(_ellipse!);
      }
      _wcaResult = _computeWca(_ellipse!, _baselinePxY);
    });
  }



  void _applyManualEllipse() {
    if (_imageWidth == null || _imageHeight == null) return;
    final cx = double.tryParse(_bxCtrl.text);
    final cy = double.tryParse(_byCtrl.text);
    final sa = double.tryParse(_bsaCtrl.text);
    final sb = double.tryParse(_bsbCtrl.text);
    final ag = double.tryParse(_bangCtrl.text) ?? 0.0;
    if (cx == null || cy == null || sa == null || sb == null) return;
    final nA = sa / _imageWidth!, nB = sb / _imageHeight!;
    final ellipse = [cx / _imageWidth!, cy / _imageHeight!, nA, nB, ag];
    setState(() {
      _ellipse      = ellipse;
      _ellipseBaseA = nA;
      _ellipseBaseB = nB;
      _ellipseAngle = ag;
      _ellipseScaleA = 1.0;
      _ellipseScaleB = 1.0;
      _wcaResult    = _computeWca(ellipse, _baselinePxY);
    });
  }

  void _applyManualBaseline() {
    final v = double.tryParse(_blCtrl.text);
    if (v != null && _imageHeight != null) {
      setState(() {
        _baselinePxY = v.clamp(0, _imageHeight! - 1);
        if (_ellipse != null) {
          _wcaResult = _computeWca(_ellipse!, _baselinePxY);
        }
      });
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  void _closeSheet() {
    if (_openSheet != _Sheet.none) setState(() => _openSheet = _Sheet.none);
  }

  void _toggleSheet(_Sheet s) {
    setState(() => _openSheet = (_openSheet == s) ? _Sheet.none : s);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter(fontSize: 13)),
      backgroundColor: _C.surface2,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _promptSaveDefaults() async {
    final save = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: _C.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4, decoration: BoxDecoration(
              color: _C.dim, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          Icon(Icons.bookmark_add_outlined, color: _C.blue, size: 36),
          const SizedBox(height: 12),
          Text('Simpan sebagai default?',
              style: GoogleFonts.outfit(fontSize: 18,
                  fontWeight: FontWeight.w700, color: _C.text)),
          const SizedBox(height: 8),
          Text('Pengaturan kalibrasi ini akan dipakai otomatis di pengambilan berikutnya.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: _C.muted)),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              style: OutlinedButton.styleFrom(
                  side: BorderSide(color: _C.dim),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text('Lewati', style: GoogleFonts.inter(
                  color: _C.muted, fontWeight: FontWeight.w600, fontSize: 14)),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _C.blue,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0),
              child: Text('Simpan', style: GoogleFonts.inter(
                  color: Colors.white, fontWeight: FontWeight.w700,
                  fontSize: 14)),
            )),
          ]),
        ]),
      ),
    );
    if (save == true && mounted) {
      await CalibrationStorage.saveDefaults(
        _baselinePxY / (_imageHeight ?? 1.0),
        _dropletBox,
        brightness:      _brightness != 0       ? _brightness      : null,
        contrast:        _contrast   != 1.0     ? _contrast        : null,
        edgeSensitivity: _edgeSensitivity != 50 ? _edgeSensitivity : null,
        ellipseAngle:    _ellipseAngle  != 0.0  ? _ellipseAngle    : null,
        ellipseScaleA:   _ellipseScaleA != 1.0  ? _ellipseScaleA   : null,
        ellipseScaleB:   _ellipseScaleB != 1.0  ? _ellipseScaleB   : null,
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) { if (!did) context.go('/'); },
      child: Scaffold(
        backgroundColor: _C.bg,
        body: GestureDetector(
          onTap: _closeSheet,
          behavior: HitTestBehavior.translucent,
          child: Stack(children: [

            // ── Full-screen image viewer + overlays (zoomable) ──────────
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 5.0,
                child: Stack(alignment: Alignment.center, children: [
                  Positioned.fill(child: _buildViewer()),
                  if (_imageWidth != null && _imageHeight != null)
                    AspectRatio(
                      aspectRatio: _imageWidth! / _imageHeight!,
                      child: _buildOverlays(),
                    ),
                ]),
              ),
            ),

            // ── Top bar ──────────────────────────────────────────────────
            Positioned(
              top: mq.padding.top,
              left: 0, right: 0,
              child: _buildTopBar(),
            ),

            // ── Bottom toolbar ─────────────────────────────────────────────
            Positioned(
              left: 0, right: 0,
              bottom: mq.padding.bottom + 60,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_openSheet != _Sheet.none) _buildSheet(_openSheet),
                  _buildToolbar(),
                ],
              ),
            ),

            // ── Global busy overlay ───────────────────────────────────────
            if (_isAnalyzing) Positioned.fill(child: _buildBusyOverlay()),
          ]),
        ),
      ),
    );
  }

  // ── Top bar ────────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [_C.bg.withValues(alpha: 0.92), _C.bg.withValues(alpha: 0.0)],
        ),
      ),
      child: Row(children: [
        _TopBtn(icon: Icons.arrow_back_ios_new_rounded,
            onTap: () => context.go('/')),
        const Spacer(),
        Text('Kalibrasi',
            style: GoogleFonts.outfit(
                color: _C.text, fontSize: 17, fontWeight: FontWeight.w600)),
        const Spacer(),
        _isAnalyzing
            ? const SizedBox(width: 44, height: 44,
                child: Center(child: SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: Color(0xFF10B981), strokeWidth: 2.5))))
            : _TopBtn(
                icon: Icons.check_rounded,
                onTap: (_isDetectingEllipse || !_imageLoaded) ? null : _analyze,
                accent: _C.green,
              ),
      ]),
    );
  }

  // ── Image viewer — client-side grayscale + brightness/contrast/sharpness ──
  Widget _buildViewer() {
    if (!_imageLoaded) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF3B82F6)));
    }

    // Build the colour matrix for grayscale + brightness + contrast
    final matrix = _buildColorMatrix();

    // Sharpness: positive = unsharp mask (sharpen), negative = soften
    // Approximate with a backdrop blur — positive sharpness means we want
    // the opposite of blur so we compose: sharp = original + (original − blurred).
    // Flutter doesn't have unsharp mask natively, so we use a subtle
    // BackdropFilter only for softening (negative sharpness).
    final double blurSigma = _sharpness < 0
        ? (-_sharpness / 50.0) * 3.0   // 0 .. 3 px blur
        : 0.0;

    Widget imageWidget;

    if (_rawImageBytes != null && !kIsWeb) {
      imageWidget = Image.memory(_rawImageBytes!, fit: BoxFit.contain);
    } else if (kIsWeb) {
      imageWidget = Image.network(widget.imagePath, fit: BoxFit.contain);
    } else {
      imageWidget = Image.file(File(widget.imagePath), fit: BoxFit.contain);
    }

    // Wrap in Container, InteractiveViewer handles the zooming parent
    return Container(
      color: _C.bg,
      child: Center(
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(matrix),
          child: blurSigma > 0
              ? ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                      sigmaX: blurSigma, sigmaY: blurSigma),
                  child: imageWidget,
                )
              : imageWidget,
        ),
      ),
    );
  }

  // ── Overlays ───────────────────────────────────────────────────────────────
  Widget _buildOverlays() {
    return LayoutBuilder(builder: (ctx, box) {
      final sz = box.biggest;
      final screenBaselineY = _imagePxToScreenY(_baselinePxY, sz);
      return Stack(children: [

        // Bounding box
        if (_dropletBox != null && !_isDrawingRegion)
          Positioned.fill(child: Stack(children: [
            SizedBox.expand(
              child: CustomPaint(painter: _BoxPainter(box: _dropletBox!, size: sz)),
            ),
            Positioned(
              left: _dropletBox!.right * sz.width,
              top: _dropletBox!.top * sz.height,
              child: GestureDetector(
                onTap: () => setState(() => _dropletBox = null),
                behavior: HitTestBehavior.opaque,
                child: Transform.translate(
                  offset: const Offset(-12, -12),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ),
          ])),

        // (Drawing canvas moved below ellipse handles so it stays on top)

        // Baseline drag strip (Moved below ellipse for Z-index)
        if (screenBaselineY != null)
          Positioned(
            top: screenBaselineY - 22,
            left: 0, right: 0, height: 44,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: _isBaselineLocked ? null : (d) {
                final dpxPerScreenPx = _imageHeight! / sz.height;
                setState(() {
                  _baselinePxY = (_baselinePxY + d.delta.dy * dpxPerScreenPx)
                      .clamp(0, _imageHeight! - 1);
                  _blCtrl.text = _baselinePxY.toStringAsFixed(0);
                  if (_ellipse != null) {
                    _wcaResult = _computeWca(_ellipse!, _baselinePxY);
                  }
                });
              },
              child: Stack(alignment: Alignment.center, children: [
                Container(height: 2, color: _C.yellow),
                Positioned(
                  left: 10,
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _isBaselineLocked = !_isBaselineLocked),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _C.yellow.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            _isBaselineLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                            size: 14,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _C.yellow.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'baseline  ${_baselinePxY.toStringAsFixed(0)} px',
                          style: GoogleFonts.inter(
                              fontSize: 10, fontWeight: FontWeight.w700,
                              color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(right: 12,
                    child: Icon(Icons.drag_handle_rounded,
                        color: _C.yellow.withValues(alpha: 0.9), size: 20)),
              ]),
            ),
          ),

        // Ellipse drawing
        if (_ellipse != null)
          Positioned.fill(child: CustomPaint(
            painter: _EllipsePainter(
              ellipse:   _ellipse!,
              size:      sz,
              wcaResult: _wcaResult,
              baselineNormY: _imageHeight != null
                  ? _baselinePxY / _imageHeight!
                  : 0.65,
            ),
          )),

        // Ellipse gesture handles — only active when NOT drawing a region
        if (_ellipse != null && !_isDrawingRegion)
          ..._handlePositions(sz).asMap().entries.map((e) {
            final i = e.key;
            final pos = e.value;
            final hitSize = i == 0 ? 44.0 : 36.0;
            return Positioned(
              left: pos.dx - hitSize / 2,
              top: pos.dy - hitSize / 2,
              width: hitSize,
              height: hitSize,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => setState(() {
                  _dragHandle = i;
                  // Store absolute handle center as origin for delta tracking
                  _dragOrigin = pos;
                  _ellipseSnap = List.from(_ellipse!);
                }),
                onPanUpdate: (d) {
                  // Accumulate delta from the handle center (absolute coords)
                  final newOrigin = _dragOrigin! + d.delta;
                  _dragOrigin = newOrigin;
                  // Build an absolute position = last origin, pass to updater
                  _ellipsePanUpdateDelta(d.delta, sz);
                },
                onPanEnd: (_) => setState(() {
                  _dragHandle = null;
                  _dragOrigin = null;
                  _ellipseSnap = null;
                }),
              ),
            );
          }),

        // Drawing canvas — on TOP so region draw always works
        if (_isDrawingRegion)
          Positioned.fill(child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart:  (d) => setState(() {
              _drawStart   = _screenToNorm(d.localPosition, sz);
              _drawCurrent = _drawStart;
            }),
            onPanUpdate: (d) => setState(() =>
                _drawCurrent = _screenToNorm(d.localPosition, sz)),
            onPanEnd: (_) {
              if (_drawStart != null && _drawCurrent != null) {
                final l = math.min(_drawStart!.dx, _drawCurrent!.dx);
                final t = math.min(_drawStart!.dy, _drawCurrent!.dy);
                final r = math.max(_drawStart!.dx, _drawCurrent!.dx);
                final b = math.max(_drawStart!.dy, _drawCurrent!.dy);
                setState(() {
                  _dropletBox      = Rect.fromLTRB(l, t, r, b);
                  _isDrawingRegion = false;
                  _drawStart = _drawCurrent = null;
                });
              }
            },
            child: SizedBox.expand(
              child: CustomPaint(
                painter: _BoxPainter(
                  box: _drawStart != null && _drawCurrent != null
                      ? Rect.fromPoints(_drawStart!, _drawCurrent!)
                      : null,
                  existing: _dropletBox,
                  size: sz,
                  drawing: true,
                ),
              ),
            ),
          )),

        // WCA result badge (top-left, appears after detect)
        // WCA result badge — top center
        if (_wcaResult != null)
          Positioned(
            top: 10, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF4B0082).withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: const Color(0xFFAA44FF).withValues(alpha: 0.6)),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF9933FF).withValues(alpha: 0.3),
                        blurRadius: 12, offset: const Offset(0, 3))
                  ],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.water_drop_outlined,
                      color: Color(0xFFCC88FF), size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'WCA  ${_wcaResult!.avgAngle.toStringAsFixed(1)}°'
                    '  (L ${_wcaResult!.leftAngle.toStringAsFixed(1)}°'
                    ' / R ${_wcaResult!.rightAngle.toStringAsFixed(1)}°)',
                    style: GoogleFonts.inter(
                        color: const Color(0xFFEEBBFF),
                        fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ]),
              ).animate().fadeIn(duration: 250.ms).slideY(begin: -0.3, end: 0, duration: 250.ms),
            ),
          ),

        // Ellipse detected badge — top center
        if (_ellipse != null && !_isDetectingEllipse && _wcaResult == null)
          Positioned(top: 10, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: _C.green.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _C.green.withValues(alpha: 0.5))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.radio_button_checked, color: _C.green, size: 11),
                  const SizedBox(width: 5),
                  Text('Elips terdeteksi',
                      style: GoogleFonts.inter(
                          color: _C.green, fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ]),
              ).animate().fadeIn(duration: 200.ms),
            )),
      ]);
    });
  }

  /// Converts image-pixel Y to screen Y for the InteractiveViewer content.
  double? _imagePxToScreenY(double pxY, Size containerSz) {
    if (_imageHeight == null || _imageWidth == null) return null;
    final scale = math.min(containerSz.width / _imageWidth!, containerSz.height / _imageHeight!);
    final scaledH = _imageHeight! * scale;
    final originY = (containerSz.height - scaledH) / 2;
    return originY + (pxY / _imageHeight!) * scaledH;
  }

  Offset _screenToNorm(Offset screen, Size sz) =>
      Offset(screen.dx / sz.width, screen.dy / sz.height);

  // ── Bottom toolbar ─────────────────────────────────────────────────────────
  Widget _buildToolbar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: _C.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _C.border),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _ToolBtn(
            icon: Icons.tune_rounded,
            label: 'Gambar',
            active: _openSheet == _Sheet.image,
            onTap: () => _toggleSheet(_Sheet.image),
          ),
          _ToolBtn(
            icon: _dropletBox != null
                ? Icons.crop_free_rounded
                : Icons.add_box_outlined,
            label: _dropletBox != null ? 'Region ✓' : 'Region',
            active: _isDrawingRegion,
            activeColor: _dropletBox != null ? _C.green : _C.blue,
            onTap: () {
              if (_isDrawingRegion) {
                setState(() {
                  _isDrawingRegion = false;
                  _drawStart = _drawCurrent = null;
                });
              } else {
                _closeSheet();
                setState(() => _isDrawingRegion = true);
              }
            },
          ),
          // Centre primary action — detect droplet
          GestureDetector(
            onTap: (_isDetectingEllipse || !_imageLoaded) ? null : _detectDroplet,
            child: Container(
              width: 58, height: 58,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: (_isDetectingEllipse || !_imageLoaded)
                        ? [_C.dim, _C.dim]
                        : [_C.blue, _C.blueD],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(
                    color: _C.blue.withValues(alpha: 0.35),
                    blurRadius: 12, offset: const Offset(0, 4))],
              ),
              child: _isDetectingEllipse
                  ? const Center(child: SizedBox(width: 22, height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5)))
                  : const Icon(Icons.search_rounded,
                      color: Colors.white, size: 26),
            ),
          ),
          _ToolBtn(
            icon: Icons.horizontal_rule_rounded,
            label: 'Baseline',
            active: _openSheet == _Sheet.baseline,
            onTap: () => _toggleSheet(_Sheet.baseline),
          ),
          _ToolBtn(
            icon: Icons.tune_outlined,
            label: 'Lainnya',
            active: _openSheet == _Sheet.more,
            onTap: () => _toggleSheet(_Sheet.more),
          ),
        ],
      ),
    );
  }

  // ── Sheet switcher ─────────────────────────────────────────────────────────
  Widget _buildSheet(_Sheet s) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _C.border),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: switch (s) {
          _Sheet.image    => _buildImageSheet(),
          _Sheet.baseline => _buildBaselineSheet(),
          _Sheet.more     => _buildMoreSheet(),
          _Sheet.none     => const SizedBox.shrink(),
        },
      ),
    ).animate()
      .slideY(begin: 0.15, end: 0, duration: 220.ms, curve: Curves.easeOut)
      .fadeIn(duration: 180.ms);
  }

  // ── Image settings sheet ───────────────────────────────────────────────────
  Widget _buildImageSheet() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _SheetHeader(
          title: 'Pengaturan Gambar',
          onReset: () => setState(() {
            _brightness = 0;
            _contrast   = 1.0;
            _sharpness  = 0;
            _edgeSensitivity = 50;
          }),
        ),
        const SizedBox(height: 12),
        _ParamRow(
          label: 'Kecerahan', icon: Icons.brightness_6_rounded,
          value: _brightness.toDouble(), min: -100, max: 100, divisions: 200,
          display: _brightness.toString(),
          onChanged: (v) => setState(() => _brightness = v.round()),
          inputCtrl: TextEditingController(text: _brightness.toString()),
          onInputSubmit: (s) {
            final v = int.tryParse(s);
            if (v != null) setState(() => _brightness = v.clamp(-100, 100));
          },
        ),
        _ParamRow(
          label: 'Kontras', icon: Icons.contrast_rounded,
          value: _contrast, min: 0.5, max: 3.0, divisions: 50,
          display: _contrast.toStringAsFixed(2),
          onChanged: (v) => setState(() => _contrast = v),
          inputCtrl: TextEditingController(text: _contrast.toStringAsFixed(2)),
          onInputSubmit: (s) {
            final v = double.tryParse(s);
            if (v != null) setState(() => _contrast = v.clamp(0.5, 3.0));
          },
        ),
        _ParamRow(
          label: 'Ketajaman', icon: Icons.auto_fix_high_rounded,
          value: _sharpness.toDouble(), min: -50, max: 50, divisions: 100,
          display: _sharpness.toString(),
          onChanged: (v) => setState(() {
            _sharpness = v.round();
            _edgeSensitivity = (50 + _sharpness).clamp(10, 150).toInt();
          }),
          inputCtrl: TextEditingController(text: _sharpness.toString()),
          onInputSubmit: (s) {
            final v = int.tryParse(s);
            if (v != null) {
              setState(() {
                _sharpness = v.clamp(-50, 50);
                _edgeSensitivity = (50 + _sharpness).clamp(10, 150).toInt();
              });
            }
          },
        ),
      ]),
    );
  }

  // ── Baseline sheet ─────────────────────────────────────────────────────────
  Widget _buildBaselineSheet() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _SheetHeader(
          title: 'Garis Dasar',
          trailing: _isDetectingBaseline
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF3B82F6)))
              : TextButton.icon(
                  onPressed: _detectBaseline,
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                  label: Text('Auto', style: GoogleFonts.inter(
                      fontSize: 12, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                      foregroundColor: _C.blue,
                      visualDensity: VisualDensity.compact),
                ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor:   _C.yellow,
              inactiveTrackColor: _C.dim,
              thumbColor:         _C.yellow,
              overlayColor: _C.yellow.withValues(alpha: 0.2),
              trackHeight: 3,
            ),
            child: Slider(
              value: _imageHeight != null
                  ? (_baselinePxY / _imageHeight!).clamp(0.0, 1.0) : 0.5,
              min: 0, max: 1,
              onChanged: (v) {
                setState(() {
                  _baselinePxY = v * (_imageHeight ?? 1.0);
                  _blCtrl.text = _baselinePxY.toStringAsFixed(0);
                  if (_ellipse != null) {
                    _wcaResult = _computeWca(_ellipse!, _baselinePxY);
                  }
                });
              },
            ),
          )),
          const SizedBox(width: 8),
          SizedBox(width: 76, child: _PxInput(
            ctrl: _blCtrl,
            hint: 'px Y',
            onSubmit: (_) => _applyManualBaseline(),
          )),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('0 px',
              style: GoogleFonts.inter(color: _C.muted, fontSize: 11)),
          Text('${_baselinePxY.toStringAsFixed(0)} px',
              style: GoogleFonts.inter(
                  color: _C.yellow, fontSize: 12,
                  fontWeight: FontWeight.w700)),
          Text('${(_imageHeight ?? 0).toStringAsFixed(0)} px',
              style: GoogleFonts.inter(color: _C.muted, fontSize: 11)),
        ]),
      ]),
    );
  }

  // ── More / ellipse fine-tune sheet ─────────────────────────────────────────
  Widget _buildMoreSheet() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _SheetHeader(
          title: 'Penyesuaian Elips',
          onReset: () => setState(() {
            _ellipseAngle  = 0;
            _ellipseScaleA = 1;
            _ellipseScaleB = 1;
            if (_ellipse != null) {
              _ellipse![4] = 0;
              _ellipse![2] = _ellipseBaseA;
              _ellipse![3] = _ellipseBaseB;
              _wcaResult = _computeWca(_ellipse!, _baselinePxY);
            }
          }),
        ),
        const SizedBox(height: 10),
        _ParamRow(
          label: 'Rotasi °', icon: Icons.rotate_right_rounded,
          value: _ellipseAngle, min: -45, max: 45, divisions: 180,
          display: _ellipseAngle.toStringAsFixed(1),
          onChanged: (v) => setState(() {
            _ellipseAngle = v;
            if (_ellipse != null) {
              _ellipse![4] = v;
              _wcaResult = _computeWca(_ellipse!, _baselinePxY);
            }
          }),
          inputCtrl: TextEditingController(
              text: _ellipseAngle.toStringAsFixed(1)),
          onInputSubmit: (s) {
            final v = double.tryParse(s);
            if (v != null) {
              setState(() {
                _ellipseAngle = v.clamp(-45, 45);
                if (_ellipse != null) {
                  _ellipse![4] = _ellipseAngle;
                  _wcaResult = _computeWca(_ellipse!, _baselinePxY);
                }
              });
            }
          },
        ),
        _ParamRow(
          label: 'Skala Lebar', icon: Icons.swap_horiz_rounded,
          value: _ellipseScaleA, min: 0.5, max: 2.0, divisions: 150,
          display: _ellipseScaleA.toStringAsFixed(2),
          onChanged: (v) => setState(() {
            _ellipseScaleA = v;
            if (_ellipse != null) {
              _ellipse![2] = _ellipseBaseA * v;
              _wcaResult = _computeWca(_ellipse!, _baselinePxY);
            }
          }),
          inputCtrl: TextEditingController(
              text: _ellipseScaleA.toStringAsFixed(2)),
          onInputSubmit: (s) {
            final v = double.tryParse(s);
            if (v != null) {
              setState(() {
                _ellipseScaleA = v.clamp(0.5, 2.0);
                if (_ellipse != null) {
                  _ellipse![2] = _ellipseBaseA * _ellipseScaleA;
                  _wcaResult = _computeWca(_ellipse!, _baselinePxY);
                }
              });
            }
          },
        ),
        _ParamRow(
          label: 'Skala Tinggi', icon: Icons.swap_vert_rounded,
          value: _ellipseScaleB, min: 0.5, max: 2.0, divisions: 150,
          display: _ellipseScaleB.toStringAsFixed(2),
          onChanged: (v) => setState(() {
            _ellipseScaleB = v;
            if (_ellipse != null) {
              _ellipse![3] = _ellipseBaseB * v;
              _wcaResult = _computeWca(_ellipse!, _baselinePxY);
            }
          }),
          inputCtrl: TextEditingController(
              text: _ellipseScaleB.toStringAsFixed(2)),
          onInputSubmit: (s) {
            final v = double.tryParse(s);
            if (v != null) {
              setState(() {
                _ellipseScaleB = v.clamp(0.5, 2.0);
                if (_ellipse != null) {
                  _ellipse![3] = _ellipseBaseB * _ellipseScaleB;
                  _wcaResult = _computeWca(_ellipse!, _baselinePxY);
                }
              });
            }
          },
        ),
        const SizedBox(height: 8),
        Divider(color: _C.border, height: 1),
        const SizedBox(height: 10),
        Text('Input Manual (px)', style: GoogleFonts.inter(
            color: _C.muted, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _PxInput(ctrl: _bxCtrl,   hint: 'cx')),
          const SizedBox(width: 6),
          Expanded(child: _PxInput(ctrl: _byCtrl,   hint: 'cy')),
          const SizedBox(width: 6),
          Expanded(child: _PxInput(ctrl: _bsaCtrl,  hint: 'semi-a')),
          const SizedBox(width: 6),
          Expanded(child: _PxInput(ctrl: _bsbCtrl,  hint: 'semi-b')),
          const SizedBox(width: 6),
          Expanded(child: _PxInput(ctrl: _bangCtrl, hint: 'angle')),
        ]),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity,
          child: ElevatedButton(
            onPressed: _applyManualEllipse,
            style: ElevatedButton.styleFrom(
                backgroundColor: _C.surface2,
                foregroundColor: _C.text,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                elevation: 0),
            child: Text('Terapkan Manual',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          )),
      ]),
    );
  }

  // ── Busy overlay ───────────────────────────────────────────────────────────
  Widget _buildBusyOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF3B82F6)),
        const SizedBox(height: 20),
        Text('Menghitung WCA...',
            style: GoogleFonts.outfit(color: Colors.white,
                fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Mohon tunggu',
            style: GoogleFonts.inter(color: Colors.white54, fontSize: 13)),
      ])),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  Helper: crossing point data class
// ══════════════════════════════════════════════════════════════════════════════

class _CrossPoint {
  final double x, y, t;
  const _CrossPoint({required this.x, required this.y, required this.t});
}

// ══════════════════════════════════════════════════════════════════════════════
//  SMALL WIDGETS
// ══════════════════════════════════════════════════════════════════════════════

class _TopBtn extends StatelessWidget {
  const _TopBtn({required this.icon, required this.onTap, this.accent});
  final IconData icon;
  final VoidCallback? onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final col = accent ?? Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: col.withValues(alpha: 0.3)),
        ),
        child: Icon(icon,
            color: onTap == null ? Colors.white38 : col, size: 20),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final col = active ? (activeColor ?? _C.blue) : _C.muted;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: active ? col.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: col, size: 22),
        ),
        const SizedBox(height: 2),
        Text(label, style: GoogleFonts.inter(
            fontSize: 10, fontWeight: FontWeight.w500, color: col)),
      ]),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.onReset, this.trailing});
  final String title;
  final VoidCallback? onReset;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(title, style: GoogleFonts.outfit(
          color: _C.text, fontSize: 14, fontWeight: FontWeight.w700)),
      const Spacer(),
      ?trailing,
      if (onReset != null)
        GestureDetector(
          onTap: onReset,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: _C.surface2,
                borderRadius: BorderRadius.circular(8)),
            child: Text('Reset', style: GoogleFonts.inter(
                color: _C.muted, fontSize: 11,
                fontWeight: FontWeight.w600)),
          ),
        ),
    ]);
  }
}

class _ParamRow extends StatelessWidget {
  const _ParamRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    required this.inputCtrl,
    required this.onInputSubmit,
  });
  final String label;
  final IconData icon;
  final double value, min, max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final TextEditingController inputCtrl;
  final ValueChanged<String> onInputSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(icon, color: _C.muted, size: 17),
        const SizedBox(width: 6),
        SizedBox(width: 72, child: Text(label,
            style: GoogleFonts.inter(
                color: _C.text, fontSize: 12,
                fontWeight: FontWeight.w500))),
        Expanded(child: SliderTheme(
          data: SliderThemeData(
            activeTrackColor:   _C.blue,
            inactiveTrackColor: _C.dim,
            thumbColor:         _C.blue,
            overlayColor: _C.blue.withValues(alpha: 0.15),
            trackHeight: 2.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
          ),
          child: Slider(
              value: value.clamp(min, max),
              min: min, max: max, divisions: divisions,
              onChanged: onChanged),
        )),
        SizedBox(width: 60, child: _PxInput(
          ctrl: inputCtrl, hint: display, onSubmit: onInputSubmit)),
      ]),
    );
  }
}

class _PxInput extends StatelessWidget {
  const _PxInput({required this.ctrl, required this.hint, this.onSubmit});
  final TextEditingController ctrl;
  final String hint;
  final ValueChanged<String>? onSubmit;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      keyboardType: const TextInputType.numberWithOptions(
          decimal: true, signed: true),
      textAlign: TextAlign.center,
      style: GoogleFonts.inter(
          color: _C.text, fontSize: 12, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(color: _C.muted, fontSize: 11),
        filled: true,
        fillColor: _C.surface2,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 6, vertical: 8),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _C.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _C.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _C.blue, width: 1.5)),
      ),
      onSubmitted: onSubmit,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  PAINTERS
// ══════════════════════════════════════════════════════════════════════════════

/// Bounding box overlay
class _BoxPainter extends CustomPainter {
  final Rect? box;
  final Rect? existing;
  final Size size;
  final bool drawing;

  const _BoxPainter({
    this.box, this.existing, required this.size, this.drawing = false,
  });

  @override
  void paint(Canvas canvas, Size sz) {
    final stroke = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.0;
    final fill   = Paint()..style = PaintingStyle.fill;

    void drawRect(Rect norm, Color c, {bool dashed = false}) {
      final r = Rect.fromLTRB(
        norm.left * sz.width,  norm.top * sz.height,
        norm.right * sz.width, norm.bottom * sz.height,
      );
      fill.color = c.withValues(alpha: 0.08);
      canvas.drawRect(r, fill);
      stroke.color = c;
      if (dashed) {
        _drawDashedRect(canvas, r, stroke);
      } else {
        canvas.drawRect(r, stroke);
      }
      final hp = Paint()..color = c..style = PaintingStyle.fill;
      for (final o in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
        canvas.drawCircle(o, 5, hp);
      }
    }

    if (existing != null) { drawRect(existing!, const Color(0xFF10B981)); }
    if (box != null)      { drawRect(box!,      const Color(0xFF3B82F6), dashed: drawing); }
  }

  void _drawDashedRect(Canvas canvas, Rect r, Paint p) {
    const dash = 8.0, gap = 5.0;
    void drawDashedLine(Offset a, Offset b) {
      final d = b - a;
      final len = d.distance;
      final dir = d / len;
      double pos = 0;
      while (pos < len) {
        final end = math.min(pos + dash, len);
        canvas.drawLine(a + dir * pos, a + dir * end, p);
        pos += dash + gap;
      }
    }
    drawDashedLine(r.topLeft,    r.topRight);
    drawDashedLine(r.topRight,   r.bottomRight);
    drawDashedLine(r.bottomRight, r.bottomLeft);
    drawDashedLine(r.bottomLeft,  r.topLeft);
  }

  @override
  bool shouldRepaint(_BoxPainter o) =>
      o.box != box || o.existing != existing || o.drawing != drawing;
}

// ── Ellipse + WCA overlay painter ─────────────────────────────────────────────
class _EllipsePainter extends CustomPainter {
  final List<double> ellipse;   // [cx_n, cy_n, a_n, b_n, angle_deg]
  final Size size;
  final _WcaResult? wcaResult;
  final double baselineNormY;   // normalised 0-1

  const _EllipsePainter({
    required this.ellipse,
    required this.size,
    this.wcaResult,
    required this.baselineNormY,
  });

  @override
  void paint(Canvas canvas, Size sz) {
    final cx   = ellipse[0] * sz.width;
    final cy   = ellipse[1] * sz.height;
    final a    = ellipse[2] * sz.width;
    final b    = ellipse[3] * sz.height;
    final ar   = ellipse[4] * math.pi / 180.0;
    final cosA = math.cos(ar), sinA = math.sin(ar);

    // ── Ellipse — thin semi-transparent stroke ───────────────────────────
    final glowPaint = Paint()
      ..color = const Color(0xFF10B981).withValues(alpha: 0.10)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    final linePaint = Paint()
      ..color = const Color(0xFF10B981).withValues(alpha: 0.70)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final ellipsePath = Path();
    const steps = 120;
    for (int i = 0; i <= steps; i++) {
      final t  = 2 * math.pi * i / steps;
      final ex = cx + a * math.cos(t) * cosA - b * math.sin(t) * sinA;
      final ey = cy + a * math.cos(t) * sinA + b * math.sin(t) * cosA;
      i == 0 ? ellipsePath.moveTo(ex, ey) : ellipsePath.lineTo(ex, ey);
    }
    ellipsePath.close();
    canvas.drawPath(ellipsePath, glowPaint);
    canvas.drawPath(ellipsePath, linePaint);

    // ── Axis lines ───────────────────────────────────────────────────────
    final axPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final handles = [
      Offset(cx, cy),
      Offset(cx + a * cosA, cy + a * sinA),
      Offset(cx - a * cosA, cy - a * sinA),
      Offset(cx - b * sinA, cy + b * cosA),
      Offset(cx + b * sinA, cy - b * cosA),
    ];
    canvas.drawLine(handles[2], handles[1], axPaint);
    canvas.drawLine(handles[3], handles[4], axPaint);

    // ── Drag handles — smaller, semi-transparent ─────────────────────────
    const handleColors = [
      Color(0xFFFACC15),
      Color(0xFF3B82F6),
      Color(0xFF3B82F6),
      Color(0xFF06B6D4),
      Color(0xFF06B6D4),
    ];
    for (int i = 0; i < handles.length; i++) {
      canvas.drawCircle(handles[i], 6,
          Paint()..color = handleColors[i].withValues(alpha: 0.75)..style = PaintingStyle.fill);
      canvas.drawCircle(handles[i], 6,
          Paint()..color = Colors.white.withValues(alpha: 0.5)..strokeWidth = 1.2
              ..style = PaintingStyle.stroke);
    }

    // ── WCA overlay ───────────────────────────────────────────────────────
    if (wcaResult != null) {
      _paintWcaOverlay(canvas, sz, wcaResult!);
    }
  }

  /// Draws the WCA visualisation exactly mirroring test2.py:
  ///   • Red tangent lines extending upward into the droplet
  ///   • Red baseline arms extending outward from each contact point
  ///   • Purple dotted arc along the ellipse between contact point and 90° away
  ///   • Angle labels in purple
  void _paintWcaOverlay(Canvas canvas, Size sz, _WcaResult wca) {
    const purple      = Color(0xFF9933FF);
    const red         = Color(0xFFFF4444);
    const tangentLen  = 80.0;

    final linePaint = Paint()
      ..style      = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final dotPaint  = Paint()
      ..style = PaintingStyle.fill
      ..color = purple;

    // Contact points in canvas coords
    final lx = wca.leftContact.dx  * sz.width;
    final ly = wca.leftContact.dy  * sz.height;
    final rx = wca.rightContact.dx * sz.width;
    final ry = wca.rightContact.dy * sz.height;

    // ── Contact point dots ──────────────────────────────────────────────
    final dotBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white;
    canvas.drawCircle(Offset(lx, ly), 5, dotPaint);
    canvas.drawCircle(Offset(lx, ly), 5, dotBorder);
    canvas.drawCircle(Offset(rx, ry), 5, dotPaint);
    canvas.drawCircle(Offset(rx, ry), 5, dotBorder);

    // ── LEFT contact ────────────────────────────────────────────────────
    // Tangent line (upward into droplet)
    linePaint.color = red;
    canvas.drawLine(
      Offset(lx, ly),
      Offset(lx + wca.leftTangent.dx * tangentLen,
             ly + wca.leftTangent.dy * tangentLen),
      linePaint,
    );
    // Baseline arm (extends left from contact point)
    canvas.drawLine(Offset(lx, ly), Offset(lx - tangentLen, ly), linePaint);

    // ── RIGHT contact ───────────────────────────────────────────────────
    canvas.drawLine(
      Offset(rx, ry),
      Offset(rx + wca.rightTangent.dx * tangentLen,
             ry + wca.rightTangent.dy * tangentLen),
      linePaint,
    );
    // Baseline arm (extends right)
    canvas.drawLine(Offset(rx, ry), Offset(rx + tangentLen, ry), linePaint);

    // ── Purple dotted arc on the ellipse ─────────────────────────────────
    // Find the parameter t for each contact point, then draw dots along
    // the ellipse from t to t ± π/2, mirroring test2.py exactly.
    final cx   = ellipse[0] * sz.width;
    final cy   = ellipse[1] * sz.height;
    final a    = ellipse[2] * sz.width;
    final b    = ellipse[3] * sz.height;
    final ar   = ellipse[4] * math.pi / 180.0;
    final cosA = math.cos(ar), sinA = math.sin(ar);

    double findT(double px, double py) {
      const res = 3600;
      double best = 0;
      double bestDist = double.infinity;
      for (int i = 0; i < res; i++) {
        final t  = 2 * math.pi * i / res;
        final ex = cx + a * math.cos(t) * cosA - b * math.sin(t) * sinA;
        final ey = cy + a * math.cos(t) * sinA + b * math.sin(t) * cosA;
        final d  = math.sqrt((ex - px) * (ex - px) + (ey - py) * (ey - py));
        if (d < bestDist) { bestDist = d; best = t; }
      }
      return best;
    }

    void drawDottedArc(double tStart, double tEnd) {
      const nPts = 48;
      const minDist = 5.0;
      Offset? prev;
      for (int i = 0; i <= nPts; i++) {
        final t  = tStart + (tEnd - tStart) * i / nPts;
        final ex = cx + a * math.cos(t) * cosA - b * math.sin(t) * sinA;
        final ey = cy + a * math.cos(t) * sinA + b * math.sin(t) * cosA;
        final pt = Offset(ex, ey);
        if (prev == null || (pt - prev).distance >= minDist) {
          canvas.drawCircle(pt, 2.5, dotPaint);
          prev = pt;
        }
      }
    }

    final tLeft  = findT(lx, ly);
    final tRight = findT(rx, ry);
    drawDottedArc(tLeft,  tLeft  - math.pi / 2);
    drawDottedArc(tRight, tRight + math.pi / 2);

    // ── Angle labels ─────────────────────────────────────────────────────
    final labelOffset = 18.0;

    // Left label: midpoint of arc parameter range, nudged left
    final tMidL = tLeft - math.pi / 4;
    final lLabelX = cx + a * math.cos(tMidL) * cosA
                       - b * math.sin(tMidL) * sinA - labelOffset;
    final lLabelY = cy + a * math.cos(tMidL) * sinA
                       + b * math.sin(tMidL) * cosA;

    // Right label: nudged right
    final tMidR = tRight + math.pi / 4;
    final rLabelX = cx + a * math.cos(tMidR) * cosA
                       - b * math.sin(tMidR) * sinA + labelOffset;
    final rLabelY = cy + a * math.cos(tMidR) * sinA
                       + b * math.sin(tMidR) * cosA;

    _drawLabel(canvas, Offset(lLabelX, lLabelY),
        '${wca.leftAngle.toStringAsFixed(1)}°');
    _drawLabel(canvas, Offset(rLabelX, rLabelY),
        '${wca.rightAngle.toStringAsFixed(1)}°');

    // ── Average WCA banner at top-centre of the canvas ────────────────────
    _drawLabel(
      canvas,
      Offset(sz.width / 2, 20),
      'WCA = ${wca.avgAngle.toStringAsFixed(1)}°',
      fontSize: 14,
    );
  }

  void _drawLabel(Canvas canvas, Offset pos, String text,
      {double fontSize = 11}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xFFCC88FF),
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          shadows: const [
            Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(1, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_EllipsePainter o) =>
      o.ellipse != ellipse || o.wcaResult != wcaResult ||
      o.baselineNormY != baselineNormY;
}
