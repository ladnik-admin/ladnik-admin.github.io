import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import '../api.dart';
import 'common.dart';

class UsersView extends StatefulWidget {
  final UserPage data;
  final AdminController controller;
  const UsersView(this.data, this.controller, {super.key});
  @override
  State<UsersView> createState() => _UsersViewState();
}

class _UsersViewState extends State<UsersView> {
  late final TextEditingController search = TextEditingController(
    text: widget.controller.usersSearch,
  );
  String? error;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void submit() {
    final value = search.text.trim();
    if (value.isNotEmpty && !RegExp(r'^[a-zA-Z0-9_]{3,32}$').hasMatch(value)) {
      setState(
        () => error =
            'Enter 3–32 username characters: letters, numbers or underscore.',
      );
      return;
    }
    widget.controller.searchUsers(value);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: search,
        decoration: InputDecoration(
          labelText: 'Username prefix',
          helperText: 'Empty shows all accounts; page size 50.',
          errorText: error,
        ),
        onSubmitted: (_) => submit(),
      ),
      const SizedBox(height: 12),
      FilledButton(onPressed: submit, child: const Text('Search')),
      const SizedBox(height: 16),
      if (widget.data.users.isEmpty) const Text('No accounts on this page.'),
      for (final user in widget.data.users)
        panel(user.username ?? 'Username unavailable', [
          fact('UUID', user.id),
          fact('Verified', user.verified),
          fact('Lifecycle', user.lifecycle),
          if (validUserId(user.id))
            TextButton(
              onPressed: () => widget.controller.showUser(user.id!),
              child: const Text('View account'),
            ),
        ]),
      Row(
        children: [
          TextButton(
            onPressed: () => widget.controller.select(Section.users),
            child: const Text('First page'),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: widget.data.nextAfter == null
                ? null
                : widget.controller.nextUsers,
            child: const Text('Next page'),
          ),
        ],
      ),
    ],
  );
}

class UserDetailView extends StatelessWidget {
  final UserDetail data;
  final AdminController controller;
  const UserDetailView(this.data, this.controller, {super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(
        onPressed: () => controller.select(Section.users),
        child: const Text('Back to Users'),
      ),
      if (!data.found)
        const Text('Account not found.')
      else ...[
        panel('Account metadata', [
          fact('UUID', data.user.id),
          fact('Username', data.user.username),
          fact('Verified', data.user.verified),
          fact('Lifecycle', data.user.lifecycle),
          fact('Created at', data.user.createdAt),
          fact('Deleted at', data.user.deletedAt),
          for (final entry in data.user.counters.entries)
            fact(entry.key.replaceAll('_', ' '), entry.value.label),
        ]),
        panel('Latest app signal · self-reported heartbeat', [
          if (data.latestSignal == null)
            const Text('Unavailable')
          else ...[
            fact('Platform', data.latestSignal!.platform),
            fact('App version', data.latestSignal!.version),
            fact('Build', data.latestSignal!.build),
            fact('Last observed', data.latestSignal!.lastSeen),
          ],
        ]),
        aiObservations(data.ai),
        const Text('Targeted Admin Audit · up to 10 returned events'),
        const SizedBox(height: 12),
        if (data.audit.isEmpty)
          const Text('No targeted audit entries returned.'),
        for (final event in data.audit) auditEvent(event),
      ],
    ],
  );
}
