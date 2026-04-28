import 'package:fsm/features/permissions/data/permission_repository.dart';
import 'package:fsm/features/permissions/domain/permission_model.dart';

class PermissionController {
  final PermissionRepository _repo = PermissionRepository();

  Future<AppPermissionStatus> requestLocation() async {
    return await _repo.requestLocation();
  }

  Future<bool> checkPermission() async {
    return await _repo.hasPermission();
  }

  Future<void> openSettings() async {
    await _repo.openSettings();
  }
}
