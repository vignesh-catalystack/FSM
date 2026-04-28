import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackingCacheStore {
  TrackingCacheStore._();

  static const String _liveCacheKey = 'tracking_live_cache_v1';
  static const String _historyCacheKey = 'tracking_history_cache_v1';
  static const String _pendingSyncKey = 'tracking_pending_sync_v1';
  static const int _maxHistoryPoints = 1200;
  static const int _maxPendingPoints = 300;
  static const int _maxLiveRows = 150;

  static Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return await SharedPreferences.getInstance();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> cacheLiveRows(List<Map<String, dynamic>> rows) async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final trimmed = rows.take(_maxLiveRows).toList(growable: false);
    await prefs.setString(_liveCacheKey, jsonEncode(trimmed));
  }

  static Future<List<Map<String, dynamic>>> readLiveRows() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return <Map<String, dynamic>>[];
    final raw = prefs.getString(_liveCacheKey);
    return _decodeList(raw);
  }

  static Future<void> cacheHistoryPoints(
    List<Map<String, dynamic>> points,
  ) async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final merged = await _mergeHistoryPoints(points);
    await prefs.setString(_historyCacheKey, jsonEncode(merged));
  }

  static Future<List<Map<String, dynamic>>> readHistoryPoints() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return <Map<String, dynamic>>[];
    final raw = prefs.getString(_historyCacheKey);
    return _decodeList(raw);
  }

  static Future<void> appendHistoryPoint(Map<String, dynamic> point) async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final existing = _decodeList(prefs.getString(_historyCacheKey));
    existing.add(point);
    final trimmed = _trimToMax(existing, _maxHistoryPoints);
    await prefs.setString(_historyCacheKey, jsonEncode(trimmed));
  }

  static Future<void> enqueuePendingSync(Map<String, dynamic> point) async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final queue = _decodeList(prefs.getString(_pendingSyncKey));
    if (queue.isNotEmpty && _isSamePendingPoint(queue.last, point)) {
      return;
    }
    queue.add(point);
    final trimmed = _trimToMax(queue, _maxPendingPoints);
    await prefs.setString(_pendingSyncKey, jsonEncode(trimmed));
  }

  static Future<List<Map<String, dynamic>>> readPendingSync() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return <Map<String, dynamic>>[];
    return _decodeList(prefs.getString(_pendingSyncKey));
  }

  static Future<void> savePendingSync(
    List<Map<String, dynamic>> queue,
  ) async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    final trimmed = _trimToMax(queue, _maxPendingPoints);
    await prefs.setString(_pendingSyncKey, jsonEncode(trimmed));
  }

  static List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<List<Map<String, dynamic>>> _mergeHistoryPoints(
    List<Map<String, dynamic>> incoming,
  ) async {
    final existing = await readHistoryPoints();
    final merged = <String, Map<String, dynamic>>{};

    for (final point in existing) {
      final key = _historyKey(point);
      merged[key] = point;
    }
    for (final point in incoming) {
      final key = _historyKey(point);
      merged[key] = point;
    }

    final values = merged.values.toList(growable: true);
    values.sort((a, b) {
      final aAt = a['captured_at']?.toString() ?? '';
      final bAt = b['captured_at']?.toString() ?? '';
      return aAt.compareTo(bAt);
    });
    return _trimToMax(values, _maxHistoryPoints);
  }

  static String _historyKey(Map<String, dynamic> point) {
    final tech = point['technician_id']?.toString() ?? '-';
    final job = point['job_id']?.toString() ?? '-';
    final lat = point['latitude']?.toString() ?? '-';
    final lng = point['longitude']?.toString() ?? '-';
    final at = point['captured_at']?.toString() ?? '-';
    return '$tech|$job|$lat|$lng|$at';
  }

  static List<Map<String, dynamic>> _trimToMax(
    List<Map<String, dynamic>> rows,
    int maxRows,
  ) {
    if (rows.length <= maxRows) return rows;
    return rows.sublist(rows.length - maxRows);
  }

  static bool _isSamePendingPoint(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    return a['job_id']?.toString() == b['job_id']?.toString() &&
        a['latitude']?.toString() == b['latitude']?.toString() &&
        a['longitude']?.toString() == b['longitude']?.toString() &&
        a['captured_at']?.toString() == b['captured_at']?.toString();
  }
}
