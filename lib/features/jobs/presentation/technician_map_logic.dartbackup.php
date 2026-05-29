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
  static const Duration liveRefreshInterval = Duration(seconds: 5);
  static const Duration historyRefreshInterval = Duration(seconds: 10);
  static const LatLng defaultCenter = LatLng(12.9716, 77.5946);
  static const String userAgentPackageName = 'com.example.fsm';
  static const Duration liveTrailMaxAge = Duration(hours: 24);
  static const int liveTrailMaxPoints = 5000;

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

    if (distance < 1) return false; // Ignore jitter.
    if (distance > 300) return false; // Ignore GPS spikes.

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
     if (location.accuracy != null && location.accuracy! > 35) return; // ← add this
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

    if (distance < 0.8) {
      if (point.capturedAt.isAfter(last.capturedAt)) {
        trail[trail.length - 1] = point;
      }
      return;
    }

    if (distance > 600) {
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

      final metadata = metadataByKey[entry.key] ?? const <String, dynamic>{};
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
        updatedAt: asDateTime(point['captured_at'] ?? metadata['updated_at']) ??
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

  bool isSyntheticHistoryPoint(Map<String, dynamic> row) {
    final source = row['source']?.toString().trim().toLowerCase();
    return source == 'live_snapshot';
  }

  // List<Map<String, dynamic>> restrictHistoryToLiveSession(
  //   List<Map<String, dynamic>> points,
  //   TechnicianLocation location,
  // ) {
  //   final anchorAt = asDateTime(location.updatedAt)?.toLocal();
  //   if (anchorAt == null) return points;

  //   final earliest = anchorAt.subtract(const Duration(minutes: 25));
  //   final latest = anchorAt.add(const Duration(minutes: 30));

  //   return points.where((point) {
  //     final capturedAt = asDateTime(point['captured_at'])?.toLocal();
  //     if (capturedAt == null) return false;
  //     return !capturedAt.isBefore(earliest) && !capturedAt.isAfter(latest);
  //   }).toList();
  // }
List<Map<String, dynamic>> restrictHistoryToLiveSession(
  List<Map<String, dynamic>> points,
  TechnicianLocation location,
) {
  return points;
}
  List<List<LatLng>> buildHistoryRoutePaths(
    List<Map<String, dynamic>> historyRows,
    List<TechnicianLocation> activeLocations,
    bool allowTechnicianFallback, {
    required bool strictLiveSession,
  }) {
    if (historyRows.isEmpty || activeLocations.isEmpty) {
      return const <List<LatLng>>[];
    }

    final byKey = <String, TechnicianLocation>{};
    for (final location in activeLocations) {
      byKey[location.trackingKey] = location;
      final fallbackKey = location.technicianFallbackKey;
      if (fallbackKey != null) {
        byKey.putIfAbsent(fallbackKey, () => location);
      }
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in historyRows) {
      if (strictLiveSession && isSyntheticHistoryPoint(row)) continue;

      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final compositeKey = buildCompositeTrackingKey(technicianId, jobId);

      String? matchedKey =
          byKey.containsKey(compositeKey) ? compositeKey : null;
      if (matchedKey == null && allowTechnicianFallback) {
        final fallbackKey = buildTechnicianFallbackKey(technicianId);
        if (fallbackKey != null && byKey.containsKey(fallbackKey)) {
          matchedKey = fallbackKey;
        }
      }
      if (matchedKey == null) continue;

      grouped.putIfAbsent(matchedKey, () => <Map<String, dynamic>>[]).add(row);
    }

    final routePaths = <List<LatLng>>[];
    for (final entry in grouped.entries) {
      final location = byKey[entry.key];
      if (location == null) continue;

      // 🛠️ FIX 1: Bypass strict 25-minute live filtering if the sync payload is small (e.g., 2 points)
      final useStrictFilters = strictLiveSession && entry.value.length > 2;

      final scopedPoints = useStrictFilters
          ? restrictHistoryToLiveSession(entry.value, location)
          : entry.value;

      final trimmed = trimRouteHistory(
        scopedPoints,
        maxAge: (allowTechnicianFallback || !useStrictFilters)
            ? const Duration(
                hours: 24) // 🛠️ FIX 2: Give offline history a wide window
            : const Duration(minutes: 45),
        maxPoints: allowTechnicianFallback ? 500 : 200,
      ).toList(growable: true);

      trimmed.sort((a, b) {
        final aAt = asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

      

      final coordinates = cleanAndSimplifyPath(trimmed).toList(growable: true);

      // 🛠️ FIX 3: Force append the actual active anchor point to close the gap
      if (coordinates.isNotEmpty) {
        final distanceToAnchor =
            distanceMeters(coordinates.last, location.latLng);
        if (distanceToAnchor > 0.5 && distanceToAnchor <= 5000) {
          if (coordinates.last.latitude != location.latLng.latitude ||
              coordinates.last.longitude != location.latLng.longitude) {
            coordinates.add(location.latLng);
          }
        }
      } else {
        // If filters stripped everything, seed with the only known spot
        coordinates.add(location.latLng);
      }

      // 🛠️ FIX 4: Explicitly allow 2 points to build a path vector
      if (coordinates.length < 2) continue;
      routePaths.add(coordinates);
    }

    return routePaths;
  }

  List<List<LatLng>> buildLiveAwareRoutePaths(
    List<Map<String, dynamic>> historyRows,
    List<TechnicianLocation> activeLocations,
    bool allowTechnicianFallback, {
    required bool strictLiveSession,
  }) {
    if (activeLocations.isEmpty) return const <List<LatLng>>[];

    syncLiveRouteTrails(activeLocations);

    final byKey = <String, TechnicianLocation>{};
    for (final location in activeLocations) {
      byKey[location.trackingKey] = location;
      final fallbackKey = location.technicianFallbackKey;
      if (fallbackKey != null) {
        byKey.putIfAbsent(fallbackKey, () => location);
      }
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in historyRows) {
      if (strictLiveSession && isSyntheticHistoryPoint(row)) continue;

      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final technicianId = asInt(row['technician_id']);
      final jobId = asInt(row['job_id']);
      final compositeKey = buildCompositeTrackingKey(technicianId, jobId);

      String? matchedKey =
          byKey.containsKey(compositeKey) ? compositeKey : null;
      if (matchedKey == null && allowTechnicianFallback) {
        final fallbackKey = buildTechnicianFallbackKey(technicianId);
        if (fallbackKey != null && byKey.containsKey(fallbackKey)) {
          matchedKey = fallbackKey;
        }
      }
      if (matchedKey == null) continue;

      grouped.putIfAbsent(matchedKey, () => <Map<String, dynamic>>[]).add(row);
    }

    final routePaths = <List<LatLng>>[];
    for (final location in activeLocations) {
      final routeRows = <Map<String, dynamic>>[];
      final exactRows = grouped[location.trackingKey];
      if (exactRows != null) routeRows.addAll(exactRows);

      final fallbackKey = location.technicianFallbackKey;
      if (allowTechnicianFallback &&
          fallbackKey != null &&
          fallbackKey != location.trackingKey) {
        final fallbackRows = grouped[fallbackKey];
        if (fallbackRows != null) routeRows.addAll(fallbackRows);
      }

      final useStrictFilters = strictLiveSession && routeRows.length > 2;
      final scopedPoints = useStrictFilters
          ? restrictHistoryToLiveSession(routeRows, location)
          : routeRows;

      final trimmed = trimRouteHistory(
        scopedPoints,
        maxAge: (allowTechnicianFallback || !useStrictFilters)
            ? const Duration(hours: 24)
            : const Duration(minutes: 45),
        maxPoints: allowTechnicianFallback ? 500 : 200,
      ).toList(growable: true);

      trimmed.sort((a, b) {
        final aAt = asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

      final coordinates = cleanAndSimplifyPath(trimmed).toList(growable: true);
      final liveTrail =
          location.isLive ? _liveTrailByKey[location.trackingKey] : null;

      if (liveTrail != null && liveTrail.isNotEmpty) {
        final livePoints = liveTrail.toList(growable: false)
          ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

        for (final point in livePoints) {
          _appendRouteCoordinate(
            coordinates,
            point.latLng,
            maxGapMeters: 5000,
          );
        }
      }

      _appendRouteCoordinate(
        coordinates,
        location.latLng,
        maxGapMeters: location.isLive ? 5000 : 800,
      );

      if (coordinates.length < 2) continue;
      final route = downsamplePath(
        coordinates,
        maxPoints: location.isLive ? 240 : 500,
      );
      _rememberRouteBearing(location, route);
      routePaths.add(route);
    }

    return routePaths;
  }

  List<Polyline> buildHistoryPolylines(List<List<LatLng>> routePaths) {
    if (routePaths.isEmpty) return const <Polyline>[];

    return routePaths
        .map(
          (coordinates) => Polyline(
            points: coordinates,
            strokeWidth: 8,
            color: const Color(
                0xFF64748B), // 🛠️ FIX: Use neutral slate-grey for historical lines
            borderColor: Colors.white.withValues(alpha: 0.9),
            borderStrokeWidth: 1.5,
            strokeCap: StrokeCap.round,
          ),
        )
        .toList(growable: false);
  }

  List<Polyline> buildLiveRoutePolylines(List<List<LatLng>> routePaths) {
    if (routePaths.isEmpty) return const <Polyline>[];

    return routePaths
        .map(
          (coordinates) => Polyline(
            points: coordinates,
            strokeWidth: 5,
            color: const Color(0xFF2563EB).withValues(alpha: 0.9),
            borderColor: Colors.white.withValues(alpha: 0.85),
            borderStrokeWidth: 2,
            strokeCap: StrokeCap.round,
          ),
        )
        .toList(growable: false);
  }

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

List<LatLng> cleanAndSimplifyPath(List<Map<String, dynamic>> points) {
  // Filter low-accuracy points before building any path
  final accuratePoints = points.where((point) {
    final accuracy = asDouble(point['accuracy']);
    return accuracy == null || accuracy <= 35.0;
  }).toList();

  final cleaned = <LatLng>[];
  LatLng? previous;
  Map<String, dynamic>? previousPoint;

  // 🛠️ FIX 5: If we only have ≤2 points after filtering, bypass complex cleaning
  if (accuratePoints.length <= 2) {
    for (final point in accuratePoints) {
      final lat = asDouble(point['latitude']);
      final lng = asDouble(point['longitude']);
      if (lat != null && lng != null && lat != 0.0 && lng != 0.0) {
        cleaned.add(LatLng(lat, lng));
      }
    }
    return cleaned;
  }

  for (final point in accuratePoints) {   // ← was `points`, now `accuratePoints`
    final lat = asDouble(point['latitude']);
    final lng = asDouble(point['longitude']);
    if (lat == null || lng == null) continue;
    if (lat == 0.0 && lng == 0.0) continue;

    final raw = LatLng(lat, lng);
    final current = previous == null
        ? raw
        : _smooth(previous, raw, asDouble(point['speed']));

    if (previous == null) {
      cleaned.add(current);
      previous = current;
      previousPoint = point;
      continue;
    }

    final distance = distanceMeters(previous, current);
    final previousAt = asDateTime(previousPoint?['captured_at']);
    final currentAt = asDateTime(point['captured_at']);
    final elapsedSeconds = previousAt != null && currentAt != null
        ? currentAt.difference(previousAt).inSeconds.abs()
        : 0;

    final maxReasonableDistance =
        (elapsedSeconds * 55.0 + 100).clamp(500.0, 5000.0).toDouble();

    if (distance >= 0.5 && distance <= maxReasonableDistance) {
      cleaned.add(current);
      previous = current;
      previousPoint = point;
    }
  }

  return cleaned;
}
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

    final latestAt = asDateTime(sorted.last['captured_at']);
    if (latestAt == null) {
      return sorted.length <= maxPoints
          ? sorted
          : sorted.sublist(sorted.length - maxPoints);
    }

    final threshold = latestAt.subtract(maxAge);
    final recent = sorted.where((point) {
      final capturedAt = asDateTime(point['captured_at']);
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
      // 🛠️ FIX: Resolve dynamic key colors instead of forcing a static blue tone
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
      alpha = 0.6; // fast movement → less smoothing
    } else if (distance > 20) {
      alpha = 0.5;
    } else {
      alpha = 0.25; // slow → more smoothing
    }

    return LatLng(
      prev.latitude + alpha * (next.latitude - prev.latitude),
      prev.longitude + alpha * (next.longitude - prev.longitude),
    );
  }
}
