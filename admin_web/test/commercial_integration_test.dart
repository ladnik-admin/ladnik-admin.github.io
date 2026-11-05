import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/config.dart';

import '../../test_support/commercial_bridge.dart';

class ConnectedTransport implements AdminTransport {
  final CommercialBridge bridge;
  ConnectedTransport(this.bridge);
  @override
  Future<ApiResponse> invoke(Map<String, Object?> body) async {
    final result = await bridge.edge('admin', body);
    return ApiResponse(result['status'] as int, result['body']);
  }
}

void main() {
  final context = Platform.environment['LADNIK_SYNTHETIC_CONTEXT'];
  test(
    'Pages API v1 -> actual Edge -> exact stage PG; owner/CAS/ACL',
    () async {
      final bridge = CommercialBridge(context!);
      final api = ControlApi(
        const PublicConfig(
          'https://project.synthetic.invalid',
          'sb_publishable_synthetic',
          'staging',
        ),
        ConnectedTransport(bridge),
      );
      await api.subscriptions();
      final target = const Uuid().v4();
      final values = <String, Object?>{
        'plan': 'PRO',
        'user_id': bridge.fixture['other'],
        'team_id': null,
        'starts_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String(),
        'internal_note': '',
        'limits': <String, Object?>{},
        'revoked': false,
      };
      Future<dynamic> change(int revision, bool preview) =>
          api.changeSubscription(
            command: 'grant.set',
            target: target,
            revision: revision,
            values: values,
            reason: 'Synthetic connected Pages test',
            correlation: const Uuid().v4(),
            preview: preview,
          );
      await change(0, true);
      await change(0, false);
      await expectLater(
        change(0, false),
        throwsA(
          isA<AdminException>().having(
            (e) => e.failure,
            'failure',
            AdminFailure.conflict,
          ),
        ),
      );
      await api.subscription(bridge.fixture['other'] as String);
      bridge.actor = bridge.fixture['other'] as String;
      final projection = await bridge.rpc('commercial_snapshot', {});
      expect(projection['personal']['plan'], 'PRO');
      await expectLater(
        api.subscriptions(),
        throwsA(
          isA<AdminException>().having(
            (e) => e.failure,
            'failure',
            AdminFailure.forbidden,
          ),
        ),
      );
      bridge.actor = null;
      await expectLater(
        api.subscriptions(),
        throwsA(
          isA<AdminException>().having(
            (e) => e.failure,
            'failure',
            AdminFailure.session,
          ),
        ),
      );
    },
    skip: context == null
        ? 'Run via commercial_e2e_test.py (owned PG17 required)'
        : false,
  );
}
