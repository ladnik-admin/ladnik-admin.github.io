import 'package:flutter/material.dart';

import '../models.dart';
import '../controller.dart';
import '../api.dart';

import 'package:uuid/uuid.dart';

import 'common.dart';

class ReleasesView extends StatelessWidget {
  final Releases data;
  final AdminController? controller;
  const ReleasesView(this.data, {super.key, this.controller});
  Future<void> edit(BuildContext context, ReleasePolicyData policy) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReleasePolicyEditor(policy, controller!),
    );
    if (changed == true) await controller!.select(Section.releases);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final policy in data.policies)
        panel('${policy.platform} release policy', [
          fact(
            'Latest',
            '${policy.latestVersion ?? 'Unset'} + ${policy.latestBuild ?? 'Unset'}',
          ),
          fact(
            'Minimum supported',
            '${policy.minimumVersion ?? 'Unset'} + ${policy.minimumBuild ?? 'Unset'}',
          ),
          fact('Store URL', policy.storeUrl),
          fact('Published', policy.published),
          fact('Revision', policy.revision),
          if (controller != null)
            OutlinedButton(
              key: ValueKey('edit-release-${policy.platform}'),
              onPressed: () => edit(context, policy),
              child: const Text('Edit policy'),
            ),
        ]),
      const Text(
        'self-reported heartbeat',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      if (data.days != null) fact('Observation window (days)', data.days),
      if (!data.available) ...[
        const Text('Release telemetry unavailable.'),
        if (data.reason != null) fact('Reason', data.reason),
      ] else ...[
        if (data.groups.isEmpty) const Text('No release groups returned.'),
        for (final group in data.groups)
          panel(group.platform ?? 'Platform unavailable', [
            fact('App version', group.version),
            fact('Build', group.build),
            fact('Installation count', group.installations),
            fact('Account count', group.accounts),
            fact('First observed', group.firstSeen),
            fact('Last observed', group.lastSeen),
          ]),
        if (data.truncated)
          const Text('Only the first 100 release groups are returned.'),
      ],
    ],
  );
}

class _ReleasePolicyEditor extends StatefulWidget {
  final ReleasePolicyData policy;
  final AdminController controller;
  const _ReleasePolicyEditor(this.policy, this.controller);
  @override
  State<_ReleasePolicyEditor> createState() => _ReleasePolicyEditorState();
}

class _ReleasePolicyEditorState extends State<_ReleasePolicyEditor> {
  late final Map<String, TextEditingController> fields;
  final reason = TextEditingController();
  final correlation = const Uuid().v4();
  late bool published;
  bool confirming = false, confirmed = false, busy = false;
  ReleasePolicyData? draft;
  String? error;
  @override
  void initState() {
    super.initState();
    published = widget.policy.published;
    fields = {
      for (final key in [
        'latest_version',
        'latest_build',
        'minimum_version',
        'minimum_build',
        'store_url',
      ])
        key: TextEditingController(
          text: widget.policy.toMap()[key]?.toString() ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    reason.dispose();
    super.dispose();
  }

  void summarize() {
    try {
      final payload = <String, Object?>{
        ...widget.policy.toMap(),
        'published': published,
      };
      for (final entry in fields.entries) {
        final value = entry.value.text.trim();
        payload[entry.key] = value.isEmpty
            ? null
            : entry.key.endsWith('_build')
            ? int.parse(value)
            : value;
      }
      if (reason.text.trim().isEmpty || reason.text.runes.length > 500) {
        throw const FormatException();
      }
      draft = ReleasePolicyData(payload);
      setState(() {
        confirming = true;
        error = null;
      });
    } catch (_) {
      setState(() => error = 'Check version/build values and enter a reason.');
    }
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.controller.api.setReleasePolicy(
        draft!,
        reason.text,
        correlation,
      );
      if (!result.containsKey('audit_id')) throw const FormatException();
      if (mounted) Navigator.pop(context, true);
    } on AdminException catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = failure.failure == AdminFailure.conflict
              ? 'Revision changed. Cancel, refresh policy and review again.'
              : 'Change not confirmed. Check policy values or retry this confirmation.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Change not confirmed. Retry or refresh the policy.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        '${confirming ? 'Confirm' : 'Edit'} ${widget.policy.platform} release policy',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!confirming) ...[
                for (final entry in fields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: entry.value,
                      maxLength: entry.key == 'store_url' ? 500 : 20,
                      decoration: InputDecoration(
                        labelText: entry.key.replaceAll('_', ' '),
                      ),
                    ),
                  ),
                CheckboxListTile(
                  value: published,
                  onChanged: (value) => setState(() => published = value!),
                  title: const Text(
                    'Published: Store availability confirmed by owner',
                  ),
                ),
                TextField(
                  controller: reason,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Required reason',
                  ),
                ),
              ] else ...[
                const Text(
                  'Impact: below minimum version/build, ordinary product interaction is blocked. Below latest, supported devices receive an optional update. Required cached policy expires after 24 hours offline.',
                ),
                for (final key in [
                  'latest_version',
                  'latest_build',
                  'minimum_version',
                  'minimum_build',
                  'store_url',
                  'published',
                ])
                  fact(
                    key,
                    '${widget.policy.toMap()[key]} → ${draft!.toMap()[key]}',
                  ),
                fact('Expected revision', widget.policy.revision),
                fact('Reason', reason.text.trim()),
                CheckboxListTile(
                  value: confirmed,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => confirmed = value!),
                  title: const Text(
                    'I confirm this impact and Store availability when published',
                  ),
                ),
              ],
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
        if (!confirming)
          FilledButton(
            onPressed: summarize,
            child: const Text('Review impact'),
          ),
        if (confirming)
          FilledButton(
            onPressed: busy || !confirmed ? null : submit,
            child: const Text('Confirm policy change'),
          ),
      ],
    ),
  );
}
