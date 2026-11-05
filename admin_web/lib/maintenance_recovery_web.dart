import 'dart:js_interop';

import 'maintenance_recovery.dart';

@JS('window.localStorage.getItem')
external String? _read(String key);
@JS('window.localStorage.setItem')
external void _save(String key, String value);
@JS('window.localStorage.removeItem')
external void _clear(String key);
@JS('navigator.locks.request')
external JSPromise<JSAny?> _lock(String name, JSFunction callback);

MaintenanceRecovery createRecovery() => _BrowserRecovery();

class _BrowserRecovery implements MaintenanceRecovery {
  @override
  String? read(String project, String actor) =>
      _read(recoveryKey(project, actor));
  @override
  Future<void> save(String project, String actor, String request) =>
      _exclusive(project, actor, () {
        final key = recoveryKey(project, actor);
        final previous = _read(key);
        if (previous != null && previous != request) {
          throw StateError('Unresolved command');
        }
        _save(key, request);
        if (_read(key) != request) throw StateError('Recovery unavailable');
      });

  @override
  Future<void> clear(String project, String actor, String request) =>
      _exclusive(project, actor, () {
        final key = recoveryKey(project, actor);
        if (_read(key) != request) throw StateError('Recovery changed');
        _clear(key);
      });

  // Web Locks serialize the check/write across same-origin tabs and workers.
  // Missing/denied Web Locks rejects persistence and therefore refuses SEND.
  Future<void> _exclusive(
    String project,
    String actor,
    void Function() change,
  ) async {
    var succeeded = false;
    final callback = ((JSAny? _) {
      try {
        change();
        succeeded = true;
      } catch (_) {
        /* fail closed */
      }
      return true.toJS;
    }).toJS;
    await _lock(recoveryKey(project, actor), callback).toDart;
    if (!succeeded) throw StateError('Recovery unavailable or unresolved');
  }
}
