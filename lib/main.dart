import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sim_number_picker/sim_number_picker.dart';
import 'APIServices.dart';
import 'AudioStreamSender.dart';
import 'Pages/AdminHomePage.dart';
import 'WebRTCHelper.dart';
import 'WebSocketHelper.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.error != null) {
      print('Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('Stack trace: ${record.stackTrace}');
    }
  });
  runApp(const MyApp());
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

class _CallListenerPageState extends State<CallListenerPage>
    with SingleTickerProviderStateMixin {
  String callStatus = "Initializing...";
  String callerInfo = "Unknown";
  List<String> callHistory = [];
  StreamSubscription<PhoneState>? _phoneStateSubscription;
  bool isListening = false;
  bool _isLiveStreamActive = false;
  final Logger _logger = Logger('CallListenerPage');
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


  @override
  void initState() {
    super.initState();
    // WidgetsBinding.instance.addObserver(this as WidgetsBindingObserver);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _colorAnimation =
        ColorTween(begin: Colors.orange, end: Colors.green)
            .animate(_animationController);
    checkAndRequestPermissions();
    _loadPhoneNumberIntoLocalStorage();
  }

  @override
  void dispose() {
    // WidgetsBinding.instance.removeObserver(this as WidgetsBindingObserver);
    _animationController.dispose();
    _phoneStateSubscription?.cancel();
    _audioStreamSender?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initializeApp();
    } else if (state == AppLifecycleState.paused) {
      _cleanupResources();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _logger.info('Hot reload detected - cleaning up and reinitializing');
    _cleanupResources().then((_) => _initializeApp());
  }

  Future<void> _initializeApp() async {
    _logger.info('Initializing application...');
    try {
      await checkAndRequestPermissions();
      await _loadPhoneNumberIntoLocalStorage();
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

  Future<void> _cleanupResources() async {
    _logger.info('Cleaning up resources...');
    try {
      // Cancel and nullify all subscriptions
      await _phoneStateSubscription?.cancel();
      _phoneStateSubscription = null;

      // Dispose of audio resources
      await _audioStreamSender?.dispose();
      _audioStreamSender = null;

      // Clean up WebRTC and WebSocket connections
      await WebRTCHelper.cleanup();
      await WebSocketHelper.disconnect();

      // Reset all state variables
      _resetCallVariables();

      _logger.info('Resource cleanup completed');
    } catch (e, stack) {
      _logger.severe('Error during cleanup', e, stack);
    }
  }

  Future<void> _loadPhoneNumberIntoLocalStorage() async {
    final pref = await SharedPreferences.getInstance();
    final storeNumber = pref.getString("my_phone_number");
    if (storeNumber != null && storeNumber.isNotEmpty) {
      setState(() {
        _phoneNumber = storeNumber;
      });
    } else {
      _fetchNumber();
    }
  }

  void _fetchNumber() async {
    if (_hasShownNumberSelectionPopup) {
      return;
    }
    final result = await _getMyPhoneNumber();
    if (!mounted) return;
    if (result == null || result.isEmpty) {
      await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Select Phone Number'),
            content: const Text('Please select your phone number.'),
            actions: <Widget>[
              TextButton(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
      setState(() {
        _hasShownNumberSelectionPopup = true;
      });
    } else {
      setState(() async {
        final pref = await SharedPreferences.getInstance();
        pref.setString("my_phone_number", result);
        _phoneNumber = result;
      });
    }
  }

  Future<void> _initializeAudioStreamSender() async {
    try {
      _audioStreamSender = AudioStreamSender(
          'ws://192.168.1.3:8001/api/live_audio?callId=$currentCallId');
      await _audioStreamSender?.init();
    } catch (e) {
      print("Error initializing AudioStreamSender: $e");
    }
  }

  Future<String> getContactName(String phoneNumber) async {
    if (phoneNumber.isEmpty || phoneNumber == "Unknown") {
      return "Unknown";
    }
    try {
      bool isGranted = await FlutterContacts.requestPermission();
      if (!isGranted) {
        print("Contacts permission not granted");
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
              cleanedContactNumber.endsWith(cleanedIncomingNumber.substring(
                  cleanedIncomingNumber.length > 10
                      ? cleanedIncomingNumber.length - 10
                      : 0)) ||
              cleanedIncomingNumber.endsWith(cleanedContactNumber.substring(
                  cleanedContactNumber.length > 10
                      ? cleanedContactNumber.length - 10
                      : 0))) {
            print(
                "Contact found: ${contact.displayName} for number: $phoneNumber");
            return contact.displayName;
          }
        }
      }
    } catch (e) {
      print("Error fetching contacts: $e");
    }
    print("No contact found for number: $phoneNumber");
    return "Unknown";
  }

  Future<void> handleIncomingCall(
      String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") return;

    print("=== INCOMING CALL ===");
    print("Number: $displayNumber");
    print("Contact: $contactName");
    if (!isCallActive) {
      _resetCallVariables();
      callStartTime = DateTime.now();
      callEndTime = null;
      lastNumber = displayNumber;
      lastContactName = contactName;
      currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      isCallActive = true;
      isIncomingCall = true;
      _apiCallSent = false;
      print("Call tracking started - Incoming call");
      print("Start time: ${callStartTime!.toIso8601String()}");
      print("Call ID: $currentCallId");
      await _initializeAudioStreamSender();
      await _initializeLiveStream();
    }

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

      print("WebSocket incoming call message sent");
    } catch (e) {
      print("Error handling incoming call: $e");
    }
  }

  Future<void> handleCallStarted(
      String displayNumber, String contactName) async {
    if (displayNumber == "Unknown") {
      print("Skipping processing for unknown number");
      return;
    }

    print("=== CALL STARTED ===");
    print("Number: $displayNumber");
    print("Contact: $contactName");

    if (!isCallActive) {
      _resetCallVariables();
      callStartTime = DateTime.now();
      callEndTime = null;
      lastNumber = displayNumber;
      lastContactName = contactName;
      currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
      isCallActive = true;
      isIncomingCall = false;
      _apiCallSent = false;
      print("Call tracking started - Outgoing call");
      print("Start time: ${callStartTime!.toIso8601String()}");
      print("Call ID: $currentCallId");
      await _initializeAudioStreamSender();
    }

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

      print("WebSocket call started message sent");
    } catch (e) {
      print("Error sending call started notification: $e");
    }
  }

  Future<void> handleCallEnded(PhoneState phoneState, String displayNumber, String contactName) async {
    _logger.info('=== CALL ENDED ===');

    if (callStartTime == null || !isCallActive || _apiCallSent) {
      print(
          "ERROR: No active call to end, missing call start time, or API call already sent");
      print(
          "callStartTime: $callStartTime, isCallActive: $isCallActive, apiCallSent: $_apiCallSent");
      return;
    }


    print("isCallActive Checker: $isCallActive");
    callEndTime = DateTime.now();
    final duration = callEndTime!.difference(callStartTime!);
    final durationInSeconds = duration.inSeconds;
    final finalContactName = lastContactName ?? contactName;
    final finalNumber = lastNumber ?? displayNumber;

    print("=== CALL DURATION CALCULATION ===");
    print("Call Start Time: ${callStartTime!.toIso8601String()}");
    print("Call End Time: ${callEndTime!.toIso8601String()}");
    print("Total Duration: $durationInSeconds seconds");
    print("Final Contact Name: $finalContactName");
    print("Final Number: $finalNumber");

    try {
      await _audioStreamSender?.stopRecording();
      final myDisplayNumber = _phoneNumber;
      final senderNumber =
      isIncomingCall ? finalNumber : myDisplayNumber;
      final receiverNumber =
      isIncomingCall ? myDisplayNumber : finalNumber;

      await WebSocketHelper.sendMessage({
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
      });

      print("WebSocket call ended message sent");

      final audioFile = await getLatestCallRecording();
      if (audioFile != null && audioFile.existsSync()) {
        print("=== SENDING CALL DATA TO API ===");
        print("Audio file: ${audioFile.path}");

        final success = await API.sendCallData(
          callId: currentCallId ?? generateRandomCallId(),
          senderNumber: senderNumber,
          receiverNumber: receiverNumber,
          callStartTime: callStartTime!.toLocal(),
          duration: duration,
          audioFile: audioFile,
        ).timeout(Duration(seconds: 30), onTimeout: (){
          _logger.warning('API call timed out');
          return false;
        });

        _logger.info('API call completed with success: $success');
        print("API call result: $success");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(success
                  ? "Call data sent successfully!\nDuration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}"
                  : "Failed to send call data"),
              backgroundColor: success ? Colors.green : Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      print("ERROR: Exception in handleCallEnded: $e");
    } finally {
      await WebRTCHelper.cleanup();
      await Future.delayed(const Duration(milliseconds: 10));
      _resetCallVariables();
    }
  }

  String generateRandomCallId() {
    final random = Random();
    return '${DateTime.now().millisecondsSinceEpoch}_${random.nextInt(100000)}';
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

      print("=== PHONE STATE CHANGE ===");
      print("Status: $status");
      print("Number: $displayNumber");
      print("Contact: $contactName");
      print("Current call active: $isCallActive");

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
            print("Call ended detected from NOTHING state");
            await handleCallEnded(
                phoneState, lastNumber ?? displayNumber, lastContactName ?? contactName);
          }
          break;
      }
    } catch (e) {
      print("Error handling phone state change: $e");
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
    print("=== RESETTING CALL VARIABLES ===");
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


    print("All call variables reset");
  }

  Future<String> getAudioFileUrl(String callId) async {
    return "http://192.168.1.3:8001/media/audio_files/Call_recording_$callId.m4a";
  }

  void updateCallUI(
      String contactName, String displayNumber, PhoneStateStatus status) {
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
    final logMessage =
        "$timestamp - $statusString: ${contactName != "Unknown" ? contactName : displayNumber}";
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

  Future<void> checkAndRequestPermissions() async {
    try {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.phone,
        Permission.contacts,
        if (Platform.isAndroid) Permission.manageExternalStorage,
      ].request();

      if (!statuses[Permission.phone]!.isGranted) {
        setState(() => callStatus = "Phone permission denied.");
        if (statuses[Permission.phone]!.isPermanentlyDenied) openAppSettings();
        return;
      }
      if (!statuses[Permission.contacts]!.isGranted) {
        setState(() => callStatus = "Contacts permission denied.");
        if (statuses[Permission.contacts]!.isPermanentlyDenied) openAppSettings();
        return;
      }
      if (Platform.isAndroid &&
          !statuses[Permission.manageExternalStorage]!.isGranted) {
        setState(() => callStatus = "Storage permission denied.");
        if (statuses[Permission.manageExternalStorage]!.isPermanentlyDenied)
          openAppSettings();
        return;
      }
      await initPhoneListener();
    } catch (e) {
      print("Error requesting permissions: $e");
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
      print("=== STARTING PHONE STATE LISTENER ===");
      setState(() {
        callStatus = "Starting listener...";
        isListening = false;
      });
      await _phoneStateSubscription?.cancel();
      _phoneStateSubscription = PhoneState.stream.listen(
            (PhoneState phoneState) {
          print("=== PHONE STATE RECEIVED ===");
          print("Status: ${phoneState.status}");
          print("Number: '${phoneState.number ?? 'null'}'");
          handlePhoneStateChange(phoneState);
        },
        onError: (error) {
          print("=== PHONE STATE ERROR ===");
          print("Error: $error");
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
          print("=== PHONE STATE STREAM CLOSED ===");
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
      print("=== LISTENER STARTED SUCCESSFULLY ===");
    } catch (e) {
      print("=== ERROR STARTING LISTENER ===");
      print("Error: $e");
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
    if (Platform.isIOS) {
      print("iOS does not support accessing system call recordings.");
      setState(() {
        callStatus = "System call recording not supported on iOS.";
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("System call recording not supported on iOS."),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
    try {
      await Future.delayed(const Duration(seconds: 5));
      final today = DateTime.now();
      final possiblePaths = [
        '/storage/emulated/0/CallRecordings',
        '/storage/emulated/0/Recordings/CallRecordings',
        '/storage/emulated/0/MIUI/sound_recorder/call',
        '/storage/emulated/0/Recordings/Call',
        '/storage/emulated/0/Phone/Call',
        "/sdcard/Phone/Call"
      ];

      for (String path in possiblePaths) {
        final directory = Directory(path);
        print("Checking directory: $path");
        if (!await directory.exists()) {
          print("Directory does not exist: $path");
          continue;
        }
        final files = directory.listSync().whereType<File>().toList();
        if (files.isEmpty) {
          print("No files found in $path");
          continue;
        }
        final todayFiles = files.where((file) {
          final modified = file.lastModifiedSync();
          return modified.year == today.year &&
              modified.month == today.month &&
              modified.day == today.day;
        }).toList();
        if (todayFiles.isEmpty) {
          print("No files from today in $path");
          continue;
        }
        todayFiles.sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
        );
        final latestFile = todayFiles.first;
        if (callStartTime != null) {
          final fileModifiedTime = await latestFile.lastModified();
          final diffMinutes =
              fileModifiedTime.difference(callStartTime!).inMinutes;
          print("Time diff: $diffMinutes minutes");
          if (diffMinutes.abs() <= 5) {
            print("Matched recording file: ${latestFile.path}");
            return latestFile;
          } else {
            print("Latest file is from today but not within time range.");
          }
        }
        print("Returning today's latest recording: ${latestFile.path}");
        return latestFile;
      }
      print("No call recording found from today.");
      return null;
    } catch (e) {
      print("Error accessing call recordings: $e");
      return null;
    }
  }

  Future<String?> _getMyPhoneNumber({bool forDisplay = false}) async {
    try {
      if (!Platform.isAndroid) {
        print("Not an Android device, returning default.");
        return forDisplay ? "My Number" : null;
      }
      var status = await Permission.phone.status;
      if (!status.isGranted) {
        status = await Permission.phone.request();
        if (!status.isGranted) {
          print("Phone permission not granted");
          return forDisplay ? "My Number" : null;
        }
      }
      final plugin = SimNumberPicker();
      final number = await plugin.getPhoneNumberHint();
      if (number != null && number.isNotEmpty) {
        print("Original SIM Number: $number");
        String sanitized = number.replaceAll(RegExp(r'\s+|-'), '');
        sanitized = sanitized.replaceFirst(RegExp(r'^\+?\d{1,3}'), '+91');
        print("Modified SIM Number: $sanitized");
        return forDisplay ? "My Number" : sanitized;
      } else {
        print("SIM number not available");
        return forDisplay ? "My Number" : null;
      }
    } catch (e) {
      print("Error getting my phone number: $e");
      return forDisplay ? "My Number" : null;
    }
  }

  void restartListener() {
    print("=== RESTARTING LISTENER ===");
    setState(() {
      callStatus = "Restarting listener...";
      isListening = false;
    });
    _resetCallVariables(); // Reset call variables when restarting the listener
    checkAndRequestPermissions();
  }


  void clearHistory() {
    setState(() {
      callerInfo = "Unknown";
      callStatus = "Listening for calls...";
      callHistory.clear();
    });
  }

  Map<String, dynamic> getCallDebugInfo() {
    return {
      'isCallActive': isCallActive,
      'isIncomingCall': isIncomingCall,
      'apiCallSent': _apiCallSent,
      'callStartTime': callStartTime?.toIso8601String(),
      'callEndTime': callEndTime?.toIso8601String(),
      'lastNumber': lastNumber,
      'lastContactName': lastContactName,
      'currentCallId': currentCallId,
      'callerInfo': callerInfo,
      'isLiveStreamActive': _isLiveStreamActive,
    };
  }

  @override
  Widget build(BuildContext context) {
    print("isCallActive Checker: $isCallActive");
    return Scaffold(
      appBar: AppBar(
        title: const Text("Call Listener"),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const AdminHomePage()),
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
                                if (callStartTime == null)
                                  return const SizedBox.shrink();
                                final duration =
                                DateTime.now().difference(callStartTime!);
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
                                color: _apiCallSent
                                    ? Colors.white
                                    : Colors.white70,
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
                          ? const Center(
                        child: Text("No call history yet."),
                      )
                          : ListView.builder(
                        itemCount: callHistory.length,
                        itemBuilder: (context, index) {
                          return ListTile(
                            title: Text(callHistory[index]),
                          );
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












// import 'dart:math';
// import 'package:crm_new/Pages/AdminHomePage.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:logging/logging.dart';
// import 'package:phone_state/phone_state.dart';
// import 'package:permission_handler/permission_handler.dart';
// import 'package:flutter_contacts/flutter_contacts.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'package:sim_number_picker/sim_number_picker.dart';
// import 'dart:async';
// import 'dart:io';
// import 'APIServices.dart';
// import 'AudioStreamSender.dart';
// import 'WebRTCHelper.dart';
// import 'WebSocketHelper.dart';
//
// void main() {
//   Logger.root.level = Level.ALL;
//   Logger.root.onRecord.listen((record) {
//     print('${record.level.name}: ${record.time}: ${record.message}');
//     if (record.error != null) {
//       print('Error: ${record.error}');
//     }
//     if (record.stackTrace != null) {
//       print('Stack trace: ${record.stackTrace}');
//     }
//   });
//   runApp(const MyApp());
// }
//
// class MyApp extends StatelessWidget {
//   const MyApp({super.key});
//
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       theme: ThemeData(
//         primarySwatch: Colors.blue,
//         visualDensity: VisualDensity.adaptivePlatformDensity,
//       ),
//       home: const CallListenerPage(),
//       debugShowCheckedModeBanner: false,
//     );
//   }
// }
//
// class CallListenerPage extends StatefulWidget {
//   const CallListenerPage({super.key});
//
//   @override
//   State<CallListenerPage> createState() => _CallListenerPageState();
// }
//
// class _CallListenerPageState extends State<CallListenerPage> with SingleTickerProviderStateMixin {
//   String callStatus = "Initializing...";
//   String callerInfo = "Unknown";
//   List<String> callHistory = [];
//   StreamSubscription<PhoneState>? _phoneStateSubscription;
//   bool isListening = false;
//   bool _isLiveStreamActive = false;
//   final Logger _logger = Logger('CallListenerPage');
//
//   DateTime? callStartTime;
//   DateTime? callEndTime;
//   String? lastNumber;
//   String? lastContactName;
//   String? currentCallId;
//   bool isCallActive = false;
//   bool isIncomingCall = false;
//   bool _apiCallSent = false;
//   AudioStreamSender? _audioStreamSender;
//   bool _hasShownNumberSelectionPopup = false;
//   String _phoneNumber = '';
//
//   late AnimationController _animationController;
//   late Animation<Color?> _colorAnimation;
//
//   @override
//   void initState() {
//     super.initState();
//     _animationController = AnimationController(
//       vsync: this,
//       duration: const Duration(milliseconds: 500),
//     );
//     _colorAnimation = ColorTween(begin: Colors.orange, end: Colors.green)
//         .animate(_animationController);
//     checkAndRequestPermissions();
//     _loadPhoneNumberIntoLocalStorage();
//   }
//
//   @override
//   void dispose() {
//     _animationController.dispose();
//     _phoneStateSubscription?.cancel();
//     _audioStreamSender?.dispose();
//     super.dispose();
//   }
//
//   // Future<void> _loadPhoneNumberIntoLocalStorage() async {
//   //   final pref = await SharedPreferences.getInstance();
//   //   final storeNumber = pref.getString("my_phone_number");
//   //
//   //   if (storeNumber != null && storeNumber.isNotEmpty) {
//   //     final callDetails = await API.getCallDetailsByNumber(storeNumber);
//   //
//   //     if (callDetails != null && callDetails['active'] == true) {
//   //       setState(() {
//   //         _phoneNumber = storeNumber;
//   //       });
//   //     } else {
//   //       _showAccessDeniedDialog();
//   //     }
//   //   } else {
//   //     _fetchNumber();
//   //   }
//   // }
//   //
//   // void _showAccessDeniedDialog() {
//   //   showDialog(
//   //     context: context,
//   //     builder: (_) => AlertDialog(
//   //       title: const Text("Access Denied"),
//   //       content: const Text("You are not authorized to access this app."),
//   //       actions: [
//   //         TextButton(
//   //           onPressed: () {
//   //             Navigator.of(context).pop();
//   //             SystemNavigator.pop();
//   //           },
//   //           child: const Text("OK"),
//   //         ),
//   //       ],
//   //     ),
//   //   );
//   // }
//
//
//   Future<void> _loadPhoneNumberIntoLocalStorage() async{
//     final pref = await SharedPreferences.getInstance();
//     final storeNumber = pref.getString("my_phone_number");
//
//     if(storeNumber != null && storeNumber.isNotEmpty){
//       setState(() {
//         _phoneNumber = storeNumber;
//       });
//     }else{
//       _fetchNumber();
//     }
//   }
//
//   void _fetchNumber() async {
//     if (_hasShownNumberSelectionPopup) {
//       return;
//     }
//     final result = await _getMyPhoneNumber();
//     if (!mounted) return;
//     if (result == null || result.isEmpty) {
//       await showDialog(
//         context: context,
//         builder: (BuildContext context) {
//           return AlertDialog(
//             title: const Text('Select Phone Number'),
//             content: const Text('Please select your phone number.'),
//             actions: <Widget>[
//               TextButton(
//                 child: const Text('OK'),
//                 onPressed: () {
//                   Navigator.of(context).pop();
//                 },
//               ),
//             ],
//           );
//         },
//       );
//       setState(() {
//         _hasShownNumberSelectionPopup = true;
//       });
//     } else {
//       setState(() async{
//         final pref = await SharedPreferences.getInstance();
//         pref.setString("my_phone_number", result);
//         _phoneNumber = result;
//       });
//     }
//   }
//
//   Future<void> _initializeAudioStreamSender() async {
//     try {
//       _audioStreamSender =
//           AudioStreamSender('ws://192.168.1.3:8001/api/live_audio?callId=$currentCallId');
//       await _audioStreamSender?.init();
//     } catch (e) {
//       print("Error initializing AudioStreamSender: $e");
//     }
//   }
//
//   Future<String> getContactName(String phoneNumber) async {
//     if (phoneNumber.isEmpty || phoneNumber == "Unknown") {
//       return "Unknown";
//     }
//     try {
//       bool isGranted = await FlutterContacts.requestPermission();
//       if (!isGranted) {
//         print("Contacts permission not granted");
//         return "Unknown";
//       }
//       List<Contact> contacts = await FlutterContacts.getContacts(
//         withProperties: true,
//         withPhoto: false,
//       );
//       for (var contact in contacts) {
//         for (var phone in contact.phones) {
//           String cleanedContactNumber = phone.number.replaceAll(RegExp(r'[^\d+]'), '');
//           String cleanedIncomingNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
//           if (cleanedContactNumber == cleanedIncomingNumber ||
//               cleanedContactNumber.endsWith(cleanedIncomingNumber.substring(
//                   cleanedIncomingNumber.length > 10
//                       ? cleanedIncomingNumber.length - 10
//                       : 0)) ||
//               cleanedIncomingNumber.endsWith(cleanedContactNumber.substring(
//                   cleanedContactNumber.length > 10
//                       ? cleanedContactNumber.length - 10
//                       : 0))) {
//             print("Contact found: ${contact.displayName} for number: $phoneNumber");
//             return contact.displayName;
//           }
//         }
//       }
//     } catch (e) {
//       print("Error fetching contacts: $e");
//     }
//     print("No contact found for number: $phoneNumber");
//     return "Unknown";
//   }
//
//
//   Future<void> handleIncomingCall(String displayNumber, String contactName) async {
//     if (displayNumber == "Unknown") return;
//     print("=== INCOMING CALL ===");
//     print("Number: $displayNumber");
//     print("Contact: $contactName");
//     if (!isCallActive) {
//       _resetCallVariables();
//
//       callStartTime = DateTime.now();
//       callEndTime = null;
//       lastNumber = displayNumber;
//       lastContactName = contactName;
//       currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
//       isCallActive = true;
//       isIncomingCall = true;
//       _apiCallSent = false;
//       print("Call tracking started - Incoming call");
//       print("Start time: ${callStartTime!.toIso8601String()}");
//       print("Call ID: $currentCallId");
//       await _initializeAudioStreamSender();
//       await _initializeLiveStream();
//     }
//     try {
//       final myDisplayNumber = _phoneNumber;
//       final senderNumber = displayNumber;
//       final receiverNumber = myDisplayNumber;
//       final audioFileUrl = await getAudioFileUrl(currentCallId!);
//       await WebSocketHelper.sendMessage({
//         'type': 'incoming_call',
//         'callId': currentCallId,
//         'senderNumber': senderNumber,
//         'receiverNumber': receiverNumber,
//         'contactName': contactName,
//         'startTime': callStartTime!.toIso8601String(),
//         'timestamp': DateTime.now().toIso8601String(),
//         'status': 'Incoming',
//         'isIncoming': isIncomingCall,
//         'audio_file': audioFileUrl,
//       });
//       setState(() {
//         callerInfo = contactName != "Unknown" ? contactName : displayNumber;
//         callStatus = "INCOMING CALL!\nFrom: $callerInfo";
//       });
//       print("WebSocket incoming call message sent");
//     } catch (e) {
//       print("Error handling incoming call: $e");
//     }
//   }
//
//   Future<void> handleCallStarted(String displayNumber, String contactName) async {
//     if (displayNumber == "Unknown") {
//       print("Skipping processing for unknown number");
//       return;
//     }
//     print("=== CALL STARTED ===");
//     print("Number: $displayNumber");
//     print("Contact: $contactName");
//     if (!isCallActive) {
//
//       _resetCallVariables();
//
//       callStartTime = DateTime.now();
//       callEndTime = null;
//       lastNumber = displayNumber;
//       lastContactName = contactName;
//       currentCallId = DateTime.now().millisecondsSinceEpoch.toString();
//       isCallActive = true;
//       isIncomingCall = false;
//       _apiCallSent = false;
//       print("Call tracking started - Outgoing call");
//       print("Start time: ${callStartTime!.toIso8601String()}");
//       print("Call ID: $currentCallId");
//       await _initializeAudioStreamSender();
//     }
//     try {
//       await _audioStreamSender?.startRecording();
//       final myDisplayNumber = _phoneNumber;
//       final senderNumber = myDisplayNumber;
//       final receiverNumber = displayNumber;
//       final audioFileUrl = await getAudioFileUrl(currentCallId!);
//       await WebSocketHelper.sendMessage({
//         'type': 'call_started',
//         'callId': currentCallId,
//         'senderNumber': senderNumber,
//         'receiverNumber': receiverNumber,
//         'contactName': contactName,
//         'startTime': callStartTime!.toIso8601String(),
//         'timestamp': DateTime.now().toIso8601String(),
//         'status': 'Active',
//         'isIncoming': isIncomingCall,
//         'audio_file': audioFileUrl,
//       });
//       print("WebSocket call started message sent");
//     } catch (e) {
//       print("Error sending call started notification: $e");
//     }
//   }
//
//   Future<void> handleCallEnded(PhoneState phoneState, String displayNumber, String contactName) async {
//     _logger.info('=== CALL ENDED ===');
//
//     if (callStartTime == null || !isCallActive || _apiCallSent) {
//       print("ERROR: No active call to end, missing call start time, or API call already sent");
//       print("callStartTime: $callStartTime, isCallActive: $isCallActive, apiCallSent: $_apiCallSent");
//       return;
//     }
//
//     if(_apiCallSent){
//       print("API call already sent for this call, skipping duplicate");
//       return;
//     }
//
//     print("isCallActive Checker: $isCallActive");
//     callEndTime = DateTime.now();
//     final duration = callEndTime!.difference(callStartTime!);
//     final durationInSeconds = duration.inSeconds;
//     final finalContactName = lastContactName ?? contactName;
//     final finalNumber = lastNumber ?? displayNumber;
//
//     print("=== CALL DURATION CALCULATION ===");
//     print("Call Start Time: ${callStartTime!.toIso8601String()}");
//     print("Call End Time: ${callEndTime!.toIso8601String()}");
//     print("Total Duration: $durationInSeconds seconds");
//     print("Final Contact Name: $finalContactName");
//     print("Final Number: $finalNumber");
//
//     try {
//       await _audioStreamSender?.stopRecording();
//       final myDisplayNumber = _phoneNumber;
//       final senderNumber = isIncomingCall ? finalNumber : myDisplayNumber;
//       final receiverNumber = isIncomingCall ? myDisplayNumber : finalNumber;
//
//       await WebSocketHelper.sendMessage({
//         'type': 'call_ended',
//         'callId': currentCallId,
//         'senderNumber': senderNumber,
//         'receiverNumber': receiverNumber,
//         'contactName': finalContactName,
//         'startTime': callStartTime!.toIso8601String(),
//         'endTime': callEndTime!.toIso8601String(),
//         'duration': durationInSeconds,
//         'timestamp': DateTime.now().toIso8601String(),
//         'status': 'Ended',
//         'isIncoming': isIncomingCall,
//       });
//
//       print("WebSocket call ended message sent");
//
//       final audioFile = await getLatestCallRecording();
//       if (audioFile != null && audioFile.existsSync()) {
//         print("=== SENDING CALL DATA TO API ===");
//         print("Audio file: ${audioFile.path}");
//
//         _apiCallSent = true;
//
//         final success = await API.sendCallData(
//           callId: currentCallId ?? generateRandomCallId(),
//           senderNumber: senderNumber,
//           receiverNumber: receiverNumber,
//           callStartTime: callStartTime!.toLocal(),
//           duration: duration,
//           audioFile: audioFile,
//         );
//
//         _apiCallSent = true;
//
//         print("API call result: $success");
//         if (mounted) {
//           ScaffoldMessenger.of(context).showSnackBar(
//             SnackBar(
//               content: Text(success
//                   ? "Call data sent successfully!\nDuration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}"
//                   : "Failed to send call data"),
//               backgroundColor: success ? Colors.green : Colors.red,
//               duration: const Duration(seconds: 4),
//             ),
//           );
//         }
//       }
//     } catch (e) {
//       print("ERROR: Exception in handleCallEnded: $e");
//     } finally {
//       await WebRTCHelper.cleanup();
//       await Future.delayed(Duration(milliseconds: 10));
//       _resetCallVariables();
//     }
//   }
//
//   String generateRandomCallId() {
//     final random = Random();
//     return '${DateTime.now().millisecondsSinceEpoch}_${random.nextInt(100000)}';
//   }
//
//   Future<void> _initializeLiveStream() async {
//     try {
//       _logger.info('Initializing live stream for call: $currentCallId');
//       final channel = await WebSocketHelper.connect();
//       if (channel == null) {
//         throw Exception('Failed to establish WebSocket connection');
//       }
//       await WebRTCHelper.initializeCaller(currentCallId!, channel);
//       setState(() {
//         _isLiveStreamActive = true;
//       });
//       _logger.info('✅ Live stream initialized for call: $currentCallId');
//     } catch (e, stack) {
//       _logger.severe('❌ Error initializing live stream', e, stack);
//       setState(() {
//         _isLiveStreamActive = false;
//       });
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           SnackBar(
//             content: Text('Failed to start live stream: ${e.toString()}'),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//     }
//   }
//
//   void handlePhoneStateChange(PhoneState phoneState) async {
//     try {
//       final String rawNumber = phoneState.number ?? "Unknown";
//       final PhoneStateStatus status = phoneState.status;
//       final String displayNumber = formatPhoneNumber(rawNumber);
//       final String contactName = await getContactName(displayNumber);
//       updateCallUI(contactName, displayNumber, status);
//       logCallEvent(status, contactName, displayNumber);
//       print("=== PHONE STATE CHANGE ===");
//       print("Status: $status");
//       print("Number: $displayNumber");
//       print("Contact: $contactName");
//       print("Current call active: $isCallActive");
//       switch (status) {
//         case PhoneStateStatus.CALL_INCOMING:
//           await handleIncomingCall(displayNumber, contactName);
//           break;
//         case PhoneStateStatus.CALL_STARTED:
//           await handleCallStarted(displayNumber, contactName);
//           break;
//         case PhoneStateStatus.CALL_ENDED:
//           await handleCallEnded(phoneState, displayNumber, contactName);
//           break;
//         case PhoneStateStatus.NOTHING:
//           if (isCallActive && !_apiCallSent) {
//             print("Call ended detected from NOTHING state");
//             await handleCallEnded(
//                 phoneState, lastNumber ?? displayNumber, lastContactName ?? contactName);
//           }
//           break;
//         }
//     } catch (e) {
//       print("Error handling phone state change: $e");
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           SnackBar(
//             content: Text("Error processing call: $e"),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//     }
//   }
//
//   void _resetCallVariables() {
//     print("=== RESETTING CALL VARIABLES ===");
//     callStartTime = null;
//     callEndTime = null;
//     lastNumber = null;
//     lastContactName = null;
//     currentCallId = null;
//     isCallActive = false;
//     isIncomingCall = false;
//     _apiCallSent = false;
//     _isLiveStreamActive = false;
//     callerInfo = "";
//     callStatus = "No active call";
//     print("All call variables reset");
//   }
//
//   Future<String> getAudioFileUrl(String callId) async {
//     return "http://192.168.1.3:8001/media/audio_files/Call_recording_$callId.m4a";
//   }
//
//   void updateCallUI(String contactName, String displayNumber, PhoneStateStatus status) {
//     setState(() {
//       callerInfo = contactName != "Unknown" ? contactName : displayNumber;
//       callStatus = getCallStatusMessage(status, callerInfo);
//       if (isListening) {
//         _animationController.forward();
//       } else {
//         _animationController.reverse();
//       }
//     });
//   }
//
//   void logCallEvent(PhoneStateStatus status, String contactName, String displayNumber) {
//     final timestamp = DateTime.now().toString().split('.')[0];
//     final statusString = status.toString().split('.').last;
//     final logMessage = "$timestamp - $statusString: ${contactName != "Unknown" ? contactName : displayNumber}";
//     setState(() {
//       callHistory.insert(0, logMessage);
//       if (callHistory.length > 15) {
//         callHistory.removeLast();
//       }
//     });
//   }
//
//   String formatPhoneNumber(String rawNumber) {
//     if (rawNumber.isEmpty || rawNumber == "Unknown") {
//       return "Unknown";
//     }
//     return rawNumber.replaceAll(RegExp(r'[^\d+]'), '');
//   }
//
//   String getCallStatusMessage(PhoneStateStatus status, String info) {
//     switch (status) {
//       case PhoneStateStatus.CALL_INCOMING:
//         return "INCOMING CALL!\nFrom: $info";
//       case PhoneStateStatus.CALL_STARTED:
//         return "CALL ACTIVE\nWith: $info";
//       case PhoneStateStatus.CALL_ENDED:
//         return "CALL ENDED\nWas with: $info";
//       case PhoneStateStatus.NOTHING:
//         return "Listening for calls...";
//       }
//   }
//
//   Future<void> checkAndRequestPermissions() async {
//     try {
//       Map<Permission, PermissionStatus> statuses = await [
//         Permission.phone,
//         Permission.contacts,
//         if (Platform.isAndroid) Permission.manageExternalStorage,
//       ].request();
//       if (!statuses[Permission.phone]!.isGranted) {
//         setState(() => callStatus = "Phone permission denied.");
//         if (statuses[Permission.phone]!.isPermanentlyDenied) openAppSettings();
//         return;
//       }
//       if (!statuses[Permission.contacts]!.isGranted) {
//         setState(() => callStatus = "Contacts permission denied.");
//         if (statuses[Permission.contacts]!.isPermanentlyDenied) openAppSettings();
//         return;
//       }
//       if (Platform.isAndroid && !statuses[Permission.manageExternalStorage]!.isGranted) {
//         setState(() => callStatus = "Storage permission denied.");
//         if (statuses[Permission.manageExternalStorage]!.isPermanentlyDenied) openAppSettings();
//         return;
//       }
//       await initPhoneListener();
//     } catch (e) {
//       print("Error requesting permissions: $e");
//       setState(() => callStatus = "Permission request failed: $e");
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           SnackBar(
//             content: Text("Permission request failed: $e"),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//     }
//   }
//
//   Future<void> initPhoneListener() async {
//     try {
//       print("=== STARTING PHONE STATE LISTENER ===");
//       setState(() {
//         callStatus = "Starting listener...";
//         isListening = false;
//       });
//       await _phoneStateSubscription?.cancel();
//       _phoneStateSubscription = PhoneState.stream.listen(
//             (PhoneState phoneState) {
//           print("=== PHONE STATE RECEIVED ===");
//           print("Status: ${phoneState.status}");
//           print("Number: '${phoneState.number ?? 'null'}'");
//           handlePhoneStateChange(phoneState);
//         },
//         onError: (error) {
//           print("=== PHONE STATE ERROR ===");
//           print("Error: $error");
//           setState(() {
//             callStatus = "Listener error: $error";
//             isListening = false;
//           });
//           if (mounted) {
//             ScaffoldMessenger.of(context).showSnackBar(
//               SnackBar(
//                 content: Text("Listener error: $error"),
//                 backgroundColor: Colors.red,
//               ),
//             );
//           }
//         },
//         onDone: () {
//           print("=== PHONE STATE STREAM CLOSED ===");
//           setState(() {
//             callStatus = "Phone state stream closed";
//             isListening = false;
//           });
//         },
//       );
//       setState(() {
//         callStatus = "Listening for calls...";
//         isListening = true;
//       });
//       print("=== LISTENER STARTED SUCCESSFULLY ===");
//     } catch (e) {
//       print("=== ERROR STARTING LISTENER ===");
//       print("Error: $e");
//       setState(() {
//         callStatus = "Failed to start listener: $e";
//         isListening = false;
//       });
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           SnackBar(
//             content: Text("Failed to start listener: $e"),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//     }
//   }
//
//   Future<File?> getLatestCallRecording() async {
//     if (Platform.isIOS) {
//       print("iOS does not support accessing system call recordings.");
//       setState(() {
//         callStatus = "System call recording not supported on iOS.";
//       });
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           const SnackBar(
//             content: Text("System call recording not supported on iOS."),
//             backgroundColor: Colors.red,
//           ),
//         );
//       }
//       return null;
//     }
//     try {
//       await Future.delayed(const Duration(seconds: 5));
//       final today = DateTime.now();
//       final possiblePaths = [
//         '/storage/emulated/0/CallRecordings',
//         '/storage/emulated/0/Recordings/CallRecordings',
//         '/storage/emulated/0/MIUI/sound_recorder/call',
//         '/storage/emulated/0/Recordings/Call',
//         '/storage/emulated/0/Phone/Call',
//         "/sdcard/Phone/Call"
//       ];
//       for (String path in possiblePaths) {
//         final directory = Directory(path);
//         print("Checking directory: $path");
//         if (!await directory.exists()) {
//           print("Directory does not exist: $path");
//           continue;
//         }
//         final files = directory.listSync().whereType<File>().toList();
//         if (files.isEmpty) {
//           print("No files found in $path");
//           continue;
//         }
//         final todayFiles = files.where((file) {
//           final modified = file.lastModifiedSync();
//           return modified.year == today.year &&
//               modified.month == today.month &&
//               modified.day == today.day;
//         }).toList();
//         if (todayFiles.isEmpty) {
//           print("No files from today in $path");
//           continue;
//         }
//         todayFiles.sort(
//               (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
//         );
//         final latestFile = todayFiles.first;
//         if (callStartTime != null) {
//           final fileModifiedTime = await latestFile.lastModified();
//           final diffMinutes = fileModifiedTime.difference(callStartTime!).inMinutes;
//           print("Time diff: $diffMinutes minutes");
//           if (diffMinutes.abs() <= 5) {
//             print("Matched recording file: ${latestFile.path}");
//             return latestFile;
//           } else {
//             print("Latest file is from today but not within time range.");
//           }
//         }
//         print("Returning today's latest recording: ${latestFile.path}");
//         return latestFile;
//       }
//       print("No call recording found from today.");
//       return null;
//     } catch (e) {
//       print("Error accessing call recordings: $e");
//       return null;
//     }
//   }
//
//   Future<String?> _getMyPhoneNumber({bool forDisplay = false}) async {
//     try {
//       if (!Platform.isAndroid) {
//         print("Not an Android device, returning default.");
//         return forDisplay ? "My Number" : null;
//       }
//       var status = await Permission.phone.status;
//       if (!status.isGranted) {
//         status = await Permission.phone.request();
//         if (!status.isGranted) {
//           print("Phone permission not granted");
//           return forDisplay ? "My Number" : null;
//         }
//       }
//       final plugin = SimNumberPicker();
//       final number = await plugin.getPhoneNumberHint();
//       if (number != null && number.isNotEmpty) {
//         print("Original SIM Number: $number");
//         String sanitized = number.replaceAll(RegExp(r'\s+|-'), '');
//         sanitized = sanitized.replaceFirst(RegExp(r'^\+?\d{1,3}'), '+91');
//         print("Modified SIM Number: $sanitized");
//         return forDisplay ? "My Number" : sanitized;
//       } else {
//         print("SIM number not available");
//         return forDisplay ? "My Number" : null;
//       }
//     } catch (e) {
//       print("Error getting my phone number: $e");
//       return forDisplay ? "My Number" : null;
//     }
//   }
//
//   void restartListener() {
//     print("=== RESTARTING LISTENER ===");
//     setState(() {
//       callStatus = "Restarting listener...";
//       isListening = false;
//     });
//     _resetCallVariables();
//     checkAndRequestPermissions();
//   }
//
//   void clearHistory() {
//     setState(() {
//       callerInfo = "Unknown";
//       callStatus = "Listening for calls...";
//       callHistory.clear(); // <-- if you're tracking history
//     });
//   }
//
//   Map<String, dynamic> getCallDebugInfo() {
//     return {
//       'isCallActive': isCallActive,
//       'isIncomingCall': isIncomingCall,
//       'apiCallSent': _apiCallSent,
//       'callStartTime': callStartTime?.toIso8601String(),
//       'callEndTime': callEndTime?.toIso8601String(),
//       'lastNumber': lastNumber,
//       'lastContactName': lastContactName,
//       'currentCallId': currentCallId,
//       'callerInfo': callerInfo,
//       'isLiveStreamActive': _isLiveStreamActive,
//     };
//   }
//
//   @override
//   Widget build(BuildContext context) {
//
//     print("isCallActive Checker: $isCallActive");
//
//
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text("Call Listener"),
//         actions: [
//           IconButton(
//             onPressed: () => Navigator.push(
//               context,
//               MaterialPageRoute(builder: (context) => AdminHomePage()),
//             ),
//             icon: const Icon(Icons.login),
//             tooltip: "Admin Login",
//           ),
//           IconButton(
//             icon: const Icon(Icons.refresh),
//             onPressed: restartListener,
//             tooltip: "Restart Listener",
//           ),
//           IconButton(
//             icon: const Icon(Icons.clear_all),
//             onPressed: clearHistory,
//             tooltip: "Clear History",
//           ),
//         ],
//       ),
//       body: Padding(
//         padding: const EdgeInsets.all(16.0),
//         child: Column(
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             AnimatedBuilder(
//               animation: _colorAnimation,
//               builder: (context, child) {
//                 return Card(
//                   elevation: 8,
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(12.0),
//                   ),
//                   color: _colorAnimation.value,
//                   child: Padding(
//                     padding: const EdgeInsets.all(20.0),
//                     child: Column(
//                       children: [
//                         Icon(
//                           isListening ? Icons.phone : Icons.phone_disabled,
//                           size: 60,
//                           color: Colors.white,
//                         ),
//                         const SizedBox(height: 20),
//                         Text(
//                           callStatus,
//                           style: const TextStyle(
//                             fontSize: 18,
//                             fontWeight: FontWeight.bold,
//                             color: Colors.white,
//                           ),
//                           textAlign: TextAlign.center,
//                         ),
//                         Padding(
//                           padding: const EdgeInsets.only(top: 15),
//                           child: Text(
//                             "Caller: $callerInfo",
//                             style: const TextStyle(
//                               fontSize: 20,
//                               fontWeight: FontWeight.bold,
//                               color: Colors.white,
//                             ),
//                           ),
//                         ),
//                         if (isCallActive && callStartTime != null)
//                           Padding(
//                             padding: const EdgeInsets.only(top: 10),
//                             child: StreamBuilder(
//                               stream: Stream.periodic(const Duration(seconds: 1)),
//                               builder: (context, snapshot) {
//                                 if (callStartTime == null) return const SizedBox.shrink();
//                                 final duration = DateTime.now().difference(callStartTime!);
//                                 return Text(
//                                   "Duration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}",
//                                   style: const TextStyle(
//                                     fontSize: 16,
//                                     fontWeight: FontWeight.bold,
//                                     color: Colors.white,
//                                   ),
//                                 );
//                               },
//                             ),
//                           ),
//                         if (isCallActive)
//                           Padding(
//                             padding: const EdgeInsets.only(top: 5),
//                             child: Text(
//                               "API Status: ${_apiCallSent ? 'Sent' : 'Pending'}",
//                               style: TextStyle(
//                                 fontSize: 12,
//                                 color: _apiCallSent ? Colors.white : Colors.white70,
//                               ),
//                             ),
//                           ),
//                       ],
//                     ),
//                   ),
//                 );
//               },
//             ),
//             const SizedBox(height: 20),
//             Expanded(
//               child: Card(
//                 elevation: 8,
//                 shape: RoundedRectangleBorder(
//                   borderRadius: BorderRadius.circular(12.0),
//                 ),
//                 child: Column(
//                   children: [
//                     const Padding(
//                       padding: EdgeInsets.all(16.0),
//                       child: Text(
//                         "Call History",
//                         style: TextStyle(
//                           fontSize: 18,
//                           fontWeight: FontWeight.bold,
//                         ),
//                       ),
//                     ),
//                     Expanded(
//                       child: callHistory.isEmpty
//                           ? const Center(
//                         child: Text("No call history yet."),
//                       )
//                           : ListView.builder(
//                         itemCount: callHistory.length,
//                         itemBuilder: (context, index) {
//                           return ListTile(
//                             title: Text(callHistory[index]),
//                           );
//                         },
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
//
//
//
//
//
//
