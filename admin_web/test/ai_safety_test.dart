import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';
import 'package:ladnik_control_center/sections/ai_safety.dart';

import 'support.dart';

const limits = <String, int>{
  'text_minute_limit': 2,
  'text_day_limit': 3,
  'text_month_limit': 4,
  'audio_minute_ms_limit': 1000,
  'audio_day_ms_limit': 2000,
  'audio_month_ms_limit': 3000,
};
final projection = <String, dynamic>{
  'enabled': true,
  'configured': true,
  'status': 'available',
  'exhausted': false,
  'limits': limits,
  'text_attempts': [1, 1, 1],
  'audio_attempts': [0, 0, 0],
  'audio_ms': [0, 0, 0],
  'windows': [
    '2026-10-04T12:00:00Z',
    '2026-10-04T00:00:00Z',
    '2026-10-01T00:00:00Z',
  ],
  'provider_response': 'PRIVATE',
  'api_key': 'PRIVATE',
  'monetary_cost': 0,
};
void main() {
  test(
    'Fixed control actions validate limits/reason/correlation before transport',
    () async {
      final transport = FakeTransport()..project = (_) => projection;
      final api = ControlApi(config, transport);
      expect((await api.aiControl()).monetaryCost, 'UNAVAILABLE');
      expect(transport.requests.single['action'], 'ai.control.get');
      for (final bad in [
        <String, int>{},
        {...limits, 'text_minute_limit': 4},
        {...limits, 'text_month_limit': 1000000000001},
      ]) {
        expect(
          () => api.setAiControl(true, bad, 'Acceptance', userId),
          throwsA(isA<AdminException>()),
        );
      }
      expect(
        () => api.setAiControl(true, limits, '', userId),
        throwsA(isA<AdminException>()),
      );
      expect(
        () => api.setAiControl(true, null, 'Acceptance', userId),
        throwsA(isA<AdminException>()),
      );
      expect(transport.requests.length, 1);
      await api.setAiControl(false, limits, 'Emergency', userId);
      expect(transport.requests.last['action'], 'ai.control.set');
      expect(transport.requests.last['correlation_id'], userId);
      transport.status = 403;
      await expectLater(
        api.aiControl(),
        throwsA(
          isA<AdminException>().having(
            (v) => v.failure,
            'failure',
            AdminFailure.forbidden,
          ),
        ),
      );
    },
  );
  test(
    'Health uses typed counters and reports unknown cost as unavailable',
    () {
      final health = SystemHealth({
        'ai': {'control': projection},
      });
      expect(health.sections['ai']!.control!.textAttempts, [1, 1, 1]);
      expect(health.sections['ai']!.control!.monetaryCost, 'UNAVAILABLE');
      expect(
        AiControl({
          'text_attempts': [-1, '2', 1],
        }).textAttempts,
        [null, null, 1],
      );
    },
  );
  testWidgets(
    'Disable requires confirmation and reason; ambiguous retry reuses correlation',
    (tester) async {
      final transport = FakeTransport()..project = (_) => projection;
      final auth = FakeAuth()..signIn();
      final controller = AdminController(auth, ControlApi(config, transport));
      controller.start();
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiSafetyView(AiControl(projection), controller),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Disable immediately'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disable immediately'));
      await tester.pumpAndSettle();
      expect(
        transport.requests.where((r) => r['action'] == 'ai.control.set'),
        isEmpty,
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        transport.requests.where((r) => r['action'] == 'ai.control.set'),
        isEmpty,
      );
      await tester.enterText(find.byType(TextField), 'Emergency');
      transport.status = 503;
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      final first = transport.requests.last;
      expect(first['action'], 'ai.control.set');
      expect((first['params'] as Map)['enabled'], false);
      transport.status = 200;
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      final attempts = transport.requests
          .where((r) => r['action'] == 'ai.control.set')
          .toList();
      expect(attempts.length, 2);
      expect(attempts[0]['correlation_id'], attempts[1]['correlation_id']);
      expect(find.text('PRIVATE'), findsNothing);
      expect(find.textContaining('UNAVAILABLE'), findsOneWidget);
      controller.dispose();
      await auth.events.close();
    },
  );
}
