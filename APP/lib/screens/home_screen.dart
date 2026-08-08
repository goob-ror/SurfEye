import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Color _categoryColor(String category) {
    if (category.contains('Super-Hydrophilic')) return HydroColors.accent;
    if (category.contains('Hydrophilic')) return HydroColors.secondary;
    if (category.contains('Hydrophobic')) return HydroColors.primary;
    return HydroColors.mutedForeground;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HydroColors.background,
      body: Column(
        children: [
          // ── Gradient header ──────────────────────────────────────────────
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: HydroColors.hydroGradient,
            ),
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 16,
              left: 24,
              right: 24,
              bottom: 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Image.asset(
                      'assets/images/logopkm26.png',
                      height: 28,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.water_drop,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'SurfEye',
                      style: GoogleFonts.outfit(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Contact Angle Analyzer',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          )
              .animate()
              .fadeIn(duration: 400.ms)
              .slideY(begin: -0.1, end: 0, duration: 400.ms),

          // ── Scrollable body ──────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 0),

                  // New Measurement card (overlaps header by -16)
                  Transform.translate(
                    offset: const Offset(0, -16),
                    child: _NewMeasurementCard(),
                  ),

                  // Quick stats
                  _QuickStats()
                      .animate()
                      .fadeIn(delay: 200.ms, duration: 400.ms)
                      .slideY(begin: 0.15, end: 0, delay: 200.ms),

                  const SizedBox(height: 20),

                  // Recent tests heading
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Recent Tests',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: HydroColors.foreground,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {},
                        child: Text(
                          'View All',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: HydroColors.accent,
                          ),
                        ),
                      ),
                    ],
                  )
                      .animate()
                      .fadeIn(delay: 300.ms, duration: 400.ms),

                  const SizedBox(height: 12),

                  // Recent test cards
                  ...sampleMeasurements.asMap().entries.map((entry) {
                    final i = entry.key;
                    final test = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _RecentTestCard(
                        test: test,
                        categoryColor: _categoryColor(test.category),
                      )
                          .animate()
                          .fadeIn(delay: Duration(milliseconds: 400 + i * 100))
                          .slideX(
                            begin: -0.1,
                            end: 0,
                            delay: Duration(milliseconds: 400 + i * 100),
                          ),
                    );
                  }),
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

// ── New Measurement card ───────────────────────────────────────────────────────
class _NewMeasurementCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/camera'),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: HydroColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: HydroColors.border),
          boxShadow: HydroColors.hydroGlow,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: HydroColors.hydroGradient,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.science_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'New Measurement',
                        style: GoogleFonts.outfit(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: HydroColors.cardForeground,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Capture a water droplet image to analyze its contact angle and surface wettability.',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: HydroColors.mutedForeground,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.arrow_forward_rounded,
                color: HydroColors.accent, size: 20),
          ],
        ),
      )
          .animate()
          .fadeIn(delay: 100.ms, duration: 400.ms)
          .slideY(begin: 0.15, end: 0, delay: 100.ms),
    );
  }
}

// ── Quick Stats row ───────────────────────────────────────────────────────────
class _QuickStats extends StatelessWidget {
  static const _stats = [
    {'label': 'Total Tests', 'value': '24', 'icon': Icons.bar_chart_rounded},
    {'label': 'Avg Angle', 'value': '52.1°', 'icon': Icons.water_drop_rounded},
    {'label': 'This Week', 'value': '7', 'icon': Icons.schedule_rounded},
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: (_stats).map((stat) {
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(
              left: stat == _stats.first ? 0 : 6,
              right: stat == _stats.last ? 0 : 6,
            ),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: HydroColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: HydroColors.border),
            ),
            child: Column(
              children: [
                Icon(stat['icon'] as IconData,
                    color: HydroColors.accent, size: 18),
                const SizedBox(height: 6),
                Text(
                  stat['value'] as String,
                  style: GoogleFonts.outfit(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: HydroColors.cardForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  stat['label'] as String,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: HydroColors.mutedForeground,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Recent Test card ──────────────────────────────────────────────────────────
class _RecentTestCard extends StatelessWidget {
  const _RecentTestCard({
    required this.test,
    required this.categoryColor,
  });

  final Measurement test;
  final Color categoryColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HydroColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: HydroColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: HydroColors.hydroSurface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.water_drop_rounded,
                color: HydroColors.secondary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  test.surface,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: HydroColors.cardForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  test.timeAgo,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: HydroColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${test.angle}°',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: HydroColors.cardForeground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                test.category,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: categoryColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
