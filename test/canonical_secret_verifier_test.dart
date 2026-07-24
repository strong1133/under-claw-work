import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/worklog_core.dart';

void main() {
  late Directory root;
  late Workspace workspace;

  setUp(() {
    root = Directory.systemTemp.createTempSync('canonical-secret-');
    workspace = Workspace(root)..ensureLayout();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('portable verifier blocks credential-like values', () async {
    final credentialName = ['api', 'key'].join('_');
    final file = File(p.join(workspace.workdb.path, 'knowledge', 'KNW-bad.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '$credentialName = ${['fixture', 'secret'].join('-')}\n',
      );

    await expectLater(
      const CanonicalSecretVerifier().verify(workspace),
      throwsStateError,
    );

    file.writeAsStringSync('$credentialName = ${r'${'}API_KEY}\n');
    await const CanonicalSecretVerifier().verify(workspace);
  });
}
