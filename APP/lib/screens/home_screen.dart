import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:surfeye_app/models/measurement.dart';
import 'package:surfeye_app/services/database_service.dart';
import 'package:surfeye_app/theme/app_theme.dart';
import 'package:surfeye_app/widgets/bottom_nav.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Measurement> _measurements = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMeasurements();
  }

  Future<void> _loadMeasurements() async {
    final measurements = await DatabaseService.instance.getMeasurements();
    setState(() {
      _measurements = measurements;
      _isLoading = false;
    });
  }

  Color _categoryColor(String category) {
    if (category.contains('Super-Hidrofilik')) return NatureColors.accent;
    if (category.contains('Hidrofilik')) return NatureColors.secondary;
    if (category.contains('Hidrofobik')) return NatureColors.primary;
    if (category.contains('Super-Hidrofobik')) return NatureColors.accent;
    return NatureColors.mutedForeground;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NatureColors.background,
      body: Column(
        children: [
          // ── Gradient header ──────────────────────────────────────────────
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: NatureColors.natureGradient,
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
                    ClipOval(
                      child: Image.asset(
                        'assets/images/logopkm26.png',
                        height: 56,
                        width: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.energy_savings_leaf,
                          color: Colors.white,
                          size: 56,
                        ),
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
                  'Penganalisis Sudut Kontak',
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

                  const SizedBox(height: 20),

                  // Recent tests heading
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tes Terbaru',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: NatureColors.foreground,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {},
                        child: Text(
                          'Lihat Semua',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: NatureColors.accent,
                          ),
                        ),
                      ),
                    ],
                  )
                      .animate()
                      .fadeIn(delay: 300.ms, duration: 400.ms),

                  const SizedBox(height: 12),

                  if (_isLoading)
                    const Center(child: CircularProgressIndicator())
                  else if (_measurements.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Text(
                          'Belum ada tes. Lakukan pengukuran!',
                          style: GoogleFonts.inter(color: NatureColors.mutedForeground),
                        ),
                      ),
                    )
                  else
                    // Recent test cards
                    ..._measurements.asMap().entries.map((entry) {
                      final i = entry.key;
                      final test = entry.value;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GestureDetector(
                          onTap: () => context.go('/results', extra: {'measurement': test}),
                          child: _RecentTestCard(
                            test: test,
                            categoryColor: _categoryColor(test.category),
                          ),
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
          color: NatureColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NatureColors.border),
          boxShadow: NatureColors.natureGlow,
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
                          gradient: NatureColors.natureGradient,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.science_rounded,
                            color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Pengukuran Baru',
                        style: GoogleFonts.outfit(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: NatureColors.cardForeground,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Ambil gambar tetesan air untuk menganalisis sudut kontak dan kebasahan permukaan.',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: NatureColors.mutedForeground,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.arrow_forward_rounded,
                color: NatureColors.accent, size: 20),
          ],
        ),
      )
          .animate()
          .fadeIn(delay: 100.ms, duration: 400.ms)
          .slideY(begin: 0.15, end: 0, delay: 100.ms),
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
        color: NatureColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NatureColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: NatureColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.water_drop_rounded,
                color: NatureColors.secondary, size: 20),
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
                    color: NatureColors.cardForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  test.timeAgo,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: NatureColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${test.formattedAngle}°',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: NatureColors.cardForeground,
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
