import 'dart:async';

import 'package:ladnik_control_center/api.dart';
import 'package:ladnik_control_center/auth.dart';
import 'package:ladnik_control_center/config.dart';

const config = PublicConfig(
  'https://project.supabase.co',
  'sb_publishable_test_public',
  'development',
);
const userId = '00000000-0000-4000-8000-000000000001';
const otherId = '00000000-0000-4000-8000-000000000002';

class FakeAuth implements AuthGateway {
  AuthSession? current;
  final events = StreamController<AuthSession?>.broadcast(sync: true);
  int logouts = 0;
  bool failLogin = false;
  @override
  AuthSession? get session => current;
  @override
  Stream<AuthSession?> get changes => events.stream;
  void signIn([String id = userId]) {
    current = AuthSession(id, DateTime.now().add(const Duration(hours: 1)));
    events.add(current);
  }

  void loseSession() {
    current = null;
    events.add(null);
  }

  @override
  Future<void> login(String email, String password) async {
    if (failLogin) throw StateError('private auth internal');
    signIn();
  }

  @override
  Future<void> logout() async {
    logouts++;
    loseSession();
  }
}

class FakeTransport implements AdminTransport {
  final requests = <Map<String, Object?>>[];
  int status = 200;
  Object? Function(Map<String, Object?>) project = (_) => <String, Object?>{};
  Future<ApiResponse> Function(Map<String, Object?>)? deferred;
  @override
  Future<ApiResponse> invoke(Map<String, Object?> body) async {
    requests.add(body);
    if (deferred != null) return deferred!(body);
    return reply(body, project(body), status);
  }
}

ApiResponse reply(
  Map<String, Object?> request,
  Object? data, [
  int status = 200,
]) => ApiResponse(status, {
  'correlation_id': request['correlation_id'],
  'environment': {
    'label': config.environment,
    'project_url': config.projectUrl,
  },
  'data': data,
});
Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
}
