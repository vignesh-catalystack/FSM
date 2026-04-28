import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

class ResilientHttp {
  ResilientHttp._();

  static const Duration _defaultTimeout = Duration(seconds: 12);
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 350),
    Duration(milliseconds: 900),
  ];

  static bool _shouldRetryStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  static bool _shouldRetryError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is http.ClientException;
  }

  static Future<http.Response> get({
    required Uri uri,
    Map<String, String>? headers,
    Duration timeout = _defaultTimeout,
  }) {
    return send(
      timeout: timeout,
      request: () => http.get(uri, headers: headers),
    );
  }

  static Future<http.Response> post({
    required Uri uri,
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
    Duration timeout = _defaultTimeout,
  }) {
    return send(
      timeout: timeout,
      request: () => http.post(
        uri,
        headers: headers,
        body: body,
        encoding: encoding,
      ),
    );
  }

  static Future<http.Response> send({
    required Future<http.Response> Function() request,
    Duration timeout = _defaultTimeout,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
      try {
        final response = await request().timeout(timeout);
        if (_shouldRetryStatus(response.statusCode) &&
            attempt < _retryDelays.length) {
          await Future<void>.delayed(_retryDelays[attempt]);
          continue;
        }
        return response;
      } catch (error) {
        lastError = error;
        if (!_shouldRetryError(error) || attempt >= _retryDelays.length) {
          rethrow;
        }
        await Future<void>.delayed(_retryDelays[attempt]);
      }
    }

    if (lastError != null) {
      throw lastError;
    }
    throw Exception('Request failed without a known error.');
  }
}
