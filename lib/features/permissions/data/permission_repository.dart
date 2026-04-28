import 'package:fsm/core/services/permission_service.dart';
import 'package:fsm/features/permissions/domain/permission_model.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionRepository {
  final PermissionService _service = PermissionService();

  Future<AppPermissionStatus> requestLocation() async {
    final status = await _service.requestLocationPermissionStatus();
    return _mapStatus(status);
  }

  Future<bool> hasPermission() async {
    return await _service.hasLocationPermission();
  }

  Future<void> openSettings() async {
    await _service.openSettings();
  }

  AppPermissionStatus _mapStatus(PermissionStatus status) {
    if (status.isGranted) return AppPermissionStatus.granted;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return AppPermissionStatus.permanentlyDenied;
    }
    return AppPermissionStatus.denied;
  }
}
