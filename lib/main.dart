import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:fsm/core/routing/app_routing.dart';
import 'package:fsm/features/permissions/presentation/permission_screen.dart';
import 'package:fsm/features/dashboards/admin_dashboard.dart';

/// 🔔 Local notifications instance
final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

/// 🔥 Background handler
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("BG MESSAGE: ${message.notification?.title}");
}

/// 🔔 Setup notification channel
Future<void> _setupNotificationChannel() async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'default_channel',
    'Default Notifications',
    description: 'General notifications',
    importance: Importance.high,
  );

  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

/// 🔔 Initialize local notifications
Future<void> _initLocalNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings settings = InitializationSettings(
    android: androidSettings,
  );

  await _localNotifications.initialize(
  settings,
  onDidReceiveNotificationResponse: (response) {
    print("NOTIFICATION CLICKED (LOCAL)");
  },
);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /// 🔥 Firebase init
  await Firebase.initializeApp();

  /// 🔔 Local notification init
  await _initLocalNotifications();

  /// 🔔 Channel setup
  await _setupNotificationChannel();

  /// 🔥 Background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  /// 🔥 Permission
  await FirebaseMessaging.instance.requestPermission();

  /// 🔥 Token
  final token = await FirebaseMessaging.instance.getToken();
  print("FCM TOKEN: $token");

  /// 🔔 Foreground notification
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final notification = message.notification;

    if (notification != null) {
_localNotifications.show(
  notification.hashCode,
  notification.title,
  notification.body,
  const NotificationDetails(
    android: AndroidNotificationDetails(
      'default_channel',
      'Default Notifications',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
    ),
  ),
);
    }
  });

  /// 👆 Click (background → open)
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    print("NOTIFICATION CLICKED (BACKGROUND)");
  });

  /// 🚀 App opened from terminated state
  final initialMessage =
      await FirebaseMessaging.instance.getInitialMessage();

  if (initialMessage != null) {
    print("APP OPENED FROM TERMINATED VIA NOTIFICATION");
  }

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const AppRouter(),
      routes: {
        '/permissions': (_) => const PermissionScreen(),
        '/dashboard': (_) => const AdminDashboard(),
      },
    );
  }
}