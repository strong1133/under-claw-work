import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  test('CLI exposes shared sync and installed-runtime operations', () {
    // The production CLI is emitted by `dart build cli`; executing this source
    // with `dart run` is intentionally unsupported because the package also
    // contains Flutter desktop plugins.
    final output = File('bin/worklog.dart').readAsStringSync();
    expect(output, contains('git-sync <workspace>'));
    expect(output, contains('runtime-register <workspace>'));
    expect(output, contains('meta-generate <workspace>'));
    expect(output, contains('worker-next-agent <workspace>'));
    expect(output, contains('scope-config-create <workspace>'));
    expect(output, contains('context-resolve <workspace>'));
    expect(output, contains('mcp-serve <workspace>'));
    expect(output, contains('host-binding-set <workspace>'));
    expect(output, contains('CanonicalSyncService(workspace)'));
    expect(output, contains('MetaPromptService('));
    expect(output, contains("capability: 'orchestration'"));
  });
}
