import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final root = Directory.current;

  String read(String relative) =>
      File(p.join(root.path, relative)).readAsStringSync();

  test('host context templates describe the non-replacement boundary', () {
    const templates = [
      'AGENTS.md',
      'CLAUDE.md',
      'personas/generic/SYSTEM.md',
      'personas/claude-code/CLAUDE.md',
      'personas/codex/AGENTS.md',
      'personas/hermes/AGENTS.md',
      'personas/hermes/SOUL.md',
      'personas/gemini/GEMINI.md',
      'personas/copilot/copilot-instructions.md',
      'personas/cursor/under-claw-work.mdc',
    ];

    for (final relative in templates) {
      final file = File(p.join(root.path, relative));
      expect(file.existsSync(), isTrue, reason: relative);
      expect(file.readAsStringSync().trim(), isNotEmpty, reason: relative);
    }

    for (final relative in [
      'AGENTS.md',
      'personas/generic/SYSTEM.md',
      'personas/claude-code/CLAUDE.md',
      'personas/codex/AGENTS.md',
      'personas/hermes/AGENTS.md',
    ]) {
      expect(
        read(relative).toLowerCase(),
        anyOf(
          contains('does not replace'),
          contains('not a replacement'),
          contains('대체하지'),
        ),
        reason: relative,
      );
    }
  });

  test('five-skill bundle includes pinned Jarvis plan and local guide', () {
    final lock = read('skills/bundle.lock.yaml');
    for (final skill in [
      'under-claw-work',
      'under-claw-work-plan',
      'under-claw-meta-prompt',
      'under-claw-jarvis-plan-loop',
      'under-claw-jarvis-plan',
    ]) {
      expect(lock, contains('$skill:'), reason: skill);
    }

    final installer = read('packaging/install.sh');
    expect(installer, contains('skills/under-claw-work'));
    expect(installer, contains('skills/\$skill'));
    expect(installer, contains('bundled-skills skills personas'));
    expect(installer, isNot(contains('UNDER_CLAW_EXPERIMENTAL_HERMES')));

    final updater = read('packaging/update.sh');
    expect(updater, contains('bundled-skills skills personas'));
  });
}
