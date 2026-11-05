@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:ladnik_control_center/maintenance_recovery.dart';

void main() {
  test('Browser exclusive lock admits one concurrent journal writer', () async {
    final project = 'https://fixture.invalid/${const Uuid().v4()}';
    final actor = const Uuid().v4();
    final requests = [const Uuid().v4(), const Uuid().v4()];
    final first = createMaintenanceRecovery(),
        second = createMaintenanceRecovery();
    Future<bool> attempt(MaintenanceRecovery store, String request) async {
      try {
        await store.save(project, actor, request);
        return true;
      } catch (_) {
        return false;
      }
    }

    final results = await Future.wait([
      attempt(first, requests[0]),
      attempt(second, requests[1]),
    ]);
    expect(results.where((r) => r).length, 1);
    final winner = requests[results.indexOf(true)];
    expect(first.read(project, actor), winner);
    expect(second.read(project, actor), winner);
    await first.clear(project, actor, winner);
  });

  test('Browser replacement instance recovers exact actor/project and clear matches', () async {
    final project = 'https://fixture.invalid/${const Uuid().v4()}';
    final actor = const Uuid().v4(), request = const Uuid().v4();
    await createMaintenanceRecovery().save(project, actor, request);
    final reloaded = createMaintenanceRecovery();
    expect(reloaded.read(project, actor), request);
    expect(reloaded.read(project, const Uuid().v4()), isNull);
    await expectLater(
      reloaded.save(project, actor, const Uuid().v4()),
      throwsA(anything),
    );
    await expectLater(
      reloaded.clear(project, actor, const Uuid().v4()),
      throwsA(anything),
    );
    expect(reloaded.read(project, actor), request);
    await reloaded.clear(project, actor, request);
    expect(reloaded.read(project, actor), isNull);
  });
}
