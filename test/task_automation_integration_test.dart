import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  test(
    'orchestration auto-accepts child and related Tasks and forwards models',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'under-claw-task-automation-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final workspace = Workspace(temporary)..ensureLayout();
      final scopes = ScopeConfigurationService(workspace);
      final domain = EntityService(
        workspace,
      ).create(kind: EntityKind.domain, title: 'Automation Domain');
      final project = scopes.createProject(
        domainId: domain.id,
        title: 'Portable project',
      );
      final repository = TaskRepository(workspace);
      final parent = repository.create(
        WorkTask(
          id: 'TSK-automation-parent',
          title: 'Automatic parent',
          status: TaskStatus.ready,
          promptDraft: 'Draft',
          promptMeta: 'Approved Meta',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 1,
          promptMetaSourceSha256: TaskRepository.draftSha256('Draft'),
          approval: PromptApproval.approved,
          processingMode: TaskProcessingMode.automatic,
          autoDeriveTasks: true,
          autoFollowupTasks: true,
          autoAcceptGeneratedTasks: true,
          maxGenerationDepth: 2,
          projectIds: [project.id],
          targetEnvironmentIds: const ['ENV-astro'],
          modelSelectionKeys: const ['primary', 'reviewer'],
        ),
      );
      final projection = ProjectionStore(workspace)..rebuild();
      // Registered after the directory tear-down so it runs first: Windows
      // refuses to delete the workspace while the SQLite handle is still open.
      addTearDown(projection.dispose);
      final runner = _GeneratedTaskRunner();

      await SkillPipeline(
        projection,
        runner,
        environmentId: 'ENV-astro',
        modelBindings: const {
          'primary': 'provider/primary',
          'reviewer': 'provider/reviewer',
        },
        manageClaim: false,
      ).execute(parent, 'RUN-task-automation');

      expect(runner.receivedModels, {
        'primary': 'provider/primary',
        'reviewer': 'provider/reviewer',
      });
      final generated = repository
          .list()
          .where((task) => task.id != parent.id)
          .toList();
      expect(generated, hasLength(2));
      final child = generated.singleWhere(
        (task) => task.parentTaskId == parent.id,
      );
      final related = generated.singleWhere(
        (task) => task.relatedTaskIds.contains(parent.id),
      );
      for (final task in [child, related]) {
        expect(task.status, TaskStatus.metaRequested);
        expect(task.processingMode, TaskProcessingMode.automatic);
        expect(task.projectIds, parent.projectIds);
        expect(
          task.effectiveTargetEnvironmentIds,
          parent.effectiveTargetEnvironmentIds,
        );
        expect(task.modelSelectionKeys, parent.modelSelectionKeys);
      }
      expect(
        TaskCandidateService(workspace)
            .list()
            .where((candidate) => candidate.parentTaskId == parent.id)
            .map((candidate) => candidate.disposition)
            .toSet(),
        {CandidateDisposition.accepted},
      );
    },
  );
}

class _GeneratedTaskRunner implements RunnerAdapter {
  Map<String, String>? receivedModels;

  @override
  Future<OrchestrationResult> invokeOrchestration(
    SkillInvocation invocation,
  ) async {
    receivedModels = invocation.modelBindings;
    final now = DateTime.now().toUtc();
    return OrchestrationResult(
      trace: [
        SkillInvocation(
          SkillPipeline.metaPrompt,
          invocation.runId,
          0,
          parentSkillId: SkillPipeline.orchestrator,
        ),
        SkillInvocation(
          SkillPipeline.planLoop,
          invocation.runId,
          0,
          parentSkillId: SkillPipeline.orchestrator,
        ),
        SkillInvocation(
          SkillPipeline.basePlan,
          invocation.runId,
          1,
          parentSkillId: SkillPipeline.planLoop,
        ),
      ],
      reviewerScore: 9.8,
      independentReviewer: true,
      evidence: RunnerEvidence(
        adapterId: 'test-runner',
        processId: 123,
        exitCode: 0,
        outputSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        startedAt: now,
        finishedAt: now,
        reviewerArtifactSha256:
            '1111111111111111111111111111111111111111111111111111111111111111',
        artifactVerified: true,
        reviewerSessionId: 'review-session',
      ),
      candidateProposals: const [
        CandidateProposal(
          title: 'Generated child',
          draft: 'Child Draft',
          objectiveIds: [],
          knowledgeIds: [],
          referenceIds: [],
          reason: 'Break down the parent.',
        ),
        CandidateProposal(
          title: 'Generated related Task',
          draft: 'Related Draft',
          objectiveIds: [],
          knowledgeIds: [],
          referenceIds: [],
          reason: 'Track related work.',
          relation: GeneratedTaskRelation.related,
        ),
      ],
    );
  }
}
