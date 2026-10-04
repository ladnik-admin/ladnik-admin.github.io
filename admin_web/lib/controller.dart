import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'auth.dart';
import 'models.dart';

enum Section { overview, users, health, releases, audit, moderation, aiSafety }

enum Access {
  signedOut,
  checking,
  ready,
  forbidden,
  environment,
  unavailable,
  invalidRequest,
}

class AdminController extends ChangeNotifier {
  final AuthGateway auth;
  final ControlApi api;
  StreamSubscription<AuthSession?>? _subscription;
  Timer? _expiry;
  int _generation = 0;
  bool _disposed = false, _loggingOut = false;
  AuthSession? _session;
  Access access = Access.signedOut;
  Section section = Section.overview;
  AdminData? data;
  String? loginError;
  String? usersSearch;
  String? moderationStatus;
  bool loginBusy = false;
  AdminController(this.auth, this.api);
  bool get signedIn => _session != null;
  String? get actorId => _session?.userId;
  void start() {
    _subscription = auth.changes.listen(
      _changed,
      onError: (Object _) {
        unawaited(logout());
      },
    );
    _changed(auth.session);
  }

  void _changed(AuthSession? session) {
    if (_disposed || _loggingOut) return;
    _clear();
    if (session == null) {
      _notify();
      return;
    }
    final duration = session.expiresAt.difference(DateTime.now());
    if (duration <= Duration.zero) {
      unawaited(logout());
      return;
    }
    _session = session;
    _expiry = Timer(duration, () {
      unawaited(logout());
    });
    unawaited(select(Section.overview));
  }

  void _clear() {
    _generation++;
    _expiry?.cancel();
    _expiry = null;
    _session = null;
    data = null;
    usersSearch = null;
    moderationStatus = null;
    section = Section.overview;
    access = Access.signedOut;
    loginError = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> login(String email, String password) async {
    if (loginBusy || _disposed) return;
    loginBusy = true;
    loginError = null;
    _notify();
    try {
      await auth.login(email.trim(), password);
      if (!_disposed && !signedIn) _changed(auth.session);
    } catch (_) {
      if (!_disposed) {
        loginError = 'Sign-in failed. Check your credentials or try again.';
      }
    } finally {
      loginBusy = false;
      _notify();
    }
  }

  Future<void> logout() async {
    if (_loggingOut || _disposed) return;
    _loggingOut = true;
    _clear();
    loginBusy = true;
    _notify();
    try {
      await auth.logout();
    } catch (_) {
      loginError = 'Session cleared locally. Sign-out could not be confirmed.';
    } finally {
      _loggingOut = false;
      loginBusy = false;
      _notify();
    }
  }

  Future<void> _load(Future<AdminData> Function() fetch) async {
    if (!signedIn || _disposed || _loggingOut) return;
    final generation = ++_generation;
    data = null;
    access = Access.checking;
    _notify();
    try {
      final result = await fetch();
      if (_disposed || generation != _generation || !signedIn) return;
      data = result;
      access = Access.ready;
    } on AdminException catch (error) {
      if (_disposed || generation != _generation) return;
      if (error.failure == AdminFailure.session) {
        await logout();
        return;
      }
      access = switch (error.failure) {
        AdminFailure.forbidden => Access.forbidden,
        AdminFailure.environment => Access.environment,
        AdminFailure.invalidRequest => Access.invalidRequest,
        _ => Access.unavailable,
      };
    } catch (_) {
      if (_disposed || generation != _generation) return;
      access = Access.unavailable;
    }
    _notify();
  }

  Future<void> select(Section value) async {
    section = value;
    await _load(switch (value) {
      Section.aiSafety => api.aiControl,
      Section.overview => api.overview,
      Section.users => () => api.users(search: usersSearch),
      Section.health => api.health,
      Section.releases => api.releases,
      Section.audit => api.audit,
      Section.moderation => () => api.moderation(status: moderationStatus),
    });
  }

  Future<void> searchUsers(String prefix) async {
    final query = prefix.trim();
    usersSearch = query.isEmpty ? null : query;
    section = Section.users;
    await _load(() => api.users(search: usersSearch));
  }

  Future<void> nextUsers() async {
    final current = data;
    if (current is! UserPage || current.nextAfter == null) return;
    await _load(() => api.users(search: usersSearch, after: current.nextAfter));
  }

  Future<void> showUser(String id) async {
    section = Section.users;
    await _load(() => api.user(id));
  }

  Future<void> nextAudit() async {
    final current = data;
    if (current is! AuditPage || current.next == null) return;
    await _load(() => api.audit(before: current.next));
  }

  Future<void> showReport(String id) async {
    section = Section.moderation;
    await _load(() => api.report(id));
  }

  Future<void> filterReports(String? status) async {
    moderationStatus = status;
    await select(Section.moderation);
  }

  Future<void> nextReports() async {
    final current = data;
    if (current is! ModerationPage || current.nextOffset == null) return;
    await _load(
      () =>
          api.moderation(status: moderationStatus, offset: current.nextOffset!),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _clear();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
