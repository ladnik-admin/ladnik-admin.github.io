import 'package:flutter/material.dart';

import '../api.dart';
import '../controller.dart';
import '../models.dart';

/// Publication is a separate command from Maintenance mode; Push stays absent.
class ServiceNoticesView extends StatefulWidget {
  final ServiceNoticesData data;
  final AdminController controller;
  const ServiceNoticesView(this.data, this.controller, {super.key});
  @override
  State<ServiceNoticesView> createState() => _ServiceNoticesViewState();
}

class _ServiceNoticesViewState extends State<ServiceNoticesView> {
  late final actor = widget.controller.actorId;
  late final epoch = widget.controller.contextEpoch;
  final fields = {
    for (final key in [
      'title_ru',
      'message_ru',
      'title_en',
      'message_en',
      'starts_at',
      'ends_at',
      'display_limit',
    ])
      key: TextEditingController(),
  };
  Json? preview;
  String? request, message, journalValue;
  NoticeCommand? expected;
  bool busy = false,
      confirmed = false,
      recovery = true,
      invalidated = false,
      terminal = false;
  bool get current =>
      !invalidated &&
      actor != null &&
      actor == widget.controller.actorId &&
      epoch == widget.controller.contextEpoch;
  @override
  void initState() {
    super.initState();
    fields['display_limit']!.text = '1';
    widget.controller.addListener(invalidate);
    try {
      journalValue = widget.controller.api.maintenanceRecovery.read(
        widget.controller.api.noticeJournalScope,
        actor ?? '',
      );
      if (journalValue != null) {
        expected = NoticeCommand.decode(journalValue!);
        request = expected!.request;
      }
      if (request != null) message = 'Unresolved publication recovered. Check receipt only; do not resend.';
    } catch (_) {
      recovery = false;
      message = 'Recovery storage unavailable. Publication disabled.';
    }
  }

  void invalidate() {
    if (!mounted || current || invalidated) return;
    setState(() {
      invalidated = true;
      preview = null;
      confirmed = false;
      request = null;
      expected = null;
      journalValue = null;
      for (final field in fields.values) {
        field.clear();
      }
      message = 'Owner context changed. Refresh before continuing.';
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(invalidate);
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void prepare() {
    if (!current ||
        busy ||
        request != null ||
        !widget.data.available ||
        !recovery ||
        terminal) {
      return;
    }
    try {
      final draft = <String, dynamic>{
        'id': widget.controller.api.newCorrelation(),
        for (final key in ['title_ru', 'message_ru', 'title_en', 'message_en'])
          key: fields[key]!.text.trim(),
        'starts_at': fields['starts_at']!.text.trim(),
        'ends_at': fields['ends_at']!.text.trim(),
        'display_limit': int.tryParse(fields['display_limit']!.text),
      };
      for (final key in ['title_ru', 'message_ru', 'title_en', 'message_en']) {
        final value = draft[key] as String;
        if (value.isEmpty ||
            value.runes.length > (key.startsWith('title') ? 100 : 500) ||
            value.contains(RegExp('[<>]'))) {
          throw const FormatException();
        }
      }
      DateTime parse(String key) {
        final value = draft[key] as String;
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
            .hasMatch(value)) {
          throw const FormatException();
        }
        return DateTime.parse(value);
      }

      final start = parse('starts_at'),
          end = parse('ends_at'),
          now = DateTime.now().toUtc();
      if (!end.isAfter(start) ||
          !end.isAfter(now) ||
          end.isAfter(now.add(const Duration(days: 31))) ||
          end.difference(start) > const Duration(days: 31) ||
          draft['display_limit'] is! int ||
          draft['display_limit'] < 1 ||
          draft['display_limit'] > 100) {
        throw const FormatException();
      }
      setState(() {
        preview = Map.unmodifiable(draft);
        confirmed = false;
        message = null;
      });
    } catch (_) {
      setState(
        () => message = 'Use both languages, UTC timestamps ending in Z, a window up to 31 days and 1-100 displays.',
      );
    }
  }

  Future<void> accept(Json result, String id) async {
    if (result['version'] != 1 || result['requestId'] != id) {
      throw const FormatException();
    }
    if (result['state'] == 'unknown') {
      if (mounted && current) {
        message =
            'Receipt unknown. This does not prove rollback; do not resend.';
      }
      return;
    }
    if (expected == null ||
        !expected!.accepts(result) ||
        journalValue == null) {
      throw const FormatException();
    }
    final api = widget.controller.api;
    await api.maintenanceRecovery.clear(
      api.noticeJournalScope,
      actor!,
      journalValue!,
    );
    if (mounted && current) {
      terminal = true;
      request = null;
      message =
          'Server confirmed ${result['state']}. Refresh to read current status.';
    }
  }

  Future<void> send({Json? resolve}) async {
    if (!current ||
        busy ||
        !recovery ||
        request != null ||
        terminal ||
        (resolve == null &&
            (!widget.data.available || !confirmed || preview == null))) {
      return;
    }
    final api = widget.controller.api,
        owner = actor!,
        project = api.noticeJournalScope;
    final draft = preview;
    final id = api.newCorrelation();
    final command = NoticeCommand(
      request: id,
      notice: (resolve ?? draft)!['id'] as String,
      state: resolve == null ? 'published' : 'resolved',
      revision: resolve == null ? 1 : (resolve['revision'] as int) + 1,
    );
    final stored = command.encode();
    setState(() {
      expected = command;
      journalValue = stored;
      busy = true;
      request = id;
      preview = null;
      confirmed = false;
      message = 'Awaiting server confirmation...';
    });
    var saved = false;
    try {
      await api.maintenanceRecovery.save(project, owner, stored);
      saved = true;
      if (!mounted || !current) {
        await api.maintenanceRecovery.clear(project, owner, stored);
        return;
      }
      final result = resolve == null
          ? await api.publishNotice(draft!, id)
          : await api.resolveNotice(
              resolve['id'] as String,
              resolve['revision'] as int,
              id,
            );
      // Captured receipt belongs to the old scope even if navigation changed.
      if (command.accepts(result)) {
        await api.maintenanceRecovery.clear(project, owner, stored);
        if (mounted && current) {
          terminal = true;
          request = null;
          message =
              'Server confirmed ${result['state']}. Refresh to read current status.';
        }
      } else if (mounted && current) {
        message = 'Unknown result. Check receipt only; do not resend.';
      }
    } on AdminException catch (error) {
      if (error.definiteRejection) {
        try {
          await api.maintenanceRecovery.clear(project, owner, stored);
          if (mounted && current) {
            terminal = true;
            request = null;
            message =
                'Server rejected this attempt. Refresh before a new command.';
          }
        } catch (_) {
          if (mounted && current) {
            message = 'Reconcile recovery storage before another command.';
          }
        }
      } else if (mounted && current) {
        message = 'Unknown result. Check receipt only; do not resend.';
      }
    } catch (_) {
      if (mounted && current) {
        if (!saved) recovery = false;
        message = saved
            ? 'Unknown result. Check receipt only; do not resend.'
            : 'Recovery storage unavailable. No command sent.';
      }
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> reconcile() async {
    final id = request;
    if (!current || busy || id == null) return;
    setState(() => busy = true);
    try {
      final result = await widget.controller.api.noticeReceipt(id);
      if (mounted && current) await accept(result, id);
    } catch (_) {
      if (mounted && current) {
        message = 'Receipt unavailable. Keep this request; do not resend.';
      }
    } finally {
      if (mounted && current) setState(() => busy = false);
    }
  }

  Future<void> resolve(Json notice) async {
    if (!current || busy || request != null || terminal) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop this announcement?'),
        content: Text(text(notice['titleEn']) ?? 'Announcement'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop announcement'),
          ),
        ],
      ),
    );
    if (yes == true &&
        mounted &&
        current &&
        validUserId(text(notice['id'])) &&
        notice['revision'] is int) {
      await send(resolve: notice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final edit =
        current &&
        recovery &&
        !busy &&
        request == null &&
        !terminal &&
        widget.data.available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Service notices',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        Text(
          widget.data.available
              ? 'In-app announcements available. Fresh Owner sign-in required to publish or stop.'
              : 'OFF / not qualified. No announcement can be published.',
        ),
        const Text(
          'Publishing does not pause writes. Push and view analytics are unavailable.',
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(message!),
          ),
        if (request != null) ...[
          SelectableText('Request: $request'),
          FilledButton(
            onPressed: current && !busy ? reconcile : null,
            child: const Text('Check receipt'),
          ),
        ],
        for (final notice in widget.data.notices)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(text(notice['titleEn']) ?? 'Announcement'),
                  Text(text(notice['messageEn']) ?? ''),
                  Text('${notice['startsAt']} to ${notice['endsAt']}'),
                  TextButton(
                    onPressed:
                        current &&
                            !busy &&
                            request == null &&
                            !terminal &&
                            recovery
                        ? () => resolve(notice)
                        : null,
                    child: const Text('Stop announcement'),
                  ),
                ],
              ),
            ),
          ),
        if (preview == null) ...[
          for (final entry in fields.entries)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: entry.value,
                enabled: edit,
                minLines: entry.key.startsWith('message') ? 3 : 1,
                maxLines: entry.key.startsWith('message') ? 6 : 1,
                decoration: InputDecoration(
                  labelText: switch (entry.key) {
                    'title_ru' => 'Russian title',
                    'message_ru' => 'Russian message',
                    'title_en' => 'English title',
                    'message_en' => 'English message',
                    'starts_at' => 'Work start (UTC, YYYY-MM-DDTHH:mm:ssZ)',
                    'ends_at' => 'Estimated end (UTC, YYYY-MM-DDTHH:mm:ssZ)',
                    _ => 'Maximum in-app displays per user',
                  },
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: edit ? prepare : null,
            child: const Text('Preview announcement'),
          ),
        ] else ...[
          const SizedBox(height: 16),
          const Text('Preview - not published'),
          for (final key in [
            'title_ru',
            'message_ru',
            'title_en',
            'message_en',
            'starts_at',
            'ends_at',
            'display_limit',
          ])
            Text('${preview![key]}'),
          CheckboxListTile(
            value: confirmed,
            onChanged: edit
                ? (v) => setState(() => confirmed = v == true)
                : null,
            title: const Text(
              'Publish exactly this text and time window. This does not enable Maintenance.',
            ),
          ),
          FilledButton(
            onPressed: edit && confirmed ? () => send() : null,
            child: const Text('Publish announcement'),
          ),
          TextButton(
            onPressed: edit ? () => setState(() => preview = null) : null,
            child: const Text('Edit draft'),
          ),
        ],
      ],
    );
  }
}
