import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────
// MapLayerType enum (UNCHANGED)
// ─────────────────────────────────────────────
enum MapLayerType {
  standard,
  satellite,
  hybrid,
  terrain,
  dark;

  String get label => switch (this) {
        MapLayerType.standard => 'Standard',
        MapLayerType.satellite => 'Satellite',
        MapLayerType.hybrid => 'Hybrid',
        MapLayerType.terrain => 'Terrain',
        MapLayerType.dark => 'Dark',
      };

  IconData get icon => switch (this) {
        MapLayerType.standard => Icons.map_outlined,
        MapLayerType.satellite => Icons.satellite_alt_outlined,
        MapLayerType.hybrid => Icons.layers_outlined,
        MapLayerType.terrain => Icons.terrain_outlined,
        MapLayerType.dark => Icons.dark_mode_outlined,
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

  List<String> get subdomains => switch (this) {
        // Newly added: return a fresh mutable list because flutter_map may
        // normalize or reorder subdomains internally.
        MapLayerType.dark => <String>['a', 'b', 'c', 'd'],
        _ => <String>[],
      };

  bool get needsLabelOverlay => this == MapLayerType.hybrid;

  String get attribution => switch (this) {
        MapLayerType.standard => 'OpenStreetMap contributors',
        MapLayerType.satellite ||
        MapLayerType.hybrid ||
        MapLayerType.terrain =>
          'Esri, Maxar, Earthstar Geographics',
        MapLayerType.dark => 'CartoDB, OpenStreetMap contributors',
      };
}

// ─────────────────────────────────────────────
// TechnicianLocation (PRODUCTION READY)
// ─────────────────────────────────────────────
@immutable
class TechnicianLocation {
  const TechnicianLocation({
    required this.markerKey,
    required this.trackingKey,
    required this.technicianId,
    required this.jobId,
    required this.technicianName,
    required this.jobTitle,
    required this.jobStatus,
    required this.trackingStatus,
    required this.updatedAt,
    required this.latLng,
    required this.isLive,
    this.technicianFallbackKey,
    this.isOfflineHistory = false,
    this.sourceLabel = '',
    this.speed,
    this.accuracy,
    this.bearing,
  });

  final String markerKey;
  final String trackingKey;

  final int? technicianId;
  final int? jobId;

  final String technicianName;
  final String jobTitle;
  final String jobStatus;
  final String trackingStatus;

  final DateTime updatedAt;

  final LatLng latLng;

  final bool isLive;

  final String? technicianFallbackKey;
  final bool isOfflineHistory;
  final String sourceLabel;

  final double? speed;
  final double? accuracy;
  final double? bearing;

  // ─────────────────────────────────────────────
  // FACTORY (BACKEND SAFE)
  // ─────────────────────────────────────────────
  factory TechnicianLocation.fromJson(Map<String, dynamic> json) {
    final lat = (json['latitude'] as num?)?.toDouble();
    final lng = (json['longitude'] as num?)?.toDouble();

    if (lat == null || lng == null) {
      throw Exception('Invalid coordinates');
    }
    int? toIntValue(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    DateTime? parseDateValue(dynamic v) {
      if (v == null) return null;
      final text = v.toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text) ??
          DateTime.tryParse(text.replaceFirst(' ', 'T'));
    }

    final techId = toIntValue(json['technician_id']);
    final jobId = toIntValue(json['job_id']);

    return TechnicianLocation(
      markerKey: 'tech:$techId|job:$jobId',
      trackingKey: 'tech:$techId|job:$jobId',
      technicianId: techId,
      jobId: jobId,
      technicianName: json['technician_name'] ?? '',
      jobTitle: json['job_title'] ?? '',
      jobStatus: json['job_status'] ?? '',
      trackingStatus: json['tracking_status'] ?? '',
      updatedAt: parseDateValue(json['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      latLng: LatLng(lat, lng),
      isLive: json['is_live'] == true || json['is_live'] == 1,
      speed: (json['speed'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
    );
  }

  // ─────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────
  double get latitude => latLng.latitude;
  double get longitude => latLng.longitude;

  bool get hasValidSpeed => speed != null && speed! >= 0;
  bool get isHighAccuracy => accuracy == null || accuracy! <= 50;

  // ─────────────────────────────────────────────
  // COPY
  // ─────────────────────────────────────────────
  TechnicianLocation copyWith({
    LatLng? latLng,
    double? speed,
    double? accuracy,
    double? bearing,
    DateTime? updatedAt,
  }) {
    return TechnicianLocation(
      markerKey: markerKey,
      trackingKey: trackingKey,
      technicianId: technicianId,
      jobId: jobId,
      technicianName: technicianName,
      jobTitle: jobTitle,
      jobStatus: jobStatus,
      trackingStatus: trackingStatus,
      updatedAt: updatedAt ?? this.updatedAt,
      latLng: latLng ?? this.latLng,
      isLive: isLive,
      technicianFallbackKey: technicianFallbackKey,
      isOfflineHistory: isOfflineHistory,
      sourceLabel: sourceLabel,
      speed: speed ?? this.speed,
      accuracy: accuracy ?? this.accuracy,
      bearing: bearing ?? this.bearing,
    );
  }

  // ─────────────────────────────────────────────
  // EQUALITY (STABLE FOR ANIMATION)
  // ─────────────────────────────────────────────
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is TechnicianLocation &&
            other.markerKey == markerKey &&
            _sameLatLng(other.latLng, latLng) &&
            other.updatedAt == updatedAt);
  }

  bool _sameLatLng(LatLng a, LatLng b) {
    const threshold = 0.00001;
    return (a.latitude - b.latitude).abs() < threshold &&
        (a.longitude - b.longitude).abs() < threshold;
  }

  @override
  int get hashCode =>
      Object.hash(markerKey, latLng.latitude, latLng.longitude, updatedAt);
}

// ─────────────────────────────────────────────
// RouteMetrics (UNCHANGED)
// ─────────────────────────────────────────────
@immutable
class RouteMetrics {
  const RouteMetrics({required this.points});
  final List<LatLng> points;
}
