import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  Future<PermissionStatus> requestLocationPermissionStatus({
    bool requireBackground = false,
  }) async {
    var status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      if (status.isPermanentlyDenied || status.isRestricted) {
        return PermissionStatus.permanentlyDenied;
      }
      return status;
    }

    if (!requireBackground) {
      return status;
    }

    status = await Permission.locationAlways.request();
    if (status.isPermanentlyDenied || status.isRestricted) {
      return PermissionStatus.permanentlyDenied;
    }
    return status;
  }

  /// Request foreground location. Optionally request background too.
  Future<bool> requestLocationPermission({
    bool requireBackground = false,
  }) async {
    final status = await requestLocationPermissionStatus(
      requireBackground: requireBackground,
    );
    return status.isGranted;
  }

  Future<PermissionStatus> locationPermissionStatus({
    bool requireBackground = false,
  }) async {
    final whenInUse = await Permission.locationWhenInUse.status;
    if (!whenInUse.isGranted) {
      if (whenInUse.isPermanentlyDenied || whenInUse.isRestricted) {
        return PermissionStatus.permanentlyDenied;
      }
      return whenInUse;
    }

    if (!requireBackground) return whenInUse;

    final always = await Permission.locationAlways.status;
    if (always.isPermanentlyDenied || always.isRestricted) {
      return PermissionStatus.permanentlyDenied;
    }
    return always;
  }

  /// Check permission
  Future<bool> hasLocationPermission({bool requireBackground = false}) async {
    final status = await locationPermissionStatus(
      requireBackground: requireBackground,
    );
    return status.isGranted;
  }

  /// Open settings manually
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
