// lib/features/home/services/notification_service.dart
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
  debugPrint('Background: ${message.notification?.title}');
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _fcm       = FirebaseMessaging.instance;
  final _firestore = FirebaseFirestore.instance;
  final _auth      = FirebaseAuth.instance;
  final _local     = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  StreamSubscription<String>?        _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedAppSub;
  StreamSubscription<User?>?         _authSub;

  static const _rideChannel = AndroidNotificationChannel(
    'ctsride_rides', 'Ride Updates',
    description: 'Ride requests and trip updates',
    importance:  Importance.max,
    playSound:   true,
  );
  static const _generalChannel = AndroidNotificationChannel(
    'ctsride_general', 'General Notifications',
    description: 'General app notifications',
    importance:  Importance.high,
    playSound:   true,
  );
  static const _paymentChannel = AndroidNotificationChannel(
    'ctsride_payments', 'Payment Notifications',
    description: 'Wallet and payment updates',
    importance:  Importance.high,
    playSound:   true,
  );

  Future<void> initialize(GlobalKey<NavigatorState> navigatorKey) async {
    if (_initialized) return;
    _initialized = true;
    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await _fcm.requestPermission(
        alert: true, badge: true, sound: true, provisional: false,
      );
      await _fcm.setForegroundNotificationPresentationOptions(
        alert: true, badge: true, sound: true,
      );
      await _initLocalNotifications(navigatorKey);
      _listenForeground();
      _listenTaps(navigatorKey);
      await _handleInitialMessage(navigatorKey);
      _authSub = _auth.authStateChanges().listen((user) async {
        if (user != null) await _saveToken();
      });
      _tokenRefreshSub = _fcm.onTokenRefresh.listen((token) async {
        if (_auth.currentUser != null) await _persistToken(token);
      });
      debugPrint('NotificationService ready');
    } catch (e) {
      _initialized = false;
      debugPrint('NotificationService failed: $e');
    }
  }

  Future<void> _initLocalNotifications(GlobalKey<NavigatorState> navigatorKey) async {
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        ),
      ),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final route = response.payload;
        if (route != null && route.isNotEmpty) {
          navigatorKey.currentState?.pushNamed(route);
        }
      },
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(_rideChannel);
      await android.createNotificationChannel(_generalChannel);
      await android.createNotificationChannel(_paymentChannel);
    }
  }

  void _listenForeground() {
    _foregroundSub = FirebaseMessaging.onMessage.listen((msg) async {
      final notif = msg.notification;
      if (notif == null) return;
      final channel = _channelForType(msg.data['type'] as String? ?? '');
      await _local.show(
        id: notif.hashCode,
        title: notif.title,
        body: notif.body,
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
        payload: msg.data['route'] as String?,
      );
    });
  }

  void _listenTaps(GlobalKey<NavigatorState> navigatorKey) {
    _openedAppSub = FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      _navigate(navigatorKey, msg.data['route'] as String?);
    });
  }

  Future<void> _handleInitialMessage(GlobalKey<NavigatorState> navigatorKey) async {
    final msg = await _fcm.getInitialMessage();
    if (msg == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigate(navigatorKey, msg.data['route'] as String?);
    });
  }

  void _navigate(GlobalKey<NavigatorState> nav, String? route) {
    if (route == null || route.isEmpty) return;

    // Notification payloads carry deep links like "/delivery-tracking?deliveryId=abc".
    // The route generator matches on PATH only and reads ids from `arguments`, so
    // split the query off and pass its params as arguments.
    final uri  = Uri.parse(route);
    final path = uri.path.isEmpty ? route : uri.path;
    final qp   = uri.queryParameters;

    final args = <String, dynamic>{
      if (qp['deliveryId'] != null) 'deliveryId': qp['deliveryId'],
      if (qp['rideId']     != null) 'rideId':     qp['rideId'],
      if (qp['orderId']    != null) 'orderId':    qp['orderId'],
      if (qp['tripId']     != null) 'tripId':     qp['tripId'],
    };

    nav.currentState?.pushNamed(
      path,
      arguments: args.isEmpty ? null : args,
    );
  }

  Future<void> _saveToken() async {
    try {
      final token = await _fcm.getToken();
      if (token != null) await _persistToken(token);
    } catch (e) {
      debugPrint('FCM token fetch failed: $e');
    }
  }

  Future<void> _persistToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('users').doc(uid).set({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      'platform': defaultTargetPlatform.name,
    }, SetOptions(merge: true));
    debugPrint('FCM token saved for uid: $uid');
  }

  Future<void> clearToken() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        await _firestore.collection('users').doc(uid).update({
          'fcmToken': FieldValue.delete(),
        });
      }
      await _fcm.deleteToken();
    } catch (e) {
      debugPrint('Token clear failed: $e');
    }
  }

  AndroidNotificationChannel _channelForType(String type) {
    switch (type) {
      case 'ride':
      case 'delivery':
        return _rideChannel;
      case 'wallet':
      case 'gas':
        return _paymentChannel;
      default:
        return _generalChannel;
    }
  }

  Future<void> dispose() async {
    await _foregroundSub?.cancel();
    await _openedAppSub?.cancel();
    await _tokenRefreshSub?.cancel();
    await _authSub?.cancel();
    _initialized = false;
  }
}
