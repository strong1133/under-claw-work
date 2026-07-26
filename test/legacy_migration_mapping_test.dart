import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

/// Reproduces the shape of the real `ai/prompt-task` corpus: a convention
/// document that contains an example block, and per-Domain directories whose
/// blocks are marked `요청완료` with local absolute paths in `targets::`.
void main() {
  late Directory temporary;
  late Workspace workspace;
  late Directory source;
  late String alphaDomainId;
  late String betaDomainId;
  late String milestoneId;
  late String projectId;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-migration-');
    workspace = Workspace(temporary)..ensureLayout();
    final entities = EntityService(workspace);
    alphaDomainId = entities.create(kind: EntityKind.domain, title: 'alpha').id;
    betaDomainId = entities.create(kind: EntityKind.domain, title: 'beta').id;
    milestoneId = entities
        .create(
          kind: EntityKind.milestone,
          title: 'backlog',
          domainId: alphaDomainId,
        )
        .id;
    projectId = ScopeConfigurationService(
      workspace,
    ).createProject(title: 'alpha-product', domainId: alphaDomainId).id;

    source = Directory('${temporary.path}/legacy')..createSync();
    File('${source.path}/_SYSTEM.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
# prompt-task 시스템 규약

블록 포맷 예시는 아래와 같다.

[요청완료] <PT-20260628-beta-99>

**요구사항**
옵션 범위 정정
targets:: beta
related::
''');
    File('${source.path}/alpha/2026/07/2026-07-21.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[요청완료] <PT-20260721-alpha-01>

**요구사항**
검색창에서 식별번호로 항목이 검색되지 않는다.
targets:: /Users/someone/work/alpha-product, alpha-product
related::

[요청완료] <PT-20260721-alpha-02>

**요구사항**
기한 항목에 종일 체크란을 추가한다.
targets::
related:: PT-20260721-alpha-01, PT-20250101-gone-01

#### Meta Prompt
    # 역할
    대상 서비스의 풀스택 유지보수 개발자.
###
''');
    File('${source.path}/beta/2026/07/2026-07-03.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[요청완료] <PT-20260703-beta-01>

**요구사항**
계산기를 고친다.
targets::
related::
''');
    File('${source.path}/alpha/2026/06/2026-06-30.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
[완료] <PT-20260630-alpha-09>

**요구사항**
이미 끝난 작업.
targets::
related::
''');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  List<WorkTask> importAll(MigrationDryRun plan) =>
      LegacyMigrationService(workspace).import(
        plan,
        approved: true,
        domainId: alphaDomainId,
        milestoneId: milestoneId,
        targetEnvironment: 'ENV-legacy',
        domainIdsBySourcePrefix: {'alpha': alphaDomainId, 'beta': betaDomainId},
        targetProjectIds: {'alpha-product': projectId},
      );

  test('convention documents are excluded from the imported blocks', () {
    final plan = LegacyMigrationService(workspace).dryRun(source);

    expect(
      plan.blocks.map((block) => block.legacyId),
      isNot(contains('PT-20260628-beta-99')),
    );
    expect(
      plan.skipped.join('\n'),
      contains('_SYSTEM.md: convention document excluded'),
    );
    expect(plan.blocks, hasLength(4));
  });

  test('요청완료 imports as a waiting state, not as completed', () {
    final plan = LegacyMigrationService(workspace).dryRun(source);
    final imported = {
      for (final task in importAll(plan)) task.legacyIds.single: task,
    };

    // No Meta yet — the request waits for Meta Prompt authoring.
    expect(imported['PT-20260721-alpha-01']!.status, TaskStatus.metaRequested);
    expect(imported['PT-20260703-beta-01']!.status, TaskStatus.metaRequested);
    // Meta already written by hand — it waits for review, not for authoring.
    expect(imported['PT-20260721-alpha-02']!.status, TaskStatus.metaReview);
    expect(imported['PT-20260721-alpha-02']!.approval, PromptApproval.pending);
    // A bare completion label still closes the Task.
    expect(imported['PT-20260630-alpha-09']!.status, TaskStatus.completed);

    expect(
      imported.values.where((task) => task.status == TaskStatus.completed),
      hasLength(1),
    );
  });

  test('source directory maps each block to its own Domain', () {
    final plan = LegacyMigrationService(workspace).dryRun(source);
    final imported = {
      for (final task in importAll(plan)) task.legacyIds.single: task,
    };

    expect(imported['PT-20260721-alpha-01']!.domainId, alphaDomainId);
    expect(imported['PT-20260703-beta-01']!.domainId, betaDomainId);
    // A Milestone is only valid inside its owning Domain.
    expect(imported['PT-20260721-alpha-01']!.milestoneId, milestoneId);
    expect(imported['PT-20260703-beta-01']!.milestoneId, '');
  });

  test('targets link only through an explicit Project mapping', () {
    final plan = LegacyMigrationService(workspace).dryRun(source);
    final imported = {
      for (final task in importAll(plan)) task.legacyIds.single: task,
    };

    expect(imported['PT-20260721-alpha-01']!.projectIds, [projectId]);

    // The local absolute path had no mapping, so it must not reach Task YAML.
    final yaml = File(
      '${workspace.tasks.path}/${imported['PT-20260721-alpha-01']!.id}/task.yaml',
    ).readAsStringSync();
    expect(yaml, isNot(contains('/Users/someone')));

    final report = jsonDecode(
      File(
        '${workspace.migrations.path}/${plan.importId}.json',
      ).readAsStringSync(),
    );
    final residue = (report['residue'] as List).cast<Map<String, Object?>>();
    expect(
      residue.where(
        (item) =>
            item['field'] == 'targets' &&
            item['value'] == '/Users/someone/work/alpha-product',
      ),
      hasLength(1),
    );
  });

  test('related PT ids resolve to Task ids in a second pass', () {
    final plan = LegacyMigrationService(workspace).dryRun(source);
    final tasks = importAll(plan);
    final imported = {for (final task in tasks) task.legacyIds.single: task};

    expect(imported['PT-20260721-alpha-02']!.relatedTaskIds, [
      imported['PT-20260721-alpha-01']!.id,
    ]);
    expect(
      TaskRepository(
        workspace,
      ).get(imported['PT-20260721-alpha-02']!.id)!.relatedTaskIds,
      [imported['PT-20260721-alpha-01']!.id],
    );

    final report = jsonDecode(
      File(
        '${workspace.migrations.path}/${plan.importId}.json',
      ).readAsStringSync(),
    );
    final residue = (report['residue'] as List).cast<Map<String, Object?>>();
    expect(
      residue.where(
        (item) =>
            item['field'] == 'related' &&
            item['value'] == 'PT-20250101-gone-01',
      ),
      hasLength(1),
    );
  });
}
