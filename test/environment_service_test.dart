import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory temporary;
  late Workspace workspace;
  late EnvironmentService environments;

  const macbook = EnvironmentIdentity(
    machineKey: 'MK-macbook',
    os: 'macos',
    architecture: 'macosArm64',
  );
  const server = EnvironmentIdentity(
    machineKey: 'MK-server',
    os: 'linux',
    architecture: 'linuxX64',
  );

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('under-claw-env-');
    workspace = Workspace(temporary)..ensureLayout();
    environments = EnvironmentService(workspace);
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  test('registration is idempotent by immutable machine key, not alias', () {
    final first = environments.register(
      identity: macbook,
      alias: 'JSJ MacBook',
    );
    // Re-registering the same host with a different alias must NOT mint a new
    // id and must preserve the previously stored alias (editable, non-identity).
    final repeated = environments.register(
      identity: macbook,
      alias: 'Different name typed by mistake',
    );
    expect(repeated.id, first.id);
    expect(repeated.alias, 'JSJ MacBook');

    // A genuinely different machine gets its own immutable id.
    final other = environments.register(identity: server, alias: 'CI server');
    expect(other.id, isNot(first.id));
    expect(environments.list(), hasLength(2));

    // The editable alias is never the identity key.
    expect(first.alias, isNot(first.id));
    expect(first.alias, isNot(first.machineKey));
  });

  test('renaming the alias preserves referential integrity of the id', () {
    final env = environments.register(identity: macbook, alias: 'Old alias');

    // A Task references the environment by its immutable id.
    TaskRepository(workspace).create(
      WorkTask(
        id: 'TSK-env',
        domainId: 'DOM-x',
        milestoneId: 'MLS-x',
        title: 'Bound to environment',
        status: TaskStatus.draft,
        promptDraft: '',
        promptMeta: '',
        promptDraftRevision: 1,
        promptMetaSourceRevision: 0,
        approval: PromptApproval.missing,
        autoDeriveTasks: false,
        targetEnvironment: env.id,
      ),
    );

    final renamed = environments.rename(env.id, 'New friendly alias');
    expect(renamed.id, env.id);
    expect(renamed.machineKey, env.machineKey);
    expect(renamed.alias, 'New friendly alias');

    // The Task's environment reference still resolves after the rename.
    final task = TaskRepository(workspace).get('TSK-env')!;
    expect(task.targetEnvironment, env.id);
    expect(
      environments.get(task.targetEnvironment)!.alias,
      'New friendly alias',
    );

    expect(() => environments.rename(env.id, '   '), throwsFormatException);
  });

  test('os/kind/capability/status metadata are edited independently', () {
    final env = environments.register(
      identity: macbook,
      alias: 'Workstation',
      kind: 'desktop',
      capabilities: const ['git'],
    );
    expect(env.status, 'active');
    expect(env.kind, 'desktop');

    environments.setKind(env.id, 'agent_runtime');
    environments.setCapabilities(env.id, const ['git', 'gui', 'docker']);
    final deactivated = environments.deactivate(env.id);
    expect(deactivated.status, 'inactive');
    expect(deactivated.isActive, isFalse);

    final reloaded = EnvironmentService(workspace).get(env.id)!;
    expect(reloaded.kind, 'agent_runtime');
    expect(reloaded.capabilities, ['docker', 'git', 'gui']);
    expect(reloaded.status, 'inactive');
    // Identity fields survived every metadata edit unchanged.
    expect(reloaded.id, env.id);
    expect(reloaded.machineKey, env.machineKey);

    environments.activate(env.id);
    expect(EnvironmentService(workspace).get(env.id)!.status, 'active');

    expect(() => environments.setKind(env.id, 'phone'), throwsFormatException);
    expect(() => environments.setStatus(env.id, 'nope'), throwsFormatException);
  });

  test('legacy name-only records are read as editable aliases', () {
    // Simulate a pre-split registry document.
    File(p.join(workspace.config.path, 'environments.json')).writeAsStringSync(
      '${jsonEncode({
        'schema_version': 1,
        'environments': [
          {
            'id': 'ENV-legacy',
            'name': 'Legacy desktop',
            'os': 'macos',
            'status': 'active',
            'capabilities': ['git'],
            'registered_at': '2026-01-01T00:00:00Z',
          },
        ],
      })}\n',
    );
    final record = environments.get('ENV-legacy')!;
    expect(record.alias, 'Legacy desktop');
    expect(record.machineKey, 'legacy:ENV-legacy');

    // Renaming a legacy record keeps its immutable id and legacy machine key.
    final renamed = environments.rename('ENV-legacy', 'Migrated alias');
    expect(renamed.id, 'ENV-legacy');
    expect(renamed.machineKey, 'legacy:ENV-legacy');
    expect(renamed.alias, 'Migrated alias');
  });

  test('detected identity is stable and salted (no raw hostname stored)', () {
    final first = EnvironmentIdentity.detect(workspace);
    final second = EnvironmentIdentity.detect(workspace);
    expect(first.machineKey, second.machineKey);
    expect(first.machineKey, startsWith('MK-'));
    final machineFile = File(p.join(workspace.local.path, 'machine.json'));
    expect(machineFile.existsSync(), isTrue);
    // The salted machine key may be cached locally in the git-ignored
    // `.worklog/`, but the raw hostname must never be written anywhere.
    expect(
      machineFile.readAsStringSync(),
      isNot(contains(Platform.localHostname)),
    );
    // The version-controlled registry likewise never leaks the hostname.
    environments.register(identity: first, alias: 'This host');
    final registry = File(
      p.join(workspace.config.path, 'environments.yaml'),
    ).readAsStringSync();
    expect(registry, isNot(contains(Platform.localHostname)));
    expect(registry, contains(first.machineKey));
  });

  test('registry is canonical YAML and reads a legacy JSON registry', () {
    // Given only a legacy JSON registry (initial vertical slice), the service
    // reads it but writes the canonical YAML form on the next mutation.
    File(p.join(workspace.config.path, 'environments.json')).writeAsStringSync(
      '${jsonEncode({
        'schema_version': 1,
        'environments': [
          {
            'id': 'ENV-json',
            'name': 'From JSON',
            'os': 'macos',
            'status': 'active',
            'capabilities': ['git'],
            'registered_at': '2026-01-01T00:00:00Z',
          },
        ],
      })}\n',
    );
    expect(environments.get('ENV-json')!.alias, 'From JSON');
    environments.register(identity: server, alias: 'CI');
    expect(
      File(p.join(workspace.config.path, 'environments.yaml')).existsSync(),
      isTrue,
    );
    // Both records are visible through the canonical YAML now.
    expect(EnvironmentService(workspace).list(), hasLength(2));
  });

  test('legacy name-only record is safely promoted once for its host', () {
    // A legacy record with the same alias/os but no machine key.
    File(p.join(workspace.config.path, 'environments.json')).writeAsStringSync(
      '${jsonEncode({
        'schema_version': 1,
        'environments': [
          {
            'id': 'ENV-legacy',
            'name': 'JSJ MacBook',
            'os': 'macos',
            'status': 'active',
            'capabilities': ['git'],
            'registered_at': '2026-01-01T00:00:00Z',
          },
        ],
      })}\n',
    );
    final promoted = environments.register(
      identity: macbook,
      alias: 'JSJ MacBook',
    );
    // Same id preserved, no duplicate ENV, machine key now bound.
    expect(promoted.id, 'ENV-legacy');
    expect(promoted.machineKey, macbook.machineKey);
    expect(promoted.previousMachineKeys, ['legacy:ENV-legacy']);
    expect(environments.list(), hasLength(1));
    // A second registration is idempotent (still one env, same id).
    final again = environments.register(identity: macbook, alias: 'renamed');
    expect(again.id, 'ENV-legacy');
    expect(environments.list(), hasLength(1));
  });

  test('salt loss recovery relinks the same ENV id without duplication', () {
    final original = environments.register(
      identity: macbook,
      alias: 'Workstation',
    );
    // Simulate salt loss / reinstall: a brand-new host identity appears.
    const reinstalled = EnvironmentIdentity(
      machineKey: 'MK-reinstalled',
      os: 'macos',
      architecture: 'macosArm64',
    );
    final relinked = environments.relink(original.id, reinstalled);
    expect(relinked.id, original.id);
    expect(relinked.machineKey, 'MK-reinstalled');
    expect(relinked.previousMachineKeys, contains(macbook.machineKey));
    expect(environments.list(), hasLength(1));
    // Registering again under the reinstalled identity is now idempotent.
    final rereg = environments.register(
      identity: reinstalled,
      alias: 'ignored',
    );
    expect(rereg.id, original.id);
    expect(environments.list(), hasLength(1));

    // Relink refuses to steal a machine key already bound elsewhere.
    final other = environments.register(identity: server, alias: 'CI');
    expect(() => environments.relink(other.id, reinstalled), throwsStateError);
  });

  test('registry write is atomic and lock-guarded against lost updates', () {
    environments.register(identity: macbook, alias: 'A');
    // A stale lock blocks writers; the short timeout surfaces a clear error
    // instead of silently clobbering a concurrent update.
    final lock = File(p.join(workspace.config.path, 'environments.yaml.lock'))
      ..writeAsStringSync('held');
    final guarded = EnvironmentService(
      workspace,
      lockTimeout: const Duration(milliseconds: 100),
    );
    expect(
      () => guarded.register(identity: server, alias: 'B'),
      throwsStateError,
    );
    lock.deleteSync();
    // Once released, distinct hosts both persist (no lost update).
    guarded.register(identity: server, alias: 'B');
    expect(
      guarded.list().map((record) => record.alias),
      containsAll(['A', 'B']),
    );
    // No stray temp file left behind by the atomic rename.
    expect(
      File(p.join(workspace.config.path, 'environments.yaml.tmp')).existsSync(),
      isFalse,
    );
  });

  test('records pass the runtime environment contract validator', () {
    environments.register(identity: macbook, alias: 'Valid host');
    environments.validateAll();
    final record = environments.list().single.toJson();
    expect(record['machine_key'], startsWith('MK-'));
    expect(record['kind'], isNotNull);
    expect(record['architecture'], isNotNull);
  });

  test('a stale lock from a crashed writer is reclaimed (gap 8)', () {
    environments.register(identity: macbook, alias: 'A');
    // A lock whose timestamp is far in the past models a crashed writer.
    final lock = File(p.join(workspace.config.path, 'environments.yaml.lock'))
      ..writeAsStringSync('{"pid":999999,"at":"2000-01-01T00:00:00.000Z"}');
    final service = EnvironmentService(
      workspace,
      lockTimeout: const Duration(milliseconds: 200),
      staleLockTimeout: const Duration(seconds: 1),
    );
    // The stale lock is reclaimed and the registration completes.
    final created = service.register(identity: server, alias: 'B');
    expect(created.alias, 'B');
    expect(service.list(), hasLength(2));
    expect(lock.existsSync(), isFalse);
  });

  test('a fresh lock is never reclaimed (only genuinely stale ones)', () {
    environments.register(identity: macbook, alias: 'A');
    File(
      p.join(workspace.config.path, 'environments.yaml.lock'),
    ).writeAsStringSync(
      '{"pid":1,"at":"${DateTime.now().toUtc().toIso8601String()}"}',
    );
    final service = EnvironmentService(
      workspace,
      lockTimeout: const Duration(milliseconds: 100),
      staleLockTimeout: const Duration(minutes: 5),
    );
    expect(
      () => service.register(identity: server, alias: 'B'),
      throwsStateError,
    );
  });

  test(
    'agent registry serializes writes and reclaims a stale lock (gap 8)',
    () {
      final env = environments.register(identity: macbook, alias: 'Host');
      final agents = AgentRegistryService(
        workspace,
        lockTimeout: const Duration(milliseconds: 100),
        staleLockTimeout: const Duration(seconds: 1),
      );
      final first = agents.register(
        name: 'Hermes',
        kind: 'hermes',
        environmentId: env.id,
      );
      // A fresh foreign lock blocks a concurrent registration (no lost update).
      final lock = File(p.join(workspace.config.path, 'agents.yaml.lock'))
        ..writeAsStringSync(
          '{"pid":1,"at":"${DateTime.now().toUtc().toIso8601String()}"}',
        );
      expect(
        () => agents.register(
          name: 'Codex',
          kind: 'codex',
          environmentId: env.id,
        ),
        throwsStateError,
      );
      // Once the lock ages past the stale threshold it is reclaimed.
      lock.writeAsStringSync('{"pid":1,"at":"2000-01-01T00:00:00.000Z"}');
      final second = agents.register(
        name: 'Codex',
        kind: 'codex',
        environmentId: env.id,
      );
      expect(
        agents.list().map((record) => record.id),
        containsAll([first.id, second.id]),
      );
      expect(lock.existsSync(), isFalse);
    },
  );
}
