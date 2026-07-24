import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/models.dart';
import 'package:under_claw_work/core/task_repository.dart';
import 'package:under_claw_work/core/workspace.dart';
import 'package:under_claw_work/core/workspace_mutation_lock.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late WorkTask task;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('mutation-lock-');
    workspace = Workspace(temporary)..ensureLayout();
    task = WorkTask(
      id: 'TSK-lock',
      domainId: 'DOM-lock',
      milestoneId: 'MLS-lock',
      title: 'Locked Task',
      status: TaskStatus.ready,
      promptDraft: 'Draft',
      promptMeta: '',
      promptDraftRevision: 1,
      promptMetaSourceRevision: 0,
      approval: PromptApproval.missing,
      autoDeriveTasks: false,
      targetEnvironment: 'ENV-test',
    );
    TaskRepository(workspace).create(task);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('rejects same-isolate mutation outside the owning async Zone', () async {
    await WorkspaceMutationLock.runExclusive(workspace, () async {
      expect(
        () => Zone.root.run(
          () => TaskRepository(workspace).saveDraft(task, 'Concurrent'),
        ),
        throwsStateError,
      );
      expect(TaskRepository(workspace).get(task.id)!.promptDraft, 'Draft');
    });
  });

  test('revokes inherited owner Zones after the owning scope closes', () async {
    late Zone staleOwnerZone;
    await WorkspaceMutationLock.runExclusive(workspace, () async {
      staleOwnerZone = Zone.current;
    });

    await WorkspaceMutationLock.runExclusive(workspace, () async {
      expect(
        () => staleOwnerZone.run(
          () => TaskRepository(workspace).saveDraft(task, 'Stale bypass'),
        ),
        throwsStateError,
      );
      expect(TaskRepository(workspace).get(task.id)!.promptDraft, 'Draft');
    });
  });

  test('compare-and-swap rejects a replacement for another Task', () {
    final repository = TaskRepository(workspace);
    final other = WorkTask(
      id: 'TSK-other',
      domainId: task.domainId,
      milestoneId: task.milestoneId,
      title: 'Other Task',
      status: TaskStatus.ready,
      promptDraft: 'Other Draft',
      promptMeta: '',
      promptDraftRevision: 1,
      promptMetaSourceRevision: 0,
      approval: PromptApproval.missing,
      autoDeriveTasks: false,
      targetEnvironment: task.targetEnvironment,
    );
    repository.create(other);

    expect(
      () => repository.compareAndSwap(
        task,
        other.copyWith(promptDraft: 'Wrong replacement'),
      ),
      throwsArgumentError,
    );
    expect(repository.get(other.id)!.promptDraft, 'Other Draft');
  });

  test('compare-and-swap never overwrites a newer Task', () {
    final repository = TaskRepository(workspace);
    final newer = repository.saveDraft(task, 'Newer');

    final updated = repository.compareAndSwap(
      task,
      task.copyWith(promptMeta: 'Generated', approval: PromptApproval.pending),
    );

    expect(updated, isFalse);
    expect(repository.get(task.id)!.promptDraft, newer.promptDraft);
    expect(repository.get(task.id)!.promptMeta, isEmpty);
  });
}
