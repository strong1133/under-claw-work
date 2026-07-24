import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/ui/design_tokens.dart';
import 'package:under_claw_work/ui/environment_screen.dart';
import 'package:under_claw_work/ui/status_pill.dart';
import 'package:under_claw_work/ui/typography.dart';

import 'test_support.dart';

void main() {
  // Load the real D2Coding faces so goldens render true glyphs, not tofu boxes.
  setUpAll(loadRealFonts);

  // Seed the registry with STABLE ids so the golden is deterministic (the real
  // service mints random ENV ids, which would render differently each run).
  Directory seedWorkspace() {
    final temporary = Directory.systemTemp.createTempSync('under-claw-golden-');
    final workspace = Workspace(temporary)..ensureLayout();
    final registry = {
      'schema_version': 1,
      'environments': [
        {
          'schema_version': 1,
          'id': 'ENV-macbook',
          'type': 'environment',
          'machine_key': 'MK-macbook',
          'alias': 'JSJ MacBook',
          'os': 'macos',
          'architecture': 'macosArm64',
          'kind': 'desktop',
          'capabilities': ['git', 'gui'],
          'status': 'active',
          'registered_at': '2026-07-24T00:00:00Z',
          'updated_at': '2026-07-24T00:00:00Z',
        },
        {
          'schema_version': 1,
          'id': 'ENV-ci-runner',
          'type': 'environment',
          'machine_key': 'MK-server',
          'alias': 'CI Runner',
          'os': 'linux',
          'architecture': 'linuxX64',
          'kind': 'server',
          'capabilities': ['git', 'docker'],
          'status': 'inactive',
          'registered_at': '2026-07-24T00:00:00Z',
          'updated_at': '2026-07-24T00:00:00Z',
        },
      ],
    };
    File(
      p.join(workspace.config.path, 'environments.yaml'),
    ).writeAsStringSync('${jsonEncode(registry)}\n');
    return temporary;
  }

  testWidgets('Environment management screen matches golden', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1120, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final root = seedWorkspace();
    addTearDown(() => root.deleteSync(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        home: EnvironmentManagementScreen(workspaceRoot: root),
      ),
    );
    await tester.pumpAndSettle();

    // Sanity: data reaches the panel through Core (not a mock).
    expect(find.text('JSJ MacBook'), findsWidgets);
    expect(find.text('CI Runner'), findsWidgets);

    await expectLater(
      find.byType(EnvironmentManagementScreen),
      matchesGoldenFile('goldens/environment_screen.png'),
    );
  }, tags: 'golden');

  testWidgets('Design token gallery matches golden', (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        home: const Scaffold(body: _TokenGallery()),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(_TokenGallery),
      matchesGoldenFile('goldens/token_gallery.png'),
    );
  }, tags: 'golden');
}

/// A compact visual proof-sheet of the token layer: palette swatches, the
/// 16pt-default type scale, monospace surface, and every status pairing
/// (colour + icon + text).
class _TokenGallery extends StatelessWidget {
  const _TokenGallery();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(AppTokens.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Under Claw Work — token system', style: text.headlineMedium),
          const SizedBox(height: AppTokens.spaceLg),
          Wrap(
            spacing: AppTokens.spaceSm,
            children: const [
              _Swatch('background', AppTokens.backgroundDark),
              _Swatch('surface', AppTokens.surfaceDark),
              _Swatch('raised', AppTokens.surfaceRaisedDark),
              _Swatch('accent', AppTokens.accent),
              _Swatch('accentAlt', AppTokens.accentAlt),
            ],
          ),
          const SizedBox(height: AppTokens.spaceXl),
          Text('Title 20 (exception)', style: text.titleLarge),
          Text('Body / input / list default — 16pt', style: text.bodyLarge),
          Text('Label 13 (exception)', style: text.labelSmall),
          const SizedBox(height: AppTokens.spaceMd),
          Text(
            'const id = "ENV-1a2b3c";  // D2Coding → monospace fallback',
            style: AppTypography.mono(color: AppTokens.textSecondaryDark),
          ),
          const SizedBox(height: AppTokens.spaceXl),
          Wrap(
            spacing: AppTokens.spaceSm,
            runSpacing: AppTokens.spaceSm,
            children: const [
              StatusPill(kind: AppStatusKind.success, label: 'active'),
              StatusPill(kind: AppStatusKind.neutral, label: 'inactive'),
              StatusPill(kind: AppStatusKind.danger, label: 'retired'),
              StatusPill(kind: AppStatusKind.warning),
              StatusPill(kind: AppStatusKind.info),
              StatusPill(kind: AppStatusKind.conflict),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 48,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            border: Border.all(color: AppTokens.borderDark),
          ),
        ),
        const SizedBox(height: AppTokens.spaceXs),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
