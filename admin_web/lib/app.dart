import 'sections/ai_safety.dart';
import 'sections/moderation.dart';

import 'package:flutter/material.dart';

import 'config.dart';
import 'controller.dart';
import 'models.dart';
import 'sections/overview.dart';
import 'sections/users.dart';
import 'sections/health.dart';
import 'sections/releases.dart';
import 'sections/audit.dart';

class ControlCenterApp extends StatefulWidget {
  final PublicConfig config;
  final AdminController? controller;
  final bool bootstrapFailed;
  const ControlCenterApp({
    super.key,
    required this.config,
    this.controller,
    this.bootstrapFailed = false,
  });
  @override
  State<ControlCenterApp> createState() => _ControlCenterAppState();
}

class _ControlCenterAppState extends State<ControlCenterApp> {
  @override
  void initState() {
    super.initState();
    if (widget.config.valid) widget.controller?.start();
  }

  @override
  void dispose() {
    widget.controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LADNIK Control Center',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF455A64)),
      scaffoldBackgroundColor: const Color(0xFFF5F6F7),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home:
        !widget.config.valid ||
            widget.controller == null ||
            widget.bootstrapFailed
        ? const Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: SizedBox(
                  width: 560,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Control Center configuration unavailable',
                        style: TextStyle(fontSize: 24),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Provide a valid SUPABASE_URL, public SUPABASE_PUBLISHABLE_KEY and LADNIK_CONTROL_ENVIRONMENT (development, staging or production). No session or Admin request is started without valid configuration.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : AnimatedBuilder(
            animation: widget.controller!,
            builder: (context, _) => widget.controller!.signedIn
                ? AdminShell(widget.controller!, widget.config)
                : LoginView(widget.controller!),
          ),
  );
}

class LoginView extends StatefulWidget {
  final AdminController controller;
  const LoginView(this.controller, {super.key});
  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final email = TextEditingController(), password = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  void login() {
    if (!form.currentState!.validate()) return;
    final secret = password.text;
    password.clear();
    widget.controller.login(email.text, secret);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'LADNIK Control Center',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('Admin Login'),
                const SizedBox(height: 24),
                TextFormField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) => v == null || !v.contains('@')
                      ? 'Enter your email.'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Password'),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Enter your password.' : null,
                  onFieldSubmitted: (_) {
                    if (!widget.controller.loginBusy) login();
                  },
                ),
                const SizedBox(height: 16),
                if (widget.controller.loginError != null)
                  Text(
                    widget.controller.loginError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                FilledButton(
                  onPressed: widget.controller.loginBusy ? null : login,
                  child: Text(
                    widget.controller.loginBusy ? 'Signing in…' : 'Sign in',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

const sectionLabels = {
  Section.aiSafety: 'AI Safety',
  Section.overview: 'Overview',
  Section.users: 'Users',
  Section.health: 'Health',
  Section.releases: 'Releases',
  Section.audit: 'Audit',
  Section.moderation: 'Moderation',
};

class AdminShell extends StatelessWidget {
  final AdminController controller;
  final PublicConfig config;
  const AdminShell(this.controller, this.config, {super.key});
  Widget navigation(BuildContext context, {bool drawer = false}) => Column(
    children: [
      const SizedBox(height: 16),
      for (final entry in sectionLabels.entries)
        ListTile(
          selected: controller.section == entry.key,
          title: Text(entry.value),
          onTap: () {
            if (drawer) Navigator.pop(context);
            controller.select(entry.key);
          },
        ),
      const Spacer(),
      ListTile(
        leading: const Icon(Icons.logout),
        title: const Text('Logout'),
        onTap: controller.logout,
      ),
      const SizedBox(height: 16),
    ],
  );
  Widget content() {
    if (controller.access != Access.ready) {
      return switch (controller.access) {
        Access.checking => const Center(child: CircularProgressIndicator()),
        Access.forbidden => const Text(
          'Forbidden. This authenticated account is not permitted to access Control Center.',
        ),
        Access.environment => const Text(
          'Environment mismatch. Check the public configuration before continuing.',
        ),
        Access.invalidRequest => const Text(
          'Request unavailable. Check the search or pagination input.',
        ),
        _ => const Text(
          'Control Center temporarily unavailable or not configured. Try Refresh later.',
        ),
      };
    }
    return switch (controller.data) {
      AiControl value => AiSafetyView(value, controller),
      Overview value => OverviewView(value),
      UserPage value => UsersView(value, controller),
      UserDetail value => UserDetailView(value, controller),
      SystemHealth value => HealthView(value),
      Releases value => ReleasesView(value),
      AuditPage value => AuditView(value, controller),
      ModerationPage value => ModerationQueueView(value, controller),
      ModerationDetail value => ModerationDetailView(value, controller),
      _ => const Text('Unavailable'),
    };
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 900;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            'Control Center · ${config.environment} · ${sectionLabels[controller.section]}',
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: controller.access == Access.checking
                  ? null
                  : () => controller.select(controller.section),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        drawer: wide ? null : Drawer(child: navigation(context, drawer: true)),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              SizedBox(
                width: 200,
                child: Material(
                  color: Colors.white,
                  child: navigation(context),
                ),
              ),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: controller.access == Access.checking
                  ? content()
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1200),
                          child: content(),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
