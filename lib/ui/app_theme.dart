import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'typography.dart';

/// Assembles a [ThemeData] entirely from [AppTokens] / [AppTypography] so the
/// Orca/Warp-inspired dark shell (and its light counterpart) is a pure function
/// of the token layer — no hard-coded colours leak into widgets.
class AppTheme {
  const AppTheme._();

  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData of(Brightness brightness) => _build(brightness);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final background = isDark
        ? AppTokens.backgroundDark
        : AppTokens.backgroundLight;
    final surface = isDark ? AppTokens.surfaceDark : AppTokens.surfaceLight;
    final surfaceRaised = isDark
        ? AppTokens.surfaceRaisedDark
        : AppTokens.surfaceRaisedLight;
    final border = isDark ? AppTokens.borderDark : AppTokens.borderLight;
    final textPrimary = isDark
        ? AppTokens.textPrimaryDark
        : AppTokens.textPrimaryLight;
    final textSecondary = isDark
        ? AppTokens.textSecondaryDark
        : AppTokens.textSecondaryLight;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: AppTokens.accent,
      onPrimary: const Color(0xFF04120F),
      secondary: AppTokens.accentAlt,
      onSecondary: const Color(0xFF120C22),
      error: AppTokens.statusDanger,
      onError: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceRaised,
      outline: border,
    );

    final textTheme = AppTypography.textTheme(textPrimary, textSecondary);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      textTheme: textTheme,
      fontFamily: 'D2Coding',
      primaryTextTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        shape: Border(bottom: BorderSide(color: border)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: border),
          borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedTileColor: surfaceRaised,
        selectedColor: textPrimary,
        iconColor: textSecondary,
        textColor: textPrimary,
        minVerticalPadding: AppTokens.spaceSm,
        dense: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? AppTokens.backgroundDark : AppTokens.surfaceLight,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceMd,
          vertical: AppTokens.spaceMd,
        ),
        labelStyle: TextStyle(
          color: textSecondary,
          fontFamily: 'D2Coding',
          fontSize: AppTypography.sizeBody,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          borderSide: const BorderSide(color: AppTokens.accent, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceRaised,
        side: BorderSide(color: border),
        labelStyle: textTheme.labelSmall,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.spaceSm,
          vertical: AppTokens.spaceXxs,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppTokens.accent,
          foregroundColor: const Color(0xFF04120F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(textStyle: textTheme.bodyMedium),
      popupMenuTheme: PopupMenuThemeData(textStyle: textTheme.bodyMedium),
      dialogTheme: DialogThemeData(
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
    );
  }
}
