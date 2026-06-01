import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import 'package:fsm/features/jobs/application/tracking_cache_store.dart';
import 'package:fsm/features/jobs/data/job_api_service.dart';

class TechnicianTrackingService {
  static const Duration _pendingFlushInterval = Duration(seconds: 30);
  static const int _maxSyncBatchSize = 25;

  static const int _lowBatteryThreshold = 20;
  static const int _batteryNotificationId = 9001;
  static const Duration _batteryNotificationCooldown = Duration(minutes: 10);

  // ── GPS GATES ──────────────────────────────────────────────────────────────
  // Accuracy: reject anything worse than 20 m (same as map viewer).
  static const double _liveAccuracyGateMeters = 20.0;

  // Distance: don't store/send micro-moves.
  static const double _minDistanceMeters = 8.0;

  // Long-pause jump: if the GPS woke up after ≥2 min of silence AND
  // the new point is >80 m from the last sent point, reject it.
  // This prevents the "rest → bad wakeup spike" triangle on the route.
  static const Duration _pauseJumpWindow = Duration(minutes: 2);
  static const double _pauseJumpMaxMeters = 80.0;

  // Warm-up: how long to wait after startTracking before accepting the
  // very first point from the stream (lets GPS settle).
  static const Duration _gpsWarmupDuration = Duration(seconds: 6);

  TechnicianTrackingService({
    required this.apiProvider,
    required this.tokenProvider,
    this.onLocationSynced,
  });

  final JobApiService Function() apiProvider;
  final String? Function() tokenProvider;
  final VoidCallback? onLocationSynced;

  StreamSubscription<Position>? _positionSubscription;
  Timer? _pendingFlushTimer;

  int? _activeJobId;
  int? _activeSessionId;

  Position? _lastSentPosition;
  DateTime? _lastSentAt;
  DateTime? _trackingStartedAt;

  bool _isFlushingPending = false;
  bool _disposed = false;

  // Track the last stored DB point separately so offline route matches live.
  Position? _lastStoredPosition;

  final Battery _battery = Battery();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _notificationsInitialised = false;
  DateTime? _lastBatteryNotificationAt;

  int? get activeJobId => _activeJobId;
  int? get activeSessionId => _activeSessionId;
  bool get isTracking => _positionSubscription != null && _activeJobId != null;

  // ─────────────────────────────────────────────────────
  // NOTIFICATIONS
  // ─────────────────────────────────────────────────────

  Future<void> _initNotifications() async {
    if (_notificationsInitialised) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _notifications.initialize(initSettings);
    _notificationsInitialised = true;
  }

  Future<void> _maybeSendLowBatteryNotification(int batteryPercent) async {
    if (batteryPercent >= _lowBatteryThreshold) return;

    final now = DateTime.now();
    if (_lastBatteryNotificationAt != null &&
        now.difference(_lastBatteryNotificationAt!) <
            _batteryNotificationCooldown) {
      return;
    }

    await _initNotifications();
    _lastBatteryNotificationAt = now;

    const androidDetails = AndroidNotificationDetails(
      'battery_low_channel',
      'Battery alerts',
      channelDescription: 'Alerts when technician battery is low',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _notifications.show(
      _batteryNotificationId,
      'Battery low — $batteryPercent%',
      'Please charge your device to keep tracking active.',
      details,
    );
  }

  Future<({int? battery, int? isCharging})> _readBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final charging =
          (state == BatteryState.charging || state == BatteryState.full)
              ? 1
              : 0;
      unawaited(_maybeSendLowBatteryNotification(level));
      return (battery: level, isCharging: charging);
    } catch (_) {
      return (battery: null, isCharging: null);
    }
  }

  // ─────────────────────────────────────────────────────
  // TRACKING LIFECYCLE
  // ─────────────────────────────────────────────────────

  Future<void> startTracking({
    required int jobId,
    int? sessionId,
  }) async {
    if (_disposed) return;

    await stopTracking();

    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      throw Exception('Please enable location service for live tracking.');
    }

    _activeJobId = jobId;
    _activeSessionId = sessionId;
    _trackingStartedAt = DateTime.now();

    final settings = _resolveLocationSettings();

    _startPendingFlushTimer();

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (position) {
        unawaited(_onPosition(position));
      },
      onError: (_) {},
      cancelOnError: false,
    );

    // ── STARTUP FIX ───────────────────────────────────────────────────────
    // Do NOT push getLastKnownPosition here — it is stale (could be hours old)
    // and produces a long straight line from where the device was last.
    //
    // Instead, after the GPS warm-up window, request a fresh fix once.
    // This gives the device time to acquire satellites before the first
    // point is committed, so the marker appears at the real start position.
    Future.delayed(_gpsWarmupDuration, () async {
      if (_disposed || _activeJobId != jobId) return;
      try {
        final current = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 20),
        );
        // Accept this warm-up fix only if accuracy is good.
        if (current.accuracy <= _liveAccuracyGateMeters) {
          await _onPosition(current, force: true);
        }
      } catch (_) {
        // GPS unavailable — stream points will take over.
      }
    });

    unawaited(_flushPendingSync());
  }

  Future<void> stopTracking({int? jobId}) async {
    if (jobId != null && _activeJobId != null && jobId != _activeJobId) {
      return;
    }

    await _positionSubscription?.cancel();
    _positionSubscription = null;

    _pendingFlushTimer?.cancel();
    _pendingFlushTimer = null;

    _activeJobId = null;
    _activeSessionId = null;
    _trackingStartedAt = null;

    _lastSentPosition = null;
    _lastSentAt = null;
    _lastStoredPosition = null;

    _isFlushingPending = false;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopTracking();
  }

  // ─────────────────────────────────────────────────────
  // LOCATION SETTINGS
  // ─────────────────────────────────────────────────────

  LocationSettings _resolveLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 8,
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 8,
          intervalDuration: const Duration(seconds: 3),
          forceLocationManager: true,
        );

      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 8,
          pauseLocationUpdatesAutomatically: false,
          activityType: ActivityType.automotiveNavigation,
        );

      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 8,
        );
    }
  }

  // ─────────────────────────────────────────────────────
  // TIMER
  // ─────────────────────────────────────────────────────

  void _startPendingFlushTimer() {
    _pendingFlushTimer?.cancel();
    _pendingFlushTimer = Timer.periodic(
      _pendingFlushInterval,
      (_) {
        if (_disposed || _activeJobId == null) return;
        unawaited(_flushPendingSync());
      },
    );
  }

  // ─────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  /// Haversine distance in metres between two lat/lng points.
  double _distanceBetween(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.pow(math.sin(dLon / 2), 2) *
            math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  // ─────────────────────────────────────────────────────
  // PENDING FLUSH
  // ─────────────────────────────────────────────────────

  Future<void> _flushPendingSync() async {
    if (_disposed || _isFlushingPending) return;
    _isFlushingPending = true;

    try {
      final queue = await TrackingCacheStore.readPendingSync();
      if (queue.isEmpty) return;

      final batch = queue.take(_maxSyncBatchSize).toList();
      final untouched = queue.skip(_maxSyncBatchSize).toList();
      final remaining = <Map<String, dynamic>>[];

      for (var i = 0; i < batch.length; i++) {
        final item = batch[i];

        final parsedJobId = item['job_id'] is num
            ? (item['job_id'] as num).toInt()
            : int.tryParse('${item['job_id']}');

        final parsedSessionId = item['session_id'] is num
            ? (item['session_id'] as num).toInt()
            : int.tryParse('${item['session_id']}');

        final parsedLat = _asDouble(item['latitude']);
        final parsedLng = _asDouble(item['longitude']);

        if (parsedJobId == null || parsedLat == null || parsedLng == null) {
          continue;
        }

        try {
          await apiProvider()
              .trackLocation(
                token: tokenProvider(),
                jobId: parsedJobId,
                sessionId: parsedSessionId,
                latitude: parsedLat,
                longitude: parsedLng,
                accuracy: _asDouble(item['accuracy']),
                speed: _asDouble(item['speed']),
                heading: _asDouble(item['heading']),
              )
              .timeout(const Duration(seconds: 15));

          onLocationSynced?.call();
        } catch (e) {
          final error = e.toString().toLowerCase();
          final retryable = error.contains('timeout') ||
              error.contains('socket') ||
              error.contains('500');

          if (retryable) {
            remaining.add(item);
            if (i + 1 < batch.length) {
              remaining.addAll(batch.sublist(i + 1));
            }
          }

          break;
        }
      }

      await TrackingCacheStore.savePendingSync([
        ...remaining,
        ...untouched,
      ]);
    } finally {
      _isFlushingPending = false;
    }
  }

  // ─────────────────────────────────────────────────────
  // POSITION HANDLER
  // ─────────────────────────────────────────────────────

  Future<void> _onPosition(
    Position position, {
    bool force = false,
  }) async {
    if (_disposed) return;

    final activeJobId = _activeJobId;
    if (activeJobId == null) return;

    // ── GATE 1: accuracy — reject weak GPS ──────────────────────────────────
    if (!force && position.accuracy > _liveAccuracyGateMeters) return;

    // ── GATE 2: warm-up window ───────────────────────────────────────────────
    // Reject stream points that arrive before the GPS warm-up window expires.
    // The forced fix from getCurrentPosition bypasses this.
    if (!force && _trackingStartedAt != null) {
      final elapsed = DateTime.now().difference(_trackingStartedAt!);
      if (elapsed < _gpsWarmupDuration) return;
    }

    // ── GATE 3: time throttle — at most one send per second ──────────────────
    if (!force &&
        _lastSentAt != null &&
        DateTime.now().difference(_lastSentAt!) < const Duration(seconds: 1)) {
      return;
    }

    // ── GATE 4: minimum distance ─────────────────────────────────────────────
    if (!force && _lastSentPosition != null) {
      final dist = _distanceBetween(
        _lastSentPosition!.latitude,
        _lastSentPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (dist < _minDistanceMeters) return;
    }

    // ── GATE 5: long-pause jump filter ───────────────────────────────────────
    // If GPS was silent for ≥2 min (technician was resting) and the new point
    // is >80 m from the last stored point, it's a bad wakeup fix — reject.
    // This prevents "rest → spike → triangle" corruption in the route.
    if (!force && _lastSentAt != null && _lastSentPosition != null) {
      final gap = DateTime.now().difference(_lastSentAt!);
      if (gap >= _pauseJumpWindow) {
        final jump = _distanceBetween(
          _lastSentPosition!.latitude,
          _lastSentPosition!.longitude,
          position.latitude,
          position.longitude,
        );
        if (jump > _pauseJumpMaxMeters) {
          // Bad wakeup point — skip it. The next point (after GPS re-settles)
          // will be accepted if it passes the accuracy gate.
          return;
        }
      }
    }

    // ── ALL GATES PASSED ─────────────────────────────────────────────────────

    final capturedAt = position.timestamp.toLocal();

    final historyPoint = <String, dynamic>{
      'job_id': activeJobId,
      'session_id': _activeSessionId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'heading': position.heading,
      'captured_at': capturedAt.toIso8601String(),
      'source': 'device',
      'technician_id': null, // Filled by backend.
    };

    // Append to local cache so offline viewer shows the same route.
    unawaited(TrackingCacheStore.appendHistoryPoint(historyPoint));
    unawaited(_readBattery());

    try {
      await apiProvider()
          .trackLocation(
            token: tokenProvider(),
            jobId: activeJobId,
            sessionId: _activeSessionId,
            latitude: position.latitude,
            longitude: position.longitude,
            accuracy: position.accuracy,
            speed: position.speed,
            heading: position.heading,
          )
          .timeout(const Duration(seconds: 15));

      _lastSentPosition = position;
      _lastStoredPosition = position;
      _lastSentAt = DateTime.now();

      onLocationSynced?.call();

      if (!_isFlushingPending) {
        unawaited(_flushPendingSync());
      }
    } catch (e) {
      final error = e.toString().toLowerCase();
      final retryable = error.contains('timeout') ||
          error.contains('socket') ||
          error.contains('500');

      if (retryable) {
        // Still count this position as "last stored" so the distance
        // gate works correctly even when offline.
        _lastSentPosition = position;
        _lastStoredPosition = position;
        _lastSentAt = DateTime.now();
        await TrackingCacheStore.enqueuePendingSync(historyPoint);
      }
    }
  }
}