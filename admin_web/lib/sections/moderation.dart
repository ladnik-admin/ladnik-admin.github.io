import 'common.dart';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';

class ModerationQueueView extends StatelessWidget {
  final ModerationPage page;
  final AdminController controller;
  const ModerationQueueView(this.page, this.controller, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Moderation queue', style: TextStyle(fontSize: 24)),
      DropdownButton<String>(
        value: controller.moderationStatus ?? 'all',
        items: [
          for (final status in [
            'all',
            'pending',
            'reviewed',
            'actioned',
            'dismissed',
          ])
            DropdownMenuItem(value: status, child: Text(status)),
        ],
        onChanged: (value) =>
            controller.filterReports(value == 'all' ? null : value),
      ),
      for (final report in page.reports)
        ListTile(
          title: Text(
            '${report.status} · ${report.reason} · ${report.targetUsername ?? report.targetId ?? 'Deleted account'}',
          ),
          subtitle: Text(
            '${report.createdAt} · ${report.state ?? 'Unavailable'}',
          ),
          onTap: report.id == null
              ? null
              : () => controller.showReport(report.id!),
        ),
      if (page.reports.isEmpty) const Text('No reports in this queue.'),
      if (page.nextOffset != null)
        TextButton(
          onPressed: controller.nextReports,
          child: const Text('Next page'),
        ),
    ],
  );
}

class ModerationDetailView extends StatelessWidget {
  final ModerationDetail detail;
  final AdminController controller;
  const ModerationDetailView(this.detail, this.controller, {super.key});
  static Widget _counter(String label, AbuseCounterObservation value) => Text(
    value.available
        ? '$label: Hour: ${value.hourCount} · Day: ${value.dayCount} · Hour bucket: ${value.hourStart} · UTC day: ${value.utcDay}'
        : '$label: Unavailable',
  );
  Future<void> mutate(BuildContext context, String action) async {
    final succeeded = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ModerationConfirmation(
        controller: controller,
        report: detail.report,
        action: action,
      ),
    );
    if (succeeded == true && context.mounted) {
      await controller.showReport(detail.report.id!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = detail.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(
          onPressed: () => controller.select(Section.moderation),
          child: const Text('Back to queue'),
        ),
        const Text('Report detail', style: TextStyle(fontSize: 24)),
        Text('Report: ${r.id}'),
        Text('Status: ${r.status} · Reason: ${r.reason}'),
        Text('Created: ${r.createdAt} · Resolved: ${r.resolvedAt ?? 'Open'}'),
        Text(
          'Reporter: ${r.reporter['first_name'] ?? ''} ${r.reporter['last_name'] ?? ''} @${r.reporter['username'] ?? ''} · ${r.reporterId ?? 'Deleted account'}',
        ),
        Text(
          'Target: ${r.target['first_name'] ?? ''} ${r.target['last_name'] ?? ''} @${r.target['username'] ?? ''} · ${r.targetId ?? 'Deleted account'}',
        ),
        Text(
          'Context: ${r.contextType} · Workspace: ${r.workspaceId ?? 'None'} · Invitation: ${r.invitationId ?? 'None'}',
        ),
        if (r.explanation != null) Text(r.explanation!),
        Text(
          'Previous reports: ${r.priorReports['total'] ?? 0} · Open: ${r.priorReports['open'] ?? 0}',
        ),
        Text(
          'Enforcement: ${r.state ?? 'Unavailable'} · Expiry: ${r.expiresAt ?? 'None / indefinite'}',
        ),
        const Text('Abuse counters'),
        const Text('Counter/bucket observations'),
        _counter('Invitation', r.invitationQuota),
        _counter('Reports', r.reportQuota),
        if (r.ownerTarget)
          const Text(
            'Platform owner: restriction and suspension are unavailable.',
          ),
        Wrap(
          spacing: 8,
          children: [
            if (r.status == 'pending')
              TextButton(
                onPressed: () => mutate(context, 'reviewed'),
                child: const Text('Mark reviewed'),
              ),
            if (r.status == 'pending' || r.status == 'reviewed') ...[
              TextButton(
                onPressed: () => mutate(context, 'dismissed'),
                child: const Text('Dismiss'),
              ),
              TextButton(
                onPressed: () => mutate(context, 'actioned'),
                child: const Text('Mark actioned'),
              ),
            ],
            if (r.targetId != null) ...[
              if (!r.ownerTarget) ...[
                TextButton(
                  onPressed: () => mutate(context, 'RESTRICTED'),
                  child: const Text('Restrict'),
                ),
                TextButton(
                  onPressed: () => mutate(context, 'SUSPENDED'),
                  child: const Text('Suspend'),
                ),
              ],
              TextButton(
                onPressed: () => mutate(context, 'ACTIVE'),
                child: const Text('Restore'),
              ),
            ],
          ],
        ),
        const Text('Relevant audit'),
        for (final entry in r.audit) auditEvent(entry),
      ],
    );
  }
}

class _ModerationConfirmation extends StatefulWidget {
  final AdminController controller;
  final ModerationReport report;
  final String action;
  const _ModerationConfirmation({
    required this.controller,
    required this.report,
    required this.action,
  });
  @override
  State<_ModerationConfirmation> createState() =>
      _ModerationConfirmationState();
}

class _ModerationConfirmationState extends State<_ModerationConfirmation> {
  String? actor;
  @override
  void initState() {
    super.initState();
    actor = widget.controller.actorId;
    widget.controller.addListener(sessionChanged);
  }

  void sessionChanged() {
    if (actor != widget.controller.actorId && mounted) {
      Navigator.pop(context, false);
    }
  }

  final reason = TextEditingController();
  String duration = '24h';
  String? correlation, requestKey, expiry, message;
  bool busy = false, done = false;
  bool get enforcement =>
      ['ACTIVE', 'RESTRICTED', 'SUSPENDED'].contains(widget.action);
  @override
  void dispose() {
    widget.controller.removeListener(sessionChanged);
    reason.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final explanation = reason.text.trim();
    if (explanation.isEmpty || explanation.runes.length > 500) {
      setState(() => message = 'A reason of 1-500 characters is required.');
      return;
    }
    final key = '$explanation|$duration';
    if (key != requestKey) {
      requestKey = key;
      correlation = widget.controller.api.newCorrelation();
      final hours = {'24h': 24, '7d': 168, '30d': 720}[duration];
      expiry = widget.action == 'ACTIVE' || hours == null
          ? null
          : DateTime.now()
                .toUtc()
                .add(Duration(hours: hours))
                .toIso8601String();
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = enforcement
          ? await widget.controller.api.accountState(
              widget.report.targetId!,
              widget.action,
              expiry,
              explanation,
              correlation!,
            )
          : await widget.controller.api.reportStatus(
              widget.report.id!,
              widget.action,
              explanation,
              correlation!,
            );
      if (!mounted || widget.controller.actorId != actor) return;
      final before = object(result['before']), after = object(result['after']);
      setState(() {
        done = true;
        message =
            '${before['state'] ?? before['status']} to ${after['state'] ?? after['status']}';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Mutation unavailable. Retry preserves the correlation ID and expiry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Confirm ${widget.action}'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Target: ${enforcement ? widget.report.targetId : widget.report.id}',
          ),
          if (!done) ...[
            TextField(
              controller: reason,
              enabled: !busy,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Required moderation reason',
              ),
            ),
            if (enforcement && widget.action != 'ACTIVE')
              DropdownButton<String>(
                value: duration,
                items: [
                  for (final d in {
                    '24h': '24 hours',
                    '7d': '7 days',
                    '30d': '30 days',
                    'indefinite': 'Indefinite',
                  }.entries)
                    DropdownMenuItem(value: d.key, child: Text(d.value)),
                ],
                onChanged: busy ? null : (v) => setState(() => duration = v!),
              ),
          ],
          if (busy) const LinearProgressIndicator(),
          if (message != null) Text(message!),
        ],
      ),
    ),
    actions: [
      if (!done)
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      FilledButton(
        onPressed: busy
            ? null
            : done
            ? () => Navigator.pop(context, true)
            : submit,
        child: Text(done ? 'Done' : 'Confirm'),
      ),
    ],
  );
}
