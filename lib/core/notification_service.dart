import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'workspace.dart';

class MetaReadyNotification {
  const MetaReadyNotification({
    required this.taskId,
    required this.title,
    required this.sourceRevision,
    this.sourceSha256 = '',
    required this.environmentId,
    required this.adapterId,
    this.pendingTargets = const [],
  });

  final String taskId;
  final String title;
  final int sourceRevision;
  final String sourceSha256;
  final String environmentId;
  final String adapterId;
  final List<String> pendingTargets;

  String get idempotencyKey =>
      '$taskId:$sourceRevision:${sourceSha256.isEmpty ? 'legacy' : sourceSha256}:$adapterId';

  factory MetaReadyNotification.fromJson(Map<String, Object?> json) =>
      MetaReadyNotification(
        taskId: json['task_id'] as String,
        title: json['title'] as String,
        sourceRevision: json['source_revision'] as int,
        sourceSha256: json['source_sha256'] as String? ?? '',
        environmentId: json['environment_id'] as String,
        adapterId: json['adapter_id'] as String,
        pendingTargets: (json['pending_targets'] as List<Object?>? ?? const [])
            .map((value) => value as String)
            .toList(growable: false),
      );

  MetaReadyNotification withPendingTargets(List<String> targets) =>
      MetaReadyNotification(
        taskId: taskId,
        title: title,
        sourceRevision: sourceRevision,
        sourceSha256: sourceSha256,
        environmentId: environmentId,
        adapterId: adapterId,
        pendingTargets: List.unmodifiable(targets),
      );

  Map<String, Object?> toJson() => {
    'event': 'meta_prompt.ready',
    'task_id': taskId,
    'title': title,
    'source_revision': sourceRevision,
    'source_sha256': sourceSha256,
    'environment_id': environmentId,
    'adapter_id': adapterId,
    'idempotency_key': idempotencyKey,
    if (pendingTargets.isNotEmpty) 'pending_targets': pendingTargets,
  };
}

class NotificationDeliveryReport {
  const NotificationDeliveryReport({
    required this.delivered,
    required this.failed,
    this.failedTargets = const [],
  });

  final int delivered;
  final int failed;
  final List<String> failedTargets;
}

abstract interface class MetaReadyNotifier {
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  );
}

class NoopMetaReadyNotifier implements MetaReadyNotifier {
  const NoopMetaReadyNotifier();

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async => const NotificationDeliveryReport(delivered: 0, failed: 0);
}

enum NotificationChannelKind { fcm, hermesWebhook }

class FcmRegistration {
  const FcmRegistration({required this.environmentId, required this.token});

  final String environmentId;
  final String token;
}

class NotificationChannelDescriptor {
  const NotificationChannelDescriptor({
    required this.id,
    required this.kind,
    required this.endpoint,
    this.secret,
    this.accessTokenCommand = const [],
    this.tokens = const [],
  });

  final String id;
  final NotificationChannelKind kind;
  final Uri endpoint;
  final String? secret;
  final List<String> accessTokenCommand;
  final List<FcmRegistration> tokens;

  factory NotificationChannelDescriptor.fromJson(Map<String, Object?> json) {
    final id = json['id'] as String? ?? '';
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id)) {
      throw const FormatException('Notification channel id is invalid.');
    }
    final rawKind = json['kind'] as String?;
    final kind = switch (rawKind) {
      'fcm' => NotificationChannelKind.fcm,
      'hermes_webhook' => NotificationChannelKind.hermesWebhook,
      _ => throw const FormatException('Notification channel kind is invalid.'),
    };
    final endpoint = Uri.tryParse(json['endpoint'] as String? ?? '');
    if (endpoint == null || endpoint.host.isEmpty) {
      throw const FormatException('Notification endpoint is invalid.');
    }
    if (kind == NotificationChannelKind.fcm) {
      if (endpoint.scheme != 'https' || endpoint.host != 'fcm.googleapis.com') {
        throw const FormatException(
          'FCM endpoint must use fcm.googleapis.com HTTPS.',
        );
      }
      final command =
          (json['access_token_command'] as List<Object?>? ?? const [])
              .map((value) => value as String)
              .toList(growable: false);
      if (command.isEmpty || !p.isAbsolute(command.first)) {
        throw const FormatException(
          'FCM access token command must be absolute.',
        );
      }
      final rawTokens = json['tokens'] as List<Object?>? ?? const [];
      final tokens = rawTokens
          .map((value) {
            final item = Map<String, Object?>.from(value as Map);
            final environmentId = item['environment_id'] as String? ?? '';
            final token = item['token'] as String? ?? '';
            if (!RegExp(r'^ENV-[A-Za-z0-9._-]+$').hasMatch(environmentId) ||
                token.trim().isEmpty) {
              throw const FormatException('FCM registration is invalid.');
            }
            return FcmRegistration(environmentId: environmentId, token: token);
          })
          .toList(growable: false);
      if (tokens.isEmpty) {
        throw const FormatException('At least one FCM token is required.');
      }
      if (tokens.map((token) => token.environmentId).toSet().length !=
          tokens.length) {
        throw const FormatException(
          'FCM environment registrations must be unique per channel.',
        );
      }
      return NotificationChannelDescriptor(
        id: id,
        kind: kind,
        endpoint: endpoint,
        accessTokenCommand: command,
        tokens: tokens,
      );
    }
    final isLoopback =
        endpoint.host == '127.0.0.1' ||
        endpoint.host == 'localhost' ||
        endpoint.host == '::1';
    if (endpoint.scheme != 'https' &&
        !(endpoint.scheme == 'http' && isLoopback)) {
      throw const FormatException(
        'Hermes webhook must use HTTPS or a loopback HTTP endpoint.',
      );
    }
    final secret = json['secret'] as String? ?? '';
    if (secret.trim().isEmpty) {
      throw const FormatException('Hermes webhook secret is required.');
    }
    return NotificationChannelDescriptor(
      id: id,
      kind: kind,
      endpoint: endpoint,
      secret: secret,
    );
  }
}

class NotificationChannelRegistry {
  NotificationChannelRegistry(this.workspace);

  final Workspace workspace;

  File get file =>
      File(p.join(workspace.local.path, 'notification-channels.json'));

  void registerFrom(File source) {
    final decoded = jsonDecode(source.readAsStringSync()) as Map;
    final json = Map<String, Object?>.from(decoded);
    if (json['schema_version'] != 1) {
      throw const FormatException('Unsupported notification schema version.');
    }
    final channels = json['channels'] as List<Object?>? ?? const [];
    final parsed = channels
        .map(
          (value) => NotificationChannelDescriptor.fromJson(
            Map<String, Object?>.from(value as Map),
          ),
        )
        .toList(growable: false);
    final ids = parsed.map((channel) => channel.id).toSet();
    if (ids.length != parsed.length) {
      throw const FormatException('Notification channel ids must be unique.');
    }
    workspace.local.createSync(recursive: true);
    if (!Platform.isWindows) {
      final directoryMode = Process.runSync('chmod', [
        '700',
        workspace.local.path,
      ]);
      if (directoryMode.exitCode != 0) {
        throw FileSystemException(
          'Could not secure local notification directory.',
          workspace.local.path,
        );
      }
    }
    final temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    temporary.createSync(exclusive: true);
    if (!Platform.isWindows) {
      final result = Process.runSync('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        temporary.deleteSync();
        throw FileSystemException(
          'Could not secure notification registry.',
          temporary.path,
        );
      }
    }
    temporary.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }

  List<NotificationChannelDescriptor> list() {
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync()) as Map;
    final channels = decoded['channels'] as List<Object?>? ?? const [];
    return channels
        .map(
          (value) => NotificationChannelDescriptor.fromJson(
            Map<String, Object?>.from(value as Map),
          ),
        )
        .toList(growable: false);
  }
}

typedef AccessTokenRunner = Future<String> Function(List<String> command);

class HttpMetaReadyNotifier implements MetaReadyNotifier {
  HttpMetaReadyNotifier(
    this.registry, {
    http.Client? client,
    AccessTokenRunner? accessTokenRunner,
  }) : _client = client ?? http.Client(),
       _accessTokenRunner = accessTokenRunner ?? _runAccessTokenCommand;

  final NotificationChannelRegistry registry;
  final http.Client _client;
  final AccessTokenRunner _accessTokenRunner;

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) async {
    var delivered = 0;
    var failed = 0;
    final failedTargets = <String>[];
    bool wants(String target) =>
        notification.pendingTargets.isEmpty ||
        notification.pendingTargets.contains(target);
    for (final channel in registry.list()) {
      if (channel.kind == NotificationChannelKind.hermesWebhook) {
        final target = 'channel:${channel.id}';
        if (!wants(target)) continue;
        try {
          final body = jsonEncode(notification.toJson());
          final signature = Hmac(
            sha256,
            utf8.encode(channel.secret!),
          ).convert(utf8.encode(body));
          final response = await _client.post(
            channel.endpoint,
            headers: {
              HttpHeaders.contentTypeHeader: 'application/json',
              'x-hub-signature-256': 'sha256=$signature',
              'x-webhook-event': 'meta_prompt.ready',
            },
            body: body,
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            delivered++;
          } else {
            failed++;
            failedTargets.add(target);
          }
        } catch (_) {
          failed++;
          failedTargets.add(target);
        }
        continue;
      }
      final registrations = channel.tokens
          .where(
            (registration) => wants(
              'channel:${channel.id}:environment:${registration.environmentId}',
            ),
          )
          .toList(growable: false);
      if (registrations.isEmpty) continue;
      String accessToken;
      try {
        accessToken = await _accessTokenRunner(channel.accessTokenCommand);
        if (accessToken.trim().isEmpty) throw StateError('Empty access token.');
      } catch (_) {
        failed += registrations.length;
        failedTargets.addAll(
          registrations.map(
            (registration) =>
                'channel:${channel.id}:environment:${registration.environmentId}',
          ),
        );
        continue;
      }
      for (final registration in registrations) {
        final target =
            'channel:${channel.id}:environment:${registration.environmentId}';
        try {
          final data = notification.toJson().map(
            (key, value) => MapEntry(key, value.toString()),
          );
          data['target_environment_id'] = registration.environmentId;
          final response = await _client.post(
            channel.endpoint,
            headers: {
              HttpHeaders.contentTypeHeader: 'application/json',
              HttpHeaders.authorizationHeader: 'Bearer ${accessToken.trim()}',
            },
            body: jsonEncode({
              'message': {
                'token': registration.token,
                'notification': {
                  'title': 'Meta Prompt ready',
                  'body': '${notification.taskId}: ${notification.title}',
                },
                'data': data,
              },
            }),
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            delivered++;
          } else {
            failed++;
            failedTargets.add(target);
          }
        } catch (_) {
          failed++;
          failedTargets.add(target);
        }
      }
    }
    return NotificationDeliveryReport(
      delivered: delivered,
      failed: failed,
      failedTargets: failedTargets,
    );
  }

  static Future<String> _runAccessTokenCommand(List<String> command) async {
    final executable = File(command.first);
    if (!executable.existsSync()) {
      throw StateError('FCM access token command is unavailable.');
    }
    final result = await Process.run(
      executable.path,
      command.skip(1).toList(growable: false),
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError('FCM access token command failed.');
    }
    return result.stdout.toString().trim();
  }
}

class QueuedMetaReadyNotifier implements MetaReadyNotifier {
  QueuedMetaReadyNotifier(this.workspace, this.delegate);

  final Workspace workspace;
  final MetaReadyNotifier delegate;
  static final Map<String, Future<void>> _localTails = {};

  Directory get _outbox =>
      Directory(p.join(workspace.local.path, 'notification-outbox'));

  int get pendingCount => _pendingFiles().length;

  @override
  Future<NotificationDeliveryReport> notifyMetaReady(
    MetaReadyNotification notification,
  ) => _withLock(() async {
    final file = _fileFor(notification);
    // Persist intent before attempting delivery. A process crash can therefore
    // cause an at-least-once retry, but cannot silently lose the notification.
    _write(file, notification);
    final report = await delegate.notifyMetaReady(notification);
    if (report.failed > 0) {
      if (report.failedTargets.isNotEmpty) {
        _write(file, notification.withPendingTargets(report.failedTargets));
      }
    } else if (file.existsSync()) {
      file.deleteSync();
    }
    return report;
  });

  Future<NotificationDeliveryReport> retryPending() => _withLock(() async {
    var delivered = 0;
    var failed = 0;
    for (final file in _pendingFiles()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync()) as Map;
        final notification = MetaReadyNotification.fromJson(
          Map<String, Object?>.from(decoded),
        );
        final report = await delegate.notifyMetaReady(notification);
        delivered += report.delivered;
        failed += report.failed;
        if (report.failed == 0) {
          file.deleteSync();
        } else if (report.failedTargets.isNotEmpty) {
          _write(file, notification.withPendingTargets(report.failedTargets));
        }
      } catch (_) {
        failed++;
      }
    }
    return NotificationDeliveryReport(delivered: delivered, failed: failed);
  });

  Future<T> _withLock<T>(Future<T> Function() action) async {
    final key = p.normalize(workspace.local.absolute.path);
    final previous = _localTails[key] ?? Future<void>.value();
    final turn = Completer<void>();
    _localTails[key] = turn.future;
    await previous;
    RandomAccessFile? lock;
    var acquired = false;
    try {
      workspace.local.createSync(recursive: true);
      if (!Platform.isWindows) {
        final mode = Process.runSync('chmod', ['700', workspace.local.path]);
        if (mode.exitCode != 0) {
          throw FileSystemException(
            'Could not secure notification state directory.',
            workspace.local.path,
          );
        }
      }
      lock = File(
        p.join(workspace.local.path, 'notification-outbox.lock'),
      ).openSync(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      acquired = true;
      return await action();
    } finally {
      if (lock != null) {
        try {
          if (acquired) await lock.unlock();
        } finally {
          await lock.close();
        }
      }
      turn.complete();
      if (identical(_localTails[key], turn.future)) {
        _localTails.remove(key);
      }
    }
  }

  File _fileFor(MetaReadyNotification notification) {
    final digest = sha256.convert(utf8.encode(notification.idempotencyKey));
    return File(p.join(_outbox.path, '$digest.json'));
  }

  List<File> _pendingFiles() {
    if (!_outbox.existsSync()) return const [];
    final files = _outbox
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  void _write(File file, MetaReadyNotification notification) {
    _outbox.createSync(recursive: true);
    if (!Platform.isWindows) {
      final directoryMode = Process.runSync('chmod', ['700', _outbox.path]);
      if (directoryMode.exitCode != 0) {
        throw FileSystemException(
          'Could not secure notification outbox directory.',
          _outbox.path,
        );
      }
    }
    final temporary = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    temporary.createSync(exclusive: true);
    if (!Platform.isWindows) {
      final result = Process.runSync('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        temporary.deleteSync();
        throw FileSystemException(
          'Could not secure notification outbox.',
          temporary.path,
        );
      }
    }
    temporary.writeAsStringSync(jsonEncode(notification.toJson()), flush: true);
    temporary.renameSync(file.path);
  }
}
