import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/releases.dart';

import 'support.dart';

Map<String, Object?> policy(String platform) => {
  'platform': platform,
  'latest_version': '1.1.0',
  'latest_build': 2,
  'minimum_version': '1.0.0',
  'minimum_build': 1,
  'store_url': platform == 'android'
      ? 'https://play.google.com/store/apps/details?id=com.ladnik.app'
      : 'https://apps.apple.com/app/id123456789',
  'published': false,
  'revision': 1,
};
void main() {
  test('typed policy mutation uses fixed route, CAS and correlation; reason rejection before transport', () async {
    final transport = FakeTransport()
      ..project = (_) => {'audit_id': userId, 'policy': policy('android')};
    final api = ControlApi(config, transport),
        p = ReleasePolicyData(policy('android'));
    await expectLater(
      api.setReleasePolicy(p, '', userId),
      throwsA(isA<AdminException>()),
    );
    expect(transport.requests, isEmpty);
    await api.setReleasePolicy(p, 'Owner acceptance', userId);
    expect(transport.requests.single['action'], 'release.policy.set');
    expect(transport.requests.single['correlation_id'], userId);
    expect((transport.requests.single['params'] as Map)['revision'], 1);
  });
  test('CAS conflicts stay distinct from environment mismatch', () async {
    final transport = FakeTransport()
      ..deferred = (body) async =>
          const ApiResponse(409, {'error': 'revision_conflict'});
    await expectLater(
      ControlApi(config, transport).setReleasePolicy(
        ReleasePolicyData(policy('android')),
        'Reason',
        userId,
      ),
      throwsA(
        isA<AdminException>().having(
          (error) => error.failure,
          'failure',
          AdminFailure.conflict,
        ),
      ),
    );
  });
  testWidgets(
    'Releases retains adoption view, two policy cards and edit/impact/reason/confirmation flow',
    (tester) async {
      final transport = FakeTransport();
      var writes = 0;
      transport.deferred = (body) async {
        if (body['action'] == 'release.policy.set') {
          writes++;
          return writes == 1
              ? const ApiResponse(503, {'error': 'unavailable'})
              : reply(body, {'audit_id': userId, 'policy': policy('android')});
        }
        return reply(body, {});
      };
      final controller = AdminController(
        FakeAuth(),
        ControlApi(config, transport),
      );
      addTearDown(controller.dispose);
      final data = Releases({
        'availability': 'available',
        'groups': [],
        'policies': [policy('android'), policy('ios')],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReleasesView(data, controller: controller),
            ),
          ),
        ),
      );
      expect(find.text('self-reported heartbeat'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-release-ios')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-release-android')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      expect(
        find.text('Check version/build values and enter a reason.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Required reason'),
        'Owner acceptance',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review impact'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(
        FilledButton,
        'Confirm policy change',
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, null);
      await tester.ensureVisible(
        find.text(
          'I confirm this impact and Store availability when published',
        ),
      );
      await tester.tap(
        find.text(
          'I confirm this impact and Store availability when published',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Change not confirmed. Check policy values or retry this confirmation.',
        ),
        findsOneWidget,
      );
      final first = transport.requests.last;
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final second = transport.requests.last;
      expect(second['correlation_id'], first['correlation_id']);
      expect(second['params'], first['params']);
      expect(find.text('Confirm android release policy'), findsNothing);
    },
  );
}
