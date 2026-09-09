import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';

/// Port of the website's dark/light CSS variables (index.html :root and
/// :root[data-theme="light"]). Fields are mutable (not const) so
/// [AppTheme.toggle] can repaint the whole app by swapping them in place —
/// every screen just reads AppColors.xxx directly rather than going through
/// Theme.of(context), so this is the one place that needs to change.
class AppColors {
  static Color bg = _dark.bg;
  static Color panel = _dark.panel;
  static Color panel2 = _dark.panel2;
  static Color line = _dark.line;
  static Color red = _dark.red;
  static Color teal = _dark.teal;
  static Color text = _dark.text;
  static Color muted = _dark.muted;
  static Color muted2 = _dark.muted2;
  static Color byline = _dark.byline;
  static Color glassBg = _dark.glassBg;
  static Color glassBorder = _dark.glassBorder;

  static void _apply(_Palette p) {
    bg = p.bg;
    panel = p.panel;
    panel2 = p.panel2;
    line = p.line;
    red = p.red;
    teal = p.teal;
    text = p.text;
    muted = p.muted;
    muted2 = p.muted2;
    byline = p.byline;
    glassBg = p.glassBg;
    glassBorder = p.glassBorder;
  }
}

class _Palette {
  final Color bg, panel, panel2, line, red, teal, text, muted, muted2, byline, glassBg, glassBorder;
  const _Palette({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.red,
    required this.teal,
    required this.text,
    required this.muted,
    required this.muted2,
    required this.byline,
    required this.glassBg,
    required this.glassBorder,
  });
}

const _dark = _Palette(
  bg: Color(0xFF14120F),
  panel: Color(0xFF1D1A16),
  panel2: Color(0xFF26221C),
  line: Color(0x1EF3EDE4), // rgba(243,237,228,0.12)
  red: Color(0xFFE8622C),
  teal: Color(0xFF6FA8A0),
  text: Color(0xFFF3EDE4),
  muted: Color(0xFFAFA492),
  muted2: Color(0xFF7D7362),
  byline: Color(0xFFA8496B),
  glassBg: Color(0x80262218), // rgba(38,34,28,0.5)
  glassBorder: Color(0x29F3EDE4), // rgba(243,237,228,0.16)
);

// Matches the website's :root[data-theme="light"] block.
const _light = _Palette(
  bg: Color(0xFFF3EFE7),
  panel: Color(0xFFFFFFFF),
  panel2: Color(0xFFEAE3D6),
  line: Color(0x241E1912), // rgba(30,25,18,0.14)
  red: Color(0xFFC94E1F),
  teal: Color(0xFF3E7D74),
  text: Color(0xFF1E1912),
  muted: Color(0xFF5C5344),
  muted2: Color(0xFF8C8171),
  byline: Color(0xFFA8496B),
  glassBg: Color(0x8CFFFFFF), // rgba(255,255,255,0.55)
  glassBorder: Color(0xB3FFFFFF), // rgba(255,255,255,0.7)
);

/// Light/dark toggle, mirroring the website's applyTheme()/toggleTheme() —
/// same default (dark), same persistence intent (website uses localStorage
/// under 'ss_theme'; here it's flutter_secure_storage, the only storage
/// dependency this app already has — a theme preference isn't sensitive,
/// but there's no reason to add a second storage package just for this).
class AppTheme extends ChangeNotifier {
  AppTheme._();
  static final AppTheme instance = AppTheme._();

  static const _key = 'ss_theme';
  final _storage = const FlutterSecureStorage();

  bool _isDark = true;
  bool get isDark => _isDark;

  Future<void> init() async {
    try {
      final saved = await _storage.read(key: _key);
      if (saved == 'light') _setDark(false, persist: false);
    } catch (_) {
      // Storage unavailable — fall back to the default (dark), same as the
      // website falling back to 'dark' when localStorage throws.
    }
  }

  void toggle() => _setDark(!_isDark);

  void _setDark(bool dark, {bool persist = true}) {
    _isDark = dark;
    AppColors._apply(dark ? _dark : _light);
    notifyListeners();
    if (persist) {
      _storage.write(key: _key, value: dark ? 'dark' : 'light').catchError((_) {});
    }
  }
}

/// Font helpers matching the website's stack:
/// Big Shoulders Display (headings), Work Sans (body), IBM Plex Mono (labels/tags/prices).
class AppFonts {
  static TextStyle heading({
    double size = 24,
    Color? color,
    FontWeight weight = FontWeight.w800,
    double letterSpacing = 0.2,
  }) =>
      GoogleFonts.bigShouldersDisplay(
        fontSize: size,
        fontWeight: weight,
        color: color ?? AppColors.text,
        letterSpacing: letterSpacing,
        height: 1.05,
      );

  static TextStyle body({
    double size = 14,
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) =>
      GoogleFonts.workSans(fontSize: size, fontWeight: weight, color: color ?? AppColors.text);

  static TextStyle mono({
    double size = 11,
    Color? color,
    FontWeight weight = FontWeight.w600,
    double letterSpacing = 1,
  }) =>
      GoogleFonts.ibmPlexMono(
        fontSize: size,
        fontWeight: weight,
        color: color ?? AppColors.muted2,
        letterSpacing: letterSpacing,
      );

  /// Small uppercase mono tag/eyebrow style, e.g. course tags and card labels.
  static TextStyle eyebrow({Color? color, double size = 11}) =>
      mono(size: size, color: color ?? AppColors.red, weight: FontWeight.w600, letterSpacing: 1.2);
}

ThemeData buildAppTheme() {
  final base = ThemeData(useMaterial3: true, brightness: AppTheme.instance.isDark ? Brightness.dark : Brightness.light);
  final workSansTextTheme = GoogleFonts.workSansTextTheme(base.textTheme)
      .apply(bodyColor: AppColors.text, displayColor: AppColors.text);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme(
      brightness: AppTheme.instance.isDark ? Brightness.dark : Brightness.light,
      primary: AppColors.red,
      onPrimary: Colors.white,
      secondary: AppColors.teal,
      onSecondary: Colors.white,
      error: AppColors.red,
      onError: Colors.white,
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
        side: BorderSide(color: AppColors.line),
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
        side: BorderSide(color: AppColors.line),
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
        borderSide: BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: AppColors.red),
      ),
    ),
    dividerColor: AppColors.line,
    progressIndicatorTheme: ProgressIndicatorThemeData(color: AppColors.red),
  );
}
