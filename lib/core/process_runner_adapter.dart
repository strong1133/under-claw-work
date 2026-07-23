import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'canonical_repository.dart';
import 'skill_pipeline.dart';
import 'workspace.dart';

class ProcessRunnerAdapter implements RunnerAdapter {
  ProcessRunnerAdapter({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.timeout = const Duration(minutes: 30),
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Duration timeout;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    final process = await Process.start(
      executable,
      arguments
          .map(
            (value) => value
                .replaceAll('{skill_id}', invocation.skillId)
                .replaceAll('{run_id}', invocation.runId)
                .replaceAll('{round}', invocation.round.toString()),
          )
          .toList(),
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    int exit;
    try {
      exit = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      throw TimeoutException('Runner exceeded ${timeout.inSeconds}s.');
    }
    final stderr = await errors;
    if (exit != 0) {
      throw ProcessException(executable, arguments, stderr.trim(), exit);
    }
    final decoded = jsonDecode(await output);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Runner output must be a JSON object.');
    }
    final trace = decoded['trace'];
    if (trace is! List) {
      throw const FormatException('Runner trace is required.');
    }
    return OrchestrationResult(
      trace: trace.map((raw) {
        if (raw is! Map) throw const FormatException('Invalid trace entry.');
        return SkillInvocation(
          raw['skill_id'] as String,
          invocation.runId,
          raw['round'] as int? ?? 0,
          parentSkillId: raw['parent_skill_id'] as String?,
        );
      }).toList(),
      reviewerScore: (decoded['reviewer_score'] as num).toDouble(),
      independentReviewer: decoded['independent_reviewer'] == true,
      knowledgeIds: _strings(decoded['knowledge_ids']),
      eventIds: _strings(decoded['event_ids']),
      followUpTaskIds: _strings(decoded['follow_up_task_ids']),
    );
  }

  static List<String> _strings(Object? value) =>
      value is List ? value.cast<String>() : const [];
}

class HermesRunnerAdapter implements RunnerAdapter {
  HermesRunnerAdapter({
    required String worklogRequest,
    required this.workspace,
    this.executable = 'hermes',
    this.timeout = const Duration(minutes: 30),
  }) : request = worklogRequest;

  final String request;
  final Workspace workspace;
  final String executable;
  final Duration timeout;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    final process = await Process.start(
      executable,
      [
        'chat',
        '-s',
        SkillPipeline.orchestrator,
        '-q',
        '$request run_id=${invocation.runId}',
      ],
      workingDirectory: workspace.root.path,
      runInShell: false,
    );
    final diagnostics = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    int exit;
    try {
      exit = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      throw TimeoutException('Hermes runner exceeded ${timeout.inSeconds}s.');
    }
    await diagnostics;
    final stderr = await errors;
    if (exit != 0) {
      throw ProcessException(executable, const ['chat'], stderr.trim(), exit);
    }

    final repository = CanonicalRepository(workspace);
    final records =
        repository
            .list(EntityKind.invocation)
            .where((item) => item.data['run_id'] == invocation.runId)
            .toList()
          ..sort(
            (left, right) => (left.data['sequence'] as int).compareTo(
              right.data['sequence'] as int,
            ),
          );
    final verdicts = repository
        .list(EntityKind.event)
        .where(
          (item) =>
              item.data['run_id'] == invocation.runId &&
              item.data['event_type'] == 'reviewer_verdict',
        )
        .toList();
    if (records.isEmpty || verdicts.isEmpty) {
      throw StateError(
        'Hermes exited without canonical invocation/reviewer evidence.',
      );
    }
    final verdict = verdicts.last.data;
    return OrchestrationResult(
      trace: records
          .where((item) => item.data['skill_id'] != SkillPipeline.orchestrator)
          .map(
            (item) => SkillInvocation(
              item.data['skill_id'] as String,
              invocation.runId,
              item.data['round'] as int? ?? 0,
            ),
          )
          .toList(),
      reviewerScore: (verdict['score'] as num).toDouble(),
      independentReviewer: verdict['independent_reviewer'] == true,
    );
  }
}
