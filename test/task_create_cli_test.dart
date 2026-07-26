import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

import '../bin/worklog.dart' as cli;

void main() {
  late Directory temporary;
  late Workspace workspace;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'under-claw-task-create-cli-',
    );
    workspace = Workspace(temporary)..ensureLayout();
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('modern task-create supports optional scope and environment', () async {
    await cli.main(['task-create', temporary.path, 'Unscoped']);
    var task = TaskRepository(workspace).list().single;
    expect(task.title, 'Unscoped');
    expect(task.hasDomain, isFalse);
    expect(task.hasMilestone, isFalse);
    expect(task.targetEnvironmentIds, isEmpty);

    final entities = EntityService(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    final environment = EnvironmentService(workspace).register(
      identity: EnvironmentIdentity.detect(workspace),
      alias: 'MacBook',
    );

    await cli.main([
      'task-create',
      temporary.path,
      'Scoped',
      '--domain',
      domain.id,
      '--milestone',
      milestone.id,
      '--environment',
      environment.id,
    ]);
    task = TaskRepository(
      workspace,
    ).list().singleWhere((item) => item.title == 'Scoped');
    expect(task.domainId, domain.id);
    expect(task.milestoneId, milestone.id);
    expect(task.targetEnvironmentIds, [environment.id]);
  });

  test('modern task-create rejects milestone without Domain', () async {
    expect(
      () => cli.main([
        'task-create',
        temporary.path,
        'Invalid',
        '--milestone',
        'MLS-invalid',
      ]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('requires a Domain'),
        ),
      ),
    );
    expect(TaskRepository(workspace).list(), isEmpty);
  });

  test('legacy positional task-create remains compatible', () async {
    final entities = EntityService(workspace);
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    final environment = EnvironmentService(workspace).register(
      identity: EnvironmentIdentity.detect(workspace),
      alias: 'Legacy',
    );

    await cli.main([
      'task-create',
      temporary.path,
      domain.id,
      milestone.id,
      'Legacy Task',
      environment.id,
    ]);

    final task = TaskRepository(workspace).list().single;
    expect(task.title, 'Legacy Task');
    expect(task.domainId, domain.id);
    expect(task.milestoneId, milestone.id);
    expect(task.effectiveTargetEnvironmentIds, [environment.id]);
  });
}
