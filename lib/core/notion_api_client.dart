import 'dart:convert';

import 'package:http/http.dart' as http;

import 'notion_sync_adapter.dart';

/// Minimal production transport for the public Notion REST API.
///
/// The client is deliberately injected so tests can use [http.MockClient] and
/// no token, workspace id, or private URL is compiled into the application.
class NotionApiClient implements NotionClient {
  NotionApiClient({
    required http.Client httpClient,
    Uri? baseUri,
    this.apiVersion = '2022-06-28',
  }) : _http = httpClient,
       baseUri = baseUri ?? Uri.parse('https://api.notion.com');

  final http.Client _http;
  final Uri baseUri;
  final String apiVersion;

  @override
  Future<void> verifyConnection(String token) async {
    await _request(token, 'POST', '/v1/search', body: {'page_size': 1});
  }

  @override
  Future<NotionRemotePage> createPage(
    String token, {
    required String databaseId,
    required String canonicalId,
    required String origin,
    required Map<String, Object?> properties,
  }) async {
    final json = await _request(
      token,
      'POST',
      '/v1/pages',
      body: {
        'parent': {'database_id': databaseId},
        'properties': _encodeProperties({
          ...properties,
          'canonical_id': canonicalId,
          'origin': origin,
        }),
      },
    );
    return _decodePage(json, fallbackDatabaseId: databaseId);
  }

  @override
  Future<NotionRemotePage> updatePage(
    String token, {
    required String pageId,
    required String expectedRevision,
    required String origin,
    Map<String, Object?>? properties,
    bool? archived,
  }) async {
    final current = await page(token, pageId);
    if (current == null) {
      throw NotionSyncException('No such Notion page: $pageId.');
    }
    if (current.revision != expectedRevision) {
      throw NotionConflict(
        current.canonicalId,
        expectedRevision,
        current.revision,
      );
    }
    final json = await _request(
      token,
      'PATCH',
      '/v1/pages/$pageId',
      body: {
        if (properties != null)
          'properties': _encodeProperties({...properties, 'origin': origin}),
        'archived': ?archived,
      },
    );
    return _decodePage(json, fallbackDatabaseId: current.databaseId);
  }

  @override
  Future<NotionRemotePage?> page(String token, String pageId) async {
    try {
      final json = await _request(token, 'GET', '/v1/pages/$pageId');
      return _decodePage(json);
    } on NotionSyncException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<NotionRemotePage?> pageByCanonicalId(
    String token,
    String canonicalId,
  ) async {
    String? cursor;
    do {
      final json = await _request(
        token,
        'POST',
        '/v1/search',
        body: {
          'filter': {'property': 'object', 'value': 'page'},
          'page_size': 100,
          'start_cursor': ?cursor,
        },
      );
      for (final raw in (json['results'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final page = _decodePage(raw.cast<String, Object?>());
        if (!page.archived && page.canonicalId == canonicalId) return page;
      }
      cursor = json['has_more'] == true ? json['next_cursor'] as String? : null;
    } while (cursor != null);
    return null;
  }

  @override
  Future<({List<NotionRemotePage> pages, String cursor})> changesSince(
    String token,
    String sinceCursor,
  ) async {
    final pages = <NotionRemotePage>[];
    String? cursor;
    do {
      final json = await _request(
        token,
        'POST',
        '/v1/search',
        body: {
          'filter': {'property': 'object', 'value': 'page'},
          'sort': {'direction': 'ascending', 'timestamp': 'last_edited_time'},
          'page_size': 100,
          'start_cursor': ?cursor,
        },
      );
      for (final raw in (json['results'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final page = _decodePage(raw.cast<String, Object?>());
        // Inclusive overlap is intentional. Notion's timestamp sort is not a
        // unique cursor: two pages can share the same last_edited_time. The
        // adapter removes revisions already acknowledged in local sync state.
        if (sinceCursor.isEmpty || page.revision.compareTo(sinceCursor) >= 0) {
          pages.add(page);
        }
      }
      cursor = json['has_more'] == true ? json['next_cursor'] as String? : null;
    } while (cursor != null);
    pages.sort((left, right) => left.revision.compareTo(right.revision));
    final highWater = pages.isEmpty ? sinceCursor : pages.last.revision;
    return (pages: pages, cursor: highWater);
  }

  Future<Map<String, Object?>> _request(
    String token,
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = baseUri.resolve(path);
    final headers = {
      'Authorization': 'Bearer $token',
      'Notion-Version': apiVersion,
      'Content-Type': 'application/json',
    };
    late http.Response response;
    try {
      response = switch (method) {
        'GET' => await _http.get(uri, headers: headers),
        'POST' => await _http.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        ),
        'PATCH' => await _http.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? const {}),
        ),
        _ => throw ArgumentError.value(method, 'method'),
      };
    } on Exception {
      throw const NotionSyncException('Notion request failed.');
    }
    Map<String, Object?> decoded = const {};
    if (response.body.isNotEmpty) {
      try {
        final value = jsonDecode(response.body);
        if (value is Map) decoded = value.cast<String, Object?>();
      } on FormatException {
        throw NotionSyncException(
          'Notion returned malformed JSON.',
          statusCode: response.statusCode,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded['code']?.toString() ?? 'http_error';
      throw NotionSyncException(
        'Notion request rejected ($code).',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Map<String, Object?> _encodeProperties(Map<String, Object?> values) {
    return {
      for (final entry in values.entries)
        entry.key: entry.key == 'title'
            ? {
                'title': [
                  {
                    'text': {'content': entry.value?.toString() ?? ''},
                  },
                ],
              }
            : {
                'rich_text': [
                  {
                    'text': {
                      'content': entry.value is String
                          ? entry.value
                          : jsonEncode(entry.value),
                    },
                  },
                ],
              },
    };
  }

  NotionRemotePage _decodePage(
    Map<String, Object?> json, {
    String? fallbackDatabaseId,
  }) {
    final parent = json['parent'];
    final properties = _decodeProperties(json['properties']);
    final canonicalId = properties['canonical_id']?.toString() ?? '';
    if (canonicalId.isEmpty) {
      throw const NotionSyncException('Notion page is missing canonical_id.');
    }
    return NotionRemotePage(
      pageId: json['id']?.toString() ?? '',
      databaseId: parent is Map
          ? (parent['database_id']?.toString() ?? fallbackDatabaseId ?? '')
          : (fallbackDatabaseId ?? ''),
      canonicalId: canonicalId,
      revision: json['last_edited_time']?.toString() ?? '',
      origin: properties.remove('origin')?.toString() ?? 'notion-user',
      properties: properties,
      archived: json['archived'] == true || json['in_trash'] == true,
    );
  }

  Map<String, Object?> _decodeProperties(Object? raw) {
    if (raw is! Map) return {};
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      final property = entry.value;
      if (property is! Map) continue;
      final fragments = property['title'] ?? property['rich_text'];
      if (fragments is! List) continue;
      final text = fragments
          .whereType<Map>()
          .map((item) => item['plain_text']?.toString() ?? '')
          .join();
      if (text.isEmpty) {
        result[entry.key.toString()] = '';
        continue;
      }
      try {
        result[entry.key.toString()] = jsonDecode(text);
      } on FormatException {
        result[entry.key.toString()] = text;
      }
    }
    return result;
  }
}
