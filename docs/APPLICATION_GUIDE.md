# FSM Application Guide

This project is a Flutter field-service-management app. It supports role-based login, admin/manager/technician/user dashboards, job assignment, technician job acceptance, live location tracking, offline tracking cache, Firebase push notifications, and location permission handling.

## 1. Big Picture

The app is organized by feature:

```text
lib/
  main.dart
  core/
    auth/
    config/
    network/
    routing/
    services/
    theme/
  features/
    auth/
    dashboards/
    jobs/
    notifications/
    permissions/
```

The pattern is roughly:

```text
Presentation screen
  -> Riverpod provider/controller
    -> API service or platform service
      -> PHP backend / Firebase / device GPS / local cache
```

Important libraries:

- `flutter_riverpod`: app state management and dependency injection.
- `http`: backend API calls.
- `firebase_core` and `firebase_messaging`: push notifications and FCM token handling.
- `flutter_local_notifications`: showing notifications while the app is open.
- `permission_handler`: location permission requests.
- `geolocator`: GPS location and position streams.
- `flutter_map` and `latlong2`: map display using tile providers instead of Google Maps.
- `shared_preferences`: offline tracking cache and pending location sync queue.
- `battery_plus`: technician battery state while tracking.

## 2. App Startup

Entry point: `lib/main.dart`

Startup flow:

```text
main()
  -> WidgetsFlutterBinding.ensureInitialized()
  -> Firebase.initializeApp()
  -> initialize local notifications
  -> create Android notification channel
  -> register Firebase background message handler
  -> request Firebase notification permission
  -> read FCM token
  -> listen for foreground/background notification clicks
  -> runApp(ProviderScope(child: MyApp()))
```

Why `ProviderScope` is used:

Riverpod providers only work inside a `ProviderScope`. This makes providers like `authProvider`, `loginProvider`, and `myJobsProvider` available throughout the app.

`MyApp` creates a `MaterialApp` whose `home` is `AppRouter`.

## 3. Routing And Role-Based Navigation

Main file: `lib/core/routing/app_routing.dart`

`AppRouter` watches `authProvider`.

If the user is not logged in:

```text
AppRouter -> LoginScreen
```

If the user is logged in:

```text
UserRole.admin      -> AdminDashboard
UserRole.manager    -> ManagerDashboard
UserRole.technician -> TechnicianDashboard
UserRole.user       -> UserDashboard
```

This means the app does not use a large named-route system for role navigation. Authentication state itself decides which dashboard is visible.

## 4. Authentication State

Files:

- `lib/core/auth/auth_state.dart`
- `lib/core/auth/auth_notifier.dart`
- `lib/core/auth/user_role.dart`

`AuthState` stores:

- `isAuthenticated`: whether the user is logged in.
- `role`: the parsed user role.
- `token`: backend API token.
- `logoutMessage`: optional state-driven message shown after forced logout.

`AuthNotifier` controls login/logout:

```text
login(role, token)
  -> state = authenticated
  -> ask Firebase Messaging permission
  -> get FCM token
  -> send FCM token to backend

logout()
  -> state = unauthenticated

invalidateSession()
  -> clear local session cache
  -> state = unauthenticated with forced logout message
```

Why this exists:

Every API feature needs the auth token. Every screen needs to know whether the user is logged in and which dashboard to show. Keeping that in `authProvider` gives one reliable source of truth.

## 5. API Base URL And Headers

Main file: `lib/core/config/app_api_config.dart`

`AppApiConfig` defines backend URL behavior.

Base URL candidates:

- Compile-time value: `--dart-define=API_BASE_URL=...`
- Debug Android emulator URL: `http://10.0.2.2/fsm_api`
- Debug local machine URL: `http://127.0.0.1/fsm_api`
- Release builds require an explicit HTTPS `API_BASE_URL`.

Important methods:

- `baseUrl`: currently uses the first candidate.
- `endpointUri(endpoint)`: builds the full endpoint URL.
- `buildHeaders(token)`: creates JSON headers and adds `Authorization: Bearer <token>` when available.

Why this exists:

The app talks to a PHP backend under `/fsm_api`. Centralizing base URL and headers prevents every service from manually building URLs and authorization headers.

## 6. Resilient HTTP Layer

Main file: `lib/core/network/resilient_http.dart`

`ResilientHttp` wraps `http.get` and `http.post`.

It retries on:

- Timeout
- Socket errors
- HTTP client errors
- Status codes `408`, `425`, `429`, `502`, `503`, `504`

Retry delays:

- 350 ms
- 900 ms

Why this exists:

Mobile networks and local XAMPP/live backends can be unstable. This layer avoids instantly failing on temporary connection problems.

It also acts as the app's global auth interceptor. When any API response returns:

```text
HTTP 401
ERR_SESSION_INVALIDATED: true
```

`ResilientHttp` notifies `authProvider`. `AuthNotifier.invalidateSession()` clears session-owned local cache and changes the state to unauthenticated with this message:

```text
Logged out: Your account was accessed on another device
```

`AppRouter` consumes that state. It clears any pushed navigation stack and shows the session-ended screen, so dashboards, job screens, maps, notifications, and tracking code do not need duplicated logout handling.

Backend contract:

- `auth/login.php` accepts `email`, `password`, and `device_id`.
- On successful login, the backend revokes older active tokens for that user with `revoked_reason = session_invalidated`.
- Protected PHP endpoints call `authenticate($pdo)` from `middleware/auth.php`.
- If an older revoked token is used, middleware returns `401` plus `ERR_SESSION_INVALIDATED: true`.
- Normal missing or malformed tokens still return regular `401` responses without the invalidation header.

## 7. Auth Feature

Main files:

- `lib/features/auth/data/auth_api_service.dart`
- `lib/features/auth/presentation/login_notifier.dart`
- `lib/features/auth/presentation/login_screen.dart`
- `lib/features/auth/presentation/forgot_password_notifier.dart`
- `lib/features/auth/presentation/forgot_password_screen.dart`
- `lib/features/auth/presentation/reset_password_screen.dart`

### Login Flow

```text
LoginScreen
  -> loginProvider.notifier.login(email, password)
    -> AuthApiService.login()
      -> create/read app-scoped device_id
      -> POST auth/login.php
      -> response JSON
    -> extract role from response
    -> extract token from response
    -> authProvider.notifier.login(role, token)
      -> AppRouter switches dashboard
```

`LoginNotifier` handles UI state:

- `loading`
- generic `error`
- `emailError`
- `passwordError`

It also maps backend role strings to the app enum:

```text
admin      -> UserRole.admin
manager    -> UserRole.manager
technician -> UserRole.technician
user       -> UserRole.user
customer   -> UserRole.user
```

### Forgot And Reset Password

```text
ForgotPasswordScreen
  -> ForgotPasswordNotifier.sendReset(email)
    -> AuthApiService.forgotPassword()
      -> POST auth/forgot_password.php
      -> returns debug token if backend provides it
  -> ResetPasswordScreen
    -> AuthApiService.resetPassword()
      -> POST auth/reset_password.php
```

## 8. Permissions Feature

Files:

- `lib/core/services/permission_service.dart`
- `lib/features/permissions/data/permission_repository.dart`
- `lib/features/permissions/application/permission_controller.dart`
- `lib/features/permissions/domain/permission_model.dart`
- `lib/features/permissions/presentation/permission_screen.dart`

Layer responsibilities:

- `PermissionService`: talks directly to `permission_handler`.
- `PermissionRepository`: converts plugin status into app status.
- `PermissionController`: simple application layer used by the screen.
- `PermissionScreen`: UI for requesting/opening permissions.

Location permission flow:

```text
PermissionScreen
  -> PermissionController.requestLocation()
    -> PermissionRepository.requestLocation()
      -> PermissionService.requestLocationPermissionStatus()
        -> Permission.locationWhenInUse.request()
        -> optionally Permission.locationAlways.request()
```

Why this exists:

Technician tracking cannot work without location permission. This feature separates device permission logic from UI.

## 9. Jobs Feature

Main files:

- `lib/features/jobs/data/job_api_service.dart`
- `lib/features/jobs/application/job_controller.dart`
- `lib/features/jobs/application/technician_tracking_service.dart`
- `lib/features/jobs/application/tracking_cache_store.dart`
- `lib/features/jobs/application/tracking_presence.dart`
- `lib/features/jobs/presentation/my_jobs_screen.dart`
- `lib/features/jobs/presentation/technician_locations_map_screen.dart`

### Job Providers

File: `lib/features/jobs/application/job_controller.dart`

Providers:

- `jobApiServiceProvider`: creates `JobApiService`.
- `myJobsProvider`: fetches technician jobs.
- `adminTechnicianLiveProvider`: fetches live technician locations.
- `adminTechnicianHistoryProvider`: fetches location history.
- `adminDashboardSummaryProvider`: fetches dashboard summary.
- `adminJobAssignmentsProvider`: fetches admin job list.
- `adminDeletedJobsProvider`: fetches deleted jobs.
- `technicianTrackingServiceProvider`: owns live GPS tracking.
- `jobActionControllerProvider`: exposes job actions to screens.

Why providers are used:

Screens should not directly construct API services. Providers let the UI watch async data, refresh it, invalidate it, and access the current auth token.

### Job API Endpoints

File: `lib/features/jobs/data/job_api_service.dart`

The service calls these backend endpoints:

```text
GET  jobs/get_my_jobs.php
POST jobs/accept.php
POST jobs/finish.php
POST tracking/update_location.php
GET  tracking/live_status.php
GET  jobs/list.php
GET  tracking/location_history.php
GET  jobs/admin_summary.php
GET  jobs/dashboard_summary.php
POST jobs/create.php
POST jobs/delete.php
POST jobs/soft_delete.php
POST jobs/archive.php
GET  jobs/deleted.php
GET  jobs/deleted_jobs.php
GET  jobs/list_deleted.php
```

Some actions have fallback endpoints because the backend may differ between installs. For example, soft delete tries `jobs/delete.php`, `jobs/soft_delete.php`, then `jobs/archive.php`.

### Technician Accept Job Flow

```text
TechnicianDashboard or MyJobsScreen
  -> jobActionControllerProvider.acceptJobAndShareLocation(jobId)
    -> request location permission
    -> verify device location service is enabled
    -> get current GPS position
    -> read battery level
    -> JobApiService.acceptJobWithLocation()
      -> POST jobs/accept.php
    -> TechnicianTrackingService.startTracking(jobId)
      -> subscribe to GPS stream
      -> send location updates
```

Why accept requires location:

The application treats accepting a job as the start of live technician tracking. It immediately records the technician's first known location.

### Technician Finish Job Flow

```text
TechnicianDashboard
  -> jobActionControllerProvider.finishJobAndStopTracking(jobId)
    -> JobApiService.finishJobAndStopTracking()
      -> POST jobs/finish.php
    -> TechnicianTrackingService.stopTracking(jobId)
      -> cancel GPS stream
      -> stop pending sync timer
```

### Live Tracking Flow

File: `lib/features/jobs/application/technician_tracking_service.dart`

```text
startTracking(jobId)
  -> stop any previous tracking
  -> set active job id
  -> start pending sync timer
  -> verify location service
  -> subscribe to Geolocator.getPositionStream()
  -> send last known/current position when available

on each position
  -> check accuracy
  -> check movement/time thresholds
  -> append point to local history cache
  -> read battery and charging state
  -> POST tracking/update_location.php
  -> if send fails, queue point for later sync
```

Send throttling rules:

- Fast moving technicians can send more often.
- Stationary technicians send less often.
- A heartbeat forces periodic updates even without much movement.
- Bad GPS accuracy is ignored.

Offline behavior:

If location upload fails, the point is saved in `shared_preferences` as pending sync. A timer retries pending locations every 30 seconds while tracking is active.

Battery behavior:

Battery percentage and charging state are included in location updates when available. If battery is below 20%, a local notification reminds the technician to charge.

### Tracking Cache

File: `lib/features/jobs/application/tracking_cache_store.dart`

Stores:

- Last live rows: `tracking_live_cache_v1`
- Location history: `tracking_history_cache_v1`
- Pending sync queue: `tracking_pending_sync_v1`

Limits:

- Live rows: 150
- History points: 1200
- Pending sync points: 300

Why this exists:

The map and tracking feature can still show recent data and replay unsent points after network problems.

### Tracking Presence

File: `lib/features/jobs/application/tracking_presence.dart`

This helper decides whether a technician is live/offline based on:

- Coordinates exist.
- Status is active or terminal.
- `is_tracking` flag.
- `updated_at` freshness.
- Whether row came from cache.

Freshness window:

```text
2 minutes
```

If the update is fresh, active, not terminal, and not cached, it is considered live.

## 10. Notifications Feature

Files:

- `lib/features/notifications/data/notification_api_service.dart`
- `lib/features/notifications/application/notification_controller.dart`

API endpoints:

```text
GET  notifications/list.php
GET  notifications/unread_count.php
POST notifications/mark_read.php
POST notifications/save_fcm_token.php
```

Flow after login:

```text
AuthNotifier.login()
  -> FirebaseMessaging.getToken()
  -> NotificationApiService.saveFcmToken()
    -> POST notifications/save_fcm_token.php
```

Notification providers:

- `notificationFeedProvider`: fetches recent notifications.
- `unreadNotificationCountProvider`: fetches unread count.
- `notificationPollingControllerProvider`: fetch latest/new notifications and marks read.

Admin and technician dashboards poll notifications periodically and can display snackbars or refresh data when new notifications arrive.

## 11. Dashboards

Files:

- `lib/features/dashboards/admin_dashboard.dart`
- `lib/features/dashboards/technician_dashboard.dart`
- `lib/features/dashboards/manager_dashboard.dart`
- `lib/features/dashboards/user_dashboard.dart`

### Admin Dashboard

The admin dashboard is the most complete dashboard.

It watches:

- `adminTechnicianLiveProvider`
- `adminDashboardSummaryProvider`
- `adminJobAssignmentsProvider`
- `adminDeletedJobsProvider`

Main features:

- Dashboard summary cards.
- Live technician tracking list.
- Open technician location map.
- Create job dialog.
- Job assignments list.
- Soft delete job with short undo timer.
- Deleted jobs section.
- Notification polling.
- Adaptive refresh for live data.
- Battery indicators.

Admin data flow:

```text
AdminDashboard
  -> watches providers
  -> providers call JobApiService
  -> service calls backend
  -> UI renders AsyncValue loading/error/data states
```

### Technician Dashboard

The technician dashboard watches `myJobsProvider`.

Main features:

- Shows assigned jobs.
- Accept job.
- Finish job.
- Starts/stops live location tracking.
- Polls notifications.
- Refreshes job list.
- Stops tracking on logout/dispose.

Technician data flow:

```text
TechnicianDashboard
  -> myJobsProvider
    -> JobApiService.getMyJobs()
  -> Accept button
    -> JobActionController.acceptJobAndShareLocation()
  -> Finish button
    -> JobActionController.finishJobAndStopTracking()
```

### Manager Dashboard

Currently mostly static UI.

It shows manager metrics and action buttons, but does not yet call backend APIs.

### User Dashboard

Currently mostly static UI.

It shows user request/payment widgets, but does not yet call backend APIs.

## 12. Map Screen

Main file: `lib/features/jobs/presentation/technician_locations_map_screen.dart`

Purpose:

- Show live technician locations.
- Show cached/offline history if live data is unavailable.
- Show technician path history.
- Fit the camera to markers.
- Allow map layer selection.

Data sources:

- `adminTechnicianLiveProvider`
- `adminTechnicianHistoryProvider`
- tracking cache from `TrackingCacheStore`

Map rendering:

- Uses `flutter_map`.
- Uses `latlong2` coordinates.
- Uses tile URLs instead of Google Maps API.

## 13. Data Flow Examples

### Login To Dashboard

```text
User enters email/password
  -> LoginScreen._submitLogin()
  -> LoginNotifier.login()
  -> AuthApiService.login()
  -> backend returns role/token
  -> LoginNotifier parses role/token
  -> AuthNotifier.login()
  -> authProvider state changes
  -> AppRouter rebuilds
  -> correct dashboard appears
```

### Admin Creates Job

```text
Admin opens create job dialog
  -> enters title and technician id
  -> AdminDashboard._createJob()
  -> JobActionController.createJob()
  -> JobApiService.createJob()
  -> POST jobs/create.php
  -> invalidate admin summary/live/jobs providers
  -> dashboard refetches fresh data
```

### Technician Location Update

```text
Technician accepts job
  -> app captures current GPS
  -> backend gets accept payload
  -> tracking service starts stream
  -> every useful GPS update:
       local history cache updated
       battery read
       POST tracking/update_location.php
       admin live provider invalidated
  -> admin dashboard/map refreshes live location
```

### Offline Location Sync

```text
GPS point generated
  -> API update fails
  -> point saved to pending queue
  -> flush timer runs every 30 seconds
  -> queued points are retried
  -> successful points removed from queue
```

## 14. Why The App Uses These Patterns

Riverpod:

Keeps app state testable and centralized. Screens can watch providers instead of manually passing data through constructors.

Feature folders:

Keeps auth, jobs, notifications, and permissions separate. This makes the app easier to grow.

API service classes:

Keep HTTP details out of widgets. Widgets should not know endpoint names or JSON parsing rules.

Controller/provider layer:

Coordinates multiple services. Example: accepting a job needs permission, GPS, battery, API, and tracking startup.

Local tracking cache:

Makes live tracking more reliable when network drops. This is important for mobile field apps.

Central API config:

Avoids scattered base URLs and duplicate authorization header logic.

## 15. Important Maintenance Notes

- `admin_dashboardoff.dart`, `technician_dashboardoff.dart`, and `login_screen0ff.dart` look like old/offline backup versions. They are not imported by the main router.
- `app_theme.dart` is empty, so the current app styling is defined inside individual screens.
- `README.md` is still the default Flutter README. This guide is the real application documentation.
- API response parsing is intentionally flexible. Many methods accept lists directly or maps containing `data`, `jobs`, `items`, or similar fields.
- Auth is stored only in memory. If the app restarts, the user must log in again unless persistence is added later.
- `AppApiConfig.baseUrl` returns the first candidate URL. In debug, local development URLs are available automatically. In release, the build must pass an HTTPS `API_BASE_URL`.

## 16. How To Run

Typical commands:

```bash
flutter pub get
flutter run
```

Run with a custom backend:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1/fsm_api
```

For Android emulator local backend:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2/fsm_api
```

Build production APK with live HTTPS backend:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://your-domain.com/fsm_api
```

## 17. Suggested Learning Order

1. Read `lib/main.dart` to understand startup.
2. Read `lib/core/routing/app_routing.dart` to understand role navigation.
3. Read `lib/core/auth/auth_state.dart` and `auth_notifier.dart` to understand session state.
4. Read `lib/features/auth/presentation/login_notifier.dart` and `auth_api_service.dart` to understand login.
5. Read `lib/features/jobs/application/job_controller.dart` to understand the main job use cases.
6. Read `lib/features/jobs/data/job_api_service.dart` to understand backend endpoints.
7. Read `lib/features/jobs/application/technician_tracking_service.dart` to understand live tracking.
8. Read `lib/features/dashboards/admin_dashboard.dart` and `technician_dashboard.dart` to understand UI behavior.
9. Read `lib/features/notifications/*` to understand FCM and notification polling.
10. Read `lib/features/permissions/*` to understand location permission flow.
