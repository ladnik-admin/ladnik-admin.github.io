import 'dart:convert';

class PublicConfig {
  final String projectUrl, clientKey, environment;
  const PublicConfig(this.projectUrl, this.clientKey, this.environment);
  factory PublicConfig.fromDefines() => const PublicConfig(
    String.fromEnvironment('SUPABASE_URL'),
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    String.fromEnvironment('LADNIK_CONTROL_ENVIRONMENT'),
  );
  bool get valid {
    try {
      if (!['development', 'staging', 'production'].contains(environment)) {
        return false;
      }
      final uri = Uri.tryParse(projectUrl);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.origin != projectUrl) {
        return false;
      }
      final local = ['localhost', '127.0.0.1', '::1'].contains(uri.host);
      if (uri.scheme != 'https' &&
          !(environment == 'development' && local && uri.scheme == 'http')) {
        return false;
      }
      if (local && environment != 'development') {
        return false;
      }
      if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(clientKey)) {
        return true;
      }
      // Key hygiene only; user authorization is exclusively the server's job.
      final parts = clientKey.split('.');
      if (parts.length != 3) {
        return false;
      }
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return claims is Map && claims['role'] == 'anon';
    } catch (_) {
      return false;
    }
  }
}
