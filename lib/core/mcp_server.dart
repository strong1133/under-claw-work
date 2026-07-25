import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'canonical_repository.dart';
import 'context_builder.dart';
import 'memory_recall_service.dart';
import 'scope_context_resolver.dart';
import 'task_repository.dart';
import 'workspace.dart';

class UnderClawMcpHandler {
  UnderClawMcpHandler(
    this.workspace, {
    required this.domainId,
    this.milestoneId,
  }) : repository = CanonicalRepository(workspace) {
    _validateFixedScope();
  }

  void _validateFixedScope() {
    final domain = repository.get(EntityKind.domain, domainId);
    if (domain == null) throw StateError('Domain does not exist: $domainId');
    if (domain.data['status'] != 'active') {
      throw StateError('Domain is not active: $domainId');
    }
    if (milestoneId != null) {
      final milestone = repository.get(EntityKind.milestone, milestoneId!);
      if (milestone == null ||
          milestone.data['status'] != 'active' ||
          milestone.data['domain_id'] != domainId) {
        throw StateError('Milestone is not in the configured Domain.');
      }
    }
  }

  final Workspace workspace;
  final String domainId;
  final String? milestoneId;
  final CanonicalRepository repository;

  Map<String, Object?>? handle(Map<String, Object?> request) {
    final method = request['method'];
    final hasId = request.containsKey('id');
    final id = request['id'];
    final validId = !hasId || id is String || id is num;
    if (request['jsonrpc'] != '2.0' ||
        method is! String ||
        method.isEmpty ||
        !validId) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32600, 'message': 'Invalid JSON-RPC request.'},
      };
    }
    if (!hasId) return null;
    if (!const {
      'initialize',
      'ping',
      'tools/list',
      'tools/call',
    }.contains(method)) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Method not found: $method'},
      };
    }
    try {
      if (request.containsKey('params') && request['params'] is! Map) {
        throw const FormatException('params must be an object.');
      }
      _validateFixedScope();
      final result = switch (method) {
        'initialize' => _initialize(request['params']),
        'ping' => <String, Object?>{},
        'tools/list' => {'tools': _tools},
        'tools/call' => _callTool(request['params']),
        _ => throw StateError('Unreachable MCP method: $method'),
      };
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on FormatException catch (error) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32602, 'message': error.toString()},
      };
    } catch (error) {
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': 'Internal MCP error.'},
      };
    }
  }

  Map<String, Object?> _initialize(Object? rawParams) {
    final params = rawParams as Map? ?? const <String, Object?>{};
    final requested = params['protocolVersion'];
    const supported = {'2024-11-05', '2025-03-26'};
    final protocolVersion = requested is String && supported.contains(requested)
        ? requested
        : '2025-03-26';
    return {
      'protocolVersion': protocolVersion,
      'capabilities': {'tools': <String, Object?>{}},
      'serverInfo': {'name': 'under-claw-work', 'version': '1.0.0'},
    };
  }

  Map<String, Object?> _callTool(Object? rawParams) {
    if (rawParams is! Map) throw const FormatException('params are required.');
    final name = rawParams['name'];
    final arguments = rawParams['arguments'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('name is required.');
    }
    if (arguments != null && arguments is! Map) {
      throw const FormatException('arguments must be an object.');
    }
    final args = arguments is Map ? arguments : const <String, Object?>{};
    final payload = switch (name) {
      'underclaw_recall' => _recall(),
      'underclaw_resolve_context' => ScopeContextResolver(
        workspace,
      ).resolve(domainId: domainId, milestoneId: milestoneId).toJson(),
      'underclaw_list_milestones' => _milestones(),
      'underclaw_build_task_context' => _taskContext(args),
      _ => throw FormatException('Unknown read-only tool: $name'),
    };
    return {
      'content': [
        {'type': 'text', 'text': jsonEncode(payload)},
      ],
      'structuredContent': payload,
      'isError': false,
    };
  }

  Map<String, Object?> _recall() {
    final result = MemoryRecallService(
      workspace,
    ).recall(domainId: domainId, milestoneId: milestoneId);
    Map<String, Object?> item(RecalledKnowledge value) => {
      'id': value.id,
      'title': value.title,
      'body': value.body,
      'confidence': value.confidence,
      'provenance': value.provenance,
      'superseded_by': value.supersededBy,
      'contradicted_by': value.contradictedBy,
    };
    return {
      'domain_id': domainId,
      if (milestoneId != null) 'milestone_id': milestoneId,
      'current': result.current.map(item).toList(),
      'superseded': result.superseded.map(item).toList(),
    };
  }

  List<Map<String, Object?>> _milestones() => repository
      .list(EntityKind.milestone)
      .where(
        (entity) =>
            entity.data['status'] == 'active' &&
            entity.data['domain_id'] == domainId &&
            (milestoneId == null || entity.id == milestoneId),
      )
      .map((entity) => entity.data)
      .toList();

  Map<String, Object?> _taskContext(Map args) {
    final taskId = args['task_id'];
    if (taskId is! String || taskId.isEmpty) {
      throw const FormatException('task_id is required.');
    }
    final task = TaskRepository(workspace).get(taskId);
    if (task == null || task.domainId != domainId) {
      throw const FormatException('Task is outside the configured Domain.');
    }
    if (milestoneId != null && task.milestoneId != milestoneId) {
      throw const FormatException('Task is outside the configured Milestone.');
    }
    final rawTokenBudget = args['token_budget'];
    if (rawTokenBudget != null &&
        (rawTokenBudget is! int ||
            rawTokenBudget < 1 ||
            rawTokenBudget > 65536)) {
      throw const FormatException(
        'token_budget must be an integer between 1 and 65536.',
      );
    }
    final pack = ContextPackBuilder(
      workspace,
    ).build(taskId, tokenBudget: rawTokenBudget as int? ?? 4096);
    return {
      'task_id': pack.taskId,
      'token_budget': pack.tokenBudget,
      'estimated_tokens': pack.estimatedTokens,
      'entries': pack.entries
          .map(
            (entry) => {
              'id': entry.id,
              'entity_type': entry.entityType,
              'content': entry.content,
              'provenance': entry.provenance,
              'relation_distance': entry.relationDistance,
              'truncated': entry.truncated,
            },
          )
          .toList(),
      'omitted_ids': pack.omittedIds,
      'superseded_ids': pack.supersededIds,
    };
  }

  static const _tools = <Map<String, Object?>>[
    {
      'name': 'underclaw_recall',
      'description': 'Recall non-restricted Knowledge from the fixed scope.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'underclaw_resolve_context',
      'description': 'Resolve Agent, Persona, Discord, MCP and Skill policy.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'underclaw_list_milestones',
      'description': 'List Milestones in the fixed Domain.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'underclaw_build_task_context',
      'description': 'Build a deterministic context pack for an in-scope Task.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'task_id': {'type': 'string'},
          'token_budget': {'type': 'integer', 'minimum': 1, 'maximum': 65536},
        },
        'required': ['task_id'],
      },
    },
  ];
}

class UnderClawMcpServer {
  UnderClawMcpServer(this.handler);

  final UnderClawMcpHandler handler;

  Map<String, Object?>? handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        return {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32600, 'message': 'Invalid JSON-RPC request.'},
        };
      }
      return handler.handle(decoded.cast<String, Object?>());
    } on FormatException {
      return {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'JSON-RPC parse error.'},
      };
    }
  }

  Future<void> runStdio() async {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final response = handleLine(line);
      if (response != null) stdout.writeln(jsonEncode(response));
    }
  }
}
