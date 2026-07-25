import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('auto Meta service installer uses the installed watcher variable', () {
    final script = File(
      'packaging/install-auto-meta-service.sh',
    ).readAsStringSync();
    expect(script, contains('watch_script='));
    expect(script, isNot(contains(r'$watcher')));
    expect(script, contains(r'ExecStart=$quoted_watch_script'));
  });

  test('service installer rejects newline values before writing a unit', () {
    if (!Platform.isLinux || !Directory('/run/systemd/system').existsSync()) {
      return;
    }
    final root = Directory.systemTemp.createTempSync('auto-meta-unit-');
    addTearDown(() => root.deleteSync(recursive: true));
    final install = Directory(p.join(root.path, 'install'));
    final workspace = Directory(p.join(root.path, 'workspace'));
    final config = Directory(p.join(root.path, 'config'));
    Directory(p.join(install.path, 'packaging')).createSync(recursive: true);
    Directory(p.join(install.path, 'bin')).createSync(recursive: true);
    Directory(p.join(workspace.path, '.git')).createSync(recursive: true);
    final watcher = File(
      p.join(install.path, 'packaging', 'auto-meta-watch.sh'),
    )..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final worklog = File(p.join(install.path, 'bin', 'worklog'))
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    final hermes = File(p.join(root.path, 'hermes\ninjected'))
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['755', watcher.path, worklog.path, hermes.path]);

    final result = Process.runSync(
      'bash',
      [
        'packaging/install-auto-meta-service.sh',
        workspace.path,
        'ENV-test',
        'adapter',
        '15',
      ],
      environment: {
        ...Platform.environment,
        'UNDER_CLAW_WORK_HOME': install.path,
        'UNDER_CLAW_HERMES_BIN': hermes.path,
        'XDG_CONFIG_HOME': config.path,
      },
    );

    expect(result.exitCode, 64);
    expect(result.stderr, contains('Unit values may not contain newlines'));
    expect(
      File(
        p.join(config.path, 'systemd', 'user', 'under-claw-auto-meta.service'),
      ).existsSync(),
      isFalse,
    );
  });

  test('watcher prefers packaged CLI so native assets stay adjacent', () {
    final script = File('packaging/auto-meta-watch.sh').readAsStringSync();
    expect(script, contains(r'default_worklog="$install_root/bin/worklog"'));
    expect(script, contains(r'"$worklog_bin" auto-meta-next'));
  });

  test('unsigned package records and installs its source revision', () {
    final build = File('packaging/build-unsigned.sh').readAsStringSync();
    final install = File('packaging/install.sh').readAsStringSync();

    expect(build, contains('SOURCE-REVISION.txt'));
    expect(build, contains('UNDER_CLAW_SOURCE_REVISION'));
    expect(install, contains('SOURCE-REVISION.txt'));
  });
}
