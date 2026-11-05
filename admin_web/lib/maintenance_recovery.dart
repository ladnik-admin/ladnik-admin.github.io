import 'maintenance_recovery_memory.dart'
    if (dart.library.js_interop) 'maintenance_recovery_web.dart'
    as platform;

/// Scoped atomic journal slot: M7 stores an unresolved UUID; the separate notice
/// namespace stores UUID plus expected operation/notice/revision metadata. Never
/// stores notice text, a nonce, token, password or authentication proof.
abstract interface class MaintenanceRecovery {
  String? read(String project, String actor);
  Future<void> save(String project, String actor, String request);
  Future<void> clear(String project, String actor, String request);
}

MaintenanceRecovery createMaintenanceRecovery() => platform.createRecovery();
String recoveryKey(String project, String actor) =>
    'ladnik.maintenance.pending.v2:$project:$actor';
