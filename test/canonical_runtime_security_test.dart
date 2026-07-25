import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late CanonicalRepository canonical;
  late EntityService entities;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'canonical-runtime-security-',
    );
    workspace = Workspace(temporary)..ensureLayout();
    canonical = CanonicalRepository(workspace);
    entities = EntityService(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('Task reads bind document id to the requested canonical path', () {
    final file = File('${workspace.tasks.path}/TSK-path/task.yaml')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(TaskCodec.encode(_task(id: 'TSK-document')));
    expect(file.existsSync(), isTrue);

    expect(
      () => TaskRepository(workspace).get('TSK-path'),
      throwsFormatException,
    );
  });

  test('Task Git reads enforce the complete runtime contract', () {
    File('${workspace.tasks.path}/TSK-invalid/task.yaml')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        TaskCodec.encode(_task(id: 'TSK-invalid', title: '')),
      );

    expect(
      () => TaskRepository(workspace).get('TSK-invalid'),
      throwsA(anyOf(isA<FormatException>(), isA<ContractViolation>())),
    );
  });

  test('configured Task scope rejects a Milestone from another Domain', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'A');
    final other = entities.create(kind: EntityKind.domain, title: 'B');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'B milestone',
      domainId: other.id,
    );

    expect(
      () => TaskRepository(
        workspace,
      ).create(_task(domainId: domain.id, milestoneId: milestone.id)),
      throwsFormatException,
    );
  });

  test('Run scope resolver rejects exactly one missing scope document', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'A');

    expect(
      () => buildRunScopeContextSnapshot(
        workspace,
        domainId: domain.id,
        milestoneId: 'MLS-missing',
      ),
      throwsStateError,
    );
  });

  test('canonical discovery ignores nested and wrong-extension files', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'A');
    final data = {
      'schema_version': 1,
      'id': 'PER-nested',
      'type': 'persona',
      'title': 'Nested',
      'status': 'active',
      'domain_id': domain.id,
    };
    File('${workspace.personas.path}/nested/PER-nested.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('---\n${jsonEncode(data)}\n---\nbody\n');
    File('${workspace.personas.path}/PER-wrong.yaml').writeAsStringSync(
      '---\n${jsonEncode({...data, 'id': 'PER-wrong'})}\n---\nbody\n',
    );

    expect(canonical.list(EntityKind.persona), isEmpty);
  });

  test('Task discovery rejects a nested noncanonical task path', () {
    File('${workspace.tasks.path}/nested/TSK-nested/task.yaml')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(TaskCodec.encode(_task(id: 'TSK-nested')));

    expect(TaskRepository(workspace).list, throwsFormatException);
  });

  test('runtime Git reads reject malformed configuration internals', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'A');
    final configurations = ScopeConfigurationService(workspace);
    final persona = configurations.createPersona(
      title: 'Persona',
      body: 'Body',
      domainId: domain.id,
    );
    final group = configurations.createAgentGroup(
      title: 'Group',
      domainId: domain.id,
      roles: [AgentRole(name: 'worker', personaId: persona.id)],
    );
    final channel = configurations.createChannelBinding(
      title: 'Channel',
      platform: 'discord',
      externalChannelId: '123',
      agentGroupId: group.id,
      domainId: domain.id,
    );
    final mcp = configurations.createMcpBinding(
      title: 'MCP',
      bindingKey: 'valid-key',
      access: 'read',
      domainId: domain.id,
    );

    void overwrite(CanonicalEntity entity, Map<String, Object?> data) {
      canonical
          .fileFor(entity.kind, entity.id)
          .writeAsStringSync('---\n${jsonEncode(data)}\n---\n${entity.body}\n');
    }

    overwrite(group, {
      ...group.data,
      'roles': ['not-an-object'],
    });
    expect(
      () => canonical.get(EntityKind.agentGroup, group.id),
      throwsA(isA<ContractViolation>()),
    );

    overwrite(channel, {...channel.data, 'platform': 'arbitrary'});
    expect(
      () => canonical.get(EntityKind.channelBinding, channel.id),
      throwsA(isA<ContractViolation>()),
    );

    overwrite(mcp, {...mcp.data, 'binding_key': '../invalid'});
    expect(
      () => canonical.get(EntityKind.mcpBinding, mcp.id),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('Repository runtime contract rejects local and credential locators', () {
    final repository = CanonicalRepository(workspace);
    CanonicalEntity repositoryEntity(String id, String kind, String value) =>
        CanonicalEntity(
          kind: EntityKind.repository,
          id: id,
          data: {
            'schema_version': 1,
            'id': id,
            'type': 'repository',
            'title': 'Host-local locator',
            'status': 'active',
            'locator': {'kind': kind, 'value': value},
          },
        );

    expect(
      () => repository.create(
        repositoryEntity('REP-local', 'local_path', '/home/user/private'),
      ),
      throwsA(isA<ContractViolation>()),
    );
    expect(
      () => repository.create(
        repositoryEntity(
          'REP-userinfo',
          'git_remote',
          'https://user:token@example.invalid/private.git',
        ),
      ),
      throwsA(isA<ContractViolation>()),
    );
    final credentialQueryKey = ['access', 'token'].join('_');
    expect(
      () => repository.create(
        repositoryEntity(
          'REP-query',
          'git_remote',
          Uri.https('example.invalid', '/private.git', {
            credentialQueryKey: 'redacted',
          }).toString(),
        ),
      ),
      throwsA(isA<ContractViolation>()),
    );
    expect(
      () => repository.create(
        repositoryEntity(
          'REP-ssh-password',
          'git_remote',
          'ssh://user:plaintext-password@example.invalid/private.git',
        ),
      ),
      throwsA(isA<ContractViolation>()),
    );
  });

  test('Task mutation rejects archived scope anchors but remains readable', () {
    final entities = EntityService(workspace);
    final canonical = CanonicalRepository(workspace);
    final tasks = TaskRepository(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    final task = tasks.create(
      WorkTask(
        id: 'TSK-archived-scope',
        domainId: domain.id,
        milestoneId: milestone.id,
        title: 'Archived scope task',
        status: TaskStatus.draft,
        promptDraft: 'draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-local',
      ),
    );
    canonical.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'archived'},
        body: milestone.body,
      ),
    );

    expect(tasks.get(task.id)?.id, task.id);
    expect(
      () => tasks.update(task.copyWith(title: 'Changed after archive')),
      throwsFormatException,
    );
  });

  test('Run scope context snapshot is write-once', () {
    const originalSnapshot = <String, Object?>{
      'status': 'resolved',
      'domain_id': 'DOM-a',
      'milestone_id': 'MLS-a',
    };
    const run = CanonicalEntity(
      kind: EntityKind.run,
      id: 'RUN-snapshot',
      data: {
        'schema_version': 1,
        'id': 'RUN-snapshot',
        'type': 'run',
        'operation_id': 'OPR-snapshot',
        'task_id': 'TSK-snapshot',
        'status': 'running',
        'created_at': '2026-07-25T00:00:00Z',
        'scope_context_snapshot': originalSnapshot,
      },
    );
    canonical.create(run);

    final completed = CanonicalEntity(
      kind: run.kind,
      id: run.id,
      data: {...run.data, 'status': 'completed'},
    );
    expect(() => canonical.update(completed), returnsNormally);

    expect(
      () => canonical.update(
        CanonicalEntity(
          kind: run.kind,
          id: run.id,
          data: {
            ...completed.data,
            'scope_context_snapshot': {
              ...originalSnapshot,
              'domain_id': 'DOM-forged',
            },
          },
        ),
      ),
      throwsStateError,
    );
    expect(
      () => canonical.update(
        CanonicalEntity(
          kind: run.kind,
          id: run.id,
          data: {...completed.data}..remove('scope_context_snapshot'),
        ),
      ),
      throwsStateError,
    );
  });

  test('canonical reads and mutations reject symbolic-link files', () {
    if (Platform.isWindows) return;
    final entity = entities.create(kind: EntityKind.domain, title: 'Safe');
    final canonicalFile = canonical.fileFor(EntityKind.domain, entity.id);
    final external = File('${temporary.path}-external-domain.md')
      ..writeAsStringSync(canonicalFile.readAsStringSync());
    addTearDown(() {
      if (external.existsSync()) external.deleteSync();
    });
    canonicalFile.deleteSync();
    Link(canonicalFile.path).createSync(external.path);
    final before = external.readAsStringSync();

    expect(
      () => canonical.get(EntityKind.domain, entity.id),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      () => canonical.update(
        CanonicalEntity(
          kind: entity.kind,
          id: entity.id,
          data: {...entity.data, 'title': 'Forged'},
          body: entity.body,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(external.readAsStringSync(), before);
  });

  test('workspace layout rejects symbolic-link directories', () {
    if (Platform.isWindows) return;
    workspace.workdb.deleteSync(recursive: true);
    final external = Directory('${temporary.path}-external-workdb')
      ..createSync();
    addTearDown(() {
      if (external.existsSync()) external.deleteSync(recursive: true);
    });
    Link(workspace.workdb.path).createSync(external.path);

    expect(workspace.ensureLayout, throwsA(isA<FileSystemException>()));
    expect(external.listSync(), isEmpty);
  });
}

WorkTask _task({
  String id = 'TSK-secure',
  String domainId = 'DOM-legacy',
  String milestoneId = 'MLS-legacy',
  String title = 'Task',
}) => WorkTask(
  id: id,
  domainId: domainId,
  milestoneId: milestoneId,
  title: title,
  status: TaskStatus.draft,
  promptDraft: 'draft',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  autoDeriveTasks: false,
  targetEnvironment: 'ENV-test',
);
