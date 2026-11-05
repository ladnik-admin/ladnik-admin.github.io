import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'config.dart';
import 'models.dart';
import 'maintenance_recovery.dart';

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
  conflict,
}

class AdminException implements Exception {
  final AdminFailure failure;
  final bool definiteRejection;
  const AdminException(this.failure, {this.definiteRejection = false});
}

/// Sanitized, attempt-bound evidence of a completed SQL rollback. Never retain
/// raw FunctionException.details, SQL errors or arbitrary provider response keys.
ApiResponse safeAdminError(
  int status,
  Object? details,
  Map<String, Object?> request,
) {
  final value = object(details),
      environment = object(object(details)['environment']);
  const allowed = {
    'revision_conflict': 409,
    'invalid_request': 400,
    'forbidden': 403,
    'maintenance_not_qualified': 503,
    'maintenance_rejected': 503,
    'notices_unavailable': 503,
    'notices_rejected': 503,
    'notice_capacity': 409,
  };
  final version = request['action'] == 'maintenance.commit.v2'
      ? 2
      : const [
          'notices.publish.v1',
          'notices.resolve.v1',
        ].contains(request['action'])
      ? 1
      : null;
  if (version == null ||
      value['rejected'] != true ||
      value['contract_version'] is! int ||
      value['contract_version'] != version ||
      allowed[value['error']] != status ||
      value['correlation_id'] != request['correlation_id'] ||
      environment['label'] != request['expected_environment'] ||
      environment['project_url'] != request['expected_project_url']) {
    return ApiResponse(status, null);
  }
  return ApiResponse(status, {
    'error': value['error'],
    'rejected': true,
    'contract_version': version,
    'correlation_id': request['correlation_id'],
    'environment': {
      'label': request['expected_environment'],
      'project_url': request['expected_project_url'],
    },
  });
}

enum _Action {
  noticeContext('notices.get.v1'),
  noticePublish('notices.publish.v1'),
  noticeResolve('notices.resolve.v1'),
  noticeReceipt('notices.receipt.v1'),
  maintenanceContext('maintenance.context.v2'),
  maintenancePrepare('maintenance.prepare.v2'),
  maintenanceCommit('maintenance.commit.v2'),
  maintenanceReceipt('maintenance.receipt.v2'),
  subscriptionsOverview('subscriptions.overview'),
  subscriptionsGet('subscriptions.get'),
  subscriptionsPreview('subscriptions.preview'),
  subscriptionsApply('subscriptions.apply'),
  releasePolicySet('release.policy.set'),
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

/// Minimal immutable expectation persisted with an unresolved notice command.
/// No announcement content, authentication material or personal data.
class NoticeCommand {
  final String request, notice, state;
  final int revision;
  NoticeCommand({
    required this.request,
    required this.notice,
    required this.state,
    required this.revision,
  }) {
    if (!validUserId(request) ||
        !validUserId(notice) ||
        !const ['published', 'resolved'].contains(state) ||
        revision < 1 ||
        revision >= 9007199254740991) {
      throw const FormatException();
    }
  }
  factory NoticeCommand.decode(String value) {
    if (value.length > 512) throw const FormatException();
    final row = object(jsonDecode(value));
    if (row.length != 5 ||
        row.keys.any(
          (k) => !const [
            'version',
            'request',
            'notice',
            'state',
            'revision',
          ].contains(k),
        ) ||
        row['version'] != 1 ||
        row['request'] is! String ||
        row['notice'] is! String ||
        row['state'] is! String ||
        row['revision'] is! int) {
      throw const FormatException();
    }
    return NoticeCommand(
      request: row['request'] as String,
      notice: row['notice'] as String,
      state: row['state'] as String,
      revision: row['revision'] as int,
    );
  }
  String encode() => jsonEncode({
    'version': 1,
    'request': request,
    'notice': notice,
    'state': state,
    'revision': revision,
  });
  bool accepts(Json result) =>
      result['version'] == 1 &&
      result['requestId'] == request &&
      result['state'] == state &&
      result['notice'] == notice &&
      result['revision'] == revision;
}

class ControlApi {
  final PublicConfig config;
  final AdminTransport transport;
  final MaintenanceRecovery maintenanceRecovery;
  final Uuid _uuid = const Uuid();
  ControlApi(this.config, this.transport, {MaintenanceRecovery? recovery})
    : maintenanceRecovery = recovery ?? createMaintenanceRecovery();
  Future<Json> _request(
    _Action action,
    Map<String, Object?> params, {
    String? correlationId,
  }) async {
    if (!config.valid) throw const AdminException(AdminFailure.unavailable);
    final correlation = correlationId ?? _uuid.v4();
    final subscriptions =
        action.wire.startsWith('subscriptions.') ||
        action.wire.startsWith('notices.');
    final maintenance = action.wire.startsWith('maintenance.');
    final body = <String, Object?>{
      'action': action.wire,
      if (subscriptions) 'contract_version': 1,
      if (maintenance) 'contract_version': 2,
      'correlation_id': correlation,
      'expected_environment': config.environment,
      'expected_project_url': config.projectUrl,
      'params': params,
    };
    ApiResponse response;
    try {
      response = await transport.invoke(body);
    } catch (_) {
      throw const AdminException(AdminFailure.unavailable);
    }
    if (response.status != 200) {
      throw AdminException(
        switch (response.status) {
          401 => AdminFailure.session,
          403 => AdminFailure.forbidden,
          409 =>
            object(response.body)['error'] == 'revision_conflict'
                ? AdminFailure.conflict
                : AdminFailure.environment,
          400 => AdminFailure.invalidRequest,
          _ => AdminFailure.unavailable,
        },
        definiteRejection:
            safeAdminError(response.status, response.body, body).body != null,
      );
    }
    final envelope = object(response.body),
        environment = object(object(response.body)['environment']);
    if (subscriptions &&
        (envelope['contract_version'] is! int ||
            envelope['contract_version'] != 1)) {
      throw const AdminException(AdminFailure.unavailable);
    }
    if (maintenance &&
        (envelope['contract_version'] is! int ||
            envelope['contract_version'] != 2)) {
      throw const AdminException(AdminFailure.unavailable);
    }
    if (environment['label'] != config.environment ||
        environment['project_url'] != config.projectUrl) {
      throw const AdminException(AdminFailure.environment);
    }
    if (envelope['correlation_id'] != correlation || envelope['data'] is! Map) {
      throw const AdminException(AdminFailure.unavailable);
    }
    return object(envelope['data']);
  }

  String get noticeJournalScope => '${config.projectUrl}/service-notices-v1';
  Future<ServiceNoticesData> serviceNotices() async =>
      ServiceNoticesData(await _request(_Action.noticeContext, {}));
  Future<Json> publishNotice(Json draft, String request) => _request(
    _Action.noticePublish,
    {...draft, 'confirmed': true},
    correlationId: request,
  );
  Future<Json> resolveNotice(String id, int revision, String request) =>
      _request(_Action.noticeResolve, {
        'id': id,
        'revision': revision,
        'confirmed': true,
      }, correlationId: request);
  Future<Json> noticeReceipt(String request) =>
      _request(_Action.noticeReceipt, {'request': request});

  Future<AiControl> aiControl() async =>
      AiControl(await _request(_Action.aiControlGet, {}));

  Future<MaintenanceContext> maintenanceContext() async =>
      MaintenanceContext(await _request(_Action.maintenanceContext, {}));

  Future<Json> prepareMaintenance(int revision, String mode, DateTime? until) {
    if (revision < 1 ||
        revision >= 9007199254740991 ||
        !const ['NORMAL', 'READ_ONLY', 'CRITICAL_PAUSE'].contains(mode) ||
        (mode == 'NORMAL') != (until == null)) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(_Action.maintenancePrepare, {
      'version': 2,
      'revision': revision,
      'mode': mode,
      'reason_code': mode == 'NORMAL' ? 'resume' : 'planned_migration',
      'expires_at': until?.toUtc().toIso8601String(),
    });
  }

  Future<Json> commitMaintenance(
    String intent,
    String nonce,
    String request,
    int revision,
  ) {
    if (!validUserId(intent) ||
        !validUserId(request) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce) ||
        revision < 1 ||
        revision >= 9007199254740991) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(_Action.maintenanceCommit, {
      'version': 2,
      'intent': intent,
      'nonce': nonce,
      'request': request,
      'revision': revision,
    }, correlationId: request);
  }

  Future<Json> maintenanceReceipt(String request) {
    if (!validUserId(request)) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(_Action.maintenanceReceipt, {
      'version': 2,
      'request': request,
    });
  }

  Future<Subscriptions> subscriptions() async => Subscriptions(
    await _request(_Action.subscriptionsOverview, {}),
    overview: true,
  );
  Future<Subscriptions> subscription(String id, {bool team = false}) async {
    if (!validUserId(id)) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return Subscriptions(
      await _request(_Action.subscriptionsGet, {
        team ? 'team_id' : 'user_id': id,
      }),
    );
  }

  Future<Json> changeSubscription({
    required String command,
    String? target,
    required int revision,
    required Json values,
    required String reason,
    required String correlation,
    required bool preview,
  }) async {
    if (!['grant.set', 'policy.set', 'enforcement.set'].contains(command) ||
        revision < 0 ||
        revision > 2147483646 ||
        reason.trim().isEmpty ||
        reason.trim().runes.length > 500 ||
        !validUserId(correlation) ||
        (command == 'grant.set' ? !validUserId(target) : target != null)) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(
      preview ? _Action.subscriptionsPreview : _Action.subscriptionsApply,
      {
        'command': command,
        'target_id': target,
        'revision': revision,
        'values': values,
        'reason': reason.trim(),
      },
      correlationId: correlation,
    );
  }

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
  Future<Json> setReleasePolicy(
    ReleasePolicyData policy,
    String reason,
    String correlation,
  ) async {
    if (!validUserId(correlation) ||
        reason.trim().isEmpty ||
        reason.runes.length > 500) {
      throw const AdminException(AdminFailure.invalidRequest);
    }
    return _request(_Action.releasePolicySet, {
      ...policy.toMap(),
      'reason': reason.trim(),
    }, correlationId: correlation);
  }

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
