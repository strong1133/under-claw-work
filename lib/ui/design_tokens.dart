import 'package:flutter/material.dart';

/// Centralised design tokens for the Under Claw Work desktop shell.
///
/// The visual language takes its *impression* from native developer terminals
/// in the Orca/Warp lineage — a low-chroma dark canvas, dense information
/// panels, tight spacing and a single confident accent — but every value here
/// is an original token. No third-party trademark, logo, colour value or
/// proprietary asset is copied; the palette is re-interpreted from scratch so
/// the product carries its own identity while feeling native to that family of
/// tools.
///
/// Everything that colours, spaces, rounds or sizes the UI flows from this one
/// file, so a future retheme (or a light/dark swap) is a single-surface change.
@immutable
class AppTokens {
  const AppTokens._();

  // ---- Dark canvas (default) ------------------------------------------------
  /// Deepest backdrop behind all panels.
  static const Color backgroundDark = Color(0xFF0E1116);

  /// Standard panel surface.
  static const Color surfaceDark = Color(0xFF161B22);

  /// A raised surface (selected row, popover, command bar).
  static const Color surfaceRaisedDark = Color(0xFF1C232D);

  /// Hairline divider / panel border.
  static const Color borderDark = Color(0xFF2A313C);
  static const Color borderStrongDark = Color(0xFF3A434F);

  static const Color textPrimaryDark = Color(0xFFE6EDF3);
  static const Color textSecondaryDark = Color(0xFF9BA7B4);
  static const Color textMutedDark = Color(0xFF6B7684);

  // ---- Light canvas ---------------------------------------------------------
  static const Color backgroundLight = Color(0xFFF6F8FA);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceRaisedLight = Color(0xFFEDF1F5);
  static const Color borderLight = Color(0xFFD5DCE3);
  static const Color borderStrongLight = Color(0xFFBAC4CE);
  static const Color textPrimaryLight = Color(0xFF1A1F26);
  static const Color textSecondaryLight = Color(0xFF48525E);
  static const Color textMutedLight = Color(0xFF6B7684);

  // ---- Accents (brightness-neutral) ----------------------------------------
  /// Primary accent — a calm teal that reads on both canvases.
  static const Color accent = Color(0xFF37C4B5);
  static const Color accentPressed = Color(0xFF2AA79A);

  /// Secondary accent for provenance / agent affordances.
  static const Color accentAlt = Color(0xFFA987F0);

  // ---- Status ---------------------------------------------------------------
  // Status is *never* signalled by colour alone; each pairs with an icon and a
  // text label in [AppStatusStyle]. These are the colours those pairings use.
  static const Color statusSuccess = Color(0xFF3FB950);
  static const Color statusWarning = Color(0xFFE3B341);
  static const Color statusDanger = Color(0xFFF85149);
  static const Color statusInfo = Color(0xFF58A6FF);
  static const Color statusNeutral = Color(0xFF8B98A5);

  /// A deliberately distinct hue for sync/merge conflict so it never blurs with
  /// plain danger.
  static const Color statusConflict = Color(0xFFDB6D28);

  // ---- Spacing scale (4pt base) --------------------------------------------
  static const double spaceXxs = 2;
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double spaceXxl = 32;

  // ---- Radii ----------------------------------------------------------------
  static const double radiusSm = 6;
  static const double radiusMd = 10;
  static const double radiusLg = 14;

  /// Dense list row height for information-rich panels.
  static const double rowHeight = 40;

  /// Standard side-panel width for the master/detail shell.
  static const double panelWidth = 320;
}

/// Which visual family (colour + icon + text) a status maps to. Encoding a
/// status as one of these guarantees an icon and a label always accompany the
/// colour — the UI is legible to colour-blind users and in monochrome.
enum AppStatusKind { success, warning, danger, info, neutral, conflict }

@immutable
class AppStatusStyle {
  const AppStatusStyle({
    required this.color,
    required this.icon,
    required this.label,
  });

  final Color color;
  final IconData icon;
  final String label;

  static AppStatusStyle of(AppStatusKind kind) => switch (kind) {
    AppStatusKind.success => const AppStatusStyle(
      color: AppTokens.statusSuccess,
      icon: Icons.check_circle_outline,
      label: 'active',
    ),
    AppStatusKind.warning => const AppStatusStyle(
      color: AppTokens.statusWarning,
      icon: Icons.warning_amber_rounded,
      label: 'warning',
    ),
    AppStatusKind.danger => const AppStatusStyle(
      color: AppTokens.statusDanger,
      icon: Icons.error_outline,
      label: 'error',
    ),
    AppStatusKind.info => const AppStatusStyle(
      color: AppTokens.statusInfo,
      icon: Icons.info_outline,
      label: 'info',
    ),
    AppStatusKind.neutral => const AppStatusStyle(
      color: AppTokens.statusNeutral,
      icon: Icons.remove_circle_outline,
      label: 'inactive',
    ),
    AppStatusKind.conflict => const AppStatusStyle(
      color: AppTokens.statusConflict,
      icon: Icons.merge_type,
      label: 'conflict',
    ),
  };

  /// Maps a lifecycle status string to a status kind (icon+colour+text).
  static AppStatusKind kindForLifecycle(String status) => switch (status) {
    'active' => AppStatusKind.success,
    'inactive' => AppStatusKind.neutral,
    'retired' => AppStatusKind.danger,
    _ => AppStatusKind.info,
  };

  /// Maps a Match review state to a status kind. Revoked uses the distinct
  /// conflict hue so a corrected mis-match never reads as a plain error.
  static AppStatusKind kindForReview(String reviewState) =>
      switch (reviewState) {
        'approved' => AppStatusKind.success,
        'rejected' => AppStatusKind.danger,
        'revoked' => AppStatusKind.conflict,
        'proposed' => AppStatusKind.info,
        _ => AppStatusKind.neutral,
      };
}
