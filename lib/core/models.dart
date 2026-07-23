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
    required this.targetEnvironment,
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
  final String targetEnvironment;

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
    String? targetEnvironment,
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
      targetEnvironment: targetEnvironment ?? this.targetEnvironment,
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
