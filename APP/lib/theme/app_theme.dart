import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Hydro colour tokens (mirrored from aqua-angle CSS variables) ──────────────
class HydroColors {
  HydroColors._();

  // Primary  hsl(201 96% 32%)
  static const primary = Color(0xFF0369A1);
  // Secondary hsl(199 89% 48%)
  static const secondary = Color(0xFF0EA5E9);
  // Accent    hsl(199 89% 60%)
  static const accent = Color(0xFF38BDF8);

  // Background hsl(210 40% 98%)
  static const background = Color(0xFFF1F5F9);
  // Foreground hsl(222 47% 11%)
  static const foreground = Color(0xFF0F172A);

  // Card
  static const card = Colors.white;
  static const cardForeground = Color(0xFF0F172A);

  // Muted
  static const muted = Color(0xFFE2E8F0);
  static const mutedForeground = Color(0xFF64748B);

  // Border
  static const border = Color(0xFFE2E8F0);

  // Hydro surface hsl(199 89% 97%)
  static const hydroSurface = Color(0xFFE0F7FE);

  // Dark variants
  static const darkBackground = Color(0xFF070D1A);
  static const darkCard = Color(0xFF0D1526);
  static const darkBorder = Color(0xFF1E293B);
  static const darkMuted = Color(0xFF1E293B);
  static const darkMutedForeground = Color(0xFF94A3B8);

  // Gradient
  static const gradientStart = primary;
  static const gradientEnd = accent;

  static const LinearGradient hydroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );

  // Glow shadow
  static List<BoxShadow> get hydroGlow => [
        BoxShadow(
          color: accent.withValues(alpha: 0.4),
          blurRadius: 32,
          offset: const Offset(0, 8),
          spreadRadius: -8,
        ),
      ];
}

// ── Theme ─────────────────────────────────────────────────────────────────────
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: HydroColors.background,
      colorScheme: const ColorScheme.light(
        primary: HydroColors.primary,
        secondary: HydroColors.secondary,
        tertiary: HydroColors.accent,
        surface: HydroColors.card,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: HydroColors.cardForeground,
        outline: HydroColors.border,
      ),
      textTheme: _buildTextTheme(HydroColors.foreground),
      cardTheme: CardThemeData(
        color: HydroColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: HydroColors.border),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: HydroColors.foreground),
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: HydroColors.foreground,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: HydroColors.card.withValues(alpha: 0.9),
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: active ? HydroColors.accent : HydroColors.mutedForeground,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return IconThemeData(
            color: active ? HydroColors.accent : HydroColors.mutedForeground,
            size: 22,
          );
        }),
      ),
    );
  }

  static TextTheme _buildTextTheme(Color base) {
    return TextTheme(
      displayLarge: GoogleFonts.outfit(fontSize: 57, fontWeight: FontWeight.w800, color: base),
      displayMedium: GoogleFonts.outfit(fontSize: 45, fontWeight: FontWeight.w700, color: base),
      displaySmall: GoogleFonts.outfit(fontSize: 36, fontWeight: FontWeight.w700, color: base),
      headlineLarge: GoogleFonts.outfit(fontSize: 32, fontWeight: FontWeight.w700, color: base),
      headlineMedium: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w600, color: base),
      headlineSmall: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.w600, color: base),
      titleLarge: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w600, color: base),
      titleMedium: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w600, color: base),
      titleSmall: GoogleFonts.outfit(fontSize: 14, fontWeight: FontWeight.w500, color: base),
      bodyLarge: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400, color: base),
      bodyMedium: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400, color: base),
      bodySmall: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400, color: HydroColors.mutedForeground),
      labelLarge: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500, color: base),
      labelMedium: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: base),
      labelSmall: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500, color: HydroColors.mutedForeground),
    );
  }
}
