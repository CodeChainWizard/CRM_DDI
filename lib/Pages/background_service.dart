// background_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:phone_state/phone_state.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

class BackgroundService {
  static final Logger _logger = Logger('BackgroundService');
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
  FlutterLocalNotificationsPlugin();
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static Future<void> initialize() async {
    try {
      // Initialize notifications first
      await _initializeNotifications();

      // Configure the background service
      final service = FlutterBackgroundService();
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: true,
          isForegroundMode: true,
          notificationChannelId: 'call_listener_channel',
          initialNotificationTitle: 'Call Listener',
          initialNotificationContent: 'Monitoring calls',
          foregroundServiceNotificationId: 888,
          // notificationChannelName: 'Call Listener',
          // notificationChannelDescription: 'Tracks incoming and outgoing calls',
          // notificationImportance: AndroidNotificationImportance.LOW,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: true,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
      );

      _logger.info('Background service initialized');
    } catch (e, stack) {
      _logger.severe('Failed to initialize background service', e, stack);
    }
  }

  static Future<void> _initializeNotifications() async {
    try {
      const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initializationSettings =
      InitializationSettings(
        android: initializationSettingsAndroid,
      );

      await _notificationsPlugin.initialize(initializationSettings);

      if (Platform.isAndroid) {
        const AndroidNotificationChannel channel = AndroidNotificationChannel(
          'call_listener_channel',
          'Call Listener',
          description: 'Channel for call monitoring service',
          importance: Importance.low,
        );

        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
      }
    } catch (e, stack) {
      _logger.severe('Failed to initialize notifications', e, stack);
    }
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {

    DartPluginRegistrant.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "Call Listener Active",
        content: "Monitoring calls in background",
      );
    }

    // Initialize call listener
    final callListener = BackgroundCallListener();
    await callListener.initialize();

    // Keep the service alive
    Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: "Call Listener Active",
          content: "Last active: ${DateTime.now()}",
        );
      }
    });

    service.on('stop').listen((event) {
      callListener.dispose();
      service.stopSelf();
    });
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  static Future<void> start() async {
    final service = FlutterBackgroundService();
    await service.startService();
  }

  static Future<bool> isRunning() async {
    try {
      return await _service.isRunning();
    } catch (e, stack) {
      _logger.severe('Failed to check service status', e, stack);
      return false;
    }
  }


  static Future<void> stop() async {
    try {
      if (await isRunning()) {
        _service.invoke('stop');
        _logger.info('Background service stop requested');

        // Verify service actually stopped
        await Future.doWhile(() async {
          await Future.delayed(const Duration(milliseconds: 100));
          return await isRunning();
        }).timeout(const Duration(seconds: 5));

        _logger.info('Background service confirmed stopped');
      }
    } catch (e, stack) {
      _logger.severe('Failed to stop background service', e, stack);
      rethrow;
    }
  }
}

class BackgroundCallListener {
  final Logger _logger = Logger('BackgroundCallListener');
  StreamSubscription<PhoneState>? _phoneStateSubscription;
  String _phoneNumber = '';
  bool _isCallActive = false;
  DateTime? _callStartTime;
  String? _currentCallId;

  Future<void> initialize() async {
    try {
      await _loadPhoneNumber();
      await _startPhoneStateListener();
      _logger.info('Background call listener initialized');
    } catch (e, stack) {
      _logger.severe('Failed to initialize call listener', e, stack);
    }
  }

  Future<void> _loadPhoneNumber() async {
    final prefs = await SharedPreferences.getInstance();
    _phoneNumber = prefs.getString('my_phone_number') ?? '';
    _logger.info('Loaded phone number: $_phoneNumber');
  }

  Future<void> _startPhoneStateListener() async {
    _phoneStateSubscription = PhoneState.stream.listen((phoneState) {
      _handlePhoneState(phoneState);
    }, onError: (error) {
      _logger.severe('Phone state error', error);
    });
  }

  Future<void> _handlePhoneState(PhoneState phoneState) async {
    try {
      final number = phoneState.number ?? 'Unknown';
      final status = phoneState.status;

      _logger.info('Phone state changed: $status - $number');

      switch (status) {
        case PhoneStateStatus.CALL_STARTED:
          await _handleCallStarted(number);
          break;
        case PhoneStateStatus.CALL_ENDED:
          await _handleCallEnded(number);
          break;
        case PhoneStateStatus.CALL_INCOMING:
          await _handleIncomingCall(number);
          break;
        case PhoneStateStatus.NOTHING:
          if (_isCallActive) {
            await _handleCallEnded(number);
          }
          break;
      }
    } catch (e, stack) {
      _logger.severe('Error handling phone state', e, stack);
    }
  }

  Future<void> _handleCallStarted(String number) async {
    _isCallActive = true;
    _callStartTime = DateTime.now();
    _currentCallId = 'call_${_callStartTime!.millisecondsSinceEpoch}';

    _logger.info('Call started with $number at $_callStartTime');

    // Here you would implement your call recording/logic
  }

  Future<void> _handleCallEnded(String number) async {
    if (!_isCallActive) return;

    final endTime = DateTime.now();
    final duration = endTime.difference(_callStartTime!);

    _logger.info('Call ended with $number, duration: $duration');

    // Here you would implement your call end processing
    // Send data to server, save recording, etc.

    _resetCallState();
  }

  Future<void> _handleIncomingCall(String number) async {
    _logger.info('Incoming call from $number');
    // Handle incoming call specific logic
  }

  void _resetCallState() {
    _isCallActive = false;
    _callStartTime = null;
    _currentCallId = null;
  }

  void dispose() {
    _phoneStateSubscription?.cancel();
    _phoneStateSubscription = null;
  }
}