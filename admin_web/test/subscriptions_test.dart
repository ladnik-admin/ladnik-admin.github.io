import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/app.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/subscriptions.dart';

import 'support.dart';

Json grantValues({bool team = false}) => {
  'plan': team ? 'TEAM' : 'PRO',
  'user_id': team ? null : userId,
  'team_id': team ? otherId : null,
  'starts_at': '2026-10-07T00:00:00Z',
  'expires_at': null,
  'internal_note': '',
  'limits': {},
  'revoked': false,
};
Future<void> editor(WidgetTester tester, ControlApi api, {bool team = false}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubscriptionEditor(
            api,
            'grant.set',
            grantValues(team: team),
            0,
            id: userId,
          ),
        ),
      ),
    );
Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

void main() {
  test('Subscriptions navigation and safe allowlisted projections', () {
    expect(sectionLabels[Section.subscriptions], 'Subscriptions');
    final data = Subscriptions({
      'plan': 'PRO',
      'raw_webhook': 'SECRET',
      'limits': {'seat_limit': 20, 'unknown': 1},
      'grants': [],
    });
    expect(data.detail.containsKey('raw_webhook'), false);
    expect(object(data.detail['limits']).containsKey('unknown'), false);
    expect(data.detail['plan'], 'PRO');
    expect(data.teamCreationEnabled, isNull);
    expect(
      Subscriptions({
        'control': {'enabled': true, 'team_creation_enabled': false},
      }).teamCreationEnabled,
      false,
    );
    expect(
      Subscriptions({
        'control': {'enabled': false, 'team_creation_enabled': true},
      }).teamCreationEnabled,
      true,
    );
  });
  test('Store facts and canonical AI are distinct from grants and exclude raw receipts', () {
    final detail = Subscriptions({
      'plan': 'PRO',
      'store_sources': [
        {
          'provider': 'apple',
          'plan': 'PRO',
          'period': 'month',
          'state': 'grace',
          'auto_renew': false,
          'external_subscription_id': 'SECRET',
          'raw_receipt': 'SECRET',
        },
      ],
      'ai_policy': {
        'configured': true,
        'used_percentage': 73,
        'reset_at': '2026-11-01',
        'tracking_since': '2026-10-09',
        'raw_cost': 123,
      },
    }).detail;
    expect(
      rows(
        detail['store_sources'],
        100,
      ).single.containsKey('external_subscription_id'),
      false,
    );
    expect(rows(detail['store_sources'], 100).single['state'], 'grace');
    expect(object(detail['ai_policy'])['used_percentage'], 73);
    expect(object(detail['ai_policy']).containsKey('raw_cost'), false);
  });
  test(
    'API exact scopes, fixed routes, reason, CAS and request correlation',
    () async {
      final transport = FakeTransport();
      final api = ControlApi(config, transport);
      await api.subscription(userId);
      await api.subscription(otherId, team: true);
      expect(transport.requests.map((r) => r['action']), [
        'subscriptions.get',
        'subscriptions.get',
      ]);
      await expectLater(
        api.changeSubscription(
          command: 'grant.set',
          target: userId,
          revision: 0,
          values: grantValues(),
          reason: '',
          correlation: userId,
          preview: true,
        ),
        throwsA(isA<AdminException>()),
      );
      expect(transport.requests.length, 2);
      await api.changeSubscription(
        command: 'grant.set',
        target: userId,
        revision: 0,
        values: grantValues(),
        reason: 'Support',
        correlation: userId,
        preview: true,
      );
      expect(transport.requests.last['correlation_id'], userId);
      expect(transport.requests.last['action'], 'subscriptions.preview');
      expect(transport.requests.every((r) => r['contract_version'] == 1), true);
    },
  );
  test('Subscriptions reject missing or incompatible version before using a projection', () async {
    final transport = FakeTransport();
    final api = ControlApi(config, transport);
    for (final version in [null, true, '1', 1.0, 2]) {
      transport.deferred = (request) async {
        final envelope = object(reply(request, <String, Object?>{}).body);
        envelope.remove('contract_version');
        if (version != null) envelope['contract_version'] = version;
        return ApiResponse(200, envelope);
      };
      await expectLater(
        api.subscriptions(),
        throwsA(
          isA<AdminException>().having(
            (e) => e.failure,
            'failure',
            AdminFailure.unavailable,
          ),
        ),
      );
    }
    expect(transport.requests, hasLength(5));
    transport.deferred = null;
    await api.subscriptions();
    expect(transport.requests.last['contract_version'], 1);
    await api.overview();
    expect(transport.requests.last.containsKey('contract_version'), false);
  });
  testWidgets(
    'Overview enforcement OFF and unavailable revenue; empty Team state',
    (tester) async {
      final controller = AdminController(
        FakeAuth(),
        ControlApi(config, FakeTransport()),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SubscriptionsView(
                Subscriptions({
                  'control': {'enabled': false, 'revision': 1},
                  'aggregates_available': true,
                  'policies': [],
                  'teams': [],
                }, overview: true),
                controller,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Monetization enforcement: OFF'), findsOneWidget);
      expect(
        find.text(
          'Store billing requires separate operator acceptance. Revenue / MRR: Unavailable.',
        ),
        findsOneWidget,
      );
      expect(find.text('No Teams returned.'), findsOneWidget);
    },
  );
  testWidgets('User Pro and Team limits are rendered without domain content', (
    tester,
  ) async {
    final controller = AdminController(
      FakeAuth(),
      ControlApi(config, FakeTransport()),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SubscriptionsView(
              Subscriptions({
                'user_id': userId,
                'plan': 'PRO',
                'sources': ['admin'],
                'limits': {'owned_cloud_limit': 10},
                'activation': {
                  'state': 'selection_required',
                  'owned_cloud_used': 12,
                },
                'teams': [
                  {
                    'id': otherId,
                    'name': 'Test Team',
                    'plan': 'TEAM',
                    'limits': {'seat_limit': 20},
                    'members_used': 11,
                  },
                ],
              }),
              controller,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Provided by LADNIK'), findsWidgets);
    expect(find.textContaining('selection_required'), findsOneWidget);
    expect(find.text('Test Team'), findsOneWidget);
    expect(find.text('No admin grants.'), findsOneWidget);
  });
  testWidgets(
    'Grant reason required; no expiry and typed override preview before confirmation',
    (tester) async {
      final transport = FakeTransport()
        ..project = (body) => {
          'preview': true,
          'before': null,
          'after': object(body['params'])['values'],
        };
      await editor(tester, ControlApi(config, transport));
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      expect(transport.requests, isEmpty);
      expect(find.textContaining('Preview unavailable'), findsOneWidget);
      await tester.ensureVisible(field('owned_cloud_limit'));
      await tester.enterText(field('owned_cloud_limit'), '20');
      await tester.ensureVisible(field('Required reason'));
      await tester.enterText(field('Required reason'), 'Tester 90 days');
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      final values = object(
        object(transport.requests.single['params'])['values'],
      );
      expect(values['expires_at'], null);
      expect(object(values['limits'])['owned_cloud_limit'], 20);
      expect(find.text('Confirm subscription change'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirm change'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('I confirm this impact'));
      await tester.tap(find.text('I confirm this impact'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirm change'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets('Team exact scope, complimentary seat override, default reset', (
    tester,
  ) async {
    final transport = FakeTransport()
      ..project = (_) => {'preview': true, 'before': null};
    await editor(tester, ControlApi(config, transport), team: true);
    await tester.ensureVisible(field('seat_limit'));
    await tester.enterText(field('seat_limit'), '20');
    await tester.ensureVisible(field('Required reason'));
    await tester.enterText(field('Required reason'), 'Extra seats');
    await tester.tap(find.text('Review impact'));
    await tester.pumpAndSettle();
    final values = object(
      object(transport.requests.single['params'])['values'],
    );
    expect(values['user_id'], null);
    expect(values['team_id'], otherId);
    expect(object(values['limits'])['seat_limit'], 20);
  });
  testWidgets(
    'Policy editor keeps typed policy scope and confirmation workflow',
    (tester) async {
      final transport = FakeTransport()
        ..project = (_) => {
          'preview': true,
          'before': {'limits': {}},
        };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriptionEditor(
              ControlApi(config, transport),
              'policy.set',
              {
                'plan': 'FREE',
                'limits': {
                  'owned_cloud_limit': 2,
                  'owned_shared_limit': 1,
                  'shared_member_limit': 2,
                  'team_workspace_limit': null,
                  'seat_limit': null,
                  'automation_limit': 3,
                  'ai_budget_micro_usd': 100000,
                },
              },
              1,
            ),
          ),
        ),
      );
      expect(field('ai_multiplier_bps'), findsNothing);
      await tester.ensureVisible(field('Required reason'));
      await tester.enterText(field('Required reason'), 'Policy revision');
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      expect(object(transport.requests.single['params'])['revision'], 1);
      expect(find.text('Confirm subscription change'), findsOneWidget);
    },
  );
  testWidgets('Server error leaves grant editable without optimistic success', (
    tester,
  ) async {
    final transport = FakeTransport()..status = 503;
    await editor(tester, ControlApi(config, transport));
    await tester.ensureVisible(field('Required reason'));
    await tester.enterText(field('Required reason'), 'Support');
    await tester.tap(find.text('Review impact'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Preview unavailable'), findsOneWidget);
    expect(find.text('Confirm change'), findsNothing);
  });
  testWidgets(
    'Loading preview, explicit confirmation and lost-response retry retain frozen correlation',
    (tester) async {
      final pending = Completer<ApiResponse>();
      final transport = FakeTransport();
      var applies = 0;
      bool? saved;
      transport.deferred = (body) async {
        if (body['action'] == 'subscriptions.preview') return pending.future;
        applies++;
        return applies == 1
            ? const ApiResponse(503, {'error': 'unavailable'})
            : reply(body, {'audit_id': userId, 'replayed': true});
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  saved = await showDialog<bool>(
                    context: context,
                    builder: (_) => SubscriptionEditor(
                      ControlApi(config, transport),
                      'grant.set',
                      grantValues(),
                      0,
                      id: userId,
                    ),
                  );
                },
                child: const Text('Open grant'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open grant'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('Required reason'));
      await tester.enterText(field('Required reason'), 'Support');
      await tester.tap(find.text('Review impact'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(applies, 0);
      pending.complete(
        reply(transport.requests.single, {'preview': true, 'before': null}),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('I confirm this impact'));
      await tester.tap(find.text('I confirm this impact'));
      await tester.pump();
      await tester.tap(find.text('Confirm change'));
      await tester.pumpAndSettle();
      expect(saved, null);
      expect(find.textContaining('Change not confirmed'), findsOneWidget);
      await tester.tap(find.text('Confirm change'));
      await tester.pumpAndSettle();
      expect(saved, true);
      expect(applies, 2);
      expect(
        transport.requests.map((r) => r['correlation_id']).toSet().length,
        1,
      );
      expect(transport.requests[1]['params'], transport.requests[2]['params']);
    },
  );
  testWidgets(
    'Owner can choose FREE personal AI override without Pro or Store promotion',
    (tester) async {
      final transport = FakeTransport()
        ..project = (_) => {'preview': true, 'before': null};
      await editor(tester, ControlApi(config, transport));
      await tester.tap(find.text('PRO').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('FREE personal override').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Effective plan stays Free'), findsOneWidget);
      await tester.ensureVisible(field('ai_budget_micro_usd'));
      await tester.enterText(field('ai_budget_micro_usd'), '1000000');
      await tester.ensureVisible(field('Required reason'));
      await tester.enterText(
        field('Required reason'),
        'Temporary AI allowance',
      );
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      final values = object(
        object(transport.requests.single['params'])['values'],
      );
      expect(values['plan'], 'FREE');
      expect(values['user_id'], userId);
      expect(values['team_id'], null);
      final limits = object(values['limits']);
      expect(limits['ai_budget_micro_usd'], 1000000);
      for (final key in [
        'owned_cloud_limit',
        'owned_shared_limit',
        'shared_member_limit',
        'automation_limit',
      ]) {
        expect(limits[key], null);
      }
      expect(transport.requests.single['action'], 'subscriptions.preview');
    },
  );
  testWidgets(
    'FREE effective plan and Provided by LADNIK override remain distinct from subscription',
    (tester) async {
      final controller = AdminController(
        FakeAuth(),
        ControlApi(config, FakeTransport()),
      );
      addTearDown(controller.dispose);
      final data = Subscriptions({
        'user_id': userId,
        'plan': 'FREE',
        'sources': ['admin'],
        'grants': [
          {
            'id': otherId,
            'revision': 1,
            'status': 'active',
            ...grantValues(),
            'plan': 'FREE',
            'limits': {'ai_budget_micro_usd': 1000000},
          },
        ],
      });
      expect(data.grants.single.personalOverride, true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SubscriptionsView(data, controller),
            ),
          ),
        ),
      );
      expect(find.textContaining('FREE personal override'), findsOneWidget);
      expect(find.textContaining('Provided by LADNIK'), findsWidgets);
      expect(
        find.text(
          'Store billing requires separate operator acceptance. Revenue / MRR: Unavailable.',
        ),
        findsOneWidget,
      );
    },
  );
}
