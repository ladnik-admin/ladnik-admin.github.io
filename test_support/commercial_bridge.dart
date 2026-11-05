// Test-only stdio bridge. The Python side rejects non-disposable identities.
import 'dart:convert';
import 'dart:io';

class CommercialBridge {
  final String context;
  final Map<String, dynamic> fixture;
  String? actor;
  CommercialBridge(this.context)
    : fixture = jsonDecode(File(context).readAsStringSync()) {
    actor = fixture['owner'] as String;
  }

  Future<Map<String, dynamic>> send(Map<String, Object?> request) async {
    final python = Platform.environment['LADNIK_TEST_PYTHON'];
    if (python == null) throw StateError('DISPOSABLE_RUNNER_REQUIRED');
    final script = File('../supabase/tests/commercial_e2e_bridge.py').absolute;
    final process = await Process.start(python, [
      '-X',
      'utf8',
      script.path,
      '--context',
      context,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(jsonEncode(request));
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 120));
    if (code != 0) throw StateError(await errors);
    return jsonDecode(await output) as Map<String, dynamic>;
  }

  Future<dynamic> rpc(String name, Map<String, dynamic> args) async {
    final result = await send({
      'operation': 'rpc',
      'name': name,
      'args': args,
      'actor': actor,
    });
    if (result['error'] != null) throw StateError('${result['error']}');
    return result['data'];
  }

  Future<Map<String, dynamic>> edge(
    String lane,
    Map<String, Object?> body, {
    String route = 'reconcile',
    List<Map<String, Object?>> subscriptions = const [],
  }) => send({
    'operation': 'edge',
    'lane': lane,
    'route': route,
    'body': body,
    'actor': actor,
    'subscriptions': subscriptions,
  });
}
