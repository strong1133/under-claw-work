import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/ui/font_detection.dart';
import 'package:under_claw_work/ui/typography.dart';

void main() {
  const resolver = MonospaceFontResolver();

  group('D2Coding installation detection (requirement 4)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('font-detect-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('detects an installed D2Coding face by scanning a font directory', () {
      File('${dir.path}/D2Coding.ttf').writeAsBytesSync(const [0, 1, 2]);
      final result = resolver.detect(searchDirectories: [dir]);
      expect(result.systemInstalled, isTrue);
      expect(result.matchedPath, endsWith('D2Coding.ttf'));
      expect(result.available, isTrue);
    });

    test('matches case-insensitively and only real font extensions', () {
      File('${dir.path}/d2coding-Bold.OTF').writeAsBytesSync(const [0]);
      File('${dir.path}/notes-about-d2coding.txt').writeAsBytesSync(const [0]);
      final result = resolver.detect(searchDirectories: [dir]);
      expect(result.systemInstalled, isTrue);
      expect(result.matchedPath!.toLowerCase(), endsWith('.otf'));
    });

    test('reports absent when neither installed nor bundled', () {
      final result = resolver.detect(searchDirectories: [dir], bundled: false);
      expect(result.systemInstalled, isFalse);
      expect(result.available, isFalse);
    });

    test('bundled asset makes the face available even with no install', () {
      final result = resolver.detect(searchDirectories: [dir], bundled: true);
      expect(result.systemInstalled, isFalse);
      expect(result.available, isTrue);
    });

    test('missing directories are tolerated (no throw)', () {
      final result = resolver.detect(
        searchDirectories: [Directory('${dir.path}/does-not-exist')],
      );
      expect(result.available, isFalse);
    });
  });

  group('monospace family resolution + fallback', () {
    test(
      'resolves to D2Coding when available, native fallback when absent',
      () {
        const available = D2CodingDetection(
          bundled: true,
          systemInstalled: false,
        );
        const absent = D2CodingDetection(
          bundled: false,
          systemInstalled: false,
        );
        expect(resolver.resolveFamily(available), 'D2Coding');
        expect(resolver.resolveFallback(available).first, 'D2Coding');
        // Degrades to the first native monospace face, not tofu.
        expect(resolver.resolveFamily(absent), 'Menlo');
        expect(resolver.resolveFallback(absent), isNot(contains('D2Coding')));
        expect(resolver.resolveFallback(absent), contains('monospace'));
      },
    );
  });

  group('default system font directories per OS', () {
    test('macOS includes the user + system font locations', () {
      final dirs = MonospaceFontResolver.defaultSystemFontDirectories(
        platform: 'macos',
        environment: {'HOME': '/Users/tester'},
      );
      final paths = dirs.map((d) => d.path).toList();
      expect(paths, contains('/Users/tester/Library/Fonts'));
      expect(paths, contains('/Library/Fonts'));
    });

    test('linux and windows resolve their known directories', () {
      final linux = MonospaceFontResolver.defaultSystemFontDirectories(
        platform: 'linux',
        environment: {'HOME': '/home/tester'},
      ).map((d) => d.path);
      expect(linux, contains('/home/tester/.fonts'));
      expect(linux, contains('/usr/share/fonts'));

      final windows = MonospaceFontResolver.defaultSystemFontDirectories(
        platform: 'windows',
        environment: {'LOCALAPPDATA': r'C:\Users\t\AppData\Local'},
      ).map((d) => d.path);
      expect(windows, contains(r'C:\Windows\Fonts'));
    });
  });

  group('typography contract (requirement 4)', () {
    test('mono default size is 16, matching the D2Coding body size', () {
      expect(AppTypography.sizeCode, 16);
      expect(AppTypography.sizeBody, 16);
    });

    test('bundled build resolves the monospace family to D2Coding', () {
      expect(AppTypography.bundlesD2Coding, isTrue);
      expect(AppTypography.monospaceFamily, 'D2Coding');
      expect(AppTypography.monospaceFallback, contains('monospace'));
    });
  });
}
