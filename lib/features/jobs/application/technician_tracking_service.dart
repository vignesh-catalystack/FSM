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

  // Single source of truth for the live accuracy gate.
  static const double _liveAccuracyGateMeters = 20.0;

  // Minimum distance a position must move before we store/send it.
  // Mirrors the simple app's minPathDistanceMeters = 8.
  static const double _minDistanceMeters = 8.0;

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

  bool _isFlushingPending = false;
  bool _disposed = false;

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

    // Use the same accuracy gate constant for the last-known position
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null && lastKnown.accuracy <= _liveAccuracyGateMeters) {
      unawaited(_onPosition(lastKnown, force: true));
    }

    unawaited(_flushPendingSync());

    try {
      final current = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
      await _onPosition(current, force: true);
    } catch (_) {}
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

    _lastSentPosition = null;
    _lastSentAt = null;

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
        distanceFilter: 3,
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

  Map<String, dynamic> _buildHistoryPoint(Position position, int jobId) {
    return <String, dynamic>{
      'job_id': jobId,
      'session_id': _activeSessionId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'heading': position.heading,
      'captured_at': position.timestamp.toIso8601String(),
      'source': 'device',
    };
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

    // Gate 1: accuracy — reject weak GPS
    if (!force && position.accuracy > _liveAccuracyGateMeters) return;

    // Gate 2: time throttle — at most one send per second
    if (!force &&
        _lastSentAt != null &&
        DateTime.now().difference(_lastSentAt!) < const Duration(seconds: 1)) {
      return;
    }

    // Gate 3: minimum distance — prevents micro-move flood that backend dedup rejects
    if (!force && _lastSentPosition != null) {
      final dist = _distanceBetween(
        _lastSentPosition!.latitude,
        _lastSentPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (dist < _minDistanceMeters) return;
    }

    // CRITICAL FIX: Ensure captured_at uses device time consistently
    final capturedAt = position.timestamp.toLocal();

    final historyPoint = <String, dynamic>{
      'job_id': activeJobId,
      'session_id': _activeSessionId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'heading': position.heading,
      'captured_at': capturedAt.toIso8601String(),  // Use local time
      'source': 'device',
      'technician_id': null,  // Will be filled by backend
    };

    // Append to local cache only for valid points
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
        await TrackingCacheStore.enqueuePendingSync(historyPoint);
      }
    }
  }
}