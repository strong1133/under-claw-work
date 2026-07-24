import 'package:flutter/material.dart';

import 'font_detection.dart';

/// Typography tokens for the desktop shell.
///
/// D2Coding font policy (requirement 4)
/// ------------------------------------
/// D2Coding is distributed under the SIL Open Font License 1.1 (OFL), which
/// *does* permit bundling and redistribution inside an application provided the
/// OFL terms are met (ship the licence text, keep the reserved font name, do
/// not sell the font on its own). See KNW-d2coding-ligatures for the canonical
/// evidence note.
///
/// This build **bundles** the OFL-licensed D2Coding faces under `assets/fonts/`
/// (regular + bold), declares the `D2Coding` family in `pubspec.yaml`, and ships
/// `assets/fonts/OFL.txt` beside them, so the reserved-name/licence terms are
/// met. On top of the bundle we still run a verifiable **installation
/// detection** ([MonospaceFontResolver]) that probes the platform's font
/// directories: [resolvedMonospaceFamily] resolves to D2Coding when it is
/// bundled *or* installed, and degrades to the host's native monospace faces
/// ([monospaceFallback]) otherwise. No layout depends on D2Coding being present.
@immutable
class AppTypography {
  const AppTypography._();

  /// The app bundles the D2Coding asset (see pubspec.yaml), so detection always
  /// starts from `bundled: true`; the resolver additionally reports whether the
  /// face is *also* installed system-wide.
  static const bool bundlesD2Coding = true;

  static const MonospaceFontResolver _resolver = MonospaceFontResolver();

  /// Cached detection so the filesystem probe runs at most once per process.
  static D2CodingDetection? _detection;

  static D2CodingDetection get detection =>
      _detection ??= _resolver.detect(bundled: bundlesD2Coding);

  /// Primary monospace family — code, terminal and dense id surfaces. Resolves
  /// to D2Coding when available, degrading to native monospace when absent.
  static String get monospaceFamily => _resolver.resolveFamily(detection);

  static List<String> get monospaceFallback =>
      _resolver.resolveFallback(detection);

  // Every text surface uses the bundled D2Coding face at exactly 16pt. Visual
  // hierarchy comes from weight, colour and spacing, never a hidden size
  // exception in an individual Material component.
  static const double sizeBody = 16;
  static const double sizeCode = 16;
  static const double sizeTitle = 16;
  static const double sizeHeadline = 16;
  static const double sizeLabel = 16;
  static const double sizeCaption = 16;

  static const double lineHeightBody = 1.45;

  /// Builds a Material [TextTheme] whose default reading surfaces are 16pt.
  static TextTheme textTheme(Color primary, Color secondary) {
    TextStyle body({Color? color, FontWeight? weight}) => TextStyle(
      fontFamily: 'D2Coding',
      fontFamilyFallback: monospaceFallback,
      fontSize: sizeBody,
      height: lineHeightBody,
      color: color ?? primary,
      fontWeight: weight,
    );
    return TextTheme(
      displayLarge: body(weight: FontWeight.w700),
      displayMedium: body(weight: FontWeight.w700),
      displaySmall: body(weight: FontWeight.w700),
      headlineLarge: body(weight: FontWeight.w700),
      headlineMedium: body(weight: FontWeight.w700),
      headlineSmall: body(weight: FontWeight.w700),
      titleLarge: body(weight: FontWeight.w700),
      titleMedium: body(weight: FontWeight.w600),
      titleSmall: body(weight: FontWeight.w600),
      bodyLarge: body(),
      bodyMedium: body(),
      bodySmall: body(color: secondary),
      labelLarge: body(weight: FontWeight.w600),
      labelMedium: body(color: secondary, weight: FontWeight.w600),
      labelSmall: body(color: secondary),
    );
  }

  /// Monospace style for code/terminal/id surfaces, resolving D2Coding with a
  /// safe fallback chain.
  ///
  /// There is deliberately no `size` parameter: requirement 4 unifies every
  /// text surface on 16pt, so this style is always [sizeBody]. Hierarchy comes
  /// from [color] and [weight] only. Keeping the size off the API means the code
  /// cannot even express a sub-16pt intent.
  static TextStyle mono({Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: 'D2Coding',
    fontFamilyFallback: monospaceFallback,
    fontSize: sizeBody,
    height: 1.4,
    letterSpacing: 0,
    color: color,
    fontWeight: weight,
  );
}
