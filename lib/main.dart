import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_number_picker/sim_number_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';

import 'APIServices.dart';
import 'Pages/AdminHomePage.dart';
import 'WebRTCHelper.dart';
import 'WebSocketHelper.dart';

class AudioStreamSender {
  final String websocketUrl;
  final Logger _logger = Logger('AudioStreamSender');
  FlutterSoundRecorder? _recorder;
  bool _isRecording = false;

  AudioStreamSender(this.websocketUrl);

  Future<void> init() async {
    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();
    _logger.info("Audio recorder initialized");
  }

  Future<void> startRecording() async {
    if (_isRecording) return;
    try {
      await _recorder!.startRecorder(
        toFile: 'Call_recording_${DateTime.now().millisecondsSinceEpoch}.m4a',
        codec: Codec.aacMP4,
      );
      _isRecording = true;
      _logger.info("Recording started");
    } catch (e) {
      _logger.severe("Error starting recording", e);
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder!.stopRecorder();
      _isRecording = false;
      _logger.info("Recording stopped");
    } catch (e) {
      _logger.severe("Error stopping recording", e);
    }
  }

  Future<void> dispose() async {
    if (_recorder != null) {
      await stopRecording();
      await _recorder!.closeRecorder();
      _recorder = null;
      _logger.info("AudioStreamSender disposed");
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    print("Flutter Error: ${details.exception}");
    if (details.stack != null) {
      print("Stack Trace: ${details.stack}");
    }
  };

  runZonedGuarded(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      print('${record.level.name}: ${record.time}: ${record.message}');
      if (record.error != null) print('Error: ${record.error}');
      if (record.stackTrace != null) print('Stack trace: ${record.stackTrace}');
    });

    await BackgroundService.initialize();
    await BackgroundService.start();

    runApp(const MyApp());
  }, (error, stackTrace) {
    print('Zoned Error: $error');
    print('Stack Trace: $stackTrace');
  });
}


// void main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   Logger.root.level = Level.ALL;
//
//   Logger.root.onRecord.listen((record) {
//     print('${record.level.name}: ${record.time}: ${record.message}');
//     if (record.error != null) {
//       print('Error: ${record.error}');
//     }
//     if (record.stackTrace != null) {
//       print('Stack trace: ${record.stackTrace}');
//     }
//   });
//
//   await BackgroundService.initialize();
//   await BackgroundService.start();
//   runApp(const MyApp());
// }

@pragma('vm:entry-point')
class BackgroundService {
  static final Logger _logger = Logger('BackgroundService');
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
  FlutterLocalNotificationsPlugin();
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static Future<void> initialize() async {
    try {
      await _initializeNotifications();

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
      InitializationSettings(android: initializationSettingsAndroid);

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
      try {
        await service.setForegroundNotificationInfo(
          title: "Call Listener Active",
          content: "Monitoring calls in background",
        );
        _logger.info("Foreground service notification set");
      } catch (e) {
        _logger.severe("Failed to set foreground notification", e);
        service.stopSelf();
        return;
      }
    }

    final callListener = BackgroundCallListener();
    await callListener.initialize();

    Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (service is AndroidServiceInstance) {
        await service.setForegroundNotificationInfo(
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
  String? _lastNumber;
  String? _lastContactName;
  bool _isIncomingCall = false;
  bool _apiCallSent = false;
  AudioStreamSender? _audioStreamSender;
  DateTime? callEndTime;

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
    await _phoneStateSubscription?.cancel();
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
      final displayNumber = formatPhoneNumber(number);
      final contactName = await getContactName(displayNumber);

      _logger.info('Phone state changed: $status - $displayNumber ($contactName)');

      switch (status) {
        case PhoneStateStatus.CALL_INCOMING:
          await handleIncomingCall(displayNumber, contactName);
          break;
        case PhoneStateStatus.CALL_STARTED:
          await handleCallStarted(displayNumber, contactName);
          break;
        case PhoneStateStatus.CALL_ENDED:
          await handleCallEnded(phoneState, displayNumber, contactName);
          break;
        case PhoneStateStatus.NOTHING:
          if (_isCallActive && !_apiCallSent) {
            await handleCallEnded(phoneState, displayNumber, contactName);
          }
          break;
      }
    } catch (e, stack) {
      _logger.severe('Error handling phone state', e, stack);
    }
  }

  Future<void> handleCallStarted(String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") {
      _logger.info("Skipping processing for unknown number");
      return;
    }
    _logger.info("=== CALL STARTED ===");
    _logger.info("Number: $displayNumber");
    _logger.info("Contact: $contactName");
    _apiCallSent = false;
    if (!_isCallActive) {
      _resetCallState();
      _callStartTime = DateTime.now();
      _lastNumber = displayNumber;
      _lastContactName = contactName;
      _currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      _isCallActive = true;
      _isIncomingCall = false;
      _logger.info("Call tracking started - Outgoing call");
      _logger.info("Start time: ${_callStartTime!.toIso8601String()}");
      _logger.info("Call ID: $_currentCallId");
      await _initializeAudioStreamSender();
      try {
        await _audioStreamSender?.startRecording();
        final myDisplayNumber = _phoneNumber;
        final senderNumber = myDisplayNumber;
        final receiverNumber = displayNumber;
        final audioFileUrl = await getAudioFileUrl(_currentCallId!);
        await WebSocketHelper.sendMessage({
          'type': 'call_started',
          'callId': _currentCallId,
          'senderNumber': senderNumber,
          'receiverNumber': receiverNumber,
          'contactName': contactName,
          'startTime': _callStartTime!.toIso8601String(),
          'timestamp': DateTime.now().toIso8601String(),
          'status': 'Active',
          'isIncoming': _isIncomingCall,
          'audio_file': audioFileUrl,
        });
        _logger.info("WebSocket call started message sent");
      } catch (e) {
        _logger.severe("Error sending call started notification: $e");
      }
    }
  }


  Future<bool?> _getUserRecordingStatus(String phoneNumber) async {
    try {
      final response = await API.getCallDetailsByNumber(phoneNumber);
      if (response != null && response.containsKey('recording')) {
        return response['recording'] == true;
      }
      return false;
    } catch (e) {
      _logger.severe('Error getting user recording status', e);
      return null;
    }
  }

  Future<void> handleCallEnded(
      PhoneState phoneState,
      String displayNumber,
      String contactName, {
        BuildContext? context,
        bool mounted = false,
      }) async {
    _logger.info('=== CALL ENDED ===');

    if (_callStartTime == null || !_isCallActive || _apiCallSent) {
      _logger.warning("No active call to end, missing call start time, or API call already sent");
      return;
    }

    try {
      final userRecordingStatus = await _getUserRecordingStatus(_phoneNumber);
      final shouldSendRecording = userRecordingStatus ?? false;
      callEndTime = DateTime.now();
      final duration = callEndTime!.difference(_callStartTime!);
      final durationInSeconds = duration.inSeconds;
      final finalContactName = _lastContactName ?? contactName;
      final finalNumber = _lastNumber ?? displayNumber;

      await _audioStreamSender?.stopRecording();

      final myDisplayNumber = _phoneNumber;
      final senderNumber = _isIncomingCall ? finalNumber : myDisplayNumber;
      final receiverNumber = _isIncomingCall ? myDisplayNumber : finalNumber;

      final callData = {
        'type': 'call_ended',
        'callId': _currentCallId,
        'senderNumber': senderNumber,
        'receiverNumber': receiverNumber,
        'contactName': finalContactName,
        'startTime': _callStartTime!.toIso8601String(),
        'endTime': callEndTime!.toIso8601String(),
        'duration': durationInSeconds,
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'Ended',
        'isIncoming': _isIncomingCall,
      };

      Future<void> safeSendWebSocketMessage(Map<String, dynamic> data) async {
        try {
          if (!WebSocketHelper.isConnected) {
            _logger.info("Attempting to reconnect WebSocket...");
            await WebSocketHelper.connect();
          }
          if (WebSocketHelper.isConnected) {
            await WebSocketHelper.sendMessage(data);
            _logger.info("WebSocket message sent successfully");
          } else {
            _logger.warning("Failed to send WebSocket message - connection not established");
          }
        } catch (e) {
          _logger.severe("Error sending WebSocket message", e);
        }
      }

      await safeSendWebSocketMessage(callData);

      if (shouldSendRecording) {
        try {
          await Future.delayed(const Duration(seconds: 2));
          final audioFile = await getLatestCallRecording();

          if (audioFile != null && await audioFile.exists()) {
            callData['audio_file'] = await getAudioFileUrl(_currentCallId!);
            await safeSendWebSocketMessage(callData);

            final success = await API.sendCallData(
              callId: _currentCallId!,
              senderNumber: senderNumber,
              receiverNumber: receiverNumber,
              callStartTime: _callStartTime!.toLocal(),
              duration: duration,
              audioFile: audioFile,
            ).timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                _logger.warning('API call timed out');
                return false;
              },
            );

            _handleApiCallResult(success, duration);
          } else {
            _logger.warning("Recording enabled but no audio file found");
            if (context != null && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Recording enabled but no audio file found"),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        } catch (e) {
          _logger.severe('Error processing recording', e);
          if (context != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Error processing recording: ${e.toString()}"),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } else {
        if (context != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Call data sent (recording disabled)"),
              backgroundColor: Colors.blue,
            ),
          );
        }
      }
    } catch (e) {
      _logger.severe('Error in handleCallEnded', e);
      if (context != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error ending call: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      await WebRTCHelper.cleanup();
      _resetCallVariables();
    }
  }


  void _resetCallVariables() {
    print("=== RESETTING CALL VARIABLES ===");
    _callStartTime = null;
    // callEndTime = null;
    _lastNumber = null;
    _lastContactName = null;
    _currentCallId = null;
    _isCallActive = false;
    _isIncomingCall = false;
    _apiCallSent = false;
    // _isLiveStreamActive = false;
    // callerInfo = "";
    // callStatus = "No active call";
    print("All call variables reset");
  }

  void _handleApiCallResult(
      bool success,
      Duration duration, {
        BuildContext? context,
        bool mounted = false,
      }) {
    _logger.info('API call completed with success: $success');

    if (context != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? "Call data sent successfully!\nDuration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}"
                : "Failed to send call data",
          ),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }



  Future<void> handleIncomingCall(String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") return;
    _logger.info("=== INCOMING CALL ===");
    _logger.info("Number: $displayNumber");
    _logger.info("Contact: $contactName");
    _apiCallSent = false;
    if (!_isCallActive) {
      _resetCallState();
      _callStartTime = DateTime.now();
      _lastNumber = displayNumber;
      _lastContactName = contactName;
      _currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      _isCallActive = true;
      _isIncomingCall = true;
      _logger.info("Call tracking started - Incoming call");
      _logger.info("Start time: ${_callStartTime!.toIso8601String()}");
      _logger.info("Call ID: $_currentCallId");
      await _initializeAudioStreamSender();
      try {
        final myDisplayNumber = _phoneNumber;
        final senderNumber = displayNumber;
        final receiverNumber = myDisplayNumber;
        final audioFileUrl = await getAudioFileUrl(_currentCallId!);
        await WebSocketHelper.sendMessage({
          'type': 'incoming_call',
          'callId': _currentCallId,
          'senderNumber': senderNumber,
          'receiverNumber': receiverNumber,
          'contactName': contactName,
          'startTime': _callStartTime!.toIso8601String(),
          'timestamp': DateTime.now().toIso8601String(),
          'status': 'Incoming',
          'isIncoming': _isIncomingCall,
          'audio_file': audioFileUrl,
        });
        _logger.info("WebSocket incoming call message sent");
      } catch (e) {
        _logger.severe("Error handling incoming call: $e");
      }
    }
  }

  Future<void> _initializeAudioStreamSender() async {
    try {
      _audioStreamSender = AudioStreamSender(
        'ws://192.168.1.6:8001/api/live_audio?callId=$_currentCallId',
      );
      await _audioStreamSender?.init();
    } catch (e) {
      _logger.severe("Error initializing AudioStreamSender: $e");
    }
  }

  Future<String> getContactName(String phoneNumber) async {
    if (phoneNumber.isEmpty || phoneNumber == "Unknown") {
      return "Unknown";
    }
    try {
      bool isGranted = await FlutterContacts.requestPermission();
      if (!isGranted) {
        _logger.warning("Contacts permission not granted");
        return "Unknown";
      }
      List<Contact> contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      for (var contact in contacts) {
        for (var phone in contact.phones) {
          String cleanedContactNumber = phone.number.replaceAll(RegExp(r'[^\d+]'), '');
          String cleanedIncomingNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
          if (cleanedContactNumber == cleanedIncomingNumber ||
              cleanedContactNumber.endsWith(
                cleanedIncomingNumber.substring(
                  cleanedIncomingNumber.length > 10 ? cleanedIncomingNumber.length - 10 : 0,
                ),
              ) ||
              cleanedIncomingNumber.endsWith(
                cleanedContactNumber.substring(
                  cleanedContactNumber.length > 10 ? cleanedContactNumber.length - 10 : 0,
                ),
              )) {
            _logger.info("Contact found: ${contact.displayName} for number: $phoneNumber");
            return contact.displayName;
          }
        }
      }
    } catch (e) {
      _logger.severe("Error fetching contacts: $e");
    }
    _logger.info("No contact found for number: $phoneNumber");
    return "Unknown";
  }

  Future<String> getAudioFileUrl(String callId) async {
    return "http://192.168.1.6:8001/media/audio_files/Call_recording_$callId.m4a";
  }

  Future<File?> getLatestCallRecording() async {
    try {
      if (Platform.isIOS) {
        _logger.info("iOS does not support accessing system call recordings.");
        return null;
      }

      _logger.info("🎙️ getLatestCallRecording() started");
      await Future.delayed(const Duration(seconds: 2));

      final possiblePaths = [
        '/storage/emulated/0/CallRecordings',
        '/storage/emulated/0/Recordings/CallRecordings',
        '/storage/emulated/0/MIUI/sound_recorder/call',
        '/storage/emulated/0/Recordings/Call',
        '/storage/emulated/0/Phone/Call',
        '/sdcard/Phone/Call',
        '/storage/emulated/0/Recordings',
        '/storage/emulated/0/DCIM/CallRecordings',
      ];

      final allowedExtensions = ['.mp3', '.mp4', '.m4a', '.3gp', '.aac', '.wav'];

      for (String path in possiblePaths) {
        try {
          final directory = Directory(path);
          _logger.info("🔍 Checking directory: $path");
          if (!await directory.exists()) {
            _logger.info("Directory does not exist: $path");
            continue;
          }

          final files = await directory
              .list(recursive: false)
              .where((entity) =>
          entity is File &&
              allowedExtensions.any((ext) =>
              entity.path.toLowerCase().endsWith(ext) &&
                  entity.path.contains('call') &&
                  entity.path.contains(_currentCallId ?? '')))
              .cast<File>()
              .toList();

          if (files.isEmpty) {
            _logger.info("No call recordings found in: $path");
            continue;
          }

          files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
          final latestFile = files.first;
          _logger.info("✅ Found latest recording: ${latestFile.path}");
          return latestFile;
        } catch (e) {
          _logger.warning('Error checking directory $path', e);
        }
      }

      _logger.warning("📭 No call recording files found in any accessible directory");
      return null;
    } catch (e, stackTrace) {
      _logger.severe('Error in getLatestCallRecording', e, stackTrace);
      return null;
    }
  }

  String formatPhoneNumber(String rawNumber) {
    if (rawNumber.isEmpty || rawNumber == "Unknown") {
      return "Unknown";
    }
    return rawNumber.replaceAll(RegExp(r'[^\d+]'), '');
  }

  void _resetCallState() {
    _logger.info("=== RESETTING CALL VARIABLES ===");
    _isCallActive = false;
    _callStartTime = null;
    _currentCallId = null;
    _lastNumber = null;
    _lastContactName = null;
    _isIncomingCall = false;
    _apiCallSent = false;
    _audioStreamSender?.dispose();
    _audioStreamSender = null;
    _logger.info("All call variables reset");
  }

  void dispose() {
    _phoneStateSubscription?.cancel();
    _phoneStateSubscription = null;
    _audioStreamSender?.dispose();
    _audioStreamSender = null;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const CallListenerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CallListenerPage extends StatefulWidget {
  const CallListenerPage({super.key});

  @override
  State<CallListenerPage> createState() => _CallListenerPageState();
}

class _CallListenerPageState extends State<CallListenerPage> with SingleTickerProviderStateMixin {
  final Logger _logger = Logger('CallListenerPage');
  String callStatus = "Initializing...";
  String callerInfo = "Unknown";
  List<String> callHistory = [];
  StreamSubscription<PhoneState>? _phoneStateSubscription;
  bool isListening = false;
  bool _isLiveStreamActive = false;
  DateTime? callStartTime;
  DateTime? callEndTime;
  String? lastNumber;
  String? lastContactName;
  String? currentCallId;
  bool isCallActive = false;
  bool isIncomingCall = false;
  bool _apiCallSent = false;
  AudioStreamSender? _audioStreamSender;
  bool _hasShownNumberSelectionPopup = false;
  String _phoneNumber = '';
  late AnimationController _animationController;
  late Animation<Color?> _colorAnimation;
  final TextEditingController _numberController = TextEditingController();

  @override
  void initState(){
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _colorAnimation = ColorTween(
      begin: Colors.orange,
      end: Colors.green,
    ).animate(_animationController);
    checkAndRequestPermissions();
    _loadPhoneNumberIntoLocalStorage();
    updateAppState();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _phoneStateSubscription?.cancel();
    _audioStreamSender?.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    _logger.info('Initializing application...');
    try {
      await checkAndRequestPermissions();
      await _loadPhoneNumberIntoLocalStorage();
      if (_phoneNumber.isNotEmpty) {
        await _checkUserAccess(_phoneNumber);
      }
      await initPhoneListener();
    } catch (e, stack) {
      _logger.severe('Error during initialization', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Initialization failed: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  bool _hasShownAccessGranted = false;

  Future<void> _checkUserAccess(String phoneNumber) async {
    try {
      final userDetails = await API.getCallDetailsByNumber(phoneNumber);
      if (userDetails == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to verify access. Please try again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final hasAccess = userDetails.containsKey('active') && userDetails['active'] == true;
      if (!hasAccess) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('You do not have access to use this app.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        await Future.delayed(const Duration(seconds: 2));
        SystemNavigator.pop();
      } else {
        if (mounted && !_hasShownAccessGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Access granted. Welcome!'),
              backgroundColor: Colors.green,
            ),
          );
          _hasShownAccessGranted = true;
        }
      }
    } catch (e) {
      print("Error checking user access: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error checking access: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<bool?> _getUserRecordingStatus(String phoneNumber) async {
    try {
      final response = await API.getCallDetailsByNumber(phoneNumber);
      if (response != null && response.containsKey('recording')) {
        return response['recording'] == true;
      }
      return false;
    } catch (e) {
      _logger.severe('Error getting user recording status', e);
      return null;
    }
  }

  void _handleApiCallResult(bool success, Duration duration) {
    _logger.info('API call completed with success: $success');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? "Call data sent successfully!\nDuration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}"
                : "Failed to send call data",
          ),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _cleanupResources() async {
    _logger.info('Cleaning up resources...');
    try {
      await _phoneStateSubscription?.cancel();
      _phoneStateSubscription = null;
      await _audioStreamSender?.dispose();
      _audioStreamSender = null;
      await WebRTCHelper.cleanup();
      await WebSocketHelper.disconnect();
      _resetCallVariables();
      _logger.info('Resource cleanup completed');
    } catch (e, stack) {
      _logger.severe('Error during cleanup', e, stack);
    }
  }

  Future<void> _loadPhoneNumberIntoLocalStorage() async {
    final pref = await SharedPreferences.getInstance();
    final storeNumber = pref.getString("my_phone_number");
    final hasShownPopup = pref.getBool("has_shown_number_popup") ?? false;
    setState(() {
      _hasShownNumberSelectionPopup = hasShownPopup;
    });
    if (storeNumber != null && storeNumber.isNotEmpty) {
      setState(() {
        _phoneNumber = storeNumber;
      });
      _logger.info("Loaded phone number from storage: $storeNumber");
    } else {
      _logger.info("No phone number found in storage, attempting to fetch...");
      await _fetchNumber();
    }
  }

  Future<void> _fetchNumber() async {
    try {
      _logger.info("Attempting to fetch phone number...");
      final result = await _getMyPhoneNumber();
      if (!mounted) return;
      if (result == null || result.isEmpty) {
        if (!_hasShownNumberSelectionPopup) {
          _logger.info("Showing phone number selection popup...");
          await _showPhoneNumberSelectionDialog();
        } else {
          _logger.info("Phone number popup already shown, skipping...");
        }
      } else {
        _logger.info("Phone number fetched successfully: $result");
        await _savePhoneNumber(result);
      }
    } catch (e) {
      _logger.severe("Error in _fetchNumber: $e");
      if (!_hasShownNumberSelectionPopup && mounted) {
        await _showPhoneNumberSelectionDialog();
      }
    }
  }

  Future<void> _showPhoneNumberSelectionDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        final TextEditingController phoneController = TextEditingController();
        return AlertDialog(
          title: const Text('Enter Phone Number'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Please enter your registered phone number to continue:'),
              const SizedBox(height: 16),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  hintText: '+91XXXXXXXXXX',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                SystemNavigator.pop();
              },
            ),
            TextButton(
              child: const Text('Save'),
              onPressed: () async {
                final phoneNumber = phoneController.text.trim();
                if (phoneNumber.isEmpty || !_isValidPhoneNumber(phoneNumber)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter a valid phone number.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }

                try {
                  final otpResponse = await API.sendOtp(phoneNumber);
                  if (otpResponse == null || otpResponse.containsKey('error')) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to send OTP: ${otpResponse?['error'] ?? 'Unknown error'}'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('OTP sent successfully'),
                      backgroundColor: Colors.green,
                    ),
                  );

                  final otp = await _showOtpInputDialog(phoneNumber);
                  if (otp == null || otp.isEmpty) return;

                  final verifyResponse = await API.verifyOtp(
                    phoneNumber: phoneNumber,
                    otp: otp,
                  );

                  if (verifyResponse == null || verifyResponse.containsKey('error')) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('OTP verification failed: ${verifyResponse?['error'] ?? 'Unknown error'}'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  await _checkUserAccess(phoneNumber);

                  await _savePhoneNumber(phoneNumber);
                  Navigator.of(context).pop();
                } catch (e) {
                  print("ERROR WHILE LOGIN: ${e.toString()}");
                  debugPrint("ERROR WHILE LOGIN: ${e.toString()}");
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error verifying number: ${e.toString()}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
            ),
          ],
        );
      },
    );
    await _markPopupAsShown();
  }

  Future<String?> _showOtpInputDialog(String phoneNumber) async {
    final otpController = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enter OTP'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('An OTP has been sent to $phoneNumber'),
              const SizedBox(height: 12),
              TextField(
                controller: otpController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'OTP',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final otp = otpController.text.trim();
                Navigator.of(context).pop(otp);
              },
              child: const Text('Verify'),
            ),
          ],
        );
      },
    );
  }

  bool _isValidPhoneNumber(String phoneNumber) {
    final pattern = r'^\+?[0-9]{10,15}$';
    final regExp = RegExp(pattern);
    return regExp.hasMatch(phoneNumber);
  }

  Future<void> _savePhoneNumber(String phoneNumber) async {
    try {
      final pref = await SharedPreferences.getInstance();
      await pref.setString("my_phone_number", phoneNumber);
      setState(() {
        _phoneNumber = phoneNumber;
      });
      print("Phone number saved: $phoneNumber");
      final userDetails = await API.getCallDetailsByNumber(phoneNumber);
      if (userDetails == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to verify access. Please try again.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      final hasAccess =
          userDetails.containsKey('active') && userDetails['active'] == true;
      if (hasAccess) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Phone number saved: $phoneNumber'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('You do not have access to use this app.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        await Future.delayed(const Duration(seconds: 2));
        SystemNavigator.pop();
      }
    } catch (e) {
      print("Error saving phone number: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving phone number: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _markPopupAsShown() async {
    try {
      final pref = await SharedPreferences.getInstance();
      await pref.setBool("has_shown_number_popup", true);
      setState(() {
        _hasShownNumberSelectionPopup = true;
      });
      _logger.info("Marked popup as shown");
    } catch (e) {
      _logger.severe("Error marking popup as shown: $e");
    }
  }

  Future<void> _initializeAudioStreamSender() async {
    try {
      _audioStreamSender = AudioStreamSender(
        'ws://192.168.1.6:8001/api/live_audio?callId=$currentCallId',
      );
      await _audioStreamSender?.init();
    } catch (e) {
      _logger.severe("Error initializing AudioStreamSender: $e");
    }
  }

  Future<String> getContactName(String phoneNumber) async {
    if (phoneNumber.isEmpty || phoneNumber == "Unknown") {
      return "Unknown";
    }
    try {
      bool isGranted = await FlutterContacts.requestPermission();
      if (!isGranted) {
        _logger.warning("Contacts permission not granted");
        return "Unknown";
      }
      List<Contact> contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      for (var contact in contacts) {
        for (var phone in contact.phones) {
          String cleanedContactNumber = phone.number.replaceAll(RegExp(r'[^\d+]'), '');
          String cleanedIncomingNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
          if (cleanedContactNumber == cleanedIncomingNumber ||
              cleanedContactNumber.endsWith(
                cleanedIncomingNumber.substring(
                  cleanedIncomingNumber.length > 10 ? cleanedIncomingNumber.length - 10 : 0,
                ),
              ) ||
              cleanedIncomingNumber.endsWith(
                cleanedContactNumber.substring(
                  cleanedContactNumber.length > 10 ? cleanedContactNumber.length - 10 : 0,
                ),
              )) {
            _logger.info("Contact found: ${contact.displayName} for number: $phoneNumber");
            return contact.displayName;
          }
        }
      }
    } catch (e) {
      _logger.severe("Error fetching contacts: $e");
    }
    _logger.info("No contact found for number: $phoneNumber");
    return "Unknown";
  }

  Future<void> handleIncomingCall(String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") return;
    _logger.info("=== INCOMING CALL ===");
    _logger.info("Number: $displayNumber");
    _logger.info("Contact: $contactName");
    _apiCallSent = false;
    if (!isCallActive) {
      _resetCallVariables();
      callStartTime = DateTime.now();
      callEndTime = null;
      lastNumber = displayNumber;
      lastContactName = contactName;
      currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      isCallActive = true;
      isIncomingCall = true;
      _logger.info("Call tracking started - Incoming call");
      _logger.info("Start time: ${callStartTime!.toIso8601String()}");
      _logger.info("Call ID: $currentCallId");
      await _initializeAudioStreamSender();
      await _initializeLiveStream();
      try {
        final myDisplayNumber = _phoneNumber;
        final senderNumber = displayNumber;
        final receiverNumber = myDisplayNumber;
        final audioFileUrl = await getAudioFileUrl(currentCallId!);
        await WebSocketHelper.sendMessage({
          'type': 'incoming_call',
          'callId': currentCallId,
          'senderNumber': senderNumber,
          'receiverNumber': receiverNumber,
          'contactName': contactName,
          'startTime': callStartTime!.toIso8601String(),
          'timestamp': DateTime.now().toIso8601String(),
          'status': 'Incoming',
          'isIncoming': isIncomingCall,
          'audio_file': audioFileUrl,
        });
        setState(() {
          callerInfo = contactName != "Unknown" ? contactName : displayNumber;
          callStatus = "INCOMING CALL!\nFrom: $callerInfo";
        });
        _logger.info("WebSocket incoming call message sent");
      } catch (e) {
        _logger.severe("Error handling incoming call: $e");
      }
    }
  }

  Future<void> handleCallStarted(String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") {
      _logger.info("Skipping processing for unknown number");
      return;
    }
    _logger.info("=== CALL STARTED ===");
    _logger.info("Number: $displayNumber");
    _logger.info("Contact: $contactName");
    _apiCallSent = false;
    if (!isCallActive) {
      _resetCallVariables();
      callStartTime = DateTime.now();
      callEndTime = null;
      lastNumber = displayNumber;
      lastContactName = contactName;
      currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      isCallActive = true;
      isIncomingCall = false;
      _logger.info("Call tracking started - Outgoing call");
      _logger.info("Start time: ${callStartTime!.toIso8601String()}");
      _logger.info("Call ID: $currentCallId");
      await _initializeAudioStreamSender();
      try {
        await _audioStreamSender?.startRecording();
        final myDisplayNumber = _phoneNumber;
        final senderNumber = myDisplayNumber;
        final receiverNumber = displayNumber;
        final audioFileUrl = await getAudioFileUrl(currentCallId!);
        await WebSocketHelper.sendMessage({
          'type': 'call_started',
          'callId': currentCallId,
          'senderNumber': senderNumber,
          'receiverNumber': receiverNumber,
          'contactName': contactName,
          'startTime': callStartTime!.toIso8601String(),
          'timestamp': DateTime.now().toIso8601String(),
          'status': 'Active',
          'isIncoming': isIncomingCall,
          'audio_file': audioFileUrl,
        });
        setState(() {
          callerInfo = contactName != "Unknown" ? contactName : displayNumber;
          callStatus = "CALL ACTIVE\nWith: $callerInfo";
        });
        _logger.info("WebSocket call started message sent");
      } catch (e) {
        _logger.severe("Error sending call started notification: $e");
      }
    }
  }

  Future<void> handleCallEnded(PhoneState phoneState, String displayNumber, String contactName) async {
    _logger.info('=== CALL ENDED ===');
    if (callStartTime == null || !isCallActive) {
      _logger.warning("No active call to end or missing call start time");
      return;
    }
    if (_apiCallSent) {
      _logger.warning("API call already sent, skipping duplicate");
      return;
    }
    setState(() {
      _apiCallSent = true;
    });
    try {
      final userRecordingStatus = await _getUserRecordingStatus(_phoneNumber);
      final shouldSendRecording = userRecordingStatus ?? false;
      callEndTime = DateTime.now();
      final duration = callEndTime!.difference(callStartTime!);
      final durationInSeconds = duration.inSeconds;
      final finalContactName = lastContactName ?? contactName;
      final finalNumber = lastNumber ?? displayNumber;

      await _audioStreamSender?.stopRecording();

      final myDisplayNumber = _phoneNumber;
      final senderNumber = isIncomingCall ? finalNumber : myDisplayNumber;
      final receiverNumber = isIncomingCall ? myDisplayNumber : finalNumber;

      final callData = {
        'type': 'call_ended',
        'callId': currentCallId,
        'senderNumber': senderNumber,
        'receiverNumber': receiverNumber,
        'contactName': finalContactName,
        'startTime': callStartTime!.toIso8601String(),
        'endTime': callEndTime!.toIso8601String(),
        'duration': durationInSeconds,
        'timestamp': DateTime.now().toIso8601String(),
        'status': 'Ended',
        'isIncoming': isIncomingCall,
      };

      try {
        if (!WebSocketHelper.isConnected) {
          _logger.info("Attempting to reconnect WebSocket...");
          await WebSocketHelper.connect();
        }
        if (WebSocketHelper.isConnected) {
          await WebSocketHelper.sendMessage(callData);
          _logger.info("WebSocket message sent successfully");
        }
      } catch (e) {
        _logger.severe("Error sending WebSocket message", e);
      }

      if (shouldSendRecording) {
        try {
          await Future.delayed(const Duration(seconds: 2));
          final audioFile = await getLatestCallRecording();
          if (audioFile != null && await audioFile.exists()) {
            callData['audio_file'] = await getAudioFileUrl(currentCallId!);
            await WebSocketHelper.sendMessage(callData);
            final success = await API.sendCallData(
              callId: currentCallId!,
              senderNumber: senderNumber,
              receiverNumber: receiverNumber,
              callStartTime: callStartTime!.toLocal(),
              duration: duration,
              audioFile: audioFile,
            ).timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                _logger.warning('API call timed out');
                return false;
              },
            );
            _handleApiCallResult(success, duration);
          } else {
            _logger.warning("Recording enabled but no audio file found");
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Recording enabled but no audio file found"),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          }
        } catch (e) {
          _logger.severe('Error processing recording', e);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Error processing recording: ${e.toString()}"),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Call data sent (recording disabled)"),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e, stack) {
      _logger.severe('Error in handleCallEnded', e, stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error ending call: ${e.toString()}"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      await WebRTCHelper.cleanup();
      _resetCallVariables();
    }
  }

  Future<void> _initializeLiveStream() async {
    try {
      _logger.info('Initializing live stream for call: $currentCallId');
      final channel = await WebSocketHelper.connect();
      if (channel == null) {
        throw Exception('Failed to establish WebSocket connection');
      }
      await WebRTCHelper.initializeCaller(currentCallId!, channel);
      setState(() {
        _isLiveStreamActive = true;
      });
      _logger.info('✅ Live stream initialized for call: $currentCallId');
    } catch (e, stack) {
      _logger.severe('❌ Error initializing live stream', e, stack);
      setState(() {
        _isLiveStreamActive = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start live stream: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void handlePhoneStateChange(PhoneState phoneState) async {
    try {
      final String rawNumber = phoneState.number ?? "Unknown";
      final PhoneStateStatus status = phoneState.status;
      final String displayNumber = formatPhoneNumber(rawNumber);
      final String contactName = await getContactName(displayNumber);
      updateCallUI(contactName, displayNumber, status);
      logCallEvent(status, contactName, displayNumber);
      _logger.info("=== PHONE STATE CHANGE ===");
      _logger.info("Status: $status");
      _logger.info("Number: $displayNumber");
      _logger.info("Contact: $contactName");
      _logger.info("Current call active: $isCallActive");
      switch (status) {
        case PhoneStateStatus.CALL_INCOMING:
          await handleIncomingCall(displayNumber, contactName);
          break;
        case PhoneStateStatus.CALL_STARTED:
          await handleCallStarted(displayNumber, contactName);
          break;
        case PhoneStateStatus.CALL_ENDED:
          await handleCallEnded(phoneState, displayNumber, contactName);
          break;
        case PhoneStateStatus.NOTHING:
          if (isCallActive && !_apiCallSent) {
            _logger.info("Call ended detected from NOTHING state");
            await handleCallEnded(phoneState, lastNumber ?? displayNumber, lastContactName ?? contactName);
          }
          break;
      }
    } catch (e, stack) {
      _logger.severe("Error handling phone state change: $e", stack);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error processing call: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _resetCallVariables() {
    _logger.info("=== RESETTING CALL VARIABLES ===");
    callStartTime = null;
    callEndTime = null;
    lastNumber = null;
    lastContactName = null;
    currentCallId = null;
    isCallActive = false;
    isIncomingCall = false;
    _apiCallSent = false;
    _isLiveStreamActive = false;
    callerInfo = "";
    callStatus = "No active call";
    _audioStreamSender?.dispose();
    _audioStreamSender = null;
    _logger.info("All call variables reset");
  }

  Future<String> getAudioFileUrl(String callId) async {
    return "http://192.168.1.6:8001/media/audio_files/Call_recording_$callId.m4a";
  }

  void updateCallUI(String contactName, String displayNumber, PhoneStateStatus status) {
    setState(() {
      callerInfo = contactName != "Unknown" ? contactName : displayNumber;
      callStatus = getCallStatusMessage(status, callerInfo);
      if (isListening) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  void logCallEvent(PhoneStateStatus status, String contactName, String displayNumber) {
    final timestamp = DateTime.now().toString().split('.')[0];
    final statusString = status.toString().split('.').last;
    final logMessage = "$timestamp - $statusString: ${contactName != "Unknown" ? contactName : displayNumber}";
    setState(() {
      callHistory.insert(0, logMessage);
      if (callHistory.length > 15) {
        callHistory.removeLast();
      }
    });
  }

  String formatPhoneNumber(String rawNumber) {
    if (rawNumber.isEmpty || rawNumber == "Unknown") {
      return "Unknown";
    }
    return rawNumber.replaceAll(RegExp(r'[^\d+]'), '');
  }

  String getCallStatusMessage(PhoneStateStatus status, String info) {
    switch (status) {
      case PhoneStateStatus.CALL_INCOMING:
        return "INCOMING CALL!\nFrom: $info";
      case PhoneStateStatus.CALL_STARTED:
        return "CALL ACTIVE\nWith: $info";
      case PhoneStateStatus.CALL_ENDED:
        return "CALL ENDED\nWas with: $info";
      case PhoneStateStatus.NOTHING:
        return "Listening for calls...";
      default:
        return "Unknown status";
    }
  }

  Future<void> updateAppState() async {
    bool hasPermissions = await _checkPermissions();
    if (_phoneNumber.isNotEmpty) {
      await _checkUserAccess(_phoneNumber);
    }
    setState(() {
      isListening = hasPermissions;
      callStatus = hasPermissions ? "Listening for calls..." : "Permissions not granted";
    });
  }

  Future<bool> _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.phone,
      Permission.contacts,
      if (Platform.isAndroid) Permission.manageExternalStorage,
    ].request();

    bool phonePermissionGranted = statuses[Permission.phone]!.isGranted;
    bool contactsPermissionGranted = statuses[Permission.contacts]!.isGranted;
    bool storagePermissionGranted =
    Platform.isAndroid ? statuses[Permission.manageExternalStorage]!.isGranted : true;
    // bool notificationPermissionGranted =
    // Platform.isAndroid && Platform.version >= 33
    //     ? statuses[Permission.notification]!.isGranted
    //     : true;

    return phonePermissionGranted &&
        contactsPermissionGranted &&
        storagePermissionGranted;
        // notificationPermissionGranted;
  }

  Future<void> checkAndRequestPermissions() async {
    try {
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        _logger.warning("Permissions not granted, requesting again...");
        hasPermissions = await _checkPermissions();
      }

      setState(() {
        isListening = hasPermissions;
        callStatus = hasPermissions
            ? "Listening for calls..."
            : "Permissions not granted. Please enable all required permissions.";
      });

      if (hasPermissions) {
        await initPhoneListener();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Please grant all required permissions in Settings."),
              backgroundColor: Colors.red,
              action: SnackBarAction(
                label: 'Open Settings',
                onPressed: openAppSettings,
              ),
            ),
          );
        }
      }
    } catch (e, stack) {
      _logger.severe("Error requesting permissions", e, stack);
      setState(() => callStatus = "Permission request failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Permission request failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> initPhoneListener() async {
    try {
      _logger.info("=== STARTING PHONE STATE LISTENER ===");
      setState(() {
        callStatus = "Starting listener...";
        isListening = false;
      });
      await _phoneStateSubscription?.cancel();
      _phoneStateSubscription = PhoneState.stream.listen(
            (PhoneState phoneState) {
          _logger.info("=== PHONE STATE RECEIVED ===");
          _logger.info("Status: ${phoneState.status}");
          _logger.info("Number: '${phoneState.number ?? 'null'}'");
          handlePhoneStateChange(phoneState);
        },
        onError: (error) {
          _logger.severe("=== PHONE STATE ERROR ===");
          _logger.severe("Error: $error");
          setState(() {
            callStatus = "Listener error: $error";
            isListening = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Listener error: $error"),
                backgroundColor: Colors.red,
              ),
            );
          }
        },
        onDone: () {
          _logger.info("=== PHONE STATE STREAM CLOSED ===");
          setState(() {
            callStatus = "Phone state stream closed";
            isListening = false;
          });
        },
      );
      setState(() {
        callStatus = "Listening for calls...";
        isListening = true;
      });
      _logger.info("=== LISTENER STARTED SUCCESSFULLY ===");
    } catch (e) {
      _logger.severe("=== ERROR STARTING LISTENER ===");
      _logger.severe("Error: $e");
      setState(() {
        callStatus = "Failed to start listener: $e";
        isListening = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to start listener: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<File?> getLatestCallRecording() async {
    try {
      if (Platform.isIOS) {
        _logger.info("iOS does not support accessing system call recordings.");
        return null;
      }

      _logger.info("🎙️ getLatestCallRecording() started");
      await Future.delayed(const Duration(seconds: 2));

      // First, let's scan all possible root directories
      final rootPaths = [
        '/storage/emulated/0',
        '/sdcard',
        '/storage/self/primary',
      ];

      final allowedExtensions = ['.mp3', '.mp4', '.m4a', '.3gp', '.aac', '.wav'];
      final namePrefixes = [
        'Call recording',
        'call recording',
        'Call_recording',
        'call_recording',
      ];

      // Comprehensive list of possible subdirectories where call recordings might be stored
      final possibleSubPaths = [
        'Phone/Call',
        'CallRecordings',
        'Recordings/CallRecordings',
        'Recordings/Call',
        'MIUI/sound_recorder/call',
        'Recordings',
        'Phone',
        'Call',
        'Audio/Call',
        'Music/Call',
        'Downloads/Call',
        'Documents/Call',
        'Samsung/CallRecording',
        'Xiaomi/CallRecording',
        'Huawei/CallRecording',
        'OnePlus/CallRecording',
        'DCIM/CallRecording', // Some phones store here
        'Android/data/com.android.dialer/files',
        'Android/data/com.samsung.android.dialer/files',
      ];

      List<String> allPossiblePaths = [];

      // Generate all combinations of root paths and sub paths
      for (final root in rootPaths) {
        for (final sub in possibleSubPaths) {
          allPossiblePaths.add('$root/$sub');
        }
        // Also check root directories directly
        allPossiblePaths.add(root);
      }

      _logger.info("🔍 Will check ${allPossiblePaths.length} possible directories");

      // First pass: Find directories that exist and log them
      List<Directory> existingDirs = [];
      for (final path in allPossiblePaths) {
        try {
          final directory = Directory(path);
          if (await directory.exists()) {
            existingDirs.add(directory);
            _logger.info("✅ Directory exists: $path");
          }
        } catch (e) {
          // Silently continue
        }
      }

      _logger.info("📁 Found ${existingDirs.length} existing directories");

      // Second pass: Search for call recording files in existing directories
      for (final directory in existingDirs) {
        try {
          _logger.info("🔍 Searching in: ${directory.path}");

          final entities = await directory.list().toList();
          final allFiles = entities.whereType<File>().toList();

          _logger.info("📄 Found ${allFiles.length} total files in ${directory.path}");

          // Log first few files to see naming patterns
          if (allFiles.isNotEmpty) {
            _logger.info("📋 Sample files in ${directory.path}:");
            for (int i = 0; i < math.min(5, allFiles.length); i++) {
              final fileName = allFiles[i].path.split('/').last;
              _logger.info("  - $fileName");
            }
          }

          final callRecordingFiles = allFiles.where((file) {
            final fileName = file.path.split('/').last;
            final fileNameLower = fileName.toLowerCase();

            // Check if file has allowed extension
            final extMatch = allowedExtensions.any((ext) => fileNameLower.endsWith(ext));

            // Check if file name contains call recording keywords (more flexible)
            final nameMatch = namePrefixes.any((prefix) =>
            fileName.contains(prefix) ||
                fileNameLower.contains(prefix.toLowerCase()) ||
                fileNameLower.contains('call') && fileNameLower.contains('record')
            );

            if (extMatch && nameMatch) {
              _logger.info("🎯 Found matching file: $fileName");
            }

            return extMatch && nameMatch;
          }).toList();

          _logger.info("🎙️ Found ${callRecordingFiles.length} call recording files in: ${directory.path}");

          if (callRecordingFiles.isNotEmpty) {
            // Sort by last modified time (newest first)
            callRecordingFiles.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
            final latestFile = callRecordingFiles.first;

            final fileSize = await latestFile.length();
            _logger.info("✅ Latest recording found: ${latestFile.path}");
            _logger.info("✅ File size: $fileSize bytes");
            _logger.info("✅ Last modified: ${latestFile.lastModifiedSync()}");

            return latestFile;
          }
        } catch (e, stackTrace) {
          _logger.warning('⚠️ Error searching directory ${directory.path}', e, stackTrace);
        }
      }

      // Third pass: Try to find any audio files that might be call recordings
      _logger.info("🔍 Third pass: Looking for any audio files with phone numbers in name");

      for (final directory in existingDirs) {
        try {
          final entities = await directory.list().toList();
          final audioFiles = entities.whereType<File>().where((file) {
            final fileName = file.path.split('/').last.toLowerCase();
            final hasAudioExt = allowedExtensions.any((ext) => fileName.endsWith(ext));

            // Look for files with phone number patterns
            final hasPhoneNumber = RegExp(r'[+]?\d{10,}').hasMatch(fileName);

            return hasAudioExt && hasPhoneNumber;
          }).toList();

          if (audioFiles.isNotEmpty) {
            _logger.info("🎵 Found ${audioFiles.length} audio files with phone numbers in: ${directory.path}");

            for (final file in audioFiles.take(3)) { // Log first 3 files
              final fileName = file.path.split('/').last;
              _logger.info("  📱 $fileName");
            }

            // Sort by last modified time and return the newest
            audioFiles.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
            final latestFile = audioFiles.first;

            _logger.info("✅ Latest audio file with phone number: ${latestFile.path}");
            return latestFile;
          }
        } catch (e) {
          // Continue searching
        }
      }

      _logger.warning("📭 No call recording files found in any accessible directory");
      return null;

    } catch (e, stackTrace) {
      _logger.severe('❌ Error in getLatestCallRecording', e, stackTrace);
      return null;
    }
  }

  Future<String?> _getMyPhoneNumber({bool forDisplay = false}) async {
    try {
      if (!Platform.isAndroid) {
        _logger.info("Not an Android device, returning default.");
        return forDisplay ? "My Number" : null;
      }
      var status = await Permission.phone.status;
      if (!status.isGranted) {
        status = await Permission.phone.request();
        if (!status.isGranted) {
          _logger.warning("Phone permission not granted");
          return forDisplay ? "My Number" : null;
        }
      }
      final plugin = SimNumberPicker();
      final number = await plugin.getPhoneNumberHint();
      if (number != null && number.isNotEmpty) {
        _logger.info("Original SIM Number: $number");
        String sanitized = number.replaceAll(RegExp(r'\s+|-'), '');
        sanitized = sanitized.replaceFirst(RegExp(r'^\+?\d{1,3}'), '+91');
        _logger.info("Modified SIM Number: $sanitized");
        return forDisplay ? "My Number" : sanitized;
      } else {
        _logger.warning("SIM number not available");
        return null;
      }
    } catch (e) {
      _logger.severe("Error getting my phone number: $e");
      return null;
    }
  }

  void restartListener() {
    _logger.info("=== RESTARTING LISTENER ===");
    setState(() {
      callStatus = "Restarting listener...";
      isListening = false;
    });
    _resetCallVariables();
    checkAndRequestPermissions();
  }

  void clearHistory() {
    setState(() {
      callerInfo = "Unknown";
      callStatus = "Listening for calls...";
      callHistory.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    _logger.info("isCallActive Checker: $isCallActive");
    return Scaffold(
      appBar: AppBar(
        title: const Text("Call Listener"),
        actions: [
          IconButton(
            onPressed:
                () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AdminHomePage(),
              ),
            ),
            icon: const Icon(Icons.login),
            tooltip: "Admin Login",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: restartListener,
            tooltip: "Restart Listener",
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: clearHistory,
            tooltip: "Clear History",
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedBuilder(
              animation: _colorAnimation,
              builder: (context, child) {
                return Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                  ),
                  color: _colorAnimation.value,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      children: [
                        Icon(
                          isListening ? Icons.phone : Icons.phone_disabled,
                          size: 60,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          callStatus,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 15),
                          child: Text(
                            "Caller: $callerInfo",
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        if (isCallActive && callStartTime != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: StreamBuilder(
                              stream: Stream.periodic(const Duration(seconds: 1)),
                              builder: (context, snapshot) {
                                if (callStartTime == null) return const SizedBox.shrink();
                                final duration = DateTime.now().difference(callStartTime!);
                                return Text(
                                  "Duration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}",
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                );
                              },
                            ),
                          ),
                        if (isCallActive)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Text(
                              "API Status: ${_apiCallSent ? 'Sent' : 'Pending'}",
                              style: TextStyle(
                                fontSize: 12,
                                color: _apiCallSent ? Colors.white : Colors.white70,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12.0),
                ),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "Call History",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: callHistory.isEmpty
                          ? const Center(child: Text("No call history yet."))
                          : ListView.builder(
                        itemCount: callHistory.length,
                        itemBuilder: (context, index) {
                          return ListTile(title: Text(callHistory[index]));
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}