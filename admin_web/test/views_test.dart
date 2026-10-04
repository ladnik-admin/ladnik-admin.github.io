import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/app.dart';
import 'package:ladnik_control_center/auth.dart';
import 'package:ladnik_control_center/config.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/users.dart';
import 'package:ladnik_control_center/sections/health.dart';
import 'package:ladnik_control_center/sections/releases.dart';
import 'package:ladnik_control_center/sections/audit.dart';

import 'support.dart';

void main() {
  late FakeAuth auth;
  late FakeTransport remote;
  late AdminController state;
  setUp(() {
    auth = FakeAuth();
    remote = FakeTransport();
    state = AdminController(auth, ControlApi(config, remote));
  });
  Future<void> mount(
    WidgetTester tester, {
    bool signedIn = false,
    PublicConfig publicConfig = config,
    double width = 1280,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (signedIn) auth.signIn();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.events.close();
    });
    await tester.pumpWidget(
      ControlCenterApp(config: publicConfig, controller: state),
    );
    await tester.pumpAndSettle();
  }

  Future<void> standalone(WidgetTester tester, Widget view) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await auth.events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: view)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Missing public configuration shows fail-closed screen without Auth/API bootstrap',
    (tester) async {
      await mount(tester, publicConfig: const PublicConfig('', '', ''));
      expect(
        find.text('Control Center configuration unavailable'),
        findsOneWidget,
      );
      expect(remote.requests, isEmpty);
      expect(auth.events.hasListener, false);
    },
  );
  testWidgets(
    'Login uses normal Auth; signed-in shell is authorized only through API',
    (tester) async {
      await mount(tester);
      expect(find.text('Admin Login'), findsOneWidget);
      expect(remote.requests, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'operator@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password',
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Admin Login'), findsNothing);
      expect(find.text('Overview'), findsOneWidget);
      expect(remote.requests.single['action'], 'overview');
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      expect(find.text('Admin Login'), findsOneWidget);
      expect(state.data, isNull);
    },
  );
  testWidgets('Login errors never display Auth/provider internal messages', (
    tester,
  ) async {
    auth.failLogin = true;
    await mount(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'operator@example.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'password',
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign-in failed'), findsOneWidget);
    expect(find.textContaining('private auth internal'), findsNothing);
  });
  for (final pair in [
    (403, 'Forbidden.'),
    (409, 'Environment mismatch.'),
    (503, 'temporarily unavailable'),
  ]) {
    testWidgets('Signed-in ${pair.$1} outcome has sanitized presentation', (
      tester,
    ) async {
      remote.status = pair.$1;
      await mount(tester, signedIn: true);
      expect(find.textContaining(pair.$2), findsOneWidget);
      expect(state.data, isNull);
      expect(find.text('Logout'), findsOneWidget);
    });
  }
  testWidgets(
    'Overview shows exact available and scan-capped/unavailable values',
    (tester) async {
      remote.project = (_) => {
        'accounts': {'availability': 'available', 'value': 4},
        'workspaces': {
          'availability': 'unavailable',
          'lower_bound': 10000,
          'reason': 'scan_cap',
        },
      };
      await mount(tester, signedIn: true);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Unavailable (at least 10000)'), findsOneWidget);
      expect(find.text('Unavailable'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Unsupported metrics'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('DAU: Unavailable'), findsOneWidget);
      expect(find.text('AI cost: Unavailable'), findsOneWidget);
    },
  );
  testWidgets(
    'Users UI enforces prefix contract, resets search cursor and shows empty state',
    (tester) async {
      remote.project = (r) => r['action'] == 'users.list'
          ? {
              'users': [
                {'id': userId, 'username': 'safe'},
              ],
              'next_after': otherId,
            }
          : {};
      await mount(tester, signedIn: true);
      await tester.tap(find.text('Users'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Username prefix'),
        'ab',
      );
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter 3–32'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Username prefix'),
        'abc',
      );
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next page'));
      await tester.pumpAndSettle();
      expect(remote.requests.last['params'], {
        'limit': 50,
        'search': 'abc',
        'after': otherId,
      });
      remote.project = (_) => {'users': []};
      await tester.tap(find.text('First page'));
      await tester.pumpAndSettle();
      expect(find.text('No accounts on this page.'), findsOneWidget);
    },
  );
  testWidgets(
    'User detail renders only approved metadata, observations and audit safe booleans',
    (tester) async {
      final detail = UserDetail({
        'found': true,
        'user': {
          'id': userId,
          'username': 'safe_name',
          'verified': true,
          'lifecycle': 'available',
          'email': 'PRIVATE_EMAIL',
          'last_name': 'PRIVATE_SURNAME',
          'workspace_names': ['PRIVATE_WORKSPACE'],
          'notes': ['PRIVATE_NOTE'],
          'avatar_path': 'PRIVATE_AVATAR',
          'token': 'PRIVATE_TOKEN',
        },
        'latest_app_signal': {
          'platform': 'android',
          'app_version': '0.9.0',
          'build_number': '1',
          'last_seen_at': '2026-10-04T00:00:00Z',
          'secret': 'PRIVATE_SIGNAL',
        },
        'ai': {
          'availability': 'available',
          'window_days': 30,
          'summary': {'requests': 7, 'prompt': 'PRIVATE_PROMPT'},
        },
        'audit': [
          {
            'action_type': 'account_signal',
            'safe_before': {'enabled': false, 'secret': 'PRIVATE_BEFORE'},
            'safe_after': {'enabled': true},
          },
        ],
      });
      await standalone(tester, UserDetailView(detail, state));
      expect(find.text('UUID: $userId'), findsOneWidget);
      expect(find.text('Username: safe_name'), findsOneWidget);
      expect(find.text('Verified: true'), findsOneWidget);
      expect(find.text('requests: 7'), findsOneWidget);
      expect(find.text('Safe before: Enabled: false'), findsOneWidget);
      expect(find.text('Safe after: Enabled: true'), findsOneWidget);
      expect(find.textContaining('PRIVATE_'), findsNothing);
    },
  );
  testWidgets(
    'Health retains unknown/degraded/incident and uses text as well as icons',
    (tester) async {
      await standalone(
        tester,
        HealthView(
          SystemHealth({
            'state': 'incident',
            'push': {'state': 'degraded'},
            'ai': {'state': 'incident'},
          }),
        ),
      );
      expect(find.text('incident'), findsNWidgets(2));
      expect(find.text('degraded'), findsOneWidget);
      expect(find.text('unknown'), findsNWidgets(5));
      expect(find.byIcon(Icons.help_outline), findsNWidgets(5));
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    },
  );
  testWidgets(
    'Releases labels heartbeat observation without active-users or DAU claims',
    (tester) async {
      await standalone(
        tester,
        ReleasesView(
          Releases({
            'availability': 'available',
            'window_days': 30,
            'groups': [
              {
                'platform': 'android',
                'app_version': '0.9.0',
                'build_number': '1',
                'installations': 2,
                'accounts': 1,
                'first_seen': '2026-10-03',
                'last_seen': '2026-10-04',
              },
            ],
          }),
        ),
      );
      expect(find.text('self-reported heartbeat'), findsOneWidget);
      expect(find.text('Installation count: 2'), findsOneWidget);
      expect(find.text('Account count: 1'), findsOneWidget);
      expect(find.textContaining('active users'), findsNothing);
      expect(find.textContaining('active installs'), findsNothing);
      expect(find.textContaining('DAU'), findsNothing);
    },
  );
  testWidgets(
    'Releases unavailable telemetry never renders supplied groups as available',
    (tester) async {
      await standalone(
        tester,
        ReleasesView(
          Releases({
            'availability': 'unavailable',
            'groups': [
              {'platform': 'SHOULD_NOT_RENDER'},
            ],
          }),
        ),
      );
      expect(find.text('Release telemetry unavailable.'), findsOneWidget);
      expect(find.text('SHOULD_NOT_RENDER'), findsNothing);
    },
  );
  testWidgets('Audit is read-only and exposes only bounded cursor navigation', (
    tester,
  ) async {
    await standalone(
      tester,
      AuditView(
        AuditPage({
          'events': [
            {
              'action_type': 'owner_change',
              'admin_actor': userId,
              'target_id': otherId,
              'reason': 'review',
              'result': 'ok',
              'correlation_id': userId,
              'occurred_at': '2026-10-04T00:00:00Z',
            },
          ],
        }),
        state,
      ),
    );
    for (final forbidden in ['Delete', 'Edit', 'Clear', 'Export all']) {
      expect(find.text(forbidden), findsNothing);
    }
    expect(find.text('Actor: $userId'), findsOneWidget);
    expect(find.text('Target: $otherId'), findsOneWidget);
    expect(find.text('Latest page'), findsOneWidget);
    expect(find.text('Older page'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Older page'))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'Session expiry clears displayed Admin projections and returns to Login',
    (tester) async {
      auth.current = AuthSession(
        userId,
        DateTime.now().add(const Duration(minutes: 1)),
      );
      remote.project = (_) => {
        'accounts': {'availability': 'available', 'value': 987},
      };
      await mount(tester);
      expect(find.text('987'), findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(find.text('987'), findsNothing);
      expect(find.text('Admin Login'), findsOneWidget);
      expect(state.data, isNull);
    },
  );
  testWidgets('Session loss clears current view immediately', (tester) async {
    remote.project = (_) => {
      'accounts': {'availability': 'available', 'value': 987},
    };
    await mount(tester, signedIn: true);
    auth.loseSession();
    await tester.pumpAndSettle();
    expect(find.text('987'), findsNothing);
    expect(find.text('Admin Login'), findsOneWidget);
    expect(state.data, isNull);
  });
  testWidgets('Tablet shell uses drawer navigation without overflow', (
    tester,
  ) async {
    await mount(tester, signedIn: true, width: 760);
    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Users'), findsOneWidget);
    await tester.tap(find.text('Users'));
    await tester.pumpAndSettle();
    expect(state.section, Section.users);
    expect(tester.takeException(), isNull);
  });
}
