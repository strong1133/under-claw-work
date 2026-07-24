import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:under_claw_work/core/notion_api_client.dart';
import 'package:under_claw_work/core/notion_sync_adapter.dart';

void main() {
  const token = 'PLACEHOLDER-transport-token';

  test('create maps canonical properties without logging the token', () async {
    late http.Request observed;
    final client = NotionApiClient(
      httpClient: MockClient((request) async {
        observed = request;
        return http.Response(
          jsonEncode({
            'id': 'page-1',
            'parent': {'database_id': 'db-task'},
            'last_edited_time': '2026-07-24T00:00:00.000Z',
            'archived': false,
            'properties': {
              'canonical_id': {
                'rich_text': [
                  {'plain_text': 'TSK-1'},
                ],
              },
              'title': {
                'title': [
                  {'plain_text': 'Task'},
                ],
              },
              'origin': {
                'rich_text': [
                  {'plain_text': 'inst-1#0'},
                ],
              },
            },
          }),
          200,
        );
      }),
    );

    final page = await client.createPage(
      token,
      databaseId: 'db-task',
      canonicalId: 'TSK-1',
      origin: 'inst-1#0',
      properties: const {'title': 'Task'},
    );

    expect(observed.method, 'POST');
    expect(observed.url.path, '/v1/pages');
    expect(observed.headers['Authorization'], 'Bearer $token');
    expect(page.canonicalId, 'TSK-1');
    expect(page.properties['title'], 'Task');
    expect(page.origin, 'inst-1#0');
  });

  test('HTTP failures are normalized without token disclosure', () async {
    final client = NotionApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 'unauthorized', 'message': 'bad token'}),
          401,
        ),
      ),
    );

    await expectLater(
      client.verifyConnection(token),
      throwsA(
        isA<NotionSyncException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => '$error', 'message', isNot(contains(token))),
      ),
    );
  });

  test('opaque cursor uses last-edited high-water value', () async {
    final client = NotionApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'has_more': false,
            'next_cursor': null,
            'results': [
              {
                'id': 'page-1',
                'parent': {'database_id': 'db-task'},
                'last_edited_time': '2026-07-24T00:00:01.000Z',
                'properties': {
                  'canonical_id': {
                    'rich_text': [
                      {'plain_text': 'TSK-1'},
                    ],
                  },
                },
              },
            ],
          }),
          200,
        ),
      ),
    );

    final result = await client.changesSince(token, '2026-07-24T00:00:00.000Z');
    expect(result.pages.single.canonicalId, 'TSK-1');
    expect(result.cursor, '2026-07-24T00:00:01.000Z');
  });

  test(
    'cursor overlap retains a new page sharing the high-water time',
    () async {
      final client = NotionApiClient(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'has_more': false,
              'results': [
                {
                  'id': 'page-2',
                  'parent': {'database_id': 'db-task'},
                  'last_edited_time': '2026-07-24T00:00:01.000Z',
                  'properties': {
                    'canonical_id': {
                      'rich_text': [
                        {'plain_text': 'TSK-2'},
                      ],
                    },
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );

      final result = await client.changesSince(
        token,
        '2026-07-24T00:00:01.000Z',
      );
      expect(result.pages.single.canonicalId, 'TSK-2');
    },
  );
}
