import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
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

  /// From history — full measurement object
  final Measurement? measurement;
  /// From camera — individual fields (legacy path)
  final List<String> imagePaths;
  final double? angle;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late final PageController _pageController;
  int _currentPage = 0;

  // Resolve source: measurement takes priority
  Measurement? get _m => widget.measurement;
  double get _angle => (_m?.angle ?? widget.angle ?? 0.0).clamp(0, 180).toDouble();
  List<String> get _imagePaths {
    if (_m?.imagePath != null) return [_m!.imagePath!];
    return widget.imagePaths;
  }

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
    if (_angle < 10) return 'Permukaan menunjukkan kebasahan ekstrem. Air menyebar hampir sepenuhnya rata.';
    if (_angle < 90) return 'Permukaan dapat basah. Air cenderung menyebar dan menempel pada permukaan.';
    if (_angle < 150) return 'Permukaan menolak air. Tetesan membentuk butiran dan dapat menggelinding dengan mudah.';
    return 'Permukaan menunjukkan penolakan air yang ekstrem, mirip dengan efek daun teratai.';
  }

  bool get _isEmpty => _m == null && (widget.angle == null || widget.angle == 0.0);

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _prevImage() {
    if (_currentPage > 0) _pageController.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _nextImage() {
    if (_currentPage < _imagePaths.length - 1) _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    final catColor = _categoryColor;
    final multiImage = _imagePaths.length > 1;

    return Scaffold(
      backgroundColor: NatureColors.background,
      body: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _IconBtn(icon: Icons.arrow_back_rounded, onTap: () => context.go('/')),
                  const Spacer(),
                  Text('Hasil', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w600, color: NatureColors.foreground)),
                  const Spacer(),
                  Row(children: [
                    _IconBtn(
                      icon: Icons.share_rounded,
                      onTap: () async {
                        final path = _imagePaths.isNotEmpty ? _imagePaths[_currentPage] : null;
                        if (path != null) {
                          await Share.shareXFiles([XFile(path)], text: 'Sudut kontak: $_formattedAngle° – $_category');
                        } else {
                          await Share.share('Sudut kontak: $_formattedAngle° – $_category');
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

          // ── Scrollable content ───────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              child: Column(
                children: [
                  // ── Image gallery / placeholder ──────────────────────────
                  _ImageGallery(
                    imagePaths: _imagePaths,
                    pageController: _pageController,
                    currentPage: _currentPage,
                    onPageChanged: (i) => setState(() => _currentPage = i),
                    onPrev: multiImage ? _prevImage : null,
                    onNext: multiImage ? _nextImage : null,
                  )
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .scale(begin: const Offset(0.95, 0.95), duration: 400.ms, curve: Curves.easeOut),

                  const SizedBox(height: 16),

                  // ── Contact angle card ───────────────────────────────────
                  _DataCard(
                    delay: 200,
                    child: _isEmpty
                        ? _EmptyCardContent(label: 'SUDUT KONTAK')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('SUDUT KONTAK',
                                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: NatureColors.mutedForeground, letterSpacing: 1.2)),
                              const SizedBox(height: 6),
                              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(_formattedAngle,
                                    style: GoogleFonts.outfit(fontSize: 52, fontWeight: FontWeight.w700, color: NatureColors.cardForeground, height: 1)),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text('°', style: GoogleFonts.outfit(fontSize: 28, color: NatureColors.mutedForeground)),
                                ),
                              ]),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: catColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(_category,
                                    style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: catColor)),
                              ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 12),

                  // ── Analysis card ────────────────────────────────────────
                  _DataCard(
                    delay: 300,
                    child: _isEmpty
                        ? _EmptyCardContent(label: 'ANALISIS')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ANALISIS',
                                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: NatureColors.mutedForeground, letterSpacing: 1.2)),
                              const SizedBox(height: 8),
                              Text(_description,
                                  style: GoogleFonts.inter(fontSize: 13, color: NatureColors.cardForeground, height: 1.6)),
                            ],
                          ),
                  ),

                  const SizedBox(height: 12),

                  // ── Measurement details card ─────────────────────────────
                  _DataCard(
                    delay: 400,
                    child: _isEmpty
                        ? _EmptyCardContent(label: 'DETAIL PENGUKURAN')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('DETAIL PENGUKURAN',
                                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: NatureColors.mutedForeground, letterSpacing: 1.2)),
                              const SizedBox(height: 12),
                              ..._buildDetailRows(),
                            ],
                          ),
                  ),

                  const SizedBox(height: 12),

                  // ── Disclaimer ───────────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, size: 16, color: NatureColors.mutedForeground),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Hasil ini adalah perkiraan berdasarkan analisis gambar. Untuk pengukuran yang presisi, gunakan peralatan yang dikalibrasi.',
                          style: GoogleFonts.inter(fontSize: 11, color: NatureColors.mutedForeground, height: 1.5),
                        ),
                      ),
                    ],
                  ).animate().fadeIn(delay: 500.ms, duration: 400.ms).slideY(begin: 0.1, end: 0, delay: 500.ms),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNav(),
    );
  }

  List<Widget> _buildDetailRows() {
    final rows = <List<String>>[];

    // Use real data from measurement if available, else fallback estimates
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
    rows.add(['Metode', method == 'young_laplace' ? 'Young-Laplace' : 'Circle Fit']);
    if (bond != null) rows.add(['Bond Number', bond.toStringAsFixed(4)]);
    if (widthPx != null) rows.add(['Lebar Tetesan', '${widthPx.toStringAsFixed(1)} px']);
    if (heightPx != null) rows.add(['Tinggi Tetesan', '${heightPx.toStringAsFixed(1)} px']);
    if (rms != null) rows.add(['RMS Residual', '${rms.toStringAsFixed(2)} px']);
    if (_m?.timestamp != null) {
      final ts = _m!.timestamp;
      rows.add(['Waktu', '${ts.day}/${ts.month}/${ts.year} ${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}']);
    }

    return rows.map((row) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(row[0], style: GoogleFonts.inter(fontSize: 13, color: NatureColors.mutedForeground)),
          Text(row[1], style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500, color: NatureColors.cardForeground)),
        ],
      ),
    )).toList();
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
        Text(label, style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: NatureColors.mutedForeground, letterSpacing: 1.2)),
        const SizedBox(height: 16),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: NatureColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 20,
          width: 120,
          decoration: BoxDecoration(color: NatureColors.surface, borderRadius: BorderRadius.circular(6)),
        ),
      ],
    );
  }
}

// ── Image gallery ──────────────────────────────────────────────────────────────
class _ImageGallery extends StatelessWidget {
  const _ImageGallery({
    required this.imagePaths,
    required this.pageController,
    required this.currentPage,
    required this.onPageChanged,
    this.onPrev,
    this.onNext,
  });

  final List<String> imagePaths;
  final PageController pageController;
  final int currentPage;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final hasImages = imagePaths.isNotEmpty;
    final multiImage = imagePaths.length > 1;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImages)
              PageView.builder(
                controller: pageController,
                itemCount: imagePaths.length,
                onPageChanged: onPageChanged,
                itemBuilder: (context, i) {
                  return Image.file(
                    File(imagePaths[i]),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const _Placeholder(),
                  );
                },
              )
            else
              const _Placeholder(),

            if (multiImage) ...[
              Positioned(
                left: 10, top: 0, bottom: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: currentPage > 0 ? 1.0 : 0.3,
                    duration: const Duration(milliseconds: 200),
                    child: GestureDetector(
                      onTap: onPrev,
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                        child: const Icon(Icons.chevron_left_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 10, top: 0, bottom: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: currentPage < imagePaths.length - 1 ? 1.0 : 0.3,
                    duration: const Duration(milliseconds: 200),
                    child: GestureDetector(
                      onTap: onNext,
                      child: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                        child: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 24),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 12, left: 0, right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(imagePaths.length, (i) {
                    final active = i == currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: active ? 18 : 6, height: 6,
                      decoration: BoxDecoration(
                        color: active ? Colors.white : Colors.white.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
              ),
              Positioned(
                top: 10, right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(20)),
                  child: Text('${currentPage + 1} / ${imagePaths.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Placeholder ────────────────────────────────────────────────────────────────
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: NatureColors.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/images/logopkm26.png',
                width: 80, height: 80, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.energy_savings_leaf, size: 64, color: NatureColors.mutedForeground),
              ),
            ),
            const SizedBox(height: 10),
            Text('Tidak ada gambar', style: TextStyle(fontSize: 12, color: NatureColors.mutedForeground)),
          ],
        ),
      ),
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
        .slideY(begin: 0.1, end: 0, delay: Duration(milliseconds: delay), duration: 400.ms);
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
        width: 40, height: 40,
        decoration: BoxDecoration(color: NatureColors.muted, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: NatureColors.foreground),
      ),
    );
  }
}
