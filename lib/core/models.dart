import 'dart:convert';

import 'package:crypto/crypto.dart';

enum TaskStatus {
  draft,
  writing,
  metaRequested,
  metaReview,
  ready,
  claimed,
  running,
  paused,
  blocked,
  completed,
  cancelled,
}

enum PromptApproval { missing, stale, pending, approved }

enum ControlCommand { start, pause, resume, cancel, complete }

enum ExecutionScope { singleMachine, multiEnvironment }

/// Whether a ready Task waits for an explicit request or may be scheduled by
/// the local automation watcher. Meta approval remains an explicit governance
/// gate in both modes.
enum TaskProcessingMode { manual, automatic }

enum GeneratedTaskRelation { child, related }

class WorkTask {
  const WorkTask({
    required this.id,
    this.domainId = '',
    this.milestoneId = '',
    required this.title,
    required this.status,
    required this.promptDraft,
    required this.promptMeta,
    required this.promptDraftRevision,
    required this.promptMetaSourceRevision,
    this.promptMetaSourceSha256 = '',
    required this.approval,
    required this.autoDeriveTasks,
    this.autoFollowupTasks = false,
    this.autoAcceptGeneratedTasks = false,
    this.maxGenerationDepth = 2,
    String? targetEnvironment,
    this.targetEnvironmentIds = const [],
    this.projectIds = const [],
    this.modelSelectionKeys = const [],
    this.processingMode = TaskProcessingMode.manual,
    this.executionScope = ExecutionScope.multiEnvironment,
    this.parentTaskId,
    this.relatedTaskIds = const [],
    this.alignedObjectiveIds = const [],
    this.evidenceKnowledgeIds = const [],
    this.sourceReferenceIds = const [],
    this.generationDepth = 0,
    this.generationFingerprint,
    this.createdAutomatically = false,
    this.legacyIds = const [],
  }) : _legacyTargetEnvironment = targetEnvironment;

  final String id;
  final String domainId;
  final String milestoneId;
  final String title;
  final TaskStatus status;
  final String promptDraft;
  final String promptMeta;
  final int promptDraftRevision;
  final int promptMetaSourceRevision;
  final String promptMetaSourceSha256;
  final PromptApproval approval;
  final bool autoDeriveTasks;
  final bool autoFollowupTasks;
  final bool autoAcceptGeneratedTasks;
  final int maxGenerationDepth;
  final String? _legacyTargetEnvironment;
  final List<String> targetEnvironmentIds;
  final List<String> projectIds;
  final List<String> modelSelectionKeys;
  final TaskProcessingMode processingMode;
  final ExecutionScope executionScope;
  final String? parentTaskId;
  final List<String> relatedTaskIds;
  final List<String> alignedObjectiveIds;
  final List<String> evidenceKnowledgeIds;
  final List<String> sourceReferenceIds;
  final int generationDepth;
  final String? generationFingerprint;
  final bool createdAutomatically;
  final List<String> legacyIds;

  bool get hasDomain => domainId.isNotEmpty;
  bool get hasMilestone => milestoneId.isNotEmpty;

  /// Compatibility view for v1/v2 call sites that selected exactly one host.
  String get targetEnvironment =>
      effectiveTargetEnvironmentIds.firstOrNull ?? '';

  bool get usesLegacyTargetEnvironment => _legacyTargetEnvironment != null;

  /// The Environment a v1/v2 Task selected before canonical Environments were
  /// required. It is persisted so that rewriting the Task at schema version 3
  /// does not silently withdraw the legacy start allowance; explicitly
  /// reconfiguring `targetEnvironmentIds` clears it.
  String? get legacyTargetEnvironment => _legacyTargetEnvironment;

  List<String> get effectiveTargetEnvironmentIds {
    final ids = <String>{...targetEnvironmentIds};
    final legacy = _legacyTargetEnvironment;
    if (legacy != null && legacy.isNotEmpty) ids.add(legacy);
    return ids.toList(growable: false);
  }

  bool get isMetaCurrent =>
      promptMeta.isNotEmpty &&
      promptMetaSourceRevision == promptDraftRevision &&
      promptMetaSourceSha256.isNotEmpty &&
      promptMetaSourceSha256 ==
          sha256.convert(utf8.encode(promptDraft)).toString() &&
      approval == PromptApproval.approved;

  bool get isExecutionEligible => status == TaskStatus.ready && isMetaCurrent;

  WorkTask copyWith({
    String? title,
    TaskStatus? status,
    String? promptDraft,
    String? promptMeta,
    int? promptDraftRevision,
    int? promptMetaSourceRevision,
    String? promptMetaSourceSha256,
    PromptApproval? approval,
    bool? autoDeriveTasks,
    bool? autoFollowupTasks,
    bool? autoAcceptGeneratedTasks,
    int? maxGenerationDepth,
    String? targetEnvironment,
    List<String>? targetEnvironmentIds,
    List<String>? projectIds,
    List<String>? modelSelectionKeys,
    TaskProcessingMode? processingMode,
    ExecutionScope? executionScope,
    String? parentTaskId,
    List<String>? relatedTaskIds,
    List<String>? alignedObjectiveIds,
    List<String>? evidenceKnowledgeIds,
    List<String>? sourceReferenceIds,
    int? generationDepth,
    String? generationFingerprint,
    bool? createdAutomatically,
    List<String>? legacyIds,
  }) {
    return WorkTask(
      id: id,
      domainId: domainId,
      milestoneId: milestoneId,
      title: title ?? this.title,
      status: status ?? this.status,
      promptDraft: promptDraft ?? this.promptDraft,
      promptMeta: promptMeta ?? this.promptMeta,
      promptDraftRevision: promptDraftRevision ?? this.promptDraftRevision,
      promptMetaSourceRevision:
          promptMetaSourceRevision ?? this.promptMetaSourceRevision,
      promptMetaSourceSha256:
          promptMetaSourceSha256 ?? this.promptMetaSourceSha256,
      approval: approval ?? this.approval,
      autoDeriveTasks: autoDeriveTasks ?? this.autoDeriveTasks,
      autoFollowupTasks: autoFollowupTasks ?? this.autoFollowupTasks,
      autoAcceptGeneratedTasks:
          autoAcceptGeneratedTasks ?? this.autoAcceptGeneratedTasks,
      maxGenerationDepth: maxGenerationDepth ?? this.maxGenerationDepth,
      targetEnvironment:
          targetEnvironment ??
          (targetEnvironmentIds == null ? _legacyTargetEnvironment : null),
      targetEnvironmentIds: targetEnvironmentIds ?? this.targetEnvironmentIds,
      projectIds: projectIds ?? this.projectIds,
      modelSelectionKeys: modelSelectionKeys ?? this.modelSelectionKeys,
      processingMode: processingMode ?? this.processingMode,
      executionScope: executionScope ?? this.executionScope,
      parentTaskId: parentTaskId ?? this.parentTaskId,
      relatedTaskIds: relatedTaskIds ?? this.relatedTaskIds,
      alignedObjectiveIds: alignedObjectiveIds ?? this.alignedObjectiveIds,
      evidenceKnowledgeIds: evidenceKnowledgeIds ?? this.evidenceKnowledgeIds,
      sourceReferenceIds: sourceReferenceIds ?? this.sourceReferenceIds,
      generationDepth: generationDepth ?? this.generationDepth,
      generationFingerprint:
          generationFingerprint ?? this.generationFingerprint,
      createdAutomatically: createdAutomatically ?? this.createdAutomatically,
      legacyIds: legacyIds ?? this.legacyIds,
    );
  }
}

class ControlRequest {
  const ControlRequest({
    required this.id,
    required this.operationId,
    required this.taskId,
    required this.command,
    required this.expectedRevision,
    required this.requestedAt,
  });

  final String id;
  final String operationId;
  final String taskId;
  final ControlCommand command;
  final int expectedRevision;
  final DateTime requestedAt;
}

class SkillInvocation {
  const SkillInvocation(
    this.skillId,
    this.runId,
    this.round, {
    this.parentSkillId,
    this.modelBindings = const {},
  });
  final String skillId;
  final String runId;
  final int round;
  final String? parentSkillId;
  final Map<String, String> modelBindings;
}

/// Evidence observed by Core around a runner process, never asserted by the
/// model inside that process.
class RunnerEvidence {
  const RunnerEvidence({
    required this.adapterId,
    required this.processId,
    required this.exitCode,
    required this.outputSha256,
    required this.startedAt,
    required this.finishedAt,
    required this.reviewerArtifactSha256,
    required this.artifactVerified,
    required this.reviewerSessionId,
  });

  final String adapterId;
  final int processId;
  final int exitCode;
  final String outputSha256;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String reviewerArtifactSha256;
  final bool artifactVerified;
  final String reviewerSessionId;

  bool get provesSuccessfulProcess =>
      adapterId.trim().isNotEmpty &&
      processId >= 0 &&
      exitCode == 0 &&
      outputSha256.length == 64 &&
      reviewerArtifactSha256.length == 64 &&
      artifactVerified &&
      reviewerSessionId.trim().isNotEmpty &&
      !finishedAt.isBefore(startedAt);

  static RunnerEvidence fixture(String name) {
    final digest = name.padRight(64, '0').substring(0, 64);
    final instant = DateTime.utc(2000);
    return RunnerEvidence(
      adapterId: 'fixture:$name',
      processId: 0,
      exitCode: 0,
      outputSha256: digest,
      startedAt: instant,
      finishedAt: instant,
      reviewerArtifactSha256: digest,
      artifactVerified: true,
      reviewerSessionId: 'fixture-session:$name',
    );
  }
}
