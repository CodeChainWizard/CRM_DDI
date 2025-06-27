import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../APIServices.dart';
import '../WebRTCHelper.dart';
import '../WebSocketHelper.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final List<Map<String, dynamic>> _activeCalls = [];
  final List<Map<String, dynamic>> _recentCalls = [];
  bool _isConnected = false;
  String _connectionStatus = "Connecting...";
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  bool _isReceivingLiveStream = false;
  WebSocketChannel? _webSocketChannel;
  final AudioPlayer _audioPlayer = AudioPlayer();
  WebSocketChannel? _audioSocket;
  String? _currentlyStreamingCallId;
  bool _isBuffering = false;
  PlayerState _playerState = PlayerState.stopped;
  String? _currentlyPlayingUrl;
  bool _isLiveStreamPlaying = false;
  String? _currentLiveStreamCallId;
  final _remoteRenderer = RTCVideoRenderer();
  bool _isRendererInitialized = false;
  final int _maxRecentCalls = 20;
  bool _isLoadingRecentCalls = false;
  String? _recentCallsError;
  String userStatus = 'Active';
  String recordingStatus = 'Recording';
  final List<Uint8List> _receivedChunks = [];
  List<Map<String, dynamic>> _numberAccessList = [];
  bool _isLoadingNumberAccess = false;
  String? _numberAccessError;
  List<Map<String, dynamic>> _userList = [];

  @override
  void initState() {
    super.initState();
    _initRenderer();
    _setupAudioPlayerListeners();
    _initializeWebSocket();
    _fetchRecentCalls();
    _fetchUserDetails();
    _fetchNumberAccess();
  }

  Future<void> _fetchNumberAccess() async {
    setState(() {
      _isLoadingNumberAccess = true;
      _numberAccessError = null;
    });
    try {
      final response = await API.getCallNumberAccess();
      if (response != null) {
        setState(() {
          _numberAccessList = response;
        });
      } else {
        setState(() {
          _numberAccessError = 'Failed to load number access data';
        });
      }
    } catch (e) {
      setState(() {
        _numberAccessError = 'Error fetching number access data: ${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoadingNumberAccess = false;
      });
    }
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
    setState(() {
      _isRendererInitialized = true;
    });
  }

  void _setupAudioPlayerListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _playerState = state;
          if (state == PlayerState.stopped || state == PlayerState.completed) {
            _currentlyPlayingUrl = null;
            _isLiveStreamPlaying = false;
            _currentLiveStreamCallId = null;
            _currentlyStreamingCallId = null;
          }
        });
      }
    });
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) {
        setState(() {
          _currentlyPlayingUrl = null;
          _isLiveStreamPlaying = false;
          _currentLiveStreamCallId = null;
          _currentlyStreamingCallId = null;
        });
      }
    });
  }

  Future<void> _initializeWebSocket() async {
    try {
      await _subscription?.cancel();
      await _channel?.sink.close();
      _channel = await WebSocketHelper.connect();
      _subscription = _channel?.stream.listen(
            (message) => _handleWebSocketMessage(message),
        onError: _handleWebSocketError,
        onDone: _handleWebSocketDisconnect,
      );
      setState(() {
        _isConnected = true;
        _connectionStatus = "Connected";
      });
    } catch (e) {
      setState(() {
        _connectionStatus = "Failed to connect";
        _isConnected = false;
      });
      Future.delayed(const Duration(seconds: 5), _initializeWebSocket);
    }
  }

  void _handleWebSocketMessage(dynamic message) {
    try {
      final data = json.decode(message) as Map<String, dynamic>;
      if (data['type'] == 'pcm' && data['chunk'] != null) {
        final decodedChunk = base64Decode(data['chunk']);
        _receivedChunks.add(decodedChunk);
        print("PCM Chunk Received: ${decodedChunk.length} bytes");
        print("First 10 Samples: ${Int16List.view(decodedChunk.buffer).take(10).toList()}");
        return;
      }
      if (data.containsKey('error') && data.containsKey('received')) {
        final callData = json.decode(data['received']) as Map<String, dynamic>;
        _processCallData(callData);
        return;
      }
      _processCallData(data);
    } catch (e) {
      debugPrint("Error processing WebSocket message: $e");
    }
  }

  void _processCallData(Map<String, dynamic> data) {
    final String messageType = data['type'] ?? 'unknown';
    final String callId = data['callId'] ?? _generateCallId();
    switch (messageType) {
      case 'call_started':
        _handleCallStarted(data, callId);
        break;
      case 'call_ended':
        _handleCallEnded(data, callId);
        break;
      case 'incoming_call':
        _handleIncomingCall(data, callId);
        break;
      case 'call_update':
        _handleCallUpdate(data, callId);
        break;
      case 'live_audio':
        _handleLiveAudioUpdate(data, callId);
        break;
      default:
        _handleGenericCallData(data, callId);
        break;
    }
  }

  void _handleLiveAudioUpdate(Map<String, dynamic> data, String callId) {
    setState(() {
      final callIndex = _activeCalls.indexWhere((call) => call['callId'] == callId);
      if (callIndex != -1) {
        _activeCalls[callIndex]['live_stream_url'] = data['stream_url'];
      }
    });
  }

  String _generateCallId() {
    return '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1000)}';
  }

  Future<void> _handleIncomingCall(Map<String, dynamic> data, String callId) async {
    try {
      await WebRTCHelper.initializeReceiver(
        callId: callId,
        signalingChannel: _webSocketChannel!,
        onRemoteStream: (MediaStream stream) {
          if (mounted) {
            setState(() {
              _remoteRenderer.srcObject = stream;
              _isReceivingLiveStream = true;
            });
          }
          for (var track in stream.getAudioTracks()) {
            track.enabled = true;
          }
        },
        onStreamUrl: (String streamUrl) {
          if (mounted) {
            setState(() {
              _isReceivingLiveStream = true;
              final callIndex = _activeCalls.indexWhere((call) => call['callId'] == callId);
              if (callIndex != -1) {
                _activeCalls[callIndex]['live_stream_url'] = streamUrl;
              }
            });
          }
        },
      );
    } catch (e) {
      debugPrint("Error initializing WebRTC receiver: $e");
    }
  }

  void _handleCallStarted(Map<String, dynamic> data, String callId) {
    setState(() {
      _activeCalls.removeWhere((call) => call['callId'] == callId);
      _activeCalls.add({
        'callId': callId,
        'senderNumber': data['senderNumber'] ?? 'Unknown',
        'receiverNumber': data['receiverNumber'] ?? 'Unknown',
        'contactName': data['contactName'] ?? 'Unknown',
        'status': 'Active',
        'startTime': data['startTime'] != null ? DateTime.parse(data['startTime']) : DateTime.now(),
        'duration': 0,
        'audio_file': data['audio_file'],
        'audioFile': data['audioFile'],
      });
    });
  }

  void _handleCallEnded(Map<String, dynamic> data, String callId) {
    if (_currentlyStreamingCallId == callId) {
      _stopLiveAudioStream();
    }
    setState(() {
      final callIndex = _activeCalls.indexWhere((call) => call['callId'] == callId);
      if (callIndex != -1) {
        final endedCall = _activeCalls.removeAt(callIndex);
        endedCall['status'] = 'Ended';
        endedCall['endTime'] = data['endTime'] != null ? DateTime.parse(data['endTime']) : DateTime.now();
        endedCall['duration'] = data['duration'] ?? 0;
        if (data['audio_file'] != null) {
          endedCall['audio_file'] = data['audio_file'];
        }
        if (data['audioFile'] != null) {
          endedCall['audioFile'] = data['audioFile'];
        }
        _recentCalls.insert(0, endedCall);
        if (_recentCalls.length > _maxRecentCalls) {
          _recentCalls.removeLast();
        }
      }
    });
  }

  void _handleCallUpdate(Map<String, dynamic> data, String callId) {
    setState(() {
      final callIndex = _activeCalls.indexWhere((call) => call['callId'] == callId);
      if (callIndex != -1) {
        _activeCalls[callIndex] = {..._activeCalls[callIndex], ...data, 'status': data['status'] ?? _activeCalls[callIndex]['status']};
      }
    });
  }

  void _handleGenericCallData(Map<String, dynamic> data, String callId) {
    setState(() {
      _activeCalls.add({
        'callId': callId,
        'senderNumber': data['callerNumber'] ?? data['senderNumber'] ?? 'Unknown',
        'receiverNumber': data['receiverNumber'] ?? 'Unknown',
        'contactName': data['contactName'] ?? 'Unknown',
        'status': data['status'] ?? 'Active',
        'startTime': DateTime.now(),
        'duration': 0,
        'audio_file': data['audio_file'],
        'audioFile': data['audioFile'],
      });
    });
  }

  void _handleWebSocketError(dynamic error) {
    setState(() {
      _connectionStatus = "Error occurred";
      _isConnected = false;
    });
    _reconnectWebSocket();
  }

  void _handleWebSocketDisconnect() {
    setState(() {
      _connectionStatus = "Disconnected";
      _isConnected = false;
    });
    _reconnectWebSocket();
  }

  void _reconnectWebSocket() {
    setState(() {
      _connectionStatus = "Reconnecting...";
    });
    Future.delayed(const Duration(seconds: 2), _initializeWebSocket);
  }

  Future<void> _fetchRecentCalls() async {
    if (_isLoadingRecentCalls) return;
    setState(() {
      _isLoadingRecentCalls = true;
      _recentCallsError = null;
    });
    try {
      final List<Map<String, dynamic>>? apiCalls = await API.getCallDetails(page: 1, limit: _maxRecentCalls);
      if (apiCalls != null) {
        final List<Map<String, dynamic>> transformedCalls = apiCalls.map((call) {
          return {
            'callId': call['id'].toString(),
            'senderNumber': call['sender_ph'],
            'receiverNumber': call['receiver_ph'],
            'contactName': call['contact_name'] ?? 'Unknown',
            'status': 'Ended',
            'startTime': DateTime.parse(call['start_time']),
            'endTime': DateTime.parse(call['end_time']),
            'duration': call['duration'],
            'audio_file': call['recording_url'],
          };
        }).toList();
        transformedCalls.sort((a, b) => (b['startTime'] as DateTime).compareTo(a['startTime'] as DateTime));
        setState(() {
          _recentCalls
            ..clear()
            ..addAll(transformedCalls.take(_maxRecentCalls));
        });
      } else {
        setState(() {
          _recentCallsError = 'Failed to load recent calls: No data received';
        });
      }
    } catch (e) {
      setState(() {
        _recentCallsError = 'Failed to load recent calls: ${e.toString()}';
      });
    } finally {
      setState(() {
        _isLoadingRecentCalls = false;
      });
    }
  }

  Future<void> _startLiveAudioStream(String callId) async {
    try {
      await _stopLiveAudioStream();
      final call = _activeCalls.firstWhere((c) => c['callId'] == callId, orElse: () => {});
      if (call.isEmpty) {
        _showSnackBar("Call not found", Colors.red);
        return;
      }
      setState(() {
        _isBuffering = true;
        _currentlyStreamingCallId = callId;
        _isLiveStreamPlaying = true;
        _currentLiveStreamCallId = callId;
      });
      if (!_remoteRenderers.containsKey(callId)) {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        _remoteRenderers[callId] = renderer;
        await WebRTCHelper.initializeReceiver(
          callId: callId,
          signalingChannel: _channel!,
          onRemoteStream: (MediaStream stream) {
            if (mounted) {
              setState(() {
                _remoteRenderers[callId]!.srcObject = stream;
                _isReceivingLiveStream = true;
                _isBuffering = false;
              });
              stream.getAudioTracks().forEach((track) => track.enabled = true);
            }
          },
          onStreamUrl: (String streamUrl) {},
        );
      }
      print("Live audio stream started for call $callId");
    } catch (e) {
      print("Error starting live audio stream: $e");
      _handleStreamError(e, callId);
    }
  }

  Future<void> _stopLiveAudioStream() async {
    try {
      await _audioSocket?.sink.close();
      await _audioPlayer.stop();
      _audioSocket = null;
      _cleanupStream(_currentlyStreamingCallId);
      if (_currentlyStreamingCallId != null && _remoteRenderers.containsKey(_currentlyStreamingCallId)) {
        await _remoteRenderers[_currentlyStreamingCallId]!.dispose();
        _remoteRenderers.remove(_currentlyStreamingCallId);
      }
    } catch (e) {
      debugPrint("Error stopping stream: $e");
    }
  }

  void _cleanupStream(String? callId) {
    if (mounted) {
      setState(() {
        _isBuffering = false;
        if (_currentlyStreamingCallId == callId) {
          _currentlyStreamingCallId = null;
        }
      });
    }
  }

  void _handleStreamError(dynamic error, String callId) {
    debugPrint("Stream error for call $callId: $error");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Audio stream error: ${error.toString().length > 50 ? error.toString().substring(0, 50) + '...' : error.toString()}")),
      );
    }
    _stopLiveAudioStream();
  }

  Future<void> _playRecording(String url, String callId) async {
    try {
      setState(() {
        _isBuffering = true;
        _currentlyPlayingUrl = url;
        _currentlyStreamingCallId = null;
        _isLiveStreamPlaying = false;
        _currentLiveStreamCallId = null;
      });
      await _audioPlayer.stop();
      await _audioPlayer.play(UrlSource(url));
      _audioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      _showSnackBar("Now playing call recording", Colors.green);
    } catch (e) {
      _handleError('Error playing recording: ${e.toString()}', callId);
    } finally {
      if (mounted) {
        setState(() => _isBuffering = false);
      }
    }
  }

  void _handleError(String message, String callId) {
    debugPrint("Error playing audio ($callId): $message");
    _showSnackBar(message, Colors.red);
    setState(() => _currentlyPlayingUrl = null);
  }

  Future<void> _cleanTempFiles(Directory directory, String currentCallId) async {
    try {
      final files = await directory.list().toList();
      for (var file in files) {
        if (file.path.contains('temp_audio_') && !file.path.contains(currentCallId)) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint("Error cleaning temp files: $e");
    }
  }

  Future<void> _pauseAudio() async {
    try {
      await _audioPlayer.pause();
      setState(() {
        _playerState = PlayerState.paused;
      });
    } catch (e) {
      debugPrint("Error pausing audio: $e");
    }
  }

  Future<void> _stopAudio() async {
    try {
      await _audioPlayer.stop();
      setState(() {
        _currentlyPlayingUrl = null;
        if (_isLiveStreamPlaying) {
          _isLiveStreamPlaying = false;
          _currentLiveStreamCallId = null;
        }
        _playerState = PlayerState.stopped;
      });
    } catch (e) {
      debugPrint("Error stopping audio: $e");
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: color,
      ),
    );
  }

  String _formatDurationFromSeconds(int seconds) {
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  bool _shouldShowPlayButton(Map<String, dynamic> call, bool isActive) {
    final audioFile = call['audio_file'] ?? call['audioFile'] ?? call['recording_url'];
    return (audioFile != null && audioFile.toString().isNotEmpty);
  }

  Widget _buildPlaybackControls({required bool isCurrentlyPlaying, required bool isLiveStream, required Map<String, dynamic> call}) {
    final bool isBuffering = _isBuffering;
    final callId = call['callId'];
    final isThisStreamPlaying = _currentlyStreamingCallId == callId && _playerState == PlayerState.playing;
    if (isBuffering && _currentlyStreamingCallId == callId) {
      return const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
    }
    final audioFile = call['audio_file'] ?? call['audioFile'] ?? call['recording_url'];
    final liveStreamUrl = call['live_stream_url'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isLiveStream && liveStreamUrl != null)
          IconButton(
            icon: Icon(
              isThisStreamPlaying ? Icons.pause : Icons.play_arrow,
              size: 24,
              color: Colors.red,
            ),
            onPressed: () async {
              print("▶️ Play/Pause button pressed for call $callId");
              if (isThisStreamPlaying) {
                await _pauseAudio();
              } else {
                if (_currentlyStreamingCallId != callId) {
                  await _stopLiveAudioStream();
                }
                await _startLiveAudioStream(callId);
              }
            },
            tooltip: isThisStreamPlaying ? 'Pause Live Stream' : 'Play Live Stream',
          ),
        if (!isLiveStream && audioFile != null)
          IconButton(
            icon: Icon(
              _currentlyPlayingUrl == audioFile && _playerState == PlayerState.playing ? Icons.pause : Icons.play_arrow,
              size: 24,
            ),
            onPressed: () async {
              print("▶️ Play/Pause button pressed for recording $callId");
              if (_currentlyPlayingUrl == audioFile && _playerState == PlayerState.playing) {
                await _pauseAudio();
              } else {
                if (_currentlyPlayingUrl != null && _currentlyPlayingUrl != audioFile) {
                  await _stopAudio();
                }
                await _playRecording(audioFile, callId);
              }
            },
            tooltip: _playerState == PlayerState.playing && _currentlyPlayingUrl == audioFile ? 'Pause Recording' : 'Play Recording',
          ),
      ],
    );
  }

  final _formKey = GlobalKey<FormState>();
  final TextEditingController _phoneController = TextEditingController();

  Widget _buildAddUserForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            TextFormField(
              controller: _phoneController,
              decoration: const InputDecoration(labelText: 'Phone Number'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a phone number';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitUserForm,
              child: const Text('Add User'),
            ),
          ],
        ),
      ),
    );
  }



  Future<void> _submitUserForm() async {
    if (_formKey.currentState!.validate()) {
      final phone = _phoneController.text.trim();
      try {
        final response = await API.addUserByAdmin(phone);
        if (response != null) {
          _showSnackBar('User added successfully', Colors.green);
          _phoneController.clear();
        } else {
          _showSnackBar('Failed to add user', Colors.red);
          _phoneController.clear();
        }
      } catch (e) {
        _showSnackBar('Error adding user: $e', Colors.red);
      }
    }
  }

  Future<void> _refreshUserList() async {
    await _fetchUserDetails();
    setState(() {});
  }

  bool _isFetchingUser = false;

  Widget _buildGetUserForm() {
    if (_isFetchingUser || _isLoadingNumberAccess) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_userList.isEmpty) {
      return const Center(child: Text('No users found.'));
    }

    return RefreshIndicator(
      onRefresh: _refreshUserList,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _userList.length,
        itemBuilder: (context, index) {
          final user = _userList[index];
          final currentActiveStatus = user['active'] == 1 ? 'Active' : 'Inactive';
          final currentRecordingStatus = user['recordingStatus'] == 1 ? 'Recording' : 'UnRecording';
      
          if (user['selectedNumbers'] == null) {
            user['selectedNumbers'] = [];
          }
      
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Mobile: ${user['mobileno']}", style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text("User ID: ${user['userid']}"),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: currentActiveStatus,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'Active', child: Text('Active')),
                            DropdownMenuItem(value: 'Inactive', child: Text('Inactive')),
                          ],
                          onChanged: (newValue) {
                            if (newValue != null) {
                              _updateUserStatus(index, newValue, 'active');
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: currentRecordingStatus,
                          decoration: const InputDecoration(
                            labelText: 'Recording',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'Recording', child: Text('Recording')),
                            DropdownMenuItem(value: 'UnRecording', child: Text('UnRecording')),
                          ],
                          onChanged: (newValue) {
                            if (newValue != null) {
                              _updateUserStatus(index, newValue, 'recording');
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
      
                  ElevatedButton.icon(
                    onPressed: () async {
                      await _showMultiSelectDialog(context, index);
                      setState(() {}); // Rebuilds UI to reflect selected numbers
                    },
                    icon: const Icon(Icons.format_list_numbered),
                    label: const Text('Select Numbers'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      textStyle: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
      
                  Text('Selected Numbers: ${user['selectedNumbers']?.join(", ") ?? "None"}')
      
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _sendSelectedNumbersToAPI(int index) async {
    final user = _userList[index];
    final List<String> selectedNumbers = List<String>.from(user['selectedNumbers']);

    if (selectedNumbers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No numbers selected.')),
      );
      return;
    }

    try {
      print("USER DETAILS: $user");
      final response = await API.sendSelectedNumbers(user['mobileno'], selectedNumbers);

      if (response != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected numbers sent successfully.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to send selected numbers.')),
        );
      }
    } catch (e) {
      print("Error while sending data: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sending selected numbers: $e')),
      );
    }
  }

  Future<void> _showMultiSelectDialog(BuildContext context, int index) async {
    final user = _userList[index];
    final userMobileNumber = user['mobileno'];

    // Filter out the user's own mobile number from the list
    final filteredNumberAccessList = _numberAccessList.where((item) => item['mobileno'] != userMobileNumber).toList();

    if (filteredNumberAccessList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No numbers available to select.')),
      );
      return;
    }

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Numbers'),
          content: StatefulBuilder(
            builder: (BuildContext context, StateSetter setStateDialog) {
              return SingleChildScrollView(
                child: ListBody(
                  children: filteredNumberAccessList.map((item) {
                    final mobileNo = item['mobileno'];
                    final isSelected = _userList[index]['selectedNumbers'].contains(mobileNo);
                    return CheckboxListTile(
                      value: isSelected,
                      title: Text(mobileNo),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (isChecked) async {
                        setStateDialog(() {
                          if (isChecked == true) {
                            _userList[index]['selectedNumbers'].add(mobileNo);
                          } else {
                            _userList[index]['selectedNumbers'].remove(mobileNo);
                          }
                        });

                        // Call the delete API if the number is unselected
                        if (isChecked == false) {
                          _deleteSelectedNumber(userMobileNumber, mobileNo);
                        }
                      },
                    );
                  }).toList(),
                ),
              );
            },
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
                _sendSelectedNumbersToAPI(index);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteSelectedNumber(String userMobileNumber, String selectedNumber) async {
    try {
      final response = await API.DeleteSelectedNumbers(userMobileNumber, [selectedNumber]);
      if (response != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Number $selectedNumber deleted successfully.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete number $selectedNumber.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting number $selectedNumber: $e')),
      );
    }
  }

  Future<void> _updateUserStatus(int index, String newStatus, String statusType) async {
    final user = _userList[index];
    final phone = user['mobileno'];
    final isActive = newStatus == 'Active';
    final isRecording = newStatus == 'Recording';
    final uiActiveValue = isActive ? 1 : 0;
    final uiRecordingValue = isRecording ? 1 : 0;
    final apiActiveValue = isActive ? 1 : 0;
    final apiRecordingValue = isRecording ? 1 : 0;

    setState(() {
      if (statusType == 'active') {
        _userList[index]['active'] = uiActiveValue;
      } else if (statusType == 'recording') {
        _userList[index]['recordingStatus'] = uiRecordingValue;
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      '${phone}_${statusType}_status',
      statusType == 'active' ? uiActiveValue : uiRecordingValue,
    );

    final Map<String, dynamic> apiData = {};
    if (statusType == 'active') {
      apiData['active'] = apiActiveValue;
    } else {
      apiData['recordingStatus'] = apiRecordingValue;
    }

    final success = await API.updateUserStatus(phone, apiData);
    if (!success) {
      setState(() {
        if (statusType == 'active') {
          _userList[index]['active'] = uiActiveValue == 1 ? 0 : 1;
        } else {
          _userList[index]['recordingStatus'] = uiRecordingValue == 1 ? 0 : 1;
        }
      });
      _showSnackBar('Failed to update status', Colors.red);
    }
  }

  Future<void> _updateUserRecordingStatus(int index, String newStatus) async {
    final user = _userList[index];
    final phone = user['mobileno'];
    setState(() {
      _userList[index]['recordingStatus'] = newStatus == 'Recording' ? 1 : 0;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${phone}_recording_status', newStatus == 'Recording' ? 1 : 0);

    await API.updateCallStatus(phone, newStatus);
  }

  Future<void> _fetchUserDetails() async {
    setState(() {
      _isFetchingUser = true;
    });

    try {
      final response = await API.getCallDetailsUser();
      if (response != null) {
        for (var user in response) {
          final phoneNumber = user['mobileno'];
          final accessNumbers = await API.getAccessNumberByUser(phoneNumber);
          user['selectedNumbers'] = accessNumbers ?? [];
        }
        setState(() {
          _userList = response;
        });
      }
    } catch (e) {
      print("Error fetching user details: $e");
    } finally {
      setState(() {
        _isFetchingUser = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            icon: Icon(_isConnected ? Icons.wifi : Icons.wifi_off, color: _isConnected ? Colors.green : Colors.red),
            onPressed: _reconnectWebSocket,
            tooltip: _connectionStatus,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Center(
              child: Text(
                _connectionStatus,
                style: TextStyle(color: _isConnected ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatsRow(),
          Expanded(
            child: DefaultTabController(
              length: 4,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(icon: Icon(Icons.person_add), text: 'Add User'),
                      Tab(icon: Icon(Icons.person_pin), text: 'Get User'),
                      Tab(icon: Icon(Icons.phone_in_talk), text: 'Active Calls'),
                      Tab(icon: Icon(Icons.history), text: 'Recent Calls'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildAddUserForm(),
                        _buildGetUserForm(),
                        _buildActiveCallsList(),
                        _buildRecentCallsList()
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          Expanded(child: _buildStatCard(icon: Icons.phone_in_talk, color: Colors.green, count: _activeCalls.length, label: 'Active Calls')),
          const SizedBox(width: 16),
          Expanded(child: _buildStatCard(icon: Icons.history, color: Colors.blue, count: _recentCalls.length, label: 'Recent Calls')),
        ],
      ),
    );
  }

  Widget _buildStatCard({required IconData icon, required Color color, required int count, required String label}) {
    return Card(
      color: color.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 8),
            Text('$count', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveCallsList() {
    if (_activeCalls.isEmpty) {
      return _buildEmptyState(icon: Icons.phone_disabled, title: 'No active calls', subtitle: 'Calls will appear here when they start');
    }
    return ListView.builder(
      itemCount: _activeCalls.length,
      itemBuilder: (context, index) {
        final call = _activeCalls[index];
        return _buildCallCard(call, isActive: true);
      },
    );
  }

  Widget _buildRecentCallsList() {
    if (_recentCalls.isEmpty) {
      return _buildEmptyState(icon: Icons.history, title: 'No recent calls', subtitle: 'Completed calls will appear here');
    }
    return ListView.builder(
      itemCount: _recentCalls.length,
      itemBuilder: (context, index) {
        final call = _recentCalls[index];
        return _buildCallCard(call, isActive: false);
      },
    );
  }

  Widget _buildCallCard(Map<String, dynamic> call, {required bool isActive}) {
    final startTime = call['startTime'] as DateTime?;
    final endTime = call['endTime'] as DateTime?;
    final audioFile = call['audio_file'] ?? call['audioFile'] ?? call['recording_url'];
    final liveStreamUrl = call['live_stream_url'];
    final callId = call['callId'];
    final isCurrentlyPlaying = _currentlyPlayingUrl == audioFile || _currentlyPlayingUrl == liveStreamUrl;
    final isLiveStreamAvailable = liveStreamUrl != null && isActive;

    if (startTime == null) {
      debugPrint("Warning: startTime is null for call: $call");
      return const SizedBox.shrink();
    }

    final duration = isActive ? DateTime.now().difference(startTime) : endTime != null ? endTime.difference(startTime) : Duration.zero;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      elevation: 4,
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(backgroundColor: _getStatusColor(call['status']), child: Icon(_getStatusIcon(call['status']), color: Colors.white)),
        title: Text(call['contactName'] ?? 'Unknown Contact', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${call['senderNumber']} → ${call['receiverNumber']}', overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(children: [const Icon(Icons.access_time, size: 14), const SizedBox(width: 4), Text('Duration: ${_formatDurationFromSeconds(duration.inSeconds)}', style: const TextStyle(fontSize: 12))]),
            if (isLiveStreamAvailable) ...[
              const SizedBox(height: 4),
              Row(children: [const Icon(Icons.live_tv, size: 14, color: Colors.red), const SizedBox(width: 4), Text('Live Stream Available', style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.bold))]),
            ],
          ],
        ),
        trailing: SizedBox(
          width: 100,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: _getStatusColor(call['status']), borderRadius: BorderRadius.circular(12)),
                child: Text(call['status'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              if (_shouldShowPlayButton(call, isActive)) _buildPlaybackControls(isCurrentlyPlaying: isCurrentlyPlaying, isLiveStream: isLiveStreamAvailable, call: call),
            ],
          ),
        ),
      ),
    );
  }

  Color _getStatusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'active':
        return Colors.green;
      case 'incoming':
        return Colors.blue;
      case 'ended':
        return Colors.grey;
      default:
        return Colors.orange;
    }
  }

  IconData _getStatusIcon(String? status) {
    switch (status?.toLowerCase()) {
      case 'active':
        return Icons.phone_in_talk;
      case 'incoming':
        return Icons.call_received;
      case 'ended':
        return Icons.call_end;
      default:
        return Icons.phone;
    }
  }

  Widget _buildEmptyState({required IconData icon, required String title, required String subtitle}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 18, color: Colors.grey)),
          Text(subtitle, style: const TextStyle(fontSize: 14, color: Colors.grey)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _stopAudio();
    _stopLiveAudioStream();
    WebRTCHelper.cleanup();
    _subscription?.cancel();
    _channel?.sink.close();
    _webSocketChannel?.sink.close();
    _remoteRenderer.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}
