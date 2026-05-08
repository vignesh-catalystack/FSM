import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:fsm/features/jobs/application/job_controller.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';
import 'technician_map_models.dart';

// ─────────────────────────────────────────────
// Abstract widget base
// The mixin constraint (W extends …Base) lets the
// mixin access widget properties such as jobIdFilter.
// ─────────────────────────────────────────────
abstract class TechnicianLocationsMapScreenBase
    extends ConsumerStatefulWidget {
  const TechnicianLocationsMapScreenBase({super.key});

  int? get jobIdFilter;
  int? get technicianIdFilter;
  bool get liveOnly;
  bool get offlineHistoryOnly;
  String? get jobTitleHint;
  String? get technicianNameHint;
  List<Map<String, dynamic>>? get seedRows;
}

// ─────────────────────────────────────────────
// Mixin: TechnicianMapLogic
// ─────────────────────────────────────────────
mixin TechnicianMapLogic<W extends TechnicianLocationsMapScreenBase>
    on ConsumerState<W> {
  // ── constants ─────────────────────────────────────────────────────────────
  static const Duration liveRefreshInterval = Duration(seconds: 8);
  static const Duration historyRefreshInterval = Duration(seconds: 32);
  static const LatLng defaultCenter = LatLng(12.9716, 77.5946); // Bengaluru
  static const String userAgentPackageName = 'com.example.fsm';

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

  // ── mutable state owned by the mixin ─────────────────────────────────────
  final MapController mapController = MapController();
  Timer? refreshTimer;
  TechnicianLocation? selectedLocation;
  bool cameraFramed = false;
  bool mapReady = false;
  int lastMarkerHash = 0;
  int refreshTick = 0;
  bool refreshInProgress = false;
  MapLayerType activeLayer = MapLayerType.standard;

  // ── lifecycle helpers ─────────────────────────────────────────────────────
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

  // ── primitive coercers ────────────────────────────────────────────────────

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

  // ── display helpers ───────────────────────────────────────────────────────

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
    return isOfflineHistory
        ? const Color(0xFF64748B)
        : const Color(0xFFB45309);
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

  // ── refresh logic ─────────────────────────────────────────────────────────

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

  // ── tracking-key helpers ──────────────────────────────────────────────────

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
        .where((p) => p.trim().isNotEmpty)
        .toList(growable: false);
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

  // ── deduplication ─────────────────────────────────────────────────────────

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

    final deduped = latestByKey.values.toList(growable: false)
      ..sort((a, b) {
        final aAt = asDateTime(a[timestampField]) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b[timestampField]) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bAt.compareTo(aAt);
      });

    return deduped;
  }

  // ── location extraction ───────────────────────────────────────────────────

  /// Builds [TechnicianLocation] list from the live-tracking rows.
  List<TechnicianLocation> extractLocations(
      List<Map<String, dynamic>> rows) {
    final result = <TechnicianLocation>[];

    for (final row in rows) {
      final lat = asDouble(row['latitude']);
      final lng = asDouble(row['longitude']);
      if (lat == null || lng == null) continue;
      // Discard (0, 0) sentinel coordinates
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
        technicianName:
            asText(row['technician_name'], fallback: 'Technician'),
        jobTitle:
            asText(row['job_title'], fallback: 'No job assigned'),
        jobStatus: asText(row['status']),
        trackingStatus: asText(row['tracking_status']),
        updatedAt: row['updated_at'],
        isOfflineHistory: false,
        sourceLabel: 'Live now',
        latLng: LatLng(lat, lng),
      ));
    }

    return result;
  }

  /// Picks the single most-recent row per composite key from [rows] and
  /// returns them as "Last synced" locations (used when live data is absent).
  List<TechnicianLocation> extractLastKnownLocations(
      List<Map<String, dynamic>> rows) {
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
        technicianName:
            asText(row['technician_name'], fallback: 'Technician'),
        jobTitle:
            asText(row['job_title'], fallback: 'No job assigned'),
        jobStatus: asText(row['status']),
        trackingStatus: asText(row['tracking_status']),
        updatedAt: row['updated_at'],
        isOfflineHistory: true,
        sourceLabel: 'Last synced',
        latLng: LatLng(lat, lng),
      ));
    }

    result.sort((a, b) {
      final aAt = asDateTime(a.updatedAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = asDateTime(b.updatedAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });

    return result;
  }

  /// Merges offline [historyRows] with metadata from [liveRows] to produce
  /// "Offline history" pins — one per composite key, most-recent point wins.
  List<TechnicianLocation> extractOfflineHistoryLocations(
    List<Map<String, dynamic>> liveRows,
    List<Map<String, dynamic>> historyRows,
  ) {
    // Build a metadata lookup from live rows (name, job title, status …)
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

    // Pick the newest history point per effective key
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

      // Prefer composite key; fall back to technician-only key
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

      final metadata =
          metadataByKey[entry.key] ?? const <String, dynamic>{};
      final technicianId =
          asInt(point['technician_id']) ?? asInt(metadata['technician_id']);
      final jobId =
          asInt(point['job_id']) ?? asInt(metadata['job_id']);
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
        jobStatus:
            asText(metadata['status'], fallback: 'Offline history'),
        trackingStatus: asText(metadata['tracking_status'],
            fallback: 'Offline history'),
        updatedAt: point['captured_at'] ?? metadata['updated_at'],
        isOfflineHistory: true,
        sourceLabel: 'Offline history',
        latLng: LatLng(lat, lng),
      ));
    }

    result.sort((a, b) {
      final aAt = asDateTime(a.updatedAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = asDateTime(b.updatedAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });

    return result;
  }

  // ── history / polyline helpers ────────────────────────────────────────────

  bool isSyntheticHistoryPoint(Map<String, dynamic> row) {
    final source = row['source']?.toString().trim().toLowerCase();
    return source == 'live_snapshot';
  }

  List<Map<String, dynamic>> restrictHistoryToLiveSession(
    List<Map<String, dynamic>> points,
    TechnicianLocation location,
  ) {
    final anchorAt = asDateTime(location.updatedAt)?.toLocal();
    if (anchorAt == null) return points;

    final earliest = anchorAt.subtract(const Duration(minutes: 25));
    final latest = anchorAt.add(const Duration(minutes: 2));

    return points.where((point) {
      final capturedAt = asDateTime(point['captured_at'])?.toLocal();
      if (capturedAt == null) return false;
      return !capturedAt.isBefore(earliest) && !capturedAt.isAfter(latest);
    }).toList(growable: false);
  }

  List<Polyline> buildHistoryPolylines(
    List<Map<String, dynamic>> historyRows,
    List<TechnicianLocation> activeLocations,
    bool allowTechnicianFallback, {
    required bool strictLiveSession,
  }) {
    if (historyRows.isEmpty || activeLocations.isEmpty) {
      return const <Polyline>[];
    }

    // Build a fast lookup from key → location
    final byKey = <String, TechnicianLocation>{};
    for (final loc in activeLocations) {
      byKey[loc.trackingKey] = loc;
      final fb = loc.technicianFallbackKey;
      if (fb != null) byKey.putIfAbsent(fb, () => loc);
    }

    // Group history points by matched location key
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

      String? matchedKey = byKey.containsKey(compositeKey) ? compositeKey : null;
      if (matchedKey == null && allowTechnicianFallback) {
        final fb = buildTechnicianFallbackKey(technicianId);
        if (fb != null && byKey.containsKey(fb)) matchedKey = fb;
      }
      if (matchedKey == null) continue;

      grouped.putIfAbsent(matchedKey, () => []).add(row);
    }

    final polylines = <Polyline>[];
    for (final entry in grouped.entries) {
      final location = byKey[entry.key];
      if (location == null) continue;

      final scopedPoints = strictLiveSession
          ? restrictHistoryToLiveSession(entry.value, location)
          : entry.value;

      final trimmed = trimRouteHistory(
        scopedPoints,
        maxAge: allowTechnicianFallback
            ? const Duration(hours: 12)
            : const Duration(minutes: 25),
        maxPoints: allowTechnicianFallback ? 120 : 60,
      );

      trimmed.sort((a, b) {
        final aAt = asDateTime(a['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bAt = asDateTime(b['captured_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return aAt.compareTo(bAt);
      });

      final coords = cleanAndSimplifyPath(trimmed);
      if (coords.length < 2) continue;

      final colorKey = primaryTrackingKeyForLocation(location);
      polylines.add(Polyline(
        points: coords,
        strokeWidth: 4,
        color: colorForTrackingKey(colorKey).withValues(alpha: 0.72),
      ));
    }

    return polylines;
  }

  /// Removes GPS jitter and GPS-off-to-on jumps.
  ///
  /// * < 5 m  → stationary noise, skip.
  /// * > 500 m → implausible jump (GPS re-acquire, tunnel exit, etc.), skip.
  ///   Raise this threshold if technicians travel by vehicle on highways.
  List<LatLng> cleanAndSimplifyPath(List<Map<String, dynamic>> points) {
    final cleaned = <LatLng>[];
    LatLng? previous;
    Map<String, dynamic>? previousPoint;

    for (final point in points) {
      final lat = asDouble(point['latitude']);
      final lng = asDouble(point['longitude']);
      if (lat == null || lng == null) continue;
      if (lat == 0.0 && lng == 0.0) continue;

      final current = LatLng(lat, lng);

      if (previous == null) {
        cleaned.add(current);
        previous = current;
        previousPoint = point;
        continue;
      }

      final d = distanceMeters(previous, current);
      final previousAt = asDateTime(previousPoint?['captured_at']);
      final currentAt = asDateTime(point['captured_at']);
      final elapsedSeconds = previousAt != null && currentAt != null
          ? currentAt.difference(previousAt).inSeconds.abs()
          : 0;
      final maxReasonableDistance =
          (elapsedSeconds * 55.0 + 100).clamp(500.0, 5000.0);
      // Keep points that represent genuine movement (≥5 m) but discard
      // implausible teleports while allowing longer offline/time-gap jumps.
      if (d >= 5 && d <= maxReasonableDistance) {
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
    if (points.isEmpty) return const [];

    final sorted = points.toList(growable: false)
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
    final recent = sorted.where((p) {
      final capturedAt = asDateTime(p['captured_at']);
      return capturedAt == null || !capturedAt.isBefore(threshold);
    }).toList(growable: false);

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

    final distToAnchor = distanceMeters(route.last, anchor);
    if (distToAnchor > 5 && distToAnchor <= 150) {
      route.add(anchor);
      totalDistance += distToAnchor;
    }

    if (route.length < minimumPointCount ||
        totalDistance < minimumDistanceMeters) {
      return null;
    }

    return RouteMetrics(points: route);
  }

  List<LatLng> downsamplePath(List<LatLng> points,
      {required int maxPoints}) {
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

  // ── marker helpers ────────────────────────────────────────────────────────

  TechnicianLocation? findLocationByMarkerKey(
    List<TechnicianLocation> locations,
    String markerKey,
  ) {
    for (final loc in locations) {
      if (loc.markerKey == markerKey) return loc;
    }
    return null;
  }

  List<Marker> buildMarkers(List<TechnicianLocation> locations) {
    return locations.map((location) {
      final color =
          colorForTrackingKey(primaryTrackingKeyForLocation(location));
      final isSelected =
          selectedLocation?.markerKey == location.markerKey;
      final size = isSelected ? 38.0 : 34.0;

      return Marker(
        key: ValueKey(location.markerKey),
        point: location.latLng,
        width: 72,
        height: 76,
        child: GestureDetector(
          onTap: () => setState(() => selectedLocation = location),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Circle avatar
              Container(
                width: size,
                height: size,
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
                  markerLabel(location),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // Teardrop stem
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
              // Tip dot
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
    }).toList();
  }

  // ── camera ────────────────────────────────────────────────────────────────

  void fitCamera(List<TechnicianLocation> locations, {bool force = false}) {
    if (!mapReady || locations.isEmpty) return;
    if (cameraFramed && !force) return;

    if (locations.length == 1) {
      mapController.move(locations.first.latLng, 15);
    } else {
      mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: locations.map((l) => l.latLng).toList(),
          padding: const EdgeInsets.all(56),
          maxZoom: 16,
        ),
      );
    }

    cameraFramed = true;
  }
}
