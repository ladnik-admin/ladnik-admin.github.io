import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/app.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/moderation.dart';

import 'support.dart';

final report = <String, dynamic>{
  'id': userId,
  'status': 'pending',
  'reason': 'spam',
  'target_id': otherId,
  'reporter_id': userId,
  'target_username': 'target',
  'context_type': 'invitation',
  'workspace_id': otherId,
  'invitation_id': userId,
  'created_at': '2026-10-04T00:00:00Z',
  'state': 'SUSPENDED',
  'explanation': 'Caller explanation',
  'reporter': {'id': userId, 'first_name': 'Reporter', 'email': 'PRIVATE'},
  'target': {'id': otherId, 'username': 'target', 'note_body': 'SECRET'},
  'prior_reports': {'total': 3, 'open': 1},
  'private_workspace_content': 'SECRET',
  'invitation_quota': {
    'hour_count': 2,
    'day_count': 7,
    'hour_start': '2026-10-04T10:00:00+00:00',
    'utc_day': '2026-10-04',
    'query_text': 'PRIVATE',
  },
  'report_quota': {
    'hour_count': 1,
    'day_count': 3,
    'hour_start': '2026-10-04T10:00:00Z',
    'utc_day': '2026-10-04',
    'email': 'SECRET',
  },
};
void main() {
  test(
    'Counter observations reject malformed values and retain only typed fields',
    () {
      final valid = ModerationReport(report).invitationQuota;
      expect(valid.available, isTrue);
      expect(valid.hourCount, 2);
      expect(valid.dayCount, 7);
      expect(valid.hourStart, '2026-10-04T10:00:00+00:00');
      expect(valid.utcDay, '2026-10-04');
      expect(AbuseCounterObservation(null).available, isFalse);
      final raw = report['invitation_quota'] as Map<String, dynamic>;
      for (final bad in [
        {'hour_count': -1},
        {'hour_count': 1.5},
        {'day_count': '7'},
        {'hour_count': 2147483648},
        {'hour_start': 'PRIVATE'},
        {'hour_start': '2026-02-30T10:00:00Z'},
        {'hour_start': '2026-10-04T25:00:00Z'},
        {'utc_day': '2026-02-30'},
        {'utc_day': '2026-10-04PRIVATE'},
      ]) {
        expect(AbuseCounterObservation({...raw, ...bad}).available, isFalse);
      }
    },
  );
  test('Fixed mutations preserve exact correlation on retry and safe typed projections', () async {
    final remote = FakeTransport();
    final api = ControlApi(config, remote);
    final correlation = api.newCorrelation();
    await api.accountState(otherId, 'ACTIVE', null, 'Restored', correlation);
    await api.accountState(otherId, 'ACTIVE', null, 'Restored', correlation);
    expect(remote.requests[0], remote.requests[1]);
    expect(
      remote.requests.singleWhere(
        (_) => false,
        orElse: () => remote.requests.first,
      )['action'],
      'moderation.account_state',
    );
    expect(ModerationReport(report).reporter.containsKey('email'), false);
    expect(ModerationReport(report).target.containsKey('note_body'), false);
  });
  test('Moderation audit allows state/status/expiry only and discards unknown content', () {
    final event = AuditEvent({
      'safe_before': {'state': 'RESTRICTED', 'secret': 'PRIVATE'},
      'safe_after': {
        'state': 'ACTIVE',
        'status': 'invalid',
        'expires_at': 'PRIVATE',
      },
    });
    expect(event.beforeState, 'RESTRICTED');
    expect(event.afterState, 'ACTIVE');
    expect(event.afterStatus, isNull);
    expect(event.afterExpiry, isNull);
    final emoji = String.fromCharCode(0x1F600);
    expect(AuditEvent({'reason': emoji * 500}).reason, emoji * 500);
    expect(AuditEvent({'reason': emoji * 501}).reason, isNull);
  });
  Future<AdminController> controller(
    WidgetTester t, {
    bool ownerTarget = false,
  }) async {
    t.view.physicalSize = const Size(1280, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final auth = FakeAuth()..signIn();
    final remote = FakeTransport();
    remote.project = (body) => body['action'] == 'moderation.list'
        ? {
            'reports': [report],
          }
        : body['action'] == 'moderation.get'
        ? {...report, 'owner_target': ownerTarget}
        : body['action'] == 'moderation.account_state'
        ? {
            'before': {'state': 'SUSPENDED'},
            'after': {'state': (body['params'] as Map)['state']},
          }
        : body['action'] == 'moderation.report_status'
        ? {
            'before': {'status': 'pending'},
            'after': {'status': (body['params'] as Map)['status']},
          }
        : {};
    final state = AdminController(auth, ControlApi(config, remote));
    await t.runAsync(() async {
      state.start();
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      state.dispose();
      await auth.events.close();
    });
    await t.pumpAndSettle();
    return state;
  }

  testWidgets('Deleted target has unavailable state and absent counters', (
    t,
  ) async {
    final state = await controller(t);
    final deleted = {
      ...report,
      'target_id': null,
      'target_username': null,
      'target': null,
      'state': null,
      'expires_at': null,
      'owner_target': false,
      'invitation_quota': null,
      'report_quota': null,
    };
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationQueueView(
            ModerationPage({
              'reports': [deleted],
            }),
            state,
          ),
        ),
      ),
    );
    expect(find.text('pending · spam · Deleted account'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsOneWidget);
    expect(find.textContaining('ACTIVE'), findsNothing);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationDetailView(ModerationDetail(deleted), state),
        ),
      ),
    );
    expect(
      find.text('Enforcement: Unavailable · Expiry: None / indefinite'),
      findsOneWidget,
    );
    expect(find.text('Invitation: Unavailable'), findsOneWidget);
    expect(find.text('Reports: Unavailable'), findsOneWidget);
    expect(find.textContaining('ACTIVE'), findsNothing);
    expect(find.text('Restrict'), findsNothing);
    expect(find.text('Suspend'), findsNothing);
    expect(find.text('Restore'), findsNothing);
    final malformed = {
      ...deleted,
      'invitation_quota': {'hour_count': 'PRIVATE'},
    };
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationDetailView(ModerationDetail(malformed), state),
        ),
      ),
    );
    expect(find.text('Invitation: Unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
  });
  testWidgets('Queue and detail render safe metadata, reason and counts only', (
    t,
  ) async {
    final state = await controller(t);
    await state.select(Section.moderation);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationQueueView(state.data as ModerationPage, state),
        ),
      ),
    );
    expect(find.text('Moderation queue'), findsOneWidget);
    expect(find.text('pending · spam · target'), findsOneWidget);
    expect(
      t
          .widgetList<Text>(find.byType(Text))
          .any((text) => (text.data ?? '').contains(' ? ')),
      isFalse,
    );
    expect(find.textContaining('spam'), findsOneWidget);
    await t.tap(find.textContaining('spam'));
    await t.pumpAndSettle();
    expect(state.data, isA<ModerationDetail>());
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationDetailView(state.data as ModerationDetail, state),
        ),
      ),
    );
    expect(find.text('Caller explanation'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(
      find.textContaining('Previous reports: 3 · Open: 1'),
      findsOneWidget,
    );
    expect(find.text('Counter/bucket observations'), findsOneWidget);
    expect(
      find.textContaining('Invitation: Hour: 2 · Day: 7 · Hour bucket:'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Reports: Hour: 1 · Day: 3 · Hour bucket:'),
      findsOneWidget,
    );
    expect(find.textContaining('UTC day: 2026-10-04'), findsNWidgets(2));
    expect(
      t
          .widgetList<Text>(find.byType(Text))
          .any((text) => (text.data ?? '').contains(' ? ')),
      isFalse,
    );
  });
  for (final action in {
    'Restrict': 'RESTRICTED',
    'Suspend': 'SUSPENDED',
    'Restore': 'ACTIVE',
  }.entries) {
    testWidgets(
      '${action.key} requires confirmation/reason and refreshes returned state',
      (t) async {
        final state = await controller(t);
        await state.showReport(userId);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ModerationDetailView(state.data as ModerationDetail, state),
            ),
          ),
        );
        final remote = state.api.transport as FakeTransport;
        final before = remote.requests.length;
        await t.tap(find.text(action.key));
        await t.pumpAndSettle();
        expect(remote.requests.length, before);
        await t.tap(find.text('Confirm'));
        await t.pumpAndSettle();
        expect(remote.requests.length, before);
        await t.enterText(find.byType(TextField), 'Owner reason');
        await t.tap(find.text('Confirm'));
        await t.pumpAndSettle();
        expect(remote.requests.last['action'], 'moderation.account_state');
        expect((remote.requests.last['params'] as Map)['state'], action.value);
        expect(
          (remote.requests.last['params'] as Map)['reason'],
          'Owner reason',
        );
        if (action.value == 'ACTIVE') {
          expect((remote.requests.last['params'] as Map)['expires_at'], isNull);
        } else {
          expect(
            DateTime.parse(
              (remote.requests.last['params'] as Map)['expires_at'],
            ).isAfter(DateTime.now()),
            true,
          );
        }
        await t.tap(find.text('Done'));
        await t.pumpAndSettle();
        expect(remote.requests.last['action'], 'moderation.get');
      },
    );
  }
  testWidgets('Owner target does not expose Restrict or Suspend actions', (
    t,
  ) async {
    final state = await controller(t, ownerTarget: true);
    await state.showReport(userId);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationDetailView(state.data as ModerationDetail, state),
        ),
      ),
    );
    expect(find.text('Restrict'), findsNothing);
    expect(find.text('Suspend'), findsNothing);
    expect(find.text('Restore'), findsOneWidget);
  });
  testWidgets('Moderation owner denial uses the existing forbidden shell', (
    t,
  ) async {
    final state = await controller(t);
    (state.api.transport as FakeTransport).status = 403;
    await state.select(Section.moderation);
    await t.pumpWidget(MaterialApp(home: AdminShell(state, config)));
    expect(find.textContaining('Forbidden.'), findsOneWidget);
    expect(find.text('Caller explanation'), findsNothing);
  });
  testWidgets('Lost response retry retains correlation and expiry', (t) async {
    final state = await controller(t);
    await state.showReport(userId);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModerationDetailView(state.data as ModerationDetail, state),
        ),
      ),
    );
    final remote = state.api.transport as FakeTransport;
    await t.tap(find.text('Restrict'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Owner reason');
    remote.status = 503;
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();
    final first = remote.requests.last;
    remote.status = 200;
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();
    expect(remote.requests.last, first);
  });
}
