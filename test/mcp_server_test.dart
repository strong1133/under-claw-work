import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EntityService entities;
  late CanonicalRepository repository;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-mcp-');
    workspace = Workspace(temporary)..ensureLayout();
    entities = EntityService(workspace);
    repository = CanonicalRepository(workspace);
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('read-only MCP handler fixes every request to its configured scope', () {
    final allowedDomain = entities.create(
      kind: EntityKind.domain,
      title: 'AI-WorkSpace',
    );
    final otherDomain = entities.create(
      kind: EntityKind.domain,
      title: 'Company',
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Allowed fact',
      body: 'Visible AI workspace knowledge.',
      domainId: allowedDomain.id,
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Other fact',
      body: 'Must not cross the scope boundary.',
      domainId: otherDomain.id,
    );
    final restricted = entities.create(
      kind: EntityKind.knowledge,
      title: 'Restricted fact',
      body: 'Must not be exposed without authorization.',
      domainId: allowedDomain.id,
    );
    repository.update(
      CanonicalEntity(
        kind: restricted.kind,
        id: restricted.id,
        data: {...restricted.data, 'visibility': 'restricted'},
        body: restricted.body,
      ),
    );

    final handler = UnderClawMcpHandler(workspace, domainId: allowedDomain.id);
    final initialized = handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-03-26',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'test', 'version': '1'},
      },
    });
    expect(initialized?['result'], isA<Map>());
    expect((initialized?['result'] as Map)['protocolVersion'], '2025-03-26');

    final legacyInitialized = handler.handle({
      'jsonrpc': '2.0',
      'id': 10,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'legacy-test', 'version': '1'},
      },
    });
    expect(
      (legacyInitialized?['result'] as Map)['protocolVersion'],
      '2024-11-05',
    );

    final listed = handler.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = ((listed?['result'] as Map)['tools'] as List)
        .whereType<Map>()
        .map((item) => item['name']);
    expect(
      tools,
      containsAll(['underclaw_recall', 'underclaw_resolve_context']),
    );

    final recalled = handler.handle({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'underclaw_recall', 'arguments': <String, Object?>{}},
    });
    final text =
        ((((recalled?['result'] as Map)['content'] as List).single
                as Map)['text'])
            .toString();
    expect(text, contains('Allowed fact'));
    expect(text, isNot(contains('Other fact')));
    expect(text, isNot(contains('Restricted fact')));
  });

  test('milestone-fixed MCP recall excludes sibling Milestone knowledge', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final allowedMilestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Allowed',
      domainId: domain.id,
    );
    final siblingMilestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Sibling',
      domainId: domain.id,
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Allowed milestone fact',
      body: 'ALLOWED-MILESTONE-BODY',
      domainId: domain.id,
      milestoneId: allowedMilestone.id,
    );
    entities.create(
      kind: EntityKind.knowledge,
      title: 'Sibling milestone secret',
      body: 'SIBLING-MILESTONE-SECRET',
      domainId: domain.id,
      milestoneId: siblingMilestone.id,
    );

    final handler = UnderClawMcpHandler(
      workspace,
      domainId: domain.id,
      milestoneId: allowedMilestone.id,
    );
    final recalled = handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'underclaw_recall', 'arguments': <String, Object?>{}},
    });
    final text =
        ((((recalled?['result'] as Map)['content'] as List).single
                as Map)['text'])
            .toString();

    expect(text, contains('ALLOWED-MILESTONE-BODY'));
    expect(text, isNot(contains('SIBLING-MILESTONE-SECRET')));
  });

  test('MCP handler exposes no mutation tools', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);
    final listed = handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
    });
    final names = ((listed?['result'] as Map)['tools'] as List)
        .whereType<Map>()
        .map((item) => item['name'].toString());
    expect(names, everyElement(isNot(contains('create'))));
    expect(names, everyElement(isNot(contains('update'))));
    expect(names, everyElement(isNot(contains('delete'))));
  });

  test('milestone-fixed MCP lists only its configured milestone', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final allowed = entities.create(
      kind: EntityKind.milestone,
      title: 'Allowed',
      domainId: domain.id,
    );
    final sibling = entities.create(
      kind: EntityKind.milestone,
      title: 'Sibling',
      domainId: domain.id,
    );
    final handler = UnderClawMcpHandler(
      workspace,
      domainId: domain.id,
      milestoneId: allowed.id,
    );

    final response = handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'underclaw_list_milestones',
        'arguments': <String, Object?>{},
      },
    });
    final text =
        ((((response?['result'] as Map)['content'] as List).single
                as Map)['text'])
            .toString();
    expect(text, contains(allowed.id));
    expect(text, isNot(contains(sibling.id)));
  });

  test('MCP rejects archived Domain and Milestone anchors', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'archived'},
        body: milestone.body,
      ),
    );
    expect(
      () => UnderClawMcpHandler(
        workspace,
        domainId: domain.id,
        milestoneId: milestone.id,
      ),
      throwsStateError,
    );

    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'active'},
        body: milestone.body,
      ),
    );
    repository.update(
      CanonicalEntity(
        kind: domain.kind,
        id: domain.id,
        data: {...domain.data, 'status': 'archived'},
        body: domain.body,
      ),
    );
    expect(
      () => UnderClawMcpHandler(
        workspace,
        domainId: domain.id,
        milestoneId: milestone.id,
      ),
      throwsStateError,
    );
  });

  test('long-running MCP revokes access when its scope is archived', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    final handler = UnderClawMcpHandler(
      workspace,
      domainId: domain.id,
      milestoneId: milestone.id,
    );
    repository.update(
      CanonicalEntity(
        kind: milestone.kind,
        id: milestone.id,
        data: {...milestone.data, 'status': 'archived'},
        body: milestone.body,
      ),
    );

    final response = handler.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': 'underclaw_recall', 'arguments': <String, Object?>{}},
    });

    expect((response?['error'] as Map)['code'], -32603);
    expect(response?['result'], isNull);
  });

  test('JSON-RPC notifications never receive a response', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    expect(handler.handle({'jsonrpc': '2.0', 'method': 'ping'}), isNull);
  });

  test('MCP rejects requests with the wrong JSON-RPC version', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    final response = handler.handle({
      'jsonrpc': '1.0',
      'id': 1,
      'method': 'ping',
    });
    expect(response?['result'], isNull);
    expect((response?['error'] as Map)['code'], -32600);
  });

  test('Tasks reject context relations outside their fixed scope', () {
    final domainA = entities.create(kind: EntityKind.domain, title: 'A');
    final milestoneA = entities.create(
      kind: EntityKind.milestone,
      title: 'A1',
      domainId: domainA.id,
    );
    final domainB = entities.create(kind: EntityKind.domain, title: 'B');
    final knowledgeB = entities.create(
      kind: EntityKind.knowledge,
      title: 'B only',
      body: 'Must not cross scope.',
      domainId: domainB.id,
    );

    expect(
      () => TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-cross-scope',
          domainId: domainA.id,
          milestoneId: milestoneA.id,
          title: 'Cross scope',
          status: TaskStatus.draft,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-test',
          evidenceKnowledgeIds: [knowledgeB.id],
        ),
      ),
      throwsFormatException,
    );
  });

  test('MCP reports unknown JSON-RPC methods with method-not-found', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    final response = handler.handle({
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'unknown/method',
    });

    expect((response?['error'] as Map)['code'], -32601);
  });

  test('MCP rejects non-object tool arguments as invalid params', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    final response = handler.handle({
      'jsonrpc': '2.0',
      'id': 8,
      'method': 'tools/call',
      'params': {'name': 'underclaw_recall', 'arguments': 'not-an-object'},
    });

    expect(response?['result'], isNull);
    expect((response?['error'] as Map)['code'], -32602);
  });

  test('MCP stdio transport reports malformed JSON as parse error', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final server = UnderClawMcpServer(
      UnderClawMcpHandler(workspace, domainId: domain.id),
    );

    final response = server.handleLine('{not-json');

    expect(response?['id'], isNull);
    expect((response?['error'] as Map)['code'], -32700);
  });

  test('Task ids cannot escape the canonical task directory', () {
    expect(
      () => TaskRepository(workspace).create(
        const WorkTask(
          id: 'TSK-../../escape',
          domainId: 'DOM-test',
          milestoneId: 'MLS-test',
          title: 'Escape',
          status: TaskStatus.draft,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-test',
        ),
      ),
      throwsFormatException,
    );
    expect(File('${temporary.path}/escape/task.yaml').existsSync(), isFalse);
  });

  test('MCP validates task context token budget types', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'M1',
      domainId: domain.id,
    );
    TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-budget',
        domainId: domain.id,
        milestoneId: milestone.id,
        title: 'Budget',
        status: TaskStatus.draft,
        promptDraft: 'Draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-test',
      ),
    );
    final response =
        UnderClawMcpHandler(
          workspace,
          domainId: domain.id,
          milestoneId: milestone.id,
        ).handle({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/call',
          'params': {
            'name': 'underclaw_build_task_context',
            'arguments': {'task_id': 'TSK-budget', 'token_budget': 'many'},
          },
        });

    expect((response?['error'] as Map)['code'], -32602);

    final oversized =
        UnderClawMcpHandler(
          workspace,
          domainId: domain.id,
          milestoneId: milestone.id,
        ).handle({
          'jsonrpc': '2.0',
          'id': 10,
          'method': 'tools/call',
          'params': {
            'name': 'underclaw_build_task_context',
            'arguments': {'task_id': 'TSK-budget', 'token_budget': 65537},
          },
        });
    expect(oversized?['result'], isNull);
    expect((oversized?['error'] as Map)['code'], -32602);
  });

  test(
    'MCP task context never expands relations into restricted Knowledge',
    () {
      final domain = entities.create(kind: EntityKind.domain, title: 'AI');
      final milestone = entities.create(
        kind: EntityKind.milestone,
        title: 'M1',
        domainId: domain.id,
      );
      final restricted = entities.create(
        kind: EntityKind.knowledge,
        title: 'Restricted target',
        body: 'SECRET-RELATION-BODY',
        domainId: domain.id,
        milestoneId: milestone.id,
        extra: {'visibility': 'restricted'},
      );
      final visible = entities.create(
        kind: EntityKind.knowledge,
        title: 'Visible seed',
        body: 'Visible context.',
        domainId: domain.id,
        milestoneId: milestone.id,
        extra: {
          'relations': {
            'supports': [restricted.id],
          },
        },
      );
      TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-restricted-relation',
          domainId: domain.id,
          milestoneId: milestone.id,
          title: 'Restricted relation',
          status: TaskStatus.draft,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-test',
          evidenceKnowledgeIds: [visible.id],
        ),
      );

      final response =
          UnderClawMcpHandler(
            workspace,
            domainId: domain.id,
            milestoneId: milestone.id,
          ).handle({
            'jsonrpc': '2.0',
            'id': 10,
            'method': 'tools/call',
            'params': {
              'name': 'underclaw_build_task_context',
              'arguments': {'task_id': 'TSK-restricted-relation'},
            },
          });
      final text =
          (((response?['result'] as Map)['content'] as List).single
                  as Map)['text']
              .toString();

      expect(text, contains('Visible seed'));
      expect(text, isNot(contains('Restricted target')));
      expect(text, isNot(contains('SECRET-RELATION-BODY')));
    },
  );

  test('canonical Knowledge relations cannot cross Domain scope', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'AI');
    final otherDomain = entities.create(
      kind: EntityKind.domain,
      title: 'Other',
    );
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'M1',
      domainId: domain.id,
    );
    final crossScope = entities.create(
      kind: EntityKind.knowledge,
      title: 'Cross-scope target',
      body: 'CROSS-SCOPE-RELATION-BODY',
      domainId: otherDomain.id,
    );
    for (final relation in ['supports', 'supersedes']) {
      expect(
        () => entities.create(
          kind: EntityKind.knowledge,
          title: 'Visible seed',
          body: 'Visible context.',
          domainId: domain.id,
          milestoneId: milestone.id,
          extra: {
            'relations': {
              relation: [crossScope.id],
            },
          },
        ),
        throwsFormatException,
        reason: relation,
      );
    }

    final pluralOnlyTarget = entities.create(
      kind: EntityKind.knowledge,
      title: 'Plural-only cross-scope target',
      body: 'PLURAL-CROSS-SCOPE-BODY',
      extra: {
        'scope': {
          'domain_ids': [otherDomain.id],
        },
      },
    );
    expect(
      () => entities.create(
        kind: EntityKind.knowledge,
        title: 'Plural relation source',
        body: 'Visible context.',
        domainId: domain.id,
        milestoneId: milestone.id,
        extra: {
          'relations': {
            'supports': [pluralOnlyTarget.id],
          },
        },
      ),
      throwsFormatException,
    );

    expect(
      () => TaskRepository(workspace).create(
        WorkTask(
          id: 'TSK-plural-scope',
          domainId: domain.id,
          milestoneId: milestone.id,
          title: 'Plural scope regression',
          status: TaskStatus.draft,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-test',
          evidenceKnowledgeIds: [pluralOnlyTarget.id],
        ),
      ),
      throwsFormatException,
    );

    final relationTask = TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-plural-relation',
        domainId: domain.id,
        milestoneId: milestone.id,
        title: 'Plural relation regression',
        status: TaskStatus.draft,
        promptDraft: 'Draft',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: 'ENV-test',
      ),
    );
    File(workspace.taskRelations(relationTask.id).path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        'knowledge_ids:\n  - ${pluralOnlyTarget.id}\n',
        flush: true,
      );
    expect(RelationRegistry(workspace).validateGraph, throwsFormatException);

    final response =
        UnderClawMcpHandler(
          workspace,
          domainId: domain.id,
          milestoneId: milestone.id,
        ).handle({
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'tools/call',
          'params': {
            'name': 'underclaw_build_task_context',
            'arguments': {'task_id': relationTask.id},
          },
        });
    final text =
        (((response?['result'] as Map)['content'] as List).single
                as Map)['text']
            .toString();
    expect(text, isNot(contains('PLURAL-CROSS-SCOPE-BODY')));
  });

  test('MCP distinguishes notifications from explicit null request ids', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    expect(
      handler.handle({'jsonrpc': '1.0', 'method': 'ping'})?['error'],
      containsPair('code', -32600),
    );
    expect(
      handler.handle({
        'jsonrpc': '2.0',
        'id': null,
        'method': 'ping',
      })?['error'],
      containsPair('code', -32600),
    );
    expect(handler.handle({'jsonrpc': '2.0', 'method': 'ping'}), isNull);
  });

  test('MCP rejects primitive params for every method', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final handler = UnderClawMcpHandler(workspace, domainId: domain.id);

    for (final method in ['initialize', 'ping', 'tools/list']) {
      final response = handler.handle({
        'jsonrpc': '2.0',
        'id': method,
        'method': method,
        'params': 'invalid',
      });
      expect(response?['error'], containsPair('code', -32602), reason: method);
    }
  });

  test('MCP recall never broadens task-scoped Knowledge', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final milestone = entities.create(
      kind: EntityKind.milestone,
      title: 'Milestone',
      domainId: domain.id,
    );
    for (final id in ['TSK-private', 'TSK-sibling']) {
      TaskRepository(workspace).create(
        WorkTask(
          id: id,
          domainId: domain.id,
          milestoneId: milestone.id,
          title: id,
          status: TaskStatus.draft,
          promptDraft: 'Draft',
          promptMeta: '',
          promptDraftRevision: 1,
          promptMetaSourceRevision: 0,
          approval: PromptApproval.missing,
          autoDeriveTasks: false,
          targetEnvironment: 'ENV-test',
        ),
      );
    }
    final scoped = entities.create(
      kind: EntityKind.knowledge,
      title: 'Private task fact',
      body: 'PRIVATE-TASK-BODY',
      domainId: domain.id,
      milestoneId: milestone.id,
      taskId: 'TSK-private',
    );
    expect(scoped.data['scope'], containsPair('task_ids', ['TSK-private']));

    for (final handler in [
      UnderClawMcpHandler(workspace, domainId: domain.id),
      UnderClawMcpHandler(
        workspace,
        domainId: domain.id,
        milestoneId: milestone.id,
      ),
    ]) {
      final response = handler.handle({
        'jsonrpc': '2.0',
        'id': 11,
        'method': 'tools/call',
        'params': {
          'name': 'underclaw_recall',
          'arguments': <String, Object?>{},
        },
      });
      final text =
          (((response?['result'] as Map)['content'] as List).single
                  as Map)['text']
              .toString();
      expect(text, isNot(contains('PRIVATE-TASK-BODY')));
    }
  });

  test('MCP recall excludes archived Knowledge', () {
    final domain = entities.create(kind: EntityKind.domain, title: 'Domain');
    final archived = entities.create(
      kind: EntityKind.knowledge,
      title: 'Archived fact',
      body: 'ARCHIVED-KNOWLEDGE-BODY',
      domainId: domain.id,
    );
    repository.update(
      CanonicalEntity(
        kind: archived.kind,
        id: archived.id,
        data: {...archived.data, 'status': 'archived'},
        body: archived.body,
      ),
    );

    final response = UnderClawMcpHandler(workspace, domainId: domain.id).handle(
      {
        'jsonrpc': '2.0',
        'id': 12,
        'method': 'tools/call',
        'params': {
          'name': 'underclaw_recall',
          'arguments': <String, Object?>{},
        },
      },
    );
    final text =
        (((response?['result'] as Map)['content'] as List).single
                as Map)['text']
            .toString();
    expect(text, isNot(contains('ARCHIVED-KNOWLEDGE-BODY')));
  });
}
