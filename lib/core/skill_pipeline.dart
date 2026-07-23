import 'models.dart';
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
  SkillPipeline(this.projection, this.runner);

  static const orchestrator = 'under-claw-work-plan';
  static const metaPrompt = 'under-claw-meta-prompt';
  static const planLoop = 'under-claw-jarvis-plan-loop';
  static const basePlan = 'under-claw-jarvis-plan';
  static const targetScore = 9.5;

  final ProjectionStore projection;
  final RunnerAdapter runner;

  Future<OrchestrationResult> execute(WorkTask task, String runId) async {
    if (!task.isMetaCurrent) {
      throw StateError('Approved current Meta Prompt required.');
    }
    final root = SkillInvocation(orchestrator, runId, 0);
    final result = await runner.invokeOrchestration(root);
    _validate(result);
    final database = projection.open();
    var sequence = 0;
    for (final invocation in [root, ...result.trace]) {
      database.execute(
        'INSERT INTO skill_invocations '
        '(run_id, skill_id, round, sequence) VALUES (?, ?, ?, ?)',
        [invocation.runId, invocation.skillId, invocation.round, ++sequence],
      );
    }
    for (final entry in <(String, String)>[
      ...result.knowledgeIds.map((id) => ('knowledge', id)),
      ...result.eventIds.map((id) => ('event', id)),
      ...result.followUpTaskIds.map((id) => ('follow_up_task', id)),
    ]) {
      database.execute(
        'INSERT INTO knowledge_events (id, run_id, entity_type, entity_ref) '
        'VALUES (?, ?, ?, ?)',
        ['${entry.$1}:${entry.$2}', runId, entry.$1, entry.$2],
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
