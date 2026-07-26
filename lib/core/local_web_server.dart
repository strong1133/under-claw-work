import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'canonical_repository.dart';
import 'models.dart';
import 'task_repository.dart';
import 'workspace.dart';

/// A running read-only browser view of one memory repository.
class LocalWebSession {
  LocalWebSession(this._server, this.token);

  final HttpServer _server;

  /// Per-launch bearer token. It is printed once and never written to Git,
  /// canonical data, or a log file.
  final String token;

  InternetAddress get address => _server.address;
  int get port => _server.port;

  /// The address to paste into a browser, token included.
  Uri get url => Uri.parse('http://${address.address}:$port/?token=$token');

  Future<void> close() => _server.close(force: true);
}

/// Serves the memory repository to a browser on this machine only.
///
/// The security posture is deliberately narrow, because a browser surface is
/// the riskiest of the UI points:
///
/// * It binds the loopback interface and offers no option to bind another one.
/// * Every request must present the per-launch token.
/// * The `Host` header must be loopback, which blocks DNS rebinding.
/// * No CORS header is ever sent, so another origin cannot read a response.
/// * There is no write endpoint. Status transitions and Meta approval keep
///   running through the CLI and desktop app, where their gates are enforced.
///
/// This token authenticates a local transport session. It is not the repository
/// password, which stays locked behind provider selection.
class LocalWebServer {
  LocalWebServer(this.workspace);

  final Workspace workspace;

  Future<LocalWebSession> start({int port = 0}) async {
    final token = _newToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final session = LocalWebSession(server, token);
    server.listen(
      (request) => _handle(request, token),
      onError: (_) {},
      cancelOnError: false,
    );
    return session;
  }

  static String _newToken() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<void> _handle(HttpRequest request, String token) async {
    final response = request.response;
    // Never let a response be reused as an origin-crossing read.
    response.headers
      ..removeAll('x-frame-options')
      ..add('X-Frame-Options', 'DENY')
      ..add('X-Content-Type-Options', 'nosniff')
      ..add('Cache-Control', 'no-store')
      ..add('Referrer-Policy', 'no-referrer');

    if (!_hostIsLoopback(request)) {
      await _fail(response, HttpStatus.forbidden, 'non-loopback host');
      return;
    }
    if (request.method != 'GET') {
      await _fail(response, HttpStatus.methodNotAllowed, 'read-only server');
      return;
    }
    if (!_authorized(request, token)) {
      await _fail(response, HttpStatus.unauthorized, 'missing or wrong token');
      return;
    }

    final path = request.uri.path;
    try {
      if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        response.write(_page());
      } else if (path == '/api/tasks') {
        await _json(response, {'tasks': _tasks()});
      } else if (path.startsWith('/api/tasks/')) {
        final id = Uri.decodeComponent(path.substring('/api/tasks/'.length));
        final task = TaskRepository(workspace).get(id);
        if (task == null) {
          await _fail(response, HttpStatus.notFound, 'no such Task');
          return;
        }
        await _json(response, _taskDetail(task));
      } else if (path == '/api/domains') {
        await _json(response, {
          'domains': CanonicalRepository(workspace)
              .list(EntityKind.domain)
              .map(
                (entity) => {
                  'id': entity.id,
                  'title': entity.data['title'] ?? entity.id,
                },
              )
              .toList(),
        });
      } else {
        await _fail(response, HttpStatus.notFound, 'no such view');
        return;
      }
    } on Object catch (error) {
      await _fail(response, HttpStatus.internalServerError, '$error');
      return;
    }
    await response.close();
  }

  bool _hostIsLoopback(HttpRequest request) {
    final host = request.headers.host;
    if (host == null) return false;
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  bool _authorized(HttpRequest request, String token) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final presented = header != null && header.startsWith('Bearer ')
        ? header.substring('Bearer '.length)
        : request.uri.queryParameters['token'];
    return presented != null && _constantTimeEquals(presented, token);
  }

  /// Compares without leaking the matching prefix length through timing.
  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  List<Map<String, Object?>> _tasks() => TaskRepository(workspace)
      .list()
      .map(
        (task) => {
          'id': task.id,
          'title': task.title,
          'status': task.status.name,
          'approval': task.approval.name,
          'domain_id': task.domainId,
          'milestone_id': task.milestoneId,
          'meta_current': task.isMetaCurrent,
          'draft_revision': task.promptDraftRevision,
        },
      )
      .toList();

  Map<String, Object?> _taskDetail(WorkTask task) => {
    'id': task.id,
    'title': task.title,
    'status': task.status.name,
    'approval': task.approval.name,
    'domain_id': task.domainId,
    'milestone_id': task.milestoneId,
    'parent_task_id': task.parentTaskId,
    'related_task_ids': task.relatedTaskIds,
    'processing_mode': task.processingMode.name,
    'draft_revision': task.promptDraftRevision,
    'meta_current': task.isMetaCurrent,
    'prompt_draft': task.promptDraft,
    'prompt_meta': task.promptMeta,
  };

  Future<void> _json(HttpResponse response, Object? body) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }

  Future<void> _fail(HttpResponse response, int status, String reason) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': reason}));
    await response.close();
  }

  String _page() => '''
<!doctype html>
<meta charset="utf-8">
<title>Under Claw Work</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 0; display: flex;
         height: 100vh; }
  #list { width: 340px; border-right: 1px solid #ccc; overflow: auto; }
  #detail { flex: 1; padding: 16px 24px; overflow: auto; }
  .row { padding: 8px 12px; border-bottom: 1px solid #eee; cursor: pointer; }
  .row:hover { background: #f4f6f8; }
  .id { color: #666; font-size: 12px; }
  pre { white-space: pre-wrap; background: #f6f8fa; padding: 12px;
        border-radius: 6px; }
  input { width: calc(100% - 24px); margin: 12px; padding: 6px; }
  .banner { background: #fff6d5; padding: 8px 24px; font-size: 12px; }
</style>
<div id="list"><input id="q" placeholder="Search title, id or draft"></div>
<div id="detail">
  <div class="banner">읽기 전용 뷰. 상태 전이와 Meta 승인은 CLI나 데스크톱 앱에서 한다.</div>
  <p>왼쪽에서 Task를 고르세요.</p>
</div>
<script>
const token = new URLSearchParams(location.search).get('token') || '';
const api = (path) => fetch(path, {headers: {'Authorization': 'Bearer ' + token}})
  .then((r) => r.json());
let all = [];
const render = () => {
  const needle = document.getElementById('q').value.trim().toLowerCase();
  const list = document.getElementById('list');
  [...list.querySelectorAll('.row')].forEach((n) => n.remove());
  all.filter((t) => !needle
        || t.title.toLowerCase().includes(needle)
        || t.id.toLowerCase().includes(needle))
     .forEach((t) => {
    const row = document.createElement('div');
    row.className = 'row';
    row.innerHTML = '<div>' + escape(t.title) + '</div><div class="id">'
      + escape(t.id) + ' · ' + escape(t.status) + '</div>';
    row.onclick = () => open(t.id);
    list.appendChild(row);
  });
};
const escape = (s) => String(s).replace(/[&<>"']/g,
  (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const open = (id) => api('/api/tasks/' + encodeURIComponent(id)).then((t) => {
  document.getElementById('detail').innerHTML =
    '<div class="banner">읽기 전용 뷰. 상태 전이와 Meta 승인은 CLI나 데스크톱 앱에서 한다.</div>'
    + '<h2>' + escape(t.title) + '</h2>'
    + '<p class="id">' + escape(t.id) + ' · ' + escape(t.status)
    + ' · approval ' + escape(t.approval) + '</p>'
    + '<h3>Draft</h3><pre>' + escape(t.prompt_draft || '(비어 있음)') + '</pre>'
    + '<h3>Meta Prompt</h3><pre>' + escape(t.prompt_meta || '(비어 있음)') + '</pre>';
});
document.getElementById('q').oninput = render;
api('/api/tasks').then((d) => { all = d.tasks || []; render(); });
</script>
''';
}
