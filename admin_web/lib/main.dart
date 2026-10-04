import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'auth.dart';
import 'config.dart';
import 'controller.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = PublicConfig.fromDefines();
  if (!config.valid) {
    runApp(ControlCenterApp(config: config));
    return;
  }
  try {
    await Supabase.initialize(
      url: config.projectUrl,
      publishableKey: config.clientKey,
      debug: false,
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
    );
    final client = Supabase.instance.client;
    final controller = AdminController(
      SupabaseAuthGateway(client),
      ControlApi(config, SupabaseAdminTransport(client)),
    );
    runApp(ControlCenterApp(config: config, controller: controller));
  } catch (_) {
    runApp(ControlCenterApp(config: config, bootstrapFailed: true));
  }
}
