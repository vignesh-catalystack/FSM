import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'auth_state.dart';
import 'user_role.dart';
import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/features/notifications/data/notification_api_service.dart';

final authProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState.unauthenticated()) {
    _initTokenRefreshListener();
  }

  /// 🔁 Attach ONCE (constructor)
  void _initTokenRefreshListener() {
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      print("REFRESHED TOKEN: $newToken");

      final currentToken = state.token;

      if (currentToken != null) {
        try {
          final api = NotificationApiService(
            baseUrl: AppApiConfig.baseUrl,
          );

          await api.saveFcmToken(
            token: currentToken,
            fcmToken: newToken,
          );

          print("REFRESHED TOKEN SAVED");
        } catch (e) {
          print("REFRESH SAVE ERROR: $e");
        }
      }
    });
  }

  /// Called AFTER credentials are validated
  Future<void> login(UserRole role, {String? token}) async {
    state = AuthState.authenticated(role, token: token);

    try {
      await FirebaseMessaging.instance.requestPermission();

      final fcmToken = await FirebaseMessaging.instance.getToken();

      print("FCM TOKEN: $fcmToken");

      if (fcmToken != null && token != null) {
        final api = NotificationApiService(
          baseUrl: AppApiConfig.baseUrl,
        );

        await api.saveFcmToken(
          token: token,
          fcmToken: fcmToken,
        );

        print("TOKEN SAVED TO BACKEND");
      } else {
        print("TOKEN NULL");
      }
    } catch (e) {
      print("FCM ERROR: $e");
    }
  }

  void logout() {
    state = const AuthState.unauthenticated();
  }
}