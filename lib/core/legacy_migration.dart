import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'id.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

class LegacyPromptBlock {
  const LegacyPromptBlock({
    required this.legacyId,
    required this.stateLabel,
    required this.draft,
    required this.meta,
    required this.targets,
    required this.relatedIds,
    required this.sourcePath,
    required this.sourceLine,
  });

  final String legacyId;
  final String stateLabel;
  final String draft;
  final String meta;
  final List<String> targets;
  final List<String> relatedIds;
  final String sourcePath;
  final int sourceLine;

  /// First path segment of [sourcePath]. The legacy corpus encodes its Domain
  /// in the directory layout (`<domain>/2026/07/2026-07-21.md`), so this is
  /// the key an importer maps to a canonical Domain.
  String get sourcePrefix {
    final segments = p.posix.split(sourcePath.replaceAll(r'\', '/'));
    return segments.length > 1 ? segments.first : '';
  }
}

/// Portable data a block carried that could not be represented canonically.
/// Recorded rather than silently dropped, and never written into Task YAML.
class MigrationResidue {
  const MigrationResidue({
    required this.legacyId,
    required this.field,
    required this.value,
    required this.reason,
  });

  final String legacyId;
  final String field;
  final String value;
  final String reason;

  Map<String, Object?> toJson() => {
    'legacy_id': legacyId,
    'field': field,
    'value': value,
    'reason': reason,
  };
}

class MigrationDryRun {
  const MigrationDryRun({
    required this.importId,
    required this.sourceRoot,
    required this.blocks,
    required this.skipped,
    required this.sourceFingerprint,
  });

  final String importId;
  final String sourceRoot;
  final List<LegacyPromptBlock> blocks;
  final List<String> skipped;
  final String sourceFingerprint;
}

class LegacyMigrationService {
  LegacyMigrationService(this.workspace);

  final Workspace workspace;

  MigrationDryRun dryRun(Directory source) {
    final result = _scan(source);
    _writeReport(result, importedTaskIds: const []);
    return result;
  }

  MigrationDryRun _scan(Directory source) {
    if (!source.existsSync()) throw StateError('Legacy source does not exist.');
    final files =
        source
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final blocks = <LegacyPromptBlock>[];
    final skipped = <String>[];
    final fingerprintBytes = BytesBuilder(copy: false);
    for (final file in files) {
      final content = file.readAsStringSync();
      final relative = p.relative(file.path, from: source.path);
      fingerprintBytes.add(utf8.encode('$relative\n'));
      fingerprintBytes.add(utf8.encode(content));
      // Convention documents (`_SYSTEM.md`, `_dashboard.md`) describe the block
      // format using fully-formed example blocks. Parsing them would import
      // documentation as real Tasks, so they are excluded by name.
      if (p.basename(file.path).startsWith('_')) {
        skipped.add('$relative: convention document excluded');
        continue;
      }
      final parsed = _parseFile(file, content, source.path);
      blocks.addAll(parsed.$1);
      skipped.addAll(parsed.$2);
    }
    final result = MigrationDryRun(
      importId: newId('MIG'),
      sourceRoot: source.absolute.path,
      blocks: blocks,
      skipped: skipped,
      sourceFingerprint: sha256
          .convert(fingerprintBytes.takeBytes())
          .toString(),
    );
    return result;
  }

  /// Imports [plan] into canonical Tasks.
  ///
  /// [domainIdsBySourcePrefix] maps the legacy corpus' top-level directory
  /// (its de-facto Domain) to a canonical Domain id; blocks with no entry fall
  /// back to [domainId]. [targetProjectIds] maps a `targets::` value to a
  /// canonical Project id — unmapped values stay out of canonical Task data
  /// because the legacy corpus records local absolute paths there, and those
  /// must never enter portable entities.
  List<WorkTask> import(
    MigrationDryRun plan, {
    required bool approved,
    required String domainId,
    required String milestoneId,
    required String targetEnvironment,
    Map<String, String> domainIdsBySourcePrefix = const {},
    Map<String, String> targetProjectIds = const {},
  }) {
    if (!approved) {
      throw StateError('Migration import requires explicit approval.');
    }
    final current = _scan(Directory(plan.sourceRoot));
    if (current.sourceFingerprint != plan.sourceFingerprint) {
      throw StateError('Legacy source changed after dry-run.');
    }
    final repository = TaskRepository(workspace);
    final existingLegacy = repository
        .list()
        .expand((task) => task.legacyIds)
        .toSet();
    final created = <WorkTask>[];
    final residue = <MigrationResidue>[];
    final taskIdByLegacyId = <String, String>{};
    try {
      for (final block in plan.blocks) {
        if (existingLegacy.contains(block.legacyId)) {
          throw StateError('Legacy ID already imported: ${block.legacyId}');
        }
        final meta = block.meta.trim();
        final blockDomainId =
            domainIdsBySourcePrefix[block.sourcePrefix] ?? domainId;
        final projectIds = <String>[];
        for (final target in block.targets) {
          final projectId = targetProjectIds[target];
          if (projectId == null) {
            residue.add(
              MigrationResidue(
                legacyId: block.legacyId,
                field: 'targets',
                value: target,
                reason: 'no canonical Project mapping supplied',
              ),
            );
            continue;
          }
          if (!projectIds.contains(projectId)) projectIds.add(projectId);
        }
        final task = WorkTask(
          id: newId('TSK'),
          domainId: blockDomainId,
          // A Milestone is only valid inside its own Domain, so it applies to
          // the fallback Domain alone.
          milestoneId: blockDomainId == domainId ? milestoneId : '',
          title: _title(block.draft, block.legacyId),
          status: _status(block.stateLabel, hasMeta: meta.isNotEmpty),
          promptDraft: block.draft,
          promptMeta: meta,
          promptDraftRevision: 1,
          promptMetaSourceRevision: meta.isEmpty ? 0 : 1,
          promptMetaSourceSha256: meta.isEmpty
              ? ''
              : TaskRepository.draftSha256(block.draft),
          approval: meta.isEmpty
              ? PromptApproval.missing
              : PromptApproval.pending,
          autoDeriveTasks: false,
          targetEnvironment: targetEnvironment,
          projectIds: projectIds,
          legacyIds: [block.legacyId],
        );
        repository.create(task);
        created.add(task);
        taskIdByLegacyId[block.legacyId] = task.id;
      }
      _linkRelatedTasks(repository, plan, created, taskIdByLegacyId, residue);
    } catch (_) {
      for (final task in created.reversed) {
        repository.delete(task.id);
      }
      rethrow;
    }
    _writeReport(
      plan,
      importedTaskIds: created.map((task) => task.id).toList(),
      residue: residue,
    );
    return created;
  }

  /// Second pass: `related::` names legacy PT ids, which only resolve to Task
  /// ids once every block in the import has one. Ids outside this import stay
  /// unresolved and are recorded rather than dropped.
  void _linkRelatedTasks(
    TaskRepository repository,
    MigrationDryRun plan,
    List<WorkTask> created,
    Map<String, String> taskIdByLegacyId,
    List<MigrationResidue> residue,
  ) {
    for (var index = 0; index < plan.blocks.length; index++) {
      final block = plan.blocks[index];
      if (block.relatedIds.isEmpty) continue;
      final relatedTaskIds = <String>[];
      for (final legacyId in block.relatedIds) {
        final taskId = taskIdByLegacyId[legacyId];
        if (taskId == null) {
          residue.add(
            MigrationResidue(
              legacyId: block.legacyId,
              field: 'related',
              value: legacyId,
              reason: 'legacy id is not part of this import',
            ),
          );
          continue;
        }
        if (taskId != created[index].id && !relatedTaskIds.contains(taskId)) {
          relatedTaskIds.add(taskId);
        }
      }
      if (relatedTaskIds.isEmpty) continue;
      created[index] = repository.update(
        created[index].copyWith(relatedTaskIds: relatedTaskIds),
      );
    }
  }

  void rollback(String importId) {
    final report = _reportFile(importId);
    if (!report.existsSync()) throw StateError('Migration report not found.');
    final value = jsonDecode(report.readAsStringSync()) as Map<String, Object?>;
    final ids =
        (value['imported_task_ids'] as List?)?.whereType<String>().toList() ??
        const [];
    final repository = TaskRepository(workspace);
    for (final id in ids) {
      final task = repository.get(id);
      if (task == null) continue;
      if (task.legacyIds.isEmpty) {
        throw StateError('Refusing to remove non-migration Task: $id');
      }
      repository.delete(id);
    }
    final rolledBack = {...value, 'rolled_back_at': _now()};
    report.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(rolledBack)}\n',
      flush: true,
    );
  }

  (List<LegacyPromptBlock>, List<String>) _parseFile(
    File file,
    String content,
    String root,
  ) {
    final lines = content.split('\n');
    final header = RegExp(r'^\[([^\]]*)\]\s*<\s*(PT-[A-Za-z0-9-]+)\s*>\s*$');
    final starts = <int>[];
    for (var index = 0; index < lines.length; index++) {
      if (header.hasMatch(lines[index].trim())) starts.add(index);
    }
    final blocks = <LegacyPromptBlock>[];
    final skipped = <String>[];
    for (var index = 0; index < starts.length; index++) {
      final start = starts[index];
      final end = index + 1 < starts.length ? starts[index + 1] : lines.length;
      final match = header.firstMatch(lines[start].trim())!;
      final section = lines.sublist(start + 1, end);
      final metaStart = section.indexWhere(
        (line) => line.trim() == '#### Meta Prompt',
      );
      final beforeMeta = metaStart < 0
          ? section
          : section.sublist(0, metaStart);
      final metaLines = metaStart < 0
          ? const <String>[]
          : section.sublist(metaStart + 1);
      final draftLines = <String>[];
      final targets = <String>[];
      final related = <String>[];
      var requirementsSeen = false;
      for (final line in beforeMeta) {
        final trimmed = line.trim();
        if (trimmed == '**요구사항**') {
          requirementsSeen = true;
          continue;
        }
        if (trimmed.startsWith('targets::')) {
          targets.addAll(_csv(trimmed.substring('targets::'.length)));
          continue;
        }
        if (trimmed.startsWith('related::')) {
          related.addAll(_csv(trimmed.substring('related::'.length)));
          continue;
        }
        if (requirementsSeen || trimmed.isNotEmpty) draftLines.add(line);
      }
      final draft = _clean(draftLines);
      final meta = _cleanMeta(metaLines);
      final source = p.relative(file.path, from: root);
      if (draft.isEmpty) {
        skipped.add('$source:${start + 1}: empty template ${match.group(2)}');
        continue;
      }
      blocks.add(
        LegacyPromptBlock(
          legacyId: match.group(2)!,
          stateLabel: match.group(1)!.trim(),
          draft: draft,
          meta: meta,
          targets: targets,
          relatedIds: related,
          sourcePath: source,
          sourceLine: start + 1,
        ),
      );
    }
    return (blocks, skipped);
  }

  String _clean(List<String> lines) {
    final copy = [...lines];
    while (copy.isNotEmpty && copy.first.trim().isEmpty) {
      copy.removeAt(0);
    }
    while (copy.isNotEmpty && copy.last.trim().isEmpty) {
      copy.removeLast();
    }
    return copy.join('\n').trim();
  }

  String _cleanMeta(List<String> lines) {
    final retained = <String>[];
    for (final line in lines) {
      if (line.trim() == '###') break;
      if (line.contains('<!-- 여기에 Meta Prompt를 기록 -->')) continue;
      retained.add(line.startsWith('    ') ? line.substring(4) : line);
    }
    return _clean(retained);
  }

  List<String> _csv(String value) => value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  String _title(String draft, String fallback) {
    final line = draft
        .split('\n')
        .map((item) => item.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => fallback);
    return line.length <= 80 ? line : '${line.substring(0, 77)}...';
  }

  /// Maps a legacy state label to a canonical status.
  ///
  /// `요청완료` means the *request* was finished, not the work: the legacy
  /// convention document states the user writes the label by hand and performs
  /// the work themselves. It therefore imports as a waiting state, not as
  /// `completed`. Only a bare completion label closes the Task.
  TaskStatus _status(String label, {required bool hasMeta}) {
    final normalized = label.trim().toLowerCase();
    if (normalized == '요청완료' || normalized == 'requested') {
      return hasMeta ? TaskStatus.metaReview : TaskStatus.metaRequested;
    }
    if (normalized.contains('완료') || normalized == 'done') {
      return TaskStatus.completed;
    }
    if (normalized.contains('진행') || normalized == 'running') {
      return TaskStatus.running;
    }
    if (normalized.contains('중단') || normalized == 'blocked') {
      return TaskStatus.blocked;
    }
    if (normalized.contains('취소') || normalized == 'cancelled') {
      return TaskStatus.cancelled;
    }
    return TaskStatus.draft;
  }

  void _writeReport(
    MigrationDryRun result, {
    required List<String> importedTaskIds,
    List<MigrationResidue> residue = const [],
  }) {
    workspace.ensureLayout();
    final data = {
      'schema_version': 1,
      'import_id': result.importId,
      'source_locator': p.basename(result.sourceRoot),
      'source_fingerprint': result.sourceFingerprint,
      'created_at': _now(),
      'blocks': result.blocks
          .map(
            (block) => {
              'legacy_id': block.legacyId,
              'state': block.stateLabel,
              'source_path': block.sourcePath,
              'source_prefix': block.sourcePrefix,
              'source_line': block.sourceLine,
              'targets': block.targets,
              'related_ids': block.relatedIds,
              'has_meta': block.meta.isNotEmpty,
            },
          )
          .toList(),
      'skipped': result.skipped,
      'imported_task_ids': importedTaskIds,
      'residue': residue.map((item) => item.toJson()).toList(),
    };
    _reportFile(result.importId).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
      flush: true,
    );
  }

  File _reportFile(String importId) =>
      File(p.join(workspace.migrations.path, '$importId.json'));

  String _now() => DateTime.now().toUtc().toIso8601String();
}
