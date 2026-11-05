// Allowlisted projections only. Unknown response keys never reach UI/state.
typedef Json = Map<String, dynamic>;
Json object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String? text(Object? value) =>
    value is String && value.length <= 500 ? value : null;
int? count(Object? value) => value is int && value >= 0 ? value : null;
List<Json> rows(Object? value, int limit) => value is List
    ? value.take(limit).whereType<Map>().map(object).toList()
    : [];

class Counter {
  final int? value, lowerBound;
  final String? reason;
  Counter(Object? raw)
    : value = object(raw)['availability'] == 'available'
          ? count(object(raw)['value'])
          : null,
      lowerBound = count(object(raw)['lower_bound']),
      reason = text(object(raw)['reason']);
  String get label => value != null
      ? '$value'
      : lowerBound != null
      ? 'Unavailable (at least $lowerBound)'
      : 'Unavailable';
}

sealed class AdminData {}

class MaintenanceContext extends AdminData {
  final bool available;
  final int? revision;
  final String? mode, expiresAt;
  MaintenanceContext(Json raw)
    : revision =
          raw['revision'] is int &&
              raw['revision'] > 0 &&
              raw['revision'] < 9007199254740991
          ? raw['revision'] as int
          : null,
      mode =
          const [
            'NORMAL',
            'READ_ONLY',
            'CRITICAL_PAUSE',
          ].contains(raw['configuredMode'])
          ? raw['configuredMode'] as String
          : null,
      expiresAt = text(raw['expiresAt']),
      available =
          raw['version'] == 2 &&
          raw['available'] == true &&
          raw['reauthRequired'] == true &&
          raw['revision'] is int &&
          raw['revision'] > 0 &&
          raw['revision'] < 9007199254740991 &&
          const [
            'NORMAL',
            'READ_ONLY',
            'CRITICAL_PAUSE',
          ].contains(raw['configuredMode']);
}

const commercialLimitNames = [
  'owned_cloud_limit',
  'owned_shared_limit',
  'shared_member_limit',
  'team_workspace_limit',
  'seat_limit',
  'automation_limit',
  'ai_budget_micro_usd',
  'ai_multiplier_bps',
];
Json commercialLimits(Object? raw) => {
  for (final key in commercialLimitNames) key: count(object(raw)[key]),
};

int? commercialAiPercentage(Json policy) {
  final value = count(policy['used_percentage']);
  return (policy['configured'] == true ||
              policy['accounting_configured'] == true) &&
          policy['pending_reconciliation'] != true &&
          policy['coverage'] == 'tracked_since' &&
          value != null &&
          value <= 100
      ? value
      : null;
}

String commercialStoreReadiness(Object? status) => switch (status) {
  'not_configured' => 'Store catalog not configured; purchases unavailable.',
  'source_configured' =>
    'Product mapping present; Store/RevenueCat acceptance pending.',
  _ => 'Store readiness unavailable; purchases not confirmed.',
};
Json commercialProjection(Object? raw) {
  final value = object(raw);
  final activation = object(value['activation']);
  return {
    for (final key in [
      'id',
      'name',
      'owner_id',
      'user_id',
      'plan',
      'expires_at',
      'billing_status',
    ])
      key: text(value[key]),
    for (final key in [
      'active',
      'actor_member',
      'over_seat_limit',
      'over_workspace_limit',
      'read_only',
    ])
      key: value[key] is bool ? value[key] : null,
    for (final key in ['members_used', 'workspaces_used'])
      key: count(value[key]),
    'sources': value['sources'] is List
        ? (value['sources'] as List)
              .take(100)
              .whereType<String>()
              .where(
                (s) => [
                  'admin',
                  'team_owner',
                  'store_apple',
                  'store_google',
                ].contains(s),
              )
              .toList()
        : <String>[],
    'limits': commercialLimits(value['limits']),
    'ai_policy': {
      for (final key in [
        'configured',
        'accounting_configured',
        'pending_reconciliation',
      ])
        key: object(value['ai_policy'])[key] == true,
      'used_percentage': count(object(value['ai_policy'])['used_percentage']),
      for (final key in ['reset_at', 'tracking_since', 'coverage'])
        key: text(object(value['ai_policy'])[key]),
    },
    'store_sources': rows(value['store_sources'], 100)
        .map(
          (s) => <String, dynamic>{
            for (final key in [
              'provider',
              'plan',
              'period',
              'state',
              'period_end',
              'access_until',
            ])
              key: text(s[key]),
            'auto_renew': s['auto_renew'] is bool ? s['auto_renew'] : null,
            'custody_blocked': s['custody_blocked'] == true,
          },
        )
        .toList(),
    'activation': {
      'state': text(activation['state']),
      for (final key in [
        'owned_cloud_used',
        'owned_shared_used',
        'revision',
        'stored_selected_count',
        'effective_selected_count',
      ])
        key: count(activation[key]),
      for (final key in ['selected_at', 'next_change_at'])
        key: text(activation[key]),
      'remediation_allowed': activation['remediation_allowed'] == true,
    },
  };
}

class CommercialGrant {
  bool get personalOverride => values['plan'] == 'FREE';
  final Json values;
  final String? id, reason, status;
  final int revision;
  CommercialGrant(Json raw)
    : id = text(raw['id']),
      status = text(raw['status']),
      reason = text(raw['reason']),
      revision = count(raw['revision']) ?? 0,
      values = {
        for (final key in [
          'plan',
          'user_id',
          'team_id',
          'starts_at',
          'expires_at',
        ])
          key: text(raw[key]),
        // Internal note is owner-only; its explicit budget is larger than metadata.
        'internal_note':
            raw['internal_note'] is String &&
                (raw['internal_note'] as String).runes.length <= 1000
            ? raw['internal_note']
            : '',
        'limits': commercialLimits(raw['limits']),
        'revoked': raw['revoked'] == true,
      };
}

class Subscriptions extends AdminData {
  final bool? teamCreationEnabled;
  final bool overview,
      enforcementEnabled,
      aggregatesAvailable,
      teamsTruncated,
      grantsTruncated,
      auditTruncated;
  final int controlRevision;
  final Json counters, detail;
  final List<Json> policies, teams, audit;
  final List<CommercialGrant> grants;
  Subscriptions(Json raw, {this.overview = false})
    : teamCreationEnabled =
          object(raw['control'])['team_creation_enabled'] is bool
          ? object(raw['control'])['team_creation_enabled'] as bool
          : null,
      enforcementEnabled = object(raw['control'])['enabled'] == true,
      controlRevision = count(object(raw['control'])['revision']) ?? 0,
      aggregatesAvailable = raw['aggregates_available'] == true,
      teamsTruncated = raw['teams_truncated'] == true,
      grantsTruncated = raw['grants_truncated'] == true,
      auditTruncated = raw['audit_truncated'] == true,
      counters = {
        'FREE': count(object(raw['accounts_by_plan'])['FREE']),
        'PRO': count(object(raw['accounts_by_plan'])['PRO']),
        for (final key in [
          'active_teams',
          'active_grants',
          'expired_grants',
          'teams_over_seat_limit',
          'selection_required_accounts',
        ])
          key: count(raw[key]),
      },
      detail = commercialProjection(raw),
      policies = rows(raw['policies'], 3)
          .map(
            (p) => <String, dynamic>{
              'plan': text(p['plan']),
              'revision': count(p['revision']),
              'limits': commercialLimits(p['limits'])
                ..remove('ai_multiplier_bps'),
            },
          )
          .toList(),
      teams = rows(raw['teams'], 100).map(commercialProjection).toList(),
      grants = rows(raw['grants'], 25).map(CommercialGrant.new).toList(),
      audit = rows(raw['audit'], 10)
          .map(
            (event) => <String, dynamic>{
              for (final key in [
                'id',
                'actor',
                'action',
                'target_user',
                'target_team',
                'reason',
                'correlation_id',
                'occurred_at',
                'result',
              ])
                key: text(event[key]),
              for (final side in ['before', 'after'])
                side: {
                  for (final key in [
                    'plan',
                    'user_id',
                    'team_id',
                    'starts_at',
                    'expires_at',
                  ])
                    key: text(object(event[side])[key]),
                  'revision': count(object(event[side])['revision']),
                  for (final key in ['enabled', 'revoked'])
                    key: object(event[side])[key] is bool
                        ? object(event[side])[key]
                        : null,
                  'limits': commercialLimits(object(event[side])['limits']),
                },
            },
          )
          .toList();
}

class Overview extends AdminData {
  static const metrics = {
    'accounts': 'Accounts',
    'deleted_profiles': 'Deleted profiles',
    'workspaces': 'Workspaces',
    'active_memberships': 'Active memberships',
    'push_registrations': 'Push registrations',
    'enabled_push_registrations': 'Enabled Push registrations',
    'retained_activity': 'Retained Activity',
    'notifications': 'Notifications',
    'ai_quota_users': 'AI quota users',
  };
  final Map<String, Counter> counters;
  Overview(Json raw)
    : counters = {for (final key in metrics.keys) key: Counter(raw[key])};
}

class UserMetadata {
  final String? id, username, createdAt, deletedAt, lifecycle;
  final bool? verified;
  final Map<String, Counter> counters;
  UserMetadata(Json raw)
    : id = text(raw['id']),
      username = text(raw['username']),
      createdAt = text(raw['created_at']),
      deletedAt = text(raw['deleted_at']),
      lifecycle = text(raw['lifecycle']),
      verified = raw['verified'] is bool ? raw['verified'] : null,
      counters = {
        for (final key in [
          'workspace_count',
          'active_workspace_count',
          'registered_device_count',
          'enabled_device_count',
        ])
          key: Counter(raw[key]),
      };
}

class UserPage extends AdminData {
  final List<UserMetadata> users;
  final String? nextAfter;
  UserPage(Json raw)
    : users = rows(raw['users'], 100).map(UserMetadata.new).toList(),
      nextAfter = text(raw['next_after']);
}

class AppSignal {
  final String? platform, version, build, lastSeen;
  AppSignal(Json raw)
    : platform = text(raw['platform']),
      version = text(raw['app_version']),
      build = text(raw['build_number']),
      lastSeen = text(raw['last_seen_at']);
}

class AiObservation {
  final bool available, truncated;
  final int? days;
  final String? reason;
  final Map<String, num?> summary;
  AiObservation(Json raw)
    : available = raw['availability'] == 'available',
      truncated = raw['groups_truncated'] == true,
      days = count(raw['window_days']),
      reason = text(raw['reason']),
      summary = {
        for (final key in [
          'requests',
          'successes',
          'provider_failures',
          'rate_limited',
          'quota_unavailable',
          'not_configured',
          'input_tokens',
          'output_tokens',
          'total_tokens',
          'missing_usage',
          'mean_latency_ms',
        ])
          key: object(raw['summary'])[key] is num
              ? object(raw['summary'])[key] as num
              : null,
      };
}

class AuditEvent {
  final String? id,
      occurredAt,
      actor,
      action,
      target,
      reason,
      result,
      correlation;
  final bool? beforeEnabled, afterEnabled;
  final String? beforeState,
      afterState,
      beforeStatus,
      afterStatus,
      beforeExpiry,
      afterExpiry;
  static String? _code(Object? value, List<String> allowed) =>
      allowed.contains(value) ? value as String : null;
  static String? _expiry(Object? value) =>
      value is String && DateTime.tryParse(value) != null ? value : null;
  AuditEvent(Json raw)
    : id = text(raw['id']),
      occurredAt = text(raw['occurred_at']),
      actor = text(raw['admin_actor']),
      action = text(raw['action_type']),
      target = text(raw['target_id']),
      reason =
          raw['reason'] is String &&
              (raw['reason'] as String).runes.length <= 500
          ? raw['reason'] as String
          : null,
      result = text(raw['result']),
      correlation = text(raw['correlation_id']),
      beforeEnabled = object(raw['safe_before'])['enabled'] is bool
          ? object(raw['safe_before'])['enabled']
          : null,
      beforeState = _code(object(raw['safe_before'])['state'], [
        'ACTIVE',
        'RESTRICTED',
        'SUSPENDED',
      ]),
      afterState = _code(object(raw['safe_after'])['state'], [
        'ACTIVE',
        'RESTRICTED',
        'SUSPENDED',
      ]),
      beforeStatus = _code(object(raw['safe_before'])['status'], [
        'pending',
        'reviewed',
        'actioned',
        'dismissed',
      ]),
      afterStatus = _code(object(raw['safe_after'])['status'], [
        'pending',
        'reviewed',
        'actioned',
        'dismissed',
      ]),
      beforeExpiry = _expiry(object(raw['safe_before'])['expires_at']),
      afterExpiry = _expiry(object(raw['safe_after'])['expires_at']),
      afterEnabled = object(raw['safe_after'])['enabled'] is bool
          ? object(raw['safe_after'])['enabled']
          : null;
}

class AuditCursor {
  final String before, beforeId;
  const AuditCursor(this.before, this.beforeId);
}

class AuditPage extends AdminData {
  final List<AuditEvent> events;
  final AuditCursor? next;
  AuditPage(Json raw)
    : events = rows(raw['events'], 100).map(AuditEvent.new).toList(),
      next =
          text(raw['next_before']) != null &&
              text(raw['next_before_id']) != null
          ? AuditCursor(text(raw['next_before'])!, text(raw['next_before_id'])!)
          : null;
}

class UserDetail extends AdminData {
  final bool found;
  final UserMetadata user;
  final AppSignal? latestSignal;
  final AiObservation ai;
  final List<AuditEvent> audit;
  UserDetail(Json raw)
    : found = raw['found'] == true,
      user = UserMetadata(object(raw['user'])),
      latestSignal = raw['latest_app_signal'] is Map
          ? AppSignal(object(raw['latest_app_signal']))
          : null,
      ai = AiObservation(object(raw['ai'])),
      audit = rows(raw['audit'], 10).map(AuditEvent.new).toList();
}

enum HealthState { healthy, degraded, incident, unknown }

HealthState healthState(Object? raw) => HealthState.values.firstWhere(
  (s) => s.name == raw,
  orElse: () => HealthState.unknown,
);

class HealthSection {
  final HealthState state;
  final String? signal, reconciliation, execution, expectedContract;
  final Map<String, int?> counts;
  final AiObservation? ai;
  final AiControl? control;
  HealthSection(Json raw)
    : state = healthState(raw['state']),
      signal = text(raw['signal']),
      reconciliation = text(raw['reconciliation']),
      execution = text(raw['execution']),
      expectedContract = text(raw['expected_contract']),
      counts = {
        for (final key in ['sent', 'failed', 'invalid_token', 'old_sending'])
          key: count(object(raw['counts'])[key]),
      },
      control = raw['control'] is Map
          ? AiControl(object(raw['control']))
          : null,
      ai = raw['observations'] is Map
          ? AiObservation(object(raw['observations']))
          : null;
}

class SystemHealth extends AdminData {
  final HealthState state;
  final Map<String, HealthSection> sections;
  SystemHealth(Json raw)
    : state = healthState(raw['state']),
      sections = {
        for (final key in [
          'database',
          'schema',
          'push',
          'ai',
          'retention',
          'sync',
          'errors',
        ])
          key: HealthSection(object(raw[key])),
      };
}

class ReleaseGroup {
  final String? platform, version, build, firstSeen, lastSeen;
  final int? installations, accounts;
  ReleaseGroup(Json raw)
    : platform = text(raw['platform']),
      version = text(raw['app_version']),
      build = text(raw['build_number']),
      firstSeen = text(raw['first_seen']),
      lastSeen = text(raw['last_seen']),
      installations = count(raw['installations']),
      accounts = count(raw['accounts']);
}

class Releases extends AdminData {
  final bool available, truncated;
  final int? days;
  final String? reason;
  final List<ReleaseGroup> groups;
  final List<ReleasePolicyData> policies;
  Releases(Json raw)
    : available = raw['availability'] == 'available',
      truncated = raw['groups_truncated'] == true,
      days = count(raw['window_days']),
      reason = text(raw['reason']),
      groups = rows(raw['groups'], 100).map(ReleaseGroup.new).toList(),
      policies = rows(raw['policies'], 2).map(ReleasePolicyData.new).toList();
}

class ReleasePolicyData {
  final String platform;
  final String? latestVersion, minimumVersion, storeUrl;
  final int? latestBuild, minimumBuild;
  final bool published;
  final int revision;
  ReleasePolicyData(Json raw)
    : platform = raw['platform'] as String,
      latestVersion = raw['latest_version'] as String?,
      latestBuild = raw['latest_build'] as int?,
      minimumVersion = raw['minimum_version'] as String?,
      minimumBuild = raw['minimum_build'] as int?,
      storeUrl = raw['store_url'] as String?,
      published = raw['published'] as bool,
      revision = raw['revision'] as int {
    if (!['android', 'ios'].contains(platform) || revision < 1) {
      throw const FormatException('invalid_release_policy');
    }
  }
  Map<String, Object?> toMap() => {
    'platform': platform,
    'latest_version': latestVersion,
    'latest_build': latestBuild,
    'minimum_version': minimumVersion,
    'minimum_build': minimumBuild,
    'store_url': storeUrl,
    'published': published,
    'revision': revision,
  };
}

class AbuseCounterObservation {
  final int? hourCount, dayCount;
  final String? hourStart, utcDay;
  AbuseCounterObservation(Object? raw)
    : hourCount = _count(object(raw)['hour_count']),
      dayCount = _count(object(raw)['day_count']),
      hourStart = _timestamp(object(raw)['hour_start']),
      utcDay = _day(object(raw)['utc_day']);
  bool get available =>
      hourCount != null &&
      dayCount != null &&
      hourStart != null &&
      utcDay != null;
  static int? _count(Object? raw) =>
      raw is int && raw >= 0 && raw <= 2147483647 ? raw : null;
  static String? _day(Object? raw) {
    if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      return null;
    }
    final date = DateTime.tryParse(raw);
    return date != null && date.toIso8601String().substring(0, 10) == raw
        ? raw
        : null;
  }

  static String? _timestamp(Object? raw) {
    if (raw is! String ||
        raw.length > 40 ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$',
        ).hasMatch(raw) ||
        _day(raw.substring(0, 10)) == null ||
        DateTime.tryParse(raw) == null) {
      return null;
    }
    return raw;
  }
}

class ModerationReport {
  final String? id,
      status,
      reason,
      targetId,
      reporterId,
      targetUsername,
      contextType,
      workspaceId,
      invitationId,
      createdAt,
      resolvedAt,
      state,
      explanation,
      expiresAt;
  final Json reporter, target, priorReports;
  final AbuseCounterObservation invitationQuota, reportQuota;
  final List<AuditEvent> audit;
  final bool ownerTarget;
  final String? entityType, entityId, evidenceTitle, channel, responseText;
  ModerationReport(Json value)
    : entityType = text(value['entity_type']),
      entityId = text(value['entity_id']),
      evidenceTitle =
          value['evidence_title'] is String &&
              (value['evidence_title'] as String).runes.length <= 200
          ? value['evidence_title'] as String
          : null,
      channel = text(value['channel']),
      responseText =
          value['response_text'] is String &&
              (value['response_text'] as String).runes.length <= 1000
          ? value['response_text'] as String
          : null,
      invitationQuota = AbuseCounterObservation(value['invitation_quota']),
      reportQuota = AbuseCounterObservation(value['report_quota']),
      id = text(value['id']),
      status = text(value['status']),
      reason = text(value['reason']),
      targetId = text(value['target_id']),
      reporterId = text(value['reporter_id']),
      targetUsername = text(value['target_username']),
      contextType = text(value['context_type']),
      workspaceId = text(value['workspace_id']),
      invitationId = text(value['invitation_id']),
      createdAt = text(value['created_at']),
      resolvedAt = text(value['resolved_at']),
      state = text(value['state']),
      explanation =
          value['explanation'] is String &&
              (value['explanation'] as String).runes.length <= 500
          ? value['explanation'] as String
          : null,
      expiresAt = text(value['expires_at']),
      ownerTarget = value['owner_target'] == true,
      reporter = _identity(value['reporter']),
      target = _identity(value['target']),
      priorReports = {
        for (final key in ['total', 'open'])
          key: count(object(value['prior_reports'])[key]),
      },
      audit = rows(value['audit'], 50).map(AuditEvent.new).toList();
  static Json _identity(Object? raw) => {
    for (final key in ['id', 'first_name', 'last_name', 'username'])
      key: text(object(raw)[key]),
  };
}

class ModerationPage extends AdminData {
  final List<ModerationReport> reports;
  final int? nextOffset;
  ModerationPage(Json value)
    : reports = rows(value['reports'], 100).map(ModerationReport.new).toList(),
      nextOffset = count(value['next_offset']);
}

class ModerationDetail extends AdminData {
  final ModerationReport report;
  ModerationDetail(Json value) : report = ModerationReport(value);
}

class AiControl extends AdminData {
  static const limitNames = [
    'text_minute_limit',
    'text_day_limit',
    'text_month_limit',
    'audio_minute_ms_limit',
    'audio_day_ms_limit',
    'audio_month_ms_limit',
  ];
  final bool? enabled;
  final bool configured, exhausted;
  final String? status;
  final Map<String, int?> limits;
  final List<int?> textAttempts, audioAttempts, audioMs;
  final List<String?> windows;
  AiControl(Json raw)
    : enabled = raw['enabled'] is bool ? raw['enabled'] : null,
      configured = raw['configured'] == true,
      exhausted = raw['exhausted'] == true,
      status =
          [
            'available',
            'ai_disabled',
            'global_rate_limited',
            'provider_unavailable',
          ].contains(raw['status'])
          ? raw['status'] as String
          : null,
      limits = {
        for (final key in limitNames) key: count(object(raw['limits'])[key]),
      },
      textAttempts = _counts(raw['text_attempts']),
      audioAttempts = _counts(raw['audio_attempts']),
      audioMs = _counts(raw['audio_ms']),
      windows = raw['windows'] is List
          ? (raw['windows'] as List)
                .take(3)
                .map(
                  (v) => v is String && DateTime.tryParse(v) != null ? v : null,
                )
                .toList()
          : [];
  static List<int?> _counts(Object? raw) =>
      raw is List ? raw.take(3).map(count).toList() : [];
  String get monetaryCost => 'UNAVAILABLE';
}

class ServiceNoticesData extends AdminData {
  final bool available;
  final List<Json> notices;
  ServiceNoticesData(Json raw)
    : available =
          raw['version'] == 1 &&
          raw['available'] == true &&
          raw['pushAvailable'] == false,
      notices = raw['version'] == 1
          ? rows(raw['notices'], 20)
                .map(
                  (r) => <String, dynamic>{
                    for (final key in [
                      'id',
                      'revision',
                      'titleRu',
                      'messageRu',
                      'titleEn',
                      'messageEn',
                      'startsAt',
                      'endsAt',
                      'displayLimit',
                    ])
                      if (r.containsKey(key)) key: r[key],
                  },
                )
                .toList()
          : [];
}
