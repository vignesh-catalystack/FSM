import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fsm/core/auth/auth_notifier.dart';
import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/core/services/permission_service.dart';
import 'package:fsm/features/jobs/data/job_api_service.dart';
import 'package:geolocator/geolocator.dart';

import 'technician_tracking_service.dart';

final jobApiServiceProvider = Provider<JobApiService>(
  (ref) => JobApiService(baseUrl: AppApiConfig.baseUrl),
);

final myJobsProvider = FutureProvider<List<dynamic>>((ref) async {
  final authState = ref.watch(authProvider);
  final api = ref.read(jobApiServiceProvider);
  return api.getMyJobs(token: authState.token);
});

final adminTechnicianLiveProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.getTechnicianLiveStatus(token: authState.token);
  },
);

final adminTechnicianHistoryProvider =
    FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.getTechnicianLocationHistory(token: authState.token);
  },
);

final adminDashboardSummaryProvider = FutureProvider<Map<String, dynamic>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.getAdminSummary(token: authState.token);
  },
);

final adminJobAssignmentsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.getAdminJobAssignments(token: authState.token);
  },
);

final adminDeletedJobsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.getDeletedJobs(token: authState.token);
  },
);

final technicianTrackingServiceProvider = Provider<TechnicianTrackingService>(
  (ref) {
    final service = TechnicianTrackingService(
      apiProvider: () => ref.read(jobApiServiceProvider),
      tokenProvider: () => ref.read(authProvider).token,
      onLocationSynced: () => ref.invalidate(adminTechnicianLiveProvider),
    );
    ref.onDispose(() {
      unawaited(service.dispose());
    });
    return service;
  },
);

final jobActionControllerProvider = Provider<JobActionController>(
  (ref) => JobActionController(ref),
);

class JobActionController {
  JobActionController(this.ref);

  final Ref ref;
  final PermissionService _permissionService = PermissionService();
  final Battery _battery = Battery();

  Future<({int? battery, int? isCharging})> _readBatterySnapshot() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final isCharging = (state == BatteryState.charging ||
              state == BatteryState.full)
          ? 1
          : 0;
      return (battery: level, isCharging: isCharging);
    } catch (_) {
      return (battery: null, isCharging: null);
    }
  }

  Future<Position> _resolveAcceptPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 8),
      );
    } on TimeoutException {
      final fallback = await Geolocator.getLastKnownPosition();
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  Future<String> acceptJobAndShareLocation({required int jobId}) async {
    final granted = await _permissionService.requestLocationPermission();
    if (!granted) {
      throw Exception('Location permission is required to accept a job.');
    }

    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      throw Exception('Please enable device location and try again.');
    }

    var geoPermission = await Geolocator.checkPermission();
    if (geoPermission == LocationPermission.denied) {
      geoPermission = await Geolocator.requestPermission();
    }

    if (geoPermission == LocationPermission.denied ||
        geoPermission == LocationPermission.deniedForever) {
      throw Exception('Location permission denied.');
    }

    Position position;
    try {
      position = await _resolveAcceptPosition();
    } on TimeoutException {
      throw Exception(
        'Unable to get current GPS quickly. Please move to open area and try again.',
      );
    }

    final authState = ref.read(authProvider);
    final api = ref.read(jobApiServiceProvider);
    final batteryInfo = await _readBatterySnapshot();

    final message = await api.acceptJobWithLocation(
      token: authState.token,
      jobId: jobId,
      latitude: position.latitude,
      longitude: position.longitude,
      battery: batteryInfo.battery,
      isCharging: batteryInfo.isCharging,
    );

    try {
      await ref
          .read(technicianTrackingServiceProvider)
          .startTracking(jobId: jobId);
    } catch (e) {
      return '$message Live tracking warning: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    return message;
  }

  Future<String> finishJobAndStopTracking({required int jobId}) async {
    final authState = ref.read(authProvider);
    final api = ref.read(jobApiServiceProvider);
    final message = await api.finishJobAndStopTracking(
      token: authState.token,
      jobId: jobId,
    );
    await ref
        .read(technicianTrackingServiceProvider)
        .stopTracking(jobId: jobId);
    return message;
  }

  Future<void> syncTrackingForActiveJob({required int? activeJobId}) async {
    final tracker = ref.read(technicianTrackingServiceProvider);
    try {
      if (activeJobId == null) {
        await tracker.stopTracking();
        return;
      }
      await tracker.startTracking(jobId: activeJobId);
    } catch (_) {
      // Dashboard sync should not block UI on transient location issues.
    }
  }

  Future<String> softDeleteJob({required int jobId}) async {
    final authState = ref.read(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.softDeleteJob(token: authState.token, jobId: jobId);
  }

  Future<String> createJob({
    required String title,
    required int technicianId,
  }) async {
    final authState = ref.read(authProvider);
    final api = ref.read(jobApiServiceProvider);
    return api.createJob(
      token: authState.token,
      title: title,
      technicianId: technicianId,
    );
  }
}
