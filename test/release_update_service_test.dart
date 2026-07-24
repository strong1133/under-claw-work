import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:under_claw_work/core/release_update_service.dart';

void main() {
  late Directory root;
  late Directory installRoot;
  late Directory release;

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
      'exit 0',
    );
    _script(
      File(p.join(installedPackaging.path, 'update.sh')),
      'printf "applied:%s\\n" "\$1"',
    );
    _script(
      File(p.join(installedPackaging.path, 'rollback.sh')),
      'printf "rolled-back\\n"',
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'checks with the trusted installed verifier, never candidate code',
    () async {
      final service = ReleaseUpdateService(installRoot: installRoot);

      final status = await service.check(release);

      expect(status.currentVersion, 'v1');
      expect(status.candidateVersion, 'v2');
      expect(status.updateAvailable, isTrue);
    },
  );

  test('applies through the installed transactional updater', () async {
    final output = await ReleaseUpdateService(
      installRoot: installRoot,
    ).apply(release);

    expect(output, contains('applied:${release.path}'));
  });

  test('rolls back through the installed rollback helper', () async {
    final output = await ReleaseUpdateService(
      installRoot: installRoot,
    ).rollback();

    expect(output, contains('rolled-back'));
  });
}

void _script(File file, String body) {
  file.writeAsStringSync('#!/usr/bin/env bash\nset -euo pipefail\n$body\n');
  Process.runSync('chmod', ['700', file.path]);
}
