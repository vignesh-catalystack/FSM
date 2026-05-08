import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import 'package:fsm/features/jobs/application/tracking_cache_store.dart';
import 'package:fsm/features/jobs/data/job_api_service.dart';

class TechnicianTrackingService {
  static const Duration _pendingFlushInterval = Duration(seconds: 30);
  static const int _maxSyncBatchSize = 25;
  static const Duration _heartbeatInterval = Duration(seconds: 45);
  static const Duration _movingInterval = Duration(seconds: 4);
  static const Duration _fastMovingInterval = Duration(seconds: 2);
  static const Duration _stationaryInterval = Duration(seconds: 20);
  static const double _movingDistanceMeters = 8;
  static const double _stationaryDistanceMeters = 12;
  static const double _fastMovingDistanceMeters = 20;
  static const double _stationarySpeedThresholdMps = 1.2;
  static const double _fastSpeedThresholdMps = 8.0;

  // 🔋 Battery notification settings
  static const int _lowBatteryThreshold = 20;
  static const int _batteryNotificationId = 9001;
  static const Duration _batteryNotificationCooldown = Duration(minutes: 10);

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
  Position? _lastSentPosition;
  DateTime? _lastSentAt;
  Position? _queuedPosition;
  bool _isSending = false;
  bool _isFlushingPending = false;
  bool _disposed = false;

  // 🔋 Battery state
  final Battery _battery = Battery();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsInitialised = false;
  DateTime? _lastBatteryNotificationAt;

  int? get activeJobId => _activeJobId;
  bool get isTracking => _positionSubscription != null && _activeJobId != null;

  // ─── Notification setup ──────────────────────────────────────────────────

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

    // Cooldown — don't re-notify more often than every 10 minutes
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

  // ─── Battery reading ─────────────────────────────────────────────────────

  /// Returns {battery: int (0-100), isCharging: int (0|1)}.
  /// Returns null values if the platform doesn't support it.
  Future<({int? battery, int? isCharging})> _readBattery() async {
    try {
      final level = await _battery.batteryLevel; // 0–100
      final state = await _battery.batteryState;
      final charging = (state == BatteryState.charging ||
              state == BatteryState.full)
          ? 1
          : 0;

      // 🔔 Fire local notification if needed (non-blocking)
      unawaited(_maybeSendLowBatteryNotification(level));

      return (battery: level, isCharging: charging);
    } catch (_) {
      return (battery: null, isCharging: null);
    }
  }

  // ─── Tracking lifecycle ──────────────────────────────────────────────────

  Future<void> startTracking({required int jobId}) async {
    if (_disposed) return;
    if (_activeJobId == jobId && _positionSubscription != null) return;

    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      throw Exception('Please enable location service for live tracking.');
    }

    final settings = _resolveLocationSettings();
    await stopTracking();
    _activeJobId = jobId;
    _queuedPosition = null;
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

    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null) {
      unawaited(_onPosition(lastKnown, force: true));
    }

    unawaited(_flushPendingSync());

    try {
      final current = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 12),
      );
      await _onPosition(current, force: true);
    } catch (_) {}
  }

  Future<void> stopTracking({int? jobId}) async {
    if (jobId != null && _activeJobId != null && jobId != _activeJobId) return;

    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _pendingFlushTimer?.cancel();
    _pendingFlushTimer = null;
    _activeJobId = null;
    _lastSentPosition = null;
    _lastSentAt = null;
    _queuedPosition = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopTracking();
  }

  // ─── Internals ───────────────────────────────────────────────────────────

  LocationSettings _resolveLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          intervalDuration: const Duration(seconds: 8),
          forceLocationManager: false,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          pauseLocationUpdatesAutomatically: true,
          activityType: ActivityType.automotiveNavigation,
        );
      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        );
    }
  }

  void _startPendingFlushTimer() {
    _pendingFlushTimer?.cancel();
    _pendingFlushTimer = Timer.periodic(_pendingFlushInterval, (_) {
      if (_disposed || _activeJobId == null) return;
      unawaited(_flushPendingSync());
    });
  }

  bool _isAccurateEnough(Position position) {
    final accuracy = position.accuracy;
    if (accuracy.isNaN || accuracy.isInfinite) return false;
    final speed =
        position.speed.isFinite && position.speed > 0 ? position.speed : 0.0;
    if (speed >= _fastSpeedThresholdMps) return accuracy <= 45;
    if (speed <= _stationarySpeedThresholdMps) return accuracy <= 25;
    return accuracy <= 35;
  }

  bool _shouldSend(Position current) {
    final lastPos = _lastSentPosition;
    final lastAt = _lastSentAt;
    if (lastPos == null || lastAt == null) return true;

    final movedMeters = Geolocator.distanceBetween(
      lastPos.latitude,
      lastPos.longitude,
      current.latitude,
      current.longitude,
    );
    final elapsed = DateTime.now().difference(lastAt);
    final speed =
        current.speed.isFinite && current.speed > 0 ? current.speed : 0.0;
    final stationary = speed <= _stationarySpeedThresholdMps &&
        movedMeters < _movingDistanceMeters;

    if (elapsed >= _heartbeatInterval) return true;
    if (stationary) {
      if (movedMeters >= _stationaryDistanceMeters) return true;
      if (elapsed >= _stationaryInterval) return true;
      return false;
    }
    if (speed >= _fastSpeedThresholdMps) {
      if (movedMeters >= _fastMovingDistanceMeters) return true;
      if (elapsed >= _fastMovingInterval) return true;
      return false;
    }
    if (movedMeters >= _movingDistanceMeters) return true;
    if (elapsed >= _movingInterval) return true;
    return false;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  Map<String, dynamic> _buildHistoryPoint(Position position, int jobId) {
    return <String, dynamic>{
      'job_id': jobId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'heading': position.heading,
      'captured_at': position.timestamp.toIso8601String(),
      'source': 'device',
    };
  }

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
        final jobId = item['job_id'];
        final lat = item['latitude'];
        final lng = item['longitude'];
        final parsedLat = _asDouble(lat);
        final parsedLng = _asDouble(lng);
        final parsedJobId =
            jobId is num ? jobId.toInt() : int.tryParse('$jobId');
        if (parsedJobId == null || parsedLat == null || parsedLng == null) {
          continue;
        }

        try {
          await apiProvider().updateTechnicianLocation(
            token: tokenProvider(),
            jobId: parsedJobId,
            latitude: parsedLat,
            longitude: parsedLng,
            accuracy: _asDouble(item['accuracy']),
            speed: _asDouble(item['speed']),
            heading: _asDouble(item['heading']),
            capturedAt: DateTime.tryParse(
              item['captured_at']?.toString() ?? '',
            ),
            // 🔋 No battery data in offline replay
            battery: null,
            isCharging: null,
          );
          onLocationSynced?.call();
        } catch (_) {
          remaining.add(item);
          if (i + 1 < batch.length) {
            remaining.addAll(batch.sublist(i + 1));
          }
          break;
        }
      }

      await TrackingCacheStore.savePendingSync(<Map<String, dynamic>>[
        ...remaining,
        ...untouched,
      ]);
    } finally {
      _isFlushingPending = false;
    }
  }

  Future<void> _onPosition(Position position, {bool force = false}) async {
    if (_disposed) return;
    if (_isSending) {
      _queuedPosition = position;
      return;
    }
    final activeJobId = _activeJobId;
    if (activeJobId == null) return;

    if (!force) {
      if (!_isAccurateEnough(position)) return;
      if (!_shouldSend(position)) return;
    }

    final historyPoint = _buildHistoryPoint(position, activeJobId);
    await TrackingCacheStore.appendHistoryPoint(historyPoint);

    // 🔋 Read battery before sending
    final batteryInfo = await _readBattery();

    _isSending = true;
    try {
      await apiProvider().updateTechnicianLocation(
        token: tokenProvider(),
        jobId: activeJobId,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        speed: position.speed,
        heading: position.heading,
        capturedAt: position.timestamp,
        battery: batteryInfo.battery,
        isCharging: batteryInfo.isCharging,
      );

      _lastSentPosition = position;
      _lastSentAt = DateTime.now();
      onLocationSynced?.call();
      unawaited(_flushPendingSync());
    } catch (_) {
      await TrackingCacheStore.enqueuePendingSync(historyPoint);
    } finally {
      _isSending = false;
      final queued = _queuedPosition;
      _queuedPosition = null;
      if (queued != null && !_disposed) {
        unawaited(_onPosition(queued));
      }
    }
  }
}
