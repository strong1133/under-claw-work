import 'dart:io';

/// Result of probing for the D2Coding monospace face.
class D2CodingDetection {
  const D2CodingDetection({
    required this.bundled,
    required this.systemInstalled,
    this.matchedPath,
  });

  /// True when the app ships the face as a Flutter asset (declared in
  /// `pubspec.yaml` under `assets/fonts/`).
  final bool bundled;

  /// True when a D2Coding face file was found in a well-known OS font directory.
  final bool systemInstalled;

  /// The first font file that matched, for diagnostics/reporting. Never a
  /// secret — only a filesystem path.
  final String? matchedPath;

  /// The face is usable when it is either bundled with the app or installed on
  /// the host. Callers pick D2Coding when true, else fall back to native
  /// monospace faces.
  bool get available => bundled || systemInstalled;

  @override
  String toString() =>
      'D2CodingDetection(bundled: $bundled, systemInstalled: $systemInstalled, '
      'matchedPath: $matchedPath)';
}

/// Detects whether the D2Coding fixed-width face is available to the app and
/// resolves the monospace family accordingly.
///
/// This is the concrete, *verifiable* installation-detection API required by
/// requirement 4: it never downloads a binary and never touches the network —
/// it is a pure filesystem probe of the platform's known font directories plus
/// a bundled-asset flag, so it is deterministic and unit-testable. When the face
/// is neither bundled nor installed, [resolveFamily]/[resolveFallback] degrade
/// to the host's native monospace faces so no code/terminal surface is ever left
/// without a fixed-width font.
class MonospaceFontResolver {
  const MonospaceFontResolver({
    this.primaryFamily = 'D2Coding',
    this.fallbackChain = const [
      'Menlo', // macOS
      'Consolas', // Windows
      'DejaVu Sans Mono', // Linux
      'Roboto Mono',
      'monospace',
    ],
  });

  /// The preferred face when it is available.
  final String primaryFamily;

  /// Native monospace faces, most-specific first, used when [primaryFamily] is
  /// absent (and appended after it when present, as a resilience fallback).
  final List<String> fallbackChain;

  /// File-name fragment that identifies a D2Coding face, matched case-folded.
  static const _needle = 'd2coding';
  static const _fontExtensions = {'.ttf', '.otf', '.ttc'};

  /// Probes for D2Coding.
  ///
  /// [bundled] is supplied by the caller (the app knows whether it declared the
  /// asset in pubspec). [searchDirectories] and [platform] are injectable so
  /// tests can drive detection deterministically against temp directories; in
  /// production they default to the real OS font locations.
  D2CodingDetection detect({
    bool bundled = false,
    List<Directory>? searchDirectories,
    String? platform,
    Map<String, String>? environment,
  }) {
    final dirs =
        searchDirectories ??
        defaultSystemFontDirectories(
          platform: platform ?? Platform.operatingSystem,
          environment: environment ?? Platform.environment,
        );
    for (final dir in dirs) {
      final match = _findInDirectory(dir);
      if (match != null) {
        return D2CodingDetection(
          bundled: bundled,
          systemInstalled: true,
          matchedPath: match,
        );
      }
    }
    return D2CodingDetection(bundled: bundled, systemInstalled: false);
  }

  String? _findInDirectory(Directory dir) {
    if (!dir.existsSync()) return null;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last.toLowerCase();
        if (!name.contains(_needle)) continue;
        final dot = name.lastIndexOf('.');
        if (dot < 0) continue;
        if (_fontExtensions.contains(name.substring(dot))) return entity.path;
      }
    } on FileSystemException {
      // A directory we cannot read (permissions) is simply skipped.
      return null;
    }
    return null;
  }

  /// The monospace family to request: [primaryFamily] when D2Coding is
  /// available, otherwise the first native monospace fallback.
  String resolveFamily(D2CodingDetection detection) =>
      detection.available ? primaryFamily : fallbackChain.first;

  /// The full ordered fallback list to hand to Flutter's `fontFamilyFallback`.
  /// D2Coding leads only when it is available; either way native faces trail so
  /// glyph coverage never collapses to tofu.
  List<String> resolveFallback(D2CodingDetection detection) =>
      detection.available
      ? [primaryFamily, ...fallbackChain]
      : List<String>.from(fallbackChain);

  /// Well-known per-OS user+system font directories.
  static List<Directory> defaultSystemFontDirectories({
    required String platform,
    required Map<String, String> environment,
  }) {
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
    switch (platform) {
      case 'macos':
        return [
          if (home.isNotEmpty) Directory('$home/Library/Fonts'),
          Directory('/Library/Fonts'),
          Directory('/System/Library/Fonts'),
        ];
      case 'linux':
        return [
          if (home.isNotEmpty) Directory('$home/.fonts'),
          if (home.isNotEmpty) Directory('$home/.local/share/fonts'),
          Directory('/usr/share/fonts'),
          Directory('/usr/local/share/fonts'),
        ];
      case 'windows':
        final local = environment['LOCALAPPDATA'];
        return [
          Directory(r'C:\Windows\Fonts'),
          if (local != null && local.isNotEmpty)
            Directory('$local\\Microsoft\\Windows\\Fonts'),
        ];
      default:
        return const [];
    }
  }
}
