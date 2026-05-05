import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/core/network/resilient_http.dart';

class AuthApiService {
  static const Duration _requestTimeout = Duration(seconds: 12);

  bool _isLikelyHtml(String body) {
    final lower = body.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') || lower.startsWith('<html');
  }

  Map<String, dynamic> _decodeResponseMap(
    http.Response response, {
    required String fallbackMessage,
  }) {
    if (_isLikelyHtml(response.body)) {
      throw Exception(
        'API returned HTML page. Verify API_BASE_URL points to /fsm_api. Current base URL: ${AppApiConfig.baseUrl}',
      );
    }

    final trimmed = response.body.trim();
    if (trimmed.isEmpty) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return <String, dynamic>{};
      }
      throw Exception(fallbackMessage);
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw Exception(fallbackMessage);
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception(fallbackMessage);
    }
    return Map<String, dynamic>.from(decoded);
  }

  Exception _mapTransportError(Object error) {
    if (error is TimeoutException) {
      return Exception(
        'Request timed out. Make sure Apache/XAMPP is running and API_BASE_URL points to /fsm_api.',
      );
    }
    if (error is SocketException || error is http.ClientException) {
      return Exception(
        'Unable to reach backend. Make sure Apache/XAMPP is running or set API_BASE_URL to your live /fsm_api server.',
      );
    }
    if (error is Exception) return error;
    return Exception('Unexpected network error');
  }

Future<Map<String, dynamic>> login({
  required String email,
  required String password,
}) async {
  try {
    final response = await ResilientHttp.post(
      uri: AppApiConfig.endpointUri('auth/login.php'),
      headers: AppApiConfig.buildHeaders(),
      body: jsonEncode({
        'email': email,
        'password': password,
      }),
      timeout: _requestTimeout,
    );

    final payload = _decodeResponseMap(
      response,
      fallbackMessage: 'Unexpected login response format',
    );

    final authHeader = response.headers['authorization'];
    if (authHeader != null && authHeader.trim().isNotEmpty) {
      payload['authorization_header'] = authHeader;
    }

    // 🔥 CRITICAL FIX: HANDLE BACKEND ERROR CODE
    if (payload['status'] == 'error') {
      throw Exception(payload['code']); // <-- THIS FIXES EVERYTHING
    }

    if (response.statusCode != 200) {
      throw Exception('HTTP_${response.statusCode}');
    }

    return payload;
  } catch (error) {
    throw _mapTransportError(error);
  }
}
  Future<String> forgotPassword(String email) async {
    try {
      final response = await ResilientHttp.post(
        uri: AppApiConfig.endpointUri('auth/forgot_password.php'),
        headers: AppApiConfig.buildHeaders(),
        body: jsonEncode({'email': email}),
        timeout: _requestTimeout,
      );

      final data = _decodeResponseMap(
        response,
        fallbackMessage: 'Failed to send reset link',
      );
      if (response.statusCode != 200) {
        throw Exception(data['message'] ?? 'Failed to send reset link');
      }
      return data['debug_token']?.toString() ?? '';
    } catch (error) {
      throw _mapTransportError(error);
    }
  }

  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {
    try {
      final response = await ResilientHttp.post(
        uri: AppApiConfig.endpointUri('auth/reset_password.php'),
        headers: AppApiConfig.buildHeaders(),
        body: jsonEncode({
          'token': token,
          'password': password,
        }),
        timeout: _requestTimeout,
      );

      final data = _decodeResponseMap(
        response,
        fallbackMessage: 'Reset failed',
      );
      if (response.statusCode != 200) {
        throw Exception(data['message'] ?? 'Reset failed');
      }
    } catch (error) {
      throw _mapTransportError(error);
    }
  }
}
