import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

import '../bin/worklog.dart' as cli;

void main() {
  late Directory temporary;
  late Workspace workspace;
  late TaskRepository tasks;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('manual-meta-prompt-');
    workspace = Workspace(temporary)..ensureLayout();
    tasks = TaskRepository(workspace);
    tasks.create(_task());
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('records pending Meta and immutable host-reported audit', () {
    const meta = 'Exact generated Meta';
    final result = ManualMetaPromptService(workspace).recordCompleted(
      taskId: 'TSK-manual',
      metaPrompt: meta,
      evidence: _evidence(meta),
    );

    expect(result.task.status, TaskStatus.metaReview);
    expect(result.task.approval, PromptApproval.pending);
    final canonical = CanonicalRepository(workspace);
    final run = canonical.list(EntityKind.run).single;
    final invocation = canonical.list(EntityKind.invocation).single;
    final event = canonical.list(EntityKind.event).single;
    expect(run.data['purpose'], 'manual_meta_prompt_generation');
    expect(invocation.data['evidence_kind'], 'host_reported');
    expect(invocation.data['skill_id'], 'under-claw-meta-prompt');
    expect(invocation.data['result_sha256'], TaskRepository.draftSha256(meta));
    expect(event.data['run_id'], result.runId);
    WorklogContractValidator().validateEntity(invocation);
    final approved = tasks.approveMeta(result.task);
    expect(approved.status, TaskStatus.ready);
  });

  test('approval rejects Meta without matching canonical evidence', () {
    final unaudited = tasks.saveMeta(tasks.get('TSK-manual')!, 'Unaudited');
    expect(() => tasks.approveMeta(unaudited), throwsStateError);
  });

  test('task-meta-record CLI persists host evidence end to end', () async {
    const meta = 'CLI generated Meta';
    final metaFile = File('${temporary.path}/meta.md')..writeAsStringSync(meta);
    final evidenceFile = File('${temporary.path}/evidence.json')
      ..writeAsStringSync(jsonEncode(_evidence(meta)));

    await cli.main([
      'task-meta-record',
      temporary.path,
      'TSK-manual',
      metaFile.path,
      evidenceFile.path,
    ]);

    final recorded = tasks.get('TSK-manual')!;
    expect(recorded.promptMeta, meta);
    expect(
      CanonicalRepository(workspace).list(EntityKind.invocation),
      hasLength(1),
    );
  });

  test('rejects stale, mismatched, and duplicate host evidence', () {
    const meta = 'Exact generated Meta';
    final service = ManualMetaPromptService(workspace);
    expect(
      () => service.recordCompleted(
        taskId: 'TSK-manual',
        metaPrompt: meta,
        evidence: {..._evidence(meta), 'source_revision': 2},
      ),
      throwsFormatException,
    );
    expect(
      () => service.recordCompleted(
        taskId: 'TSK-manual',
        metaPrompt: meta,
        evidence: {..._evidence(meta), 'result_sha256': '0' * 64},
      ),
      throwsFormatException,
    );

    service.recordCompleted(
      taskId: 'TSK-manual',
      metaPrompt: meta,
      evidence: _evidence(meta),
    );
    expect(
      () => service.recordCompleted(
        taskId: 'TSK-manual',
        metaPrompt: meta,
        evidence: _evidence(meta),
      ),
      throwsStateError,
    );
    expect(CanonicalRepository(workspace).list(EntityKind.run), hasLength(1));
  });

  test('rejects invalid timestamps and non-portable result references', () {
    const meta = 'Exact generated Meta';
    final service = ManualMetaPromptService(workspace);
    expect(
      () => service.recordCompleted(
        taskId: 'TSK-manual',
        metaPrompt: meta,
        evidence: {
          ..._evidence(meta),
          'started_at': '2026-07-26T02:00:00Z',
          'finished_at': '2026-07-26T01:00:00Z',
        },
      ),
      throwsFormatException,
    );
    expect(
      () => service.recordCompleted(
        taskId: 'TSK-manual',
        metaPrompt: meta,
        evidence: {..._evidence(meta), 'result_ref': '/tmp/meta.md'},
      ),
      throwsFormatException,
    );
    expect(tasks.get('TSK-manual')!.promptMeta, isEmpty);
  });
}

WorkTask _task() => const WorkTask(
  id: 'TSK-manual',
  title: 'Manual Meta',
  status: TaskStatus.metaRequested,
  promptDraft: 'Draft request',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  autoDeriveTasks: false,
);

Map<String, Object?> _evidence(String meta) => {
  'protocol': 'under-claw-meta-evidence/v1',
  'skill_id': 'under-claw-meta-prompt',
  'bundle_version': '1.2.3',
  'bundle_checksum': 'a' * 64,
  'host_invocation_id': 'host-session-123',
  'host_id': 'codex',
  'runner_id': 'local-codex',
  'environment_id': 'ENV-macbook',
  'source_revision': 1,
  'source_sha256': TaskRepository.draftSha256('Draft request'),
  'started_at': '2026-07-26T01:00:00Z',
  'finished_at': '2026-07-26T01:01:00Z',
  'status': 'completed',
  'result_sha256': TaskRepository.draftSha256(meta),
  'result_ref': 'task:TSK-manual#meta@1',
};
