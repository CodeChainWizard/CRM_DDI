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
  final TextEditingController _numberController = TextEditingController();

  @override
  void initState() {
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
    _cleanupResources().then((_) async {
      await _initializeApp();
      if (_phoneNumber.isNotEmpty) {
        await _checkUserAccess(_phoneNumber);
      }
      await checkAndRequestPermissions();
    });
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
      final hasAccess =
          userDetails.containsKey('active') && userDetails['active'] == true;
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Access granted. Welcome!'),
              backgroundColor: Colors.green,
            ),
          );
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
      print("Loaded phone number from storage: $storeNumber");
    } else {
      print("No phone number found in storage, attempting to fetch...");
      await _fetchNumber();
    }
  }

  Future<void> _fetchNumber() async {
    try {
      print("Attempting to fetch phone number...");
      final result = await _getMyPhoneNumber();
      if (!mounted) return;
      if (result == null || result.isEmpty) {
        if (!_hasShownNumberSelectionPopup) {
          print("Showing phone number selection popup...");
          await _showPhoneNumberSelectionDialog();
        } else {
          print("Phone number popup already shown, skipping...");
        }
      } else {
        print("Phone number fetched successfully: $result");
        await _savePhoneNumber(result);
      }
    } catch (e) {
      print("Error in _fetchNumber: $e");
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
              const Text(
                'Please enter your registered phone number to continue:',
              ),
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
              },
            ),
            TextButton(
              child: const Text('Save'),
              onPressed: () async {
                final phoneNumber = phoneController.text.trim();
                if (phoneNumber.isNotEmpty) {
                  try {
                    final userDetails = await API.getCallDetailsByNumber(
                      phoneNumber,
                    );
                    if (userDetails == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Failed to verify number. Please try again.',
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    final hasAccess =
                        userDetails.containsKey('active') &&
                        userDetails['active'] == true;
                    if (!hasAccess) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'You do not have access to use this app.',
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    await _savePhoneNumber(phoneNumber);
                    Navigator.of(context).pop();
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Error verifying number: ${e.toString()}',
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter a valid phone number'),
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
      print("Marked popup as shown");
    } catch (e) {
      print("Error marking popup as shown: $e");
    }
  }

  Future<void> _resetPhoneNumberData() async {
    try {
      final pref = await SharedPreferences.getInstance();
      await pref.remove("my_phone_number");
      await pref.setBool("has_shown_number_popup", false);
      setState(() {
        _phoneNumber = '';
        _hasShownNumberSelectionPopup = false;
      });
      print("Phone number data reset");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Phone number data reset'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      print("Error resetting phone number data: $e");
    }
  }

  Future<void> _initializeAudioStreamSender() async {
    try {
      _audioStreamSender = AudioStreamSender(
        'ws://192.168.1.3:8001/api/live_audio?callId=$currentCallId',
      );
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
          String cleanedContactNumber = phone.number.replaceAll(
            RegExp(r'[^\d+]'),
            '',
          );
          String cleanedIncomingNumber = phoneNumber.replaceAll(
            RegExp(r'[^\d+]'),
            '',
          );
          if (cleanedContactNumber == cleanedIncomingNumber ||
              cleanedContactNumber.endsWith(
                cleanedIncomingNumber.substring(
                  cleanedIncomingNumber.length > 10
                      ? cleanedIncomingNumber.length - 10
                      : 0,
                ),
              ) ||
              cleanedIncomingNumber.endsWith(
                cleanedContactNumber.substring(
                  cleanedContactNumber.length > 10
                      ? cleanedContactNumber.length - 10
                      : 0,
                ),
              )) {
            print(
              "Contact found: ${contact.displayName} for number: $phoneNumber",
            );
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
    String displayNumber,
    String contactName,
  ) async {
    if (displayNumber == "Unknown") return;
    print("=== INCOMING CALL ===");
    print("Number: $displayNumber");
    print("Contact: $contactName");
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
    String displayNumber,
    String contactName,
  ) async {
    if (displayNumber == "Unknown") {
      print("Skipping processing for unknown number");
      return;
    }
    print("=== CALL STARTED ===");
    print("Number: $displayNumber");
    print("Contact: $contactName");
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

    // Early return if no active call or API call already sent
    if (callStartTime == null || !isCallActive || _apiCallSent) {
      _logger.warning("No active call to end, missing call start time, or API call already sent");
      return;
    }

    try {
      // Mark API call as sent immediately to prevent duplicate calls
      setState(() {
        _apiCallSent = true;
      });

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

      // Always send the call ended message via WebSocket
      await safeSendWebSocketMessage(callData);

      if (shouldSendRecording) {
        try {
          // Add delay to ensure recording is saved
          await Future.delayed(const Duration(seconds: 2));

          final audioFile = await getLatestCallRecording();
          if (audioFile != null && await audioFile.exists()) {
            // Add audio file URL to call data
            callData['audio_file'] = await getAudioFileUrl(currentCallId!);

            // Send updated call data with audio file reference
            await safeSendWebSocketMessage(callData);

            // Make the API call with a timeout
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
    } catch (e) {
      _logger.severe('Error in handleCallEnded', e);
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
              phoneState,
              lastNumber ?? displayNumber,
              lastContactName ?? contactName,
            );
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
    String contactName,
    String displayNumber,
    PhoneStateStatus status,
  ) {
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

  void logCallEvent(
    PhoneStateStatus status,
    String contactName,
    String displayNumber,
  ) {
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
    bool storagePermissionGranted = Platform.isAndroid ? statuses[Permission.manageExternalStorage]!.isGranted : true;

    return phonePermissionGranted && contactsPermissionGranted && storagePermissionGranted;
  }

  Future<void> checkAndRequestPermissions() async {
    try {
      bool hasPermissions = await _checkPermissions();
      setState(() {
        isListening = hasPermissions;
        callStatus = hasPermissions ? "Listening for calls..." : "Permissions not granted";
      });
      if (hasPermissions) {
        await initPhoneListener();
      }
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
    try {
      if (Platform.isIOS) {
        _logger.info("iOS does not support accessing system call recordings.");
        return null;
      }
      await Future.delayed(const Duration(seconds: 2));
      final possiblePaths = [
        '/storage/emulated/0/CallRecordings',
        '/storage/emulated/0/Recordings/CallRecordings',
        '/storage/emulated/0/MIUI/sound_recorder/call',
        '/storage/emulated/0/Recordings/Call',
        '/storage/emulated/0/Phone/Call',
        "/sdcard/Phone/Call",
      ];
      for (String path in possiblePaths) {
        try {
          final directory = Directory(path);
          if (!await directory.exists()) continue;
          final files =
              await directory
                  .list()
                  .where((entity) => entity is File)
                  .cast<File>()
                  .toList();
          if (files.isEmpty) continue;
          files.sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
          return files.first;
        } catch (e) {
          _logger.warning('Error checking directory $path', e);
        }
      }
      return null;
    } catch (e) {
      _logger.severe('Error in getLatestCallRecording', e);
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
        return null;
      }
    } catch (e) {
      print("Error getting my phone number: $e");
      return null;
    }
  }

  void restartListener() {
    print("=== RESTARTING LISTENER ===");
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
                              stream: Stream.periodic(
                                const Duration(seconds: 1),
                              ),
                              builder: (context, snapshot) {
                                if (callStartTime == null)
                                  return const SizedBox.shrink();
                                final duration = DateTime.now().difference(
                                  callStartTime!,
                                );
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
                                color:
                                    _apiCallSent
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
                      child:
                          callHistory.isEmpty
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
