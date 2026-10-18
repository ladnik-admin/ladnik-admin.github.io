import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/app.dart';
import 'package:ladnik_control_center/controller.dart';

import 'support.dart';

void main() {
  test(
    'A to B to A discards the first A subscription grant before legacy refresh',
    () async {
      final auth = FakeAuth()..signIn();
      final transport = FakeTransport();
      final controller = AdminController(auth, ControlApi(config, transport));
      addTearDown(() async {
        controller.dispose();
        await auth.events.close();
      });
      controller.start();
      await flush();
      final pending = Completer<ApiResponse>();
      Map<String, Object?>? oldRequest;
      transport.deferred = (request) async {
        if (request['action'] == 'subscriptions.overview') {
          oldRequest = request;
          return pending.future;
        }
        return reply(request, <String, Object?>{});
      };
      final oldLoad = controller.select(Section.subscriptions);
      expect(oldRequest, isNotNull);
      auth.signIn(otherId);
      auth.signIn(userId);
      await flush();
      final current = controller.data;
      pending.complete(
        reply(oldRequest!, <String, Object?>{
          'plan': 'PRO',
          'sources': ['admin'],
          'limits': <String, Object?>{},
        }),
      );
      await oldLoad;
      expect(controller.actorId, userId);
      expect(controller.data, same(current));
      expect(controller.section, Section.overview);
      transport.deferred = (request) async =>
          ApiResponse(400, {'error': 'invalid_request'});
      await controller.select(Section.subscriptions);
      expect(controller.data, isNull);
      expect(controller.access, Access.invalidRequest);
      expect(
        transport.requests.where(
          (r) => [
            'subscriptions.preview',
            'subscriptions.apply',
          ].contains(r['action']),
        ),
        isEmpty,
      );
    },
  );

  for (final legacyStatus in [400, 200]) {
    testWidgets(
      'Rollback response $legacyStatus clears subscriptions and never falls back or grants',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = FakeAuth()..signIn();
        final transport = FakeTransport();
        final controller = AdminController(auth, ControlApi(config, transport));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await auth.events.close();
        });
        await tester.pumpWidget(
          ControlCenterApp(config: config, controller: controller),
        );
        await tester.pumpAndSettle();
        await controller.select(Section.subscriptions);
        await tester.pumpAndSettle();
        expect(controller.access, Access.ready);
        expect(controller.data, isNotNull);

        // Protocol-shaped legacy rejection, not a deployed-original v12 boot.
        transport.deferred = (request) async {
          if (request['action'].toString().startsWith('subscriptions.')) {
            final body = Map<String, Object?>.from(
              reply(request, <String, Object?>{}).body as Map,
            )..remove('contract_version');
            return ApiResponse(legacyStatus, body);
          }
          return reply(request, <String, Object?>{});
        };
        final before = transport.requests.length;
        await controller.select(Section.subscriptions);
        await tester.pumpAndSettle();
        expect(controller.data, isNull);
        expect(controller.access, isNot(Access.ready));
        expect(transport.requests.length, before + 1);
        expect(transport.requests.last['action'], 'subscriptions.overview');
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Preview'), findsNothing);
        expect(find.text('Apply'), findsNothing);
        expect(
          transport.requests.where(
            (r) => [
              'subscriptions.apply',
              'subscriptions.preview',
            ].contains(r['action']),
          ),
          isEmpty,
        );

        await controller.select(Section.overview);
        await tester.pumpAndSettle();
        expect(controller.access, Access.ready);
        expect(transport.requests.last['action'], 'overview');
        expect(transport.requests.last.containsKey('contract_version'), false);
      },
    );
  }
}
