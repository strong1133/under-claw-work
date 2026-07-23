import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;
  late ProjectionStore projection;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-graph-');
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
    projection = ProjectionStore(workspace);
  });

  tearDown(() {
    projection.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('typed graph CRUD, archive and context pack share canonical data', () {
    final domain = entities.create(
      kind: EntityKind.domain,
      title: 'Product',
      body: 'Long-lived product context',
    );
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'MVP',
      domainId: domain.id,
    );
    final objective = entities.create(
      kind: EntityKind.objective,
      title: 'Ship the workflow',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    final knowledge = entities.create(
      kind: EntityKind.knowledge,
      title: 'Confirmed constraint',
      body: 'SQLite is a disposable projection.',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    final reference = entities.create(
      kind: EntityKind.reference,
      title: 'Architecture',
      body: 'Read the canonical architecture.',
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    final linked = entities.link(
      domain,
      field: 'objective_ids',
      targetKind: EntityKind.objective,
      targetId: objective.id,
    );
    expect(linked.data['objective_ids'], [objective.id]);

    TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-context',
        domainId: domain.id,
        milestoneId: milestone.id,
        title: 'Context Task',
        status: TaskStatus.draft,
        promptDraft: '',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-local',
      ),
    );
    final context = entities.buildContext('TSK-context');
    expect(context.objectives.map((item) => item.id), contains(objective.id));
    expect(context.knowledge.map((item) => item.id), contains(knowledge.id));
    expect(context.references.map((item) => item.id), contains(reference.id));

    expect(entities.archive(milestone).data['status'], 'archived');
    entities.validateGraph();
  });

  test('missing references and cyclic Task dependencies are rejected', () {
    expect(
      () => entities.create(
        kind: EntityKind.milestone,
        title: 'Missing parent',
        domainId: 'DOM-missing',
      ),
      throwsFormatException,
    );

    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    for (final id in ['TSK-one', 'TSK-two']) {
      TaskRepository(workspace).create(
        WorkTask(
          id: id,
          domainId: domain.id,
          milestoneId: milestone.id,
          title: id,
          status: TaskStatus.draft,
          promptDraft: '',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-local',
        ),
      );
    }
    workspace
        .taskRelations('TSK-one')
        .writeAsStringSync('depends_on: [TSK-two]\n');
    workspace
        .taskRelations('TSK-two')
        .writeAsStringSync('depends_on: [TSK-one]\n');
    expect(entities.validateGraph, throwsFormatException);
  });

  test('knowledge search survives a disposable SQLite rebuild', () {
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Recovery',
      body: 'Rebuild the local projection from Git.',
    );
    projection.rebuild();
    expect(projection.searchKnowledge('projection'), hasLength(1));
    projection.dispose();
    workspace.database.deleteSync();
    projection = ProjectionStore(workspace);
    projection.rebuild();
    expect(projection.searchKnowledge('Recovery').single['title'], 'Recovery');
  });
}
