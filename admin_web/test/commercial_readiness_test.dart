import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/subscriptions.dart';

import 'support.dart';
import 'subscriptions_test.dart' show field, grantValues;

void main() {
  test('Canonical AI usage hides pending, unknown coverage and invalid percentages', () {
    const measured = {
      'configured': true,
      'coverage': 'tracked_since',
      'used_percentage': 73,
    };
    expect(commercialAiPercentage(measured), 73);
    expect(commercialAiPercentage({...measured, 'used_percentage': 0}), 0);
    for (final change in [
      {'pending_reconciliation': true},
      {'coverage': 'pending'},
      {'coverage': null},
      {'configured': false},
      {'used_percentage': 101},
      {'used_percentage': -1},
      {'used_percentage': '73'},
    ]) {
      expect(commercialAiPercentage({...measured, ...change}), isNull);
    }
  });

  testWidgets(
    'Admin grant is not a Store payment; mapping alone is not RevenueCat readiness',
    (t) async {
      final auth = FakeAuth();
      final transport = FakeTransport();
      final controller = AdminController(auth, ControlApi(config, transport));
      for (final status in [
        'not_configured',
        'source_configured',
        'unexpected',
      ]) {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SubscriptionsView(
                  Subscriptions({
                    'user_id': userId,
                    'plan': 'PRO',
                    'sources': ['admin'],
                    'limits': {'seat_limit': 10, 'team_workspace_limit': 5},
                    'billing_status': status,
                    'store_sources': [],
                    'grants': [],
                    'ai_policy': {
                      'configured': true,
                      'used_percentage': 73,
                      'pending_reconciliation': true,
                      'coverage': 'tracked_since',
                    },
                  }),
                  controller,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.textContaining('Provided by LADNIK'), findsWidgets);
        expect(
          find.textContaining(commercialStoreReadiness(status)),
          findsOneWidget,
        );
        expect(find.textContaining('AI used %: 73'), findsNothing);
        expect(find.textContaining('Pending reconciliation'), findsOneWidget);
        expect(find.textContaining('Store source:'), findsNothing);
        expect(transport.requests, isEmpty);
      }
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      await auth.events.close();
    },
  );

  for (final status in [401, 403, 409]) {
    test(
      'Subscriptions fixed API rejects unauthorized/non-owner/stale response $status',
      () async {
        final transport = FakeTransport()..status = status;
        final api = ControlApi(config, transport);
        await expectLater(
          api.changeSubscription(
            command: 'grant.set',
            target: userId,
            revision: 7,
            values: grantValues(team: true),
            reason: 'Synthetic override',
            correlation: otherId,
            preview: false,
          ),
          throwsA(
            isA<AdminException>().having(
              (e) => e.failure,
              'failure',
              status == 401
                  ? AdminFailure.session
                  : status == 403
                  ? AdminFailure.forbidden
                  : AdminFailure.environment,
            ),
          ),
        );
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single['action'], 'subscriptions.apply');
        final params = object(transport.requests.single['params']);
        expect(params['revision'], 7);
        expect(object(params['values'])['team_id'], otherId);
        expect(object(params['values'])['user_id'], isNull);
      },
    );
  }

  Future<void> openEditor(
    WidgetTester t,
    FakeTransport transport, {
    AdminController? controller,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => SubscriptionEditor(
                  ControlApi(config, transport),
                  'grant.set',
                  grantValues(),
                  0,
                  id: userId,
                  controller: controller,
                ),
              ),
              child: const Text('Open grant'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Open grant'));
    await t.pumpAndSettle();
    await t.ensureVisible(field('Required reason'));
    await t.enterText(field('Required reason'), 'Synthetic support');
    await t.tap(find.text('Review impact'));
    await t.pumpAndSettle();
  }

  for (final ack in <Json>[
    {'audit_id': '', 'replayed': false},
    {'audit_id': 'not-an-audit', 'replayed': true},
    {'audit_id': otherId},
    {'audit_id': otherId, 'replayed': 'true'},
    {'audit_id': otherId, 'replayed': false, 'preview': true},
  ]) {
    testWidgets('Unrecognized Admin audit ACK does not confirm grant: $ack', (
      t,
    ) async {
      final transport = FakeTransport()
        ..project = (body) => body['action'] == 'subscriptions.preview'
            ? {'preview': true, 'before': null}
            : ack;
      await openEditor(t, transport);
      await t.ensureVisible(find.text('I confirm this impact'));
      await t.tap(find.text('I confirm this impact'));
      await t.pump();
      await t.tap(find.text('Confirm change'));
      await t.pumpAndSettle();
      expect(find.text('Confirm subscription change'), findsOneWidget);
      expect(find.textContaining('Change not confirmed'), findsOneWidget);
      expect(transport.requests, hasLength(2));
      await t.pump(const Duration(seconds: 1));
      expect(transport.requests, hasLength(2));
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'Owner audit ACK confirms once using the frozen correlation and revision',
    (t) async {
      final transport = FakeTransport()
        ..project = (body) => body['action'] == 'subscriptions.preview'
            ? {'preview': true, 'before': null}
            : {'audit_id': otherId, 'replayed': false};
      await openEditor(t, transport);
      await t.ensureVisible(find.text('I confirm this impact'));
      await t.tap(find.text('I confirm this impact'));
      await t.pump();
      await t.tap(find.text('Confirm change'));
      await t.pumpAndSettle();
      expect(find.text('Open grant'), findsOneWidget);
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.map((r) => r['correlation_id']).toSet(),
        hasLength(1),
      );
      expect(object(transport.requests.last['params'])['revision'], 0);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Actor A-B-A retires owner editor and ignores a late preview without an apply',
    (t) async {
      final auth = FakeAuth();
      final pending = Completer<ApiResponse>();
      final transport = FakeTransport();
      transport.deferred = (body) => body['action'] == 'subscriptions.preview'
          ? pending.future
          : Future.value(reply(body, {}));
      final controller = AdminController(auth, ControlApi(config, transport));
      controller.start();
      auth.signIn();
      await t.pump();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEditor(
              ControlApi(config, transport),
              'grant.set',
              {...grantValues(), 'internal_note': 'PRIVATE OWNER NOTE'},
              0,
              id: userId,
              controller: controller,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(field('Required reason'));
      await t.enterText(field('Required reason'), 'Synthetic support');
      await t.tap(find.text('Review impact'));
      await t.pump();
      final request = transport.requests.last;
      auth.signIn(otherId);
      auth.signIn(userId);
      await t.pumpAndSettle();
      pending.complete(reply(request, {'preview': true, 'before': null}));
      await t.pumpAndSettle();
      expect(find.text('Sign-in context changed'), findsOneWidget);
      expect(find.textContaining('PRIVATE OWNER NOTE'), findsNothing);
      expect(find.text('Confirm change'), findsNothing);
      expect(
        transport.requests.where((r) => r['action'] == 'subscriptions.apply'),
        isEmpty,
      );
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      await auth.events.close();
    },
  );
}
