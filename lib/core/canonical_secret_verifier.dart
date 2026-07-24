import 'dart:convert';
import 'dart:io';

import 'canonical_sync_service.dart';
import 'workspace.dart';

/// Portable pre-push guard used by both CLI and Flutter.
///
/// It intentionally mirrors the repository secret-scan policy without
/// depending on Bash or a source checkout being present on the target machine.
class CanonicalSecretVerifier implements CanonicalPrePushVerifier {
  const CanonicalSecretVerifier();

  static final _blockedName = RegExp(
    r'(^|/)(\.env($|\.)|credentials\.json$|.*\.pem$|.*\.key$)',
    caseSensitive: false,
  );
  static final _credentialValue = RegExp(
    r'(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|'
    r'access[_-]?token\s*[:=]\s*[^${(<\s]|'
    r'api[_-]?key\s*[:=]\s*[^${(<\s]|'
    r'password\s*[:=]\s*[^${(<\s])',
    caseSensitive: false,
  );

  @override
  Future<void> verify(Workspace workspace) async {
    if (!workspace.workdb.existsSync()) return;
    for (final entity in workspace.workdb.listSync(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(workspace.workdb.path.length + 1);
      if (_blockedName.hasMatch(relative.replaceAll('\\', '/'))) {
        throw StateError(
          'Canonical sync blocked credential-like file: $relative',
        );
      }
      final bytes = entity.readAsBytesSync();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (_credentialValue.hasMatch(text)) {
        throw StateError(
          'Canonical sync blocked a potential credential value in $relative.',
        );
      }
    }
  }
}
