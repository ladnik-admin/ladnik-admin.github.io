import 'package:flutter/material.dart';

import '../controller.dart';
import '../models.dart';
import 'common.dart';

class AiSafetyView extends StatelessWidget {
  final AiControl data;
  final AdminController controller;
  const AiSafetyView(this.data, this.controller, {super.key});
  Future<void> edit(
    BuildContext context,
    bool enabled, {
    bool update = false,
  }) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AiConfirmation(data, controller, enabled, update),
    );
    if (changed == true) await controller.select(Section.aiSafety);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('AI Safety', style: TextStyle(fontSize: 24)),
      fact('Enabled', data.enabled),
      fact('Gate status', data.status),
      fact('Exhausted', data.exhausted),
      for (final key in AiControl.limitNames)
        fact(key.replaceAll('_', ' '), data.limits[key]),
      const Text('Counters / UTC windows: minute, day, calendar month'),
      fact('Windows', data.windows.join(', ')),
      fact('Text attempts', data.textAttempts.join(', ')),
      fact('Audio attempts', data.audioAttempts.join(', ')),
      fact('Audio milliseconds', data.audioMs.join(', ')),
      fact('Monetary cost', data.monetaryCost),
      const Text(
        'Limits require an owner budget decision before production enablement.',
      ),
      Wrap(
        spacing: 12,
        children: [
          FilledButton(
            onPressed: data.enabled == null ? null : () => edit(context, false),
            child: const Text('Disable immediately'),
          ),
          OutlinedButton(
            onPressed: data.configured ? () => edit(context, true) : null,
            child: const Text('Enable with configured limits'),
          ),
          OutlinedButton(
            onPressed: data.enabled == null
                ? null
                : () => edit(context, data.enabled!, update: true),
            child: const Text('Update limits'),
          ),
        ],
      ),
    ],
  );
}

class _AiConfirmation extends StatefulWidget {
  final AiControl data;
  final AdminController controller;
  final bool enabled, update;
  const _AiConfirmation(this.data, this.controller, this.enabled, this.update);
  @override
  State<_AiConfirmation> createState() => _AiConfirmationState();
}

class _AiConfirmationState extends State<_AiConfirmation> {
  final reason = TextEditingController();
  late final fields = {
    for (final key in AiControl.limitNames)
      key: TextEditingController(
        text: widget.data.limits[key]?.toString() ?? '',
      ),
  };
  late final correlation = widget.controller.api.newCorrelation();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    reason.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      Map<String, int>? limits;
      if (widget.update || widget.data.configured) {
        limits = {
          for (final key in AiControl.limitNames)
            key: int.tryParse(fields[key]!.text) ?? 0,
        };
      }
      await widget.controller.api.setAiControl(
        widget.enabled,
        limits,
        reason.text,
        correlation,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Change not confirmed. Check limits/reason and retry.';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.update
          ? 'Confirm AI limits'
          : widget.enabled
          ? 'Confirm AI enablement'
          : 'Confirm AI disablement',
    ),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This changes the project-wide provider gate. Reserved in-flight calls may still finish.',
            ),
            if (widget.update)
              for (final key in AiControl.limitNames)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: fields[key],
                    enabled: !busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: key.replaceAll('_', ' '),
                    ),
                  ),
                ),
            TextField(
              controller: reason,
              enabled: !busy,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
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
      FilledButton(
        onPressed: busy ? null : submit,
        child: Text(busy ? 'Saving…' : 'Confirm'),
      ),
    ],
  );
}
