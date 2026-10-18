import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/config.dart';
import 'package:ladnik_control_center/controller.dart';

import 'support.dart';

void main() {
  const path = String.fromEnvironment('LADNIK_PG_ROLLBACK_RECEIPT');
  test(
    'Actual native PG44 rollback responses clear stale Pages subscriptions',
    () async {
      final receipt = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(receipt['pass'], true);
      expect(receipt['schema_count'], 44);
      final responses = receipt['pagesResponses'] as List;
      expect(responses.map((r) => (r as Map)['component']), [
        'v12-alternative',
        'admin-v13',
        'v12-alternative',
      ]);
      const local = PublicConfig(
        'http://127.0.0.1:9000',
        'sb_publishable_synthetic',
        'development',
      );
      final auth = FakeAuth()..signIn();
      final transport = FakeTransport();
      var stage = 0;
      transport.deferred = (request) async {
        if (request['action'] != 'subscriptions.overview') {
          return reply(request, <String, Object?>{});
        }
        final saved = responses[stage] as Map;
        // Only the per-request nonce is rebound. Preserve actual native status,
        // environment, data and contract_version from the PG-backed rehearsal.
        final body = Map<String, Object?>.from(saved['body'] as Map)
          ..['correlation_id'] = request['correlation_id'];
        return ApiResponse(saved['status'] as int, body);
      };
      final controller = AdminController(auth, ControlApi(local, transport));
      addTearDown(() async {
        controller.dispose();
        await auth.events.close();
      });
      controller.start();
      await flush();
      for (stage = 0; stage < 3; stage++) {
        final before = transport.requests.length;
        await controller.select(Section.subscriptions);
        expect(transport.requests.length, before + 1);
        if (stage == 1) {
          expect(controller.access, Access.ready);
          expect(controller.data, isNotNull);
        } else {
          expect(controller.access, Access.invalidRequest);
          expect(controller.data, isNull);
        }
      }
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
    skip: path.isEmpty
        ? 'Run after provider_pg_rollback_test.py with its exact receipt'
        : false,
  );
}
