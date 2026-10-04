import 'package:uuid/uuid.dart';

import 'config.dart';
import 'models.dart';

class ApiResponse {
  final int status;
  final Object? body;
  const ApiResponse(this.status, this.body);
}

abstract interface class AdminTransport {
  Future<ApiResponse> invoke(Map<String, Object?> body);
}

enum AdminFailure {
  session,
  forbidden,
  environment,
  unavailable,
  invalidRequest,
}

class AdminException implements Exception {
  final AdminFailure failure;
  const AdminException(this.failure);
}

enum _Action {
  aiControlGet('ai.control.get'),
  aiControlSet('ai.control.set'),
  overview('overview'),
  users('users.list'),
  user('users.get'),
  health('health'),
  releases('releases'),
  audit('audit.list'),
  moderationList('moderation.list'),
  moderationGet('moderation.get'),
  reportStatus('moderation.report_status'),
  accountState('moderation.account_state');

  final String wire;
  const _Action(this.wire);
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
bool validUserId(String? value) =>
    value != null && _uuidPattern.hasMatch(value);

class ControlApi {
  final PublicConfig config;
  final AdminTransport transport;
  final Uuid _uuid = const Uuid();
  ControlApi(this.config, this.transport);
  Future<Json> _request(
    _Action action,
    Map<String, Object?> params, {
    String? correlationId,
  }) async {
    if (!config.valid) throw const AdminException(AdminFailure.unavailable);
    final correlation = correlationId ?? _uuid.v4();
    ApiResponse response;
    try {
      response = await transport.invoke({
        'action': action.wire,
        'correlation_id': correlation,
        'expected_environment': config.environment,
        'expected_project_url': config.projectUrl,
        'params': params,
      });
    } catch (_) {
      throw const AdminException(AdminFailure.unavailable);
    }
    if (response.status != 200) {
      throw AdminException(switch (response.status) {
        401 => AdminFailure.session,
        403 => AdminFailure.forbidden,
        409 => AdminFailure.environment,
        400 => AdminFailure.invalidRequest,
        _ => AdminFailure.unavailable,
      });
    }
    final envelope = object(response.body),
        environment = object(object(response.body)['environment']);
    if (environment['label'] != config.environment ||
        environment['project_url'] != config.projectUrl) {
      throw const AdminException(AdminFailure.environment);
    }
    if (envelope['correlation_id'] != correlation || envelope['data'] is! Map) {
      throw const AdminException(AdminFailure.unavailable);
    }
    return object(envelope['data']);
  }

  Future<AiControl> aiControl() async =>
      AiControl(await _request(_Action.aiControlGet, {}));
  Future<Json> setAiControl(
    bool enabled,
    Map<String, int>? limits,
    String reason,
    String correlation,
  ) {
    if (reason.trim().runes.isEmpty ||
        reason.trim().runes.length > 500 ||
        !validUserId(correlation) ||
        (limits == null && enabled) ||
        (limits != null &&
            (limits.length != 6 ||
                AiControl.limitNames.any(
                  (k) =>
                      !limits.containsKey(k) ||
                      limits[k]! < 1 ||
                      limits[k]! > 1000000000000,
                ) ||
                limits['text_minute_limit']! > limits['text_day_limit']! ||
                limits['text_day_limit']! > limits['text_month_limit']! ||
                limits['audio_minute_ms_limit']! >
                    limits['audio_day_ms_limit']! ||
                limits['audio_day_ms_limit']! >
                    limits['audio_month_ms_limit']!))) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(_Action.aiControlSet, {
      'enabled': enabled,
      'limits': limits,
      'reason': reason.trim(),
    }, correlationId: correlation);
  }

  Future<Overview> overview() async =>
      Overview(await _request(_Action.overview, {}));
  Future<UserPage> users({
    String? after,
    String? search,
    int limit = 50,
  }) async {
    if (limit < 1 ||
        limit > 100 ||
        (after != null && !validUserId(after)) ||
        (search != null && !RegExp(r'^[a-zA-Z0-9_]{3,32}$').hasMatch(search))) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return UserPage(
      await _request(_Action.users, {
        'limit': limit,
        'after': ?after,
        'search': ?search,
      }),
    );
  }

  Future<UserDetail> user(String id) async {
    if (!validUserId(id)) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return UserDetail(await _request(_Action.user, {'user_id': id}));
  }

  Future<SystemHealth> health() async =>
      SystemHealth(await _request(_Action.health, {}));
  Future<Releases> releases() async =>
      Releases(await _request(_Action.releases, {}));
  Future<AuditPage> audit({AuditCursor? before, int limit = 50}) async {
    if (limit < 1 ||
        limit > 100 ||
        (before != null &&
            (!validUserId(before.beforeId) ||
                DateTime.tryParse(before.before) == null))) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return AuditPage(
      await _request(_Action.audit, {
        'limit': limit,
        if (before != null) 'before': before.before,
        if (before != null) 'before_id': before.beforeId,
      }),
    );
  }

  Future<ModerationPage> moderation({String? status, int offset = 0}) async =>
      ModerationPage(
        await _request(_Action.moderationList, {
          'status': ?status,
          'offset': offset,
          'limit': 50,
        }),
      );
  Future<ModerationDetail> report(String id) async => ModerationDetail(
    await _request(_Action.moderationGet, {'report_id': id}),
  );
  String newCorrelation() => _uuid.v4();
  Future<Json> reportStatus(
    String id,
    String status,
    String reason,
    String correlation,
  ) => _request(_Action.reportStatus, {
    'report_id': id,
    'status': status,
    'reason': reason,
  }, correlationId: correlation);
  Future<Json> accountState(
    String id,
    String state,
    String? expires,
    String reason,
    String correlation,
  ) => _request(_Action.accountState, {
    'user_id': id,
    'state': state,
    'expires_at': expires,
    'reason': reason,
  }, correlationId: correlation);
}
