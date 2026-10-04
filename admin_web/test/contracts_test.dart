import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/config.dart';
import 'package:ladnik_control_center/controller.dart';
import 'package:ladnik_control_center/models.dart';

import 'support.dart';

void main() {
  test('Public configuration fails closed, including privileged keys and malformed URLs', () {
    expect(config.valid, true);
    final secret =
        'x.${base64Url.encode(utf8.encode('{"role":"service_role"}'))}.x';
    final anon = 'x.${base64Url.encode(utf8.encode('{"role":"anon"}'))}.x';
    for (final c in [
      const PublicConfig('', '', ''),
      PublicConfig(config.projectUrl, secret, 'production'),
      PublicConfig(config.projectUrl, 'sb_secret_bad', 'production'),
      PublicConfig(config.projectUrl, '', 'development'),
      PublicConfig(config.projectUrl, config.clientKey, 'unknown'),
      PublicConfig('https://project.test:bad', config.clientKey, 'development'),
      PublicConfig('http://production.test', config.clientKey, 'production'),
      PublicConfig('https://localhost:8080', config.clientKey, 'staging'),
      PublicConfig(
        '${config.projectUrl}/path',
        config.clientKey,
        'development',
      ),
    ]) {
      expect(c.valid, false);
    }
    expect(PublicConfig(config.projectUrl, anon, 'production').valid, true);
    expect(
      PublicConfig(
        'http://localhost:8080',
        config.clientKey,
        'development',
      ).valid,
      true,
    );
  });
  test('Typed client uses only six fixed read actions, fresh UUIDs and exact environment binding', () async {
    final remote = FakeTransport();
    final api = ControlApi(config, remote);
    await api.overview();
    await api.users();
    await api.user(userId);
    await api.health();
    await api.releases();
    await api.audit();
    expect(remote.requests.map((r) => r['action']), [
      'overview',
      'users.list',
      'users.get',
      'health',
      'releases',
      'audit.list',
    ]);
    expect(remote.requests.map((r) => r['correlation_id']).toSet().length, 6);
    for (final request in remote.requests) {
      expect(validUserId(request['correlation_id'] as String), true);
      expect(request.keys.toSet(), {
        'action',
        'correlation_id',
        'expected_environment',
        'expected_project_url',
        'params',
      });
      expect(request['expected_environment'], config.environment);
      expect(request['expected_project_url'], config.projectUrl);
    }
    expect(remote.requests[1]['params'], {'limit': 50});
    expect(remote.requests[2]['params'], {'user_id': userId});
    expect(remote.requests[5]['params'], {'limit': 50});
    for (final operation in [
      () => api.users(limit: 101),
      () => api.users(search: '%'),
      () => api.users(after: 'SQL'),
      () => api.user('not-a-uuid'),
      () => api.audit(limit: 0),
    ]) {
      await expectLater(operation(), throwsA(isA<AdminException>()));
    }
    expect(remote.requests.length, 6);
  });
  test('Client sanitizes status failures and rejects success from a different environment/correlation', () async {
    final remote = FakeTransport();
    final api = ControlApi(config, remote);
    for (final pair in [
      (401, AdminFailure.session),
      (403, AdminFailure.forbidden),
      (409, AdminFailure.environment),
      (503, AdminFailure.unavailable),
      (500, AdminFailure.unavailable),
    ]) {
      remote.status = pair.$1;
      await expectLater(
        api.overview(),
        throwsA(
          isA<AdminException>().having((e) => e.failure, 'failure', pair.$2),
        ),
      );
    }
    remote.deferred = (body) async => ApiResponse(200, {
      'correlation_id': body['correlation_id'],
      'environment': {'label': 'production', 'project_url': config.projectUrl},
      'data': {},
    });
    await expectLater(
      api.overview(),
      throwsA(
        isA<AdminException>().having(
          (e) => e.failure,
          'failure',
          AdminFailure.environment,
        ),
      ),
    );
    remote.deferred = (body) async => ApiResponse(200, {
      'correlation_id': otherId,
      'environment': {
        'label': config.environment,
        'project_url': config.projectUrl,
      },
      'data': {},
    });
    await expectLater(api.overview(), throwsA(isA<AdminException>()));
  });
  test('Overview distinguishes zero, scan-capped lower bounds and unavailable values', () {
    final value = Overview({
      'accounts': {'availability': 'available', 'value': 0},
      'workspaces': {
        'availability': 'unavailable',
        'reason': 'scan_cap',
        'lower_bound': 10000,
      },
    });
    expect(value.counters['accounts']!.label, '0');
    expect(value.counters['workspaces']!.label, 'Unavailable (at least 10000)');
    expect(value.counters['notifications']!.label, 'Unavailable');
    expect(
      Counter({'availability': 'unavailable', 'value': 0}).label,
      'Unavailable',
    );
  });
  test('Health never upgrades absent/unknown states to healthy', () {
    final health = SystemHealth({
      'state': 'incident',
      'push': {'state': 'degraded'},
      'ai': {'state': 'incident'},
      'database': {'state': 'healthy'},
    });
    expect(health.state, HealthState.incident);
    expect(health.sections['push']!.state, HealthState.degraded);
    expect(health.sections['ai']!.state, HealthState.incident);
    expect(health.sections['schema']!.state, HealthState.unknown);
    expect(healthState('invented'), HealthState.unknown);
  });
  group('Session-scoped controller', () {
    late FakeAuth auth;
    late FakeTransport remote;
    late AdminController state;
    setUp(() {
      auth = FakeAuth();
      remote = FakeTransport();
      state = AdminController(auth, ControlApi(config, remote));
      state.start();
    });
    tearDown(() async {
      state.dispose();
      await auth.events.close();
    });
    test('Ordinary account is forbidden solely from server denial; mismatches are separate', () async {
      remote.status = 403;
      auth.signIn();
      await flush();
      expect(state.access, Access.forbidden);
      expect(state.data, isNull);
      remote.status = 409;
      await state.select(Section.health);
      expect(state.access, Access.environment);
    });
    test(
      'Users prefix/pagination is bounded; a new query resets UUID cursor',
      () async {
        remote.project = (r) => {
          'users': [
            {'id': userId, 'username': 'first'},
          ],
          'next_after': otherId,
        };
        auth.signIn();
        await flush();
        await state.searchUsers('abc');
        await state.nextUsers();
        expect(remote.requests.last['params'], {
          'limit': 50,
          'search': 'abc',
          'after': otherId,
        });
        expect((state.data as UserPage).users.length, 1);
        await state.searchUsers('xyz');
        expect(remote.requests.last['params'], {'limit': 50, 'search': 'xyz'});
        await state.showUser(userId);
        expect(remote.requests.last['action'], 'users.get');
      },
    );
    test('Audit pagination sends the timestamp/UUID pair, replacing a bounded page', () async {
      remote.project = (r) => {
        'events': [
          {'id': userId},
        ],
        'next_before': '2026-10-04T10:00:00Z',
        'next_before_id': otherId,
      };
      auth.signIn();
      await flush();
      await state.select(Section.audit);
      await state.nextAudit();
      expect(remote.requests.last['params'], {
        'limit': 50,
        'before': '2026-10-04T10:00:00Z',
        'before_id': otherId,
      });
      expect((state.data as AuditPage).events.length, 1);
    });
    test('Logout and Auth loss clear projections and discard every pending section response', () async {
      auth.signIn();
      await flush();
      expect(state.data, isA<Overview>());
      for (final section in Section.values) {
        final pending = Completer<ApiResponse>();
        remote.deferred = (_) => pending.future;
        final loading = state.select(section);
        final request = remote.requests.last;
        auth.loseSession();
        expect(state.data, isNull);
        expect(state.access, Access.signedOut);
        pending.complete(
          reply(request, {
            'accounts': {'availability': 'available', 'value': 99},
          }),
        );
        await loading;
        expect(state.data, isNull);
        expect(state.signedIn, false);
        remote.deferred = null;
        auth.signIn();
        await flush();
      }
      await state.searchUsers('abc');
      await state.logout();
      expect(state.data, isNull);
      expect(state.usersSearch, isNull);
      expect(state.access, Access.signedOut);
      expect(auth.logouts, 1);
    });
    test('401 clears data and normal Auth session; late prior-user responses cannot replace a new session', () async {
      auth.signIn();
      await flush();
      remote.status = 401;
      await state.select(Section.users);
      expect(state.data, isNull);
      expect(state.signedIn, false);
      expect(auth.logouts, 1);
      remote.status = 200;
      auth.signIn();
      await flush();
      final pending = Completer<ApiResponse>();
      remote.deferred = (_) => pending.future;
      final old = state.select(Section.health);
      final request = remote.requests.last;
      auth.loseSession();
      remote.deferred = null;
      auth.signIn(otherId);
      await flush();
      pending.complete(reply(request, {'state': 'healthy'}));
      await old;
      expect(state.data, isA<Overview>());
      expect(state.section, Section.overview);
    });
    test('Navigation races discard stale data; disposal clears data and subscriptions', () async {
      auth.signIn();
      await flush();
      final pending = Completer<ApiResponse>();
      remote.deferred = (_) => pending.future;
      final old = state.select(Section.users);
      final request = remote.requests.last;
      remote.deferred = null;
      await state.select(Section.releases);
      pending.complete(
        reply(request, {
          'users': [
            {'id': userId},
          ],
        }),
      );
      await old;
      expect(state.data, isA<Releases>());
    });
  });
}
