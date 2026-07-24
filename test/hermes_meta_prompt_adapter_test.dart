import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/hermes_meta_prompt_adapter.dart';

void main() {
  late Directory root;
  late File hermes;

  setUp(() {
    root = Directory.systemTemp.createTempSync('hermes-meta-adapter-');
    hermes = File(p.join(root.path, 'hermes'))
      ..writeAsStringSync(
        '#!/usr/bin/env bash\n'
        'set -euo pipefail\n'
        'printf "%s\\n" "META RESULT" "session_id: test-session"\n',
      );
    Process.runSync('chmod', ['700', hermes.path]);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'invokes explicit under-claw meta skill and returns protocol JSON',
    () async {
      final result =
          await HermesMetaPromptAdapter(
            hermesExecutable: hermes.path,
          ).generate({
            'protocol': 'under-claw-json-v1',
            'type': 'generate_meta',
            'task_id': 'TSK-adapter',
            'source_revision': 3,
            'source_sha256': 'a' * 64,
            'draft': 'Original Draft',
          });

      expect(result['protocol'], 'under-claw-json-v1');
      expect(result['type'], 'meta_prompt_result');
      expect(result['task_id'], 'TSK-adapter');
      expect(result['source_revision'], 3);
      expect(result['meta_prompt'], 'META RESULT');
    },
  );

  test('CLI adapter writes only JSON to stdout', () async {
    final input = jsonEncode({
      'protocol': 'under-claw-json-v1',
      'type': 'generate_meta',
      'task_id': 'TSK-adapter',
      'source_revision': 1,
      'source_sha256': 'b' * 64,
      'draft': 'Draft',
    });
    final output = StringBuffer();

    await runHermesMetaPromptAdapter(
      input: input,
      output: output,
      hermesExecutable: hermes.path,
    );

    final decoded = jsonDecode(output.toString()) as Map;
    expect(decoded['meta_prompt'], 'META RESULT');
  });
}
