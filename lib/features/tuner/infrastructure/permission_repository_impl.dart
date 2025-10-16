import 'package:permission_handler/permission_handler.dart' as ph;
import '../application/tuner_bloc.dart';

class PermissionRepositoryImpl implements PermissionRepository {
  const PermissionRepositoryImpl();

  @override
  Future<bool> hasMicPermission() async {
    final status = await ph.Permission.microphone.status;
    return status.isGranted;
  }

  @override
  Future<bool> requestMicPermission() async {
    final status = await ph.Permission.microphone.request();
    return status.isGranted;
  }

  @override
  Future<bool> isMicPermanentlyDenied() async {
    final status = await ph.Permission.microphone.status;
    return status.isPermanentlyDenied;
  }

  @override
  Future<bool> openAppSettings() async {
    return ph.openAppSettings();
  }
}
