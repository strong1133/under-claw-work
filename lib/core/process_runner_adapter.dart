import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'skill_pipeline.dart';
import 'workspace.dart';

abstract interface class ReviewerArtifactVerifier {
  Future<bool> verify({
    required String producerSessionId,
    required String reviewerSessionId,
    required List<int> artifactBytes,
  });
}

/// Production boundary for reviewer attestations. The runner never verifies
/// its own artifact: a separately configured executable receives only the
/// immutable artifact digest and identities, then returns a signed/validated
/// canonical verdict. Core accepts an exact digest match only.
class ExternalReviewerArtifactVerifier implements ReviewerArtifactVerifier {
  ExternalReviewerArtifactVerifier({
    required this.executable,
    this.arguments = const [],
    this.timeout = const Duration(seconds: 30),
  });

  final String executable;
  final List<String> arguments;
  final Duration timeout;

  @override
  Future<bool> verify({
    required String producerSessionId,
    required String reviewerSessionId,
    required List<int> artifactBytes,
  }) async {
    final digest = sha256.convert(artifactBytes).toString();
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    process.stdin.write(
      jsonEncode({
        'protocol': 'under-claw-review-attestation/v1',
        'producer_session_id': producerSessionId,
        'reviewer_session_id': reviewerSessionId,
        'artifact_sha256': digest,
      }),
    );
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    int exit;
    try {
      exit = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return false;
    }
    if (exit != 0) {
      await stderr;
      return false;
    }
    final decoded = jsonDecode(await stdout);
    return decoded is Map<String, Object?> &&
        decoded['verified'] == true &&
        decoded['artifact_sha256'] == digest &&
        decoded['reviewer_session_id'] == reviewerSessionId;
  }
}

class ProcessRunnerAdapter implements CancellableRunnerAdapter {
  ProcessRunnerAdapter({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.timeout = const Duration(minutes: 30),
    this.reviewerVerifier,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Duration timeout;
  final ReviewerArtifactVerifier? reviewerVerifier;
  Process? _activeProcess;

  @override
  Future<void> cancel() async {
    final process = _activeProcess;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
  }

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final process = await Process.start(
      executable,
      arguments.map((value) {
        var expanded = value
            .replaceAll('{skill_id}', invocation.skillId)
            .replaceAll('{run_id}', invocation.runId)
            .replaceAll('{round}', invocation.round.toString())
            .replaceAll(
              '{model_bindings_json}',
              jsonEncode(invocation.modelBindings),
            );
        for (final entry in invocation.modelBindings.entries) {
          expanded = expanded.replaceAll('{model.${entry.key}}', entry.value);
        }
        return expanded;
      }).toList(),
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _activeProcess = process;
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
    _activeProcess = null;
    if (exit != 0) {
      throw ProcessException(executable, arguments, stderr.trim(), exit);
    }
    final stdout = await output;
    final decoded = jsonDecode(stdout);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Runner output must be a JSON object.');
    }
    final trace = decoded['trace'];
    if (trace is! List) {
      throw const FormatException('Runner trace is required.');
    }
    final artifactPath = decoded['reviewer_artifact_path'];
    if (artifactPath is! String || artifactPath.trim().isEmpty) {
      throw const FormatException('reviewer_artifact_path is required.');
    }
    final producerSessionId = decoded['producer_session_id'];
    if (producerSessionId is! String || producerSessionId.trim().isEmpty) {
      throw const FormatException('producer_session_id is required.');
    }
    final base = Directory(
      p.absolute(workingDirectory ?? Directory.current.path),
    ).resolveSymbolicLinksSync();
    final unresolved = p.normalize(
      p.isAbsolute(artifactPath) ? artifactPath : p.join(base, artifactPath),
    );
    _rejectSymbolicLinkComponents(base, unresolved);
    final resolved = File(unresolved).resolveSymbolicLinksSync();
    if (resolved != base && !p.isWithin(base, resolved)) {
      throw const FormatException(
        'Reviewer artifact must be inside the workspace.',
      );
    }
    final artifactFile = File(resolved);
    if (!artifactFile.existsSync()) {
      throw const FormatException('Reviewer artifact does not exist.');
    }
    final before = artifactFile.statSync();
    final artifactBytes = artifactFile.readAsBytesSync();
    final after = artifactFile.statSync();
    if (before.type != FileSystemEntityType.file ||
        after.type != FileSystemEntityType.file ||
        before.size != after.size ||
        before.modified != after.modified) {
      throw const FormatException('Reviewer artifact changed while reading.');
    }
    final artifact = jsonDecode(utf8.decode(artifactBytes));
    if (artifact is! Map<String, Object?> ||
        artifact['run_id'] != invocation.runId ||
        artifact['independent_reviewer'] != true ||
        artifact['session_id'] is! String ||
        (artifact['session_id'] as String).trim().isEmpty ||
        artifact['session_id'] == producerSessionId ||
        artifact['producer_session_id'] != producerSessionId ||
        artifact['reviewer_score'] is! num) {
      throw const FormatException(
        'Reviewer artifact identity or verdict is invalid.',
      );
    }
    final verifier = reviewerVerifier;
    if (verifier == null ||
        !await verifier.verify(
          producerSessionId: producerSessionId,
          reviewerSessionId: artifact['session_id'] as String,
          artifactBytes: artifactBytes,
        )) {
      throw const FormatException(
        'Reviewer artifact has no trusted verifier attestation.',
      );
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
      reviewerScore: (artifact['reviewer_score'] as num).toDouble(),
      independentReviewer: artifact['independent_reviewer'] == true,
      evidence: RunnerEvidence(
        adapterId: 'process:$executable',
        processId: process.pid,
        exitCode: exit,
        outputSha256: sha256.convert(utf8.encode(stdout)).toString(),
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        reviewerArtifactSha256: sha256.convert(artifactBytes).toString(),
        artifactVerified: true,
        reviewerSessionId: artifact['session_id'] as String,
      ),
      knowledgeIds: _strings(decoded['knowledge_ids']),
      eventIds: _strings(decoded['event_ids']),
      followUpTaskIds: _strings(decoded['follow_up_task_ids']),
      candidateProposals: _candidateProposals(decoded['candidate_proposals']),
    );
  }

  static void _rejectSymbolicLinkComponents(String base, String target) {
    final absoluteBase = p.absolute(base);
    final absoluteTarget = p.absolute(target);
    if (absoluteTarget != absoluteBase &&
        !p.isWithin(absoluteBase, absoluteTarget)) {
      throw const FormatException(
        'Reviewer artifact must be inside the workspace.',
      );
    }
    var current = absoluteBase;
    final relative = p.relative(absoluteTarget, from: absoluteBase);
    for (final component in p.split(relative)) {
      current = p.join(current, component);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException(
          'Reviewer artifact path must not contain symbolic links.',
        );
      }
    }
  }

  static List<String> _strings(Object? value) =>
      value is List ? value.cast<String>() : const [];

  static List<CandidateProposal> _candidateProposals(Object? value) {
    if (value is! List) return const [];
    return value.map((raw) {
      if (raw is! Map) {
        throw const FormatException('Invalid candidate proposal.');
      }
      return CandidateProposal(
        title: raw['title'] as String,
        draft: raw['draft'] as String,
        objectiveIds: _strings(raw['objective_ids']),
        knowledgeIds: _strings(raw['knowledge_ids']),
        referenceIds: _strings(raw['reference_ids']),
        reason: raw['reason'] as String,
        relation: GeneratedTaskRelation.values.byName(
          raw['relation'] as String? ?? 'child',
        ),
      );
    }).toList();
  }
}

class HermesRunnerAdapter implements CancellableRunnerAdapter {
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
  Process? _activeProcess;

  @override
  Future<void> cancel() async {
    _activeProcess?.kill(ProcessSignal.sigterm);
  }

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    throw UnsupportedError(
      'Hermes execution is experimental and disabled until a trusted '
      'external reviewer-attestation verifier passes acceptance.',
    );
    /*
    final startedAt = DateTime.now().toUtc();
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
    _activeProcess = process;
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
    final stdout = await diagnostics;
    final stderr = await errors;
    _activeProcess = null;
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
      evidence: RunnerEvidence(
        adapterId: 'hermes:$executable',
        processId: process.pid,
        exitCode: exit,
        outputSha256: sha256.convert(utf8.encode(stdout)).toString(),
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        reviewerArtifactSha256: sha256
            .convert(utf8.encode(jsonEncode(verdict)))
            .toString(),
        artifactVerified: true,
        reviewerSessionId:
            verdict['reviewer_session_id'] as String? ?? verdicts.last.id,
      ),
    );
    */
  }
}
