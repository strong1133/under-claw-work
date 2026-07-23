enum TaskStatus {
  draft,
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

class WorkTask {
  const WorkTask({
    required this.id,
    required this.domainId,
    required this.milestoneId,
    required this.title,
    required this.status,
    required this.promptDraft,
    required this.promptMeta,
    required this.promptDraftRevision,
    required this.promptMetaSourceRevision,
    required this.approval,
    required this.autoDeriveTasks,
    this.autoFollowupTasks = false,
    this.maxGenerationDepth = 2,
    required this.targetEnvironment,
    this.executionScope = ExecutionScope.multiEnvironment,
    this.parentTaskId,
    this.alignedObjectiveIds = const [],
    this.evidenceKnowledgeIds = const [],
    this.sourceReferenceIds = const [],
    this.generationDepth = 0,
    this.generationFingerprint,
    this.createdAutomatically = false,
    this.legacyIds = const [],
  });

  final String id;
  final String domainId;
  final String milestoneId;
  final String title;
  final TaskStatus status;
  final String promptDraft;
  final String promptMeta;
  final int promptDraftRevision;
  final int promptMetaSourceRevision;
  final PromptApproval approval;
  final bool autoDeriveTasks;
  final bool autoFollowupTasks;
  final int maxGenerationDepth;
  final String targetEnvironment;
  final ExecutionScope executionScope;
  final String? parentTaskId;
  final List<String> alignedObjectiveIds;
  final List<String> evidenceKnowledgeIds;
  final List<String> sourceReferenceIds;
  final int generationDepth;
  final String? generationFingerprint;
  final bool createdAutomatically;
  final List<String> legacyIds;

  bool get isMetaCurrent =>
      promptMeta.isNotEmpty &&
      promptMetaSourceRevision == promptDraftRevision &&
      approval == PromptApproval.approved;

  WorkTask copyWith({
    String? title,
    TaskStatus? status,
    String? promptDraft,
    String? promptMeta,
    int? promptDraftRevision,
    int? promptMetaSourceRevision,
    PromptApproval? approval,
    bool? autoDeriveTasks,
    bool? autoFollowupTasks,
    int? maxGenerationDepth,
    String? targetEnvironment,
    ExecutionScope? executionScope,
    String? parentTaskId,
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
      approval: approval ?? this.approval,
      autoDeriveTasks: autoDeriveTasks ?? this.autoDeriveTasks,
      autoFollowupTasks: autoFollowupTasks ?? this.autoFollowupTasks,
      maxGenerationDepth: maxGenerationDepth ?? this.maxGenerationDepth,
      targetEnvironment: targetEnvironment ?? this.targetEnvironment,
      executionScope: executionScope ?? this.executionScope,
      parentTaskId: parentTaskId ?? this.parentTaskId,
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
  });
  final String skillId;
  final String runId;
  final int round;
  final String? parentSkillId;
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
