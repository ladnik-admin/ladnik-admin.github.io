import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

class OverviewView extends StatelessWidget {
  final Overview data;
  const OverviewView(this.data, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Bounded server counts; capped or missing counts remain unavailable.',
      ),
      const SizedBox(height: 16),
      LayoutBuilder(
        builder: (context, bounds) => Wrap(
          spacing: 16,
          runSpacing: 0,
          children: [
            for (final entry in Overview.metrics.entries)
              SizedBox(
                width: bounds.maxWidth < 300 ? bounds.maxWidth : 280,
                child: panel(entry.value, [
                  Text(
                    data.counters[entry.key]!.label,
                    style: const TextStyle(fontSize: 22),
                  ),
                  if (data.counters[entry.key]!.reason != null)
                    fact('Reason', data.counters[entry.key]!.reason),
                ]),
              ),
          ],
        ),
      ),
      panel('Unsupported metrics', [
        for (final name in [
          'DAU',
          'WAU',
          'MAU',
          'Sync backlog',
          'App errors',
          'AI cost',
        ])
          fact(name, 'Unavailable'),
      ]),
    ],
  );
}
