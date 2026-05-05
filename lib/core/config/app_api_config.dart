import 'package:flutter/foundation.dart';

class AppApiConfig {
  AppApiConfig._();

  static const String _fallbackTunnelBaseUrl =
       "https://nonredemptive-gyrational-pauletta.ngrok-free.dev/fsm_api";
  static const String _androidEmulatorBaseUrl = 'http://10.0.2.2/fsm_api';
  static const String _localMachineBaseUrl = 'http://127.0.0.1/fsm_api';
  static const String _apiRootPath = 'fsm_api';

  static String get baseUrl => _fallbackTunnelBaseUrl;

  static List<String> get candidateBaseUrls {
    final configured = const String.fromEnvironment('API_BASE_URL').trim();
    final platformDefault = _platformDefaultBaseUrl();
    final candidates = <String>[
      if (configured.isNotEmpty) configured,
      _fallbackTunnelBaseUrl,
      platformDefault,
      _localMachineBaseUrl,
    ];

    final normalized = <String>[];
    for (final candidate in candidates) {
      final value = _normalizeBaseUrl(candidate);
      if (!normalized.contains(value)) {
        normalized.add(value);
      }
    }
    return normalized;
  }

  static String get authBaseUrl => '$baseUrl/auth';

  static Uri endpointUri(String endpoint, {Map<String, String>? query}) {
    final cleaned = endpoint.trim().replaceFirst(RegExp(r'^/+'), '');
    final base = Uri.parse(baseUrl);
    final baseSegments =
        base.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final endpointSegments =
        cleaned.split('/').where((segment) => segment.isNotEmpty);
    final merged = <String>[
      ...baseSegments,
      ...endpointSegments,
    ];
    return base.replace(
      pathSegments: merged,
      queryParameters: query,
    );
  }

  static Map<String, String> buildHeaders({
    String? token,
    bool jsonContentType = true,
    bool formContentType = false,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json',
      'ngrok-skip-browser-warning': 'true',
    };

    if (jsonContentType) {
      headers['Content-Type'] = 'application/json';
    }
    if (formContentType) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    final normalizedToken = _normalizeToken(token);
    if (normalizedToken != null) {
      headers['Authorization'] = 'Bearer $normalizedToken';
    }

    return headers;
  }

  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return _fallbackTunnelBaseUrl;

    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return trimmed.endsWith('/')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
    }

    final segments =
        parsed.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) {
      segments.add(_apiRootPath);
    }

    final normalized = parsed.replace(pathSegments: segments).toString();
    return normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }

  static String? _normalizeToken(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      final withoutPrefix = trimmed.substring(7).trim();
      return withoutPrefix.isEmpty ? null : withoutPrefix;
    }
    return trimmed;
  }

  static String _platformDefaultBaseUrl() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidEmulatorBaseUrl;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return _localMachineBaseUrl;
    }
  }
}
