import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/notification_service.dart';
import 'package:under_claw_work/core/workspace.dart';

void main() {
  late Directory root;
  late Workspace workspace;

  setUp(() {
    root = Directory.systemTemp.createTempSync('notification-service-');
    workspace = Workspace(root)..ensureLayout();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('registry stores notification credentials only in local state', () {
    final source = File(p.join(root.path, 'channels.json'))
      ..writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'channels': [
            {
              'id': 'discord',
              'kind': 'hermes_webhook',
              'endpoint': 'http://127.0.0.1:8644/hooks/meta-ready',
              'secret': 'local-secret',
            },
          ],
        }),
      );

    final registry = NotificationChannelRegistry(workspace);
    registry.registerFrom(source);

    expect(registry.file.path, startsWith(workspace.local.path));
    expect(registry.file.existsSync(), isTrue);
    expect(registry.list().single.id, 'discord');
    if (!Platform.isWindows) {
      expect(workspace.local.statSync().mode & 0x1ff, 0x1c0);
      expect(registry.file.statSync().mode & 0x1ff, 0x180);
      expect(
        workspace.local.listSync().whereType<File>().where(
          (entry) => p.basename(entry.path).contains('.tmp-'),
        ),
        isEmpty,
      );
    }
  });

  test('Hermes webhook delivery is HMAC signed', () async {
    _writeConfig(workspace, [
      {
        'id': 'discord',
        'kind': 'hermes_webhook',
        'endpoint': 'http://127.0.0.1:8644/hooks/meta-ready',
        'secret': 'signing-secret',
      },
    ]);
    late http.Request captured;
    late String body;
    final client = MockClient((request) async {
      captured = request;
      body = request.body;
      return http.Response('', 200);
    });
    final notifier = HttpMetaReadyNotifier(
      NotificationChannelRegistry(workspace),
      client: client,
    );

    final report = await notifier.notifyMetaReady(_notification());

    final expected = Hmac(
      sha256,
      utf8.encode('signing-secret'),
    ).convert(utf8.encode(body));
    expect(report.delivered, 1);
    expect(report.failed, 0);
    expect(captured.headers['x-hub-signature-256'], 'sha256=$expected');
    expect(captured.headers['x-webhook-event'], 'meta_prompt.ready');
    expect(jsonDecode(body)['task_id'], 'TSK-notify');
  });

  test('rejects duplicate FCM registrations for one environment', () {
    expect(
      () => _writeConfig(workspace, [
        {
          'id': 'fcm',
          'kind': 'fcm',
          'endpoint':
              'https://fcm.googleapis.com/v1/projects/demo/messages:send',
          'access_token_command': ['/usr/bin/fake-token'],
          'tokens': [
            {'environment_id': 'ENV-astro', 'token': 'token-one'},
            {'environment_id': 'ENV-astro', 'token': 'token-two'},
          ],
        },
      ]),
      throwsFormatException,
    );
  });

  test('FCM sends one HTTP v1 message per environment token', () async {
    _writeConfig(workspace, [
      {
        'id': 'fcm',
        'kind': 'fcm',
        'endpoint': 'https://fcm.googleapis.com/v1/projects/demo/messages:send',
        'access_token_command': ['/usr/bin/fake-token'],
        'tokens': [
          {'environment_id': 'ENV-mac', 'token': 'token-mac'},
          {'environment_id': 'ENV-astro', 'token': 'token-astro'},
        ],
      },
    ]);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('', 200);
    });
    final notifier = HttpMetaReadyNotifier(
      NotificationChannelRegistry(workspace),
      client: client,
      accessTokenRunner: (command) async {
        expect(command, ['/usr/bin/fake-token']);
        return 'oauth-access-token';
      },
    );

    final report = await notifier.notifyMetaReady(_notification());

    expect(report.delivered, 2);
    expect(report.failed, 0);
    expect(requests, hasLength(2));
    expect(
      requests.every(
        (r) => r.headers['authorization'] == 'Bearer oauth-access-token',
      ),
      isTrue,
    );
    final tokens = requests
        .map((r) => (jsonDecode(r.body)['message']['token'] as String))
        .toSet();
    expect(tokens, {'token-mac', 'token-astro'});
  });

  test(
    'delivery failures are counted without exposing channel secrets',
    () async {
      _writeConfig(workspace, [
        {
          'id': 'discord',
          'kind': 'hermes_webhook',
          'endpoint': 'http://127.0.0.1:8644/hooks/meta-ready',
          'secret': 'do-not-leak',
        },
      ]);
      final notifier = HttpMetaReadyNotifier(
        NotificationChannelRegistry(workspace),
        client: MockClient(
          (request) async => http.Response('secret body', 503),
        ),
      );

      final report = await notifier.notifyMetaReady(_notification());

      expect(report.delivered, 0);
      expect(report.failed, 1);
    },
  );

  test('failed deliveries persist locally and retry later', () async {
    final notifier = QueuedMetaReadyNotifier(workspace, _FlakyNotifier());

    final first = await notifier.notifyMetaReady(_notification());
    expect(first.failed, 1);
    expect(notifier.pendingCount, 1);

    final retried = await notifier.retryPending();
    expect(retried.delivered, 1);
    expect(retried.failed, 0);
    expect(notifier.pendingCount, 0);
  });

  test('records intent before a delivery exception', () async {
    final notifier = QueuedMetaReadyNotifier(workspace, _ThrowingNotifier());

    await expectLater(
      notifier.notifyMetaReady(_notification()),
      throwsStateError,
    );

    expect(notifier.pendingCount, 1);
  });

  test('partial FCM retry targets only failed registrations', () async {
    _writeConfig(workspace, [
      {
        'id': 'fcm',
        'kind': 'fcm',
        'endpoint': 'https://fcm.googleapis.com/v1/projects/demo/messages:send',
        'access_token_command': ['/usr/bin/fake-token'],
        'tokens': [
          {'environment_id': 'ENV-mac', 'token': 'token-mac'},
          {'environment_id': 'ENV-astro', 'token': 'token-astro'},
        ],
      },
    ]);
    var retrying = false;
    final tokens = <String>[];
    final client = MockClient((request) async {
      final token = jsonDecode(request.body)['message']['token'] as String;
      tokens.add(token);
      if (!retrying && token == 'token-astro') return http.Response('', 503);
      return http.Response('', 200);
    });
    final notifier = QueuedMetaReadyNotifier(
      workspace,
      HttpMetaReadyNotifier(
        NotificationChannelRegistry(workspace),
        client: client,
        accessTokenRunner: (_) async => 'oauth-access-token',
      ),
    );

    final first = await notifier.notifyMetaReady(_notification());
    expect(first.failedTargets, ['channel:fcm:environment:ENV-astro']);
    expect(notifier.pendingCount, 1);
    retrying = true;
    final retried = await notifier.retryPending();

    expect(retried.failed, 0);
    expect(tokens, ['token-mac', 'token-astro', 'token-astro']);
    expect(notifier.pendingCount, 0);
  });

  test(
    'concurrent retries serialize and deliver an outbox item once',
    () async {
      final initial = QueuedMetaReadyNotifier(workspace, _AlwaysFailNotifier());
      await initial.notifyMetaReady(_notification());
      final delegate = _DelayedNotifier();
      final notifier = QueuedMetaReadyNotifier(workspace, delegate);

      await Future.wait([notifier.retryPending(), notifier.retryPending()]);

      expect(delegate.calls, 1);
      expect(notifier.pendingCount, 0);
    },
  );
}

void _writeConfig(Workspace workspace, List<Map<String, Object?>> channels) {
  final source = File(
    p.join(workspace.root.path, 'notification-input.json'),
  )..writeAsStringSync(jsonEncode({'schema_version': 1, 'channels': channels}));
  NotificationChannelRegistry(workspace).registerFrom(source);
}

MetaReadyNotification _notification() => const MetaReadyNotification(
  taskId: 'TSK-notify',
  title: 'Notification task',
  sourceRevision: 2,
  environmentId: 'ENV-astro',
  adapterId: 'hermes-meta',
);

class _ThrowingNotifier implements MetaReadyNotifier {
  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async => throw StateError('delivery crashed');
}

class _FlakyNotifier implements MetaReadyNotifier {
  var calls = 0;

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async {
    calls++;
    return NotificationDeliveryReport(
      delivered: calls == 1 ? 0 : 1,
      failed: calls == 1 ? 1 : 0,
    );
  }
}

class _AlwaysFailNotifier implements MetaReadyNotifier {
  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async => const NotificationDeliveryReport(delivered: 0, failed: 1);
}

class _DelayedNotifier implements MetaReadyNotifier {
  var calls = 0;

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return const NotificationDeliveryReport(delivered: 1, failed: 0);
  }
}
