import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:fsm/features/jobs/application/job_controller.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';
import 'animated_marker_widget.dart';
import 'technician_map_models.dart';

abstract class TechnicianLocationsMapScreenBase extends ConsumerStatefulWidget {
  const TechnicianLocationsMapScreenBase({super.key});

  int? get jobIdFilter;
  int? get technicianIdFilter;
  bool get liveOnly;
  bool get offlineHistoryOnly;
  String? get jobTitleHint;
  String? get technicianNameHint;
  List<Map<String, dynamic>>? get seedRows;
}

class _LiveRoutePoint {
  const _LiveRoutePoint({
    required this.latLng,
    required this.capturedAt,
    required this.speed,
  });

  final LatLng latLng;
  final DateTime capturedAt;
  final double? speed;
}

mixin TechnicianMapLogic<W extends TechnicianLocationsMapScreenBase>
    on ConsumerState<W> {
  static const Duration liveRefreshInterval = Duration(seconds: 2);
  static const Duration historyRefreshInterval = Duration(seconds: 10);
  static const LatLng defaultCenter = LatLng(12.9716, 77.5946);
  static const String userAgentPackageName = 'com.example.fsm';
  static const Duration liveTrailMaxAge = Duration(hours: 24);
  static const int liveTrailMaxPoints = 5000;

  // Accuracy thresholds separated by concern.
  static const double _liveAccuracyThresholdMeters = 20.0;
  static const double _historyAccuracyThresholdMeters = 60.0;

  // Long-pause jump protection (mirrors tracking service).
  // If the gap between two consecutive DB points is ≥ this, AND the
  // distance between them is > _pauseJumpMaxMeters, split the path.
  static const Duration _pauseJumpWindow = Duration(minutes: 10);
  static const double _pauseJumpMaxMeters = 80.0;

  static const List<Color> technicianPalette = <Color>[
    Color(0xFF2563EB),
    Color(0xFFEA580C),
    Color(0xFF0F9D58),
    Color(0xFF7C3AED),
    Color(0xFFDC2626),
    Color(0xFF0891B2),
    Color(0xFFCA8A04),
    Color(0xFFBE185D),
  ];

  final Map<String, LatLng> _prevPositions = <String, LatLng>{};

  // ── LIVE TRAIL ─────────────────────────────────────────────────────────────
  // This is the ONLY source of truth for live polylines.
  // It is NEVER merged with DB history rows for rendering.
  final Map<String, List<_LiveRoutePoint>> _liveTrailByKey =
      <String, List<_LiveRoutePoint>>{};

  final Map<String, double> _routeBearingRadiansByKey = <String, double>{};
  final Map<String, LatLng> _lastFollowedCameraPositions = <String, LatLng>{};

  final MapController mapController = MapController();
  Timer? refreshTimer;
  TechnicianLocation? selectedLocation;
  bool cameraFramed = false;
  bool mapReady = false;
  int lastMarkerHash = 0;
  int refreshTick = 0;
  bool refreshInProgress = false;
  MapLayerType activeLayer = MapLayerType.standard;

  void initLogic() {
    refreshTimer = Timer.periodic(liveRefreshInterval, (_) {
      if (!shouldAutoRefresh()) return;
      unawaited(refreshMapData());
    });
  }

  void disposeLogic() {
    refreshTimer?.cancel();
    mapController.dispose();
  }

  // ─────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────

  String asText(dynamic value, {String fallback = '-'}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  double? asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  DateTime? asDateTime(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text) ??
        DateTime.tryParse(text.replaceFirst(' ', 'T'));
  }

  int? asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double? readBearing(Map<String, dynamic> row) {
    final rawBearing = row['bearing'] ?? row['heading'];
    return normalizeBearingDegrees(asDouble(rawBearing));
  }

  double? normalizeBearingDegrees(double? value) {
    if (value == null || !value.isFinite) return null;
    final normalized = value % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  double? bearingRadiansFor(TechnicianLocation location) {
    final bearing = normalizeBearingDegrees(location.bearing);
    return bearing == null ? null : bearing * math.pi / 180;
  }

  bool _bearingLooksUnset(double? bearing) {
    final normalized = normalizeBearingDegrees(bearing);
    return normalized == null || normalized.abs() < 0.001;
  }

  double? _routeBearingRadiansFor(TechnicianLocation location) {
    return _routeBearingRadiansByKey[location.markerKey] ??
        _routeBearingRadiansByKey[location.trackingKey] ??
        (location.technicianFallbackKey == null
            ? null
            : _routeBearingRadiansByKey[location.technicianFallbackKey!]);
  }

  void _rememberRouteBearing(TechnicianLocation location, List<LatLng> route) {
    if (route.length < 2) return;
    final bearing = _calculateBearing(route[route.length - 2], route.last);
    _routeBearingRadiansByKey[location.markerKey] = bearing;
    _routeBearingRadiansByKey[location.trackingKey] = bearing;
    final fallbackKey = location.technicianFallbackKey;
    if (fallbackKey != null) {
      _routeBearingRadiansByKey[fallbackKey] = bearing;
    }
  }

  String timeAgo(dynamic value) {
    final date = asDateTime(value)?.toLocal();
    if (date == null) return 'Unknown';
    final diff = DateTime.now().difference(date);
    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }

  String syncPillLabel(dynamic value, {required bool isOfflineHistory}) {
    final label = timeAgo(value);
    if (label == 'Unknown') return 'Sync unknown';
    if (isOfflineHistory) return 'Seen $label';
    return label == 'Just now' ? 'Live now' : 'Seen $label';
  }

  Color syncPillColor(dynamic value, {required bool isOfflineHistory}) {
    final updatedAt = asDateTime(value)?.toLocal();
    if (updatedAt == null) return const Color(0xFFF59E0B);
    if (!isOfflineHistory && isTrackingFresh(value)) {
      return const Color(0xFF0F9D58);
    }
    return isOfflineHistory ? const Color(0xFF64748B) : const Color(0xFFB45309);
  }

  Color sourcePillColor(TechnicianLocation location) {
    switch (location.sourceLabel) {
      case 'Live now':
        return const Color(0xFF0F9D58);
      case 'Last synced':
        return const Color(0xFFB45309);
      default:
        return const Color(0xFF64748B);
    }
  }

  bool isArchivedHistory(TechnicianLocation location) =>
      location.sourceLabel == 'Offline history';

  bool isTrackingFresh(dynamic value) {
    final updatedAt = asDateTime(value)?.toLocal();
    if (updatedAt == null) return false;
    return DateTime.now().difference(updatedAt) <=
        TrackingPresence.freshnessWindow;
  }

  String titleCase(String value) {
    final cleaned = value.trim().replaceAll('_', ' ');
    if (cleaned.isEmpty) return '-';
    return cleaned.split(RegExp(r'\s+')).map((word) {
      if (word.isEmpty) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  bool hasDisplayValue(String? value) {
    final normalized = value?.trim();
    return normalized != null && normalized.isNotEmpty && normalized != '-';
  }

  double distanceMeters(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b);

  bool _hasValidCoordinate(LatLng point) {
    return point.latitude >= -90 &&
        point.latitude <= 90 &&
        point.longitude >= -180 &&
        point.longitude <= 180 &&
        !(point.latitude == 0.0 && point.longitude == 0.0);
  }

  bool _shouldAnimate(LatLng prev, LatLng next) {
    final distance = distanceMeters(prev, next);
    if (distance < 1) return false;
    if (distance > 300) return false;
    return true;
  }

  double _calculateBearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return math.atan2(y, x);
  }

  DateTime _capturedAtForLocation(TechnicianLocation location) {
    final updatedAt = location.updatedAt.toLocal();
    if (updatedAt.isBefore(DateTime(2000))) return DateTime.now();
    return updatedAt;
  }

  // ─────────────────────────────────────────────────────
  // LIVE TRAIL MANAGEMENT
  // ─────────────────────────────────────────────────────

  /// Called every refresh tick for live locations.
  /// Appends the current position to the in-memory trail for each
  /// live technician. The trail is the ONLY source for live polylines.
  void syncLiveRouteTrails(List<TechnicianLocation> locations) {
    final activeLiveKeys = locations
        .where((location) => location.isLive)
        .map((location) => location.trackingKey)
        .toSet();

    _liveTrailByKey.removeWhere((key, _) => !activeLiveKeys.contains(key));
    _routeBearingRadiansByKey.removeWhere(
      (key, _) => !locations.any(
        (location) =>
            location.markerKey == key ||
            location.trackingKey == key ||
            location.technicianFallbackKey == key,
      ),
    );
    _lastFollowedCameraPositions.removeWhere(
      (key, _) => !locations.any((location) => location.markerKey == key),
    );

    for (final location in locations) {
      if (!location.isLive || !_hasValidCoordinate(location.latLng)) continue;
      _appendLiveRoutePoint(location);
    }
  }

  void _appendLiveRoutePoint(TechnicianLocation location) {
    if (location.accuracy != null &&
        location.accuracy! > _liveAccuracyThresholdMeters) return;

    final trail = _liveTrailByKey.putIfAbsent(
      location.trackingKey,
      () => <_LiveRoutePoint>[],
    );
    final point = _LiveRoutePoint(
      latLng: location.latLng,
      capturedAt: _capturedAtForLocation(location),
      speed: location.speed,
    );

    if (trail.isEmpty) {
      trail.add(point);
      return;
    }

    final last = trail.last;
    final distance = distanceMeters(last.latLng, point.latLng);

    // Ignore micro-moves (same position updates).
    if (distance < 0.3) {
      if (point.capturedAt.isAfter(last.capturedAt)) {
        trail[trail.length - 1] = point;
      }
      return;
    }

    // Reject teleport spikes (>600 m jump is GPS noise).
    if (distance > 600) return;

    // ── LONG-PAUSE JUMP FILTER for live trail ────────────────────────────────
    // If the GPS was silent for ≥ _pauseJumpWindow and the new point jumped
    // more than _pauseJumpMaxMeters, the GPS is still settling after a rest
    // period — reject the point.
    final timeDiff = point.capturedAt.difference(last.capturedAt);
    if (timeDiff >= _pauseJumpWindow && distance > _pauseJumpMaxMeters) {
      return;
    }

    trail.add(point);
    _trimLiveRouteTrail(trail);
  }

  void _trimLiveRouteTrail(List<_LiveRoutePoint> trail) {
    final threshold = DateTime.now().subtract(liveTrailMaxAge);
    trail.removeWhere((point) => point.capturedAt.isBefore(threshold));
    if (trail.length > liveTrailMaxPoints) {
      trail.removeRange(0, trail.length - liveTrailMaxPoints);
    }
  }

  void _appendRouteCoordinate(
    List<LatLng> route,
    LatLng point, {
    double minDistanceMeters = 0.4,
    double maxGapMeters = 5000,
  }) {
    if (!_hasValidCoordinate(point)) return;
    if (route.isEmpty) {
      route.add(point);
      return;
    }
    final distance = distanceMeters(route.last, point);
    if (distance < minDistanceMeters) return;
    if (distance > maxGapMeters) return;
    route.add(point);
  }

  // ─────────────────────────────────────────────────────
  // REFRESH
  // ─────────────────────────────────────────────────────

  bool shouldAutoRefresh() {
    if (!mounted || refreshInProgress) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
  }

  Future<void> refreshMapData({bool forceHistory = false}) async {
    if (!mounted || refreshInProgress) return;
    refreshInProgress = true;
    refreshTick++;

    final shouldRefreshHistory = forceHistory ||
        refreshTick %
                (historyRefreshInterval.inSeconds ~/
                    liveRefreshInterval.inSeconds) ==
            0;

    try {
      final tasks = <Future<dynamic>>[
        ref.refresh(adminTechnicianLiveProvider.future),
      ];
      if (shouldRefreshHistory) {
        tasks.add(ref.refresh(adminTechnicianHistoryProvider.future));
      }
      await Future.wait(tasks);
    } finally {
      if (mounted) refreshInProgress = false;
    }
  }

  // ─────────────────────────────────────────────────────
  // KEY BUILDERS
  // ─────────────────────────────────────────────────────

  String buildCompositeTrackingKey(int? technicianId, int? jobId) =>
      'tech:${technicianId ?? '-'}|job:${jobId ?? '-'}';

  String? buildTechnicianFallbackKey(int? technicianId) {
    if (technicianId == null) return null;
    return 'tech:$technicianId';
  }

  String primaryTrackingKeyForLocation(TechnicianLocation location) =>
      location.technicianFallbackKey ?? location.trackingKey;

  Color colorForTrackingKey(String key) {
    final index = key.hashCode.abs() % technicianPalette.length;
    return technicianPalette[index];
  }

  String markerLabel(TechnicianLocation location) {
    final parts = location.technicianName
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    if (parts.length == 1 && parts.first.length >= 2) {
      return parts.first.substring(0, 2).toUpperCase();
    }
    final id = location.technicianId;
    if (id != null) return 'T$id';
    return 'TE';
  }

  // ─────────────────────────────────────────────────────
  // FILTER / FEED
  // ─────────────────────────────────────────────────────

  bool matchesFilters(Map<String, dynamic> row) {
    final jobId = asInt(row['job_id']);
    final technicianId = asInt(row['technician_id']);
    if (widget.jobIdFilter != null && jobId != widget.jobIdFilter) {
      return false;
    }
    if (widget.technicianIdFilter != null &&
        technicianId != widget.technicianIdFilter) {
      return false;
    }
    return true;
  }

  bool rowShouldAppearInFeed(Map<String, dynamic> row) =>
      TrackingPresence.evaluate(row).shouldAppearInFeed;

  bool rowIsLive(Map<String, dynamic> row) {
    final snapshot = TrackingPresence.evaluate(row);
    return snapshot.isLive;
  }

  List<Map<String, dynamic>> dedupeRowsByTrackingKey(
    List<Map<String, dynamic>> rows, {
    required String timestampField,
  }) {
    final latestByKey = <String, Map<String, dynamic>>{};

    for (final row in rows) {
      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final key = technicianId != null
          ? buildCompositeTrackingKey(technicianId, jobId)
          : 'coords:${row['latitude']}|${row['longitude']}';

      final rowAt = asDateTime(row[timestampField]) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final currentAt = latestByKey[key] == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : asDateTime(latestByKey[key]![timestampField]) ??
              DateTime.fromMillisecondsSinceEpoch(0);

      if (rowAt.isAfter(currentAt)) latestByKey[key] = row;
    }

    final deduped = latestByKey.values.toList()
      ..sort((a, b) {
        final aAt = asDateTime(a[timestampField]) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b[timestampField]) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bAt.compareTo(aAt);
      });

    return deduped;
  }

  // ─────────────────────────────────────────────────────
  // LOCATION EXTRACTION
  // ─────────────────────────────────────────────────────

  List<TechnicianLocation> extractLocations(List<Map<String, dynamic>> rows) {
    final result = <TechnicianLocation>[];

    for (final row in rows) {
      if (!rowIsLive(row)) continue;
      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final trackingKey = buildCompositeTrackingKey(technicianId, jobId);

      result.add(TechnicianLocation(
        markerKey: trackingKey,
        trackingKey: trackingKey,
        technicianFallbackKey: buildTechnicianFallbackKey(technicianId),
        technicianId: technicianId,
        jobId: jobId,
        technicianName: asText(row['technician_name'], fallback: 'Technician'),
        jobTitle: asText(row['job_title'], fallback: 'No job assigned'),
        jobStatus: asText(row['job_status'] ?? row['status']),
        trackingStatus: asText(row['tracking_status']),
        updatedAt: asDateTime(row['updated_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        isLive: true,
        isOfflineHistory: false,
        sourceLabel: 'Live now',
        latLng: LatLng(lat, lng),
        speed: asDouble(row['speed']),
        accuracy: asDouble(row['accuracy']),
        bearing: readBearing(row),
      ));
    }

    return result;
  }

  List<TechnicianLocation> extractLastKnownLocations(
    List<Map<String, dynamic>> rows,
  ) {
    final latestByKey = <String, Map<String, dynamic>>{};

    for (final row in rows) {
      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final key = buildCompositeTrackingKey(technicianId, jobId);

      final rowAt = asDateTime(row['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bestAt = latestByKey[key] == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : asDateTime(latestByKey[key]!['updated_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);

      if (rowAt.isAfter(bestAt)) latestByKey[key] = row;
    }

    final result = <TechnicianLocation>[];
    for (final row in latestByKey.values) {
      final lat = asDouble(row['latitude'])!;
      final lng = asDouble(row['longitude'])!;
      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final trackingKey = buildCompositeTrackingKey(technicianId, jobId);

      result.add(TechnicianLocation(
        markerKey: trackingKey,
        trackingKey: trackingKey,
        technicianFallbackKey: buildTechnicianFallbackKey(technicianId),
        technicianId: technicianId,
        jobId: jobId,
        technicianName: asText(row['technician_name'], fallback: 'Technician'),
        jobTitle: asText(row['job_title'], fallback: 'No job assigned'),
        jobStatus: asText(row['job_status'] ?? row['status']),
        trackingStatus: asText(row['tracking_status']),
        updatedAt: asDateTime(row['updated_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        isLive: false,
        isOfflineHistory: true,
        sourceLabel: 'Last synced',
        latLng: LatLng(lat, lng),
        speed: asDouble(row['speed']),
        accuracy: asDouble(row['accuracy']),
        bearing: readBearing(row),
      ));
    }

    result.sort((a, b) {
      final aAt =
          asDateTime(a.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt =
          asDateTime(b.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });

    return result;
  }

  List<TechnicianLocation> extractOfflineHistoryLocations(
    List<Map<String, dynamic>> liveRows,
    List<Map<String, dynamic>> historyRows,
  ) {
    final metadataByKey = <String, Map<String, dynamic>>{};
    for (final row in liveRows) {
      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final compositeKey = buildCompositeTrackingKey(technicianId, jobId);
      metadataByKey[compositeKey] = row;
      final fallbackKey = buildTechnicianFallbackKey(technicianId);
      if (fallbackKey != null) {
        metadataByKey.putIfAbsent(fallbackKey, () => row);
      }
    }

    final latestHistoryByKey = <String, Map<String, dynamic>>{};
    for (final row in historyRows) {
      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final compositeKey = buildCompositeTrackingKey(technicianId, jobId);
      final fallbackKey = buildTechnicianFallbackKey(technicianId);

      final String effectiveKey;
      if (metadataByKey.containsKey(compositeKey)) {
        effectiveKey = compositeKey;
      } else if (fallbackKey != null &&
          metadataByKey.containsKey(fallbackKey)) {
        effectiveKey = fallbackKey;
      } else {
        effectiveKey = compositeKey;
      }

      final rowAt = asDateTime(row['captured_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bestAt = latestHistoryByKey[effectiveKey] == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : asDateTime(latestHistoryByKey[effectiveKey]!['captured_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);

      if (rowAt.isAfter(bestAt)) latestHistoryByKey[effectiveKey] = row;
    }

    final result = <TechnicianLocation>[];
    for (final entry in latestHistoryByKey.entries) {
      final point = entry.value;
      final lat = asDouble(point['latitude']);
      final lng = asDouble(point['longitude']);
      if (lat == null || lng == null) continue;

      final metadata = metadataByKey[entry.key] ?? point;
      final technicianId =
          asInt(point['technician_id']) ?? asInt(metadata['technician_id']);
      final jobId = asInt(point['job_id']) ?? asInt(metadata['job_id']);
      final trackingKey = buildCompositeTrackingKey(technicianId, jobId);

      result.add(TechnicianLocation(
        markerKey: trackingKey,
        trackingKey: trackingKey,
        technicianFallbackKey: buildTechnicianFallbackKey(technicianId),
        technicianId: technicianId,
        jobId: jobId,
        technicianName: asText(
          metadata['technician_name'],
          fallback: widget.technicianNameHint ?? 'Technician',
        ),
        jobTitle: asText(
          metadata['job_title'],
          fallback: widget.jobTitleHint ?? 'Job $jobId',
        ),
        jobStatus: asText(
          metadata['job_status'] ?? metadata['status'],
          fallback: 'Offline history',
        ),
        trackingStatus: asText(
          metadata['tracking_status'],
          fallback: 'Offline history',
        ),
        updatedAt:
            asDateTime(point['captured_at'] ?? metadata['updated_at']) ??
                DateTime.fromMillisecondsSinceEpoch(0),
        isLive: false,
        isOfflineHistory: true,
        sourceLabel: 'Offline history',
        latLng: LatLng(lat, lng),
        speed: asDouble(point['speed'] ?? metadata['speed']),
        accuracy: asDouble(point['accuracy'] ?? metadata['accuracy']),
        bearing: readBearing(point) ?? readBearing(metadata),
      ));
    }

    result.sort((a, b) {
      final aAt =
          asDateTime(a.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt =
          asDateTime(b.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });

    return result;
  }

  // ─────────────────────────────────────────────────────
  // ══ ROUTE PATH BUILDERS ══
  //
  // ARCHITECTURE RULE — DO NOT VIOLATE:
  //
  //   LIVE mode   → buildLiveOnlyPolylines()
  //                 Uses _liveTrailByKey ONLY.
  //                 NEVER reads DB history rows.
  //
  //   OFFLINE mode → buildOfflineHistoryPaths() → buildOfflinePolylines()
  //                  Uses DB history rows ONLY.
  //                  NEVER reads _liveTrailByKey.
  //
  // Mixing the two sources causes triangles, loops, and backtracking.
  // ─────────────────────────────────────────────────────

  // ── LIVE POLYLINES ─────────────────────────────────────────────────────────

  /// Returns blue polylines built purely from the in-memory live trail.
  ///
  /// Call this when the job is ACTIVE (isLiveMode == true).
  /// Only draws a polyline once ≥2 points are in the trail AND
  /// the technician has moved ≥ _minDistanceForPolyline from the first point.
  ///
  /// Never call this in offline/history mode.
  List<Polyline> buildLiveOnlyPolylines(List<TechnicianLocation> locations) {
    if (locations.isEmpty) return const <Polyline>[];

    // Keep the trail up-to-date before building polylines.
    syncLiveRouteTrails(locations);

    final polylines = <Polyline>[];

    for (final location in locations) {
      if (!location.isLive) continue;

      final trail = _liveTrailByKey[location.trackingKey];
      if (trail == null || trail.length < 2) continue;

      final trailSorted = trail.toList(growable: false)
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

      final points = trailSorted.map((p) => p.latLng).toList(growable: false);

      // Downsample to avoid jank on very long trails.
      final displayPoints =
          points.length > 1000 ? downsamplePath(points, maxPoints: 1000) : points;

      if (displayPoints.length < 2) continue;

      // Remember bearing for the marker arrow.
      _rememberRouteBearing(location, displayPoints);

      polylines.add(
        Polyline(
          points: displayPoints,
          strokeWidth: 5,
          color: const Color(0xFF2563EB).withValues(alpha: 0.9),
          borderColor: Colors.white.withValues(alpha: 0.85),
          borderStrokeWidth: 2,
          strokeCap: StrokeCap.round,
        ),
      );
    }

    return polylines;
  }

  // ── OFFLINE / HISTORY PATHS ────────────────────────────────────────────────

  /// Builds ordered route paths directly from raw DB history rows.
  ///
  /// Call this for offlineHistoryOnly mode OR when a job is completed
  /// and the screen switches from live to offline view.
  ///
  /// The path produced here is the EXACT same sequence of points that
  /// the tracking service stored, so live-route == offline-route.
  List<List<LatLng>> buildOfflineHistoryPaths(
    List<Map<String, dynamic>> historyRows,
  ) {
    if (historyRows.isEmpty) return const <List<LatLng>>[];

    // Group by technician + job composite key.
    final grouped = <String, List<Map<String, dynamic>>>{};

    for (final row in historyRows) {
      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final techId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final key = buildCompositeTrackingKey(techId, jobId);
      grouped.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
    }

    final paths = <List<LatLng>>[];

    for (final rows in grouped.values) {
      // Sort chronologically so the path flows in the correct direction.
      rows.sort((a, b) {
        final aAt = asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

      final coords = cleanAndSimplifyPath(rows, isOfflineHistory: true);
      if (coords.length >= 2) paths.add(coords);
    }

    return paths;
  }

  /// Grey, thicker polylines for offline / history modes.
  List<Polyline> buildOfflinePolylines(List<List<LatLng>> routePaths) {
    if (routePaths.isEmpty) return const <Polyline>[];

    return routePaths
        .map((coordinates) => Polyline(
              points: coordinates,
              strokeWidth: 4,
              color: const Color(0xFF64748B).withValues(alpha: 0.85),
              borderColor: Colors.white.withValues(alpha: 0.7),
              borderStrokeWidth: 1.5,
              strokeCap: StrokeCap.round,
            ))
        .toList(growable: false);
  }

  // ── DEPRECATED / UNUSED ────────────────────────────────────────────────────
  // Kept here to avoid breaking callers during migration, but both methods
  // now delegate to the correct separated builders.

  /// @deprecated Use buildLiveOnlyPolylines() for live mode.
  List<Polyline> buildLiveRoutePolylines(List<List<LatLng>> routePaths) {
    return buildOfflinePolylines(routePaths); // fallback — should not be called
  }

  /// @deprecated Use buildOfflinePolylines() for history mode.
  List<Polyline> buildHistoryPolylines(List<List<LatLng>> routePaths) {
    return buildOfflinePolylines(routePaths);
  }

  // ── LEGACY: buildLiveAwareRoutePaths ──────────────────────────────────────
  // This method used to merge history + live trail + current marker position
  // into a single route, which caused triangles, loops, and path mismatch.
  //
  // It is now DISABLED. Callers should use:
  //   - buildLiveOnlyPolylines()  for live mode
  //   - buildOfflineHistoryPaths() + buildOfflinePolylines()  for offline mode
  //
  // The method body is intentionally empty so any accidental call returns
  // an empty list rather than corrupting the route.
  List<List<LatLng>> buildLiveAwareRoutePaths(
    List<Map<String, dynamic>> historyRows,
    List<TechnicianLocation> activeLocations,
    bool allowTechnicianFallback, {
    required bool strictLiveSession,
  }) {
    // INTENTIONALLY DISABLED — causes route corruption when live + history
    // are mixed. Use buildLiveOnlyPolylines or buildOfflineHistoryPaths.
    return const <List<LatLng>>[];
  }

  // ─────────────────────────────────────────────────────
  // ENDPOINT MARKERS
  // ─────────────────────────────────────────────────────

  List<Marker> buildHistoryEndpointMarkers(List<List<LatLng>> routePaths) {
    if (routePaths.isEmpty) return const <Marker>[];

    final markers = <Marker>[];
    for (var index = 0; index < routePaths.length; index++) {
      final route = routePaths[index];
      if (route.isEmpty) continue;

      markers.add(
        _buildRouteDotMarker(
          key: 'route_start_$index',
          point: route.first,
          color: const Color(0xFF16A34A),
          size: 14,
        ),
      );
      markers.add(
        _buildRouteDotMarker(
          key: 'route_end_$index',
          point: route.last,
          color: const Color(0xFFDC2626),
          size: 16,
        ),
      );
    }

    return markers;
  }

  Marker _buildRouteDotMarker({
    required String key,
    required LatLng point,
    required Color color,
    required double size,
  }) {
    return Marker(
      key: ValueKey(key),
      point: point,
      width: size,
      height: size,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────
  // PATH CLEANING
  // ─────────────────────────────────────────────────────

  /// Cleans and simplifies a raw list of DB rows into a LatLng path.
  ///
  /// - Accuracy filter: null accuracy is accepted (treat as valid).
  /// - Cold-start fix: drops first point if accuracy is null and the second
  ///   point is well-located and far away (GPS not yet locked).
  /// - Long-pause jump filter: if two consecutive points have a time gap
  ///   ≥ _pauseJumpWindow AND distance > _pauseJumpMaxMeters, the path is
  ///   split at that gap (point is still included; gap is just not bridged).
  ///   This matches the tracking service's long-pause rejection logic so
  ///   offline route == live route.
  List<LatLng> cleanAndSimplifyPath(
    List<Map<String, dynamic>> points, {
    bool isOfflineHistory = false,
  }) {
    if (points.isEmpty) return <LatLng>[];

    final accuracyThreshold =
        isOfflineHistory ? _historyAccuracyThresholdMeters : _liveAccuracyThresholdMeters;

    // Accuracy filter — null passes through.
    final validPoints = points.where((point) {
      final accuracy = asDouble(point['accuracy']);
      return accuracy == null || accuracy <= accuracyThreshold;
    }).toList();

    if (validPoints.isEmpty) return <LatLng>[];

    // Cold-start fix — drop first point if it has null accuracy AND the second
    // point is well-located and the two are far apart.
    if (validPoints.length >= 2) {
      final first = validPoints[0];
      final second = validPoints[1];
      final firstAcc = asDouble(first['accuracy']);
      final secondAcc = asDouble(second['accuracy']);
      if (firstAcc == null && secondAcc != null && secondAcc <= 10.0) {
        final lat1 = asDouble(first['latitude']);
        final lng1 = asDouble(first['longitude']);
        final lat2 = asDouble(second['latitude']);
        final lng2 = asDouble(second['longitude']);
        if (lat1 != null && lng1 != null && lat2 != null && lng2 != null) {
          final dist = distanceMeters(LatLng(lat1, lng1), LatLng(lat2, lng2));
          if (dist > 15.0) {
            validPoints.removeAt(0);
          }
        }
      }
    }

    if (validPoints.length < 2) {
      final p = validPoints.isEmpty ? null : validPoints.first;
      if (p == null) return <LatLng>[];
      final lat = asDouble(p['latitude']);
      final lng = asDouble(p['longitude']);
      if (lat != null && lng != null && lat != 0.0 && lng != 0.0) {
        return <LatLng>[LatLng(lat, lng)];
      }
      return <LatLng>[];
    }

    final cleaned = <LatLng>[];
    LatLng? previous;
    DateTime? previousTime;

    for (final point in validPoints) {
      final lat = asDouble(point['latitude']);
      final lng = asDouble(point['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final current = LatLng(lat, lng);
      final currentTime = asDateTime(point['captured_at'] ?? point['updated_at']);

      if (previous == null) {
        cleaned.add(current);
        previous = current;
        previousTime = currentTime;
        continue;
      }

      final distance = distanceMeters(previous, current);
      if (distance < 1.0) continue;

      // ── LONG-PAUSE JUMP FILTER ─────────────────────────────────────────────
      // If the time gap between this point and the previous accepted point is
      // ≥ _pauseJumpWindow AND the distance is > _pauseJumpMaxMeters, this is
      // a GPS wakeup spike after a rest — skip it.
      // This keeps the offline route identical to what the live polyline showed.
      if (previousTime != null && currentTime != null) {
        final gap = currentTime.difference(previousTime).abs();
        if (gap >= _pauseJumpWindow && distance > _pauseJumpMaxMeters) {
          // Skip the bad wakeup point; the next position will be evaluated
          // from `previous` again (we do NOT update previous/previousTime).
          continue;
        }
      }

      int elapsedSeconds = 0;
      if (previousTime != null && currentTime != null) {
        elapsedSeconds =
            currentTime.difference(previousTime).inSeconds.abs();
      }

      final maxDistanceMeters = (elapsedSeconds * 55.0 + 100)
          .clamp(100.0, isOfflineHistory ? 10000.0 : 5000.0);

      if (distance <= maxDistanceMeters) {
        cleaned.add(current);
        previous = current;
        previousTime = currentTime;
      }
    }

    if (cleaned.length > 500) {
      return downsamplePath(cleaned, maxPoints: 500);
    }

    return cleaned;
  }

  // ─────────────────────────────────────────────────────
  // TRIM / DOWNSAMPLE
  // ─────────────────────────────────────────────────────

  List<Map<String, dynamic>> trimRouteHistory(
    List<Map<String, dynamic>> points, {
    required Duration maxAge,
    required int maxPoints,
  }) {
    if (points.isEmpty) return <Map<String, dynamic>>[];

    final sorted = points.toList()
      ..sort((a, b) {
        final aAt = asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

    final threshold = DateTime.now().toUtc().subtract(maxAge);
    final recent = sorted.where((point) {
      final capturedAt = asDateTime(point['captured_at'])?.toUtc();
      return capturedAt == null || !capturedAt.isBefore(threshold);
    }).toList();

    if (recent.length <= maxPoints) return recent;
    return recent.sublist(recent.length - maxPoints);
  }

  RouteMetrics? summarizeRoute(
    List<LatLng> points, {
    required int minimumPointCount,
    required double minimumDistanceMeters,
    required LatLng anchor,
  }) {
    if (points.length < minimumPointCount) return null;

    final route = <LatLng>[];
    double totalDistance = 0;
    LatLng? previous;

    for (final point in points) {
      if (previous != null) totalDistance += distanceMeters(previous, point);
      route.add(point);
      previous = point;
    }

    if (route.isEmpty) return null;

    final distanceToAnchor = distanceMeters(route.last, anchor);
    if (distanceToAnchor > 5 && distanceToAnchor <= 150) {
      route.add(anchor);
      totalDistance += distanceToAnchor;
    }

    if (route.length < minimumPointCount ||
        totalDistance < minimumDistanceMeters) {
      return null;
    }

    return RouteMetrics(points: route);
  }

  List<LatLng> downsamplePath(
    List<LatLng> points, {
    required int maxPoints,
  }) {
    if (points.length <= maxPoints) return points;
    final stride = (points.length / maxPoints).ceil();
    final sampled = <LatLng>[];
    for (var i = 0; i < points.length; i += stride) {
      sampled.add(points[i]);
    }
    final last = points.last;
    if (sampled.isEmpty ||
        sampled.last.latitude != last.latitude ||
        sampled.last.longitude != last.longitude) {
      sampled.add(last);
    }
    return sampled;
  }

  // ─────────────────────────────────────────────────────
  // MARKER BUILDER
  // ─────────────────────────────────────────────────────

  TechnicianLocation? findLocationByMarkerKey(
    List<TechnicianLocation> locations,
    String markerKey,
  ) {
    for (final location in locations) {
      if (location.markerKey == markerKey) return location;
    }
    return null;
  }

  List<Marker> buildMarkers(List<TechnicianLocation> locations) {
    _prevPositions.removeWhere(
      (key, _) => !locations.any((location) => location.markerKey == key),
    );

    return locations.map((location) {
      final color =
          colorForTrackingKey(primaryTrackingKeyForLocation(location));
      final isSelected = selectedLocation?.markerKey == location.markerKey;
      final previous = _prevPositions[location.markerKey];
      final next = location.latLng;

      final shouldAnimate = previous != null && _shouldAnimate(previous, next);
      _prevPositions[location.markerKey] = next;

      Widget markerUi({required LatLng position, double? angle}) {
        final routeAngle = _routeBearingRadiansFor(location);
        final headingAngle = bearingRadiansFor(location);
        final resolvedAngle =
            !_bearingLooksUnset(location.bearing) ? headingAngle! : null;
        final markerAngle = resolvedAngle ??
            angle ??
            routeAngle ??
            (previous != null ? _calculateBearing(previous, next) : 0.0);

        final arrowSize = isSelected ? 34.0 : 30.0;
        final outlineSize = arrowSize + 8;

        final base = SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: Transform.rotate(
              angle: markerAngle,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.navigation_rounded,
                    size: outlineSize,
                    color: Colors.white,
                    shadows: const [
                      BoxShadow(
                        color: Color(0x44000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  Icon(
                    Icons.navigation_rounded,
                    size: arrowSize,
                    color: color,
                  ),
                ],
              ),
            ),
          ),
        );

        return GestureDetector(
          onTap: () => setState(() => selectedLocation = location),
          child: Builder(
            builder: (context) {
              final camera = MapCamera.maybeOf(context);
              var offset = Offset.zero;
              if (camera != null) {
                final animatedOffset = camera.getOffsetFromOrigin(position);
                final anchorOffset = camera.getOffsetFromOrigin(next);
                offset = animatedOffset - anchorOffset;
              }

              return OverflowBox(
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: offset,
                  child: base,
                ),
              );
            },
          ),
        );
      }

      if (previous == null || !shouldAnimate) {
        return Marker(
          key: ValueKey(location.markerKey),
          point: next,
          width: 56,
          height: 56,
          alignment: Alignment.center,
          child: markerUi(position: next),
        );
      }

      return Marker(
        key: ValueKey(location.markerKey),
        point: next,
        width: 56,
        height: 56,
        alignment: Alignment.center,
        child: AnimatedMarkerWidget(
          key: ValueKey(location.markerKey),
          position: next,
          previous: previous,
          speed: location.speed,
          builder: (position, bearing) => markerUi(
            position: position,
            angle: bearing,
          ),
        ),
      );
    }).toList();
  }

  // ─────────────────────────────────────────────────────
  // CAMERA
  // ─────────────────────────────────────────────────────

  void fitCamera(List<TechnicianLocation> locations, {bool force = false}) {
    if (!mapReady || locations.isEmpty) return;
    if (cameraFramed && !force) return;

    if (locations.length == 1) {
      mapController.move(locations.first.latLng, 15);
    } else {
      mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: locations.map((location) => location.latLng).toList(),
          padding: const EdgeInsets.all(56),
          maxZoom: 16,
        ),
      );
    }

    cameraFramed = true;
  }

  TechnicianLocation? _liveFollowTarget(List<TechnicianLocation> locations) {
    final selectedKey = selectedLocation?.markerKey;
    if (selectedKey != null) {
      for (final location in locations) {
        if (location.markerKey == selectedKey && location.isLive) {
          return location;
        }
      }
    }

    if (locations.length == 1 && locations.first.isLive) {
      return locations.first;
    }

    return null;
  }

  void followLiveCamera(List<TechnicianLocation> locations) {
    if (!mapReady || locations.isEmpty) return;

    final target = _liveFollowTarget(locations);
    if (target == null) return;

    final previous = _lastFollowedCameraPositions[target.markerKey];
    if (previous != null && distanceMeters(previous, target.latLng) < 1) {
      return;
    }

    final currentZoom = mapController.camera.zoom;
    final zoom = currentZoom < 18 ? 18.0 : currentZoom;
    mapController.move(target.latLng, zoom);
    _lastFollowedCameraPositions[target.markerKey] = target.latLng;
  }

  LatLng _smooth(LatLng prev, LatLng next, double? speed) {
    final distance = distanceMeters(prev, next);

    double alpha;
    if (speed != null && speed > 10) {
      alpha = 0.6;
    } else if (distance > 20) {
      alpha = 0.5;
    } else {
      alpha = 0.25;
    }

    return LatLng(
      prev.latitude + alpha * (next.latitude - prev.latitude),
      prev.longitude + alpha * (next.longitude - prev.longitude),
    );
  }
}