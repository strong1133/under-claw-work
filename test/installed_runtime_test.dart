import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/installed_runtime_registry.dart';
import 'package:under_claw_work/core/meta_prompt_service.dart';
import 'package:under_claw_work/core/models.dart';
import 'package:under_claw_work/core/task_repository.dart';
import 'package:under_claw_work/core/workspace.dart';

void main() {
  late Directory root;
  late Workspace workspace;
  late File adapterScript;
  late InstalledRuntimeRegistry registry;

  setUp(() {
    root = Directory.systemTemp.createTempSync('installed-runtime-');
    workspace = Workspace(root)..ensureLayout();
    adapterScript = File(p.join(root.path, 'fake_meta.dart'));
    registry = InstalledRuntimeRegistry(workspace);
    TaskRepository(workspace).create(_task());
  });

  tearDown(() => root.deleteSync(recursive: true));

  InstalledRuntimeDescriptor descriptor({Set<String>? capabilities}) {
    final executable = File(_dartExecutable());
    return InstalledRuntimeDescriptor(
      id: 'fake-json',
      protocol: InstalledRuntimeDescriptor.protocolV1,
      executable: executable.absolute.path,
      fixedArguments: [adapterScript.path],
      capabilities: capabilities ?? const {'generate_meta'},
      executableSha256: sha256.convert(executable.readAsBytesSync()).toString(),
    );
  }

  test('registry is local, strict, atomic, and checksum verified', () {
    _writeAdapter(adapterScript);
    registry.register(descriptor());

    expect(
      registry.require('fake-json', capability: 'generate_meta').id,
      'fake-json',
    );
    expect(registry.file.path, startsWith(workspace.local.path));
    expect(File('${registry.file.path}.tmp').existsSync(), isFalse);
    final decoded = jsonDecode(registry.file.readAsStringSync()) as Map;
    expect(jsonEncode(decoded), isNot(contains('token')));

    final tampered = descriptor().toJson()..['executable_sha256'] = '0' * 64;
    registry.file.writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'adapters': [tampered],
      }),
    );
    expect(
      () => registry.require('fake-json', capability: 'generate_meta'),
      throwsStateError,
    );
  });

  test(
    'fake JSON adapter generates pending Meta for the source revision',
    () async {
      _writeAdapter(adapterScript);
      registry.register(descriptor());

      final result = await MetaPromptService(
        workspace,
      ).generate(taskId: 'TSK-runtime', adapterId: 'fake-json');

      expect(result.adapterId, 'fake-json');
      expect(result.outputSha256, hasLength(64));
      expect(result.task.promptMeta, 'META: Draft v1');
      expect(result.task.promptMetaSourceRevision, 1);
      expect(result.task.approval, PromptApproval.pending);
    },
  );

  test(
    'Draft change during process makes generated Meta stale and unsaved',
    () async {
      _writeAdapter(adapterScript, delay: true);
      registry.register(descriptor());
      final future = MetaPromptService(
        workspace,
      ).generate(taskId: 'TSK-runtime', adapterId: 'fake-json');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final repository = TaskRepository(workspace);
      repository.saveDraft(repository.get('TSK-runtime')!, 'Draft v2');

      await expectLater(future, throwsStateError);
      final current = repository.get('TSK-runtime')!;
      expect(current.promptDraftRevision, 2);
      expect(current.promptMeta, isEmpty);
      expect(current.approval, PromptApproval.stale);
    },
  );

  test('unverified protocol and missing capability fail closed', () {
    _writeAdapter(adapterScript);
    expect(
      () => registry.register(
        InstalledRuntimeDescriptor(
          id: 'bad-protocol',
          protocol: 'guessed-host-v1',
          executable: _dartExecutable(),
          fixedArguments: [adapterScript.path],
          capabilities: const {'generate_meta'},
          executableSha256: sha256
              .convert(File(_dartExecutable()).readAsBytesSync())
              .toString(),
        ),
      ),
      throwsFormatException,
    );
    registry.register(descriptor());
    expect(
      () => registry.require('fake-json', capability: 'orchestration'),
      throwsStateError,
    );
    expect(
      () =>
          registry.register(descriptor(capabilities: const {'orchestration'})),
      throwsFormatException,
    );
  });

  test('registry rejects unknown top-level fields and coerced arguments', () {
    _writeAdapter(adapterScript);
    final valid = descriptor().toJson();
    registry.file.parent.createSync(recursive: true);
    registry.file.writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'adapters': [valid],
        'unexpected': true,
      }),
    );
    expect(registry.list, throwsFormatException);

    valid['fixed_arguments'] = [42];
    registry.file.writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'adapters': [valid],
      }),
    );
    expect(registry.list, throwsFormatException);
  });
}

String _dartExecutable() {
  final result = Process.runSync(Platform.isWindows ? 'where' : 'which', const [
    'dart',
  ], runInShell: false);
  if (result.exitCode != 0) throw StateError('Dart test executable not found.');
  return File(
    result.stdout.toString().split(RegExp(r'\r?\n')).first.trim(),
  ).resolveSymbolicLinksSync();
}

void _writeAdapter(File file, {bool delay = false}) {
  file.writeAsStringSync('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  ${delay ? "await Future<void>.delayed(const Duration(milliseconds: 250));" : ""}
  stdout.write(jsonEncode({
    'protocol': 'under-claw-json-v1',
    'type': 'meta_prompt_result',
    'task_id': input['task_id'],
    'source_revision': input['source_revision'],
    'meta_prompt': 'META: \${input['draft']}',
  }));
}
''');
}

WorkTask _task() => const WorkTask(
  id: 'TSK-runtime',
  domainId: 'DOM-runtime',
  milestoneId: 'MLS-runtime',
  title: 'Runtime task',
  status: TaskStatus.draft,
  promptDraft: 'Draft v1',
  promptMeta: '',
  promptDraftRevision: 1,
  promptMetaSourceRevision: 0,
  approval: PromptApproval.missing,
  autoDeriveTasks: false,
  targetEnvironment: 'ENV-runtime',
);
