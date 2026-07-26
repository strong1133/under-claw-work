import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical_repository.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

class ObsidianExportResult {
  const ObsidianExportResult({
    required this.destination,
    required this.noteCount,
    required this.removedCount,
  });

  final Directory destination;
  final int noteCount;

  /// Notes from a previous export that no longer have canonical sources.
  final int removedCount;
}

/// Renders the canonical memory repository as a read-only Obsidian vault.
///
/// The canonical prompt lives inside `task.yaml`, which Obsidian cannot open as
/// a note. Rather than splitting the canonical record, this projects it: one
/// note per entity, frontmatter for properties, `[[wikilinks]]` for relations.
///
/// The vault is derived and one-way. Editing a note changes nothing canonical,
/// because status transitions and Meta approval must pass gates that a plain
/// Markdown editor cannot enforce.
class ObsidianVaultExporter {
  ObsidianVaultExporter(this.workspace);

  /// Marks a directory as owned by this exporter, so a re-export may prune it
  /// without risking a directory the user meant to keep.
  static const vaultMarkerName = '.under-claw-vault';

  final Workspace workspace;

  ObsidianExportResult export({Directory? destination}) {
    final target = destination ?? workspace.obsidianVault;
    _assertWritableVault(target);
    target.createSync(recursive: true);

    final notes = <String, String>{
      p.join('README.md'): _readmeNote(),
      ...(_entityNotes()),
      ...(_taskNotes()),
    };

    for (final entry in notes.entries) {
      final file = File(p.join(target.path, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value, flush: true);
    }
    File(
      p.join(target.path, vaultMarkerName),
    ).writeAsStringSync('generated_by: under-claw-work\n', flush: true);

    final removed = _pruneStaleNotes(target, notes.keys.toSet());
    return ObsidianExportResult(
      destination: target,
      noteCount: notes.length,
      removedCount: removed,
    );
  }

  void _assertWritableVault(Directory target) {
    if (!target.existsSync()) return;
    if (File(p.join(target.path, vaultMarkerName)).existsSync()) return;
    if (target.listSync().isEmpty) return;
    throw StateError(
      'Refusing to export into a non-empty directory that is not an '
      'Under Claw Work vault: ${target.path}',
    );
  }

  int _pruneStaleNotes(Directory target, Set<String> current) {
    var removed = 0;
    for (final entity in target.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: target.path);
      if (p.basename(relative) == vaultMarkerName) continue;
      if (current.contains(relative)) continue;
      if (p.extension(relative) != '.md') continue;
      entity.deleteSync();
      removed++;
    }
    return removed;
  }

  static const _folders = {
    EntityKind.domain: 'Domains',
    EntityKind.milestone: 'Milestones',
    EntityKind.objective: 'Objectives',
    EntityKind.project: 'Projects',
    EntityKind.knowledge: 'Knowledge',
    EntityKind.reference: 'References',
  };

  Map<String, String> _entityNotes() {
    final repository = CanonicalRepository(workspace);
    final notes = <String, String>{};
    for (final entry in _folders.entries) {
      for (final entity in repository.list(entry.key)) {
        notes[p.join(entry.value, '${entity.id}.md')] = _entityNote(entity);
      }
    }
    return notes;
  }

  String _entityNote(CanonicalEntity entity) {
    final title = _text(entity.data['title']) ?? _text(entity.data['name']);
    final properties = <String, Object?>{
      'id': entity.id,
      'type': entity.kind.type,
      'title': ?title,
      'status': ?_text(entity.data['status']),
      'entry_kind': ?_text(entity.data['kind']),
      'generated': true,
      'canonical_source': _canonicalPath(entity.kind, entity.id),
    };

    final links = <String, List<String>>{};
    void collect(String label, Object? value) {
      final ids = _ids(value);
      if (ids.isNotEmpty) links[label] = ids;
    }

    final scope = entity.data['scope'];
    collect('domain', entity.data['domain_id']);
    collect('milestone', entity.data['milestone_id']);
    if (scope is Map) {
      collect('domain', scope['domain_id'] ?? scope['domain_ids']);
      collect('milestone', scope['milestone_id'] ?? scope['milestone_ids']);
      collect('task', scope['task_ids']);
    }
    collect('objective', entity.data['objective_ids']);
    collect('knowledge', entity.data['knowledge_ids']);
    collect('reference', entity.data['reference_ids']);
    collect('reference', entity.data['source_refs']);

    return _note(
      properties: properties,
      heading: title ?? entity.id,
      links: links,
      sections: {if (entity.body.trim().isNotEmpty) '내용': entity.body.trim()},
    );
  }

  Map<String, String> _taskNotes() {
    final notes = <String, String>{};
    for (final task in TaskRepository(workspace).list()) {
      notes[p.join('Tasks', '${task.id}.md')] = _taskNote(task);
    }
    return notes;
  }

  String _taskNote(WorkTask task) {
    final properties = <String, Object?>{
      'id': task.id,
      'type': 'task',
      'title': task.title,
      'status': task.status.name,
      'approval': task.approval.name,
      'processing_mode': task.processingMode.name,
      'draft_revision': task.promptDraftRevision,
      'meta_current': task.isMetaCurrent,
      'generated': true,
      'canonical_source': _canonicalPath(EntityKind.task, task.id),
    };

    final links = <String, List<String>>{};
    void link(String label, List<String> ids) {
      if (ids.isNotEmpty) links[label] = ids;
    }

    link('domain', _ids(task.domainId));
    link('milestone', _ids(task.milestoneId));
    link('parent', _ids(task.parentTaskId));
    link('related', task.relatedTaskIds);
    link('project', task.projectIds);
    link('objective', task.alignedObjectiveIds);
    link('knowledge', task.evidenceKnowledgeIds);
    link('reference', task.sourceReferenceIds);

    return _note(
      properties: properties,
      heading: task.title,
      links: links,
      sections: {
        if (task.promptDraft.trim().isNotEmpty)
          'Draft': task.promptDraft.trim(),
        if (task.promptMeta.trim().isNotEmpty)
          'Meta Prompt': task.promptMeta.trim(),
      },
    );
  }

  String _note({
    required Map<String, Object?> properties,
    required String heading,
    required Map<String, List<String>> links,
    required Map<String, String> sections,
  }) {
    final buffer = StringBuffer('---\n');
    for (final entry in properties.entries) {
      buffer.writeln('${entry.key}: ${_yamlScalar(entry.value)}');
    }
    for (final entry in links.entries) {
      buffer.writeln('${entry.key}_ids:');
      for (final id in entry.value) {
        buffer.writeln('  - $id');
      }
    }
    buffer
      ..writeln('---')
      ..writeln()
      ..writeln('> [!warning] 파생 노트')
      ..writeln('> 정본이 아니다. 여기서 고친 내용은 반영되지 않는다.')
      ..writeln()
      ..writeln('# $heading')
      ..writeln();

    if (links.isNotEmpty) {
      buffer.writeln('## 연결');
      for (final entry in links.entries) {
        final rendered = entry.value.map((id) => '[[$id]]').join(', ');
        buffer.writeln('- ${entry.key}: $rendered');
      }
      buffer.writeln();
    }
    for (final entry in sections.entries) {
      buffer
        ..writeln('## ${entry.key}')
        ..writeln()
        ..writeln(entry.value)
        ..writeln();
    }
    return buffer.toString();
  }

  String _readmeNote() =>
      '''
---
generated: true
---

> [!warning] 파생 vault
> 이 폴더는 `worklog obsidian-export`가 정본에서 생성한 읽기 전용 사본이다.
> 여기서 편집한 내용은 정본으로 돌아가지 않으며 다음 export에서 덮어써진다.

# 기억 저장소 vault

정본은 `${p.basename(workspace.workdb.path)}/`의 YAML·Markdown이다. 상태 전이와
Meta 승인은 게이트를 거쳐야 하므로 `worklog` CLI 또는 데스크톱 앱에서만 수행한다.

- `Tasks/` — Task 1건당 노트 1개. Draft와 Meta를 본문 섹션으로 펼친다.
- `Domains/`, `Milestones/`, `Objectives/`, `Projects/`
- `Knowledge/`, `References/`

노트 파일명은 정본 ID다. 그래서 `[[TSK-...]]` 링크와 그래프 뷰, 백링크가 정본
관계를 그대로 따른다.
''';

  String _canonicalPath(EntityKind kind, String id) => p.posix.joinAll(
    p.split(
      p.relative(
        CanonicalRepository(workspace).fileFor(kind, id).path,
        from: workspace.root.path,
      ),
    ),
  );

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _ids(Object? value) {
    if (value is String) {
      return _text(value) == null ? const [] : [value.trim()];
    }
    if (value is List) return value.expand(_ids).toList();
    return const [];
  }

  static String _yamlScalar(Object? value) {
    if (value is bool || value is num) return '$value';
    final text = '$value';
    return text.contains(RegExp(r'''[:#\[\]{}"'\n]''')) || text.trim() != text
        ? '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"'
        : text;
  }
}
