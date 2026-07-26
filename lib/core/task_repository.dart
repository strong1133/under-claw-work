import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'canonical_repository.dart';
import 'models.dart';
import 'task_codec.dart';
import 'workspace.dart';
import 'workspace_file_system.dart';
import 'workspace_mutation_lock.dart';
import 'schema_validator.dart';

class TaskRepository {
  TaskRepository(this.workspace) : canonical = CanonicalRepository(workspace);

  final Workspace workspace;
  final CanonicalRepository canonical;

  static String draftSha256(String draft) =>
      sha256.convert(utf8.encode(draft)).toString();

  List<WorkTask> list() {
    workspace.ensureLayout();
    final files =
        WorkspaceFileSystem.listFiles(workspace.root, workspace.tasks)
            .where(
              (file) =>
                  p.basename(file.path) == 'task.yaml' ||
                  (p.equals(file.parent.path, workspace.tasks.path) &&
                      p.basename(file.path).startsWith('TSK-') &&
                      file.path.endsWith('.yaml')),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return files.map((file) {
      final task = TaskCodec.decode(
        WorkspaceFileSystem.readText(workspace.root, file),
      );
      _validateFileIdentity(file, task);
      _validateRead(task);
      return task;
    }).toList();
  }

  WorkTask? get(String id) {
    final file = _existingFile(id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      return null;
    }
    final task = TaskCodec.decode(
      WorkspaceFileSystem.readText(workspace.root, file),
    );
    _validateFileIdentity(file, task, requestedId: id);
    _validateRead(task);
    return task;
  }

  WorkTask create(WorkTask task) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _create(task));

  WorkTask _create(WorkTask task) {
    _validate(task);
    final file = _file(task.id);
    WorkspaceFileSystem.createTextExclusive(
      workspace.root,
      file,
      TaskCodec.encode(task),
    );
    return task;
  }

  WorkTask update(WorkTask task) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _update(task));

  WorkTask _update(WorkTask task) {
    _validate(task);
    final file = _existingFile(task.id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      throw StateError('Task does not exist: ${task.id}');
    }
    WorkspaceFileSystem.atomicWriteText(
      workspace.root,
      file,
      TaskCodec.encode(task),
    );
    return task;
  }

  WorkTask saveDraft(WorkTask task, String draft) {
    _requirePromptMutationAllowed(task);
    final next = task.copyWith(
      promptDraft: draft,
      promptDraftRevision: task.promptDraftRevision + 1,
      approval: PromptApproval.stale,
      status: TaskStatus.writing,
    );
    return update(next);
  }

  WorkTask requestMeta(WorkTask task) {
    if (task.promptDraft.trim().isEmpty) {
      throw StateError('A non-empty Prompt Draft is required.');
    }
    if (!const {
      TaskStatus.draft,
      TaskStatus.writing,
      TaskStatus.blocked,
    }.contains(task.status)) {
      throw StateError(
        'Meta Prompt cannot be requested while Task is ${task.status.name}.',
      );
    }
    return update(task.copyWith(status: TaskStatus.metaRequested));
  }

  WorkTask configure(
    WorkTask task, {
    required String title,
    required String domainId,
    required String milestoneId,
    required List<String> projectIds,
    required List<String> targetEnvironmentIds,
    required List<String> modelSelectionKeys,
    required TaskProcessingMode processingMode,
    required bool autoDeriveTasks,
    required bool autoFollowupTasks,
    required bool autoAcceptGeneratedTasks,
    required int maxGenerationDepth,
    required String? parentTaskId,
    required List<String> relatedTaskIds,
  }) => update(
    WorkTask(
      id: task.id,
      domainId: domainId,
      milestoneId: milestoneId,
      title: title,
      status: task.status,
      promptDraft: task.promptDraft,
      promptMeta: task.promptMeta,
      promptDraftRevision: task.promptDraftRevision,
      promptMetaSourceRevision: task.promptMetaSourceRevision,
      promptMetaSourceSha256: task.promptMetaSourceSha256,
      approval: task.approval,
      autoDeriveTasks: autoDeriveTasks,
      autoFollowupTasks: autoFollowupTasks,
      autoAcceptGeneratedTasks: autoAcceptGeneratedTasks,
      maxGenerationDepth: maxGenerationDepth,
      targetEnvironmentIds: targetEnvironmentIds,
      projectIds: projectIds,
      modelSelectionKeys: modelSelectionKeys,
      processingMode: processingMode,
      executionScope: task.executionScope,
      parentTaskId: parentTaskId,
      relatedTaskIds: relatedTaskIds,
      alignedObjectiveIds: task.alignedObjectiveIds,
      evidenceKnowledgeIds: task.evidenceKnowledgeIds,
      sourceReferenceIds: task.sourceReferenceIds,
      generationDepth: task.generationDepth,
      generationFingerprint: task.generationFingerprint,
      createdAutomatically: task.createdAutomatically,
      legacyIds: task.legacyIds,
    ),
  );

  WorkTask saveMeta(WorkTask task, String meta) {
    _requirePromptMutationAllowed(task);
    return update(
      task.copyWith(
        promptMeta: meta,
        promptMetaSourceRevision: task.promptDraftRevision,
        promptMetaSourceSha256: draftSha256(task.promptDraft),
        approval: PromptApproval.pending,
        status: TaskStatus.metaReview,
      ),
    );
  }

  WorkTask approveMeta(WorkTask task) {
    _requirePromptMutationAllowed(task);
    if (task.promptMeta.isEmpty ||
        task.promptMetaSourceRevision != task.promptDraftRevision ||
        task.promptMetaSourceSha256 != draftSha256(task.promptDraft)) {
      throw StateError(
        'Only a Meta Prompt for the current Draft is approvable.',
      );
    }
    return update(
      task.copyWith(
        approval: PromptApproval.approved,
        status:
            const {
              TaskStatus.draft,
              TaskStatus.writing,
              TaskStatus.metaRequested,
              TaskStatus.metaReview,
            }.contains(task.status)
            ? TaskStatus.ready
            : task.status,
      ),
    );
  }

  void _requirePromptMutationAllowed(WorkTask task) {
    if (const {
      TaskStatus.claimed,
      TaskStatus.running,
      TaskStatus.paused,
      TaskStatus.completed,
      TaskStatus.cancelled,
    }.contains(task.status)) {
      throw StateError(
        'Task Prompt cannot change while Task is ${task.status.name}.',
      );
    }
  }

  File canonicalFile(String id) => _existingFile(id);

  bool compareAndSwap(WorkTask expected, WorkTask replacement) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () {
        if (replacement.id != expected.id) {
          throw ArgumentError.value(
            replacement.id,
            'replacement.id',
            'must match expected.id ${expected.id}',
          );
        }
        final current = get(expected.id);
        if (current == null ||
            TaskCodec.encode(current) != TaskCodec.encode(expected)) {
          return false;
        }
        _update(replacement);
        return true;
      });

  void delete(String id) =>
      WorkspaceMutationLock.runExclusiveSync(workspace, () => _delete(id));

  void _delete(String id) {
    final file = _existingFile(id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      throw StateError('Task does not exist: $id');
    }
    WorkspaceFileSystem.deleteFile(workspace.root, file);
  }

  File _file(String id) {
    _validateTaskId(id);
    return File(p.join(workspace.tasks.path, id, 'task.yaml'));
  }

  File _existingFile(String id) {
    final nested = _file(id);
    if (WorkspaceFileSystem.regularFileExists(workspace.root, nested)) {
      return nested;
    }
    return File(p.join(workspace.tasks.path, '$id.yaml'));
  }

  void _validate(
    WorkTask task, {
    bool allowStaleApproval = false,
    bool requireActiveScope = true,
  }) {
    WorklogContractValidator().validateTask(
      task,
      allowStaleApproval: allowStaleApproval,
    );
    _validateTaskId(task.id);
    if ((task.hasDomain && !task.domainId.startsWith('DOM-')) ||
        (task.hasMilestone && !task.milestoneId.startsWith('MLS-')) ||
        (task.hasMilestone && !task.hasDomain) ||
        task.title.trim().isEmpty ||
        task.promptDraftRevision < 1 ||
        task.promptMetaSourceRevision < 0 ||
        (task.promptMetaSourceSha256.isNotEmpty &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(task.promptMetaSourceSha256))) {
      throw const FormatException('Invalid Task contract.');
    }
    if (task.maxGenerationDepth < 0 || task.maxGenerationDepth > 10) {
      throw const FormatException('Generation depth must be between 0 and 10.');
    }
    if (task.generationDepth < 0 ||
        task.generationDepth > task.maxGenerationDepth) {
      throw const FormatException('Generation depth exceeds policy.');
    }
    if (task.createdAutomatically &&
        task.parentTaskId == null &&
        task.relatedTaskIds.isEmpty) {
      throw const FormatException(
        'Automatically generated Tasks require a parent or related Task.',
      );
    }
    _validateIdList(task, 'project_ids', task.projectIds, 'PRJ-');
    _validateIdList(
      task,
      'target_environment_ids',
      task.effectiveTargetEnvironmentIds,
      'ENV-',
    );
    _validateIdList(task, 'related_task_ids', task.relatedTaskIds, 'TSK-');
    _validateModelKeys(task);
    if (!allowStaleApproval &&
        task.approval == PromptApproval.approved &&
        !task.isMetaCurrent) {
      throw const FormatException('Approved Meta Prompt must be current.');
    }
    _validateScope(task, requireActive: requireActiveScope);
    _validateProjects(task, requireActive: requireActiveScope);
    _validateTaskRelations(task);
    _validateContextRelations(
      task,
      EntityKind.objective,
      task.alignedObjectiveIds,
    );
    _validateContextRelations(
      task,
      EntityKind.knowledge,
      task.evidenceKnowledgeIds,
    );
    _validateContextRelations(
      task,
      EntityKind.reference,
      task.sourceReferenceIds,
    );
  }

  void _validateRead(WorkTask task) {
    _validate(task, allowStaleApproval: true, requireActiveScope: false);
  }

  void _validateFileIdentity(File file, WorkTask task, {String? requestedId}) {
    final name = p.basename(file.path);
    final pathId = name == 'task.yaml'
        ? p.basename(file.parent.path)
        : p.basenameWithoutExtension(name);
    final canonicalPath = _existingFile(task.id).absolute.path;
    if (task.id != pathId ||
        (requestedId != null && task.id != requestedId) ||
        !p.equals(
          p.normalize(file.absolute.path),
          p.normalize(canonicalPath),
        )) {
      throw const FormatException(
        'Task document id must match its canonical path id.',
      );
    }
  }

  void _validateScope(WorkTask task, {required bool requireActive}) {
    if (!task.hasDomain) {
      if (task.hasMilestone) {
        throw const FormatException('A Task Milestone requires a Domain.');
      }
      return;
    }
    final domain = canonical.get(EntityKind.domain, task.domainId);
    final milestone = task.hasMilestone
        ? canonical.get(EntityKind.milestone, task.milestoneId)
        : null;
    if (!task.hasMilestone) {
      if (domain == null) {
        if (requireActive) {
          throw const FormatException('Task Domain does not exist.');
        }
        return;
      }
      if (requireActive && domain.data['status'] != 'active') {
        throw const FormatException('Task Domain must be active for mutation.');
      }
      return;
    }
    if (domain == null && milestone == null) return;
    if (domain == null ||
        milestone == null ||
        milestone.data['domain_id'] != task.domainId) {
      throw const FormatException(
        'Task Domain and Milestone must exist in one canonical scope.',
      );
    }
    if (requireActive &&
        (domain.data['status'] != 'active' ||
            milestone.data['status'] != 'active')) {
      throw const FormatException(
        'Task Domain and Milestone must be active for mutation.',
      );
    }
  }

  void _validateProjects(WorkTask task, {required bool requireActive}) {
    for (final id in task.projectIds) {
      final project = canonical.get(EntityKind.project, id);
      if (project == null) {
        throw FormatException('${task.id} references missing Project $id.');
      }
      if (requireActive && project.data['status'] != 'active') {
        throw FormatException('${task.id} references archived Project $id.');
      }
      if (task.hasDomain && project.data['domain_id'] != task.domainId) {
        throw FormatException(
          '${task.id} references out-of-scope Project $id.',
        );
      }
      final projectMilestone = project.data['milestone_id'];
      if (task.hasMilestone &&
          projectMilestone != null &&
          projectMilestone != task.milestoneId) {
        throw FormatException(
          '${task.id} references out-of-scope Project $id.',
        );
      }
    }
  }

  void _validateTaskRelations(WorkTask task) {
    if (task.parentTaskId == task.id || task.relatedTaskIds.contains(task.id)) {
      throw const FormatException('A Task cannot relate to itself.');
    }
    final parentId = task.parentTaskId;
    if (parentId != null) {
      final parent = _relationTarget(parentId);
      if (parent == null) {
        throw FormatException(
          '${task.id} references missing parent $parentId.',
        );
      }
      _requireCompatibleRelationScope(task, parent);
      final seen = <String>{task.id};
      WorkTask? cursor = parent;
      while (cursor != null) {
        if (!seen.add(cursor.id)) {
          throw const FormatException('Task parent relation contains a cycle.');
        }
        final next = cursor.parentTaskId;
        if (next == null) {
          cursor = null;
        } else {
          cursor = _relationTarget(next);
          if (cursor == null) {
            throw FormatException(
              '${task.id} parent chain references missing Task $next.',
            );
          }
        }
      }
    }
    for (final relatedId in task.relatedTaskIds) {
      final related = _relationTarget(relatedId);
      if (related == null) {
        throw FormatException(
          '${task.id} references missing related Task $relatedId.',
        );
      }
      _requireCompatibleRelationScope(task, related);
    }
  }

  WorkTask? _relationTarget(String id) {
    final file = _existingFile(id);
    if (!WorkspaceFileSystem.regularFileExists(workspace.root, file)) {
      return null;
    }
    final task = TaskCodec.decode(
      WorkspaceFileSystem.readText(workspace.root, file),
    );
    _validateFileIdentity(file, task, requestedId: id);
    return task;
  }

  void _requireCompatibleRelationScope(WorkTask source, WorkTask target) {
    if (source.domainId != target.domainId ||
        source.milestoneId != target.milestoneId) {
      throw FormatException(
        '${source.id} relation crosses its Domain or Milestone scope.',
      );
    }
  }

  void _validateIdList(
    WorkTask task,
    String field,
    List<String> values,
    String prefix,
  ) {
    if (values.toSet().length != values.length ||
        values.any((value) => !value.startsWith(prefix))) {
      throw FormatException('${task.id}.$field contains invalid IDs.');
    }
  }

  void _validateModelKeys(WorkTask task) {
    final pattern = RegExp(r'^[A-Za-z0-9._-]+$');
    if (task.modelSelectionKeys.toSet().length !=
            task.modelSelectionKeys.length ||
        task.modelSelectionKeys.any((key) => !pattern.hasMatch(key))) {
      throw FormatException(
        '${task.id}.model_selection_keys contains invalid keys.',
      );
    }
  }

  void _validateContextRelations(
    WorkTask task,
    EntityKind kind,
    List<String> ids,
  ) {
    for (final id in ids) {
      final target = canonical.get(kind, id);
      if (target == null) {
        throw FormatException('${task.id} references missing $id.');
      }
      final scope = canonical.scopeOf(target);
      if (!scope.permitsTask(
        domainId: task.domainId,
        milestoneId: task.milestoneId,
        taskId: task.id,
      )) {
        throw FormatException('${task.id} references out-of-scope $id.');
      }
    }
  }

  void _validateTaskId(String id) {
    if (!RegExp(r'^TSK-[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(id)) {
      throw const FormatException(
        'Task id must be a safe TSK- canonical path component.',
      );
    }
  }
}
