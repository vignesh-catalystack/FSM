import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:fsm/features/jobs/application/job_controller.dart';
import 'technician_map_logic.dart';
import 'technician_map_models.dart';


class TechnicianLocationsMapScreen extends TechnicianLocationsMapScreenBase {
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

  @override
  final int? jobIdFilter;
  @override
  final int? technicianIdFilter;
  @override
  final bool liveOnly;
  @override
  final bool offlineHistoryOnly;
  @override
  final String? jobTitleHint;
  @override
  final String? technicianNameHint;
  @override
  final List<Map<String, dynamic>>? seedRows;

  @override
  ConsumerState<TechnicianLocationsMapScreen> createState() =>
      _TechnicianLocationsMapScreenState();
}

class _TechnicianLocationsMapScreenState
    extends ConsumerState<TechnicianLocationsMapScreen>
    with TechnicianMapLogic<TechnicianLocationsMapScreen> {
  bool _mapReadyFired = false;

  @override
  void initState() {
    super.initState();
    initLogic();
  }

  @override
  void dispose() {
    disposeLogic();
    super.dispose();
  }

  String _appBarTitle() {
    if (widget.offlineHistoryOnly && widget.jobIdFilter != null) {
      return 'Offline History - Job ${widget.jobIdFilter}';
    }
    return widget.liveOnly ? 'Live Technician Map' : 'Technician Locations';
  }

  @override
  Widget build(BuildContext context) {
    final liveAsync = ref.watch(adminTechnicianLiveProvider);

    // ── HISTORY PROVIDER SELECTION ─────────────────────────────────────────
    // When a jobId is given, ALWAYS watch the job-specific history provider.
    // This ensures completed jobs show their route even when offlineHistoryOnly
    // was not explicitly passed from the caller (e.g. job card location icon).
    final bool useJobSpecificHistory =
        widget.offlineHistoryOnly || widget.jobIdFilter != null;

    final historyAsync = useJobSpecificHistory
        ? ref.watch(adminTechnicianHistoryByJobProvider(widget.jobIdFilter))
        : ref.watch(adminTechnicianHistoryProvider);

    final lastAsync = ref.watch(adminTechnicianLastProvider);

    final liveRows = liveAsync.valueOrNull ??
        widget.seedRows ??
        const <Map<String, dynamic>>[];
    final historyRows =
        historyAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final lastRows =
        (lastAsync.valueOrNull ?? const <Map<String, dynamic>>[]).where((row) {
      final jobId = asInt(row['job_id']);
      final techId = asInt(row['technician_id']);
      if (widget.jobIdFilter != null && jobId != widget.jobIdFilter) {
        return false;
      }
      if (widget.technicianIdFilter != null &&
          techId != widget.technicianIdFilter) {
        return false;
      }
      return true;
    }).toList(growable: true);

    // ── LOADING / ERROR GUARDS ────────────────────────────────────────────────
    if (widget.offlineHistoryOnly) {
      if (historyAsync.isLoading && historyRows.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(_appBarTitle())),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (historyAsync.hasError && historyRows.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(_appBarTitle())),
          body: Center(
            child: Text(
              'Failed to load tracking history.\n${historyAsync.error}',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
    } else {
      if (liveAsync.isLoading && liveRows.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(_appBarTitle())),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (liveAsync.hasError && liveRows.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(_appBarTitle())),
          body: Center(
            child: Text(
              'Unable to load technician locations.\n'
              '${liveAsync.error.toString().replaceFirst('Exception: ', '')}',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle())),
      body: Builder(
        builder: (context) {
          // ── Still waiting for offline history ──────────────────────────────
          if (widget.offlineHistoryOnly &&
              historyAsync.isLoading &&
              historyAsync.valueOrNull == null) {
            return const Center(child: CircularProgressIndicator());
          }

          // ── Dedupe and filter live rows ────────────────────────────────────
          final scopedLiveRows = dedupeRowsByTrackingKey(
            liveRows.where(matchesFilters).toList(growable: true),
            timestampField: 'updated_at',
          );

          final filteredHistoryRows =
              historyRows.where(matchesFilters).toList(growable: true);

          final liveNowRows =
              scopedLiveRows.where(rowIsLive).toList(growable: true);

          final canFallback = !widget.liveOnly;
          final filteredLiveRows =
              widget.liveOnly ? liveNowRows : scopedLiveRows;

          final showHistoryFallback = canFallback &&
              filteredLiveRows.isEmpty &&
              filteredHistoryRows.isNotEmpty;

          // ── COMPLETED JOB SAFETY NET ───────────────────────────────────────
          // If jobIdFilter is set and live rows exist but none are "live now"
          // (all rows are terminal/completed), force the history fallback.
          // This catches the case where offlineHistoryOnly was not passed
          // explicitly but the job is already done.
          final bool jobHasTerminalLiveRows = widget.jobIdFilter != null &&
              scopedLiveRows.isNotEmpty &&
              liveNowRows.isEmpty;

          final showLastKnownFallback =
              canFallback && liveNowRows.isEmpty && lastRows.isNotEmpty;

          // ─────────────────────────────────────────────────────────────────
          // DETERMINE MODE
          // ─────────────────────────────────────────────────────────────────
          //
          //  LIVE MODE:    job is active, live rows exist with fresh data.
          //                Polyline = buildLiveOnlyPolylines() (in-memory trail).
          //
          //  OFFLINE MODE: job completed OR offlineHistoryOnly flag set OR
          //                no live rows available.
          //                Polyline = buildOfflineHistoryPaths() → buildOfflinePolylines()
          //
          // These two paths NEVER share data sources.
          // ─────────────────────────────────────────────────────────────────

          final bool isLiveMode = !widget.offlineHistoryOnly &&
              liveNowRows.isNotEmpty &&
              !showHistoryFallback &&
              !jobHasTerminalLiveRows;

          final bool useOfflineHistory =
              widget.offlineHistoryOnly ||
              showHistoryFallback ||
              jobHasTerminalLiveRows;

          // ── BUILD LOCATIONS ────────────────────────────────────────────────
          final List<TechnicianLocation> locations = [];

          if (widget.offlineHistoryOnly || useOfflineHistory) {
            // ── OFFLINE HISTORY MODE ─────────────────────────────────────────
            // Show the last-known position from history as the marker.
            // The polyline is drawn from ALL history rows via buildOfflineHistoryPaths.
            if (filteredHistoryRows.isNotEmpty) {
              final sorted = [...filteredHistoryRows]
                ..sort((a, b) {
                  final aAt = asDateTime(a['captured_at']) ?? DateTime(0);
                  final bAt = asDateTime(b['captured_at']) ?? DateTime(0);
                  return aAt.compareTo(bAt);
                });
              final last = sorted.last;
              final lat = asDouble(last['latitude']);
              final lng = asDouble(last['longitude']);
              if (lat != null && lng != null && lat != 0.0 && lng != 0.0) {
                final techId = asInt(last['technician_id']);
                final jobId = asInt(last['job_id']);
                final key = buildCompositeTrackingKey(techId, jobId);
                locations.add(TechnicianLocation(
                  markerKey: key,
                  trackingKey: key,
                  technicianFallbackKey: buildTechnicianFallbackKey(techId),
                  technicianId: techId,
                  jobId: jobId,
                  technicianName:
                      widget.technicianNameHint ?? 'Technician',
                  jobTitle: widget.jobTitleHint ?? 'Job $jobId',
                  jobStatus: 'Completed',
                  trackingStatus: 'Offline',
                  updatedAt:
                      asDateTime(last['captured_at']) ?? DateTime.now(),
                  isLive: false,
                  isOfflineHistory: true,
                  sourceLabel: 'Offline history',
                  latLng: LatLng(lat, lng),
                  speed: asDouble(last['speed']),
                  accuracy: asDouble(last['accuracy']),
                  bearing: readBearing(last),
                ));
              }
            }
          } else if (isLiveMode) {
            // ── LIVE MODE ────────────────────────────────────────────────────
            // Markers come from live rows only.
            locations.addAll(extractLocations(filteredLiveRows));
          } else if (showLastKnownFallback) {
            // ── LAST KNOWN FALLBACK ──────────────────────────────────────────
            // No live data at all — show the most recent synced position.
            locations.addAll(extractLastKnownLocations(lastRows));
          }

          // ─────────────────────────────────────────────────────────────────
          // BUILD POLYLINES
          //
          // KEY RULE:
          //   isLiveMode  → buildLiveOnlyPolylines(locations)
          //                 — pure in-memory trail, NO history DB rows
          //   otherwise   → buildOfflineHistoryPaths(historyRows) → buildOfflinePolylines()
          //                 — pure DB rows, NO live trail
          //
          // The two paths NEVER overlap.
          // ─────────────────────────────────────────────────────────────────

          List<List<LatLng>> routePaths = [];
          List<Polyline> polylines = [];

          if (isLiveMode) {
            // ── LIVE: pure in-memory trail ───────────────────────────────────
            polylines = buildLiveOnlyPolylines(locations);
          } else if (useOfflineHistory && filteredHistoryRows.isNotEmpty) {
            // ── OFFLINE: pure DB rows ────────────────────────────────────────
            routePaths = buildOfflineHistoryPaths(filteredHistoryRows);
            polylines = buildOfflinePolylines(routePaths);
          }

          // Endpoint markers (start = green dot, end = red dot) for offline mode.
          final historyEndpointMarkers = useOfflineHistory
              ? buildHistoryEndpointMarkers(routePaths)
              : const <Marker>[];

          final markers = buildMarkers(locations);

          // ── EMPTY STATE ────────────────────────────────────────────────────
          if (locations.isEmpty && routePaths.isEmpty && polylines.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  (widget.offlineHistoryOnly || useOfflineHistory) &&
                          widget.jobIdFilter != null
                      ? 'No offline location history found for Job ${widget.jobIdFilter}.'
                      : widget.liveOnly
                          ? 'No technician is active right now.'
                          : 'No valid technician coordinates available yet.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          // ── CAMERA POSITIONING ─────────────────────────────────────────────
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;

            if (!cameraFramed) {
              if (routePaths.isNotEmpty) {
                final allPoints = <LatLng>[];
                for (final route in routePaths) allPoints.addAll(route);
                if (allPoints.isNotEmpty && mapReady) {
                  mapController.fitCamera(
                    CameraFit.coordinates(
                      coordinates: allPoints,
                      padding: const EdgeInsets.all(56),
                    ),
                  );
                  cameraFramed = true;
                }
              } else if (locations.isNotEmpty) {
                fitCamera(locations);
              }
            } else if (useOfflineHistory &&
                routePaths.isNotEmpty &&
                mapReady) {
              final allPoints = <LatLng>[];
              for (final route in routePaths) allPoints.addAll(route);
              if (allPoints.isNotEmpty) {
                mapController.fitCamera(
                  CameraFit.coordinates(
                    coordinates: allPoints,
                    padding: const EdgeInsets.all(56),
                  ),
                );
              }
            } else if (isLiveMode && locations.isNotEmpty) {
              followLiveCamera(locations);
            }
          });

          return Stack(
            children: [
              FlutterMap(
                mapController: mapController,
                options: MapOptions(
                  initialCenter: TechnicianMapLogic.defaultCenter,
                  initialZoom: 17,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  onTap: (_, __) => setState(() => selectedLocation = null),
                  onMapReady: () {
                    if (_mapReadyFired) return;
                    _mapReadyFired = true;
                    mapReady = true;

                    if (routePaths.isNotEmpty) {
                      final allPoints = <LatLng>[];
                      for (final route in routePaths) {
                        allPoints.addAll(route);
                      }
                      if (allPoints.isNotEmpty) {
                        mapController.fitCamera(
                          CameraFit.coordinates(
                            coordinates: allPoints,
                            padding: const EdgeInsets.all(56),
                          ),
                        );
                        cameraFramed = true;
                      }
                    } else if (locations.isNotEmpty) {
                      fitCamera(locations, force: true);
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: activeLayer.urlTemplate,
                    subdomains: List<String>.of(activeLayer.subdomains),
                    userAgentPackageName:
                        TechnicianMapLogic.userAgentPackageName,
                    maxZoom: 20,
                    maxNativeZoom: 19,
                  ),
                  if (activeLayer.needsLabelOverlay)
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/'
                          'Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName:
                          TechnicianMapLogic.userAgentPackageName,
                      maxZoom: 20,
                      maxNativeZoom: 19,
                    ),

                  if (polylines.isNotEmpty)
                    RepaintBoundary(
                      child: PolylineLayer(polylines: polylines),
                    ),

                  if (historyEndpointMarkers.isNotEmpty)
                    MarkerLayer(markers: historyEndpointMarkers),

                  if (markers.isNotEmpty)
                    RepaintBoundary(
                      child: MarkerLayer(markers: markers),
                    ),

                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(activeLayer.attribution),
                    ],
                  ),
                ],
              ),

              // ── SELECTED LOCATION CARD ────────────────────────────────────
              if (selectedLocation != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 88,
                  child: _SelectedLocationCard(
                    location: selectedLocation!,
                    markerLabel: markerLabel(selectedLocation!),
                    markerColor: colorForTrackingKey(
                      primaryTrackingKeyForLocation(selectedLocation!),
                    ),
                    timeAgoLabel: timeAgo(selectedLocation!.updatedAt),
                    syncPillLabel: syncPillLabel(
                      selectedLocation!.updatedAt,
                      isOfflineHistory: selectedLocation!.isOfflineHistory,
                    ),
                    syncPillColor: syncPillColor(
                      selectedLocation!.updatedAt,
                      isOfflineHistory: selectedLocation!.isOfflineHistory,
                    ),
                    sourcePillColor: sourcePillColor(selectedLocation!),
                    isArchivedHistory: isArchivedHistory(selectedLocation!),
                    hasDisplayValue: hasDisplayValue,
                    titleCase: titleCase,
                    onClose: () => setState(() => selectedLocation = null),
                  ),
                ),

              // ── TOP STATUS BAR ────────────────────────────────────────────
              Positioned(
                top: 14,
                left: 14,
                right: 14,
                child: _TopStatusBar(
                  locationCount: isLiveMode
                      ? locations.length
                      : (routePaths.isNotEmpty
                          ? routePaths.length
                          : locations.length),
                  liveOnly: widget.liveOnly,
                  offlineHistoryOnly:
                      widget.offlineHistoryOnly || useOfflineHistory,
                  useOfflineHistory: useOfflineHistory,
                  showLastKnownFallback: showLastKnownFallback,
                  jobIdFilter: widget.jobIdFilter,
                  isLiveMode: isLiveMode,
                  onRefresh: () {
                    if (widget.offlineHistoryOnly || useOfflineHistory) {
                      ref.invalidate(
                        adminTechnicianHistoryByJobProvider(widget.jobIdFilter),
                      );
                    } else {
                      unawaited(refreshMapData(forceHistory: true));
                    }
                  },
                ),
              ),

              // ── LAYER PICKER ──────────────────────────────────────────────
              Positioned(
                top: 80,
                right: 14,
                child: _MapLayerPicker(
                  active: activeLayer,
                  onSelected: (layer) => setState(() => activeLayer = layer),
                ),
              ),

              // ── ZOOM CONTROLS ─────────────────────────────────────────────
              Positioned(
                right: 16,
                bottom: 88,
                child: _ZoomControls(
                  onZoomIn: () {
                    final z = mapController.camera.zoom;
                    mapController.move(
                      mapController.camera.center,
                      (z + 1).clamp(1.0, 20.0),
                    );
                  },
                  onZoomOut: () {
                    final z = mapController.camera.zoom;
                    mapController.move(
                      mapController.camera.center,
                      (z - 1).clamp(1.0, 20.0),
                    );
                  },
                ),
              ),

              // ── RE-CENTRE FAB ─────────────────────────────────────────────
              Positioned(
                right: 16,
                bottom: 20,
                child: FloatingActionButton(
                  mini: true,
                  tooltip: 'Re-centre map',
                  onPressed: () {
                    if (routePaths.isNotEmpty) {
                      final allPoints = <LatLng>[];
                      for (final route in routePaths) {
                        allPoints.addAll(route);
                      }
                      if (allPoints.isNotEmpty) {
                        mapController.fitCamera(
                          CameraFit.coordinates(
                            coordinates: allPoints,
                            padding: const EdgeInsets.all(56),
                          ),
                        );
                      }
                    } else if (locations.isNotEmpty) {
                      fitCamera(locations, force: true);
                    }
                  },
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

// ════════════════════════════════════════════════════════════
//  ZOOM CONTROLS
// ════════════════════════════════════════════════════════════

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onTap: onZoomIn,
            isTop: true,
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),
          _ZoomButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onTap: onZoomOut,
            isTop: false,
          ),
        ],
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.isTop,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isTop;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.vertical(
          top: isTop ? const Radius.circular(12) : Radius.zero,
          bottom: isTop ? Radius.zero : const Radius.circular(12),
        ),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: const Color(0xFF0F172A)),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SELECTED LOCATION CARD
// ════════════════════════════════════════════════════════════

class _SelectedLocationCard extends StatelessWidget {
  const _SelectedLocationCard({
    required this.location,
    required this.markerLabel,
    required this.markerColor,
    required this.timeAgoLabel,
    required this.syncPillLabel,
    required this.syncPillColor,
    required this.sourcePillColor,
    required this.isArchivedHistory,
    required this.hasDisplayValue,
    required this.titleCase,
    required this.onClose,
  });

  final TechnicianLocation location;
  final String markerLabel;
  final Color markerColor;
  final String timeAgoLabel;
  final String syncPillLabel;
  final Color syncPillColor;
  final Color sourcePillColor;
  final bool isArchivedHistory;
  final bool Function(String?) hasDisplayValue;
  final String Function(String) titleCase;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: markerColor,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    markerLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        location.technicianName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        location.jobTitle,
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
                  onPressed: onClose,
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
                  label: 'Job ${location.jobId?.toString() ?? '-'}',
                  color: const Color(0xFF2563EB),
                ),
                _MapInfoPill(
                  label: location.sourceLabel,
                  color: sourcePillColor,
                ),
                _MapInfoPill(
                  label: syncPillLabel,
                  color: syncPillColor,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _MapDetailRow(
              icon: Icons.badge_outlined,
              label: 'Technician ID',
              value: location.technicianId?.toString() ?? '-',
            ),
            _MapDetailRow(
              icon: Icons.work_outline,
              label: isArchivedHistory ? 'Saved job status' : 'Job status',
              value: titleCase(location.jobStatus),
            ),
            if (hasDisplayValue(location.trackingStatus))
              _MapDetailRow(
                icon: Icons.route_outlined,
                label: isArchivedHistory
                    ? 'Saved tracking status'
                    : 'Tracking status',
                value: titleCase(location.trackingStatus),
              ),
            _MapDetailRow(
              icon: Icons.schedule_outlined,
              label: 'Last update',
              value: timeAgoLabel,
            ),
            _MapDetailRow(
              icon: Icons.pin_drop_outlined,
              label: 'Coordinates',
              value:
                  '${location.latLng.latitude.toStringAsFixed(5)}, ${location.latLng.longitude.toStringAsFixed(5)}',
            ),
            if (location.accuracy != null)
              _MapDetailRow(
                icon: Icons.gps_fixed_outlined,
                label: 'GPS accuracy',
                value: '±${location.accuracy!.toStringAsFixed(0)} m',
              ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  TOP STATUS BAR
// ════════════════════════════════════════════════════════════

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.locationCount,
    required this.liveOnly,
    required this.offlineHistoryOnly,
    required this.useOfflineHistory,
    required this.showLastKnownFallback,
    required this.jobIdFilter,
    required this.isLiveMode,
    required this.onRefresh,
  });

  final int locationCount;
  final bool liveOnly;
  final bool offlineHistoryOnly;
  final bool useOfflineHistory;
  final bool showLastKnownFallback;
  final int? jobIdFilter;
  final bool isLiveMode;
  final VoidCallback onRefresh;

  String _label() {
    if (offlineHistoryOnly) return 'Job $jobIdFilter — offline history';
    if (liveOnly) return '$locationCount live technician(s) on map';
    if (useOfflineHistory) {
      return jobIdFilter == null
          ? '$locationCount technician(s) — offline history'
          : 'Job $jobIdFilter — offline history';
    }
    if (showLastKnownFallback) {
      return '$locationCount last-synced technician(s) on map';
    }
    return '$locationCount live technician(s) on map';
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = isLiveMode
        ? const Color(0xFF16A34A)
        : useOfflineHistory
            ? const Color(0xFF64748B)
            : const Color(0xFFB45309);

    return DecoratedBox(
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const Icon(
              Icons.engineering_outlined,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _label(),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  MAP LAYER PICKER
// ════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════
//  SHARED SMALL WIDGETS
// ════════════════════════════════════════════════════════════

class _MapInfoPill extends StatelessWidget {
  const _MapInfoPill({required this.label, required this.color});

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