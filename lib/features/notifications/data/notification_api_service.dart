import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/core/network/resilient_http.dart';

class NotificationApiService {
  NotificationApiService({required this.baseUrl});

  final String baseUrl;
  static const Duration _requestTimeout = Duration(seconds: 10);

  bool _isLikelyHtml(String body) {
    final lower = body.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') || lower.startsWith('<html');
  }

  String? _normalizeToken(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      final withoutPrefix = trimmed.substring(7).trim();
      return withoutPrefix.isEmpty ? null : withoutPrefix;
    }
    return trimmed;
  }

  Exception _mapTransportError(Object error) {
    if (error is TimeoutException) {
      return Exception(
        'Notification request timed out. Make sure API is reachable.',
      );
    }
    if (error is SocketException || error is http.ClientException) {
      return Exception(
        'Unable to reach notification service.',
      );
    }
    if (error is Exception) return error;
    return Exception('Unexpected notification error');
  }

  Uri _uri(String endpoint, {Map<String, String>? query}) {
    final base = Uri.parse(baseUrl);
    final baseSegments =
        base.pathSegments.where((segment) => segment.isNotEmpty).toList();
    final endpointSegments =
        endpoint.split('/').where((segment) => segment.isNotEmpty);

    return base.replace(
      pathSegments: <String>[...baseSegments, ...endpointSegments],
      queryParameters: query,
    );
  }

  Map<String, String> _headers(String token) {
    return AppApiConfig.buildHeaders(token: token);
  }

  List<Map<String, dynamic>> _extractList(dynamic data) {
    if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList();
    }
    if (data is Map<String, dynamic>) {
      final list = data['notifications'] ?? data['data'] ?? data['items'];
      if (list is List) {
        return list.whereType<Map<String, dynamic>>().toList();
      }
    }
    return <Map<String, dynamic>>[];
  }

  dynamic _decodeBody(http.Response response, {required String fallback}) {
    if (_isLikelyHtml(response.body)) {
      throw Exception('API returned HTML. Check API URL.');
    }

    if (response.body.trim().isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      throw Exception(fallback);
    }

    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw Exception(fallback);
    }
  }

  // =========================
  // FETCH NOTIFICATIONS
  // =========================
  Future<List<Map<String, dynamic>>> fetchNotifications({
    required String? token,
    int limit = 20,
    int? afterId,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    try {
      final query = <String, String>{'limit': '$limit'};
      if (afterId != null) query['after_id'] = '$afterId';

      final response = await ResilientHttp.get(
        uri: _uri('notifications/list.php', query: query),
        headers: _headers(normalizedToken),
        timeout: _requestTimeout,
      );

      final data = _decodeBody(response, fallback: 'Failed to fetch notifications');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (data is Map<String, dynamic>) {
          throw Exception(data['message'] ?? 'Failed to fetch notifications');
        }
        throw Exception('Failed to fetch notifications');
      }

      return _extractList(data);
    } catch (error) {
      throw _mapTransportError(error);
    }
  }

  // =========================
  // UNREAD COUNT
  // =========================
  Future<int> fetchUnreadCount({
    required String? token,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    try {
      final response = await ResilientHttp.get(
        uri: _uri('notifications/unread_count.php'),
        headers: _headers(normalizedToken),
        timeout: _requestTimeout,
      );

      final data = _decodeBody(response, fallback: 'Failed to fetch unread count');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (data is Map<String, dynamic>) {
          throw Exception(data['message'] ?? 'Failed to fetch unread count');
        }
        throw Exception('Failed to fetch unread count');
      }

      if (data is Map<String, dynamic>) {
        final value = data['unread_count'];
        if (value is int) return value;
        if (value is num) return value.toInt();
        return int.tryParse(value?.toString() ?? '') ?? 0;
      }

      return 0;
    } catch (error) {
      throw _mapTransportError(error);
    }
  }

  // =========================
  // MARK ALL READ
  // =========================
  Future<void> markAllRead({required String? token}) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    try {
      final response = await ResilientHttp.post(
        uri: _uri('notifications/mark_read.php'),
        headers: _headers(normalizedToken),
        body: jsonEncode({}),
        timeout: _requestTimeout,
      );

      final data = _decodeBody(response, fallback: 'Failed to mark read');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (data is Map<String, dynamic>) {
          throw Exception(data['message'] ?? 'Failed to mark read');
        }
        throw Exception('Failed to mark read');
      }
    } catch (error) {
      throw _mapTransportError(error);
    }
  }

  // =========================
  // 🔥 SAVE FCM TOKEN
  // =========================
Future<void> saveFcmToken({
  required String token,
  required String fcmToken,
}) async {
  try {
    final response = await ResilientHttp.post(
      uri: _uri('notifications/save_fcm_token.php'),
      headers: _headers(token),
      body: jsonEncode({"fcm_token": fcmToken}),
    );

    print("🔥 SAVE TOKEN RESPONSE: ${response.body}");
    print("🔥 STATUS CODE: ${response.statusCode}");

  } catch (error) {
    print("❌ SAVE TOKEN ERROR: $error");
    throw _mapTransportError(error);
  }
}
}