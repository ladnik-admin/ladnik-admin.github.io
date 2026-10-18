import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';
import 'common.dart';

class SubscriptionsView extends StatefulWidget {
  final Subscriptions data;
  final AdminController controller;
  const SubscriptionsView(this.data, this.controller, {super.key});
  @override
  State<SubscriptionsView> createState() => _SubscriptionsViewState();
}

class _SubscriptionsViewState extends State<SubscriptionsView> {
  final target = TextEditingController();
  bool teamTarget = false;
  String? error;
  @override
  void dispose() {
    target.dispose();
    super.dispose();
  }

  Future<void> edit(
    String command,
    Json values,
    int revision, {
    String? id,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SubscriptionEditor(
        widget.controller.api,
        command,
        values,
        revision,
        id: id,
        controller: widget.controller,
      ),
    );
    if (result == true && mounted) {
      final detail = widget.data.detail;
      final user = text(detail['user_id']), team = text(detail['id']);
      if (!widget.data.overview && (user ?? team) != null) {
        await widget.controller.showSubscription(
          (user ?? team)!,
          team: user == null,
        );
      } else {
        await widget.controller.select(Section.subscriptions);
      }
    }
  }

  Widget scope(
    Json value, {
    bool detail = false,
  }) => panel(value['name'] ?? value['user_id'] ?? 'Subscription', [
    for (final key in [
      'id',
      'owner_id',
      'plan',
      'active',
      'read_only',
      'members_used',
      'workspaces_used',
      'over_seat_limit',
      'over_workspace_limit',
      'expires_at',
    ])
      if (value[key] != null) fact(key.replaceAll('_', ' '), value[key]),
    fact(
      'Sources',
      (value['sources'] as List).isEmpty
          ? 'Free default'
          : (value['sources'] as List)
                .map((s) => s == 'admin' ? 'Provided by LADNIK' : s)
                .join(', '),
    ),
    for (final entry in object(value['limits']).entries)
      if (entry.value != null) fact(entry.key, entry.value),
    fact('Store readiness', commercialStoreReadiness(value['billing_status'])),
    if (object(value['ai_policy'])['configured'] == true ||
        object(value['ai_policy'])['accounting_configured'] == true) ...[
      fact(
        'AI used %',
        commercialAiPercentage(object(value['ai_policy'])) ??
            (object(value['ai_policy'])['pending_reconciliation'] == true ||
                    object(value['ai_policy'])['coverage'] == 'pending'
                ? 'Pending reconciliation'
                : 'Unavailable'),
      ),
      fact('AI resets', object(value['ai_policy'])['reset_at']),
      fact('AI tracking since', object(value['ai_policy'])['tracking_since']),
    ] else
      const Text('AI accounting unavailable for this scope.'),
    for (final source in rows(value['store_sources'], 100)) ...[
      fact(
        'Store source',
        '${source['provider']} / ${source['plan']} / ${source['period']}',
      ),
      fact('Store state', source['state']),
      fact('Access until', source['access_until']),
      fact('Auto renew', source['auto_renew'] ?? 'Unknown'),
      if (source['custody_blocked'] == true)
        const Text('Custody incident: payment binding needs reconciliation.'),
    ],
    if (object(value['activation'])['state'] != null) ...[
      for (final entry in object(value['activation']).entries)
        fact(entry.key, entry.value),
    ],
    if (!detail && value['id'] != null)
      TextButton(
        onPressed: () =>
            widget.controller.showSubscription(value['id'], team: true),
        child: const Text('View Team'),
      ),
  ]);
  @override
  Widget build(BuildContext context) {
    final data = widget.data, detail = data.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Monetization enforcement: ${data.enforcementEnabled ? 'ON' : 'OFF'}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text(
          'Store billing requires separate operator acceptance. Revenue / MRR: Unavailable.',
        ),
        Text(
          'Team creation: ${data.teamCreationEnabled == null
              ? 'Unavailable'
              : data.teamCreationEnabled!
              ? 'ON'
              : 'OFF'}. Lifecycle acceptance required; no activation control is available.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                controller: target,
                decoration: const InputDecoration(
                  labelText: 'Exact user / Team UUID',
                ),
              ),
            ),
            SizedBox(
              width: 160,
              child: CheckboxListTile(
                value: teamTarget,
                onChanged: (v) => setState(() => teamTarget = v!),
                title: const Text('Team'),
              ),
            ),
            FilledButton(
              onPressed: () {
                if (!validUserId(target.text.trim())) {
                  setState(() => error = 'Enter an exact UUID.');
                  return;
                }
                setState(() => error = null);
                widget.controller.showSubscription(
                  target.text.trim(),
                  team: teamTarget,
                );
              },
              child: const Text('Inspect'),
            ),
            TextButton(
              onPressed: () => widget.controller.select(Section.subscriptions),
              child: const Text('Overview'),
            ),
          ],
        ),
        if (error != null) Text(error!),
        const SizedBox(height: 16),
        if (data.overview) ...[
          panel('Subscription overview', [
            for (final entry in data.counters.entries)
              fact(entry.key, entry.value),
            if (!data.aggregatesAvailable)
              const Text(
                'Account aggregates unavailable: bounded query budget.',
              ),
            OutlinedButton(
              onPressed: data.controlRevision < 1
                  ? null
                  : () => edit('enforcement.set', {
                      'enabled': data.enforcementEnabled,
                    }, data.controlRevision),
              child: const Text('Edit enforcement'),
            ),
          ]),
          for (final policy in data.policies)
            panel('${policy['plan']} server policy', [
              for (final entry in object(policy['limits']).entries)
                if (entry.value != null) fact(entry.key, entry.value),
              OutlinedButton(
                key: ValueKey('policy-${policy['plan']}'),
                onPressed: () => edit('policy.set', {
                  'plan': policy['plan'],
                  'limits': policy['limits'],
                }, policy['revision']),
                child: const Text('Edit server policy'),
              ),
            ]),
          if (data.teams.isEmpty) const Text('No Teams returned.'),
          for (final team in data.teams) scope(team),
          if (data.teamsTruncated)
            const Text(
              'First 50 Teams shown. Inspect an exact Team UUID for other Teams.',
            ),
        ] else ...[
          scope(detail, detail: true),
          FilledButton(
            onPressed: () => edit(
              'grant.set',
              {
                'plan': detail['user_id'] == null ? 'TEAM' : 'PRO',
                'user_id': detail['user_id'],
                'team_id': detail['id'],
                'starts_at': DateTime.now().toUtc().toIso8601String(),
                'expires_at': DateTime.now()
                    .toUtc()
                    .add(const Duration(days: 90))
                    .toIso8601String(),
                'internal_note': '',
                'limits': commercialLimits({}),
                'revoked': false,
              },
              0,
              id: const Uuid().v4(),
            ),
            child: const Text('Grant complimentary access'),
          ),
          for (final team in data.teams) scope(team),
          const SizedBox(height: 16),
          const Text('Grant history · Provided by LADNIK'),
          if (data.grants.isEmpty) const Text('No admin grants.'),
          for (final grant in data.grants)
            panel(
              '${grant.personalOverride ? 'FREE personal override' : grant.values['plan']} · ${grant.id}',
              [
                fact('Starts', grant.values['starts_at']),
                fact('Expires', grant.values['expires_at'] ?? 'No expiry'),
                fact('Revoked', grant.values['revoked']),
                fact('Status', grant.status),
                fact('Reason', grant.reason),
                for (final entry in object(grant.values['limits']).entries)
                  if (entry.value != null) fact(entry.key, entry.value),
                TextButton(
                  onPressed: () => edit(
                    'grant.set',
                    grant.values,
                    grant.revision,
                    id: grant.id,
                  ),
                  child: const Text('Edit / extend / restore defaults'),
                ),
                TextButton(
                  onPressed: grant.values['revoked'] == true
                      ? null
                      : () => edit(
                          'grant.set',
                          {...grant.values, 'revoked': true},
                          grant.revision,
                          id: grant.id,
                        ),
                  child: const Text('Revoke'),
                ),
              ],
            ),
          if (data.grantsTruncated)
            const Text('Grant history truncated to the newest 25 grants.'),
          if (data.teamsTruncated)
            const Text(
              'First 50 Teams shown. Inspect exact UUID for other Teams.',
            ),
        ],
        const SizedBox(height: 16),
        const Text('Monetization audit · immutable'),
        if (data.audit.isEmpty)
          const Text('No monetization audit entries returned.'),
        for (final event in data.audit)
          panel('${event['action']} · ${event['occurred_at']}', [
            for (final key in [
              'id',
              'actor',
              'target_user',
              'target_team',
              'reason',
              'correlation_id',
              'result',
            ])
              if (event[key] != null) fact(key, event[key]),
            for (final key in [
              'plan',
              'user_id',
              'team_id',
              'starts_at',
              'expires_at',
              'revision',
              'enabled',
              'revoked',
            ])
              if (object(event['before'])[key] != null ||
                  object(event['after'])[key] != null)
                fact(
                  key,
                  '${object(event['before'])[key]} → ${object(event['after'])[key]}',
                ),
            for (final name in commercialLimitNames)
              if (object(object(event['before'])['limits'])[name] != null ||
                  object(object(event['after'])['limits'])[name] != null)
                fact(
                  name,
                  '${object(object(event['before'])['limits'])[name]} → ${object(object(event['after'])['limits'])[name]}',
                ),
          ]),
        if (data.auditTruncated)
          const Text('Newest 10 monetization audit events shown.'),
      ],
    );
  }
}

class SubscriptionEditor extends StatefulWidget {
  final ControlApi api;
  final AdminController? controller;
  final String command;
  final Json initial;
  final int revision;
  final String? id;
  const SubscriptionEditor(
    this.api,
    this.command,
    this.initial,
    this.revision, {
    super.key,
    this.id,
    this.controller,
  });
  @override
  State<SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<SubscriptionEditor> {
  final reason = TextEditingController();
  final correlation = const Uuid().v4();
  late final TextEditingController scopeId, starts, expires, note;
  late final Map<String, TextEditingController> fields;
  late String plan;
  late bool enabled, revoked, noExpiry;
  bool busy = false, confirmed = false;
  Json? draft, preview;
  String? error;
  String? _actor;
  bool _retired = false;
  bool get currentOwnerContext =>
      !_retired &&
      (widget.controller == null ||
          widget.controller!.actorId == _actor &&
              widget.controller!.access == Access.ready);

  void _identityChanged() {
    final controller = widget.controller!;
    if (_retired) return;
    setState(() {
      if (controller.actorId != _actor ||
          !controller.signedIn ||
          controller.access == Access.forbidden) {
        _retired = true;
        preview = draft = null;
        confirmed = busy = false;
      }
    });
  }

  bool get grant => widget.command == 'grant.set';
  bool get policy => widget.command == 'policy.set';
  List<String> get names => [
    if (plan == 'TEAM') ...[
      'team_workspace_limit',
      'seat_limit',
    ] else ...[
      'owned_cloud_limit',
      'owned_shared_limit',
      'shared_member_limit',
    ],
    'automation_limit',
    'ai_budget_micro_usd',
    if (grant) 'ai_multiplier_bps',
  ];
  @override
  void initState() {
    super.initState();
    _actor = widget.controller?.actorId;
    _retired = widget.controller != null && _actor == null;
    widget.controller?.addListener(_identityChanged);
    plan = widget.initial['plan'] ?? 'PRO';
    enabled = widget.initial['enabled'] == true;
    revoked = widget.initial['revoked'] == true;
    noExpiry = widget.initial['expires_at'] == null;
    scopeId = TextEditingController(
      text: widget.initial['user_id'] ?? widget.initial['team_id'] ?? '',
    );
    starts = TextEditingController(text: widget.initial['starts_at'] ?? '');
    expires = TextEditingController(text: widget.initial['expires_at'] ?? '');
    note = TextEditingController(text: widget.initial['internal_note'] ?? '');
    fields = {
      for (final k in commercialLimitNames)
        k: TextEditingController(
          text: object(widget.initial['limits'])[k]?.toString() ?? '',
        ),
    };
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_identityChanged);
    for (final f in [
      reason,
      scopeId,
      starts,
      expires,
      note,
      ...fields.values,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> review() async {
    if (!currentOwnerContext || busy) return;
    try {
      if (reason.text.trim().isEmpty || reason.text.trim().runes.length > 500) {
        throw const FormatException();
      }
      final limits = <String, dynamic>{};
      for (final k in commercialLimitNames.where(
        (k) => grant || k != 'ai_multiplier_bps',
      )) {
        final value = names.contains(k) ? fields[k]!.text.trim() : '';
        final number = value.isEmpty ? null : int.parse(value);
        if (number != null &&
            (number <
                    ([
                          'owned_shared_limit',
                          'automation_limit',
                          'ai_budget_micro_usd',
                        ].contains(k)
                        ? 0
                        : 1) ||
                number >
                    (k == 'ai_budget_micro_usd' ? 1000000000000 : 100000))) {
          throw const FormatException();
        }
        if (policy && names.contains(k) && number == null) {
          throw const FormatException();
        }
        limits[k] = number;
      }
      draft = grant
          ? {
              'plan': plan,
              'user_id': plan != 'TEAM' ? scopeId.text.trim() : null,
              'team_id': plan == 'TEAM' ? scopeId.text.trim() : null,
              'starts_at': DateTime.parse(starts.text.trim())
                  .toUtc()
                  .toIso8601String(),
              'expires_at': noExpiry
                  ? null
                  : DateTime.parse(expires.text.trim())
                        .toUtc()
                        .toIso8601String(),
              'internal_note': note.text,
              'limits': limits,
              'revoked': revoked,
            }
          : policy
          ? {'plan': plan, 'limits': limits}
          : {'enabled': enabled};
      if (grant && !validUserId(scopeId.text.trim())) {
        throw const FormatException();
      }
      setState(() {
        busy = true;
        error = null;
      });
      final result = await widget.api.changeSubscription(
        command: widget.command,
        target: widget.id,
        revision: widget.revision,
        values: draft!,
        reason: reason.text,
        correlation: correlation,
        preview: true,
      );
      if (result['preview'] != true) throw const FormatException();
      if (!currentOwnerContext) {
        if (mounted) setState(() => busy = false);
        return;
      }
      if (mounted) {
        setState(() {
          preview = result;
          busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          if (currentOwnerContext) {
            error = 'Preview unavailable. Check target, dates, typed limits and required reason.';
          }
        });
      }
    }
  }

  Future<void> submit() async {
    if (!currentOwnerContext ||
        busy ||
        !confirmed ||
        preview == null ||
        draft == null) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.changeSubscription(
        command: widget.command,
        target: widget.id,
        revision: widget.revision,
        values: draft!,
        reason: reason.text,
        correlation: correlation,
        preview: false,
      );
      if (!validUserId(text(result['audit_id'])) ||
          result['replayed'] is! bool ||
          result['preview'] == true) {
        throw const FormatException();
      }
      if (!currentOwnerContext) {
        if (mounted) setState(() => busy = false);
        return;
      }
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on AdminException catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          if (currentOwnerContext) {
            error = failure.failure == AdminFailure.conflict
                ? 'Revision changed. Cancel, inspect again and review a new change.'
                : 'Change not confirmed. Retry this confirmation with the same request ID.';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          if (currentOwnerContext) {
            error = 'Change not confirmed. Retry this confirmation.';
          }
        });
      }
    }
  }

  Widget field(TextEditingController c, String label, {int max = 200}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          maxLength: max,
          decoration: InputDecoration(labelText: label),
        ),
      );
  @override
  Widget build(BuildContext context) {
    if (_retired) {
      return AlertDialog(
        title: const Text('Sign-in context changed'),
        content: const Text(
          'Close this dialog and reopen Subscriptions for the current account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
        ],
      );
    }
    return _buildEditor(context);
  }

  Widget _buildEditor(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        preview == null
            ? 'Edit ${widget.command}'
            : 'Confirm subscription change',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (preview == null) ...[
                if (grant) ...[
                  DropdownButtonFormField<String>(
                    initialValue: plan,
                    items: ['FREE', 'PRO', 'TEAM']
                        .map(
                          (p) => DropdownMenuItem(
                            value: p,
                            child: Text(
                              p == 'FREE' ? 'FREE personal override' : p,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: busy ? null : (v) => setState(() => plan = v!),
                    decoration: const InputDecoration(
                      labelText: 'Grant plan / scope',
                    ),
                  ),
                  field(
                    scopeId,
                    'Exact ${plan == 'TEAM' ? 'Team' : 'user'} UUID',
                  ),
                  if (plan == 'FREE')
                    const Text(
                      'Personal typed override · Provided by LADNIK. Effective plan stays Free unless another source grants Pro.',
                    ),
                  field(starts, 'Starts at (ISO UTC)'),
                  DropdownButtonFormField<int>(
                    items: [7, 30, 90, 365]
                        .map(
                          (d) => DropdownMenuItem(
                            value: d,
                            child: Text(d == 365 ? '1 year' : '$d days'),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (d) => setState(() {
                            noExpiry = false;
                            expires.text = DateTime.now()
                                .toUtc()
                                .add(Duration(days: d!))
                                .toIso8601String();
                          }),
                    decoration: const InputDecoration(
                      labelText: 'Expiry preset',
                    ),
                  ),
                  CheckboxListTile(
                    value: noExpiry,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => noExpiry = v!),
                    title: const Text('No expiry'),
                  ),
                  if (!noExpiry)
                    field(expires, 'Expires at (arbitrary ISO UTC)'),
                  field(note, 'Internal note', max: 1000),
                  CheckboxListTile(
                    value: revoked,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => revoked = v!),
                    title: const Text('Revoke grant'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            for (final f in fields.values) {
                              f.clear();
                            }
                          }),
                    child: const Text('Restore default limits'),
                  ),
                ],
                if (grant || policy) ...[
                  const Text(
                    'Typed server limits. Grant overrides enhance defaults; lower values do not reduce other active allowances. Empty values inherit defaults. AI uses integer micro-USD; multiplier uses basis points (10000 = 1×).',
                  ),
                  for (final name in names) field(fields[name]!, name, max: 13),
                ] else
                  SwitchListTile(
                    value: enabled,
                    onChanged: busy ? null : (v) => setState(() => enabled = v),
                    title: const Text('Enable monetization enforcement'),
                  ),
                field(reason, 'Required reason', max: 500),
              ] else ...[
                const Text(
                  'Server impact preview: writeability and limits are re-evaluated. No data or members are deleted. No Store charge is made.',
                ),
                if (widget.command == 'enforcement.set' && enabled)
                  const Text(
                    'Enforcement ON will block commercial writes in excess/inactive scopes.',
                  ),
                for (final key in [
                  'plan',
                  'user_id',
                  'team_id',
                  'starts_at',
                  'expires_at',
                  'revoked',
                  'enabled',
                ])
                  if (draft!.containsKey(key))
                    fact(
                      key,
                      '${object(preview!['before'])[key]} → ${draft![key]}',
                    ),
                for (final name in names)
                  if (grant || policy)
                    fact(
                      name,
                      '${object(object(preview!['before'])['limits'])[name]} → ${object(draft!['limits'])[name]}',
                    ),
                fact('Expected revision', widget.revision),
                fact('Reason', reason.text.trim()),
                CheckboxListTile(
                  value: confirmed,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => confirmed = v!),
                  title: const Text('I confirm this impact'),
                ),
              ],
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        if (preview == null)
          FilledButton(
            onPressed: busy || !currentOwnerContext ? null : review,
            child: const Text('Review impact'),
          ),
        if (preview != null)
          FilledButton(
            onPressed: busy || !confirmed || !currentOwnerContext
                ? null
                : submit,
            child: const Text('Confirm change'),
          ),
      ],
    ),
  );
}
