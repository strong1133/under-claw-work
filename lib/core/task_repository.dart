import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'task_codec.dart';
import 'workspace.dart';
import 'schema_validator.dart';

class TaskRepository {
  TaskRepository(this.workspace);

  final Workspace workspace;

  static String draftSha256(String draft) =>
      sha256.convert(utf8.encode(draft)).toString();

  List<WorkTask> list() {
    workspace.ensureLayout();
    final files =
        workspace.tasks
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  p.basename(file.path) == 'task.yaml' ||
                  (p.equals(file.parent.path, workspace.tasks.path) &&
                      p.basename(file.path).startsWith('TSK-') &&
                      file.path.endsWith('.yaml')),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return files.map(TaskCodec.read).toList();
  }

  WorkTask? get(String id) {
    final file = _existingFile(id);
    return file.existsSync() ? TaskCodec.read(file) : null;
  }

  WorkTask create(WorkTask task) {
    _validate(task);
    final file = _file(task.id);
    file.parent.createSync(recursive: true);
    file.createSync(exclusive: true);
    file.writeAsStringSync(TaskCodec.encode(task), flush: true);
    return task;
  }

  WorkTask update(WorkTask task) {
    _validate(task);
    final file = _existingFile(task.id);
    if (!file.existsSync()) throw StateError('Task does not exist: ${task.id}');
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(TaskCodec.encode(task), flush: true);
    temporary.renameSync(file.path);
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
    return update(task.copyWith(approval: PromptApproval.approved));
  }

  void delete(String id) {
    final file = _existingFile(id);
    if (!file.existsSync()) throw StateError('Task does not exist: $id');
    file.deleteSync();
  }

  File _file(String id) => File(p.join(workspace.tasks.path, id, 'task.yaml'));

  File _existingFile(String id) {
    final nested = _file(id);
    if (nested.existsSync()) return nested;
    return File(p.join(workspace.tasks.path, '$id.yaml'));
  }

  void _validate(WorkTask task) {
    WorklogContractValidator().validateTask(task);
    if (!task.id.startsWith('TSK-') ||
        !task.domainId.startsWith('DOM-') ||
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
    if (task.approval == PromptApproval.approved && !task.isMetaCurrent) {
      throw const FormatException('Approved Meta Prompt must be current.');
    }
  }
}
