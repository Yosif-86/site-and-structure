import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Port of the website's dark theme CSS variables (index.html :root).
class AppColors {
  static const bg = Color(0xFF14120F);
  static const panel = Color(0xFF1D1A16);
  static const panel2 = Color(0xFF26221C);
  static const line = Color(0x1EF3EDE4); // rgba(243,237,228,0.12)
  static const red = Color(0xFFE8622C);
  static const teal = Color(0xFF6FA8A0);
  static const text = Color(0xFFF3EDE4);
  static const muted = Color(0xFFAFA492);
  static const muted2 = Color(0xFF7D7362);
  static const byline = Color(0xFFA8496B);

  // --glass-bg / --glass-border from index.html, used by GlassCard.
  static const glassBg = Color(0x80262218); // rgba(38,34,28,0.5)
  static const glassBorder = Color(0x29F3EDE4); // rgba(243,237,228,0.16)
}

/// Font helpers matching the website's stack:
/// Big Shoulders Display (headings), Work Sans (body), IBM Plex Mono (labels/tags/prices).
class AppFonts {
  static TextStyle heading({
    double size = 24,
    Color color = AppColors.text,
    FontWeight weight = FontWeight.w800,
    double letterSpacing = 0.2,
  }) =>
      GoogleFonts.bigShouldersDisplay(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: 1.05,
      );

  static TextStyle body({
    double size = 14,
    Color color = AppColors.text,
    FontWeight weight = FontWeight.w400,
  }) =>
      GoogleFonts.workSans(fontSize: size, fontWeight: weight, color: color);

  static TextStyle mono({
    double size = 11,
    Color color = AppColors.muted2,
    FontWeight weight = FontWeight.w600,
    double letterSpacing = 1,
  }) =>
      GoogleFonts.ibmPlexMono(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
      );

  /// Small uppercase mono tag/eyebrow style, e.g. course tags and card labels.
  static TextStyle eyebrow({Color color = AppColors.red, double size = 11}) =>
      mono(size: size, color: color, weight: FontWeight.w600, letterSpacing: 1.2);
}

ThemeData buildAppTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
  final workSansTextTheme = GoogleFonts.workSansTextTheme(base.textTheme)
      .apply(bodyColor: AppColors.text, displayColor: AppColors.text);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.red,
      secondary: AppColors.teal,
      surface: AppColors.panel,
      onSurface: AppColors.text,
    ),
    textTheme: workSansTextTheme.copyWith(
      headlineLarge: AppFonts.heading(size: 32),
      headlineMedium: AppFonts.heading(size: 24),
      headlineSmall: AppFonts.heading(size: 20),
      titleLarge: GoogleFonts.workSans(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.text),
      labelSmall: AppFonts.mono(size: 10.5, color: AppColors.muted2, letterSpacing: 0.5),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: AppFonts.heading(size: 19, letterSpacing: 0.2),
    ),
    cardTheme: CardThemeData(
      color: AppColors.panel2,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.red,
        foregroundColor: Colors.white,
        textStyle: GoogleFonts.workSans(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        textStyle: GoogleFonts.workSans(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        side: const BorderSide(color: AppColors.line),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.red,
        textStyle: GoogleFonts.workSans(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.panel,
      labelStyle: AppFonts.mono(size: 10.5, color: AppColors.muted2, letterSpacing: 0.5),
      floatingLabelStyle: AppFonts.mono(size: 10.5, color: AppColors.muted, letterSpacing: 0.5),
      hintStyle: GoogleFonts.workSans(fontSize: 13.5, color: AppColors.muted2),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.red),
      ),
    ),
    dividerColor: AppColors.line,
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.red),
  );
}
