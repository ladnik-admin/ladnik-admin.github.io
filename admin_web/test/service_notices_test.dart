import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/maintenance_recovery.dart';
import 'package:ladnik_control_center/sections/service_notices.dart';

import 'support.dart';

ApiResponse noticeReply(Map<String, Object?> request, Object? data) =>
    ApiResponse(200, {
      ...reply(request, data).body as Map,
      'contract_version': 1,
    });

class OwnedNoticeView extends StatefulWidget {
  final AdminController controller;
  final int route;
  const OwnedNoticeView(this.controller, this.route, {super.key});
  @override
  State<OwnedNoticeView> createState() => _OwnedNoticeViewState();
}

class _OwnedNoticeViewState extends State<OwnedNoticeView> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: ServiceNoticesView(
        widget.controller.data! as ServiceNoticesData,
        widget.controller,
        key: ValueKey(widget.route),
      ),
    ),
  );
}

void main() {
  Future<(FakeAuth, FakeTransport, AdminController)> mount(
    WidgetTester tester, {
    bool available = true,
    MaintenanceRecovery? recovery,
    int route = 0,
    double scale = 1,
    AdminController? existing,
  }) async {
    final auth = FakeAuth()..signIn(), transport = FakeTransport();
    transport.deferred = (request) async {
      if (request['action'] == 'notices.get.v1') {
        return noticeReply(request, {
          'version': 1,
          'available': available,
          'pushAvailable': false,
          'notices': [],
        });
      }
      if (request['action'] == 'notices.receipt.v1') {
        return noticeReply(request, {
          'version': 1,
          'requestId': (request['params'] as Map)['request'],
          'state': 'unknown',
        });
      }
      if (request['action'] == 'overview') return reply(request, {});
      return const ApiResponse(503, null);
    };
    final controller =
        existing ??
        (AdminController(
          auth,
          ControlApi(config, transport, recovery: recovery),
        )..start());
    if (existing == null) {
      await tester.pump();
      await controller.select(Section.serviceNotices);
    }
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: OwnedNoticeView(controller, route),
      ),
    );
    await tester.pumpAndSettle();
    if (existing == null) {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await auth.events.close();
      });
    }
    return (auth, transport, controller);
  }

  Future<void> draft(WidgetTester tester) async {
    final start = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 1))
        .toIso8601String();
    final end = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 2))
        .toIso8601String();
    final values = [
      'Russian title',
      'Russian message',
      'English title',
      'English message',
      start,
      end,
      '2',
    ];
    for (var i = 0; i < values.length; i++) {
      await tester.ensureVisible(find.byType(TextField).at(i));
      await tester.enterText(find.byType(TextField).at(i), values[i]);
    }
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Preview announcement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview announcement'));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.text('Publish announcement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish announcement'));
    await tester.pumpAndSettle();
  }

  test('Safe rejection proof requires notice version, exact attempt/project and known error', () {
    final request = {
      'action': 'notices.publish.v1',
      'correlation_id': userId,
      'expected_environment': config.environment,
      'expected_project_url': config.projectUrl,
    };
    final proof = {
      'error': 'notices_rejected',
      'rejected': true,
      'contract_version': 1,
      'correlation_id': userId,
      'environment': {
        'label': config.environment,
        'project_url': config.projectUrl,
      },
    };
    expect(safeAdminError(503, proof, request).body, isNotNull);
    expect(
      safeAdminError(503, {...proof, 'contract_version': 2}, request).body,
      isNull,
    );
    expect(
      safeAdminError(503, {...proof, 'correlation_id': otherId}, request).body,
      isNull,
    );
    expect(
      safeAdminError(503, proof, {...request, 'action': 'notices.get.v1'}).body,
      isNull,
    );
  });
  testWidgets('Default OFF never previews or publishes', (tester) async {
    final (_, transport, _) = await mount(tester, available: false);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Preview announcement'),
          )
          .onPressed,
      isNull,
    );
    expect(
      transport.requests.where((r) => r['action'] == 'notices.publish.v1'),
      isEmpty,
    );
  });
  testWidgets(
    'Preview is separate; lost ACK survives page replacement, receipt-only',
    (tester) async {
      final recovery = createMaintenanceRecovery();
      final (_, transport, controller) = await mount(
        tester,
        recovery: recovery,
      );
      await draft(tester);
      expect(find.text('Preview - not published'), findsOneWidget);
      expect(
        transport.requests.where((r) => r['action'] == 'notices.publish.v1'),
        isEmpty,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Publish announcement'),
            )
            .onPressed,
        isNull,
      );
      await confirm(tester);
      final sent = transport.requests.singleWhere(
        (r) => r['action'] == 'notices.publish.v1',
      );
      expect(
        NoticeCommand.decode(
          recovery.read(controller.api.noticeJournalScope, userId)!,
        ).request,
        sent['correlation_id'],
      );
      await mount(tester, existing: controller, route: 1);
      await tester.ensureVisible(find.text('Check receipt'));
      await tester.tap(find.text('Check receipt'));
      await tester.pumpAndSettle();
      expect(
        transport.requests
            .where((r) => r['action'] == 'notices.publish.v1')
            .length,
        1,
      );
      expect(
        transport.requests
            .where((r) => r['action'] == 'notices.receipt.v1')
            .length,
        1,
      );
      expect(
        recovery.read(config.projectUrl, userId),
        isNull,
      ); // no Maintenance journal collision
    },
  );
  for (final wrong in ['state', 'notice', 'revision']) {
    testWidgets('Wrong $wrong ACK remains UNKNOWN with durable journal', (
      tester,
    ) async {
      final recovery = createMaintenanceRecovery();
      final (_, transport, controller) = await mount(
        tester,
        recovery: recovery,
      );
      final previous = transport.deferred!;
      transport.deferred = (request) async {
        if (request['action'] != 'notices.publish.v1') return previous(request);
        final p = request['params'] as Map;
        return noticeReply(request, {
          'version': 1,
          'requestId': request['correlation_id'],
          'state': wrong == 'state' ? 'resolved' : 'published',
          'notice': wrong == 'notice' ? otherId : p['id'],
          'revision': wrong == 'revision' ? 2 : 1,
        });
      };
      await draft(tester);
      await confirm(tester);
      expect(
        recovery.read(controller.api.noticeJournalScope, userId),
        isNotNull,
      );
      expect(find.textContaining('Unknown result.'), findsOneWidget);
      final sent = transport.requests.singleWhere(
        (r) => r['action'] == 'notices.publish.v1',
      );
      final persisted = NoticeCommand.decode(
        recovery.read(controller.api.noticeJournalScope, userId)!,
      );
      expect(persisted.request, sent['correlation_id']);
      expect(persisted.state, 'published');
      expect(persisted.notice, (sent['params'] as Map)['id']);
      expect(persisted.revision, 1);
      await mount(tester, existing: controller, route: 1);
      final beforeReceipt = transport.deferred!;
      transport.deferred = (request) async {
        if (request['action'] != 'notices.receipt.v1') {
          return beforeReceipt(request);
        }
        return noticeReply(request, {
          'version': 1,
          'requestId': (request['params'] as Map)['request'],
          'state': wrong == 'state' ? 'resolved' : 'published',
          'notice': wrong == 'notice' ? otherId : persisted.notice,
          'revision': wrong == 'revision' ? 2 : 1,
        });
      };
      await tester.ensureVisible(find.text('Check receipt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check receipt'));
      await tester.pumpAndSettle();
      expect(
        recovery.read(controller.api.noticeJournalScope, userId),
        isNotNull,
      );
      expect(
        transport.requests
            .where((r) => r['action'] == 'notices.publish.v1')
            .length,
        1,
      );
      expect(find.textContaining('Receipt unavailable.'), findsOneWidget);
    });
  }
  testWidgets(
    'A-B-A invalidates preview and never sends; 320dp large text is scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (auth, transport, controller) = await mount(tester, scale: 2);
      await draft(tester);
      auth.signIn(otherId);
      auth.signIn(userId);
      await tester.pumpAndSettle();
      expect(find.text('Publish announcement'), findsNothing);
      expect(
        transport.requests.where((r) => r['action'] == 'notices.publish.v1'),
        isEmpty,
      );
      expect(controller.contextEpoch, greaterThan(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Late definite rejection clears only captured journal after page replacement',
    (tester) async {
      final recovery = createMaintenanceRecovery();
      final (_, transport, controller) = await mount(
        tester,
        recovery: recovery,
      );
      final previous = transport.deferred!, gate = Completer<ApiResponse>();
      Map<String, Object?>? sent;
      transport.deferred = (request) async {
        if (request['action'] == 'notices.publish.v1') {
          sent = request;
          return gate.future;
        }
        return previous(request);
      };
      await draft(tester);
      await confirm(tester);
      expect(sent, isNotNull);
      await mount(tester, existing: controller, route: 1);
      gate.complete(
        ApiResponse(503, {
          'error': 'notices_rejected',
          'rejected': true,
          'contract_version': 1,
          'correlation_id': sent!['correlation_id'],
          'environment': {
            'label': config.environment,
            'project_url': config.projectUrl,
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(recovery.read(controller.api.noticeJournalScope, userId), isNull);
      expect(
        transport.requests
            .where((r) => r['action'] == 'notices.publish.v1')
            .length,
        1,
      );
    },
  );
  testWidgets('Exact original receipt clears persisted contract after reload', (
    tester,
  ) async {
    final recovery = createMaintenanceRecovery();
    final (_, transport, controller) = await mount(tester, recovery: recovery);
    await draft(tester);
    await confirm(tester);
    final command = NoticeCommand.decode(
      recovery.read(controller.api.noticeJournalScope, userId)!,
    );
    expect(
      command.encode(),
      recovery.read(controller.api.noticeJournalScope, userId),
    );
    await mount(tester, existing: controller, route: 1);
    final previous = transport.deferred!;
    transport.deferred = (request) async {
      if (request['action'] != 'notices.receipt.v1') return previous(request);
      return noticeReply(request, {
        'version': 1,
        'requestId': command.request,
        'state': command.state,
        'notice': command.notice,
        'revision': command.revision,
      });
    };
    await tester.ensureVisible(find.text('Check receipt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check receipt'));
    await tester.pumpAndSettle();
    expect(recovery.read(controller.api.noticeJournalScope, userId), isNull);
    expect(find.textContaining('Server confirmed published.'), findsOneWidget);
  });
}
