import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late String domainId;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-attachment-');
    workspace = Workspace(temporary)..ensureLayout();
    domainId = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Product').id;
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  File writeSource(String name, String content) =>
      File('${temporary.path}/$name')..writeAsStringSync(content);

  test('an attached file becomes canonical Reference data', () {
    final source = writeSource(
      'handoff.md',
      '# 전달사항\n목록 검색은 연결 항목 필드까지 매칭해야 한다.\n',
    );
    final service = ReferenceAttachmentService(workspace);

    final reference = service.attach(
      file: source,
      title: '검색 전달사항',
      domainId: domainId,
    );

    expect(reference.data['reference_type'], 'attached_document');
    expect(reference.data['source_filename'], 'handoff.md');
    expect((reference.data['locator'] as Map)['kind'], 'embedded_document');
    expect((reference.data['scope'] as Map)['domain_id'], domainId);
    expect(service.read(reference.id), contains('연결 항목 필드까지 매칭'));

    // The content is in the canonical tree, so any clone reads the same bytes.
    final canonicalFile = File(
      '${workspace.references.path}/${reference.id}.md',
    );
    expect(canonicalFile.existsSync(), isTrue);
    expect(canonicalFile.readAsStringSync(), contains('연결 항목 필드까지 매칭'));

    // Deleting the original leaves the canonical copy intact.
    source.deleteSync();
    expect(service.read(reference.id), contains('연결 항목 필드까지 매칭'));
  });

  test('an attachment scoped to a Task reaches that Task context pack', () {
    final task = TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-attachment',
        domainId: domainId,
        title: 'List search',
        status: TaskStatus.writing,
        promptDraft: 'Draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
      ),
    );
    final reference = ReferenceAttachmentService(workspace).attach(
      file: writeSource('spec.md', '검색 대상 필드 목록: 식별번호, 기관명, 당사자명'),
      title: '검색 필드 명세',
      domainId: domainId,
      taskId: task.id,
    );

    final pack = ContextPackBuilder(workspace).build(task.id);

    final entry = pack.entries.where((item) => item.id == reference.id);
    expect(entry, hasLength(1));
    expect(entry.single.content, contains('식별번호, 기관명, 당사자명'));
  });

  test('non-text and oversized attachments are rejected', () {
    final service = ReferenceAttachmentService(workspace);

    final binary = File('${temporary.path}/image.bin')
      ..writeAsBytesSync(Uint8List.fromList([0x00, 0xff, 0xfe, 0x00]));
    expect(
      () => service.attach(file: binary, title: 'binary'),
      throwsStateError,
    );

    final oversized = writeSource(
      'huge.md',
      'x' * (ReferenceAttachmentService.maxContentBytes + 1),
    );
    expect(
      () => service.attach(file: oversized, title: 'huge'),
      throwsStateError,
    );

    expect(
      () => service.attach(
        file: File('${temporary.path}/missing.md'),
        title: 'missing',
      ),
      throwsStateError,
    );
  });
}
