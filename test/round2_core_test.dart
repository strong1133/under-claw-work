import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late CanonicalRepository repository;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-round2-');
    workspace = Workspace(temporary)..ensureLayout();
    repository = CanonicalRepository(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('canonical graph CRUD validates IDs and missing relations', () {
    repository.create(
      const CanonicalEntity(
        kind: EntityKind.domain,
        id: 'DOM-example',
        data: {
          'schema_version': 1,
          'id': 'DOM-example',
          'type': 'domain',
          'name': 'Example',
          'title': 'Example',
          'status': 'active',
        },
        body: 'Domain body',
      ),
    );
    repository.create(
      const CanonicalEntity(
        kind: EntityKind.milestone,
        id: 'MLS-example',
        data: {
          'schema_version': 1,
          'id': 'MLS-example',
          'type': 'milestone',
          'domain_id': 'DOM-example',
          'title': 'Milestone',
          'status': 'active',
        },
      ),
    );
    repository.update(
      const CanonicalEntity(
        kind: EntityKind.milestone,
        id: 'MLS-example',
        data: {
          'schema_version': 1,
          'id': 'MLS-example',
          'type': 'milestone',
          'domain_id': 'DOM-example',
          'title': 'Updated',
          'status': 'active',
        },
      ),
    );
    expect(
      repository.get(EntityKind.milestone, 'MLS-example')!.data['title'],
      'Updated',
    );
    expect(
      () => repository.create(
        const CanonicalEntity(
          kind: EntityKind.objective,
          id: 'BAD-example',
          data: {'id': 'BAD-example', 'type': 'objective'},
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => repository.create(
        const CanonicalEntity(
          kind: EntityKind.objective,
          id: 'OBJ-missing',
          data: {
            'id': 'OBJ-missing',
            'type': 'objective',
            'scope': {'domain_id': 'DOM-missing'},
          },
        ),
      ),
      throwsFormatException,
    );
  });

  test('deleting SQLite rebuilds entity graph control run and relations', () {
    repository.create(
      const CanonicalEntity(
        kind: EntityKind.domain,
        id: 'DOM-example',
        data: {
          'schema_version': 1,
          'id': 'DOM-example',
          'type': 'domain',
          'name': 'Example',
          'title': 'Example',
          'status': 'active',
        },
      ),
    );
    repository.create(
      const CanonicalEntity(
        kind: EntityKind.milestone,
        id: 'MLS-example',
        data: {
          'schema_version': 1,
          'id': 'MLS-example',
          'type': 'milestone',
          'domain_id': 'DOM-example',
          'title': 'Example milestone',
          'status': 'active',
        },
      ),
    );
    repository.create(
      const CanonicalEntity(
        kind: EntityKind.knowledge,
        id: 'KNW-example',
        data: {
          'schema_version': 1,
          'id': 'KNW-example',
          'type': 'knowledge',
          'kind': 'confirmed_fact',
          'confidence': 'confirmed',
          'scope': {
            'domain_ids': ['DOM-example'],
          },
        },
        body: 'Durable fact',
      ),
    );
    _writeTask(workspace);
    var projection = ProjectionStore(workspace);
    final task = projection.rebuild().single;
    final runId = ControlService(
      workspace,
      projection,
    ).requestStart(task, 'OPR-rebuild');
    projection.dispose();
    workspace.database.deleteSync();

    projection = ProjectionStore(workspace);
    projection.rebuild();
    expect(
      projection.open().select(
        'SELECT id FROM canonical_entities WHERE id IN (?, ?, ?)',
        ['DOM-example', 'KNW-example', runId],
      ),
      hasLength(3),
    );
    expect(
      projection.open().select(
        'SELECT target_id FROM entity_relations WHERE source_id = ?',
        ['KNW-example'],
      ).single['target_id'],
      'DOM-example',
    );
    expect(
      projection.open().select('SELECT operation_id FROM runs WHERE id = ?', [
        runId,
      ]).single['operation_id'],
      'OPR-rebuild',
    );
    projection.dispose();
  });

  test(
    'setup initializes user-selected Git workspace without secrets',
    () async {
      final selected = Directory(p.join(temporary.path, 'selected'));
      final result = await SetupService().setup(
        SetupRequest(localPath: selected.path, environmentName: 'Test desktop'),
      );
      expect(Directory(p.join(selected.path, '.git')).existsSync(), isTrue);
      expect(result.workspace.database.existsSync(), isTrue);
      expect(
        File(p.join(selected.path, '.gitignore')).readAsStringSync(),
        contains('.worklog/'),
      );
      final repeated = await SetupService().setup(
        SetupRequest(localPath: selected.path, environmentName: 'Test desktop'),
      );
      expect(repeated.environmentId, result.environmentId);
      expect(
        () => SetupService().setup(
          SetupRequest(
            localPath: p.join(temporary.path, 'bad-clone'),
            environmentName: 'Test',
            privateRemote: Uri.parse('https://token@example.invalid/repo.git'),
          ),
        ),
        throwsFormatException,
      );
    },
  );
}

void _writeTask(Workspace workspace) {
  File(p.join(workspace.tasks.path, 'TSK-example.yaml')).writeAsStringSync('''
schema_version: 1
id: TSK-example
domain_id: DOM-example
milestone_id: MLS-example
title: "Example task"
status: ready
auto_derive_tasks: false
target_environment: ENV-local
prompt:
  draft_revision: 2
  meta_source_revision: 2
  meta_source_sha256: "ebf12ef47cf575b3ba9a3cc019c5310146fdac88f6d1be6618d6e91158c2f174"
  approval: approved
  draft: "Draft"
  meta: "Meta"
''');
}
