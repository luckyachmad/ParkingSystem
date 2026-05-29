// lib/core/theme.dart
//
// App-wide theme definition for the Parking System.
//
// All screens consume this theme via Theme.of(context) — no hardcoded colors
// or text styles should appear in widget files. Centralising the theme here
// makes it trivial to adjust the visual identity without touching individual
// screens.
//
// Requirements: all (Task 15.2)

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// AppTheme
// ---------------------------------------------------------------------------

/// Provides the application [ThemeData] instances.
///
/// Usage in [MaterialApp.router]:
/// ```dart
/// MaterialApp.router(
///   theme: AppTheme.light,
///   darkTheme: AppTheme.dark,
///   themeMode: ThemeMode.system,
///   ...
/// )
/// ```
abstract final class AppTheme {
  // ── Brand seed color ───────────────────────────────────────────────────────
  //
  // Indigo is used as the primary seed. Material 3's tonal palette generation
  // derives all surface, container, and on-* colors from this single seed,
  // keeping the palette coherent without manual color specification.
  static const Color _seedColor = Color(0xFF3F51B5); // Indigo 500

  // ── Light theme ────────────────────────────────────────────────────────────

  /// Light [ThemeData] used as the default app theme.
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.light,
        ),
        textTheme: _textTheme,
        inputDecorationTheme: _inputDecorationTheme,
        cardTheme: _cardTheme,
        filledButtonTheme: _filledButtonTheme,
        outlinedButtonTheme: _outlinedButtonTheme,
        textButtonTheme: _textButtonTheme,
        appBarTheme: _appBarTheme,
        snackBarTheme: _snackBarTheme,
        dividerTheme: const DividerThemeData(space: 1),
      );

  // ── Dark theme ─────────────────────────────────────────────────────────────

  /// Dark [ThemeData] — mirrors the light theme with a dark color scheme.
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
        textTheme: _textTheme,
        inputDecorationTheme: _inputDecorationTheme,
        cardTheme: _cardTheme,
        filledButtonTheme: _filledButtonTheme,
        outlinedButtonTheme: _outlinedButtonTheme,
        textButtonTheme: _textButtonTheme,
        appBarTheme: _appBarTheme,
        snackBarTheme: _snackBarTheme,
        dividerTheme: const DividerThemeData(space: 1),
      );

  // ---------------------------------------------------------------------------
  // Shared sub-themes
  // ---------------------------------------------------------------------------

  // ── Text theme ─────────────────────────────────────────────────────────────

  /// Applies a consistent font weight hierarchy across all text styles.
  ///
  /// Material 3 uses the system default font family; we only adjust weights
  /// and letter spacing to improve readability on small mobile screens.
  static const TextTheme _textTheme = TextTheme(
    // Display / headline — used for large metric values on the dashboard.
    displayLarge: TextStyle(fontWeight: FontWeight.w300, letterSpacing: -1.5),
    displayMedium: TextStyle(fontWeight: FontWeight.w300, letterSpacing: -0.5),
    displaySmall: TextStyle(fontWeight: FontWeight.w400),
    headlineLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
    headlineMedium: TextStyle(fontWeight: FontWeight.w700),
    headlineSmall: TextStyle(fontWeight: FontWeight.w600),
    // Title — used for card titles, screen section headers.
    titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.15),
    titleMedium: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0.15),
    titleSmall: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0.1),
    // Body — used for form labels, list items, descriptions.
    bodyLarge: TextStyle(fontWeight: FontWeight.w400, letterSpacing: 0.5),
    bodyMedium: TextStyle(fontWeight: FontWeight.w400, letterSpacing: 0.25),
    bodySmall: TextStyle(fontWeight: FontWeight.w400, letterSpacing: 0.4),
    // Label — used for button text, chip labels, navigation labels.
    labelLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1.25),
    labelMedium: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 1.0),
    labelSmall: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 1.5),
  );

  // ── Input decoration theme ─────────────────────────────────────────────────

  /// Consistent outlined text field style used across all form screens
  /// (login, registration, vehicle entry, vehicle exit, pricing management).
  ///
  /// Using [OutlineInputBorder] with a rounded corner radius of 12 dp matches
  /// the card corner radius, giving the UI a cohesive look.
  static final InputDecorationTheme _inputDecorationTheme =
      InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(width: 2),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(width: 2),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    floatingLabelBehavior: FloatingLabelBehavior.auto,
  );

  // ── Card theme ─────────────────────────────────────────────────────────────

  /// Consistent card elevation and corner radius used by metric cards,
  /// confirmation cards, and list item cards.
  static final CardThemeData _cardTheme = CardThemeData(
    elevation: 2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
  );

  // ── Filled button theme ────────────────────────────────────────────────────

  /// Primary action buttons (e.g. "Sign In", "Submit", "Confirm Exit").
  static final FilledButtonThemeData _filledButtonTheme =
      FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      textStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    ),
  );

  // ── Outlined button theme ──────────────────────────────────────────────────

  /// Secondary action buttons (e.g. "Cancel", "Edit").
  static final OutlinedButtonThemeData _outlinedButtonTheme =
      OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      textStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    ),
  );

  // ── Text button theme ──────────────────────────────────────────────────────

  /// Inline text links (e.g. "Register", "Forgot password").
  static final TextButtonThemeData _textButtonTheme = TextButtonThemeData(
    style: TextButton.styleFrom(
      textStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        letterSpacing: 0.25,
      ),
    ),
  );

  // ── AppBar theme ───────────────────────────────────────────────────────────

  /// Consistent app bar style: no elevation on scroll, centered title on iOS,
  /// left-aligned on Android (Material 3 default).
  static const AppBarTheme _appBarTheme = AppBarTheme(
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 2,
    titleTextStyle: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.15,
    ),
  );

  // ── SnackBar theme ─────────────────────────────────────────────────────────

  /// Floating snackbars with rounded corners, consistent with the card style.
  static const SnackBarThemeData _snackBarTheme = SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
  );
}
