import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'installed_runtime_registry.dart';
import 'manual_meta_prompt_service.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

class MetaPromptGenerationResult {
  const MetaPromptGenerationResult({
    required this.task,
    required this.adapterId,
    required this.executableSha256,
    required this.outputSha256,
  });

  final WorkTask task;
  final String adapterId;
  final String executableSha256;
  final String outputSha256;
}

class MetaPromptService {
  MetaPromptService(
    this.workspace, {
    InstalledRuntimeRegistry? runtimes,
    this.timeout = const Duration(minutes: 5),
  }) : runtimes = runtimes ?? InstalledRuntimeRegistry(workspace);

  final Workspace workspace;
  final InstalledRuntimeRegistry runtimes;
  final Duration timeout;

  Future<MetaPromptGenerationResult> generate({
    required String taskId,
    required String adapterId,
    bool recordAudit = true,
  }) async {
    final repository = TaskRepository(workspace);
    final source = repository.get(taskId);
    if (source == null) throw StateError('Task not found: $taskId.');
    if (source.promptDraft.trim().isEmpty) {
      throw StateError('A non-empty Draft is required to generate Meta.');
    }
    final descriptor = runtimes.require(adapterId, capability: 'generate_meta');
    final sourceSha256 = TaskRepository.draftSha256(source.promptDraft);
    final startedAt = DateTime.now().toUtc();
    final process = await Process.start(
      descriptor.executable,
      descriptor.fixedArguments,
      workingDirectory: workspace.root.path,
      runInShell: false,
    );
    process.stdin.writeln(
      jsonEncode({
        'protocol': InstalledRuntimeDescriptor.protocolV1,
        'type': 'generate_meta',
        'task_id': source.id,
        'source_revision': source.promptDraftRevision,
        'source_sha256': sourceSha256,
        'draft': source.promptDraft,
      }),
    );
    await process.stdin.close();
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    late final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw TimeoutException('Meta Prompt adapter timed out.');
    }
    final stdout = await stdoutFuture;
    final stderr = await stderrFuture;
    if (exitCode != 0) {
      throw ProcessException(
        descriptor.executable,
        descriptor.fixedArguments,
        stderr.trim(),
        exitCode,
      );
    }
    final decoded = jsonDecode(stdout);
    if (decoded is! Map<String, Object?> ||
        decoded['protocol'] != InstalledRuntimeDescriptor.protocolV1 ||
        decoded['type'] != 'meta_prompt_result' ||
        decoded['task_id'] != source.id ||
        decoded['source_revision'] != source.promptDraftRevision ||
        decoded['source_sha256'] != sourceSha256 ||
        decoded['meta_prompt'] is! String ||
        (decoded['meta_prompt'] as String).trim().isEmpty) {
      throw const FormatException('Invalid Meta Prompt adapter response.');
    }
    final current = repository.get(taskId);
    if (current == null ||
        current.promptDraftRevision != source.promptDraftRevision ||
        current.promptDraft != source.promptDraft) {
      throw StateError('Draft changed while Meta Prompt was generating.');
    }
    final metaPrompt = (decoded['meta_prompt'] as String).trim();
    final finishedAt = DateTime.now().toUtc();
    final updated = recordAudit
        ? ManualMetaPromptService(workspace)
              .recordCompleted(
                taskId: current.id,
                metaPrompt: metaPrompt,
                evidenceKind: 'runtime_observed',
                evidence: {
                  'protocol': 'under-claw-meta-evidence/v1',
                  'skill_id': ManualMetaPromptService.skillId,
                  'bundle_version': 'installed-runtime-v1',
                  'bundle_checksum': descriptor.executableSha256,
                  'host_invocation_id':
                      '${descriptor.id}:${process.pid}:'
                      '${startedAt.microsecondsSinceEpoch}',
                  'host_id': descriptor.id,
                  'runner_id': 'process:${process.pid}',
                  'source_revision': current.promptDraftRevision,
                  'source_sha256': sourceSha256,
                  'started_at': startedAt.toIso8601String(),
                  'finished_at': finishedAt.toIso8601String(),
                  'status': 'completed',
                  'result_sha256': TaskRepository.draftSha256(metaPrompt),
                  'result_ref':
                      'task:${current.id}#meta@'
                      '${current.promptDraftRevision}',
                },
              )
              .task
        : repository.saveMeta(current, metaPrompt);
    return MetaPromptGenerationResult(
      task: updated,
      adapterId: descriptor.id,
      executableSha256: descriptor.executableSha256,
      outputSha256: sha256.convert(utf8.encode(stdout)).toString(),
    );
  }
}
