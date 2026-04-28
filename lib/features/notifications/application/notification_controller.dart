import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fsm/core/auth/auth_notifier.dart';
import 'package:fsm/core/config/app_api_config.dart';
import 'package:fsm/features/notifications/data/notification_api_service.dart';

final notificationApiServiceProvider = Provider<NotificationApiService>(
  (ref) => NotificationApiService(baseUrl: AppApiConfig.baseUrl),
);

final notificationFeedProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(notificationApiServiceProvider);
    return api.fetchNotifications(token: authState.token, limit: 20);
  },
);

final unreadNotificationCountProvider = FutureProvider<int>(
  (ref) async {
    final authState = ref.watch(authProvider);
    final api = ref.read(notificationApiServiceProvider);
    return api.fetchUnreadCount(token: authState.token);
  },
);

final notificationPollingControllerProvider =
    Provider<NotificationPollingController>(
  (ref) => NotificationPollingController(ref),
);

class NotificationPollingController {
  NotificationPollingController(this.ref);

  final Ref ref;

  Future<List<Map<String, dynamic>>> fetchLatest({int limit = 1}) async {
    final authState = ref.read(authProvider);
    final api = ref.read(notificationApiServiceProvider);
    return api.fetchNotifications(token: authState.token, limit: limit);
  }

  Future<List<Map<String, dynamic>>> fetchNewSince(
      {required int lastId}) async {
    final authState = ref.read(authProvider);
    final api = ref.read(notificationApiServiceProvider);
    return api.fetchNotifications(
        token: authState.token, limit: 20, afterId: lastId);
  }

  Future<void> markAllRead() async {
    final authState = ref.read(authProvider);
    final api = ref.read(notificationApiServiceProvider);
    await api.markAllRead(token: authState.token);
  }
}
