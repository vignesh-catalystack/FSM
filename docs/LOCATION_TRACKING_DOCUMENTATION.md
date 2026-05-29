# Location Tracking Documentation

## 1. Scope

This document describes the active location-tracking implementation in this Flutter app as it exists in the current repository.

It covers:

- Technician-side tracking start, live pinging, stop, retry, and cache behavior.
- Admin-side live feed, map rendering, last-known fallback, and tracking history usage.
- File-wise responsibility for the active tracking code.
- The frontend-to-backend API contract the Flutter app expects.
- Why each major package/feature was chosen and what practical alternatives exist.

It does not cover server-side PHP implementation code, because the backend source is not present in this repository. Backend sections below are based on the client contract inferred from the Flutter code.

Active scope is based on the files reachable from the current app routing and imports, especially:

- `lib/core/routing/app_routing.dart`
- `lib/features/dashboards/technician_dashboard.dart`
- `lib/features/dashboards/admin_dashboard.dart`
- `lib/features/jobs/application/*`
- `lib/features/jobs/data/job_api_service.dart`
- `lib/features/jobs/presentation/technician_map_*`

Excluded from the main explanation:

- `lib/features/jobs/presentation/backup-files/*`
- `*off.dart` files

Those files look like backups or older variants, not the active implementation.

## 2. End-to-End Summary

The current tracking flow is:

1. A technician accepts a job from `TechnicianDashboard`.
2. `JobActionController.acceptJobAndShareLocation()` gets the current device GPS position.
3. `JobApiService.acceptJobWithLocation()` sends the accept payload and initial coordinates to the backend.
4. The controller starts `TechnicianTrackingService`.
5. `TechnicianTrackingService` subscribes to the `Geolocator` position stream.
6. Each useful position is cached locally as history, then uploaded to `tracking/track_location.php`.
7. If upload fails with retryable transport/server errors, the point is pushed into a pending-sync queue in `SharedPreferences`.
8. A timer retries queued points every 30 seconds while tracking is active.
9. Admin screens poll live tracking rows, merge them with job assignment rows, and display them in cards and on a map.
10. When the technician finishes the job, the app calls the finish endpoint and stops the local tracking stream.

Operational states used by the UI:

- `Live now`: fresh active tracking row.
- `Last synced`: not currently fresh, but a last-known location is available.
- `Offline history`: archived path/history data used when explicit history mode is shown.

## 3. Features, Why They Are Used, and Alternatives

| Feature | Current choice | Why used here | Practical alternatives |
| --- | --- | --- | --- |
| Permission handling | `permission_handler` | Explicit control over foreground/background location permission prompts and settings redirection. | `geolocator` permission APIs, platform channels, `flutter_permission_handler_plus` style wrappers. |
| GPS capture and stream | `geolocator` | Supports current position, last-known position, service checks, and live streams in one package. | `location`, `flutter_background_geolocation`, native Android Fused Location / iOS Core Location. |
| Map rendering | `flutter_map` + `latlong2` | Avoids Google Maps API key dependence and supports OSM/Esri/Carto tile layers. | `google_maps_flutter`, `mapbox_maps_flutter`, HERE SDK. |
| Offline local storage | `shared_preferences` | Simple, lightweight persistence for small live caches and retry queues. | `sqflite`, `drift`, `isar`, `hive`. Better for larger tracking history volumes. |
| Battery state | `battery_plus` | Adds operational context for technician device health and low-battery warnings. | Skip battery capture entirely, native platform battery APIs, periodic push from MDM/device agent. |
| Local technician alerts | `flutter_local_notifications` | Allows an on-device low-battery warning while tracking is running. | In-app banner only, Firebase push, native notification channels only. |
| State management | `flutter_riverpod` | Clean provider invalidation and lifecycle ownership for tracking service and dashboards. | `provider`, `bloc`, `getx`, `mobx`. |
| Network resilience | custom `ResilientHttp` | Adds retry behavior without bringing in a heavier client stack. | `dio` with interceptors/retry plugins, `chopper`, custom repository retry logic. |
| Live admin refresh | polling | Simple to implement with ordinary PHP endpoints. | WebSocket, Server-Sent Events, MQTT, Firebase Realtime Database / Firestore listeners. |

## 4. File-Wise Documentation

### 4.1 Bootstrap, Routing, and Platform Setup

#### `lib/main.dart`

Role:

- App bootstrap.
- Initializes Firebase.
- Initializes local notifications.
- Registers the standalone permission route.

Tracking-relevant parts:

- Creates a `FlutterLocalNotificationsPlugin` instance for app-wide notification setup.
- Registers `/permissions` -> `PermissionScreen`.
- Launches `AppRouter`, which decides whether the technician or admin dashboard is shown.

Why used:

- Tracking depends on notifications for the low-battery warning and on app startup to initialize supporting services.

Alternatives:

- Centralize all notification setup into a dedicated service singleton instead of splitting setup across `main.dart` and `TechnicianTrackingService`.

Important note:

- `TechnicianTrackingService` also creates and initializes its own notification plugin instance for low-battery alerts, so notifications are currently initialized in two places.

#### `lib/core/routing/app_routing.dart`

Role:

- Chooses the active dashboard by authenticated role.

Tracking relevance:

- Routes technicians to `TechnicianDashboard`.
- Routes admins to `AdminDashboard`.

Why used:

- These two dashboards are the entry points for the active tracking producer and tracking consumer flows.

#### `android/app/src/main/AndroidManifest.xml`

Role:

- Android platform permissions and service declarations.

Tracking-relevant entries:

- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_BACKGROUND_LOCATION`
- `FOREGROUND_SERVICE`
- `POST_NOTIFICATIONS`
- `com.baseflow.geolocator.LocationUpdatesService`

Why used:

- Fine/coarse permissions allow GPS use.
- Background and foreground-service declarations indicate the app is prepared for long-running location updates.
- Notification permission is needed for local alerts.

Alternatives:

- Foreground-only tracking can drop `ACCESS_BACKGROUND_LOCATION` if product requirements do not need background behavior.
- A dedicated native background-tracking service could replace the plugin-provided service approach.

Important note:

- The manifest declares background-related capability, but the Dart tracking flow does not fully request or configure background behavior in a robust way. See Section 7.

#### `ios/Runner/Info.plist`

Role:

- iOS location permission descriptions.

Tracking-relevant entries:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

Why used:

- iOS requires human-readable reason strings before location permission prompts can be shown.

Alternatives:

- If background tracking is not required, the app could simplify to foreground-only wording and permission scope.

### 4.2 Permissions Stack

#### `lib/core/services/permission_service.dart`

Role:

- Lowest-level permission helper around `permission_handler`.

Main functions:

- `requestLocationPermissionStatus({bool requireBackground = false})`
- `requestLocationPermission({bool requireBackground = false})`
- `locationPermissionStatus({bool requireBackground = false})`
- `hasLocationPermission({bool requireBackground = false})`
- `openSettings()`

Why used:

- Separates raw platform permission calls from UI and tracking logic.
- Supports both foreground-only and foreground+background permission shapes.

Alternatives:

- Use `Geolocator.checkPermission()` and `Geolocator.requestPermission()` instead of `permission_handler`.
- Use platform channels if custom OS-specific behavior is needed.

#### `lib/features/permissions/data/permission_repository.dart`

Role:

- Maps plugin-level permission states into app-level enum values.

Main functions:

- `requestLocation()`
- `hasPermission()`
- `openSettings()`

Why used:

- Keeps permission-state mapping out of the UI layer.

Alternatives:

- Collapse this into the controller for a smaller app.

#### `lib/features/permissions/application/permission_controller.dart`

Role:

- Thin application layer for the permission screen.

Main functions:

- `requestLocation()`
- `checkPermission()`
- `openSettings()`

Why used:

- Keeps the UI screen thin and testable.

#### `lib/features/permissions/domain/permission_model.dart`

Role:

- Small app-specific permission enum.

Values:

- `granted`
- `denied`
- `permanentlyDenied`

Why used:

- Normalizes platform/plugin permission responses into a UI-friendly model.

#### `lib/features/permissions/presentation/permission_screen.dart`

Role:

- Standalone UI for requesting location permission.

Tracking-relevant behavior:

- Calls `PermissionController.requestLocation()`.
- Offers a `Settings` shortcut if permission is permanently denied.

Alternatives:

- Inline permission prompting in the technician accept flow instead of having a separate screen.

Important note:

- I did not find an active caller that navigates to this screen from the tracking flow.

### 4.3 Tracking Runtime and Data Layer

#### `lib/features/jobs/application/job_controller.dart`

Role:

- Main application-layer coordinator for job actions and tracking service lifecycle.

Providers defined here:

- `jobApiServiceProvider`
- `myJobsProvider`
- `adminTechnicianLiveProvider`
- `adminTechnicianHistoryProvider`
- `adminTechnicianLastProvider`
- `adminDashboardSummaryProvider`
- `adminJobAssignmentsProvider`
- `adminDeletedJobsProvider`
- `technicianTrackingServiceProvider`
- `jobActionControllerProvider`

Main tracking functions:

- `_resolveAcceptPosition()`
- `_readBatterySnapshot()`
- `acceptJobAndShareLocation({required int jobId})`
- `finishJobAndStopTracking({required int jobId})`
- `syncTrackingForActiveJob({required int? activeJobId})`

Why these functions exist:

- `_resolveAcceptPosition()` gets a strong current fix for the first tracking point and falls back to last-known position on timeout so job acceptance is less brittle.
- `acceptJobAndShareLocation()` couples job acceptance with the first location capture and tracking startup.
- `finishJobAndStopTracking()` keeps job completion and local tracking shutdown in sync.
- `syncTrackingForActiveJob()` rehydrates tracking if the dashboard rebuilds and an active job is still present.

Alternatives:

- Split accept-job and start-tracking into separate user actions.
- Persist active tracking session state in durable storage rather than re-deriving it from job status.

Important notes:

- `technicianTrackingServiceProvider` owns tracking service disposal and stops tracking on auth/session loss.
- The file defines `PermissionService _permissionService`, but the active accept/start flow does not currently use it.

#### `lib/features/jobs/application/technician_tracking_service.dart`

Role:

- Core live-tracking engine.

Main public functions:

- `startTracking({required int jobId, int? sessionId})`
- `stopTracking({int? jobId})`
- `dispose()`

Main internal functions:

- `_resolveLocationSettings()`
- `_startPendingFlushTimer()`
- `_buildHistoryPoint()`
- `_flushPendingSync()`
- `_onPosition()`
- `_readBattery()`
- `_maybeSendLowBatteryNotification()`

What it does:

- Stops any previous tracking session before starting a new one.
- Verifies device location services are enabled.
- Starts a `Geolocator.getPositionStream()` subscription.
- Seeds tracking with `getLastKnownPosition()` and then a forced `getCurrentPosition()`.
- Caches every point locally as history.
- Throttles network sends to avoid pushing too frequently.
- Queues retryable failed uploads.
- Flushes queued uploads on a 30-second timer.
- Reads battery level and shows a local warning if battery is below 20 percent.

Why it is built this way:

- Stream subscription gives near-real-time updates.
- Last-known position makes the map feel responsive immediately after startup.
- Current-position force send improves the first accurate point.
- Local history cache gives the UI something to render during network issues.
- Pending queue prevents total data loss during transient outages.

Location settings used:

- Web/default: high accuracy, `distanceFilter: 3`
- Android: high accuracy, `distanceFilter: 15`, `intervalDuration: 20 seconds`
- iOS/macOS: high accuracy, `distanceFilter: 3`, `pauseLocationUpdatesAutomatically: true`, `activityType: automotiveNavigation`

Alternatives:

- `flutter_background_geolocation` for stronger background guarantees and richer activity tracking.
- Native batching or fused-provider APIs for better battery efficiency.
- A database-backed queue instead of in-memory plus `SharedPreferences`.

Important notes:

- `_onPosition()` stores a history point before trying the upload. This is why the app can still show recent movement after transport failures.
- Battery is read on each update, but ongoing `trackLocation()` uploads do not currently send battery fields. In the current code battery is sent during job acceptance only.

#### `lib/features/jobs/application/tracking_cache_store.dart`

Role:

- Local persistence for live rows, history rows, and pending uploads.

Stored keys:

- `tracking_live_cache_v1`
- `tracking_history_cache_v1`
- `tracking_pending_sync_v1`

Main functions:

- `cacheLiveRows()`
- `readLiveRows()`
- `cacheHistoryPoints()`
- `readHistoryPoints()`
- `appendHistoryPoint()`
- `enqueuePendingSync()`
- `readPendingSync()`
- `savePendingSync()`

Why used:

- Gives the app a lightweight offline story without needing a heavier local database.
- Supports:
  - last good live feed cache
  - route/history cache
  - retry queue for failed uploads

Alternatives:

- `drift`, `sqflite`, `isar`, or `hive` if tracking volume grows or offline history must be queryable by job/session over a longer time window.

Important note:

- `SharedPreferences` is acceptable for small queues and short history windows, but it is not ideal for high-frequency tracking at scale.

#### `lib/features/jobs/application/tracking_presence.dart`

Role:

- Converts raw tracking rows into UI-friendly live/offline/terminal state.

Main symbols:

- `TrackingSnapshot`
- `TrackingPresence.evaluate()`
- `TrackingPresence.isActiveStatus()`
- `TrackingPresence.isTerminalStatus()`
- `TrackingPresence.asBool()`
- `TrackingPresence.asDouble()`
- `TrackingPresence.parseDateTime()`

Rules implemented here:

- Freshness window: 3 minutes.
- Active statuses include values such as `accepted`, `in_progress`, `active`, `ongoing`, `working`, `started`.
- Terminal statuses include `ended`, `completed`, `finished`, `inactive`, `off`, `closed`, `archived`.

Why used:

- Backend data can vary in shape and wording. This file gives the UI one place to interpret state consistently.

Alternatives:

- Push a stricter backend contract and reduce the amount of heuristic state parsing in Flutter.

#### `lib/features/jobs/data/job_api_service.dart`

Role:

- All backend HTTP contract handling for jobs and tracking.

Tracking-relevant endpoint groups:

- Accept job: `jobs/accept.php`
- Finish job: `jobs/finish.php`
- Live ping: `tracking/track_location.php`
- Admin live feed: `tracking/live_location.php`
- Admin live fallback: `jobs/list.php`
- History: `tracking/location_history.php`
- Last-known rows: `tracking/last_locations.php`
- Admin summary: `jobs/admin_summary.php`
- Admin jobs list: `jobs/list.php`

Most important functions:

- `acceptJobWithLocation()`
- `finishJobAndStopTracking()`
- `trackLocation()`
- `getTechnicianLiveStatus()`
- `getTechnicianLocationHistory()`
- `getLastLocations()`
- `getAdminJobAssignments()`
- `_normalizeLiveRow()`
- `_normalizeHistoryPoint()`
- `_dedupeLiveRows()`

Why it is structured this way:

- Accept and finish endpoints support both JSON and form-post fallback because PHP stacks often read either raw JSON or `$_POST`, depending on implementation.
- Live/history readers accept many possible response wrappers (`data`, `jobs`, `locations`, `items`, `history`, `live_tracking`) because the backend response format is not fully strict.
- Live rows are normalized and deduplicated before the UI sees them.
- Live/historical API failures fall back to locally cached rows where possible.

Alternatives:

- Standardize backend on a single JSON envelope and remove the flexible parsing.
- Use `dio` with typed DTOs and interceptors.
- Replace polling endpoints with a live channel.

Important notes:

- `trackLocation()` currently posts JSON only. It does not have the JSON/form dual-fallback used by accept and finish.
- `getTechnicianLiveStatus()` writes successful results into `TrackingCacheStore` and returns cached rows with `is_from_cache: true` if the network fails.
- `getTechnicianLocationHistory()` also falls back to cached history rows.

#### `lib/core/config/app_api_config.dart`

Role:

- Central API base URL and header builder.

Main functions:

- `endpointUri()`
- `buildHeaders()`
- `candidateBaseUrls`

Why used:

- Keeps URL joining, bearer-token normalization, and common headers in one place.

Alternatives:

- Environment/flavor-based config packages such as `flutter_dotenv`.
- Separate dev/staging/prod configs per build flavor.

Important notes:

- Current `baseUrl` resolves to a fixed ngrok tunnel constant.
- Headers add:
  - `Accept: application/json`
  - `Authorization: Bearer <token>`
  - `ngrok-skip-browser-warning: true`

#### `lib/core/network/resilient_http.dart`

Role:

- Small retry wrapper around `http.get()` and `http.post()`.

Main functions:

- `get()`
- `post()`
- `send()`

Retry behavior:

- Retries status codes: `408`, `425`, `429`, `502`, `503`, `504`
- Retries errors: `TimeoutException`, `SocketException`, `http.ClientException`

Why used:

- Tracking and admin polling are network-sensitive. Short transient failures should not immediately surface as permanent failures.

Alternatives:

- `dio` retry interceptors
- custom exponential backoff with jitter

### 4.4 Technician-Side Presentation Layer

#### `lib/features/dashboards/technician_dashboard.dart`

Role:

- Main technician UI where tracking is started and stopped.

Tracking-relevant functions:

- `_acceptJob()`
- `_finishJob()`
- `_refreshDashboard()`
- `_refreshJobs()`
- `_shouldAutoRefresh()`

Tracking behavior:

- Shows jobs from `myJobsProvider`.
- Accept button calls `jobActionControllerProvider.acceptJobAndShareLocation()`.
- Finish button calls `jobActionControllerProvider.finishJobAndStopTracking()`.
- Derives `activeTrackingJobId` from job status and calls `syncTrackingForActiveJob()` when it changes.
- Stops tracking on logout by calling `technicianTrackingServiceProvider.stopTracking()`.

Why used:

- This screen is the operator workflow that turns tracking on and off.

Alternatives:

- Separate tracking controls from job actions.
- Persist active tracking session state independently from job status.

Important notes:

- Dashboard refresh timer runs every 60 seconds.
- The screen can recover local tracking after rebuild by asking the controller to resync tracking for the current active job.

#### `lib/features/jobs/presentation/animated_marker_widget.dart`

Role:

- Smooth marker movement between map updates.

Main behavior:

- Interpolates from previous to new position.
- Computes bearing from old to new point.
- Adjusts animation duration from reported speed.

Why used:

- Without animation, map markers jump on every refresh.

Alternatives:

- No animation.
- Marker clustering or native-map animated markers.

#### `lib/features/jobs/presentation/latlng_tween.dart`

Role:

- Generic `LatLng` tween utility.

Why used:

- Encapsulates coordinate interpolation logic.

Important note:

- In the active code path, `AnimatedMarkerWidget` performs its own interpolation directly. This tween is more of a reusable helper than a central active dependency.

### 4.5 Admin-Side Presentation Layer

#### `lib/features/dashboards/admin_dashboard.dart`

Role:

- Main consumer UI for live technician tracking.

Tracking-relevant functions:

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
- `_cleanLiveError()`

What it does:

- Watches:
  - `adminTechnicianLiveProvider`
  - `adminDashboardSummaryProvider`
  - `adminJobAssignmentsProvider`
  - `adminDeletedJobsProvider`
- Builds a live-row index for fast technician/job lookups.
- Merges live tracking rows with job assignment rows to fill missing fields such as job title, status, or battery metadata.
- Computes UI state using `TrackingPresence`.
- Shows:
  - dashboard counts
  - technician assignment cards
  - technician tracking feed
  - map entry points

Why used:

- Live tracking feed data is not sourced from a single clean backend endpoint, so the dashboard merges and enriches several backend views before rendering.

Alternatives:

- Move feed aggregation to the backend and return one canonical admin tracking DTO.
- Use WebSocket/SSE live updates instead of periodic polling.

Important notes:

- Adaptive refresh is 10 seconds when live technicians exist, otherwise 30 seconds.
- The "View on map" action passes current live rows as `seedRows` so the map can render immediately before provider refresh completes.

#### `lib/features/jobs/presentation/technician_map_models.dart`

Role:

- Shared data model and map-layer metadata.

Main symbols:

- `MapLayerType`
- `TechnicianLocation`
- `RouteMetrics`

Why used:

- `MapLayerType` keeps tile URLs, labels, icons, and attribution in one place.
- `TechnicianLocation` gives the map a stable, typed runtime model independent from raw backend rows.

Alternatives:

- Use a single backend DTO everywhere and avoid a separate map model.

Important notes:

- `MapLayerType` uses OSM/Esri/Carto tiles, not Google Maps.
- `TechnicianLocation` carries speed, accuracy, bearing, and source labels for richer marker behavior.

#### `lib/features/jobs/presentation/technician_map_logic.dart`

Role:

- All nontrivial map business logic and rendering helpers.

Main function groups:

- Refresh and timing:
  - `initLogic()`
  - `disposeLogic()`
  - `refreshMapData()`
  - `shouldAutoRefresh()`
- Parsing/state helpers:
  - `asText()`
  - `asDouble()`
  - `asDateTime()`
  - `asInt()`
  - `timeAgo()`
  - `titleCase()`
- Tracking-state helpers:
  - `rowShouldAppearInFeed()`
  - `rowIsLive()`
  - `dedupeRowsByTrackingKey()`
- Location extraction:
  - `extractLocations()`
  - `extractLastKnownLocations()`
  - `extractOfflineHistoryLocations()`
- Route/history rendering:
  - `buildHistoryPolylines()`
  - `restrictHistoryToLiveSession()`
  - `trimRouteHistory()`
  - `cleanAndSimplifyPath()`
  - `summarizeRoute()`
  - `downsamplePath()`
- Marker rendering:
  - `buildMarkers()`
  - `fitCamera()`
  - `_shouldAnimate()`
  - `_calculateBearing()`
  - `_smooth()`

Why this file exists:

- Keeps the screen widget readable by extracting the heavy map-specific logic.

Why specific behaviors were added:

- Refresh split:
  - live rows refresh every 5 seconds
  - history refresh every 32 seconds
  - reason: live markers need quicker updates than archived history
- `_shouldAnimate()` ignores:
  - less than 1 meter movement: GPS jitter
  - more than 300 meters sudden jump: likely GPS spike
- `cleanAndSimplifyPath()` smooths and removes unreasonable path jumps so polylines look human instead of noisy.

Alternatives:

- Move this into a dedicated presenter/view-model class.
- Use server-side path simplification instead of client-side cleanup.

#### `lib/features/jobs/presentation/technician_map_screen.dart`

Role:

- Active map UI.

What it shows:

- Live technician markers.
- Last-known fallback markers.
- History polylines.
- Selected marker details.
- Map layer switcher.

How it chooses what to show:

- Priority 1: live locations from `adminTechnicianLiveProvider`
- Priority 2: last-known rows from `adminTechnicianLastProvider`
- Explicit history mode: offline history rows from `adminTechnicianHistoryProvider`

Tracking-relevant behavior:

- Watches:
  - `adminTechnicianLiveProvider`
  - `adminTechnicianHistoryProvider`
  - `adminTechnicianLastProvider`
- Accepts optional filters:
  - `jobIdFilter`
  - `technicianIdFilter`
- Accepts optional `seedRows` for immediate first paint.

Why used:

- Separates detailed spatial visualization from dashboard cards.

Alternatives:

- Embed a smaller map directly into the admin dashboard.
- Replace tile-map view with a list-only live feed.

Important notes:

- The map supports an explicit `offlineHistoryOnly` mode, but I did not find an active caller for that mode in the current UI.

## 5. Frontend and Backend Wiring

### 5.1 Base Request Wiring

All tracking/job API requests are built through:

- `AppApiConfig` for base URL and headers
- `JobApiService` for endpoint selection and payload building
- `ResilientHttp` for retries

Common request characteristics:

- Bearer token authentication
- JSON expected in responses
- ngrok warning bypass header
- PHP-compatible endpoint naming

### 5.2 Accept Job and Start Tracking

Frontend call chain:

```text
TechnicianDashboard._acceptJob()
  -> JobActionController.acceptJobAndShareLocation(jobId)
    -> TechnicianTrackingService.stopTracking()
    -> _resolveAcceptPosition()
      -> Geolocator.getCurrentPosition()
      -> fallback Geolocator.getLastKnownPosition()
    -> _readBatterySnapshot()
    -> JobApiService.acceptJobWithLocation()
      -> POST jobs/accept.php
    -> TechnicianTrackingService.startTracking(jobId, sessionId)
```

Backend responsibilities inferred from the client contract:

```text
jobs/accept.php should:
  -> validate token and technician access
  -> mark job as accepted
  -> store first location
  -> create or reopen a tracking session
  -> return success JSON
  -> ideally return session_id
```

Accept payload fields sent by the app:

```json
{
  "job_id": 123,
  "id": 123,
  "status": "accepted",
  "job_status": "accepted",
  "latitude": 12.34,
  "longitude": 56.78,
  "lat": 12.34,
  "lng": 56.78,
  "location_lat": 12.34,
  "location_lng": 56.78,
  "accepted_at": "ISO-8601 timestamp",
  "battery": 87,
  "is_charging": 0
}
```

Why both `latitude/longitude` and `lat/lng/location_lat/location_lng` are sent:

- The app is compensating for inconsistent PHP field naming on the backend.

### 5.3 Live Tracking Ping Loop

Frontend call chain:

```text
TechnicianTrackingService.startTracking()
  -> Geolocator.isLocationServiceEnabled()
  -> Geolocator.getPositionStream(settings)
  -> optionally Geolocator.getLastKnownPosition()
  -> optionally Geolocator.getCurrentPosition()
  -> _onPosition(position)
    -> TrackingCacheStore.appendHistoryPoint()
    -> _readBattery()
    -> JobApiService.trackLocation()
      -> POST tracking/track_location.php
    -> on failure: TrackingCacheStore.enqueuePendingSync()
```

Pending retry loop:

```text
Timer every 30 seconds
  -> TechnicianTrackingService._flushPendingSync()
    -> TrackingCacheStore.readPendingSync()
    -> JobApiService.trackLocation() for queued items
    -> TrackingCacheStore.savePendingSync(remaining)
```

Backend responsibilities inferred from the client contract:

```text
tracking/track_location.php should:
  -> validate token, job_id, and optional session_id
  -> append a history point
  -> update the latest live position for that job/technician
  -> update updated_at / captured_at timestamps
  -> return a JSON success response
```

Live ping payload sent by the app:

```json
{
  "job_id": 123,
  "session_id": 456,
  "latitude": 12.34,
  "longitude": 56.78,
  "accuracy": 8.5,
  "speed": 2.1,
  "heading": 145.0,
  "captured_at": "UTC ISO-8601 timestamp"
}
```

Current behavior note:

- Ongoing live pings do not currently send battery fields.

### 5.4 Admin Live Feed Wiring

Frontend call chain:

```text
AdminDashboard.build()
  -> ref.watch(adminTechnicianLiveProvider)
    -> JobApiService.getTechnicianLiveStatus()
      -> GET tracking/live_location.php
      -> fallback GET jobs/list.php
  -> ref.watch(adminJobAssignmentsProvider)
    -> JobApiService.getAdminJobAssignments()
      -> GET jobs/list.php
  -> _buildTrackingFeed(liveRows, assignmentRows)
  -> render cards and map launchers
```

Backend responsibilities inferred from the client contract:

```text
tracking/live_location.php should return active tracking rows with fields like:
  technician_id
  technician_name
  job_id
  job_title
  status
  tracking_status
  is_tracking
  latitude
  longitude
  updated_at
  optional battery/is_charging
```

Why the admin dashboard merges live rows and job rows:

- The live endpoint is not assumed to contain every display field.
- The jobs list is used as a fallback metadata source.

### 5.5 Tracking Map Wiring

Frontend call chain:

```text
AdminDashboard._openLiveMap(rawLiveRows)
  -> Navigator.push(TechnicianLocationsMapScreen(liveOnly: true, seedRows: rawLiveRows))

AdminDashboard._openTechnicianMap(jobId, technicianId, ...)
  -> Navigator.push(TechnicianLocationsMapScreen(jobIdFilter: ..., technicianIdFilter: ...))
```

Inside the map screen:

```text
TechnicianLocationsMapScreen.build()
  -> watch live provider
  -> watch history provider
  -> watch last-locations provider
  -> choose display mode
  -> TechnicianMapLogic.extract...
  -> TechnicianMapLogic.buildMarkers()
  -> TechnicianMapLogic.buildHistoryPolylines()
  -> FlutterMap render
```

Backend responsibilities inferred from the client contract:

```text
tracking/location_history.php should return historical points
tracking/last_locations.php should return latest stored rows even if not live
```

### 5.6 Finish Job and Stop Tracking

Frontend call chain:

```text
TechnicianDashboard._finishJob()
  -> JobActionController.finishJobAndStopTracking(jobId)
    -> JobApiService.finishJobAndStopTracking()
      -> POST jobs/finish.php
    -> TechnicianTrackingService.stopTracking(jobId)
```

Finish payload fields sent by the app:

```json
{
  "job_id": 123,
  "id": 123,
  "status": "completed",
  "job_status": "completed",
  "tracking_status": "ended",
  "stop_tracking": 1,
  "is_tracking": 0,
  "ended_at": "ISO-8601 timestamp"
}
```

Backend responsibilities inferred from the client contract:

```text
jobs/finish.php should:
  -> validate token and job ownership
  -> mark job completed
  -> close/end the tracking session
  -> keep history rows intact
  -> remove the session from the live feed
```

### 5.7 Offline and Recovery Wiring

Client-side recovery model:

```text
Position generated
  -> save to local history cache
  -> attempt upload
    -> success: invalidate admin live provider
    -> retryable failure: add to pending queue
Timer flush
  -> replay pending queue
Network read failure
  -> use cached live rows or cached history rows if available
```

Why this is valuable:

- Admin users still get the last good picture.
- Device-side route history is not immediately lost during network interruptions.
- Pending points can be replayed later instead of being dropped.

Alternatives:

- Persistent queue in SQLite/Drift.
- Background worker/service for guaranteed replay after app restarts.
- Event streaming backend with durable ingestion.

## 6. Expected Backend Endpoints and Their Meaning

This section is the backend contract inferred from the Flutter app.

### `POST jobs/accept.php`

Used for:

- Accepting a job
- Sending the first location
- Optionally sending initial battery data

Expected response:

- JSON success/failure
- ideally `session_id`
- optional human-readable `message`

### `POST jobs/finish.php`

Used for:

- Completing a job
- Marking tracking ended

Expected response:

- JSON success/failure
- optional `message`

### `POST tracking/track_location.php`

Used for:

- Sending each live location ping
- Recording ongoing path/history points

Expected response:

- JSON success/failure

### `GET tracking/live_location.php`

Used for:

- Admin live technician feed
- Map live markers

Expected response shapes accepted by the app:

- a plain list of rows
- or a map with one of:
  - `technicians`
  - `live_tracking`
  - `locations`
  - `jobs`
  - `data`

### `GET tracking/location_history.php`

Used for:

- Historical path points
- Optional filtering by `technician_id` and/or `job_id`

Expected response shapes accepted by the app:

- a plain list of points
- or a map with one of:
  - `history`
  - `locations`
  - `data`
  - `items`

### `GET tracking/last_locations.php`

Used for:

- Last-synced fallback when no live row is fresh

Expected response shape:

- map containing `data: [ ...rows ]`

### `GET jobs/list.php`

Used for:

- Admin job assignments
- Live tracking fallback when a dedicated live endpoint is unavailable

### `GET jobs/admin_summary.php`

Used for:

- Admin overview counts, including live session count

## 7. Current Implementation Notes and Gaps

These points are based on the current code, not on assumed future design.

### 7.1 Permission layer exists but is not wired into the active tracking path

Observed behavior:

- `PermissionService`, repository, controller, and `PermissionScreen` exist.
- `JobActionController.acceptJobAndShareLocation()` does not call that permission layer before using `Geolocator`.

Implication:

- The app currently relies on `Geolocator` behavior/exceptions instead of the dedicated permission flow.

Recommended alternatives:

- Call `PermissionService.requestLocationPermissionStatus()` before `_resolveAcceptPosition()`.
- Navigate to `PermissionScreen` if the user must explicitly grant or fix permission.

### 7.2 Background intent is declared, but background tracking is not fully wired

Observed behavior:

- Android manifest declares background location and geolocator location service.
- iOS plist declares always-and-when-in-use messaging.
- The active permission path does not request background permission with `requireBackground: true`.
- `TechnicianTrackingService` does not configure Android foreground-notification settings for a long-running background stream.

Implication:

- Treat the current implementation as foreground-first tracking unless end-to-end device testing proves otherwise.

### 7.3 Battery is partially wired

Observed behavior:

- Battery is sent during `acceptJobWithLocation()`.
- `TechnicianTrackingService._readBattery()` runs during live tracking and can show local low-battery warnings.
- Ongoing `trackLocation()` uploads do not include battery/is_charging.

Implication:

- Admin battery display is likely based on initial accept payload or backend-side enrichment, not guaranteed live battery updates from every tracking ping.

### 7.4 `trackLocation()` is less PHP-compatible than accept/finish

Observed behavior:

- Accept and finish attempt JSON first, then form-body fallback.
- `trackLocation()` sends JSON only.

Implication:

- If the backend tracking endpoint expects `$_POST` instead of JSON decoding, live location uploads can fail even though accept/finish work.

### 7.5 Offline-history mode exists, but active UI does not seem to open it

Observed behavior:

- `TechnicianLocationsMapScreen` supports `offlineHistoryOnly`.
- I did not find an active caller passing `offlineHistoryOnly: true`.

Implication:

- Explicit archived-history map mode is present in code but not currently exposed by the active UI flow.

### 7.6 Backup files can confuse maintenance

Observed behavior:

- The repo still contains `backup-files` and several `*off.dart` tracking/map variants.

Implication:

- Future engineers can easily patch the wrong file.

## 8. Suggested Backend Shape (Inference, Not Present in Repo)

This section is a recommended backend structure inferred from what the client expects.

Suggested logical tables:

- `jobs`
  - `id`
  - `title`
  - `technician_id`
  - `status`
  - `tracking_status`
  - `last_latitude`
  - `last_longitude`
  - `last_location_updated_at`
- `tracking_sessions`
  - `id`
  - `job_id`
  - `technician_id`
  - `status`
  - `started_at`
  - `ended_at`
- `tracking_points`
  - `id`
  - `session_id`
  - `job_id`
  - `technician_id`
  - `latitude`
  - `longitude`
  - `accuracy`
  - `speed`
  - `heading`
  - `captured_at`
  - `source`
  - optional `battery`
  - optional `is_charging`

Why this shape fits the app:

- The app separates:
  - current live status
  - last-known fallback
  - full route history
- A session table cleanly supports active vs ended tracking.
- A points table cleanly supports history and map polyline reconstruction.

## 9. Recommended Next Improvements

If this tracking module is going to production, the highest-value improvements are:

1. Wire `PermissionService` into the actual accept/start flow.
2. Decide whether background tracking is a real requirement and fully implement it if yes.
3. Add battery fields to ongoing `trackLocation()` payloads if the admin battery UI is supposed to be live.
4. Make `trackLocation()` support the same JSON/form fallback as accept and finish, or standardize the backend on JSON.
5. Replace `SharedPreferences` with a queue-friendly local store if route volume will increase.
6. Remove or archive inactive tracking backup files outside the active source tree.
