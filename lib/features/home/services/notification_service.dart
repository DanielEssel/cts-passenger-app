// lib/core/services/notification_service.dart

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📩 Background notification received: ${message.messageId}');
}

enum NotificationType {
  rideRequest,
  rideAccepted,
  rideArrived,
  tripStarted,
  tripCompleted,
  tripCancelled,
  payment,
  chat,
  general,
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  // ─────────────────────────────────────────────────────────────
  // Firebase & Plugin Instances
  // ─────────────────────────────────────────────────────────────
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();

  // ─────────────────────────────────────────────────────────────
  // Internal State & Subscriptions
  // ─────────────────────────────────────────────────────────────
  bool _initialized = false;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedAppSub;

  // ─────────────────────────────────────────────────────────────
  // Android Notification Channels
  // ─────────────────────────────────────────────────────────────
  static const AndroidNotificationChannel _generalChannel = AndroidNotificationChannel(
    'ctsride_general',
    'General Notifications',
    description: 'General app notifications',
    importance: Importance.high,
    playSound: true,
  );

  static const AndroidNotificationChannel _rideChannel = AndroidNotificationChannel(
    'ctsride_rides',
    'Ride Updates',
    description: 'Ride requests and trip updates',
    importance: Importance.max,
    playSound: true,
  );

  static const AndroidNotificationChannel _paymentChannel = AndroidNotificationChannel(
    'ctsride_payments',
    'Payment Notifications',
    description: 'Wallet and payment updates',
    importance: Importance.high,
    playSound: true,
  );

  // ─────────────────────────────────────────────────────────────
  // Initialization Lifecycle
  // ─────────────────────────────────────────────────────────────
  Future<void> initialize(GlobalKey<NavigatorState> navigatorKey) async {
    if (_initialized) return;
    _initialized = true;

    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      await _requestPermissions();
      await _initializeLocalNotifications(navigatorKey);

      await _fcm.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      _listenToForegroundMessages();
      _listenToNotificationTaps(navigatorKey);
      await _handleInitialMessage(navigatorKey);
      await _saveCurrentToken();
      _listenToTokenRefresh();

      debugPrint('✅ NotificationService initialized successfully');
    } catch (e, stack) {
      _initialized = false;
      debugPrint('❌ NotificationService initialization failed: $e');
      debugPrint(stack.toString());
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Hardware & Platform Permissions
  // ─────────────────────────────────────────────────────────────
  Future<void> _requestPermissions() async {
    final settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    debugPrint('🔔 Notification permission status: ${settings.authorizationStatus}');
  }

  // ─────────────────────────────────────────────────────────────
  // Local Notifications Engine
  // ─────────────────────────────────────────────────────────────
  Future<void> _initializeLocalNotifications(GlobalKey<NavigatorState> navigatorKey) async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _local.initialize(
  settings: settings,
  onDidReceiveNotificationResponse: (response) {
    final payload = response.payload;

    if (payload == null || payload.isEmpty) {
      return;
    }

    navigatorKey.currentState?.pushNamed(payload);
  },
);

    final androidPlugin = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(_generalChannel);
      await androidPlugin.createNotificationChannel(_rideChannel);
      await androidPlugin.createNotificationChannel(_paymentChannel);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Message Streams Handling (Foreground & Background Taps)
  // ─────────────────────────────────────────────────────────────
  void _listenToForegroundMessages() {
    _foregroundSub = FirebaseMessaging.onMessage.listen((message) async {
      try {
        debugPrint('📲 Foreground notification received: ${message.messageId}');
        await _showLocalNotification(message);
      } catch (e) {
        debugPrint('❌ Foreground notification parsing error: $e');
      }
    });
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    final type = _notificationTypeFromData(message.data['type']);
    final channel = _channelForType(type);

    await _local.show(
  id: notification.hashCode,
  title: notification.title,
  body: notification.body,
  notificationDetails: NotificationDetails(
    android: AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      icon: '@mipmap/ic_launcher',
    ),
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  ),
  payload: message.data['route'],
);
  }

  void _listenToNotificationTaps(GlobalKey<NavigatorState> navigatorKey) {
    _openedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _handleNavigation(navigatorKey, message.data);
    });
  }

  Future<void> _handleInitialMessage(GlobalKey<NavigatorState> navigatorKey) async {
    final message = await _fcm.getInitialMessage();
    if (message == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleNavigation(navigatorKey, message.data);
    });
  }

  void _handleNavigation(GlobalKey<NavigatorState> navigatorKey, Map<String, dynamic> data) {
    final route = data['route'] as String?;
    if (route == null || route.isEmpty) return;
    navigatorKey.currentState?.pushNamed(route);
  }

  // ─────────────────────────────────────────────────────────────
  // Device FCM Token Management
  // ─────────────────────────────────────────────────────────────
  Future<void> _saveCurrentToken() async {
    try {
      final token = await _fcm.getToken();
      if (token != null) await _persistToken(token);
    } catch (e) {
      debugPrint('❌ Failed to extract FCM token: $e');
    }
  }

  void _listenToTokenRefresh() {
    _tokenRefreshSub = _fcm.onTokenRefresh.listen((token) async {
      try {
        await _persistToken(token);
      } catch (e) {
        debugPrint('❌ Cloud token refresh synchronization failed: $e');
      }
    });
  }

  Future<void> _persistToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    await _firestore.collection('users').doc(uid).set({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      'platform': defaultTargetPlatform.name,
    }, SetOptions(merge: true));

    debugPrint('✅ FCM Device Registration Token persisted to Firestore target: $uid');
  }

  Future<void> clearToken() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;

      await _firestore.collection('users').doc(uid).set({
        'fcmToken': FieldValue.delete(),
      }, SetOptions(merge: true));

      await _fcm.deleteToken();
      debugPrint('🗑️ Server and hardware registration tokens successfully unregistered.');
    } catch (e) {
      debugPrint('❌ Cryptographic token removal handshake failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Structural Infrastructure Mappings & Parsers
  // ─────────────────────────────────────────────────────────────
  NotificationType _notificationTypeFromData(dynamic rawType) {
    switch (rawType) {
      case 'ride_request':   return NotificationType.rideRequest;
      case 'ride_accepted':  return NotificationType.rideAccepted;
      case 'ride_arrived':   return NotificationType.rideArrived;
      case 'trip_started':   return NotificationType.tripStarted;
      case 'trip_completed': return NotificationType.tripCompleted;
      case 'trip_cancelled': return NotificationType.tripCancelled;
      case 'payment':        return NotificationType.payment;
      case 'chat':           return NotificationType.chat;
      default:               return NotificationType.general;
    }
  }

  AndroidNotificationChannel _channelForType(NotificationType type) {
    switch (type) {
      case NotificationType.rideRequest:
      case NotificationType.rideAccepted:
      case NotificationType.rideArrived:
      case NotificationType.tripStarted:
      case NotificationType.tripCompleted:
      case NotificationType.tripCancelled:
        return _rideChannel;
      case NotificationType.payment:
        return _paymentChannel;
      default:
        return _generalChannel;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Stream Resource Deallocation
  // ─────────────────────────────────────────────────────────────
  Future<void> dispose() async {
    await _foregroundSub?.cancel();
    await _openedAppSub?.cancel();
    await _tokenRefreshSub?.cancel();
    _initialized = false;
  }
}