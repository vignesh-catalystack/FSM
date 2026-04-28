import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:fsm/features/jobs/application/job_controller.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';
// ADD THIS ENTIRE BLOCK HERE ↓
enum MapLayerType {
  standard,
  satellite,
  hybrid,
  terrain,
  dark;

  String get label => switch (this) {
    MapLayerType.standard  => 'Standard',
    MapLayerType.satellite => 'Satellite',
    MapLayerType.hybrid    => 'Hybrid',
    MapLayerType.terrain   => 'Terrain',
    MapLayerType.dark      => 'Dark',
  };

  IconData get icon => switch (this) {
    MapLayerType.standard  => Icons.map_outlined,
    MapLayerType.satellite => Icons.satellite_alt_outlined,
    MapLayerType.hybrid    => Icons.layers_outlined,
    MapLayerType.terrain   => Icons.terrain_outlined,
    MapLayerType.dark      => Icons.dark_mode_outlined,
  };

  String get urlTemplate => switch (this) {
    MapLayerType.standard =>
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    MapLayerType.satellite =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Imagery/MapServer/tile/{z}/{y}/{x}',
    MapLayerType.hybrid =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Imagery/MapServer/tile/{z}/{y}/{x}',
    MapLayerType.terrain =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
    MapLayerType.dark =>
      'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
  };

  List<String>? get subdomains => switch (this) {
    MapLayerType.dark => ['a', 'b', 'c', 'd'],
    _ => null,
  };

  bool get needsLabelOverlay => this == MapLayerType.hybrid;

  String get attribution => switch (this) {
    MapLayerType.standard =>
      'OpenStreetMap contributors',
    MapLayerType.satellite ||
    MapLayerType.hybrid    ||
    MapLayerType.terrain   =>
      'Esri, Maxar, Earthstar Geographics',
    MapLayerType.dark =>
      'CartoDB, OpenStreetMap contributors',
  };
}
class TechnicianLocationsMapScreen extends ConsumerStatefulWidget {
  const TechnicianLocationsMapScreen({
    super.key,
    this.jobIdFilter,
    this.technicianIdFilter,
    this.liveOnly = false,
    this.offlineHistoryOnly = false,
    this.jobTitleHint,
    this.technicianNameHint,
    this.seedRows,
  }) : assert(
         !(liveOnly && offlineHistoryOnly),
         'liveOnly and offlineHistoryOnly cannot both be true.',
       );

  final int? jobIdFilter;
  final int? technicianIdFilter;
  final bool liveOnly;
  final bool offlineHistoryOnly;
  final String? jobTitleHint;
  final String? technicianNameHint;
  final List<Map<String, dynamic>>? seedRows;

  @override
  ConsumerState<TechnicianLocationsMapScreen> createState() =>
      _TechnicianLocationsMapScreenState();
}

class _TechnicianLocationsMapScreenState
    extends ConsumerState<TechnicianLocationsMapScreen> {
  static const Duration _liveRefreshInterval = Duration(seconds: 8);
  static const Duration _historyRefreshInterval = Duration(seconds: 32);
  static const LatLng _defaultCenter = LatLng(12.9716, 77.5946); // Bengaluru
  // static const String _tileUrlTemplate =
  //     'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _userAgentPackageName = 'com.example.fsm';
  static const List<Color> _technicianPalette = <Color>[
    Color(0xFF2563EB),
    Color(0xFFEA580C),
    Color(0xFF0F9D58),
    Color(0xFF7C3AED),
    Color(0xFFDC2626),
    Color(0xFF0891B2),
    Color(0xFFCA8A04),
    Color(0xFFBE185D),
  ];

  final MapController _mapController = MapController();
  Timer? _refreshTimer;
  _TechnicianLocation? _selectedLocation;
  bool _cameraFramed = false;
  bool _mapReady = false;
  int _lastMarkerHash = 0;
  int _refreshTick = 0;
  bool _refreshInProgress = false;
  // ADD THIS LINE ↓
  MapLayerType _activeLayer = MapLayerType.standard;


  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(_liveRefreshInterval, (_) {
      if (!_shouldAutoRefresh()) return;
      unawaited(_refreshMapData());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  String _asText(dynamic value, {String fallback = '-'}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text) ?? DateTime.tryParse(text.replaceFirst(' ', 'T'));
  }

  String _timeAgo(dynamic value) {
    final date = _asDateTime(value)?.toLocal();
    if (date == null) return 'Unknown';

    final difference = DateTime.now().difference(date);
    if (difference.inSeconds < 45) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
  }

  String _syncPillLabel(dynamic value, {required bool isOfflineHistory}) {
    final label = _timeAgo(value);
    if (label == 'Unknown') return 'Sync unknown';
    if (isOfflineHistory) return 'Seen $label';
    return label == 'Just now' ? 'Live now' : 'Seen $label';
  }

  Color _syncPillColor(dynamic value, {required bool isOfflineHistory}) {
    final updatedAt = _asDateTime(value)?.toLocal();
    if (updatedAt == null) return const Color(0xFFF59E0B);
    if (!isOfflineHistory && _isTrackingFresh(value)) {
      return const Color(0xFF0F9D58);
    }
    return isOfflineHistory
        ? const Color(0xFF64748B)
        : const Color(0xFFB45309);
  }

  Color _sourcePillColor(_TechnicianLocation location) {
    switch (location.sourceLabel) {
      case 'Live now':
        return const Color(0xFF0F9D58);
      case 'Last synced':
        return const Color(0xFFB45309);
      default:
        return const Color(0xFF64748B);
    }
  }

  bool _isArchivedHistory(_TechnicianLocation location) {
    return location.sourceLabel == 'Offline history';
  }

  bool _isTrackingFresh(dynamic value) {
    final updatedAt = _asDateTime(value)?.toLocal();
    if (updatedAt == null) return false;
    return DateTime.now().difference(updatedAt) <=
        TrackingPresence.freshnessWindow;
  }

  String _titleCase(String value) {
    final cleaned = value.trim().replaceAll('_', ' ');
    if (cleaned.isEmpty) return '-';
    return cleaned
        .split(RegExp(r'\s+'))
        .map((word) {
          if (word.isEmpty) return word;
          return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
        })
        .join(' ');
  }

  double _distanceMeters(LatLng a, LatLng b) {
    return const Distance().as(LengthUnit.Meter, a, b);
  }

  bool _shouldAutoRefresh() {
    if (!mounted || _refreshInProgress) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
  }

  Future<void> _refreshMapData({bool forceHistory = false}) async {
    if (!mounted || _refreshInProgress) return;
    _refreshInProgress = true;
    _refreshTick++;

    final shouldRefreshHistory = forceHistory ||
        _refreshTick %
                (_historyRefreshInterval.inSeconds ~/
                    _liveRefreshInterval.inSeconds) ==
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
      _refreshInProgress = false;
    }
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  bool _isLiveTrackingRow(Map<String, dynamic> row) =>
      TrackingPresence.evaluate(row).isLive;

  List<Map<String, dynamic>> _dedupeRowsByTrackingKey(
    List<Map<String, dynamic>> rows, {
    required String timestampField,
  }) {
    final latestByKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final key = technicianId != null
          ? _buildCompositeTrackingKey(technicianId, jobId)
          : 'coords:${row['latitude']}|${row['longitude']}';
      final current = latestByKey[key];
      final rowAt = _asDateTime(row[timestampField]) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final currentAt = current == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : _asDateTime(current[timestampField]) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      if (current == null || rowAt.isAfter(currentAt)) {
        latestByKey[key] = row;
      }
    }

    final deduped = latestByKey.values.toList(growable: false);
    deduped.sort((a, b) {
      final aAt = _asDateTime(a[timestampField]) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = _asDateTime(b[timestampField]) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });
    return deduped;
  }

  String _buildCompositeTrackingKey(int? technicianId, int? jobId) {
    return 'tech:${technicianId?.toString() ?? '-'}|job:${jobId?.toString() ?? '-'}';
  }

  String? _buildTechnicianFallbackKey(int? technicianId) {
    if (technicianId == null) return null;
    return 'tech:${technicianId.toString()}';
  }

  String _primaryTrackingKeyForLocation(_TechnicianLocation location) {
    return location.technicianFallbackKey ?? location.trackingKey;
  }

  Color _colorForTrackingKey(String key) {
    final index = key.hashCode.abs() % _technicianPalette.length;
    return _technicianPalette[index];
  }

  String _markerLabel(_TechnicianLocation location) {
    final parts = location.technicianName
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    if (parts.length == 1 && parts.first.length >= 2) {
      return parts.first.substring(0, 2).toUpperCase();
    }
    final technicianId = location.technicianId;
    if (technicianId != null) return 'T$technicianId';
    return 'TE';
  }

  bool _hasDisplayValue(String? value) {
    final normalized = value?.trim();
    return normalized != null && normalized.isNotEmpty && normalized != '-';
  }

  List<_TechnicianLocation> _extractLocations(List<Map<String, dynamic>> rows) {
    final result = <_TechnicianLocation>[];
    for (final row in rows) {
      final lat = _asDouble(row['latitude']);
      final lng = _asDouble(row['longitude']);
      if (lat == null || lng == null) continue;

      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final trackingKey = _buildCompositeTrackingKey(technicianId, jobId);
      final technicianFallbackKey = _buildTechnicianFallbackKey(technicianId);

      result.add(
        _TechnicianLocation(
          markerKey: trackingKey,
          trackingKey: trackingKey,
          technicianFallbackKey: technicianFallbackKey,
          technicianId: technicianId,
          jobId: jobId,
          technicianName:
              _asText(row['technician_name'], fallback: 'Technician'),
          jobTitle: _asText(row['job_title'], fallback: 'No job assigned'),
          jobStatus: _asText(row['status']),
          trackingStatus: _asText(row['tracking_status']),
          updatedAt: row['updated_at'],
          isOfflineHistory: false,
          sourceLabel: 'Live now',
          latLng: LatLng(lat, lng),
        ),
      );
    }
    return result;
  }

  List<_TechnicianLocation> _extractLastKnownLocations(
    List<Map<String, dynamic>> rows,
  ) {
    final latestByKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final lat = _asDouble(row['latitude']);
      final lng = _asDouble(row['longitude']);
      if (lat == null || lng == null) continue;

      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final compositeKey = _buildCompositeTrackingKey(technicianId, jobId);
      final currentBest = latestByKey[compositeKey];
      final currentAt = _asDateTime(row['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bestAt = currentBest == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : _asDateTime(currentBest['updated_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      if (currentBest == null || currentAt.isAfter(bestAt)) {
        latestByKey[compositeKey] = row;
      }
    }

    final result = <_TechnicianLocation>[];
    for (final row in latestByKey.values) {
      final lat = _asDouble(row['latitude']);
      final lng = _asDouble(row['longitude']);
      if (lat == null || lng == null) continue;

      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final trackingKey = _buildCompositeTrackingKey(technicianId, jobId);

      result.add(
        _TechnicianLocation(
          markerKey: trackingKey,
          trackingKey: trackingKey,
          technicianFallbackKey: _buildTechnicianFallbackKey(technicianId),
          technicianId: technicianId,
          jobId: jobId,
          technicianName:
              _asText(row['technician_name'], fallback: 'Technician'),
          jobTitle: _asText(row['job_title'], fallback: 'No job assigned'),
          jobStatus: _asText(row['status']),
          trackingStatus: _asText(row['tracking_status']),
          updatedAt: row['updated_at'],
          isOfflineHistory: true,
          sourceLabel: 'Last synced',
          latLng: LatLng(lat, lng),
        ),
      );
    }

    result.sort((a, b) {
      final aAt =
          _asDateTime(a.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt =
          _asDateTime(b.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });
    return result;
  }

  List<_TechnicianLocation> _extractOfflineHistoryLocations(
    List<Map<String, dynamic>> liveRows,
    List<Map<String, dynamic>> historyRows,
  ) {
    final metadataByKey = <String, Map<String, dynamic>>{};
    for (final row in liveRows) {
      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final compositeKey = _buildCompositeTrackingKey(technicianId, jobId);
      metadataByKey[compositeKey] = row;
      final fallbackKey = _buildTechnicianFallbackKey(technicianId);
      if (fallbackKey != null) {
        metadataByKey.putIfAbsent(fallbackKey, () => row);
      }
    }

    final latestHistoryByKey = <String, Map<String, dynamic>>{};
    for (final row in historyRows) {
      final lat = _asDouble(row['latitude']);
      final lng = _asDouble(row['longitude']);
      if (lat == null || lng == null) continue;

      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final compositeKey = _buildCompositeTrackingKey(technicianId, jobId);
      final fallbackKey = _buildTechnicianFallbackKey(technicianId);
      final effectiveKey = metadataByKey.containsKey(compositeKey)
          ? compositeKey
          : fallbackKey ?? compositeKey;
      final currentBest = latestHistoryByKey[effectiveKey];
      final currentAt = _asDateTime(row['captured_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bestAt = currentBest == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : _asDateTime(currentBest['captured_at']) ??
              DateTime.fromMillisecondsSinceEpoch(0);
      if (currentBest == null || currentAt.isAfter(bestAt)) {
        latestHistoryByKey[effectiveKey] = row;
      }
    }

    final result = <_TechnicianLocation>[];
    for (final entry in latestHistoryByKey.entries) {
      final point = entry.value;
      final lat = _asDouble(point['latitude']);
      final lng = _asDouble(point['longitude']);
      if (lat == null || lng == null) continue;

      final metadata = metadataByKey[entry.key] ?? const <String, dynamic>{};
      final technicianId =
          _asInt(point['technician_id']) ?? _asInt(metadata['technician_id']);
      final jobId = _asInt(point['job_id']) ?? _asInt(metadata['job_id']);
      final trackingKey = _buildCompositeTrackingKey(technicianId, jobId);
      final fallbackKey = _buildTechnicianFallbackKey(technicianId);

      result.add(
        _TechnicianLocation(
          markerKey: trackingKey,
          trackingKey: trackingKey,
          technicianFallbackKey: fallbackKey,
          technicianId: technicianId,
          jobId: jobId,
          technicianName: _asText(
            metadata['technician_name'],
            fallback: widget.technicianNameHint ?? 'Technician',
          ),
          jobTitle: _asText(
            metadata['job_title'],
            fallback: widget.jobTitleHint ?? 'Job $jobId',
          ),
          jobStatus: _asText(metadata['status'], fallback: 'Offline history'),
          trackingStatus:
              _asText(metadata['tracking_status'], fallback: 'Offline history'),
          updatedAt: point['captured_at'] ?? metadata['updated_at'],
          isOfflineHistory: true,
          sourceLabel: 'Offline history',
          latLng: LatLng(lat, lng),
        ),
      );
    }

    result.sort((a, b) {
      final aAt = _asDateTime(a.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = _asDateTime(b.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });
    return result;
  }

  bool _isSyntheticHistoryPoint(Map<String, dynamic> row) {
    final source = row['source']?.toString().trim().toLowerCase();
    return source == 'live_snapshot';
  }

  List<Map<String, dynamic>> _restrictHistoryToLiveSession(
    List<Map<String, dynamic>> points,
    _TechnicianLocation location,
  ) {
    final anchorUpdatedAt = _asDateTime(location.updatedAt)?.toLocal();
    if (anchorUpdatedAt == null) return points;

    final earliest = anchorUpdatedAt.subtract(const Duration(minutes: 25));
    final latest = anchorUpdatedAt.add(const Duration(minutes: 2));
    return points.where((point) {
      final capturedAt = _asDateTime(point['captured_at'])?.toLocal();
      if (capturedAt == null) return false;
      return !capturedAt.isBefore(earliest) && !capturedAt.isAfter(latest);
    }).toList(growable: false);
  }

  List<Polyline> _buildHistoryPolylines(
    List<Map<String, dynamic>> historyRows,
    List<_TechnicianLocation> activeLocations,
    bool allowTechnicianFallback, {
    required bool strictLiveSession,
  }) {
    if (historyRows.isEmpty || activeLocations.isEmpty) {
      return const <Polyline>[];
    }

    final activeLocationsByKey = <String, _TechnicianLocation>{};
    for (final location in activeLocations) {
      activeLocationsByKey[location.trackingKey] = location;
      final fallback = location.technicianFallbackKey;
      if (fallback != null) {
        activeLocationsByKey.putIfAbsent(fallback, () => location);
      }
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in historyRows) {
      if (strictLiveSession && _isSyntheticHistoryPoint(row)) {
        continue;
      }
      final lat = _asDouble(row['latitude']);
      final lng = _asDouble(row['longitude']);
      if (lat == null || lng == null) continue;

      final technicianId = _asInt(row['technician_id']);
      final jobId = _asInt(row['job_id']);
      final compositeKey = _buildCompositeTrackingKey(technicianId, jobId);
      String? matchedKey = activeLocationsByKey.containsKey(compositeKey)
          ? compositeKey
          : null;
      if (matchedKey == null && allowTechnicianFallback) {
        final fallbackKey = _buildTechnicianFallbackKey(technicianId);
        if (fallbackKey != null && activeLocationsByKey.containsKey(fallbackKey)) {
          matchedKey = fallbackKey;
        }
      }
      if (matchedKey == null) continue;
      grouped.putIfAbsent(matchedKey, () => <Map<String, dynamic>>[]).add(row);
    }

    final polylines = <Polyline>[];
    for (final entry in grouped.entries) {
      final location = activeLocationsByKey[entry.key];
      if (location == null) continue;
      final scopedPoints = strictLiveSession
          ? _restrictHistoryToLiveSession(entry.value, location)
          : entry.value;
      final points = _trimRouteHistory(
        scopedPoints,
        maxAge: allowTechnicianFallback
            ? const Duration(hours: 12)
            : const Duration(minutes: 25),
        maxPoints: allowTechnicianFallback ? 120 : 60,
      );
      points.sort((a, b) {
        final aAt = _asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = _asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

final coords = _cleanAndSimplifyPath(points);

if (coords.length < 2) continue;

final colorKey = _primaryTrackingKeyForLocation(location);
final routeColor = _colorForTrackingKey(colorKey);

polylines.add(
  Polyline(
    points: coords,
    strokeWidth: 4,
    color: routeColor.withValues(alpha: 0.72),
  ),
);
    }

    return polylines;
  }

List<LatLng> _cleanAndSimplifyPath(List<Map<String, dynamic>> points) {
  final cleaned = <LatLng>[];

  LatLng? previous;

  for (final point in points) {
    final lat = _asDouble(point['latitude']);
    final lng = _asDouble(point['longitude']);

    if (lat == null || lng == null) continue;

    final current = LatLng(lat, lng);

    /// First point always added
    if (previous == null) {
      cleaned.add(current);
      previous = current;
      continue;
    }

    final distance = _distanceMeters(previous, current);

    /// ✅ Only allow movement > 5 meters
if (distance >= 5 && distance <= 100) {
  cleaned.add(current);
  previous = current;
}
  }

  return cleaned;
}

  List<Map<String, dynamic>> _trimRouteHistory(
    List<Map<String, dynamic>> points, {
    required Duration maxAge,
    required int maxPoints,
  }) {
    if (points.isEmpty) return const <Map<String, dynamic>>[];

    final sorted = points.toList(growable: false)
      ..sort((a, b) {
        final aAt = _asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = _asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

    final latestAt = _asDateTime(sorted.last['captured_at']);
    if (latestAt == null) {
      return sorted.length <= maxPoints
          ? sorted
          : sorted.sublist(sorted.length - maxPoints);
    }

    final threshold = latestAt.subtract(maxAge);
    final recent = sorted.where((point) {
      final capturedAt = _asDateTime(point['captured_at']);
      return capturedAt == null || !capturedAt.isBefore(threshold);
    }).toList(growable: false);

    if (recent.length <= maxPoints) return recent;
    return recent.sublist(recent.length - maxPoints);
  }

  _RouteMetrics? _summarizeRoute(
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
      if (previous != null) {
        totalDistance += _distanceMeters(previous, point);
      }
      route.add(point);
      previous = point;
    }

    if (route.isEmpty) return null;
    final lastPoint = route.last;
    final distToAnchor = _distanceMeters(lastPoint, anchor);
    // Only stitch the current pin to the trail when the final hop is plausible.
    if (distToAnchor > 5 && distToAnchor <= 150) {
      route.add(anchor);
      totalDistance += distToAnchor;
    }

    if (route.length < minimumPointCount ||
        totalDistance < minimumDistanceMeters) {
      return null;
    }

    return _RouteMetrics(points: route);
  }

  List<LatLng> _downsamplePath(List<LatLng> points, {required int maxPoints}) {
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

  _TechnicianLocation? _findLocationByMarkerKey(
    List<_TechnicianLocation> locations,
    String markerKey,
  ) {
    for (final location in locations) {
      if (location.markerKey == markerKey) return location;
    }
    return null;
  }

  List<Marker> _buildMarkers(List<_TechnicianLocation> locations) {
    return locations
        .map(
          (location) {
            final color = _colorForTrackingKey(
              _primaryTrackingKeyForLocation(location),
            );
            final isSelected = _selectedLocation?.markerKey == location.markerKey;
            return Marker(
              key: ValueKey(location.markerKey),
              point: location.latLng,
              width: 72,
              height: 76,
              child: GestureDetector(
                onTap: () => setState(() => _selectedLocation = location),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: isSelected ? 38 : 34,
                      height: isSelected ? 38 : 34,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.6),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 12,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _markerLabel(location),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Container(
                      width: 14,
                      height: 20,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(14),
                        ),
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        )
        .toList(growable: false);
  }

  void _fitCamera(
    List<_TechnicianLocation> locations, {
    bool force = false,
  }) {
    if (!_mapReady || locations.isEmpty) return;
    if (_cameraFramed && !force) return;

    if (locations.length == 1) {
      _mapController.move(locations.first.latLng, 15);
    } else {
      final coordinates =
          locations.map((location) => location.latLng).toList(growable: false);
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: coordinates,
          padding: const EdgeInsets.all(56),
          maxZoom: 16,
        ),
      );
    }

    _cameraFramed = true;
  }

  @override
  Widget build(BuildContext context) {
    final liveTrackingAsync = ref.watch(adminTechnicianLiveProvider);
    final historyAsync = ref.watch(adminTechnicianHistoryProvider);
    final providerLiveRows = liveTrackingAsync.valueOrNull;
    final liveRows =
        providerLiveRows ?? widget.seedRows ?? const <Map<String, dynamic>>[];
    final historyRows = historyAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    if (liveTrackingAsync.isLoading && liveRows.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.offlineHistoryOnly && widget.jobIdFilter != null
                ? 'Offline History - Job ${widget.jobIdFilter}'
                : widget.liveOnly
                    ? 'Live Technician Map'
                    : 'Technician Locations',
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (liveTrackingAsync.hasError && liveRows.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.offlineHistoryOnly && widget.jobIdFilter != null
                ? 'Offline History - Job ${widget.jobIdFilter}'
                : widget.liveOnly
                    ? 'Live Technician Map'
                    : 'Technician Locations',
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Unable to load technician locations.\n${liveTrackingAsync.error.toString().replaceFirst('Exception: ', '')}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF7C2D12)),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => ref.invalidate(adminTechnicianLiveProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.offlineHistoryOnly && widget.jobIdFilter != null
              ? 'Offline History - Job ${widget.jobIdFilter}'
              : widget.liveOnly
              ? 'Live Technician Map'
              : 'Technician Locations',
        ),
      ),
      body: Builder(
        builder: (context) {
          final scopedLiveRows = _dedupeRowsByTrackingKey(
            liveRows.where((row) {
              final matchesJob = widget.jobIdFilter == null ||
                  _asInt(row['job_id']) == widget.jobIdFilter;
              final matchesTechnician = widget.technicianIdFilter == null ||
                  _asInt(row['technician_id']) == widget.technicianIdFilter;
              return matchesJob && matchesTechnician;
            }).toList(growable: false),
            timestampField: 'updated_at',
          );
          final trackedRows = scopedLiveRows
              .where((row) => TrackingPresence.evaluate(row).shouldAppearInFeed)
              .toList(growable: false);
          final filteredLiveRows = scopedLiveRows
              .where(_isLiveTrackingRow)
              .toList(growable: false);
          final staleTrackedRows = trackedRows
              .where((row) => !TrackingPresence.evaluate(row).isLive)
              .toList(growable: false);
          final filteredHistoryRows = historyRows.where((row) {
            final matchesJob = widget.jobIdFilter == null ||
                _asInt(row['job_id']) == widget.jobIdFilter;
            final matchesTechnician = widget.technicianIdFilter == null ||
                _asInt(row['technician_id']) == widget.technicianIdFilter;
            return matchesJob && matchesTechnician;
          }).toList(growable: false);
          if (widget.offlineHistoryOnly &&
              historyAsync.isLoading &&
              historyAsync.valueOrNull == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final canFallbackFromLive = !widget.liveOnly;
          final showHistoryFallback =
              canFallbackFromLive &&
              filteredLiveRows.isEmpty &&
              filteredHistoryRows.isNotEmpty;
          final showLastKnownFallback =
              canFallbackFromLive &&
              filteredLiveRows.isEmpty &&
              filteredHistoryRows.isEmpty &&
              staleTrackedRows.isNotEmpty;
          final useOfflineHistory =
              widget.offlineHistoryOnly || showHistoryFallback;
          final locations = useOfflineHistory
              ? _extractOfflineHistoryLocations(scopedLiveRows, filteredHistoryRows)
              : showLastKnownFallback
                  ? _extractLastKnownLocations(staleTrackedRows)
                  : _extractLocations(filteredLiveRows);
          final markers = _buildMarkers(locations);
          final historyPolylines = _buildHistoryPolylines(
            filteredHistoryRows,
            locations,
            useOfflineHistory || showLastKnownFallback,
            strictLiveSession: !(useOfflineHistory || showLastKnownFallback),
          );
          final markerHash = Object.hashAll(
            locations.map(
              (location) => location.markerKey,
            ),
          );

          if (_selectedLocation != null) {
            _selectedLocation = _findLocationByMarkerKey(
              locations,
              _selectedLocation!.markerKey,
            );
          }

          if (markerHash != _lastMarkerHash) {
            _lastMarkerHash = markerHash;
            _cameraFramed = false;
          }

          if (locations.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  widget.liveOnly
                      ? trackedRows.isEmpty
                          ? 'No technician is active now.'
                          : 'No technician is live right now. Waiting for a fresh location update.'
                      : useOfflineHistory && widget.jobIdFilter != null
                      ? 'No offline location history found for Job ID ${widget.jobIdFilter}.'
                      : 'No valid technician coordinates available yet.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            _fitCamera(locations);
          });

          return Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _defaultCenter,
                  initialZoom: 11,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  onTap: (_, __) => setState(() => _selectedLocation = null),
                  onMapReady: () {
                    _mapReady = true;
                    _fitCamera(locations, force: true);
                  },
                ),
                children: [
// ADD THIS ↓
TileLayer(
  urlTemplate: _activeLayer.urlTemplate,
  subdomains: _activeLayer.subdomains ?? const [],
  userAgentPackageName: _userAgentPackageName,
  maxZoom: 20,
  maxNativeZoom: 19,
),
if (_activeLayer.needsLabelOverlay)
  TileLayer(
    urlTemplate:
        'https://server.arcgisonline.com/ArcGIS/rest/services/'
        'Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    userAgentPackageName: _userAgentPackageName,
    maxZoom: 20,
    maxNativeZoom: 19,
  ),
                  if (historyPolylines.isNotEmpty)
                    PolylineLayer(polylines: historyPolylines),
                  MarkerLayer(markers: markers),
RichAttributionWidget(
  attributions: [
    TextSourceAttribution(_activeLayer.attribution),
  ],
),
                ],
              ),
              if (_selectedLocation != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 88,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 16,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Builder(
                        builder: (context) {
                          final selected = _selectedLocation!;
                          final markerColor = _colorForTrackingKey(
                            _primaryTrackingKeyForLocation(selected),
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: markerColor,
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      _markerLabel(selected),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          selected.technicianName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          selected.jobTitle,
                                          style: const TextStyle(
                                            color: Color(0xFF475569),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Close',
                                    onPressed: () =>
                                        setState(() => _selectedLocation = null),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _MapInfoPill(
                                    label:
                                        'Job ${selected.jobId?.toString() ?? '-'}',
                                    color: const Color(0xFF2563EB),
                                  ),
                                  _MapInfoPill(
                                    label: selected.sourceLabel,
                                    color: _sourcePillColor(selected),
                                  ),
                                  _MapInfoPill(
                                    label: _syncPillLabel(
                                      selected.updatedAt,
                                      isOfflineHistory:
                                          selected.isOfflineHistory,
                                    ),
                                    color: _syncPillColor(
                                      selected.updatedAt,
                                      isOfflineHistory:
                                          selected.isOfflineHistory,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              _MapDetailRow(
                                icon: Icons.badge_outlined,
                                label: 'Technician ID',
                                value: selected.technicianId?.toString() ?? '-',
                              ),
                              _MapDetailRow(
                                icon: Icons.work_outline,
                                label: _isArchivedHistory(selected)
                                    ? 'Saved job status'
                                    : 'Job status',
                                value: _titleCase(selected.jobStatus),
                              ),
                              if (_hasDisplayValue(selected.trackingStatus))
                                _MapDetailRow(
                                  icon: Icons.route_outlined,
                                  label: _isArchivedHistory(selected)
                                      ? 'Saved tracking status'
                                      : 'Tracking status',
                                  value: _titleCase(selected.trackingStatus),
                                ),
                              _MapDetailRow(
                                icon: Icons.schedule_outlined,
                                label: 'Last update',
                                value: _timeAgo(selected.updatedAt),
                              ),
                              _MapDetailRow(
                                icon: Icons.pin_drop_outlined,
                                label: 'Coordinates',
                                value:
                                    '${selected.latLng.latitude.toStringAsFixed(5)}, ${selected.latLng.longitude.toStringAsFixed(5)}',
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 14,
                left: 14,
                right: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 16,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.engineering_outlined,
                          color: Color(0xFF2563EB),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.offlineHistoryOnly
                                ? 'Job ${widget.jobIdFilter} offline history'
                                : widget.liveOnly
                                    ? '${locations.length} live technician(s) on map'
                                : useOfflineHistory
                                    ? widget.jobIdFilter == null
                                        ? '${locations.length} technician(s) offline history'
                                        : 'Job ${widget.jobIdFilter} offline history'
                                : showLastKnownFallback
                                    ? '${locations.length} last synced technician(s) on map'
                                : '${locations.length} live technician(s) on map',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: () =>
                              unawaited(_refreshMapData(forceHistory: true)),
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
  top: 80,
  right: 14,
  child: _MapLayerPicker(
    active: _activeLayer,
    onSelected: (layer) => setState(() => _activeLayer = layer),
  ),
),
              Positioned(
                right: 16,
                bottom: 20,
                child: FloatingActionButton(
                  mini: true,
                  onPressed: () => _fitCamera(locations, force: true),
                  child: const Icon(Icons.my_location),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TechnicianLocation {
  const _TechnicianLocation({
    required this.markerKey,
    required this.trackingKey,
    required this.technicianFallbackKey,
    required this.technicianId,
    required this.jobId,
    required this.technicianName,
    required this.jobTitle,
    required this.jobStatus,
    required this.trackingStatus,
    required this.updatedAt,
    required this.isOfflineHistory,
    required this.sourceLabel,
    required this.latLng,
  });

  final String markerKey;
  final String trackingKey;
  final String? technicianFallbackKey;
  final int? technicianId;
  final int? jobId;
  final String technicianName;
  final String jobTitle;
  final String jobStatus;
  final String trackingStatus;
  final dynamic updatedAt;
  final bool isOfflineHistory;
  final String sourceLabel;
  final LatLng latLng;
}

class _RouteMetrics {
  const _RouteMetrics({
    required this.points,
  });

  final List<LatLng> points;
}

class _MapInfoPill extends StatelessWidget {
  const _MapInfoPill({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MapDetailRow extends StatelessWidget {
  const _MapDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF64748B)),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(
              color: Color(0xFF475569),
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Color(0xFF0F172A)),
            ),
          ),
        ],
      ),
    );
  }
}
class _MapLayerPicker extends StatefulWidget {
  const _MapLayerPicker({
    required this.active,
    required this.onSelected,
  });

  final MapLayerType active;
  final ValueChanged<MapLayerType> onSelected;

  @override
  State<_MapLayerPicker> createState() => _MapLayerPickerState();
}

class _MapLayerPickerState extends State<_MapLayerPicker> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Toggle button
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              _expanded ? Icons.close : Icons.layers_outlined,
              color: const Color(0xFF2563EB),
              size: 22,
            ),
          ),
        ),

        if (_expanded) ...[
          const SizedBox(height: 8),
          // Layer options
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: MapLayerType.values.map((layer) {
                final isActive = layer == widget.active;
                return GestureDetector(
                  onTap: () {
                    widget.onSelected(layer);
                    setState(() => _expanded = false);
                  },
                  child: Container(
                    width: 130,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xFF2563EB).withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          layer.icon,
                          size: 18,
                          color: isActive
                              ? const Color(0xFF2563EB)
                              : const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          layer.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isActive
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isActive
                                ? const Color(0xFF2563EB)
                                : const Color(0xFF0F172A),
                          ),
                        ),
                        if (isActive) ...[
                          const Spacer(),
                          const Icon(
                            Icons.check,
                            size: 16,
                            color: Color(0xFF2563EB),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }
}