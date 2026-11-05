import 'dart:async';

import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import '../api.dart';

/// SOURCE-only consumer. The server's qualification and current Owner checks
/// authorize every operation; a local checkbox or timer never supplies proof.
class MaintenanceView extends StatefulWidget {
  final MaintenanceContext data;
  final AdminController controller;
  const MaintenanceView(this.data, this.controller, {super.key});
  @override
  State<MaintenanceView> createState() => _MaintenanceViewState();
}

class _MaintenanceViewState extends State<MaintenanceView> {
  late final epoch = widget.controller.contextEpoch;
  late final actor = widget.controller.actorId;
  final receiptId = TextEditingController();
  String mode = 'READ_ONLY';
  int minutes = 60;
  Json? prepared;
  String? request, message;
  bool busy = false, confirmed = false, invalidated = false;
  bool recoveryAvailable = true;
  Timer? expiry;
  bool get current =>
      !invalidated &&
      actor != null &&
      widget.controller.actorId == actor &&
      widget.controller.contextEpoch == epoch;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(invalidate);
    try {
      final saved = widget.controller.api.maintenanceRecovery.read(
        widget.controller.api.config.projectUrl,
        actor ?? '',
      );
      if (saved != null) {
        if (!validUserId(saved)) throw const FormatException();
        request = saved;
        receiptId.text = saved;
        message = 'Unresolved command recovered. Check its receipt; do not send another change.';
      }
    } catch (_) {
      recoveryAvailable = false;
      message = 'Recovery storage unavailable. Mode changes are disabled.';
    }
  }

  void invalidate() {
    if (!mounted || current || invalidated) return;
    expiry?.cancel();
    setState(() {
      invalidated = true;
      prepared = null;
      request = null;
      receiptId.clear();
      confirmed = false;
      busy = false;
      message = 'Owner context changed. Refresh Maintenance before continuing.';
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(invalidate);
    expiry?.cancel();
    prepared = null; // Never persist a nonce, JWT or authentication evidence.
    receiptId.dispose();
    super.dispose();
  }

  Future<void> prepare() async {
    if (!current ||
        busy ||
        request != null ||
        !widget.data.available ||
        !recoveryAvailable) {
      return;
    }
    final until = mode == 'NORMAL'
        ? null
        : DateTime.now().toUtc().add(Duration(minutes: minutes));
    setState(() {
      busy = true;
      message = null;
      prepared = null;
      confirmed = false;
    });
    try {
      final value = await widget.controller.api.prepareMaintenance(
        widget.data.revision!,
        mode,
        until,
      );
      if (!mounted || !current) return;
      final expires = DateTime.tryParse(text(value['expiresAt']) ?? '');
      final pause = DateTime.tryParse(text(value['pauseExpiresAt']) ?? '');
      if (value['version'] != 2 ||
          value['state'] != 'prepared' ||
          value['revision'] is! int ||
          value['revision'] != widget.data.revision ||
          value['mode'] != mode ||
          value['reason'] !=
              (mode == 'NORMAL' ? 'resume' : 'planned_migration') ||
          (until == null
              ? value['pauseExpiresAt'] != null
              : pause == null || !pause.isAtSameMomentAs(until)) ||
          !RegExp(r'^[0-9a-f-]{36}$').hasMatch(text(value['intent']) ?? '') ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$')
              .hasMatch(text(value['nonce']) ?? '') ||
          expires == null ||
          !expires.isAfter(DateTime.now()) ||
          expires.isAfter(DateTime.now().add(const Duration(seconds: 90)))) {
        throw const FormatException();
      }
      prepared = value;
      expiry = Timer(expires.difference(DateTime.now()), () {
        if (!mounted || !current || request != null) return;
        setState(() {
          prepared = null;
          confirmed = false;
          message = 'Confirmation expired. Prepare a new change.';
        });
      });
    } catch (_) {
      if (mounted && current) {
        message = 'Preparation unavailable. A fresh Owner sign-in and server qualification are required. No mode change was sent.';
      }
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    final intent = prepared;
    if (!current || busy || !confirmed || intent == null || request != null) {
      return;
    }
    final api = widget.controller.api;
    final project = api.config.projectUrl;
    final owner = actor!;
    final revision = intent['revision'] as int;
    if (!DateTime.parse(intent['expiresAt'] as String)
        .isAfter(DateTime.now())) {
      setState(() {
        prepared = null;
        confirmed = false;
        message = 'Confirmation expired. Prepare a new change.';
      });
      return;
    }
    final id = request = api.newCorrelation();
    receiptId.text = id;
    expiry?.cancel();
    // Clear the only usable nonce before awaiting SEND. Error/unknown has only
    // a receipt-read path; neither Refresh nor another tap can repeat this SEND.
    setState(() {
      prepared = null;
      busy = true;
      message = 'Awaiting server confirmation…';
    });
    try {
      await api.maintenanceRecovery.save(project, owner, id);
    } catch (_) {
      if (!mounted || !current) return;
      setState(() {
        recoveryAvailable = false;
        busy = false;
        message = 'Recovery storage unavailable. No mode change was sent.';
      });
      return;
    }
    if (!mounted || !current) {
      // Journal succeeded, but this view never sent the command.
      try {
        await api.maintenanceRecovery.clear(project, owner, id);
      } catch (_) {
        /* retain conservatively */
      }
      return;
    }
    try {
      final result = await api.commitMaintenance(
        intent['intent'] as String,
        intent['nonce'] as String,
        id,
        revision,
      );
      if (mounted && current) await acceptReceipt(result, id);
    } on AdminException catch (error) {
      if (error.definiteRejection) {
        // A verified rollback belongs to this captured attempt even after
        // navigation/logout. Only exact old-scope journal cleanup may continue;
        // current/mounted still fence every UI update and no command is resent.
        try {
          await api.maintenanceRecovery.clear(project, owner, id);
          if (mounted && current) message = 'Server rejected this attempt; no mode change applied. Refresh Maintenance and prepare a new change.';
        } catch (_) {
          if (mounted && current) message = 'Rejected attempt; recovery storage could not be cleared. Reconcile before another change.';
        }
      } else if (mounted && current) {
        message = 'Unknown result. Keep this request ID and check its receipt; do not send the change again.';
      }
    } catch (_) {
      if (mounted && current) message = 'Unknown result. Keep this request ID and check its receipt; do not send the change again.';
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> acceptReceipt(Json result, String id) async {
    if (result['version'] != 2 || result['requestId'] != id) {
      throw const FormatException();
    }
    if (result['state'] == 'unknown') {
      message = 'Receipt is unknown. This does not prove rollback. Reconcile before another change.';
    } else if (result['state'] == 'applied' &&
        object(result['result'])['revision'] is int &&
        const [
          'NORMAL',
          'READ_ONLY',
          'CRITICAL_PAUSE',
        ].contains(object(result['result'])['configured_mode'])) {
      await widget.controller.api.maintenanceRecovery.clear(
        widget.controller.api.config.projectUrl,
        actor!,
        id,
      );
      if (!mounted || !current) return;
      message =
          'Server receipt confirms ${object(result['result'])['configured_mode']} at revision ${object(result['result'])['revision']}. Refresh to read current status.';
    } else {
      throw const FormatException();
    }
  }

  Future<void> reconcile() async {
    if (!current || busy) return;
    final id = receiptId.text.trim();
    if (!validUserId(id) || (request != null && request != id)) {
      setState(() => message = 'Enter the original command request ID.');
      return;
    }
    request = id;
    setState(() => busy = true);
    try {
      await widget.controller.api.maintenanceRecovery.save(
        widget.controller.api.config.projectUrl,
        actor!,
        id,
      );
    } catch (_) {
      if (!mounted || !current) return;
      setState(() {
        busy = false;
        message = 'Recovery storage unavailable. No change was sent.';
      });
      return;
    }
    if (!mounted || !current) return;
    try {
      final value = await widget.controller.api.maintenanceReceipt(id);
      if (mounted && current) await acceptReceipt(value, id);
    } catch (_) {
      if (mounted && current) message = 'Receipt unavailable. Outcome remains unknown; no change was resent.';
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Maintenance', style: TextStyle(fontSize: 24)),
      Text(
        'Server mode: ${widget.data.mode ?? 'unavailable'} · revision ${widget.data.revision ?? 'unavailable'}',
      ),
      if (widget.data.expiresAt != null)
        Text('Pause expiry: ${widget.data.expiresAt}'),
      if (!widget.data.available)
        const Text('Maintenance is not qualified. Mode changes are disabled.'),
      const Text(
        'Sign out and sign in again immediately before preparing a change. Only current server-verified Owner authentication is accepted.',
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        isExpanded: true,
        itemHeight: null,
        initialValue: mode,
        decoration: const InputDecoration(labelText: 'Requested mode'),
        items: const [
          'NORMAL',
          'READ_ONLY',
          'CRITICAL_PAUSE',
        ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: !current || busy || prepared != null || request != null
            ? null
            : (v) => setState(() => mode = v!),
      ),
      const SizedBox(height: 16),
      if (mode != 'NORMAL')
        DropdownButtonFormField<int>(
          isExpanded: true,
          itemHeight: null,
          initialValue: minutes,
          decoration: const InputDecoration(labelText: 'Pause window'),
          items: const [15, 60, 240, 1440]
              .map((v) => DropdownMenuItem(value: v, child: Text('$v minutes')))
              .toList(),
          onChanged: !current || busy || prepared != null || request != null
              ? null
              : (v) => setState(() => minutes = v!),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed:
            recoveryAvailable &&
                current &&
                !busy &&
                widget.data.available &&
                prepared == null &&
                request == null
            ? prepare
            : null,
        child: const Text('Prepare change'),
      ),
      if (prepared != null) ...[
        Text(
          'Confirm ${prepared!['mode']} · revision ${prepared!['revision']} · pause ends ${prepared!['pauseExpiresAt'] ?? 'not applicable'}',
        ),
        CheckboxListTile(
          value: confirmed,
          onChanged: busy || !current
              ? null
              : (v) => setState(() => confirmed = v == true),
          title: const Text('I confirm this exact service mode change.'),
        ),
        FilledButton(
          onPressed: confirmed && !busy && current ? commit : null,
          child: const Text('Confirm change'),
        ),
        TextButton(
          onPressed: busy || !current
              ? null
              : () {
                  expiry?.cancel();
                  setState(() {
                    prepared = null;
                    confirmed = false;
                  });
                },
          child: const Text('Discard confirmation'),
        ),
      ],
      if (busy) const LinearProgressIndicator(),
      if (message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(message!),
        ),
      if (request != null)
        SelectableText(
          'Request ID: $request — keep for recovery after closing or refreshing this page.',
        ),
      const SizedBox(height: 16),
      TextField(
        controller: receiptId,
        enabled: !busy && current && request == null,
        decoration: const InputDecoration(
          labelText: 'Existing request ID (read-only recovery)',
        ),
      ),
      OutlinedButton(
        onPressed: current && !busy ? reconcile : null,
        child: const Text('Check receipt'),
      ),
    ],
  );
}
