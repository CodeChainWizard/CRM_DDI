import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/material.dart';

class WebSocketHelper {
  static WebSocketChannel? _channel;
  static bool _isConnected = false;
  static const String _webSocketUrl = 'ws://192.168.1.23:8001/ws/call/';

  // Audio streaming specific
  static String? _currentCallId;
  static bool _isStreamingAudio = false;

  static Future<WebSocketChannel?> connect() async {
    try {
      await disconnect();

      print("Attempting to connect to $_webSocketUrl");
      _channel = WebSocketChannel.connect(Uri.parse(_webSocketUrl));
      _isConnected = true;

      print("WebSocket connected to admin dashboard");
      return _channel;
    } catch (e) {
      print("❌ WebSocket connection failed: $e");
      _isConnected = false;
      rethrow;
    }
  }


  static Future<void> disconnect() async {
    try {
      await _channel?.sink.close();
    } catch (e) {
      print("Error while disconnecting: $e");
    } finally {
      _isConnected = false;
      _channel = null;
      _isStreamingAudio = false;
      _currentCallId = null;
      print("WebSocket disconnected");
    }
  }

  static Stream get stream {
    if (_channel == null) {
      throw Exception("WebSocket not connected");
    }
    return _channel!.stream;
  }

  static Future<void> sendCallStarted({
    required String senderNumber,
    required String receiverNumber,
    required String contactName,
    required DateTime startTime,
    String? callId,
    String? audioFile,
  }) async {
    _currentCallId = callId ?? _generateCallId();

    await sendMessage({
      'type': 'call_started',
      'callId': _currentCallId,
      'senderNumber': senderNumber,
      'receiverNumber': receiverNumber,
      'contactName': contactName,
      'startTime': startTime.toIso8601String(),
      'timestamp': DateTime.now().toIso8601String(),
      'status': 'Active',
      'hasLiveAudio': true, // Indicate this call supports live audio
      'audio_file':audioFile
    });
  }

  static Future<void> sendMessage(Map<String, dynamic> message) async {
    if (!_isConnected) {
      await connect();
    }

    try {
      if (_channel != null) {
        _channel!.sink.add(json.encode(message));
        print("Sent to admin dashboard: ${json.encode(message)}");
      }
    } catch (e) {
      print("Error sending WebSocket message: $e");
      rethrow;
    }
  }

  static Future<void> sendCallEnded({
    required String senderNumber,
    required String receiverNumber,
    required String contactName,
    required DateTime startTime,
    required DateTime endTime,
    required Duration duration,
  }) async {
    if (!_isConnected) await connect();

    // Stop audio streaming
    stopAudioStreaming();

    final message = {
      'type': 'call_ended',
      'callId': _currentCallId,
      'senderNumber': senderNumber,
      'receiverNumber': receiverNumber,
      'contactName': contactName,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'duration': duration.inSeconds,
      'timestamp': DateTime.now().toIso8601String(),
    };

    print("SEND DATA USING SOCKET");
    _sendMessage(message);

    _currentCallId = null;
  }

  static Future<void> sendIncomingCall({
    required String callerNumber,
    required String contactName,
    String? callId,
  }) async {
    if (!_isConnected) await connect();

    _currentCallId = callId ?? _generateCallId();

    final message = {
      'type': 'incoming_call',
      'callId': _currentCallId,
      'callerNumber': callerNumber,
      'contactName': contactName,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _sendMessage(message);
  }

  // Audio Streaming Methods
  static Future<void> startAudioStreaming() async {
    if (!_isConnected) await connect();

    if (_currentCallId == null) {
      print("Cannot start audio streaming: No active call");
      return;
    }

    _isStreamingAudio = true;

    final message = {
      'type': 'audio_stream_start',
      'callId': _currentCallId,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _sendMessage(message);
    print("Started audio streaming for call: $_currentCallId");
  }

  static Future<void> stopAudioStreaming() async {
    if (!_isStreamingAudio || _currentCallId == null) return;

    _isStreamingAudio = false;

    final message = {
      'type': 'audio_stream_stop',
      'callId': _currentCallId,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _sendMessage(message);
    print("Stopped audio streaming for call: $_currentCallId");
  }

  static Future<void> sendAudioChunk(Uint8List audioData) async {
    if (!_isConnected || !_isStreamingAudio || _currentCallId == null) {
      return;
    }

    try {
      // Convert audio data to base64 for transmission
      String base64Audio = base64Encode(audioData);

      final message = {
        'type': 'audio_chunk',
        'callId': _currentCallId,
        'audioData': base64Audio,
        'timestamp': DateTime.now().toIso8601String(),
        'chunkSize': audioData.length,
      };

      // Send binary data directly for better performance
      _channel!.sink.add(json.encode(message));

    } catch (e) {
      print("Error sending audio chunk: $e");
    }
  }

  static Future<void> sendCallUpdate({
    required String senderNumber,
    required String receiverNumber,
    required String status,
    Map<String, dynamic>? additionalData,
  }) async {
    if (!_isConnected) await connect();

    final message = {
      'type': 'call_update',
      'callId': _currentCallId,
      'senderNumber': senderNumber,
      'receiverNumber': receiverNumber,
      'status': status,
      'timestamp': DateTime.now().toIso8601String(),
      if (additionalData != null) ...additionalData,
    };

    _sendMessage(message);
  }

  static void _sendMessage(Map<String, dynamic> message) {
    try {
      if (_channel != null && _isConnected) {
        _channel!.sink.add(json.encode(message));
        print("Sent to admin dashboard: ${json.encode(message)}");
      } else {
        print("WebSocket not connected, cannot send message");
      }
    } catch (e) {
      print("Error sending WebSocket message: $e");
    }
  }

  static String _generateCallId() {
    return 'call_${DateTime.now().millisecondsSinceEpoch}_${(1000 + (999 * (DateTime.now().microsecond / 1000000))).round()}';
  }

  // Getters
  static bool get isConnected => _isConnected;
  static bool get isStreamingAudio => _isStreamingAudio;
  static String? get currentCallId => _currentCallId;
}