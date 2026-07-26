import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'canonical_repository.dart';
import 'id.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

enum CandidateDisposition { pending, accepted, rejected }

class TaskCandidate {
  const TaskCandidate({
    required this.id,
    required this.parentTaskId,
    required this.title,
    required this.draft,
    required this.objectiveIds,
    required this.knowledgeIds,
    required this.referenceIds,
    required this.reason,
    required this.relation,
    required this.depth,
    required this.fingerprint,
    required this.disposition,
    this.createdTaskId,
  });

  final String id;
  final String parentTaskId;
  final String title;
  final String draft;
  final List<String> objectiveIds;
  final List<String> knowledgeIds;
  final List<String> referenceIds;
  final String reason;
  final GeneratedTaskRelation relation;
  final int depth;
  final String fingerprint;
  final CandidateDisposition disposition;
  final String? createdTaskId;
}

class TaskCandidateService {
  TaskCandidateService(this.workspace);

  final Workspace workspace;

  TaskCandidate propose({
    required String parentTaskId,
    required String title,
    required String draft,
    required List<String> objectiveIds,
    required List<String> knowledgeIds,
    required List<String> referenceIds,
    required String reason,
    GeneratedTaskRelation relation = GeneratedTaskRelation.child,
  }) {
    final tasks = TaskRepository(workspace);
    final parent = tasks.get(parentTaskId);
    if (parent == null) throw StateError('Parent Task does not exist.');
    if (relation == GeneratedTaskRelation.child && !parent.autoDeriveTasks) {
      throw StateError('Parent Task child generation policy is disabled.');
    }
    if (relation == GeneratedTaskRelation.related &&
        !parent.autoFollowupTasks) {
      throw StateError('Parent Task related generation policy is disabled.');
    }
    if (title.trim().isEmpty || draft.trim().isEmpty || reason.trim().isEmpty) {
      throw const FormatException(
        'Candidate title, Draft and reason required.',
      );
    }

    final depth = parent.generationDepth + 1;
    if (depth > parent.maxGenerationDepth) {
      throw StateError('Candidate exceeds maximum generation depth.');
    }
    final canonical = CanonicalRepository(workspace);
    for (final objective in objectiveIds) {
      if (!canonical.exists(EntityKind.objective, objective)) {
        throw FormatException('Objective does not exist: $objective');
      }
    }
    for (final knowledge in knowledgeIds) {
      if (!canonical.exists(EntityKind.knowledge, knowledge)) {
        throw FormatException('Knowledge does not exist: $knowledge');
      }
    }
    for (final reference in referenceIds) {
      if (!canonical.exists(EntityKind.reference, reference)) {
        throw FormatException('Reference does not exist: $reference');
      }
    }
    final fingerprint = sha256
        .convert(
          utf8.encode(
            [
              parent.id,
              title.trim().toLowerCase(),
              ...([...objectiveIds]..sort()),
              ...([...knowledgeIds]..sort()),
              ...([...referenceIds]..sort()),
              relation.name,
            ].join('\u0000'),
          ),
        )
        .toString();
    if (list().any((item) => item.fingerprint == fingerprint) ||
        tasks.list().any((item) => item.generationFingerprint == fingerprint)) {
      throw StateError('Duplicate generated Task fingerprint.');
    }
    final candidate = TaskCandidate(
      id: newId('TGC'),
      parentTaskId: parent.id,
      title: title.trim(),
      draft: draft.trim(),
      objectiveIds: _sorted(objectiveIds),
      knowledgeIds: _sorted(knowledgeIds),
      referenceIds: _sorted(referenceIds),
      reason: reason.trim(),
      relation: relation,
      depth: depth,
      fingerprint: fingerprint,
      disposition: CandidateDisposition.pending,
    );
    _write(candidate, create: true);
    return candidate;
  }

  List<TaskCandidate> list() {
    workspace.ensureLayout();
    final files =
        workspace.candidates
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.yaml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return files.map(_read).toList();
  }

  WorkTask accept(String candidateId) {
    final candidate = _find(candidateId);
    if (candidate.disposition != CandidateDisposition.pending) {
      throw StateError('Candidate already has a disposition.');
    }
    final parent = TaskRepository(workspace).get(candidate.parentTaskId);
    if (parent == null) throw StateError('Parent Task no longer exists.');
    if (candidate.relation == GeneratedTaskRelation.child &&
        !parent.autoDeriveTasks) {
      throw StateError('Parent Task child generation policy is disabled.');
    }
    if (candidate.relation == GeneratedTaskRelation.related &&
        !parent.autoFollowupTasks) {
      throw StateError('Parent Task related generation policy is disabled.');
    }
    final task = WorkTask(
      id: newId('TSK'),
      domainId: parent.domainId,
      milestoneId: parent.milestoneId,
      title: candidate.title,
      status: parent.processingMode == TaskProcessingMode.automatic
          ? TaskStatus.metaRequested
          : TaskStatus.writing,
      promptDraft: candidate.draft,
      promptMeta: '',
      promptDraftRevision: 1,
      promptMetaSourceRevision: 0,
      approval: PromptApproval.missing,
      autoDeriveTasks: parent.autoDeriveTasks,
      autoFollowupTasks: parent.autoFollowupTasks,
      autoAcceptGeneratedTasks: parent.autoAcceptGeneratedTasks,
      maxGenerationDepth: parent.maxGenerationDepth,
      targetEnvironmentIds: parent.effectiveTargetEnvironmentIds,
      projectIds: parent.projectIds,
      modelSelectionKeys: parent.modelSelectionKeys,
      processingMode: parent.processingMode,
      executionScope: parent.executionScope,
      parentTaskId: candidate.relation == GeneratedTaskRelation.child
          ? parent.id
          : null,
      relatedTaskIds: candidate.relation == GeneratedTaskRelation.related
          ? [parent.id]
          : const [],
      alignedObjectiveIds: candidate.objectiveIds,
      evidenceKnowledgeIds: candidate.knowledgeIds,
      sourceReferenceIds: candidate.referenceIds,
      generationDepth: candidate.depth,
      generationFingerprint: candidate.fingerprint,
      createdAutomatically: true,
    );
    final tasks = TaskRepository(workspace);
    tasks.create(task);
    try {
      _write(
        _copy(
          candidate,
          disposition: CandidateDisposition.accepted,
          createdTaskId: task.id,
        ),
      );
    } catch (_) {
      tasks.delete(task.id);
      rethrow;
    }
    return task;
  }

  void reject(String candidateId) {
    final candidate = _find(candidateId);
    if (candidate.disposition != CandidateDisposition.pending) {
      throw StateError('Candidate already has a disposition.');
    }
    _write(_copy(candidate, disposition: CandidateDisposition.rejected));
  }

  TaskCandidate _find(String id) =>
      list().where((item) => item.id == id).firstOrNull ??
      (throw StateError('Candidate does not exist: $id'));

  TaskCandidate _read(File file) {
    final raw = loadYaml(file.readAsStringSync()) as YamlMap;
    List<String> strings(String key) =>
        (raw[key] as YamlList?)?.whereType<String>().toList() ?? const [];
    return TaskCandidate(
      id: raw['id'] as String,
      parentTaskId: raw['parent_task_id'] as String,
      title: raw['title'] as String,
      draft: raw['draft'] as String,
      objectiveIds: strings('objective_ids'),
      knowledgeIds: strings('knowledge_ids'),
      referenceIds: strings('reference_ids'),
      reason: raw['reason'] as String,
      relation: GeneratedTaskRelation.values.byName(
        raw['relation'] as String? ?? 'child',
      ),
      depth: raw['depth'] as int,
      fingerprint: raw['fingerprint'] as String,
      disposition: CandidateDisposition.values.byName(
        raw['disposition'] as String,
      ),
      createdTaskId: raw['created_task_id'] as String?,
    );
  }

  void _write(TaskCandidate candidate, {bool create = false}) {
    workspace.ensureLayout();
    final file = File(
      p.join(workspace.candidates.path, '${candidate.id}.yaml'),
    );
    if (create) file.createSync(exclusive: true);
    final data = {
      'schema_version': 1,
      'id': candidate.id,
      'type': 'task_candidate',
      'parent_task_id': candidate.parentTaskId,
      'title': candidate.title,
      'draft': candidate.draft,
      'objective_ids': candidate.objectiveIds,
      'knowledge_ids': candidate.knowledgeIds,
      'reference_ids': candidate.referenceIds,
      'reason': candidate.reason,
      'relation': candidate.relation.name,
      'depth': candidate.depth,
      'fingerprint': candidate.fingerprint,
      'disposition': candidate.disposition.name,
      'created_task_id': candidate.createdTaskId,
    };
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }

  TaskCandidate _copy(
    TaskCandidate source, {
    required CandidateDisposition disposition,
    String? createdTaskId,
  }) => TaskCandidate(
    id: source.id,
    parentTaskId: source.parentTaskId,
    title: source.title,
    draft: source.draft,
    objectiveIds: source.objectiveIds,
    knowledgeIds: source.knowledgeIds,
    referenceIds: source.referenceIds,
    reason: source.reason,
    relation: source.relation,
    depth: source.depth,
    fingerprint: source.fingerprint,
    disposition: disposition,
    createdTaskId: createdTaskId,
  );

  List<String> _sorted(List<String> values) =>
      (<String>{...values}.toList()..sort());
}
