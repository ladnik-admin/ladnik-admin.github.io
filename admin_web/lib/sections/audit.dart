import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import 'common.dart';

class AuditView extends StatelessWidget {
  final AuditPage data;
  final AdminController controller;
  const AuditView(this.data, this.controller, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Read-only Admin Audit · page size 50'),
      const SizedBox(height: 16),
      if (data.events.isEmpty) const Text('No audit entries on this page.'),
      for (final event in data.events) auditEvent(event),
      Row(
        children: [
          TextButton(
            onPressed: () => controller.select(Section.audit),
            child: const Text('Latest page'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: data.next == null ? null : controller.nextAudit,
            child: const Text('Older page'),
          ),
        ],
      ),
    ],
  );
}
