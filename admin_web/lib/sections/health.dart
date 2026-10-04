import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

class HealthView extends StatelessWidget {
  final SystemHealth data;
  const HealthView(this.data, {super.key});
  Widget status(HealthState value) => Row(
    children: [
      Icon(
        switch (value) {
          HealthState.healthy => Icons.check_circle_outline,
          HealthState.degraded => Icons.warning_amber,
          HealthState.incident => Icons.error_outline,
          HealthState.unknown => Icons.help_outline,
        },
        color: switch (value) {
          HealthState.healthy => Colors.teal,
          HealthState.degraded => Colors.orange,
          HealthState.incident => Colors.red,
          HealthState.unknown => Colors.blueGrey,
        },
      ),
      const SizedBox(width: 8),
      Text(value.name),
    ],
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      status(data.state),
      const SizedBox(height: 16),
      const Text(
        'States reflect returned observations, not provider-wide uptime.',
      ),
      const SizedBox(height: 16),
      for (final entry in data.sections.entries)
        panel(entry.key == 'schema' ? 'Schema / reconciliation' : entry.key, [
          status(entry.value.state),
          if (entry.value.signal != null) fact('Signal', entry.value.signal),
          if (entry.value.reconciliation != null)
            fact('Reconciliation', entry.value.reconciliation),
          if (entry.value.execution != null)
            fact('Execution', entry.value.execution),
          if (entry.value.expectedContract != null)
            fact('Expected contract', entry.value.expectedContract),
          if (entry.key == 'push') ...[
            const Text(
              'Retained delivery outcomes; 24-hour window, sending older than 10 minutes.',
            ),
            for (final metric in entry.value.counts.entries)
              fact(metric.key.replaceAll('_', ' '), metric.value),
          ],
          if (entry.value.control != null) ...[
            fact('Global AI enabled', entry.value.control!.enabled),
            fact('Global gate', entry.value.control!.status),
            fact('Exhausted', entry.value.control!.exhausted),
            fact('UTC windows', entry.value.control!.windows.join(', ')),
            fact('Text attempts', entry.value.control!.textAttempts.join(', ')),
            fact(
              'Audio attempts',
              entry.value.control!.audioAttempts.join(', '),
            ),
            fact('Audio milliseconds', entry.value.control!.audioMs.join(', ')),
            fact('Monetary cost', entry.value.control!.monetaryCost),
          ],
          if (entry.value.ai != null) aiObservations(entry.value.ai!),
        ]),
    ],
  );
}
