import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/release_update_service.dart';

void main() {
  late Directory root;
  late Directory installRoot;
  late Directory release;
  late String manifestSha256;

  setUp(() {
    root = Directory.systemTemp.createTempSync('release-update-service-');
    installRoot = Directory(p.join(root.path, 'installed'))..createSync();
    release = Directory(p.join(root.path, 'release'))..createSync();
    File(
      p.join(installRoot.path, 'RELEASE-VERSION.txt'),
    ).writeAsStringSync('v1\n');
    File(p.join(release.path, 'RELEASE-VERSION.txt')).writeAsStringSync('v2\n');
    File(
      p.join(release.path, 'release-manifest.tsv'),
    ).writeAsStringSync('manifest\n');
    manifestSha256 = sha256.convert(utf8.encode('manifest\n')).toString();
    final releasePackaging = Directory(p.join(release.path, 'packaging'))
      ..createSync();
    _script(
      File(p.join(releasePackaging.path, 'verify-release.sh')),
      'exit 99',
    );
    final installedPackaging = Directory(p.join(installRoot.path, 'packaging'))
      ..createSync();
    _script(
      File(p.join(installedPackaging.path, 'verify-release.sh')),
      '$_environmentGuard\nexit 0',
    );
    _script(
      File(p.join(installedPackaging.path, 'update.sh')),
      '$_environmentGuard\nprintf "applied:%s\\n" "\$1"',
    );
    _script(
      File(p.join(installedPackaging.path, 'rollback.sh')),
      '$_environmentGuard\nprintf "rolled-back\\n"',
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'checks with the trusted installed verifier, never candidate code',
    () async {
      final service = ReleaseUpdateService(installRoot: installRoot);

      final status = await service.check(release, manifestSha256);

      expect(status.currentVersion, 'v1');
      expect(status.candidateVersion, 'v2');
      expect(status.updateAvailable, isTrue);
    },
  );

  test('applies through the installed transactional updater', () async {
    final output = await ReleaseUpdateService(
      installRoot: installRoot,
    ).apply(release, manifestSha256);

    if (Platform.isWindows) {
      expect(output, startsWith('applied:/'));
      expect(output, contains(p.basename(root.path)));
      expect(output, endsWith('/release'));
    } else {
      expect(output, contains('applied:${release.path}'));
    }
  });

  test('rolls back through the installed rollback helper', () async {
    final output = await ReleaseUpdateService(
      installRoot: installRoot,
    ).rollback();

    expect(output, contains('rolled-back'));
  });

  test('rejects update checks without a trusted manifest digest', () async {
    final service = ReleaseUpdateService(installRoot: installRoot);

    expect(() => service.check(release, 'untrusted'), throwsFormatException);
  });
}

final _environmentGuard = '''
[[ -z "\${BASH_ENV:-}" && -z "\${ENV:-}" ]]
[[ -z "\${UNDER_CLAW_PARENT_SENTINEL:-}" ]]
[[ "\$LC_ALL" == C ]]
${Platform.isWindows ? _windowsPathGuard : _posixPathGuard}''';

const _posixPathGuard = '''
[[ "\$HOME" == / ]]
[[ "\$PATH" == /usr/bin:/bin ]]
''';

const _windowsPathGuard = '''
[[ "\$(cygpath -a -u "\$HOME")" == / ]]
normalized_path="\$(cygpath -p -u "\$PATH")"
[[ ":\$normalized_path:" == *:/usr/bin:* ]]
[[ ":\$normalized_path:" == *:/bin:* ]]
IFS=: read -r -a path_entries <<< "\$normalized_path"
for path_entry in "\${path_entries[@]}"; do
  case "\$path_entry" in
    /mingw32/bin|/mingw64/bin|/usr/bin|/bin) ;;
    *) exit 1 ;;
  esac
done
''';

void _script(File file, String body) {
  file.writeAsStringSync('#!/usr/bin/env bash\nset -euo pipefail\n$body\n');
  Process.runSync('chmod', ['700', file.path]);
}
