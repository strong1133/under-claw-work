import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-layout-');
    workspace = Workspace(temporary);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('every canonical directory survives a clone', () {
    workspace.ensureLayout();

    // Git does not track empty directories, so the standardized tree only
    // reaches another machine if each directory holds a committed file.
    for (final directory in workspace.canonicalDirectories) {
      expect(
        File(p.join(directory.path, Workspace.placeholderName)).existsSync(),
        isTrue,
        reason: '${p.basename(directory.path)} would vanish on clone',
      );
    }

    // Host-local state is rebuildable and must stay out of the repository.
    for (final directory in workspace.hostLocalDirectories) {
      expect(
        File(p.join(directory.path, Workspace.placeholderName)).existsSync(),
        isFalse,
      );
    }
  });

  test('the layout manifest records the standardized tree and version', () {
    workspace.ensureLayout();

    final manifest = workspace.layoutManifest.readAsStringSync();
    expect(manifest, contains('type: workspace_layout'));
    expect(manifest, contains('layout_version: ${Workspace.layoutVersion}'));
    expect(manifest, contains('- workdb/tasks'));
    expect(manifest, contains('- workdb/knowledge'));
    expect(manifest, contains('- .worklog'));
    // Portable canonical data never records a host absolute path.
    expect(manifest, isNot(contains(temporary.path)));
  });

  test('ensureLayout is idempotent and does not rewrite the manifest', () {
    workspace.ensureLayout();
    final first = workspace.layoutManifest.statSync().modified;
    final content = workspace.layoutManifest.readAsStringSync();

    workspace.ensureLayout();

    expect(workspace.layoutManifest.readAsStringSync(), content);
    expect(workspace.layoutManifest.statSync().modified, first);
  });

  test('host-local state is excluded from the repository', () {
    workspace.ensureLayout();

    final ignore = File(p.join(temporary.path, '.gitignore'));
    expect(ignore.existsSync(), isTrue);
    expect(ignore.readAsStringSync().split('\n'), contains('.worklog/'));
    // The projection must never reach a clone.
    expect(p.isWithin(workspace.local.path, workspace.database.path), isTrue);
  });

  test('an existing .gitignore keeps its rules and gains ours once', () {
    final ignore = File(p.join(temporary.path, '.gitignore'))
      ..writeAsStringSync('build/\n*.log');

    workspace.ensureLayout();
    workspace.ensureLayout();

    final lines = ignore.readAsStringSync().split('\n');
    expect(lines, containsAll(['build/', '*.log']));
    expect(lines.where((line) => line == '.worklog/'), hasLength(1));
  });

  test('placeholders never decode as canonical entities', () {
    workspace.ensureLayout();
    EntityService(workspace).create(kind: EntityKind.domain, title: 'Product');

    expect(
      CanonicalRepository(workspace).list(EntityKind.domain),
      hasLength(1),
    );
    expect(TaskRepository(workspace).list(), isEmpty);
  });

  group('inspectLayout', () {
    test('reports a freshly normalized workspace as ok', () {
      workspace.ensureLayout();

      final report = workspace.inspectLayout();

      expect(report.status, 'ok');
      expect(report.isComplete, isTrue);
      expect(report.manifestVersion, Workspace.layoutVersion);
    });

    test('reports a repository that predates the manifest', () {
      workspace.ensureLayout();
      workspace.layoutManifest.deleteSync();

      final report = workspace.inspectLayout();

      expect(report.status, 'unversioned');
      expect(report.isVersioned, isFalse);
      expect(report.missingDirectories, isEmpty);
    });

    test('reports a manifest written by a different layout version', () {
      workspace.ensureLayout();
      workspace.layoutManifest.writeAsStringSync(
        'schema_version: 1\ntype: workspace_layout\nlayout_version: 99\n',
      );

      final report = workspace.inspectLayout();

      expect(report.status, 'version_mismatch');
      expect(report.manifestVersion, 99);
      expect(report.isCurrent, isFalse);
    });

    test('names the directories a damaged repository is missing', () {
      workspace.ensureLayout();
      workspace.events.deleteSync(recursive: true);

      final report = workspace.inspectLayout();

      expect(report.status, 'incomplete');
      expect(report.missingDirectories, contains('workdb/events'));
      expect(report.isComplete, isFalse);
    });

    test('flags a directory that would not survive a clone', () {
      workspace.ensureLayout();
      File(
        p.join(workspace.matches.path, Workspace.placeholderName),
      ).deleteSync();

      final report = workspace.inspectLayout();

      expect(report.status, 'not_portable');
      expect(report.missingPlaceholders, contains('workdb/matches'));
    });

    test('does not repair the workspace while diagnosing it', () {
      workspace.ensureLayout();
      workspace.runs.deleteSync(recursive: true);

      workspace.inspectLayout();

      expect(workspace.runs.existsSync(), isFalse);
    });
  });
}
