import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

class AuthSession {
  final String userId;
  final DateTime expiresAt;
  const AuthSession(this.userId, this.expiresAt);
}

abstract interface class AuthGateway {
  AuthSession? get session;
  Stream<AuthSession?> get changes;
  Future<void> login(String email, String password);
  Future<void> logout();
}

class SupabaseAuthGateway implements AuthGateway {
  final SupabaseClient client;
  SupabaseAuthGateway(this.client);
  AuthSession? _signal(Session? value) => value?.expiresAt == null
      ? null
      : AuthSession(
          value!.user.id,
          DateTime.fromMillisecondsSinceEpoch(value.expiresAt! * 1000),
        );
  @override
  AuthSession? get session => _signal(client.auth.currentSession);
  @override
  Stream<AuthSession?> get changes =>
      client.auth.onAuthStateChange.map((event) => _signal(event.session));
  @override
  Future<void> login(String email, String password) async {
    await client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<void> logout() => client.auth.signOut(scope: SignOutScope.local);
}

class SupabaseAdminTransport implements AdminTransport {
  final SupabaseClient client;
  SupabaseAdminTransport(this.client);
  @override
  Future<ApiResponse> invoke(Map<String, Object?> body) async {
    final session = client.auth.currentSession;
    if (session == null || session.isExpired) {
      return const ApiResponse(401, null);
    }
    try {
      final result = await client.functions
          .invoke(
            'admin-control',
            body: body,
            headers: {'Authorization': 'Bearer ${session.accessToken}'},
          )
          .timeout(const Duration(seconds: 15));
      return ApiResponse(result.status, result.data);
    } on FunctionException catch (error) {
      // Never retain/render error details or provider/database messages.
      return ApiResponse(error.status, null);
    } catch (_) {
      return const ApiResponse(503, null);
    }
  }
}
