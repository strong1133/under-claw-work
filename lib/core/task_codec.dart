import 'dart:io';

import 'package:yaml/yaml.dart';

import 'models.dart';

class TaskCodec {
  static WorkTask read(File file) {
    final raw = loadYaml(file.readAsStringSync()) as YamlMap;
    final prompt = raw['prompt'] as YamlMap? ?? YamlMap();
    return WorkTask(
      id: raw['id'] as String,
      domainId: raw['domain_id'] as String,
      milestoneId: raw['milestone_id'] as String,
      title: raw['title'] as String,
      status: TaskStatus.values.byName(raw['status'] as String? ?? 'draft'),
      promptDraft: prompt['draft'] as String? ?? '',
      promptMeta: prompt['meta'] as String? ?? '',
      promptDraftRevision: prompt['draft_revision'] as int? ?? 1,
      promptMetaSourceRevision: prompt['meta_source_revision'] as int? ?? 0,
      approval: PromptApproval.values.byName(
        prompt['approval'] as String? ?? 'missing',
      ),
      autoDeriveTasks: raw['auto_derive_tasks'] as bool? ?? false,
      targetEnvironment: raw['target_environment'] as String? ?? 'local',
    );
  }

  static String encode(WorkTask task) {
    String block(String value) =>
        value.split('\n').map((line) => '      $line').join('\n');
    return '''
schema_version: 1
id: ${task.id}
domain_id: ${task.domainId}
milestone_id: ${task.milestoneId}
title: ${_scalar(task.title)}
status: ${task.status.name}
auto_derive_tasks: ${task.autoDeriveTasks}
target_environment: ${_scalar(task.targetEnvironment)}
prompt:
  draft_revision: ${task.promptDraftRevision}
  meta_source_revision: ${task.promptMetaSourceRevision}
  approval: ${task.approval.name}
  draft: |-
${block(task.promptDraft)}
  meta: |-
${block(task.promptMeta)}
''';
  }

  static String _scalar(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
