import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_notifier.dart'; // ✅ REQUIRED
import '../auth/user_role.dart';

import '../../features/auth/presentation/login_screen.dart';
import '../../features/dashboards/admin_dashboard.dart';
import '../../features/dashboards/manager_dashboard.dart';
import '../../features/dashboards/technician_dashboard.dart';
import '../../features/dashboards/user_dashboard.dart';

class AppRouter extends ConsumerWidget {
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    if (!authState.isAuthenticated) {
      return const LoginScreen();
    }

    switch (authState.role) {
      case UserRole.admin:
        return const AdminDashboard();
      case UserRole.manager:
        return const ManagerDashboard();


        
      case UserRole.technician:
        return const TechnicianDashboard();

        
      case UserRole.user:
        return const UserDashboard();
      default:
        return const LoginScreen();
    }
  }
  
}
