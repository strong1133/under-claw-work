import 'models.dart';
import 'canonical_repository.dart';
import 'id.dart';
import 'claim_service.dart';
import 'projection.dart';

class OrchestrationResult {
  const OrchestrationResult({
    required this.trace,
    required this.reviewerScore,
    required this.independentReviewer,
    this.knowledgeIds = const [],
    this.eventIds = const [],
    this.followUpTaskIds = const [],
  });

  final List<SkillInvocation> trace;
  final double reviewerScore;
  final bool independentReviewer;
  final List<String> knowledgeIds;
  final List<String> eventIds;
  final List<String> followUpTaskIds;
}

abstract interface class RunnerAdapter {
  Future<OrchestrationResult> invokeOrchestration(SkillInvocation invocation);
}

class SkillPipeline {
  SkillPipeline(
    this.projection,
    this.runner, {
    this.environmentId = 'ENV-local',
  });

  static const orchestrator = 'under-claw-work-plan';
  static const metaPrompt = 'under-claw-meta-prompt';
  static const planLoop = 'under-claw-jarvis-plan-loop';
  static const basePlan = 'under-claw-jarvis-plan';
  static const targetScore = 9.5;

  final ProjectionStore projection;
  final RunnerAdapter runner;
  final String environmentId;

  Future<OrchestrationResult> execute(WorkTask task, String runId) async {
    if (!task.isMetaCurrent) {
      throw StateError('Approved current Meta Prompt required.');
    }
    final root = SkillInvocation(orchestrator, runId, 0);
    final claims = ClaimService(projection.workspace, projection);
    final claim = claims.acquire(
      taskId: task.id,
      runId: runId,
      environmentId: environmentId,
    );
    late final OrchestrationResult result;
    try {
      result = await runner.invokeOrchestration(root);
      _validate(result);
    } finally {
      claims.release(claim.id);
    }
    final repository = CanonicalRepository(projection.workspace);
    final now = DateTime.now().toUtc().toIso8601String();
    if (repository.get(EntityKind.run, runId) == null) {
      repository.create(
        CanonicalEntity(
          kind: EntityKind.run,
          id: runId,
          data: {
            'schema_version': 1,
            'id': runId,
            'type': 'run',
            'operation_id': 'OP-$runId',
            'task_id': task.id,
            'status': 'running',
            'created_at': now,
          },
        ),
      );
    }
    var sequence = 0;
    for (final invocation in [root, ...result.trace]) {
      final currentSequence = ++sequence;
      final exists = repository
          .list(EntityKind.invocation)
          .any(
            (item) =>
                item.data['run_id'] == runId &&
                item.data['sequence'] == currentSequence &&
                item.data['skill_id'] == invocation.skillId,
          );
      if (exists) continue;
      final invocationId = newId('SKI');
      repository.create(
        CanonicalEntity(
          kind: EntityKind.invocation,
          id: invocationId,
          data: {
            'schema_version': 1,
            'id': invocationId,
            'type': 'skill_invocation',
            'run_id': runId,
            'skill_id': invocation.skillId,
            'round': invocation.round,
            'sequence': currentSequence,
            'parent_skill_id': invocation.parentSkillId,
            'bundle_version': 'mvp-1',
            'started_at': now,
            'finished_at': now,
            'status': 'completed',
          },
        ),
      );
    }
    final eventId = newId('EVT');
    repository.create(
      CanonicalEntity(
        kind: EntityKind.event,
        id: eventId,
        data: {
          'schema_version': 1,
          'id': eventId,
          'type': 'event',
          'event_type': 'orchestration_completed',
          'run_id': runId,
          'reviewer_score': result.reviewerScore,
          'independent_reviewer': result.independentReviewer,
          'result_refs': {
            'knowledge': result.knowledgeIds,
            'events': result.eventIds,
            'follow_up_tasks': result.followUpTaskIds,
          },
          'occurred_at': now,
        },
      ),
    );
    projection.rebuild();
    final database = projection.open();
    for (final entry in <(String, String)>[
      ...result.knowledgeIds.map((id) => ('knowledge', id)),
      ...result.eventIds.map((id) => ('event', id)),
      ...result.followUpTaskIds.map((id) => ('follow_up_task', id)),
    ]) {
      database.execute(
        'INSERT INTO knowledge_events (id, run_id, entity_type, entity_ref) '
        'VALUES (?, ?, ?, ?)',
        ['$runId:${entry.$1}:${entry.$2}', runId, entry.$1, entry.$2],
      );
    }
    return result;
  }

  void _validate(OrchestrationResult result) {
    final skills = result.trace.map((item) => item.skillId).toList();
    final metaIndex = skills.indexOf(metaPrompt);
    final loopIndex = skills.indexOf(planLoop);
    if (metaIndex < 0 || loopIndex <= metaIndex) {
      throw StateError('Orchestration trace violates Meta → Plan Loop order.');
    }
    final baseRounds = result.trace
        .where((item) => item.skillId == basePlan && item.round > 0)
        .map((item) => item.round)
        .toSet();
    if (baseRounds.isEmpty) {
      throw StateError(
        'Every Plan Loop requires at least one base Plan round.',
      );
    }
    final maximumRound = baseRounds.reduce((a, b) => a > b ? a : b);
    for (var round = 1; round <= maximumRound; round++) {
      if (!baseRounds.contains(round)) {
        throw StateError('Missing base Plan invocation for round $round.');
      }
    }
    if (!result.independentReviewer || result.reviewerScore < targetScore) {
      throw StateError('Independent reviewer TARGET 9.5 gate failed.');
    }
  }
}
