import 'package:flutter/material.dart';

// Theme implementation based on specifications/spec_theme.md

const _navyHeader = Color(0xFF202938);

/// Theme extension for the tuner gauge (colors kept centralized)
@immutable
class TunerTheme extends ThemeExtension<TunerTheme> {
  final Color gold; // main gauge color
  final Color green; // within tolerance
  final Color red; // hard limit / error
  final double haloOpacity; // subtle halo opacity around labels/arc

  const TunerTheme({
    required this.gold,
    required this.green,
    required this.red,
    this.haloOpacity = 0.12,
  });

  @override
  TunerTheme copyWith(
      {Color? gold, Color? green, Color? red, double? haloOpacity}) {
    return TunerTheme(
      gold: gold ?? this.gold,
      green: green ?? this.green,
      red: red ?? this.red,
      haloOpacity: haloOpacity ?? this.haloOpacity,
    );
  }

  @override
  ThemeExtension<TunerTheme> lerp(ThemeExtension<TunerTheme>? other, double t) {
    if (other is! TunerTheme) return this;
    return TunerTheme(
      gold: Color.lerp(gold, other.gold, t) ?? gold,
      green: Color.lerp(green, other.green, t) ?? green,
      red: Color.lerp(red, other.red, t) ?? red,
      haloOpacity: haloOpacity + (other.haloOpacity - haloOpacity) * t,
    );
  }
}

// LIGHT ColorScheme
const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF2266FC),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6EFFF),
  onPrimaryContainer: Color(0xFF0B295E),
  secondary: Color(0xFF3A4151),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE7E9EE),
  onSecondaryContainer: Color(0xFF1F2430),
  surface: Color(0xFFFFFFFF),
  surfaceContainer: Color(0xFFF2F4F7),
  surfaceContainerHighest: Color(0xFFEDF4FB),
  onSurface: Color(0xFF0F172A),
  onSurfaceVariant: Color(0xFF475569),
  outline: Color(0xFFCBD5E1),
  error: Color(0xFFE53935),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFDE7E9),
  inverseSurface: Color(0xFF111827),
  onInverseSurface: Color(0xFFE5E7EB),
);

final ThemeData lightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: _lightScheme,
  extensions: const [
    // Gold tuned for good contrast on light surfaces
    TunerTheme(
      gold: Color(0xFFB38600), // warm gold
      green: Color(0xFF2E7D32),
      red: Color(0xFFE53935),
      haloOpacity: 0.12,
    ),
  ],
  appBarTheme: const AppBarTheme(
    backgroundColor: _navyHeader,
    foregroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
  ),
  cardTheme: const CardThemeData(
    elevation: 1,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16))),
  ),
);

// DARK ColorScheme
const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF8FB2FF),
  onPrimary: Color(0xFF0B1220),
  primaryContainer: Color(0xFF1E2C47),
  onPrimaryContainer: Color(0xFFD6E4FF),
  secondary: Color(0xFFB3B9C6),
  onSecondary: Color(0xFF1B1F2A),
  secondaryContainer: Color(0xFF2A3242),
  onSecondaryContainer: Color(0xFFE6E9EF),
  surface: Color(0xFF0E1522),
  surfaceContainer: Color(0xFF111A2A),
  surfaceContainerHighest: Color(0xFF1A2233),
  onSurface: Color(0xFFE5E9F2),
  onSurfaceVariant: Color(0xFFB8C0CC),
  outline: Color(0xFF3B475B),
  error: Color(0xFFF97066),
  onError: Color(0xFF1A0B0B),
  errorContainer: Color(0xFF3A1920),
  inverseSurface: Color(0xFFF3F4F6),
  onInverseSurface: Color(0xFF101418),
);

final ThemeData darkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: _darkScheme,
  extensions: const [
    // Slightly brighter gold for dark mode
    TunerTheme(
      gold: Color(0xFFE6B85C),
      green: Color(0xFF66BB6A),
      red: Color(0xFFF97066),
      haloOpacity: 0.18,
    ),
  ],
  appBarTheme: AppBarTheme(
    backgroundColor: _darkScheme.surfaceContainer,
    foregroundColor: _darkScheme.onSurface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
  ),
);
