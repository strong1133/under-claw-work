import 'dart:convert';
import 'dart:io';

class HermesMetaPromptAdapter {
  HermesMetaPromptAdapter({String? hermesExecutable})
    : hermesExecutable = hermesExecutable ?? 'hermes';

  final String hermesExecutable;

  Future<Map<String, Object?>> generate(Map<String, Object?> input) async {
    if (input['protocol'] != 'under-claw-json-v1' ||
        input['type'] != 'generate_meta') {
      throw const FormatException('Unsupported Meta Prompt adapter request.');
    }
    final taskId = input['task_id'] as String? ?? '';
    final sourceRevision = input['source_revision'];
    final sourceSha256 = input['source_sha256'];
    final draft = input['draft'] as String? ?? '';
    if (!RegExp(r'^TSK-[A-Za-z0-9._-]+$').hasMatch(taskId) ||
        sourceRevision is! int ||
        sourceSha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceSha256) ||
        sourceRevision < 1 ||
        draft.trim().isEmpty) {
      throw const FormatException('Meta Prompt adapter input is invalid.');
    }
    final prompt =
        '''
\$under-claw-meta-prompt

Automation contract:
- Treat the following text as the user's original Draft Prompt.
- Improve it into a precise, executable Meta Prompt.
- Do not execute the resulting prompt.
- Do not modify files or use the clipboard.
- Return only the final Meta Prompt without commentary or code fences.

Task: $taskId
Draft revision: $sourceRevision

Original Draft Prompt:
$draft
''';
    final result = await Process.run(hermesExecutable, [
      'chat',
      '-Q',
      '--source',
      'tool',
      '-s',
      'under-claw-meta-prompt',
      '-q',
      prompt,
    ], runInShell: false);
    if (result.exitCode != 0) {
      throw StateError('Hermes Meta Prompt invocation failed.');
    }
    final metaPrompt = result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .where((line) => !line.trimLeft().startsWith('session_id:'))
        .join('\n')
        .trim();
    if (metaPrompt.isEmpty) {
      throw StateError('Hermes Meta Prompt invocation returned no result.');
    }
    return {
      'protocol': 'under-claw-json-v1',
      'type': 'meta_prompt_result',
      'task_id': taskId,
      'source_revision': sourceRevision,
      'source_sha256': sourceSha256,
      'meta_prompt': metaPrompt,
    };
  }
}

Future<void> runHermesMetaPromptAdapter({
  String? input,
  StringSink? output,
  String? hermesExecutable,
}) async {
  final rawInput = input ?? await stdin.transform(utf8.decoder).join();
  final decoded = jsonDecode(rawInput);
  if (decoded is! Map) {
    throw const FormatException(
      'Meta Prompt adapter request must be an object.',
    );
  }
  final result = await HermesMetaPromptAdapter(
    hermesExecutable: hermesExecutable,
  ).generate(Map<String, Object?>.from(decoded));
  (output ?? stdout).write(jsonEncode(result));
}
