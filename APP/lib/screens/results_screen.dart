import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    this.measurement,
    this.imagePaths = const [],
    this.angle,
  });

  final Measurement? measurement;
  final List<String> imagePaths; // kept for router compat, unused in UI
  final double? angle;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  Measurement? get _m => widget.measurement;
  double get _angle =>
      (_m?.angle ?? widget.angle ?? 0.0).clamp(0, 180).toDouble();

  String get _formattedAngle => _angle.toStringAsFixed(2);

  String get _category {
    if (_angle < 10) return 'Super-Hidrofilik';
    if (_angle < 90) return 'Hidrofilik';
    if (_angle < 150) return 'Hidrofobik';
    return 'Super-Hidrofobik';
  }

  Color get _categoryColor {
    if (_angle < 10) return NatureColors.accent;
    if (_angle < 90) return NatureColors.secondary;
    if (_angle < 150) return NatureColors.primary;
    return NatureColors.foreground;
  }

  String get _description {
    if (_angle < 10) {
      return 'Permukaan menunjukkan kebasahan ekstrem. Air menyebar hampir sepenuhnya rata.';
    }
    if (_angle < 90) {
      return 'Permukaan dapat basah. Air cenderung menyebar dan menempel pada permukaan.';
    }
    if (_angle < 150) {
      return 'Permukaan menolak air. Tetesan membentuk butiran dan dapat menggelinding dengan mudah.';
    }
    return 'Permukaan menunjukkan penolakan air yang ekstrem, mirip dengan efek daun teratai.';
  }

  bool get _isEmpty =>
      _m == null && (widget.angle == null || widget.angle == 0.0);

  String? get _edgePath => _m?.edgeImagePath;
  String? get _annotatedPath => _m?.imagePath;

  // ── Full-screen image viewer ─────────────────────────────────────────────
  void _openFullscreen(String filePath, {String title = ''}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => _FullscreenImagePage(
          filePath: filePath,
          title: title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catColor = _categoryColor;

    return PopScope(
      // canPop: true — the default; system back navigates to the previous
      // route (camera or home) rather than calling context.go('/') which
      // would always jump to home and lose the back-stack.
      canPop: true,
      child: Scaffold(
        backgroundColor: NatureColors.background,
        body: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────
            SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    _IconBtn(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    Text('Hasil',
                        style: GoogleFonts.outfit(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: NatureColors.foreground)),
                    const Spacer(),
                    Row(children: [
                      _IconBtn(
                        icon: Icons.share_rounded,
                        onTap: () async {
                          final path = _annotatedPath ?? _edgePath;
                          if (path != null) {
                            await Share.shareXFiles([XFile(path)],
                                text:
                                    'Sudut kontak: $_formattedAngle° – $_category');
                          } else {
                            await Share.share(
                                'Sudut kontak: $_formattedAngle° – $_category');
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      _IconBtn(icon: Icons.download_rounded, onTap: () {}),
                    ]),
                  ],
                ),
              ),
            ),

            // ── Scrollable content ─────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                child: Column(
                  children: [
                    // ── Annotated image card (the main visualization with measurements) ─────────
                    if (_annotatedPath != null)
                      _TappableImageCard(
                        filePath: _annotatedPath!,
                        label: 'ANALISIS',
                        onTap: () => _openFullscreen(
                          _annotatedPath!,
                          title: 'Analisis',
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 350.ms)
                          .scale(
                              begin: const Offset(0.97, 0.97),
                              duration: 350.ms,
                              curve: Curves.easeOut),

                    if (_annotatedPath != null) const SizedBox(height: 12),

                    // ── Edge image card (B&W edge detection) ───────────────────────
                    if (_edgePath != null)
                      _TappableImageCard(
                        filePath: _edgePath!,
                        label: 'TEPI TETESAN (B&W)',
                        onTap: () => _openFullscreen(
                          _edgePath!,
                          title: 'Tepi Tetesan',
                        ),
                      )
                          .animate()
                          .fadeIn(duration: 350.ms)
                          .scale(
                              begin: const Offset(0.97, 0.97),
                              duration: 350.ms,
                              curve: Curves.easeOut),

                    if (_edgePath != null) const SizedBox(height: 12),

                    // ── Contact angle card ─────────────────────────────────
                    _DataCard(
                      delay: 150,
                      child: _isEmpty
                          ? _EmptyCardContent(label: 'SUDUT KONTAK')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('SUDUT KONTAK',
                                    style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: NatureColors.mutedForeground,
                                        letterSpacing: 1.2)),
                                const SizedBox(height: 6),
                                Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.end,
                                    children: [
                                      Text(_formattedAngle,
                                          style: GoogleFonts.outfit(
                                              fontSize: 52,
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  NatureColors.cardForeground,
                                              height: 1)),
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 6),
                                        child: Text('°',
                                            style: GoogleFonts.outfit(
                                                fontSize: 28,
                                                color: NatureColors
                                                    .mutedForeground)),
                                      ),
                                    ]),
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: catColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(_category,
                                      style: GoogleFonts.inter(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: catColor)),
                                ),
                              ],
                            ),
                    ),

                    const SizedBox(height: 12),

                    // ── Analysis card ──────────────────────────────────────
                    _DataCard(
                      delay: 250,
                      child: _isEmpty
                          ? _EmptyCardContent(label: 'ANALISIS')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('ANALISIS',
                                    style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: NatureColors.mutedForeground,
                                        letterSpacing: 1.2)),
                                const SizedBox(height: 8),
                                Text(_description,
                                    style: GoogleFonts.inter(
                                        fontSize: 13,
                                        color: NatureColors.cardForeground,
                                        height: 1.6)),
                              ],
                            ),
                    ),

                    const SizedBox(height: 12),

                    // ── Measurement details card ───────────────────────────
                    _DataCard(
                      delay: 350,
                      child: _isEmpty
                          ? _EmptyCardContent(label: 'DETAIL PENGUKURAN')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('DETAIL PENGUKURAN',
                                    style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: NatureColors.mutedForeground,
                                        letterSpacing: 1.2)),
                                const SizedBox(height: 12),
                                ..._buildDetailRows(),
                              ],
                            ),
                    ),

                    const SizedBox(height: 12),

                    // ── Disclaimer ─────────────────────────────────────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 16, color: NatureColors.mutedForeground),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Hasil ini adalah perkiraan berdasarkan analisis gambar. '
                            'Untuk pengukuran yang presisi, gunakan peralatan yang dikalibrasi.',
                            style: GoogleFonts.inter(
                                fontSize: 11,
                                color: NatureColors.mutedForeground,
                                height: 1.5),
                          ),
                        ),
                      ],
                    )
                        .animate()
                        .fadeIn(delay: 450.ms, duration: 400.ms)
                        .slideY(
                            begin: 0.1,
                            end: 0,
                            delay: 450.ms),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: const BottomNav(),
      ),
    );
  }

  List<Widget> _buildDetailRows() {
    final rows = <List<String>>[];

    final leftA = _m?.leftAngle ?? (_angle - 1.2);
    final rightA = _m?.rightAngle ?? (_angle + 1.2);
    final asymmetry = (rightA - leftA).abs();
    final method = _m?.method ?? 'young_laplace';
    final bond = _m?.bondNumber;
    final widthPx = _m?.dropletWidthPx;
    final heightPx = _m?.dropletHeightPx;
    final rms = _m?.fitResidualRms;

    rows.add(['Sudut Kiri', '${leftA.toStringAsFixed(2)}°']);
    rows.add(['Sudut Kanan', '${rightA.toStringAsFixed(2)}°']);
    rows.add(['Asimetri', '${asymmetry.toStringAsFixed(2)}°']);
    rows.add([
      'Metode',
      method == 'young_laplace' ? 'Young-Laplace' : 'Circle Fit'
    ]);
    if (bond != null) { rows.add(['Bond Number', bond.toStringAsFixed(4)]); }
    if (widthPx != null) {
      rows.add(['Lebar Tetesan', '${widthPx.toStringAsFixed(1)} px']);
    }
    if (heightPx != null) {
      rows.add(['Tinggi Tetesan', '${heightPx.toStringAsFixed(1)} px']);
    }
    if (rms != null) { rows.add(['RMS Residual', '${rms.toStringAsFixed(2)} px']); }
    if (_m?.timestamp != null) {
      final ts = _m!.timestamp;
      rows.add([
        'Waktu',
        '${ts.day}/${ts.month}/${ts.year} '
            '${ts.hour.toString().padLeft(2, '0')}:'
            '${ts.minute.toString().padLeft(2, '0')}'
      ]);
    }

    return rows
        .map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(row[0],
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          color: NatureColors.mutedForeground)),
                  Text(row[1],
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: NatureColors.cardForeground)),
                ],
              ),
            ))
        .toList();
  }
}

// ── Full-screen image page (photo_view) ────────────────────────────────────────
class _FullscreenImagePage extends StatelessWidget {
  const _FullscreenImagePage({required this.filePath, this.title = ''});
  final String filePath;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: title.isNotEmpty
            ? Text(title,
                style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white))
            : null,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PhotoView(
        imageProvider: FileImage(File(filePath)),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, _) => const Center(
          child: CircularProgressIndicator(color: NatureColors.accent),
        ),
        errorBuilder: (_, _, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_rounded,
                  color: NatureColors.mutedForeground, size: 48),
              const SizedBox(height: 12),
              Text('Gambar tidak ditemukan',
                  style: GoogleFonts.inter(
                      color: NatureColors.mutedForeground, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tappable image card ────────────────────────────────────────────────────────
class _TappableImageCard extends StatelessWidget {
  const _TappableImageCard({
    required this.filePath,
    required this.label,
    required this.onTap,
  });
  final String filePath;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: NatureColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NatureColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              // Image — B&W edge map, fill width
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.file(
                  File(filePath),
                  fit: BoxFit.cover,
                  color: Colors.white,
                  colorBlendMode: BlendMode.modulate,
                  errorBuilder: (_, _, _) => Container(
                    color: NatureColors.surface,
                    child: const Center(
                      child: Icon(Icons.image_not_supported_rounded,
                          color: NatureColors.mutedForeground, size: 40),
                    ),
                  ),
                ),
              ),
              // Label bar at bottom
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.75),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(label,
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                              letterSpacing: 1.1)),
                      const Icon(Icons.zoom_in_rounded,
                          color: Colors.white70, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Empty card placeholder ─────────────────────────────────────────────────────
class _EmptyCardContent extends StatelessWidget {
  const _EmptyCardContent({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: NatureColors.mutedForeground,
                letterSpacing: 1.2)),
        const SizedBox(height: 16),
        Container(
          height: 40,
          decoration: BoxDecoration(
              color: NatureColors.surface,
              borderRadius: BorderRadius.circular(8)),
        ),
        const SizedBox(height: 8),
        Container(
          height: 20,
          width: 120,
          decoration: BoxDecoration(
              color: NatureColors.surface,
              borderRadius: BorderRadius.circular(6)),
        ),
      ],
    );
  }
}

// ── Animated data card ─────────────────────────────────────────────────────────
class _DataCard extends StatelessWidget {
  const _DataCard({required this.child, this.delay = 0});
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NatureColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NatureColors.border),
      ),
      child: child,
    )
        .animate()
        .fadeIn(delay: Duration(milliseconds: delay), duration: 400.ms)
        .slideY(
            begin: 0.08,
            end: 0,
            delay: Duration(milliseconds: delay),
            duration: 400.ms);
  }
}

// ── Icon button ────────────────────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
            color: NatureColors.muted, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: NatureColors.foreground),
      ),
    );
  }
}
