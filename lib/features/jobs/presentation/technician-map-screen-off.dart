import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'package:fsm/features/jobs/application/job_controller.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';
import 'technician_map_logic.dart';
import 'technician_map_models.dart';

// ─────────────────────────────────────────────
// Screen widget
// ─────────────────────────────────────────────
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

// ─────────────────────────────────────────────
// State — lifecycle + build only;
// all business logic lives in TechnicianMapLogic.
// ─────────────────────────────────────────────
class _TechnicianLocationsMapScreenState
    extends ConsumerState<TechnicianLocationsMapScreen>
    with TechnicianMapLogic<TechnicianLocationsMapScreen> {
  // ── lifecycle ─────────────────────────────────────────────────────────────

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

  // ── helpers ───────────────────────────────────────────────────────────────

  String _appBarTitle() {
    if (widget.offlineHistoryOnly && widget.jobIdFilter != null) {
      return 'Offline History – Job ${widget.jobIdFilter}';
    }
    return widget.liveOnly ? 'Live Technician Map' : 'Technician Locations';
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final liveAsync = ref.watch(adminTechnicianLiveProvider);
    final historyAsync = ref.watch(adminTechnicianHistoryProvider);

    final liveRows =
        liveAsync.valueOrNull ?? widget.seedRows ?? const <Map<String, dynamic>>[];
    final historyRows =
        historyAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    // ── loading ──────────────────────────────────────────────────────────────
    if (liveAsync.isLoading && liveRows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(_appBarTitle())),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // ── error ────────────────────────────────────────────────────────────────
    if (liveAsync.hasError && liveRows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(_appBarTitle())),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Unable to load technician locations.\n'
                  '${liveAsync.error.toString().replaceFirst('Exception: ', '')}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF7C2D12)),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () =>
                      ref.invalidate(adminTechnicianLiveProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ── main scaffold ─────────────────────────────────────────────────────────
    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle())),
      body: Builder(builder: (context) {
        // ── 1. Filter rows by the optional job / technician selectors ─────────
        bool matchesFilters(Map<String, dynamic> row) {
          final matchesJob = widget.jobIdFilter == null ||
              asInt(row['job_id']) == widget.jobIdFilter;
          final matchesTech = widget.technicianIdFilter == null ||
              asInt(row['technician_id']) == widget.technicianIdFilter;
          return matchesJob && matchesTech;
        }

        final scopedLiveRows = dedupeRowsByTrackingKey(
          liveRows.where(matchesFilters).toList(growable: false),
          timestampField: 'updated_at',
        );

        final filteredHistoryRows = historyRows
            .where(matchesFilters)
            .toList(growable: false);

        // ── 2. Decide which technicians are "tracked" (appear in feed) ────────
        //   trackedRows  = any row that TrackingPresence considers feed-worthy
        //   (may include stale rows that are not currently live)
        final trackedRows = scopedLiveRows
            .where((r) => TrackingPresence.evaluate(r).shouldAppearInFeed)
            .toList(growable: false);
        final liveNowRows = scopedLiveRows
            .where((r) => TrackingPresence.evaluate(r).isLive)
            .toList(growable: false);

        // ── 3. Determine rendering mode ───────────────────────────────────────
        //
        //  offlineHistoryOnly → always show offline-history pins
        //  liveOnly           → show only the current-live rows
        //  default            → live rows; fall back to offline history;
        //                       then fall back to last-known positions.

        // Wait for history to load when we must show it
        if (widget.offlineHistoryOnly &&
            historyAsync.isLoading &&
            historyAsync.valueOrNull == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final canFallback = !widget.liveOnly;

        // Live rows that currently have an up-to-date GPS ping
        final filteredLiveRows = widget.liveOnly
            ? liveNowRows // strict: only truly live
            : scopedLiveRows; // relaxed: all scoped rows

        final showHistoryFallback = canFallback &&
            filteredLiveRows.isEmpty &&
            filteredHistoryRows.isNotEmpty;

        final showLastKnownFallback = canFallback &&
            filteredLiveRows.isEmpty &&
            filteredHistoryRows.isEmpty &&
            trackedRows.isNotEmpty;

        final useOfflineHistory =
            widget.offlineHistoryOnly || showHistoryFallback;

        // ── 4. Extract locations ───────────────────────────────────────────────
        final List<TechnicianLocation> locations;
        if (useOfflineHistory) {
          locations = extractOfflineHistoryLocations(
              scopedLiveRows, filteredHistoryRows);
        } else if (showLastKnownFallback) {
          locations = extractLastKnownLocations(trackedRows);
        } else {
          locations = extractLocations(filteredLiveRows);
        }

        // ── 5. Build markers + polylines ──────────────────────────────────────
        final markers = buildMarkers(locations);

        final historyPolylines = buildHistoryPolylines(
          filteredHistoryRows,
          locations,
          useOfflineHistory || showLastKnownFallback,
          strictLiveSession: !(useOfflineHistory || showLastKnownFallback),
        );

        // ── 6. Invalidate camera framing when the set of markers changes ───────
        final markerHash = Object.hashAll(locations.map((l) => l.markerKey));
        if (markerHash != lastMarkerHash) {
          lastMarkerHash = markerHash;
          cameraFramed = false;
        }

        // Keep selectedLocation reference live
        if (selectedLocation != null) {
          selectedLocation = findLocationByMarkerKey(
              locations, selectedLocation!.markerKey);
        }

        // ── 7. Empty state ────────────────────────────────────────────────────
        if (locations.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                widget.liveOnly
                    ? trackedRows.isEmpty
                        ? 'No technician is active right now.'
                        : 'Waiting for a fresh location update…'
                    : useOfflineHistory && widget.jobIdFilter != null
                        ? 'No offline location history found for Job ${widget.jobIdFilter}.'
                        : 'No valid technician coordinates available yet.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        WidgetsBinding.instance
            .addPostFrameCallback((_) => fitCamera(locations));

        // ── 8. Map UI ─────────────────────────────────────────────────────────
        return Stack(
          children: [
            // ── FlutterMap ───────────────────────────────────────────────────
            FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: TechnicianMapLogic.defaultCenter,
                initialZoom: 11,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onTap: (_, __) => setState(() => selectedLocation = null),
                onMapReady: () {
                  mapReady = true;
                  fitCamera(locations, force: true);
                },
              ),
              children: [
                // Base tile layer
                TileLayer(
                  urlTemplate: activeLayer.urlTemplate,
                  subdomains: List<String>.of(
                    activeLayer.subdomains ?? const <String>[],
                  ),
                  userAgentPackageName:
                      TechnicianMapLogic.userAgentPackageName,
                  maxZoom: 20,
                  maxNativeZoom: 19,
                ),
                // Label overlay for Hybrid mode
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
                // Route trails
                if (historyPolylines.isNotEmpty)
                  PolylineLayer(polylines: historyPolylines),
                // Technician pins
                MarkerLayer(markers: markers),
                // Attribution
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(activeLayer.attribution),
                  ],
                ),
              ],
            ),

            // ── Selected-location info card ───────────────────────────────────
            if (selectedLocation != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 88,
                child: _SelectedLocationCard(
                  location: selectedLocation!,
                  markerLabel: markerLabel(selectedLocation!),
                  markerColor: colorForTrackingKey(
                      primaryTrackingKeyForLocation(selectedLocation!)),
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

            // ── Top status bar ────────────────────────────────────────────────
            Positioned(
              top: 14,
              left: 14,
              right: 14,
              child: _TopStatusBar(
                locationCount: locations.length,
                liveOnly: widget.liveOnly,
                offlineHistoryOnly: widget.offlineHistoryOnly,
                useOfflineHistory: useOfflineHistory,
                showLastKnownFallback: showLastKnownFallback,
                jobIdFilter: widget.jobIdFilter,
                onRefresh: () =>
                    unawaited(refreshMapData(forceHistory: true)),
              ),
            ),

            // ── Map-layer picker ──────────────────────────────────────────────
            Positioned(
              top: 80,
              right: 14,
              child: _MapLayerPicker(
                active: activeLayer,
                onSelected: (layer) =>
                    setState(() => activeLayer = layer),
              ),
            ),

            // ── Re-centre FAB ─────────────────────────────────────────────────
            Positioned(
              right: 16,
              bottom: 20,
              child: FloatingActionButton(
                mini: true,
                tooltip: 'Re-centre map',
                onPressed: () => fitCamera(locations, force: true),
                child: const Icon(Icons.my_location),
              ),
            ),
          ],
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────
// _SelectedLocationCard
// ─────────────────────────────────────────────
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
            // Header
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

            // Status pills
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

            // Detail rows
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
                  '${location.latLng.latitude.toStringAsFixed(5)}, '
                  '${location.latLng.longitude.toStringAsFixed(5)}',
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _TopStatusBar
// ─────────────────────────────────────────────
class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.locationCount,
    required this.liveOnly,
    required this.offlineHistoryOnly,
    required this.useOfflineHistory,
    required this.showLastKnownFallback,
    required this.jobIdFilter,
    required this.onRefresh,
  });

  final int locationCount;
  final bool liveOnly;
  final bool offlineHistoryOnly;
  final bool useOfflineHistory;
  final bool showLastKnownFallback;
  final int? jobIdFilter;
  final VoidCallback onRefresh;

  String _label() {
    if (offlineHistoryOnly) return 'Job $jobIdFilter – offline history';
    if (liveOnly) return '$locationCount live technician(s) on map';
    if (useOfflineHistory) {
      return jobIdFilter == null
          ? '$locationCount technician(s) – offline history'
          : 'Job $jobIdFilter – offline history';
    }
    if (showLastKnownFallback) {
      return '$locationCount last-synced technician(s) on map';
    }
    return '$locationCount live technician(s) on map';
  }

  @override
  Widget build(BuildContext context) {
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
            const Icon(Icons.engineering_outlined,
                color: Color(0xFF2563EB)),
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

// ─────────────────────────────────────────────
// _MapLayerPicker
// ─────────────────────────────────────────────
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
                        horizontal: 12, vertical: 10),
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
                          const Icon(Icons.check,
                              size: 16, color: Color(0xFF2563EB)),
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

// ─────────────────────────────────────────────
// _MapInfoPill
// ─────────────────────────────────────────────
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

// ─────────────────────────────────────────────
// _MapDetailRow
// ─────────────────────────────────────────────
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
