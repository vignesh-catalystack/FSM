# Upgrade Version Of FSM Needed

## 1. Goal

This document defines the upgrade path for the current FSM application from its present MVP-stage tracking implementation to a cleaner, more reliable, more realtime-ready version.

Primary goals:

- Stable live location tracking.
- Cleaner map markers and smoother transitions.
- Better route/polyline rendering.
- Strong offline sync with durable queueing.
- Lower API call volume.
- Cleaner request/response handling.
- Easier file structure for future maintenance.

This plan is based on the current Flutter repository only. Backend PHP code is not present in this repo, so backend recommendations below are based on the API contract the app currently expects.

## 2. Upgrade Target

The upgraded version should behave like this:

1. Technician accepts a job.
2. App verifies permission, service availability, auth state, and active session rules.
3. App creates or resumes a tracking session.
4. Device collects points with adaptive throttling and strong filtering.
5. Points are written to durable local storage first.
6. Sync worker uploads points in small batches with acknowledgements.
7. Admin dashboard receives either:
   - delta polling results, or
   - realtime socket/SSE updates.
8. Map updates smoothly without marker jumps or noisy polylines.
9. API layer handles retries, auth, envelope parsing, and failures centrally.

## 3. Current Dependency Inventory

### 3.1 Dependencies Used Now

| Dependency | Current use | Key files |
| --- | --- | --- |
| `flutter_riverpod` | State, providers, lifecycle, invalidation | `job_controller.dart`, dashboards, map screen |
| `http` | API requests | `resilient_http.dart`, `job_api_service.dart` |
| `permission_handler` | Location permission and settings | `permission_service.dart` |
| `geolocator` | GPS current position, last-known position, live stream | `job_controller.dart`, `technician_tracking_service.dart` |
| `flutter_map` | Map rendering | `technician_map_screen.dart`, `technician_map_logic.dart` |
| `latlong2` | Coordinates and distance math | `technician_map_logic.dart`, `technician_map_models.dart` |
| `shared_preferences` | Local cache and pending sync queue | `tracking_cache_store.dart` |
| `battery_plus` | Battery level and charging state | `job_controller.dart`, `technician_tracking_service.dart` |
| `flutter_local_notifications` | Low battery alert | `main.dart`, `technician_tracking_service.dart` |
| `firebase_core` | App bootstrap | `main.dart` |
| `firebase_messaging` | Notifications | `main.dart`, notification layer |

### 3.2 Functions Used Now By Dependency

#### `permission_handler`

Current functions used:

- `Permission.locationWhenInUse.request()`
- `Permission.locationAlways.request()`
- `Permission.locationWhenInUse.status`
- `Permission.locationAlways.status`
- `openAppSettings()`

#### `geolocator`

Current functions used:

- `Geolocator.isLocationServiceEnabled()`
- `Geolocator.getCurrentPosition()`
- `Geolocator.getLastKnownPosition()`
- `Geolocator.getPositionStream()`

#### `flutter_map`

Current widgets/classes used:

- `FlutterMap`
- `MapController`
- `MapOptions`
- `TileLayer`
- `MarkerLayer`
- `PolylineLayer`
- `RichAttributionWidget`
- `CameraFit`

#### `latlong2`

Current functions/classes used:

- `LatLng`
- `Distance().as(LengthUnit.Meter, ...)`

#### `shared_preferences`

Current functions used:

- `SharedPreferences.getInstance()`
- `getString()`
- `setString()`

#### `battery_plus`

Current functions used:

- `batteryLevel`
- `batteryState`

#### `flutter_local_notifications`

Current functions used:

- `initialize()`
- `show()`

#### `http`

Current functions used:

- `http.get()`
- `http.post()`

#### `flutter_riverpod`

Current functions used:

- `Provider`
- `FutureProvider`
- `ref.watch()`
- `ref.read()`
- `ref.invalidate()`
- `ref.refresh()`
- `ref.listen()`

## 4. Recommended Dependency Upgrade Plan

### 4.1 Keep

These are fine to keep:

- `flutter_riverpod`
- `geolocator`
- `flutter_map`
- `latlong2`
- `battery_plus`
- `flutter_local_notifications`
- `permission_handler`

### 4.2 Replace or Reduce

#### Replace `http` with `dio`

Reason:

- Better interceptors.
- Better retry handling.
- Better timeout/cancellation.
- Cleaner request/response middleware.
- Easier auth refresh and logging.

Recommended additions:

- `dio`
- optional `pretty_dio_logger`
- optional `dio_smart_retry`

#### Replace `shared_preferences` for tracking queue storage

Reason:

- `shared_preferences` is too weak for high-frequency tracking data and durable sync queues.
- JSON strings in one key do not scale cleanly.

Recommended replacement:

- `drift`
- `sqlite3_flutter_libs`
- `path_provider`

Alternative:

- `isar`

### 4.3 Add

#### `connectivity_plus`

Reason:

- Detect online/offline transitions.
- Trigger sync immediately when network returns.

#### `workmanager`

Reason:

- Run retry sync more safely in background scenarios.

#### `web_socket_channel` or `socket_io_client`

Reason:

- Optional upgrade for admin realtime feed.
- Reduces frequent dashboard polling.

#### `freezed` and `json_serializable`

Reason:

- Typed request/response models.
- Cleaner API parsing.

Optional only if the team is ready for generated DTOs.

## 5. Major Product Improvements Needed

### 5.1 Tracking Reliability

Needed upgrades:

- Use the permission layer before starting live tracking.
- Persist active tracking session state locally.
- Store every point before upload.
- Batch unsynced points.
- Add sync acknowledgements from backend.
- Add reconnect-triggered replay.
- Add stronger retry policy with backoff.

### 5.2 Realtime Behavior

Needed upgrades:

- Move admin feed from full polling to:
  - delta polling, or
  - socket/SSE updates.
- Avoid invalidating large providers after every single point sync.
- Update only the affected technician/job state in memory.

### 5.3 Map and Marker Quality

Needed upgrades:

- Better polyline filtering by accuracy and speed.
- Better smoothing for noisy points.
- Stable marker identities by session/job.
- Rotation smoothing for marker direction.
- Camera behavior that does not keep fighting the user.

### 5.4 Offline Sync

Needed upgrades:

- Replace `SharedPreferences` queue with a durable local DB queue.
- Add sync states: `pending`, `sending`, `synced`, `failed`.
- Add unique device-side point IDs.
- Add backend dedupe using point ID or idempotency key.

### 5.5 API Efficiency

Needed upgrades:

- Reduce duplicate provider refreshes.
- Merge dashboard endpoints where possible.
- Add delta fetch with `since` cursor.
- Add ETag/If-None-Match where data is mostly unchanged.
- Batch live point uploads.

## 6. File-Wise Upgrade Plan

### 6.1 `pubspec.yaml`

Current tracking dependencies used:

- `flutter_riverpod`
- `http`
- `permission_handler`
- `geolocator`
- `flutter_map`
- `latlong2`
- `shared_preferences`
- `battery_plus`
- `flutter_local_notifications`

Update needed:

- Add:
  - `dio`
  - `connectivity_plus`
  - `drift`
  - `sqlite3_flutter_libs`
  - `path_provider`
  - `workmanager`
- Optional:
  - `web_socket_channel`
  - `freezed_annotation`
  - `json_annotation`
- Dev optional:
  - `build_runner`
  - `drift_dev`
  - `freezed`
  - `json_serializable`

Recommended change:

- Keep `shared_preferences` for tiny app settings only.
- Stop using it for location history and sync queue.

### 6.2 `lib/core/config/app_api_config.dart`

Current functions used:

- `endpointUri()`
- `buildHeaders()`
- `candidateBaseUrls`

Problems:

- Base URL is hard-coded to one tunnel.
- No API versioning.
- No environment separation.

Upgrade needed:

- Add proper environment config:
  - dev
  - staging
  - production
- Add API version root like `/api/v1`.
- Add configurable socket base URL if realtime transport is added.

New functions recommended:

- `trackingBatchUri()`
- `adminSnapshotUri()`
- `socketUri()`
- `buildEtagHeaders()`

### 6.3 `lib/core/network/resilient_http.dart`

Current functions used:

- `get()`
- `post()`
- `send()`

Problems:

- Too generic for growing API complexity.
- No interceptor chain.
- No typed error model.
- No request dedupe.

Upgrade needed:

- Replace with `ApiClient` using `dio`.
- Centralize:
  - auth header
  - timeouts
  - retry
  - logging
  - envelope parsing
  - connectivity-aware retry

Recommended new files:

- `lib/core/network/api_client.dart`
- `lib/core/network/api_envelope.dart`
- `lib/core/network/api_error.dart`

New functions recommended:

- `getJson<T>()`
- `postJson<T>()`
- `postBatch<T>()`
- `parseEnvelope<T>()`
- `mapApiError()`

### 6.4 `lib/core/services/permission_service.dart`

Current functions used:

- `requestLocationPermissionStatus()`
- `requestLocationPermission()`
- `locationPermissionStatus()`
- `hasLocationPermission()`
- `openSettings()`

Problems:

- Permission flow exists but is not fully wired into tracking start.
- No single high-level tracking permission gate.

Upgrade needed:

- Add one function used by the tracking flow:
  - `ensureTrackingPermission()`
- Add location service check:
  - `ensureLocationServiceEnabled()`
- Add background permission path only if background tracking is required.

New functions recommended:

- `ensureTrackingReady({bool requireBackground = false})`
- `checkTrackingPrerequisites()`

### 6.5 `lib/features/permissions/*`

Current files:

- `application/permission_controller.dart`
- `data/permission_repository.dart`
- `domain/permission_model.dart`
- `presentation/permission_screen.dart`

Problems:

- Clean structure exists, but active job acceptance does not depend on it.

Upgrade needed:

- Reuse this permission stack in the technician accept/start flow.
- Decide whether `PermissionScreen` stays as a full page or becomes a bottom sheet dialog.

Recommended change:

- Keep the domain/application/data layers.
- Wire them directly into tracking flow instead of leaving them detached.

### 6.6 `lib/features/jobs/application/job_controller.dart`

Current functions used:

- `_resolveAcceptPosition()`
- `_readBatterySnapshot()`
- `acceptJobAndShareLocation()`
- `finishJobAndStopTracking()`
- `syncTrackingForActiveJob()`

Problems:

- Permission layer not used in active flow.
- Too many provider invalidations after actions.
- Tracking bootstrap and job action logic are still tightly coupled.

Upgrade needed:

- Before accept:
  - check permission
  - check location service
  - check active session
- Use a tracking session bootstrap result instead of loosely starting tracking after accept.
- Invalidate only the minimum affected state.

Recommended new functions:

- `prepareTrackingStart(jobId)`
- `bootstrapTrackingSession(jobId)`
- `resumeTrackingSessionIfNeeded()`
- `markTrackingStateLocally()`

Recommended architectural split:

- keep job actions here
- move tracking-specific orchestration to a separate coordinator:
  - `tracking_session_controller.dart`

### 6.7 `lib/features/jobs/application/technician_tracking_service.dart`

Current functions used:

- `startTracking()`
- `stopTracking()`
- `dispose()`
- `_resolveLocationSettings()`
- `_startPendingFlushTimer()`
- `_buildHistoryPoint()`
- `_flushPendingSync()`
- `_onPosition()`
- `_readBattery()`
- `_maybeSendLowBatteryNotification()`

Problems:

- Queue is partly in memory and partly in `SharedPreferences`.
- Upload is point-by-point, not batch-based.
- Battery is read during tracking but not sent on ongoing tracking requests.
- No connectivity-aware sync scheduling.
- Background readiness is incomplete.

Upgrade needed:

- Persist every point to local DB first.
- Upload in batches:
  - e.g. 10 to 25 points
- Add device-generated `point_id`.
- Add sync acknowledgements from backend.
- Add connectivity listener.
- Add adaptive tracking intervals:
  - lower frequency when stationary
  - higher frequency when moving
- Add stronger accuracy filter before send.

Recommended new functions:

- `persistPoint()`
- `enqueuePointForSync()`
- `syncPendingBatch()`
- `syncPendingBatchNow()`
- `onConnectivityRestored()`
- `pauseTracking()`
- `resumeTracking()`
- `calculateTrackingMode()`
- `shouldUploadPoint()`

Recommended behavior improvements:

- Ignore points with very poor accuracy.
- Use a minimum movement threshold plus time threshold.
- Send battery and charging state in batch payloads.
- Add optional heartbeat payload when technician is stationary but still active.

### 6.8 `lib/features/jobs/application/tracking_cache_store.dart`

Current functions used:

- `cacheLiveRows()`
- `readLiveRows()`
- `cacheHistoryPoints()`
- `readHistoryPoints()`
- `appendHistoryPoint()`
- `enqueuePendingSync()`
- `readPendingSync()`
- `savePendingSync()`

Problems:

- JSON string store is not durable enough for real tracking data.
- No query support by session/job/technician.
- No sync state model.

Upgrade needed:

- Replace this file with DB-backed store.

Recommended replacement:

- `tracking_local_store.dart`
- `tracking_point_dao.dart`
- `tracking_session_dao.dart`
- `sync_queue_dao.dart`

Recommended local tables:

- `tracking_sessions`
- `tracking_points`
- `tracking_sync_queue`
- `tracking_live_cache`

Recommended functions:

- `insertTrackingPoint()`
- `markPointsSending()`
- `markPointsSynced()`
- `getPendingPoints(limit)`
- `getRecentHistoryByJob(jobId)`
- `getLatestLiveRows()`

### 6.9 `lib/features/jobs/application/tracking_presence.dart`

Current functions used:

- `TrackingPresence.evaluate()`
- `isActiveStatus()`
- `isTerminalStatus()`
- `asBool()`
- `asDouble()`
- `parseDateTime()`

Problems:

- Good utility, but rules are hard-coded.
- Freshness logic should become configurable.

Upgrade needed:

- Keep this file.
- Move freshness/config thresholds into constants/config.
- Support server-reported freshness if available.

Recommended additions:

- `isStale()`
- `isLastKnownOnly()`
- `classifyTrackingHealth()`

### 6.10 `lib/features/jobs/data/job_api_service.dart`

Current functions used:

- `acceptJobWithLocation()`
- `finishJobAndStopTracking()`
- `trackLocation()`
- `getTechnicianLiveStatus()`
- `getTechnicianLocationHistory()`
- `getLastLocations()`
- `getAdminSummary()`
- `getAdminJobAssignments()`
- `getDeletedJobs()`

Problems:

- Too many responsibilities in one file.
- Flexible parsing is useful for MVP, but it hides backend inconsistency.
- Live upload is single-point JSON only.
- Admin dashboard still depends on multiple overlapping endpoints.

Upgrade needed:

- Split into:
  - `jobs_api_service.dart`
  - `tracking_api_service.dart`
  - optional `dashboard_api_service.dart`
- Introduce a single response envelope.
- Introduce batch tracking upload endpoint.
- Add delta fetch endpoints.

Recommended new functions:

- `startTrackingSession()`
- `uploadTrackingBatch()`
- `getTrackingSnapshot({String? cursor})`
- `getAdminTrackingSnapshot({String? cursor})`
- `ackSyncedPoints()`

Recommended API reductions:

- Replace repeated admin fetches with one combined snapshot:
  - live rows
  - counts
  - technician/job metadata
- Replace separate last-location fallback endpoint if snapshot already returns `last_known`.

### 6.11 `lib/features/jobs/presentation/animated_marker_widget.dart`

Current functions used:

- `_setup()`
- `_lerp()`
- `_bearing()`

Problems:

- Good base animation, but still depends on noisy upstream points.
- No heading damping.

Upgrade needed:

- Add smoothed bearing between frames.
- Add better interruption handling when updates arrive rapidly.
- Keep controller reuse.

Recommended additions:

- `smoothedBearing()`
- `resolveAnimationDuration()`

### 6.12 `lib/features/jobs/presentation/latlng_tween.dart`

Current use:

- Generic coordinate interpolation helper.

Upgrade needed:

- Keep if reused.
- Otherwise merge its logic into the marker animation layer and remove if unused.

### 6.13 `lib/features/jobs/presentation/technician_map_models.dart`

Current classes used:

- `MapLayerType`
- `TechnicianLocation`
- `RouteMetrics`

Problems:

- Model is useful, but it should become the stable UI DTO rather than relying on raw map rows in multiple places.

Upgrade needed:

- Add:
  - point quality status
  - session ID
  - sync freshness
  - last-known/live distinction

Recommended additions to `TechnicianLocation`:

- `sessionId`
- `pointId`
- `signalQuality`
- `syncState`
- `isStale`

### 6.14 `lib/features/jobs/presentation/technician_map_logic.dart`

Current functions used:

- `refreshMapData()`
- `dedupeRowsByTrackingKey()`
- `extractLocations()`
- `extractLastKnownLocations()`
- `extractOfflineHistoryLocations()`
- `buildHistoryPolylines()`
- `cleanAndSimplifyPath()`
- `trimRouteHistory()`
- `buildMarkers()`
- `fitCamera()`
- `_shouldAnimate()`
- `_calculateBearing()`
- `_smooth()`

Problems:

- Live refresh is still polling-heavy.
- Route cleanup is good, but still basic for production-grade GPS noise.
- Marker movement depends on refresh cadence more than on event quality.

Upgrade needed:

- Improve polyline shaping:
  - remove low-quality points
  - remove backtracking spikes
  - use session-bound grouping
- Improve marker smoothness:
  - keep last stable bearing
  - animate only when point quality is acceptable
- Add map state memory:
  - user-selected technician
  - zoom persistence
  - camera lock mode

Recommended new functions:

- `filterByAccuracy()`
- `filterBySession()`
- `groupHistoryBySession()`
- `buildSessionPolylines()`
- `smoothBearingSeries()`
- `shouldRecenterCamera()`

Optional advanced improvement:

- Use Douglas-Peucker simplification for long routes.

### 6.15 `lib/features/jobs/presentation/technician_map_screen.dart`

Current behavior:

- Watches live, history, and last-location providers.
- Shows map layers, markers, polylines, and detail cards.

Problems:

- Still provider-refresh heavy.
- Fallback behavior is good, but source state should be more explicit in UI.

Upgrade needed:

- Add visible sync state badges:
  - live
  - syncing
  - offline cached
  - stale
- Use a single map view model instead of direct raw provider orchestration in the widget.

Recommended additions:

- `tracking_map_view_model.dart`
- explicit `MapDataSourceState`

### 6.16 `lib/features/dashboards/technician_dashboard.dart`

Current functions used:

- `_acceptJob()`
- `_finishJob()`
- `_refreshDashboard()`
- `_refreshJobs()`
- `_shouldAutoRefresh()`

Problems:

- Refreshes broad provider state.
- Tracking state is derived from job list status.
- Not enough dedicated UX for tracking session health.

Upgrade needed:

- Add visible tracking status card:
  - permission status
  - location service status
  - sync queue count
  - last upload time
- Show local sync health to technician.
- Separate job actions from tracking health.

Recommended additions:

- `TrackingHealthCard`
- `syncQueueCountProvider`
- `trackingSessionProvider`

### 6.17 `lib/features/dashboards/admin_dashboard.dart`

Current functions used:

- `_updateLiveRowsIndex()`
- `_findLiveRowForTechnicianAndJob()`
- `_resolveBatterySource()`
- `_mergeTrackingData()`
- `_computeTrackingFeedItem()`
- `_buildTrackingFeed()`
- `_startAdaptiveRefresh()`
- `_refreshDashboard()`
- `_openLiveMap()`
- `_openTechnicianMap()`

Problems:

- Requires multiple data sources to build one admin picture.
- Polling still drives most updates.
- Merge logic lives in the UI layer.

Upgrade needed:

- Move feed aggregation into repository/service layer.
- Replace multiple fetches with one admin snapshot endpoint.
- If realtime transport is added:
  - maintain a local live state cache
  - patch only changed technician rows

Recommended new files:

- `admin_tracking_repository.dart`
- `admin_tracking_state.dart`

Recommended dashboard behavior:

- Initial snapshot load.
- Delta/live patch updates after initial load.
- Only re-render changed cards.

### 6.18 `lib/main.dart`

Current tracking-related functions used:

- Firebase init
- local notifications init
- route registration for permission screen

Problems:

- Notification setup is split.

Upgrade needed:

- Move notification setup into:
  - `notification_service.dart`
- Keep `main.dart` as bootstrap only.

### 6.19 `android/app/src/main/AndroidManifest.xml`

Current tracking-related declarations:

- location permissions
- foreground service
- notification permission
- geolocator service

Upgrade needed:

- Validate final background-tracking strategy.
- If true background tracking is required:
  - align manifest, service notification, and Dart implementation fully.

### 6.20 `ios/Runner/Info.plist`

Current tracking-related declarations:

- when-in-use location description
- always-and-when-in-use description

Upgrade needed:

- Keep aligned with real product behavior.
- If the app stays foreground-only, simplify the requested permission scope.

## 7. New Files Recommended

Suggested new files for the upgrade:

- `lib/core/network/api_client.dart`
- `lib/core/network/api_envelope.dart`
- `lib/core/network/api_error.dart`
- `lib/core/network/request_policy.dart`
- `lib/features/jobs/data/tracking_api_service.dart`
- `lib/features/jobs/data/jobs_api_service.dart`
- `lib/features/jobs/data/admin_tracking_repository.dart`
- `lib/features/jobs/data/local/tracking_local_store.dart`
- `lib/features/jobs/data/local/tracking_database.dart`
- `lib/features/jobs/data/local/tracking_point_dao.dart`
- `lib/features/jobs/data/local/tracking_session_dao.dart`
- `lib/features/jobs/data/local/sync_queue_dao.dart`
- `lib/features/jobs/domain/tracking_point.dart`
- `lib/features/jobs/domain/tracking_session.dart`
- `lib/features/jobs/domain/tracking_sync_state.dart`
- `lib/features/jobs/application/tracking_session_controller.dart`
- `lib/features/jobs/application/tracking_sync_worker.dart`
- `lib/features/jobs/presentation/tracking_map_view_model.dart`
- `lib/features/jobs/presentation/widgets/tracking_health_card.dart`

## 8. API Enhancement Plan

### 8.1 Current API Call Issues

Current pain points:

- Multiple admin calls for related dashboard data.
- Single-point tracking uploads.
- Broad provider invalidation after each event.
- Loose response parsing because backend contracts are inconsistent.
- Last-known fallback requires a separate request path.

### 8.2 Minimum API Design Improvement

Introduce one consistent envelope:

```json
{
  "success": true,
  "data": {},
  "message": "optional",
  "error": null,
  "meta": {
    "server_time": "2026-05-21T12:00:00Z",
    "cursor": "opaque-delta-token",
    "etag": "response-version"
  }
}
```

Reason:

- Cleaner parsing.
- Cleaner error handling.
- Easier delta sync and caching.

### 8.3 Least-Call Admin API Strategy

Replace multiple admin fetches with one endpoint:

#### Recommended endpoint

- `GET /tracking/admin_snapshot`

Suggested response:

```json
{
  "success": true,
  "data": {
    "summary": {
      "total_technicians": 14,
      "total_jobs": 58,
      "completed_jobs": 21,
      "active_sessions": 4
    },
    "live_rows": [],
    "job_assignments": [],
    "last_known_rows": []
  },
  "meta": {
    "cursor": "abc123"
  }
}
```

Result:

- One snapshot call can replace:
  - `getAdminSummary()`
  - `getTechnicianLiveStatus()`
  - `getAdminJobAssignments()`
  - part of `getLastLocations()`

### 8.4 Delta Polling Strategy

If sockets are not ready yet, use delta polling.

#### Recommended endpoint

- `GET /tracking/admin_delta?cursor=<lastCursor>`

Response should contain only changed technicians/jobs since the last cursor.

Result:

- Lower payload size.
- Lower rebuild cost.
- More realtime feel without full sockets.

### 8.5 Tracking Upload Optimization

Replace single-point uploads with batch uploads.

#### Recommended endpoint

- `POST /tracking/batch`

Suggested request:

```json
{
  "session_id": 456,
  "device_id": "device-123",
  "points": [
    {
      "point_id": "uuid-1",
      "job_id": 123,
      "latitude": 12.34,
      "longitude": 56.78,
      "accuracy": 8.2,
      "speed": 2.0,
      "heading": 145.0,
      "battery": 85,
      "is_charging": 0,
      "captured_at": "2026-05-21T12:01:00Z"
    }
  ]
}
```

Suggested response:

```json
{
  "success": true,
  "data": {
    "accepted_point_ids": ["uuid-1"],
    "rejected_point_ids": []
  }
}
```

Result:

- Fewer requests.
- Better offline replay.
- Better dedupe.

### 8.6 Request Reduction Inside Flutter

Needed frontend changes:

- Do not `ref.invalidate()` multiple providers after every point upload.
- Update in-memory tracking state first.
- Refresh summary on slower intervals than live markers.
- Only fetch history when map/history tab is open.

Recommended policy:

- live marker state: event-driven or 5 to 10 second delta poll
- summary cards: 30 to 60 seconds
- history routes: only on demand

### 8.7 Caching and Conditional Requests

Recommended backend support:

- `ETag`
- `If-None-Match`
- `Last-Modified`
- `If-Modified-Since`

Use this for:

- job assignments
- deleted jobs
- admin summary

This is less useful for high-churn live points, but useful for metadata endpoints.

## 9. Smooth Marker and Polyline Upgrade Plan

### 9.1 Marker Smoothness

Current behavior:

- Marker animates between previous and next position.

Needed upgrade:

- Ignore very noisy points before animation.
- Smooth bearing changes.
- Do not animate giant spikes.
- Use session-aware identity.

Recommended rules:

- ignore if accuracy > 50m, unless no better point exists
- ignore if impossible jump by speed/time relationship
- smooth heading with weighted average

### 9.2 Polyline Quality

Current behavior:

- Basic smoothing and jump filtering already exists.

Needed upgrade:

- Filter by:
  - accuracy
  - elapsed time
  - speed sanity
  - session boundary
- Keep per-session polylines.
- Downsample long history routes before render.

Recommended steps:

1. Remove invalid coordinates.
2. Remove low-quality points.
3. Group by `session_id`.
4. Sort by `captured_at`.
5. Remove spikes.
6. Smooth.
7. Simplify long routes.
8. Render.

### 9.3 Marker/Route UI Improvements

Recommended enhancements:

- Source badges:
  - live
  - last synced
  - offline history
- Sync health badge:
  - healthy
  - delayed
  - stalled
- Battery badge color rules.
- Route color per technician or session.
- Optional start/end markers for session route.

## 10. Offline Sync Upgrade Plan

### 10.1 Current State

Current offline handling:

- live rows cached
- history cached
- pending sync queue stored in `SharedPreferences`

Good parts:

- basic retry exists

Weak parts:

- queue durability is limited
- no point-level sync acknowledgement
- no real conflict handling

### 10.2 Recommended Offline Model

Persist these entities:

- `TrackingSession`
- `TrackingPoint`
- `SyncQueueItem`

Suggested sync states:

- `pending`
- `sending`
- `synced`
- `failed_retryable`
- `failed_terminal`

### 10.3 Sync Worker Behavior

Recommended worker flow:

```text
point captured
  -> validate
  -> save locally
  -> add to sync queue
network available
  -> take oldest pending batch
  -> POST /tracking/batch
  -> mark acked points synced
  -> retry rejected retryable points later
```

Recommended retries:

- exponential backoff
- max retry count for terminal failures
- immediate retry trigger on connectivity restoration

## 11. Recommended Backend Changes

Backend changes needed to support the upgraded app cleanly:

- standard response envelope
- session-based tracking rows
- batch tracking ingest endpoint
- delta snapshot endpoint
- server-side dedupe by `point_id`
- last-known location included in snapshot
- battery fields stored on every accepted point or live row

Recommended backend endpoints:

- `POST /tracking/session/start`
- `POST /tracking/session/stop`
- `POST /tracking/batch`
- `GET /tracking/admin_snapshot`
- `GET /tracking/admin_delta?cursor=...`
- `GET /tracking/history?job_id=...`

## 12. Suggested Upgrade Phases

### Phase 1: Stability First

- Wire permission layer into tracking start.
- Replace `shared_preferences` queue with DB-backed queue.
- Add batch upload endpoint and client support.
- Centralize API response/error handling.

### Phase 2: API Reduction

- Merge admin dashboard endpoints into one snapshot endpoint.
- Add delta polling.
- Reduce provider invalidations.

### Phase 3: Map Quality

- Improve polyline filtering and session grouping.
- Improve marker smoothing and bearing damping.
- Add sync-state UI badges.

### Phase 4: Realtime Upgrade

- Add sockets or SSE for admin live state.
- Use delta patching instead of full refresh.

## 13. Priority Order

Highest-value order for this app:

1. Replace tracking queue storage.
2. Add batch upload API.
3. Wire permission flow correctly.
4. Clean up API layer with central envelope/error handling.
5. Merge admin API calls into one snapshot.
6. Improve map smoothing and polyline quality.
7. Add realtime transport if needed.

## 14. Final Recommendation

For this FSM app, the best MVP-to-stable upgrade path is:

- keep the current Riverpod + Geolocator + FlutterMap foundation
- replace ad-hoc API and cache layers
- move tracking storage from `SharedPreferences` to a local database
- send tracking in batches instead of single-point calls
- merge admin dashboard API calls into one snapshot/delta model
- tighten map smoothing, polyline cleanup, and sync-status UI

That combination will improve:

- reliability
- battery efficiency
- map quality
- API load
- maintenance clarity
