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
    final next = task.copyWith(
      promptDraft: draft,
      promptDraftRevision: task.promptDraftRevision + 1,
      approval: PromptApproval.stale,
    );
    return update(next);
  }

  WorkTask saveMeta(WorkTask task, String meta) {
    return update(
      task.copyWith(
        promptMeta: meta,
        promptMetaSourceRevision: task.promptDraftRevision,
        promptMetaSourceSha256: draftSha256(task.promptDraft),
        approval: PromptApproval.pending,
      ),
    );
  }

  WorkTask approveMeta(WorkTask task) {
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
        status: task.status == TaskStatus.draft
            ? TaskStatus.ready
            : task.status,
      ),
    );
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
    if (!task.domainId.startsWith('DOM-') ||
        !task.milestoneId.startsWith('MLS-') ||
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
        (task.parentTaskId == null || task.alignedObjectiveIds.isEmpty)) {
      throw const FormatException(
        'Automatically generated Tasks require a parent and Objective.',
      );
    }
    if (!allowStaleApproval &&
        task.approval == PromptApproval.approved &&
        !task.isMetaCurrent) {
      throw const FormatException('Approved Meta Prompt must be current.');
    }
    _validateScope(task, requireActive: requireActiveScope);
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
    final domain = canonical.get(EntityKind.domain, task.domainId);
    final milestone = canonical.get(EntityKind.milestone, task.milestoneId);
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
