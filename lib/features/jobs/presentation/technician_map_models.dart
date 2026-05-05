import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────
// MapLayerType enum
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
        // Hybrid uses the same satellite imagery base; label overlay is added separately
        MapLayerType.hybrid =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Imagery/MapServer/tile/{z}/{y}/{x}',
        MapLayerType.terrain =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/'
              'World_Topo_Map/MapServer/tile/{z}/{y}/{x}',
        MapLayerType.dark =>
          'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
      };

  /// Only the dark CartoDB layer uses subdomains.
  List<String>? get subdomains => switch (this) {
        MapLayerType.dark => ['a', 'b', 'c', 'd'],
        _ => null,
      };

  /// Whether a road/label overlay tile layer should be rendered on top.
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
// TechnicianLocation  (immutable data class)
// ─────────────────────────────────────────────
class TechnicianLocation {
  const TechnicianLocation({
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

  /// Unique key used to identify a marker widget (same as [trackingKey]).
  final String markerKey;

  /// Composite key: `tech:<id>|job:<id>`.
  final String trackingKey;

  /// Fallback key when only the technician ID is known: `tech:<id>`.
  final String? technicianFallbackKey;

  final int? technicianId;
  final int? jobId;
  final String technicianName;
  final String jobTitle;
  final String jobStatus;
  final String trackingStatus;

  /// Raw `updated_at` / `captured_at` value from the DB row (String or null).
  final dynamic updatedAt;

  final bool isOfflineHistory;

  /// Human-readable source label shown in the info card pill.
  /// One of: `'Live now'`, `'Last synced'`, `'Offline history'`.
  final String sourceLabel;

  final LatLng latLng;
}

// ─────────────────────────────────────────────
// RouteMetrics  (lightweight value object)
// ─────────────────────────────────────────────
class RouteMetrics {
  const RouteMetrics({required this.points});

  final List<LatLng> points;
}