import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/core/network/resilient_http.dart';
import 'package:fsm/features/jobs/application/tracking_cache_store.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';

class JobApiService {
  final String baseUrl;
  static const Duration _requestTimeout = Duration(seconds: 8);

  JobApiService({required this.baseUrl});

  static const List<String> _acceptJobEndpoints = [
    'jobs/accept.php',
  ];

  static const List<String> _finishJobEndpoints = [
    'jobs/finish.php',
  ];

  static const List<String> _locationUpdateEndpoints = [
    'tracking/update_location.php',
    'jobs/accept.php',
  ];

  static const List<String> _adminLiveEndpoints = [
    'tracking/live_status.php',
    // Final fallback for older installs that fold live data into jobs list.
    'jobs/list.php',
  ];

  static const List<String> _historyEndpoints = [
    'tracking/location_history.php',
  ];

  static const List<String> _adminSummaryEndpoints = [
    'jobs/admin_summary.php',
    'jobs/dashboard_summary.php',
  ];

  static const List<String> _adminJobsEndpoints = [
    'jobs/list.php',
  ];

  static const List<String> _softDeleteJobEndpoints = [
    'jobs/delete.php',
    'jobs/soft_delete.php',
    'jobs/archive.php',
  ];

  static const List<String> _createJobEndpoints = [
    'jobs/create.php',
  ];

  static const List<String> _deletedJobsEndpoints = [
    'jobs/deleted.php',
    'jobs/deleted_jobs.php',
    'jobs/list_deleted.php',
  ];

  String? _preferredLiveEndpoint;
  String? _preferredHistoryEndpoint;
  String? _preferredAdminJobsEndpoint;

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

  bool _isSuccess(int code) => code >= 200 && code < 300;

  bool _isLikelyHtml(String body) {
    final lower = body.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') || lower.startsWith('<html');
  }

  bool _didRequestSucceed({
    required int statusCode,
    required String body,
    required dynamic data,
  }) {
    if (!_isSuccess(statusCode)) return false;
    if (_isLikelyHtml(body)) return false;
    if (data is Map<String, dynamic>) {
      if (data.containsKey('success')) {
        return _toBool(data['success']);
      }
      final status = data['status']?.toString().trim().toLowerCase();
      if (status != null && status.isNotEmpty) {
        if (status == 'ok' || status == 'success' || status == 'active') {
          return true;
        }
        if (status == 'error' || status == 'failed' || status == 'fail') {
          return false;
        }
      }
    }
    return true;
  }

  dynamic _decodeBody(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  String _extractMessage(dynamic data, {required String fallback}) {
    if (data is Map<String, dynamic>) {
      final message = data['message']?.toString();
      if (message != null && message.trim().isNotEmpty) return message;
    }
    return fallback;
  }

  Map<String, String> _jsonHeaders(String token) {
    return AppApiConfig.buildHeaders(token: token);
  }

  Map<String, String> _formHeaders(String token) {
    return AppApiConfig.buildHeaders(
      token: token,
      jsonContentType: false,
      formContentType: true,
    );
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

  Iterable<String> _orderedEndpoints(
    List<String> endpoints, {
    String? preferred,
  }) sync* {
    if (preferred != null && endpoints.contains(preferred)) {
      yield preferred;
    }
    for (final endpoint in endpoints) {
      if (endpoint == preferred) continue;
      yield endpoint;
    }
  }

  Future<http.Response> _get(
    String endpoint, {
    required Map<String, String> headers,
    Map<String, String>? query,
    Duration timeout = _requestTimeout,
  }) {
    return ResilientHttp.get(
      uri: _uri(endpoint, query: query),
      headers: headers,
      timeout: timeout,
    );
  }

  Future<http.Response> _postJson(
    String endpoint, {
    required Map<String, String> headers,
    required Map<String, dynamic> payload,
    Duration timeout = _requestTimeout,
  }) {
    return ResilientHttp.post(
      uri: _uri(endpoint),
      headers: headers,
      body: jsonEncode(payload),
      timeout: timeout,
    );
  }

  Future<http.Response> _postForm(
    String endpoint, {
    required Map<String, String> headers,
    required Map<String, dynamic> payload,
    Duration timeout = _requestTimeout,
  }) {
    return ResilientHttp.post(
      uri: _uri(endpoint),
      headers: headers,
      body: payload.map(
        (key, value) => MapEntry(key, value?.toString() ?? ''),
      ),
      timeout: timeout,
    );
  }

  Exception _mapTransportError(Object error, {required String fallback}) {
    if (error is TimeoutException) {
      return Exception(
        '$fallback Request timed out. Make sure Apache/XAMPP is running and API_BASE_URL points to /fsm_api.',
      );
    }
    if (error is SocketException || error is http.ClientException) {
      return Exception(
        '$fallback Unable to reach backend. Make sure Apache/XAMPP is running or set API_BASE_URL to your live /fsm_api server.',
      );
    }
    if (error is Exception) return error;
    return Exception(fallback);
  }

  String? _pickString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  double? _pickDouble(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is num) return value.toDouble();
      final parsed = double.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _pickInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  dynamic _pickValue(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (!map.containsKey(key)) continue;
      final value = map[key];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      return value;
    }
    return null;
  }

  int _toInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return false;
    return text == '1' ||
        text == 'true' ||
        text == 'yes' ||
        text == 'y' ||
        text == 'on' ||
        text == 'active';
  }

  bool _isDeletedRow(Map<String, dynamic> row) {
    if (_toBool(row['is_deleted']) ||
        _toBool(row['deleted']) ||
        _toBool(row['archived'])) {
      return true;
    }

    final deletedAt = row['deleted_at']?.toString().trim() ?? '';
    if (deletedAt.isNotEmpty) return true;

    final status = _pickString(row, ['status', 'job_status'])?.toLowerCase();
    return status == 'deleted' || status == 'archived' || status == 'removed';
  }

Map<String, dynamic> _normalizeLiveRow(Map<String, dynamic> row) {
  final status = _pickString(row, ['status', 'job_status']) ?? '-';
  final trackingStatus = _pickString(
        row,
        ['tracking_status', 'session_status', 'location_status'],
      ) ??
      '-';

  return <String, dynamic>{
    'technician_id': _pickInt(row, [
      'technician_id',
      'user_id',
      'assigned_to',
      'id',
    ]),
    'technician_name':
        _pickString(row, ['technician_name', 'name', 'technician']) ??
            'Technician',
    'job_id': _pickInt(row, ['job_id', 'id']),
    'job_title':
        _pickString(row, ['job_title', 'title', 'assigned_job']) ?? '-',
    'status': status,
    'tracking_status': trackingStatus,
    'is_tracking': row['is_tracking'] ?? row['tracking_active'],
    'latitude': _pickDouble(row, ['latitude', 'lat', 'location_lat']),
    'longitude': _pickDouble(
      row,
      ['longitude', 'lng', 'long', 'location_lng'],
    ),
    'updated_at': _pickString(
      row,
      [
        'updated_at',
        'location_updated_at',
        'captured_at',
        'last_seen',
        'created_at',
        'accepted_at',
      ],
    ),
    'is_deleted': _isDeletedRow(row),

    // 🔋 FIX START
    'battery': _pickInt(
      row,
      ['battery', 'battery_level', 'battery_percentage', 'batteryLevel'],
    ),
    'battery_level': _pickValue(
      row,
      ['battery_level', 'battery', 'battery_percentage', 'batteryLevel'],
    ),
    'battery_percentage': _pickValue(
      row,
      ['battery_percentage', 'battery_level', 'battery', 'batteryLevel'],
    ),
    'batteryLevel': _pickValue(
      row,
      ['batteryLevel', 'battery_level', 'battery', 'battery_percentage'],
    ),
    'is_charging': _pickInt(
      row,
      ['is_charging', 'charging', 'battery_charging'],
    ),
    'charging': _pickValue(
      row,
      ['charging', 'is_charging', 'battery_charging'],
    ),
    'battery_charging': _pickValue(
      row,
      ['battery_charging', 'is_charging', 'charging'],
    ),
    // 🔋 FIX END
  };
}

  String _liveTrackingKey(Map<String, dynamic> row) {
    final technicianId = row['technician_id']?.toString().trim();
    final jobId = row['job_id']?.toString().trim();
    if (technicianId != null && technicianId.isNotEmpty) {
      return 'tech:$technicianId|job:${jobId == null || jobId.isEmpty ? '-' : jobId}';
    }
    final lat = row['latitude']?.toString().trim();
    final lng = row['longitude']?.toString().trim();
    return 'coords:${lat ?? '-'}|${lng ?? '-'}';
  }

  List<Map<String, dynamic>> _dedupeLiveRows(
    List<Map<String, dynamic>> rows,
  ) {
    final latestByKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final key = _liveTrackingKey(row);
      final current = latestByKey[key];
      final rowUpdatedAt = TrackingPresence.parseDateTime(row['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final currentUpdatedAt = current == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : TrackingPresence.parseDateTime(current['updated_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      if (current == null || rowUpdatedAt.isAfter(currentUpdatedAt)) {
        latestByKey[key] = row;
      }
    }

    final deduped = latestByKey.values.toList(growable: false);
    deduped.sort((a, b) {
      final aUpdatedAt = TrackingPresence.parseDateTime(a['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bUpdatedAt = TrackingPresence.parseDateTime(b['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bUpdatedAt.compareTo(aUpdatedAt);
    });
    return deduped;
  }

  Map<String, dynamic>? _normalizeHistoryPoint(Map<String, dynamic> row) {
    final lat = _pickDouble(row, ['latitude', 'lat', 'location_lat']);
    final lng = _pickDouble(row, ['longitude', 'lng', 'long', 'location_lng']);
    if (lat == null || lng == null) return null;

    return <String, dynamic>{
      'technician_id': _pickInt(row, [
        'technician_id',
        'user_id',
        'assigned_to',
        'id',
      ]),
      'job_id': _pickInt(row, ['job_id', 'id']),
      'latitude': lat,
      'longitude': lng,
      'accuracy': _pickDouble(row, ['accuracy']),
      'speed': _pickDouble(row, ['speed']),
      'heading': _pickDouble(row, ['heading']),
      'captured_at': _pickString(
            row,
            ['captured_at', 'updated_at', 'location_updated_at', 'created_at'],
          ) ??
          DateTime.now().toIso8601String(),
      'source': _pickString(row, ['source']) ?? 'server',
    };
  }

  bool _isSyntheticHistoryRow(Map<String, dynamic> row) {
    final source = row['source']?.toString().trim().toLowerCase();
    return source == 'live_snapshot';
  }

  List<Map<String, dynamic>> _filterRenderableHistoryRows(
    List<Map<String, dynamic>> rows,
  ) {
    return rows
        .where((row) => !_isSyntheticHistoryRow(row))
        .toList(growable: false);
  }

  bool _shouldIncludeInLiveTracking(Map<String, dynamic> row) {
    if (_toBool(row['is_deleted'])) return false;
    return TrackingPresence.evaluate(row).shouldAppearInFeed;
  }

  Future<List<dynamic>> getMyJobs({required String? token}) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    try {
      final response = await _get(
        'jobs/get_my_jobs.php',
        headers: _jsonHeaders(normalizedToken),
      );
      final data = _decodeBody(response.body);

      if (_isLikelyHtml(response.body)) {
        throw Exception('Jobs endpoint returned HTML instead of JSON.');
      }

      if (data is List) {
        return data
            .where(
              (item) => item is! Map<String, dynamic> || !_isDeletedRow(item),
            )
            .toList(growable: false);
      }
      if (data is Map<String, dynamic>) {
        if (response.statusCode != 200) {
          throw Exception(
            data['message']?.toString() ?? 'Failed to fetch jobs',
          );
        }

        final jobs = data['jobs'] ?? data['data'];
        if (jobs is List) {
          return jobs
              .where(
                (item) => item is! Map<String, dynamic> || !_isDeletedRow(item),
              )
              .toList(growable: false);
        }
        return [];
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch jobs');
      }

      return [];
    } catch (error) {
      throw _mapTransportError(
        error,
        fallback: 'Unable to fetch jobs right now.',
      );
    }
  }

  Future<String> acceptJobWithLocation({
    required String? token,
    required int jobId,
    required double latitude,
    required double longitude,
    int? battery,
    int? isCharging,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final formHeaders = _formHeaders(normalizedToken);

    final payload = {
      'job_id': jobId,
      'id': jobId,
      'status': 'accepted',
      'job_status': 'accepted',
      'latitude': latitude,
      'longitude': longitude,
      'lat': latitude,
      'lng': longitude,
      'location_lat': latitude,
      'location_lng': longitude,
      'accepted_at': DateTime.now().toIso8601String(),
    };
    if (battery != null) {
      payload['battery'] = battery;
      payload['is_charging'] = isCharging ?? 0;
    }

    final errors = <String>[];
    for (final endpoint in _acceptJobEndpoints) {
      try {
        final jsonResponse = await _postJson(
          endpoint,
          headers: headers,
          payload: payload,
        );
        final jsonData = _decodeBody(jsonResponse.body);

        if (_isSuccess(jsonResponse.statusCode)) {
          return _extractMessage(
            jsonData,
            fallback: 'Job accepted and location updated.',
          );
        }

        // Fallback for PHP APIs that read $_POST instead of JSON body.
        final formResponse = await _postForm(
          endpoint,
          headers: formHeaders,
          payload: payload,
        );
        final formData = _decodeBody(formResponse.body);
        if (_isSuccess(formResponse.statusCode)) {
          return _extractMessage(
            formData,
            fallback: 'Job accepted and location updated.',
          );
        }

        errors.add(
          '$endpoint -> ${_extractMessage(formData ?? jsonData, fallback: 'HTTP ${formResponse.statusCode}')}',
        );
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    throw Exception(
      _acceptJobEndpoints.length == 1 && errors.isNotEmpty
          ? errors.first.replaceFirst('${_acceptJobEndpoints.first} -> ', '')
          : errors.isEmpty
              ? 'Unable to accept job right now.'
              : 'Unable to accept job: ${errors.join(' | ')}',
    );
  }

  Future<String> finishJobAndStopTracking({
    required String? token,
    required int jobId,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final formHeaders = _formHeaders(normalizedToken);

    final payload = {
      'job_id': jobId,
      'id': jobId,
      'status': 'completed',
      'job_status': 'completed',
      'tracking_status': 'ended',
      'stop_tracking': 1,
      'is_tracking': 0,
      'ended_at': DateTime.now().toIso8601String(),
    };

    final errors = <String>[];
    for (final endpoint in _finishJobEndpoints) {
      try {
        final jsonResponse = await _postJson(
          endpoint,
          headers: headers,
          payload: payload,
        );
        final jsonData = _decodeBody(jsonResponse.body);

        if (_isSuccess(jsonResponse.statusCode)) {
          return _extractMessage(
            jsonData,
            fallback: 'Job finished and tracking stopped.',
          );
        }

        final formResponse = await _postForm(
          endpoint,
          headers: formHeaders,
          payload: payload,
        );
        final formData = _decodeBody(formResponse.body);

        if (_isSuccess(formResponse.statusCode)) {
          return _extractMessage(
            formData,
            fallback: 'Job finished and tracking stopped.',
          );
        }

        errors.add(
          '$endpoint -> ${_extractMessage(formData ?? jsonData, fallback: 'HTTP ${formResponse.statusCode}')}',
        );
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    throw Exception(
      _finishJobEndpoints.length == 1 && errors.isNotEmpty
          ? errors.first.replaceFirst('${_finishJobEndpoints.first} -> ', '')
          : errors.isEmpty
              ? 'Unable to finish job right now.'
              : 'Unable to finish job: ${errors.join(' | ')}',
    );
  }

  Future<void> updateTechnicianLocation({
    required String? token,
    required int jobId,
    required double latitude,
    required double longitude,
    double? accuracy,
    double? speed,
    double? heading,
    DateTime? capturedAt,
    // 🔋 NEW
  int? battery,
  int? isCharging,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final formHeaders = _formHeaders(normalizedToken);

    final locationCapturedAt = (capturedAt ?? DateTime.now()).toIso8601String();
    final payload = <String, dynamic>{
      'job_id': jobId,
      'id': jobId,
      'status': 'in_progress',
      'job_status': 'in_progress',
      'tracking_status': 'active',
      'is_tracking': 1,
      'latitude': latitude,
      'longitude': longitude,
      'lat': latitude,
      'lng': longitude,
      'location_lat': latitude,
      'location_lng': longitude,
      'accuracy': accuracy,
      'speed': speed,
      'heading': heading,
      'updated_at': locationCapturedAt,
      'captured_at': locationCapturedAt,
    };
    if (battery != null) {
      payload['battery'] = battery;
      payload['is_charging'] = isCharging ?? 0;
    }
    final errors = <String>[];
    for (final endpoint in _locationUpdateEndpoints) {
      try {
        final jsonResponse = await _postJson(
          endpoint,
          headers: headers,
          payload: payload,
        );
        final jsonData = _decodeBody(jsonResponse.body);
        if (_didRequestSucceed(
          statusCode: jsonResponse.statusCode,
          body: jsonResponse.body,
          data: jsonData,
        )) {
          return;
        }

        final formResponse = await _postForm(
          endpoint,
          headers: formHeaders,
          payload: payload,
        );
        final formData = _decodeBody(formResponse.body);
        if (_didRequestSucceed(
          statusCode: formResponse.statusCode,
          body: formResponse.body,
          data: formData,
        )) {
          return;
        }

        errors.add(
          '$endpoint -> ${_extractMessage(formData ?? jsonData, fallback: 'HTTP ${formResponse.statusCode}')}',
        );
      } on TimeoutException {
        errors.add('$endpoint -> request timeout');
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to update live location right now.'
          : 'Unable to update live location: ${errors.join(' | ')}',
    );
  }

  Future<List<Map<String, dynamic>>> getTechnicianLiveStatus({
    required String? token,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);

    final errors = <String>[];
    final notFoundEndpoints = <String>[];
    for (final endpoint in _orderedEndpoints(
      _adminLiveEndpoints,
      preferred: _preferredLiveEndpoint,
    )) {
      try {
        final response = await _get(
          endpoint,
          headers: headers,
        );
        final data = _decodeBody(response.body);

        if (!_didRequestSucceed(
          statusCode: response.statusCode,
          body: response.body,
          data: data,
        )) {
          if (response.statusCode == 404) {
            notFoundEndpoints.add(endpoint);
            continue;
          }

          final fallback = data is Map<String, dynamic>
              ? (data['message']?.toString() ?? 'HTTP ${response.statusCode}')
              : 'HTTP ${response.statusCode}';
          errors.add(
            '$endpoint -> $fallback',
          );
          continue;
        }

        final rows = <Map<String, dynamic>>[];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) {
              rows.add(item);
            }
          }
        } else if (data is Map<String, dynamic>) {
          final listCandidate = data['technicians'] ??
              data['live_tracking'] ??
              data['locations'] ??
              data['jobs'] ??
              data['data'];
          if (listCandidate is List) {
            for (final item in listCandidate) {
              if (item is Map<String, dynamic>) {
                rows.add(item);
              }
            }
          } else {
            rows.add(data);
          }
        }

        final normalized = rows
            .map(_normalizeLiveRow)
            .toList(growable: false);
        final deduped = _dedupeLiveRows(normalized);
        if (deduped.isEmpty) {
          _preferredLiveEndpoint = endpoint;
          await TrackingCacheStore.cacheLiveRows(const <Map<String, dynamic>>[]);
          return const <Map<String, dynamic>>[];
        }
        _preferredLiveEndpoint = endpoint;
        await TrackingCacheStore.cacheLiveRows(deduped);
        return deduped;
      } on TimeoutException {
        errors.add('$endpoint -> request timeout');
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    if (notFoundEndpoints.length == _adminLiveEndpoints.length) {
        throw Exception(
          'Live tracking API not found on server. '
          'Please create one endpoint (for example: tracking/live_status.php).',
        );
    }

    final cachedRows = await TrackingCacheStore.readLiveRows();
    if (cachedRows.isNotEmpty) {
      return cachedRows
          .map((row) => <String, dynamic>{...row, 'is_from_cache': true})
          .toList(growable: false);
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to fetch live technician status.'
          : 'Unable to fetch live technician status: ${errors.join(' | ')}',
    );
  }

  Future<List<Map<String, dynamic>>> getTechnicianLocationHistory({
    required String? token,
    int? technicianId,
    int? jobId,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final cachedHistory = await TrackingCacheStore.readHistoryPoints();
    final renderableCachedHistory = _filterRenderableHistoryRows(cachedHistory);

    final errors = <String>[];
    final notFoundEndpoints = <String>[];
    for (final endpoint in _orderedEndpoints(
      _historyEndpoints,
      preferred: _preferredHistoryEndpoint,
    )) {
      try {
        final query = <String, String>{};
        if (technicianId != null) {
          query['technician_id'] = technicianId.toString();
        }
        if (jobId != null) query['job_id'] = jobId.toString();

        final response = await _get(
          endpoint,
          headers: headers,
          query: query.isEmpty ? null : query,
        );
        final data = _decodeBody(response.body);

        if (!_isSuccess(response.statusCode)) {
          if (response.statusCode == 404) {
            notFoundEndpoints.add(endpoint);
            continue;
          }
          final fallback = data is Map<String, dynamic>
              ? (data['message']?.toString() ?? 'HTTP ${response.statusCode}')
              : 'HTTP ${response.statusCode}';
          errors.add('$endpoint -> $fallback');
          continue;
        }

        final rows = <Map<String, dynamic>>[];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) rows.add(item);
          }
        } else if (data is Map<String, dynamic>) {
          final listCandidate = data['history'] ??
              data['locations'] ??
              data['data'] ??
              data['items'];
          if (listCandidate is List) {
            for (final item in listCandidate) {
              if (item is Map<String, dynamic>) rows.add(item);
            }
          }
        }

        final normalized = rows
            .map(_normalizeHistoryPoint)
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);

        _preferredHistoryEndpoint = endpoint;
        await TrackingCacheStore.cacheHistoryPoints(normalized);
        return normalized;
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    if (renderableCachedHistory.isNotEmpty) return renderableCachedHistory;

    if (notFoundEndpoints.length == _historyEndpoints.length) {
      throw Exception('Location history API not found on server.');
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to fetch location history.'
          : 'Unable to fetch location history: ${errors.join(' | ')}',
    );
  }

  Future<Map<String, dynamic>> getAdminSummary({
    required String? token,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);

    final errors = <String>[];
    final notFoundEndpoints = <String>[];
    for (final endpoint in _adminSummaryEndpoints) {
      try {
        final response = await _get(
          endpoint,
          headers: headers,
        );
        final data = _decodeBody(response.body);

        if (!_isSuccess(response.statusCode)) {
          if (response.statusCode == 404) {
            notFoundEndpoints.add(endpoint);
            continue;
          }
          final fallback = data is Map<String, dynamic>
              ? (data['message']?.toString() ?? 'HTTP ${response.statusCode}')
              : 'HTTP ${response.statusCode}';
          errors.add('$endpoint -> $fallback');
          continue;
        }

        Map<String, dynamic>? payload;
        if (data is Map<String, dynamic>) {
          if (data['data'] is Map<String, dynamic>) {
            payload =
                Map<String, dynamic>.from(data['data'] as Map<String, dynamic>);
          } else {
            payload = Map<String, dynamic>.from(data);
          }
        }

        if (payload == null) {
          errors.add('$endpoint -> Invalid summary format');
          continue;
        }

        return {
          'total_users': _toInt(payload['total_users']),
          'total_managers': _toInt(payload['total_managers']),
          'total_technicians': _toInt(payload['total_technicians']),
          'total_jobs': _toInt(payload['total_jobs']),
          'completed_jobs': _toInt(payload['completed_jobs']),
          'active_sessions': _toInt(payload['active_sessions']),
        };
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    if (notFoundEndpoints.length == _adminSummaryEndpoints.length) {
      throw Exception(
        'Admin summary API not found on server. '
        'Please create jobs/admin_summary.php.',
      );
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to fetch admin summary.'
          : 'Unable to fetch admin summary: ${errors.join(' | ')}',
    );
  }

  Future<List<Map<String, dynamic>>> getAdminJobAssignments({
    required String? token,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);

    final errors = <String>[];
    final notFoundEndpoints = <String>[];

    for (final endpoint in _orderedEndpoints(
      _adminJobsEndpoints,
      preferred: _preferredAdminJobsEndpoint,
    )) {
      try {
        final response = await _get(
          endpoint,
          headers: headers,
        );
        final data = _decodeBody(response.body);

        if (!_isSuccess(response.statusCode)) {
          if (response.statusCode == 404) {
            notFoundEndpoints.add(endpoint);
            continue;
          }
          final fallback = data is Map<String, dynamic>
              ? (data['message']?.toString() ?? 'HTTP ${response.statusCode}')
              : 'HTTP ${response.statusCode}';
          errors.add('$endpoint -> $fallback');
          continue;
        }

        final rows = <Map<String, dynamic>>[];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) rows.add(item);
          }
        } else if (data is Map<String, dynamic>) {
          final listCandidate = data['jobs'] ?? data['data'] ?? data['items'];
          if (listCandidate is List) {
            for (final item in listCandidate) {
              if (item is Map<String, dynamic>) rows.add(item);
            }
          }
        }

        _preferredAdminJobsEndpoint = endpoint;
        final normalized = rows.map((row) {
          final techName = _pickString(row, [
                'technician_name',
                'technician_email',
                'email',
              ]) ??
              '-';

return <String, dynamic>{
  'job_id': _pickInt(row, ['job_id', 'id']),
  'job_title':
      _pickString(row, ['job_title', 'title', 'assigned_job']) ?? '-',
  'status': _pickString(row, ['status', 'job_status']) ?? '-',
  'technician_id': _pickInt(
    row,
    ['technician_id', 'assigned_to', 'user_id'],
  ),
  'technician_name': techName,
  'tracking_status':
      _pickString(row, ['tracking_status', 'session_status']) ?? '-',
  'updated_at': _pickString(
    row,
    ['updated_at', 'location_updated_at', 'created_at'],
  ),
  'is_deleted': _isDeletedRow(row),
  'deleted_at': _pickString(row, ['deleted_at']),
  'battery': _pickInt(row, ['battery', 'battery_level']),       // ← ADD
  'is_charging': _pickInt(row, ['is_charging', 'charging']),    // ← ADD
};
        }).toList(growable: false);

        return normalized
            .where((row) => !_toBool(row['is_deleted']))
            .toList(growable: false);
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    if (notFoundEndpoints.length == _adminJobsEndpoints.length) {
      throw Exception('Admin jobs list API not found on server.');
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to fetch admin jobs list.'
          : 'Unable to fetch admin jobs list: ${errors.join(' | ')}',
    );
  }

  Future<String> createJob({
    required String? token,
    required String title,
    required int technicianId,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final formHeaders = _formHeaders(normalizedToken);
    final payload = <String, dynamic>{
      'title': title,
      'assigned_to': technicianId,
    };

    final errors = <String>[];
    for (final endpoint in _createJobEndpoints) {
      try {
        final jsonResponse = await _postJson(
          endpoint,
          headers: headers,
          payload: payload,
        );
        final jsonData = _decodeBody(jsonResponse.body);
        if (_didRequestSucceed(
          statusCode: jsonResponse.statusCode,
          body: jsonResponse.body,
          data: jsonData,
        )) {
          return _extractMessage(
            jsonData,
            fallback: 'Job created successfully.',
          );
        }

        final formResponse = await _postForm(
          endpoint,
          headers: formHeaders,
          payload: payload,
        );
        final formData = _decodeBody(formResponse.body);
        if (_didRequestSucceed(
          statusCode: formResponse.statusCode,
          body: formResponse.body,
          data: formData,
        )) {
          return _extractMessage(
            formData,
            fallback: 'Job created successfully.',
          );
        }

        errors.add(
          '$endpoint -> ${_extractMessage(formData ?? jsonData, fallback: 'HTTP ${formResponse.statusCode}')}',
        );
      } catch (error) {
        errors.add('$endpoint -> ${_mapTransportError(error, fallback: 'Unable to create job right now.')}');
      }
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to create job right now.'
          : errors.first.replaceFirst('${_createJobEndpoints.first} -> ', ''),
    );
  }

  Future<String> softDeleteJob({
    required String? token,
    required int jobId,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);
    final formHeaders = _formHeaders(normalizedToken);

    final payload = {
      'job_id': jobId,
      'id': jobId,
      'is_deleted': 1,
      'deleted': 1,
      'status': 'deleted',
      'job_status': 'deleted',
      'deleted_at': DateTime.now().toIso8601String(),
    };

    final errors = <String>[];
    for (final endpoint in _softDeleteJobEndpoints) {
      try {
        final jsonResponse = await _postJson(
          endpoint,
          headers: headers,
          payload: payload,
        );
        final jsonData = _decodeBody(jsonResponse.body);
        if (_isSuccess(jsonResponse.statusCode)) {
          return _extractMessage(jsonData,
              fallback: 'Job moved to deleted list.');
        }

        final formResponse = await _postForm(
          endpoint,
          headers: formHeaders,
          payload: payload,
        );
        final formData = _decodeBody(formResponse.body);
        if (_isSuccess(formResponse.statusCode)) {
          return _extractMessage(formData,
              fallback: 'Job moved to deleted list.');
        }

        errors.add(
          '$endpoint -> ${_extractMessage(formData ?? jsonData, fallback: 'HTTP ${formResponse.statusCode}')}',
        );
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to delete job right now.'
          : 'Unable to delete job: ${errors.join(' | ')}',
    );
  }

  Future<List<Map<String, dynamic>>> getDeletedJobs({
    required String? token,
  }) async {
    final normalizedToken = _normalizeToken(token);
    if (normalizedToken == null) {
      throw Exception('Session expired. Please login again.');
    }

    final headers = _jsonHeaders(normalizedToken);

    final errors = <String>[];
    final notFoundEndpoints = <String>[];
    for (final endpoint in _deletedJobsEndpoints) {
      try {
        final response = await _get(
          endpoint,
          headers: headers,
        );
        final data = _decodeBody(response.body);

        if (!_isSuccess(response.statusCode)) {
          if (response.statusCode == 404) {
            notFoundEndpoints.add(endpoint);
            continue;
          }
          final fallback = data is Map<String, dynamic>
              ? (data['message']?.toString() ?? 'HTTP ${response.statusCode}')
              : 'HTTP ${response.statusCode}';
          errors.add('$endpoint -> $fallback');
          continue;
        }

        final rows = <Map<String, dynamic>>[];
        if (data is List) {
          for (final item in data) {
            if (item is Map<String, dynamic>) rows.add(item);
          }
        } else if (data is Map<String, dynamic>) {
          final listCandidate = data['jobs'] ?? data['data'] ?? data['items'];
          if (listCandidate is List) {
            for (final item in listCandidate) {
              if (item is Map<String, dynamic>) rows.add(item);
            }
          }
        }

        return rows.map((row) {
          return <String, dynamic>{
            'job_id': _pickInt(row, ['job_id', 'id']),
            'job_title':
                _pickString(row, ['job_title', 'title', 'assigned_job']) ?? '-',
            'technician_name': _pickString(
                  row,
                  ['technician_name', 'technician_email', 'email'],
                ) ??
                '-',
            'deleted_at': _pickString(row, ['deleted_at', 'updated_at']) ?? '-',
            'status': _pickString(row, ['status', 'job_status']) ?? 'deleted',
          };
        }).toList(growable: false);
      } catch (e) {
        errors.add('$endpoint -> $e');
      }
    }

    if (notFoundEndpoints.length == _deletedJobsEndpoints.length) {
      return const <Map<String, dynamic>>[];
    }

    throw Exception(
      errors.isEmpty
          ? 'Unable to fetch deleted jobs.'
          : 'Unable to fetch deleted jobs: ${errors.join(' | ')}',
    );
  }
}
