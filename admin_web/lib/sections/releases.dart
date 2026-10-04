import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

class ReleasesView extends StatelessWidget {
  final Releases data;
  const ReleasesView(this.data, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
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
