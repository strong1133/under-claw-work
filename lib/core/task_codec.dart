import 'package:yaml/yaml.dart';

import 'models.dart';

class TaskCodec {
  static const currentSchemaVersion = 3;

  static WorkTask decode(String content) {
    final raw = loadYaml(content) as YamlMap;
    final schemaVersion = raw['schema_version'] as int? ?? 1;
    if (schemaVersion < 1 || schemaVersion > currentSchemaVersion) {
      throw FormatException('Unsupported Task schema_version: $schemaVersion');
    }
    final prompt = raw['prompt'] as YamlMap? ?? YamlMap();
    return WorkTask(
      id: raw['id'] as String,
      domainId: raw['domain_id'] as String? ?? '',
      milestoneId: raw['milestone_id'] as String? ?? '',
      title: raw['title'] as String,
      status: TaskStatus.values.byName(raw['status'] as String? ?? 'draft'),
      promptDraft: prompt['draft'] as String? ?? '',
      promptMeta: prompt['meta'] as String? ?? '',
      promptDraftRevision: prompt['draft_revision'] as int? ?? 1,
      promptMetaSourceRevision: prompt['meta_source_revision'] as int? ?? 0,
      promptMetaSourceSha256: prompt['meta_source_sha256'] as String? ?? '',
      approval: PromptApproval.values.byName(
        prompt['approval'] as String? ?? 'missing',
      ),
      autoDeriveTasks: raw['auto_derive_tasks'] as bool? ?? false,
      autoFollowupTasks: raw['auto_followup_tasks'] as bool? ?? false,
      autoAcceptGeneratedTasks:
          raw['auto_accept_generated_tasks'] as bool? ?? false,
      maxGenerationDepth: raw['max_generation_depth'] as int? ?? 2,
      targetEnvironment: schemaVersion < 3
          ? _legacyEnvironment(raw['target_environment'])
          : _legacyEnvironment(raw['legacy_target_environment']),
      targetEnvironmentIds: schemaVersion >= 3
          ? _strings(raw, 'target_environment_ids')
          : const [],
      projectIds: _strings(raw, 'project_ids'),
      modelSelectionKeys: _strings(raw, 'model_selection_keys'),
      processingMode: TaskProcessingMode.values.byName(
        raw['processing_mode'] as String? ?? 'manual',
      ),
      executionScope: ExecutionScope.values.byName(
        // v1 predated this field. The conservative migration default is
        // multiEnvironment so legacy Tasks cannot bypass remote fencing.
        raw['execution_scope'] as String? ?? 'multiEnvironment',
      ),
      parentTaskId: raw['parent_task_id'] as String?,
      relatedTaskIds: _strings(raw, 'related_task_ids'),
      alignedObjectiveIds:
          (raw['aligned_objective_ids'] as YamlList?)
              ?.whereType<String>()
              .toList() ??
          const [],
      evidenceKnowledgeIds:
          (raw['evidence_knowledge_ids'] as YamlList?)
              ?.whereType<String>()
              .toList() ??
          const [],
      sourceReferenceIds:
          (raw['source_reference_ids'] as YamlList?)
              ?.whereType<String>()
              .toList() ??
          const [],
      generationDepth: raw['generation_depth'] as int? ?? 0,
      generationFingerprint: raw['generation_fingerprint'] as String?,
      createdAutomatically: raw['created_automatically'] as bool? ?? false,
      legacyIds:
          (raw['legacy_ids'] as YamlList?)?.whereType<String>().toList() ??
          const [],
    );
  }

  static String encode(WorkTask task) {
    String block(String value) =>
        value.split('\n').map((line) => '      $line').join('\n');
    return '''
schema_version: $currentSchemaVersion
id: ${task.id}
domain_id: ${task.hasDomain ? _scalar(task.domainId) : 'null'}
milestone_id: ${task.hasMilestone ? _scalar(task.milestoneId) : 'null'}
title: ${_scalar(task.title)}
status: ${task.status.name}
auto_derive_tasks: ${task.autoDeriveTasks}
auto_followup_tasks: ${task.autoFollowupTasks}
auto_accept_generated_tasks: ${task.autoAcceptGeneratedTasks}
max_generation_depth: ${task.maxGenerationDepth}
processing_mode: ${task.processingMode.name}
project_ids: ${_list(task.projectIds)}
target_environment_ids: ${_list(task.effectiveTargetEnvironmentIds)}
legacy_target_environment: ${task.legacyTargetEnvironment == null ? 'null' : _scalar(task.legacyTargetEnvironment!)}
model_selection_keys: ${_list(task.modelSelectionKeys)}
execution_scope: ${task.executionScope.name}
parent_task_id: ${task.parentTaskId == null ? 'null' : _scalar(task.parentTaskId!)}
related_task_ids: ${_list(task.relatedTaskIds)}
aligned_objective_ids: ${_list(task.alignedObjectiveIds)}
evidence_knowledge_ids: ${_list(task.evidenceKnowledgeIds)}
source_reference_ids: ${_list(task.sourceReferenceIds)}
generation_depth: ${task.generationDepth}
generation_fingerprint: ${task.generationFingerprint == null ? 'null' : _scalar(task.generationFingerprint!)}
created_automatically: ${task.createdAutomatically}
legacy_ids: ${_list(task.legacyIds)}
prompt:
  draft_revision: ${task.promptDraftRevision}
  meta_source_revision: ${task.promptMetaSourceRevision}
  meta_source_sha256: "${task.promptMetaSourceSha256}"
  approval: ${task.approval.name}
  draft: |-
${block(task.promptDraft)}
  meta: |-
${block(task.promptMeta)}
''';
  }

  static String _scalar(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static String _list(List<String> values) =>
      '[${values.map(_scalar).join(', ')}]';

  static List<String> _strings(YamlMap raw, String field) {
    final value = raw[field];
    if (value == null) return const [];
    if (value is! YamlList || value.any((item) => item is! String)) {
      throw FormatException('$field must be a list of strings.');
    }
    return value.cast<String>();
  }

  static String? _legacyEnvironment(Object? value) {
    final environmentId = value is String ? value : '';
    return environmentId.startsWith('ENV-') ? environmentId : null;
  }
}
