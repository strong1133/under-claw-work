import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late String domainId;
  late String milestoneId;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-obsidian-');
    workspace = Workspace(temporary)..ensureLayout();
    final entities = EntityService(workspace);
    domainId = entities.create(kind: EntityKind.domain, title: '제품 도메인').id;
    milestoneId = entities
        .create(kind: EntityKind.milestone, title: '검색 안정화', domainId: domainId)
        .id;
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  WorkTask createTask({
    required String id,
    String title = 'List search',
    String draft = 'Draft 본문',
    String meta = '',
    String? parentTaskId,
    List<String> relatedTaskIds = const [],
    bool scoped = true,
  }) => TaskRepository(workspace).create(
    WorkTask(
      id: id,
      domainId: scoped ? domainId : '',
      milestoneId: scoped ? milestoneId : '',
      title: title,
      status: TaskStatus.metaRequested,
      promptDraft: draft,
      promptMeta: meta,
      promptDraftRevision: 1,
      promptMetaSourceRevision: 0,
      approval: PromptApproval.missing,
      autoDeriveTasks: false,
      parentTaskId: parentTaskId,
      relatedTaskIds: relatedTaskIds,
    ),
  );

  String noteFor(Directory vault, String relative) =>
      File(p.join(vault.path, relative)).readAsStringSync();

  test('a Task becomes a note that exposes the canonical prompt', () {
    createTask(id: 'TSK-search', draft: '검색은 연결 항목까지 매칭해야 한다.');

    final result = ObsidianVaultExporter(workspace).export();
    final note = noteFor(result.destination, p.join('Tasks', 'TSK-search.md'));

    // Obsidian reads the frontmatter as note properties.
    expect(note, contains('id: TSK-search'));
    expect(note, contains('status: metaRequested'));
    expect(note, contains('draft_revision: 1'));
    // The prompt lives inside task.yaml canonically; the note unfolds it.
    expect(note, contains('## Draft'));
    expect(note, contains('검색은 연결 항목까지 매칭해야 한다.'));
    // Every note declares that it is derived, not canonical.
    expect(note, contains('generated: true'));
    expect(
      note,
      contains('canonical_source: workdb/tasks/TSK-search/task.yaml'),
    );
    expect(note, contains('정본이 아니다'));
  });

  test('relations render as wikilinks that resolve to other notes', () {
    createTask(id: 'TSK-parent');
    createTask(id: 'TSK-sibling');
    createTask(
      id: 'TSK-child',
      parentTaskId: 'TSK-parent',
      relatedTaskIds: const ['TSK-sibling'],
    );

    final result = ObsidianVaultExporter(workspace).export();
    final note = noteFor(result.destination, p.join('Tasks', 'TSK-child.md'));

    expect(note, contains('[[TSK-parent]]'));
    expect(note, contains('[[TSK-sibling]]'));
    expect(note, contains('[[$domainId]]'));
    expect(note, contains('[[$milestoneId]]'));

    // A wikilink resolves by basename, so each target must exist as a note.
    for (final target in [
      p.join('Tasks', 'TSK-parent.md'),
      p.join('Tasks', 'TSK-sibling.md'),
      p.join('Domains', '$domainId.md'),
      p.join('Milestones', '$milestoneId.md'),
    ]) {
      expect(
        File(p.join(result.destination.path, target)).existsSync(),
        isTrue,
        reason: '$target is linked but missing',
      );
    }
  });

  test('an unscoped Task exports without domain or milestone links', () {
    createTask(id: 'TSK-loose', scoped: false);

    final result = ObsidianVaultExporter(workspace).export();
    final note = noteFor(result.destination, p.join('Tasks', 'TSK-loose.md'));

    expect(note, isNot(contains('domain_ids:')));
    expect(note, isNot(contains('milestone_ids:')));
  });

  test('Knowledge and Reference notes carry their scope and body', () {
    final knowledge = EntityService(workspace).create(
      kind: EntityKind.knowledge,
      title: '검색 계약',
      domainId: domainId,
      body: '식별번호와 기관명을 함께 매칭한다.',
    );

    final result = ObsidianVaultExporter(workspace).export();
    final note = noteFor(
      result.destination,
      p.join('Knowledge', '${knowledge.id}.md'),
    );

    expect(note, contains('type: knowledge'));
    expect(note, contains('[[$domainId]]'));
    expect(note, contains('식별번호와 기관명을 함께 매칭한다.'));
  });

  test(
    're-export refreshes notes and prunes ones without a canonical source',
    () {
      createTask(id: 'TSK-keeper', draft: '첫 초안');
      final removed = createTask(id: 'TSK-doomed');
      final exporter = ObsidianVaultExporter(workspace);
      final vault = exporter.export().destination;
      expect(
        File(p.join(vault.path, 'Tasks', 'TSK-doomed.md')).existsSync(),
        isTrue,
      );

      CanonicalRepository(workspace).delete(EntityKind.task, removed.id);
      final tasks = TaskRepository(workspace);
      tasks.update(tasks.get('TSK-keeper')!.copyWith(promptDraft: '고친 초안'));
      final second = exporter.export();

      expect(
        File(p.join(vault.path, 'Tasks', 'TSK-doomed.md')).existsSync(),
        isFalse,
      );
      expect(second.removedCount, 1);
      expect(
        noteFor(vault, p.join('Tasks', 'TSK-keeper.md')),
        contains('고친 초안'),
      );
    },
  );

  test('export refuses a non-empty directory it does not own', () {
    final foreign = Directory(p.join(temporary.path, 'notes'))
      ..createSync(recursive: true);
    File(p.join(foreign.path, 'my-own-note.md')).writeAsStringSync('사용자 노트');

    expect(
      () => ObsidianVaultExporter(workspace).export(destination: foreign),
      throwsStateError,
    );
    // The user's own file is untouched.
    expect(
      File(p.join(foreign.path, 'my-own-note.md')).readAsStringSync(),
      '사용자 노트',
    );
  });

  test('the default vault stays out of the canonical tree', () {
    createTask(id: 'TSK-placement');

    final result = ObsidianVaultExporter(workspace).export();

    expect(p.isWithin(workspace.local.path, result.destination.path), isTrue);
    expect(p.isWithin(workspace.workdb.path, result.destination.path), isFalse);
  });
}
