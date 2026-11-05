import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/maintenance_recovery.dart';
import 'package:ladnik_control_center/sections/maintenance.dart';

import 'support.dart';

class _OwnedView extends StatefulWidget {
  final AdminController controller;
  final int route;
  const _OwnedView(this.controller, {this.route = 0});
  @override
  State<_OwnedView> createState() => _OwnedViewState();
}

class _OwnedViewState extends State<_OwnedView> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: MaintenanceView(
        widget.controller.data! as MaintenanceContext,
        widget.controller,
        key: ValueKey(widget.route),
      ),
    ),
  );
}

class BrokenRecovery implements MaintenanceRecovery {
  @override
  String? read(String project, String actor) => null;
  @override
  Future<void> save(String project, String actor, String request) async =>
      throw StateError('synthetic denied storage');
  @override
  Future<void> clear(String project, String actor, String request) async {}
}

const contextData = <String, Object?>{
  'version': 2,
  'available': true,
  'revision': 1,
  'configuredMode': 'NORMAL',
  'expiresAt': null,
  'reauthRequired': true,
};
const intentId = '00000000-0000-4000-8000-000000000003';
ApiResponse maintenanceReply(Map<String, Object?> request, Object? data) {
  final base = reply(request, data);
  return ApiResponse(200, {...base.body as Map, 'contract_version': 2});
}

void main() {
  test(
    'Only a sanitized exact-attempt rollback proof is a definite rejection',
    () {
      final request = <String, Object?>{
        'action': 'maintenance.commit.v2',
        'correlation_id': userId,
        'expected_environment': config.environment,
        'expected_project_url': config.projectUrl,
      };
      final proof = <String, Object?>{
        'error': 'revision_conflict',
        'rejected': true,
        'contract_version': 2,
        'correlation_id': userId,
        'environment': {
          'label': config.environment,
          'project_url': config.projectUrl,
        },
        'sql': 'PRIVATE',
        'nonce': 'PRIVATE',
      };
      final projected = safeAdminError(409, proof, request);
      expect(projected.body.toString(), isNot(contains('PRIVATE')));
      expect(projected.body, isNotNull);
      for (final changed in [
        <String, Object?>{'correlation_id': otherId},
        {'contract_version': 1},
        {
          'environment': {
            'label': 'production',
            'project_url': config.projectUrl,
          },
        },
        {'rejected': false},
        {'error': 'unavailable'},
      ]) {
        expect(
          safeAdminError(409, {...proof, ...changed}, request).body,
          isNull,
        );
      }
      expect(safeAdminError(503, proof, request).body, isNull);
    },
  );
  test(
    'Recovery retains only a scoped UUID and cannot overwrite unresolved work',
    () async {
      final recovery = createMaintenanceRecovery();
      await recovery.save(config.projectUrl, userId, intentId);
      expect(recovery.read(config.projectUrl, otherId), isNull);
      expect(recovery.read('https://other.supabase.co', userId), isNull);
      await expectLater(
        recovery.save(config.projectUrl, userId, otherId),
        throwsStateError,
      );
      await expectLater(
        recovery.clear(config.projectUrl, userId, otherId),
        throwsStateError,
      );
      expect(recovery.read(config.projectUrl, userId), intentId);
      await recovery.clear(config.projectUrl, userId, intentId);
      expect(recovery.read(config.projectUrl, userId), isNull);
    },
  );
  test('V2 context requires verified version, availability and mode', () async {
    final transport = FakeTransport();
    transport.deferred = (request) async =>
        maintenanceReply(request, contextData);
    final api = ControlApi(config, transport);
    expect((await api.maintenanceContext()).available, isTrue);
    expect(transport.requests.single['contract_version'], 2);
    transport.deferred = (request) async => reply(request, contextData);
    await expectLater(api.maintenanceContext(), throwsA(isA<AdminException>()));
    expect(
      MaintenanceContext({...contextData, 'available': 'true'}).available,
      isFalse,
    );
    expect(
      MaintenanceContext({...contextData, 'revision': -1}).available,
      isFalse,
    );
    expect(
      MaintenanceContext({...contextData, 'configuredMode': 'UNKNOWN'})
          .available,
      isFalse,
    );
  });

  Future<(FakeAuth, FakeTransport, AdminController)> mount(
    WidgetTester tester, {
    bool available = true,
    MaintenanceRecovery? recovery,
    double textScale = 1,
  }) async {
    final auth = FakeAuth()..signIn();
    final transport = FakeTransport();
    transport.deferred = (request) async {
      final action = request['action'];
      if (action == 'maintenance.context.v2') {
        return maintenanceReply(request, {
          ...contextData,
          'available': available,
        });
      }
      if (action == 'maintenance.prepare.v2') {
        final p = request['params'] as Map;
        return maintenanceReply(request, {
          'version': 2,
          'state': 'prepared',
          'intent': intentId,
          'nonce': 'a' * 43,
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(seconds: 85))
              .toIso8601String(),
          'revision': 1,
          'mode': p['mode'],
          'reason': p['reason_code'],
          'pauseExpiresAt': p['expires_at'],
        });
      }
      if (action == 'maintenance.receipt.v2') {
        return maintenanceReply(request, {
          'version': 2,
          'state': 'unknown',
          'requestId': (request['params'] as Map)['request'],
        });
      }
      return const ApiResponse(503, null);
    };
    final controller = AdminController(
      auth,
      ControlApi(config, transport, recovery: recovery),
    )..start();
    await tester.pump();
    await controller.select(Section.maintenance);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: _OwnedView(controller),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    });
    await tester.pumpAndSettle();
    return (auth, transport, controller);
  }

  testWidgets('Lost ACK survives page replacement and blocks another prepare', (
    tester,
  ) async {
    final (_, transport, controller) = await mount(tester);
    await tester.tap(find.text('Prepare change'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.text('Confirm change'));
    await tester.tap(find.text('Confirm change'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: _OwnedView(controller, route: 1)),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Prepare change'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Unresolved command recovered'), findsOneWidget);
    expect(
      transport.requests
          .where((r) => r['action'] == 'maintenance.commit.v2')
          .length,
      1,
    );
  });

  testWidgets(
    'Bound server rejection clears only this attempt and requires fresh context',
    (tester) async {
      final (_, transport, controller) = await mount(tester);
      final previous = transport.deferred!;
      transport.deferred = (r) async {
        if (r['action'] != 'maintenance.commit.v2') return previous(r);
        return ApiResponse(409, {
          ...maintenanceReply(r, {}).body as Map,
          'error': 'revision_conflict',
          'rejected': true,
        });
      };
      await tester.tap(find.text('Prepare change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.ensureVisible(find.text('Confirm change'));
      await tester.tap(find.text('Confirm change'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Server rejected'), findsOneWidget);
      expect(
        controller.api.maintenanceRecovery.read(config.projectUrl, userId),
        isNull,
      );
      await controller.select(Section.maintenance);
      await tester.pumpWidget(
        MaterialApp(home: _OwnedView(controller, route: 1)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Prepare change'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        transport.requests
            .where((r) => r['action'] == 'maintenance.commit.v2')
            .length,
        1,
      );
    },
  );

  testWidgets(
    'Delayed proven rejection after navigation clears only old scoped journal',
    (tester) async {
      final (_, transport, controller) = await mount(tester);
      final previous = transport.deferred!;
      final deferred = Completer<ApiResponse>();
      late Map<String, Object?> sent;
      transport.deferred = (r) async {
        if (r['action'] != 'maintenance.commit.v2') return previous(r);
        sent = r;
        return deferred.future;
      };
      await tester.tap(find.text('Prepare change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.ensureVisible(find.text('Confirm change'));
      await tester.tap(find.text('Confirm change'));
      await tester.pump();
      final id = (sent['params'] as Map)['request'];
      expect(
        controller.api.maintenanceRecovery.read(config.projectUrl, userId),
        id,
      );
      await controller.select(Section.maintenance);
      await tester.pumpWidget(
        MaterialApp(home: _OwnedView(controller, route: 1)),
      );
      await tester.pump();
      await controller.api.maintenanceRecovery.save(
        config.projectUrl,
        otherId,
        intentId,
      );
      deferred.complete(
        ApiResponse(409, {
          ...maintenanceReply(sent, {}).body as Map,
          'error': 'revision_conflict',
          'rejected': true,
        }),
      );
      await tester.pumpAndSettle();
      expect(
        controller.api.maintenanceRecovery.read(config.projectUrl, userId),
        isNull,
      );
      expect(
        controller.api.maintenanceRecovery.read(config.projectUrl, otherId),
        intentId,
      );
      await controller.select(Section.maintenance);
      await tester.pumpWidget(
        MaterialApp(home: _OwnedView(controller, route: 2)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Prepare change'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        transport.requests
            .where((r) => r['action'] == 'maintenance.commit.v2')
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Default OFF never offers prepare or sends a command', (
    tester,
  ) async {
    final (_, transport, _) = await mount(tester, available: false);
    expect(find.textContaining('not qualified'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Prepare change'),
    );
    expect(button.onPressed, isNull);
    expect(
      transport.requests.where((r) => r['action'] == 'maintenance.prepare.v2'),
      isEmpty,
    );
  });

  testWidgets('Pasted UNKNOWN receipt binds recovery and blocks prepare', (
    tester,
  ) async {
    final (_, transport, _) = await mount(tester);
    await tester.enterText(find.byType(TextField), otherId);
    await tester.ensureVisible(find.text('Check receipt'));
    await tester.tap(find.text('Check receipt'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Prepare change'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('does not prove rollback'), findsOneWidget);
    expect(
      transport.requests.where((r) => r['action'] == 'maintenance.prepare.v2'),
      isEmpty,
    );
  });

  testWidgets('Durable journal failure refuses SEND', (tester) async {
    final (_, transport, _) = await mount(tester, recovery: BrokenRecovery());
    await tester.tap(find.text('Prepare change'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.text('Confirm change'));
    await tester.tap(find.text('Confirm change'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No mode change was sent'), findsOneWidget);
    expect(
      transport.requests.where((r) => r['action'] == 'maintenance.commit.v2'),
      isEmpty,
    );
  });

  testWidgets(
    'Discard and expiry never SEND; narrow large text remains usable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (_, transport, _) = await mount(tester, textScale: 2);
      await tester.ensureVisible(find.text('Prepare change'));
      await tester.tap(find.text('Prepare change'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Discard confirmation'));
      await tester.tap(find.text('Discard confirmation'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm change'), findsNothing);
      await tester.ensureVisible(find.text('Prepare change'));
      await tester.tap(find.text('Prepare change'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 91));
      expect(find.text('Confirm change'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        transport.requests.where((r) => r['action'] == 'maintenance.commit.v2'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'Separate confirmation, one SEND, unknown receipt never retries commit',
    (tester) async {
      final (_, transport, _) = await mount(tester);
      await tester.tap(find.text('Prepare change'));
      await tester.pumpAndSettle();
      expect(
        transport.requests.where((r) => r['action'] == 'maintenance.commit.v2'),
        isEmpty,
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.ensureVisible(find.text('Confirm change'));
      await tester.tap(find.text('Confirm change'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unknown result'), findsOneWidget);
      expect(find.text('Confirm change'), findsNothing);
      await tester.ensureVisible(find.text('Check receipt'));
      await tester.tap(find.text('Check receipt'));
      await tester.pumpAndSettle();
      expect(
        transport.requests
            .where((r) => r['action'] == 'maintenance.commit.v2')
            .length,
        1,
      );
      expect(find.textContaining('does not prove rollback'), findsOneWidget);
    },
  );

  testWidgets('Account A-B-A invalidates a delayed prepare', (tester) async {
    final (auth, transport, _) = await mount(tester);
    final pending = Completer<ApiResponse>();
    late Map<String, Object?> prepare;
    transport.deferred = (r) async {
      if (r['action'] == 'maintenance.prepare.v2') {
        prepare = r;
        return pending.future;
      }
      return const ApiResponse(503, null);
    };
    await tester.tap(find.text('Prepare change'));
    await tester.pump();
    auth.signIn(otherId);
    auth.signIn(userId);
    pending.complete(
      maintenanceReply(prepare, {
        'version': 2,
        'state': 'prepared',
        'intent': intentId,
        'nonce': 'a' * 43,
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(seconds: 85))
            .toIso8601String(),
        'revision': 1,
        'mode': 'READ_ONLY',
        'reason': 'planned_migration',
        'pauseExpiresAt': (prepare['params'] as Map)['expires_at'],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirm change'), findsNothing);
    expect(
      transport.requests.where((r) => r['action'] == 'maintenance.commit.v2'),
      isEmpty,
    );
  });
}
