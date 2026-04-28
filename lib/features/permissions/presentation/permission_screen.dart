import 'package:flutter/material.dart';
import 'package:fsm/features/permissions/application/permission_controller.dart';
import 'package:fsm/features/permissions/domain/permission_model.dart';

class PermissionScreen extends StatefulWidget {
  const PermissionScreen({super.key});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  final controller = PermissionController();
  bool loading = false;

  Future<void> requestPermission() async {
    setState(() => loading = true);

    final result = await controller.requestLocation();

    if (!mounted) return;
    setState(() => loading = false);

    if (result == AppPermissionStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission granted.')),
      );

      Navigator.pop(context);
      return;
    }

    if (result == AppPermissionStatus.permanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Location permission is permanently denied. Open settings to allow it.',
          ),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () {
              controller.openSettings();
            },
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location permission denied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Location Permission")),
      body: Center(
        child: loading
            ? const CircularProgressIndicator()
            : ElevatedButton(
                onPressed: requestPermission,
                child: const Text("Allow Location"),
              ),
      ),
    );
  }
}
