import 'maintenance_recovery.dart';

// Native test adapter; deployed Flutter Web uses browser persistence.
MaintenanceRecovery createRecovery() => _MemoryRecovery();

class _MemoryRecovery implements MaintenanceRecovery {
  final values = <String, String>{};
  @override
  String? read(String project, String actor) =>
      values[recoveryKey(project, actor)];
  @override
  Future<void> save(String project, String actor, String request) async {
    final previous = read(project, actor);
    if (previous != null && previous != request) {
      throw StateError('Unresolved command');
    }
    values[recoveryKey(project, actor)] = request;
  }

  @override
  Future<void> clear(String project, String actor, String request) async {
    if (read(project, actor) != request) throw StateError('Recovery changed');
    values.remove(recoveryKey(project, actor));
  }
}
