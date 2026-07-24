import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';
import 'package:under_claw_work/ui/app_theme.dart';

/// Loads the REAL bundled D2Coding faces into the test font collection so
/// golden tests render actual glyphs instead of the flutter_test default
/// "Ahem"/FlutterTest boxes (the tofu blocks). Reads the same asset files the
/// app ships (`assets/fonts/D2Coding*.ttf`); no download, no network.
Future<void> loadRealFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  ByteData bytes(String path) {
    final data = File(path).readAsBytesSync();
    return ByteData.view(Uint8List.fromList(data).buffer);
  }

  final loader = FontLoader('D2Coding')
    ..addFont(Future.value(bytes('assets/fonts/D2Coding.ttf')))
    ..addFont(Future.value(bytes('assets/fonts/D2Coding-Bold.ttf')));
  await loader.load();
}

/// A theme whose base family is the loaded, real D2Coding face so EVERY text
/// surface in a golden renders true glyphs (no tofu). The app's own theme keeps
/// its native default family; this override exists only to prove real-glyph
/// rendering with the bundled face.
ThemeData goldenTheme([Brightness brightness = Brightness.dark]) {
  final base = AppTheme.of(brightness);
  // Component themes (chips, inputs) capture a family-less TextStyle, so apply
  // D2Coding to those too — otherwise their labels would still render as tofu
  // boxes even though the body text uses the real face.
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'D2Coding'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'D2Coding'),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: (base.chipTheme.labelStyle ?? const TextStyle()).copyWith(
        fontFamily: 'D2Coding',
      ),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: (base.inputDecorationTheme.labelStyle ?? const TextStyle())
          .copyWith(fontFamily: 'D2Coding'),
      hintStyle: (base.inputDecorationTheme.hintStyle ?? const TextStyle())
          .copyWith(fontFamily: 'D2Coding'),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: (base.appBarTheme.titleTextStyle ?? const TextStyle())
          .copyWith(fontFamily: 'D2Coding'),
    ),
  );
}

/// Creates a temp workspace with a stable, deterministic set of environments,
/// agents, a knowledge graph and a proposed match, so screens and goldens are
/// reproducible. All ids are fixed (the real services mint random ids).
Directory seedManagementWorkspace() {
  final root = Directory.systemTemp.createTempSync('under-claw-mgmt-');
  final ws = Workspace(root)..ensureLayout();
  _writeEnvironments(ws);
  _writeAgents(ws);
  _writeGraph(ws);
  return root;
}

void _writeEnvironments(Workspace ws) {
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
    p.join(ws.config.path, 'environments.yaml'),
  ).writeAsStringSync('${jsonEncode(registry)}\n');
}

void _writeAgents(Workspace ws) {
  final registry = {
    'schema_version': 1,
    'agents': [
      {
        'schema_version': 1,
        'id': 'AGT-hermes',
        'type': 'agent',
        'name': 'Hermes',
        'kind': 'orchestrator',
        'environment_id': 'ENV-macbook',
        'status': 'active',
        'registered_at': '2026-07-24T00:00:00Z',
        'updated_at': '2026-07-24T00:00:00Z',
      },
      {
        'schema_version': 1,
        'id': 'AGT-athena',
        'type': 'agent',
        'name': 'Athena',
        'kind': 'reviewer',
        'environment_id': 'ENV-ci-runner',
        'status': 'inactive',
        'registered_at': '2026-07-24T00:00:00Z',
        'updated_at': '2026-07-24T00:00:00Z',
      },
    ],
  };
  File(
    p.join(ws.config.path, 'agents.yaml'),
  ).writeAsStringSync('${jsonEncode(registry)}\n');
}

void _writeGraph(Workspace ws) {
  File(
    p.join(ws.domains.path, 'DOM-mgmt', 'domain.md'),
  ).createSync(recursive: true);
  File(p.join(ws.domains.path, 'DOM-mgmt', 'domain.md')).writeAsStringSync(
    _frontmatter({
      'schema_version': 1,
      'id': 'DOM-mgmt',
      'type': 'domain',
      'name': 'Management console',
    }),
  );
  File(
    p.join(ws.milestones.path, 'MLS-mgmt', 'milestone.md'),
  ).createSync(recursive: true);
  File(
    p.join(ws.milestones.path, 'MLS-mgmt', 'milestone.md'),
  ).writeAsStringSync(
    _frontmatter({
      'schema_version': 1,
      'id': 'MLS-mgmt',
      'type': 'milestone',
      'name': 'Desktop experience',
      'domain_id': 'DOM-mgmt',
    }),
  );
  // Current knowledge that supersedes the older item.
  File(p.join(ws.knowledge.path, 'KNW-fact.md')).writeAsStringSync(
    _frontmatter({
      'schema_version': 1,
      'id': 'KNW-fact',
      'type': 'knowledge',
      'kind': 'confirmed_fact',
      'title': 'Registry is Git-canonical',
      'scope': {
        'domain_ids': ['DOM-mgmt'],
        'milestone_ids': ['MLS-mgmt'],
      },
      'confidence': 'confirmed',
      'origin': {'kind': 'agent', 'actor_id': 'agent:hermes'},
      'relations': {
        'supersedes': ['KNW-old'],
      },
    }, body: 'The canonical store is Git YAML; SQLite is a projection.'),
  );
  // Older, superseded knowledge in the same scope.
  File(p.join(ws.knowledge.path, 'KNW-old.md')).writeAsStringSync(
    _frontmatter({
      'schema_version': 1,
      'id': 'KNW-old',
      'type': 'knowledge',
      'kind': 'assumption',
      'title': 'Registry lived in SQLite (outdated)',
      'scope': {
        'domain_ids': ['DOM-mgmt'],
      },
      'confidence': 'uncertain',
      'origin': {'kind': 'agent', 'actor_id': 'agent:athena'},
    }, body: 'Superseded by KNW-fact.'),
  );
  // A proposed match linking the knowledge to the milestone.
  File(p.join(ws.matches.path, 'MAT-review.yaml')).writeAsStringSync(
    '${jsonEncode({
      'schema_version': 1,
      'id': 'MAT-review',
      'type': 'match',
      'subject': {'kind': 'knowledge', 'id': 'KNW-fact'},
      'target': {'kind': 'milestone', 'id': 'MLS-mgmt'},
      'match_mode': 'manual',
      'actor': {'actor_type': 'user', 'actor_id': 'user:jsj'},
      'review_state': 'proposed',
      'evidence': 'Fact is the milestone acceptance basis.',
      'source': 'REF-desktop-gui-management-console',
      'knowledge_ids': ['KNW-fact'],
      'milestone_id': 'MLS-mgmt',
      'history': [
        {'state': 'proposed', 'action': 'proposed', 'actor_type': 'user', 'actor_id': 'user:jsj', 'at': '2026-07-24T00:00:00Z'},
      ],
      'created_at': '2026-07-24T00:00:00Z',
      'updated_at': '2026-07-24T00:00:00Z',
    })}\n',
  );
}

String _frontmatter(Map<String, Object?> data, {String body = ''}) =>
    '---\n${jsonEncode(data)}\n---\n$body';
