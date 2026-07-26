import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late LocalWebSession session;
  late HttpClient client;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('under-claw-serve-');
    workspace = Workspace(temporary)..ensureLayout();
    final domain = EntityService(
      workspace,
    ).create(kind: EntityKind.domain, title: 'Product');
    TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-served',
        domainId: domain.id,
        title: 'List search',
        status: TaskStatus.metaRequested,
        promptDraft: '검색 대상 필드를 확장한다',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
      ),
    );
    session = await LocalWebServer(workspace).start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await session.close();
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> send(
    String path, {
    String? token,
    String method = 'GET',
    String host = '127.0.0.1',
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${session.port}$path'),
    );
    request.headers.set(HttpHeaders.hostHeader, host);
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request.close();
  }

  test('binds the loopback interface only', () {
    expect(session.address.address, '127.0.0.1');
    expect(session.address.isLoopback, isTrue);
    expect(session.url.host, '127.0.0.1');
  });

  test('rejects a request without the launch token', () async {
    final response = await send('/api/tasks');

    expect(response.statusCode, HttpStatus.unauthorized);
    await response.drain<void>();
  });

  test('rejects a wrong token of the same length', () async {
    final wrong = 'x' * session.token.length;

    final response = await send('/api/tasks', token: wrong);

    expect(response.statusCode, HttpStatus.unauthorized);
    await response.drain<void>();
  });

  test('rejects a non-loopback Host header', () async {
    // A DNS rebinding attack reaches 127.0.0.1 while carrying its own hostname.
    final response = await send(
      '/api/tasks',
      token: session.token,
      host: 'attacker.example',
    );

    expect(response.statusCode, HttpStatus.forbidden);
    await response.drain<void>();
  });

  test('serves Tasks to a request carrying the token', () async {
    final response = await send('/api/tasks', token: session.token);

    expect(response.statusCode, HttpStatus.ok);
    final body =
        jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, Object?>;
    final tasks = body['tasks']! as List;
    expect(tasks, hasLength(1));
    expect((tasks.single as Map)['id'], 'TSK-served');
    expect((tasks.single as Map)['status'], 'metaRequested');
  });

  test('accepts the token from the launch URL query', () async {
    final response = await send('/api/tasks?token=${session.token}');

    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  test('serves the canonical prompt of one Task', () async {
    final response = await send('/api/tasks/TSK-served', token: session.token);

    final body =
        jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, Object?>;
    expect(body['prompt_draft'], contains('검색 대상 필드'));
    expect(body['domain_id'], startsWith('DOM-'));
  });

  test('refuses every write method', () async {
    for (final method in ['POST', 'PUT', 'DELETE', 'PATCH']) {
      final response = await send(
        '/api/tasks',
        token: session.token,
        method: method,
      );

      expect(
        response.statusCode,
        HttpStatus.methodNotAllowed,
        reason: '$method must not reach canonical data',
      );
      await response.drain<void>();
    }
  });

  test(
    'never sends a header that lets another origin read the response',
    () async {
      final response = await send('/api/tasks', token: session.token);

      expect(response.headers['access-control-allow-origin'], isNull);
      expect(response.headers.value('x-frame-options'), 'DENY');
      expect(response.headers.value('cache-control'), 'no-store');
      await response.drain<void>();
    },
  );

  test('each launch issues a different token', () async {
    final other = await LocalWebServer(workspace).start();
    addTearDown(other.close);

    expect(other.token, isNot(session.token));
    expect(session.token.length, greaterThanOrEqualTo(32));
  });
}
