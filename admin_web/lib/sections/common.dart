import 'package:flutter/material.dart';

import '../models.dart';

Widget fact(String label, Object? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: SelectableText('$label: ${value ?? 'Unavailable'}'),
);
Widget panel(String title, List<Widget> children) => Card(
  margin: const EdgeInsets.only(bottom: 16),
  child: Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  ),
);
Widget aiObservations(AiObservation ai) => panel('AI observations', [
  const Text(
    'Observed requests only. These signals do not establish provider uptime.',
  ),
  fact('Availability', ai.available ? 'Available' : 'Unavailable'),
  if (ai.days != null) fact('Window (days)', ai.days),
  if (ai.reason != null) fact('Reason', ai.reason),
  if (ai.available) ...[
    for (final metric in ai.summary.entries)
      fact(metric.key.replaceAll('_', ' '), metric.value),
  ],
  if (ai.truncated) const Text('Observation groups were capped.'),
  fact('AI cost', 'Unavailable'),
]);
Widget auditEvent(AuditEvent event) => panel(event.action ?? 'Audit event', [
  fact('Occurred at', event.occurredAt),
  fact('Actor', event.actor),
  fact('Target', event.target),
  fact('Reason', event.reason),
  fact('Result', event.result),
  fact('Correlation ID', event.correlation),
  fact(
    'Safe before',
    event.beforeState ??
        event.beforeStatus ??
        (event.beforeEnabled == null
            ? null
            : 'Enabled: ${event.beforeEnabled}'),
  ),
  fact(
    'Safe after',
    event.afterState ??
        event.afterStatus ??
        (event.afterEnabled == null ? null : 'Enabled: ${event.afterEnabled}'),
  ),
  if (event.beforeExpiry != null) fact('Before expiry', event.beforeExpiry),
  if (event.afterExpiry != null) fact('After expiry', event.afterExpiry),
]);
