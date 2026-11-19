import 'package:flutter/material.dart';

/// Refined motion duration and curve tokens for micro-animations.
class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration standard = Duration(milliseconds: 240);
  static const Duration gentle = Duration(milliseconds: 360);

  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubicEmphasized;
  static const Curve exitCurve = Curves.easeInCubic;
}

/// Town Treasure Groceries Material 3 theme anchored to the brand logo palette:
/// deep forest green (`#166534` / `#1B5E20`), fresh leaf green (`#61B146`),
/// crisp white cards (`#FFFFFF`), and soft-sage surfaces (`#F4F7F4`).
class AppTheme {
  AppTheme._();

  // Town Treasure logo palette
  static const Color forestGreen = Color(0xFF166534);
  static const Color forestGreenDeep = Color(0xFF1B5E20);
  static const Color leafGreen = Color(0xFF61B146);
  static const Color sageTint = Color(0xFFE8F3E8);
  static const Color surfaceSage = Color(0xFFF4F7F4);
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color borderSubtle = Color(0xFFDFE7DF);

  // Neutral slate ink & supporting tokens
  static const Color slateDark = Color(0xFF313A43);
  static const Color slateInk = Color(0xFF1E293B);
  static const Color slateMuted = Color(0xFF64748B);

  // Semantic status colors
  static const Color success = forestGreen;
  static const Color successSurface = Color(0xFFDCFCE7);
  static const Color warning = Color(0xFFB45309);
  static const Color warningSurface = Color(0xFFFEF3C7);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSurface = Color(0xFFFEE2E2);
  static const Color info = Color(0xFF2563EB);
  static const Color infoSurface = Color(0xFFDBEAFE);

  // Aliases for ergonomic access
  static const Color emeraldPrimary = forestGreen;
  static const Color emeraldVibrant = leafGreen;
  static const Color emeraldSoft = sageTint;
  static const Color surfaceBackground = surfaceSage;

  // Motion tokens
  static const Duration motionFast = AppMotion.fast;
  static const Duration motionStandard = AppMotion.standard;
  static const Duration motionGentle = AppMotion.gentle;
  static const Curve motionCurve = AppMotion.standardCurve;
  static const Curve motionEmphasizedCurve = AppMotion.emphasizedCurve;

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: forestGreen,
      brightness: Brightness.light,
      primary: forestGreen,
      onPrimary: Colors.white,
      primaryContainer: sageTint,
      onPrimaryContainer: forestGreenDeep,
      secondary: leafGreen,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFE5F4DF),
      onSecondaryContainer: forestGreenDeep,
      tertiary: slateDark,
      onTertiary: Colors.white,
      error: danger,
      onError: Colors.white,
      surface: surfaceCard,
      onSurface: slateInk,
      surfaceContainerLowest: surfaceCard,
      surfaceContainerLow: surfaceSage,
      surfaceContainer: const Color(0xFFECF2EC),
      onSurfaceVariant: slateMuted,
      outline: borderSubtle,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: surfaceSage,
      appBarTheme: const AppBarTheme(
        backgroundColor: forestGreenDeep,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: borderSubtle),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceCard,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: forestGreen, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: forestGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: leafGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: forestGreenDeep,
          side: const BorderSide(color: borderSubtle),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceSage,
        selectedColor: sageTint,
        side: const BorderSide(color: borderSubtle),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        labelStyle: const TextStyle(
          color: slateInk,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceCard,
        indicatorColor: sageTint,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? forestGreen : slateMuted,
          );
        }),
      ),
      dividerTheme: const DividerThemeData(
        color: borderSubtle,
        thickness: 1,
      ),
    );
  }
}
