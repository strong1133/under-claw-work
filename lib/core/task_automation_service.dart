import 'canonical_repository.dart';
import 'control_service.dart';
import 'id.dart';
import 'models.dart';
import 'projection.dart';
import 'task_repository.dart';
import 'workspace.dart';
import 'workspace_mutation_lock.dart';

class TaskAutomationResult {
  const TaskAutomationResult({
    required this.taskId,
    required this.runId,
    required this.targetEnvironmentId,
  });

  final String taskId;
  final String runId;
  final String targetEnvironmentId;
}

/// Schedules one explicitly automatic, approved, ready Task.
///
/// This service never approves a Meta Prompt. Automation begins only after the
/// same approval gate used by manual Tasks and emits the same durable start
/// request consumed by TaskExecutionWorker.
class TaskAutomationService {
  TaskAutomationService(this.workspace, this.projection);

  final Workspace workspace;
  final ProjectionStore projection;

  TaskAutomationResult? runNext() =>
      WorkspaceMutationLock.runExclusiveSync(workspace, _runNext);

  TaskAutomationResult? _runNext() {
    final canonical = CanonicalRepository(workspace);
    final alreadyRequested = canonical
        .list(EntityKind.controlRequest)
        .where((item) => item.data['command'] == ControlCommand.start.name)
        .map((item) => item.data['task_id'])
        .whereType<String>()
        .toSet();
    final tasks =
        TaskRepository(workspace)
            .list()
            .where(
              (task) =>
                  task.processingMode == TaskProcessingMode.automatic &&
                  task.isExecutionEligible &&
                  task.effectiveTargetEnvironmentIds.isNotEmpty &&
                  !alreadyRequested.contains(task.id),
            )
            .toList()
          ..sort((left, right) => left.id.compareTo(right.id));
    if (tasks.isEmpty) return null;

    final task = tasks.first;
    final environmentId = task.effectiveTargetEnvironmentIds.first;
    final runId = ControlService(workspace, projection).request(
      task,
      ControlCommand.start,
      operationId: newId('OPR'),
      actorId: 'system:task-automation',
      targetEnvironmentId: environmentId,
    );
    return TaskAutomationResult(
      taskId: task.id,
      runId: runId,
      targetEnvironmentId: environmentId,
    );
  }
}
