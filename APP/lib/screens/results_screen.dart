import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({
    super.key,
    this.imagePath,
    required this.angle,
  });

  final String? imagePath;
  final double angle;

  String get _category {
    if (angle < 10) return 'Super-Hydrophilic';
    if (angle < 90) return 'Hydrophilic';
    if (angle < 150) return 'Hydrophobic';
    return 'Super-Hydrophobic';
  }

  Color _categoryColor(BuildContext context) {
    if (angle < 10) return HydroColors.accent;
    if (angle < 90) return HydroColors.secondary;
    if (angle < 150) return HydroColors.primary;
    return HydroColors.foreground;
  }

  String get _description {
    if (angle < 10) return 'The surface exhibits extreme wettability. Water spreads almost completely flat.';
    if (angle < 90) return 'The surface is wettable. Water tends to spread and adhere to the surface.';
    if (angle < 150) return 'The surface repels water. Droplets bead up and can roll off easily.';
    return 'The surface exhibits extreme water repulsion, similar to a lotus leaf effect.';
  }

  @override
  Widget build(BuildContext context) {
    final catColor = _categoryColor(context);

    return Scaffold(
      backgroundColor: HydroColors.background,
      body: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────────
          SafeArea(
            bottom: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _IconBtn(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => context.go('/'),
                  ),
                  const Spacer(),
                  Text(
                    'Results',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: HydroColors.foreground,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      _IconBtn(
                        icon: Icons.share_rounded,
                        onTap: () async {
                          if (imagePath != null) {
                            await Share.shareXFiles(
                              [XFile(imagePath!)],
                              text: 'Contact angle: $angle° – $_category',
                            );
                          } else {
                            await Share.share(
                                'Contact angle: $angle° – $_category');
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      _IconBtn(
                        icon: Icons.download_rounded,
                        onTap: () {},
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Scrollable content ────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.fromLTRB(20, 8, 20, 100),
              child: Column(
                children: [
                  // Image with CV overlay
                  _ImageCard(imagePath: imagePath, angle: angle)
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .scale(
                          begin: const Offset(0.95, 0.95),
                          duration: 400.ms,
                          curve: Curves.easeOut),

                  const SizedBox(height: 16),

                  // Contact angle card
                  _DataCard(
                    delay: 200,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CONTACT ANGLE',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: HydroColors.mutedForeground,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$angle',
                              style: GoogleFonts.outfit(
                                fontSize: 52,
                                fontWeight: FontWeight.w700,
                                color: HydroColors.cardForeground,
                                height: 1,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '°',
                                style: GoogleFonts.outfit(
                                  fontSize: 28,
                                  color: HydroColors.mutedForeground,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: catColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _category,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: catColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Analysis card
                  _DataCard(
                    delay: 300,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ANALYSIS',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: HydroColors.mutedForeground,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _description,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: HydroColors.cardForeground,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Measurement details card
                  _DataCard(
                    delay: 400,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MEASUREMENT DETAILS',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: HydroColors.mutedForeground,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...[
                          ['Left Angle', '${(angle - 1.2).toStringAsFixed(1)}°'],
                          ['Right Angle', '${(angle + 1.2).toStringAsFixed(1)}°'],
                          ['Asymmetry', '2.4°'],
                          ['Droplet Width', '2.34 mm'],
                          ['Droplet Height', '1.12 mm'],
                        ].map(
                          (row) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  row[0],
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: HydroColors.mutedForeground,
                                  ),
                                ),
                                Text(
                                  row[1],
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: HydroColors.cardForeground,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Disclaimer
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 16,
                          color: HydroColors.mutedForeground),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Results are estimates based on image analysis. For precise measurements, use calibrated equipment.',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: HydroColors.mutedForeground,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  )
                      .animate()
                      .fadeIn(delay: 500.ms, duration: 400.ms)
                      .slideY(begin: 0.1, end: 0, delay: 500.ms),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNav(),
    );
  }
}

// ── Image card with SVG-style CV overlay ─────────────────────────────────────
class _ImageCard extends StatelessWidget {
  const _ImageCard({this.imagePath, required this.angle});

  final String? imagePath;
  final double angle;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Image or placeholder
            if (imagePath != null)
              Image.file(File(imagePath!), fit: BoxFit.cover)
            else
              Container(
                color: HydroColors.foreground.withValues(alpha: 0.05),
                child: const Center(
                  child: Icon(Icons.water_drop_outlined,
                      size: 64,
                      color: HydroColors.mutedForeground),
                ),
              ),

            // CV overlay (mirrors the SVG from the web app)
            CustomPaint(painter: _CVOverlayPainter(angle: angle)),
          ],
        ),
      ),
    );
  }
}

class _CVOverlayPainter extends CustomPainter {
  const _CVOverlayPainter({required this.angle});
  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Scale factors (original viewBox 400×225)
    final sx = w / 400;
    final sy = h / 225;

    final dropletPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..strokeWidth = 2 * sx
      ..style = PaintingStyle.stroke;
    dropletPaint.strokeCap = StrokeCap.round;

    final dashPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.8)
      ..strokeWidth = 1.5 * sx
      ..style = PaintingStyle.stroke;

    final anglePaint = Paint()
      ..color = const Color(0xFFF59E0B)
      ..strokeWidth = 1.5 * sx
      ..style = PaintingStyle.stroke;

    // Droplet ellipse (dashed)
    final path = Path();
    path.addOval(Rect.fromCenter(
      center: Offset(200 * sx, 140 * sy),
      width: 120 * sx,
      height: 100 * sy,
    ));
    canvas.drawPath(_dashPath(path, 4 * sx, 2 * sx), dropletPaint);

    // Surface line
    canvas.drawLine(
      Offset(100 * sx, 175 * sy),
      Offset(300 * sx, 175 * sy),
      dashPaint,
    );

    // Left tangent line
    canvas.drawLine(
      Offset(145 * sx, 170 * sy),
      Offset(175 * sx, 120 * sy),
      anglePaint,
    );

    // Right tangent line
    canvas.drawLine(
      Offset(255 * sx, 170 * sy),
      Offset(225 * sx, 120 * sy),
      anglePaint,
    );

    // Angle label
    final textPainter = TextPainter(
      text: TextSpan(
        text: '$angle°',
        style: TextStyle(
          color: const Color(0xFFF59E0B),
          fontSize: 11 * sx,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(150 * sx, 148 * sy));
  }

  // Helper to draw a dashed path
  Path _dashPath(Path source, double dashLen, double gapLen) {
    final dest = Path();
    for (final metric in source.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        dest.addPath(
          metric.extractPath(dist, dist + dashLen),
          Offset.zero,
        );
        dist += dashLen + gapLen;
      }
    }
    return dest;
  }

  @override
  bool shouldRepaint(covariant _CVOverlayPainter old) => old.angle != angle;
}

// ── Reusable animated data card ───────────────────────────────────────────────
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
        color: HydroColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: HydroColors.border),
      ),
      child: child,
    )
        .animate()
        .fadeIn(delay: Duration(milliseconds: delay), duration: 400.ms)
        .slideY(
            begin: 0.1,
            end: 0,
            delay: Duration(milliseconds: delay),
            duration: 400.ms);
  }
}

// ── Icon button ───────────────────────────────────────────────────────────────
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
          color: HydroColors.muted,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: HydroColors.foreground),
      ),
    );
  }
}
