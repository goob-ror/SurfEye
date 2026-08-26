import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Nature colour tokens (Green Theme) ──────────────
class NatureColors {
  NatureColors._();

  // Primary
  static const primary = Color(0xFF166534); // Green 800
  // Secondary
  static const secondary = Color(0xFF22C55E); // Green 500
  // Accent
  static const accent = Color(0xFF4ADE80); // Green 400

  // Background
  static const background = Color(0xFFF0FDF4); // Green 50
  // Foreground
  static const foreground = Color(0xFF14532D); // Green 900

  // Card
  static const card = Colors.white;
  static const cardForeground = Color(0xFF14532D);

  // Muted
  static const muted = Color(0xFFDCFCE7); // Green 100
  static const mutedForeground = Color(0xFF166534);

  // Border
  static const border = Color(0xFFBBF7D0); // Green 200

  // Surface
  static const surface = Color(0xFFF0FDF4);

  // Gradient
  static const gradientStart = primary;
  static const gradientEnd = accent;

  static const LinearGradient natureGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );

  // Glow shadow
  static List<BoxShadow> get natureGlow => [
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
      scaffoldBackgroundColor: NatureColors.background,
      colorScheme: const ColorScheme.light(
        primary: NatureColors.primary,
        secondary: NatureColors.secondary,
        tertiary: NatureColors.accent,
        surface: NatureColors.card,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: NatureColors.cardForeground,
        outline: NatureColors.border,
      ),
      textTheme: _buildTextTheme(NatureColors.foreground),
      cardTheme: CardThemeData(
        color: NatureColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: NatureColors.border),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: NatureColors.foreground),
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: NatureColors.foreground,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: NatureColors.card.withValues(alpha: 0.9),
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: active ? NatureColors.accent : NatureColors.mutedForeground,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return IconThemeData(
            color: active ? NatureColors.accent : NatureColors.mutedForeground,
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
      bodySmall: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400, color: NatureColors.mutedForeground),
      labelLarge: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500, color: base),
      labelMedium: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: base),
      labelSmall: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500, color: NatureColors.mutedForeground),
    );
  }
}
