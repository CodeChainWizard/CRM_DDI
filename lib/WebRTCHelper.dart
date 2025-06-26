// WebRTCHelper.dart
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:logging/logging.dart';
import 'WebSocketHelper.dart';

class WebRTCHelper {
  static final Logger _logger = Logger('WebRTCHelper');

  static RTCPeerConnection? _peerConnection;
  static MediaStream? _localStream;
  static WebSocketChannel? _signalingChannel;
  static String? _currentCallId;
  static bool _isLiveStreamActive = false;

  static const Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

  static const Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
    'sdpSemantics': 'unified-plan',
  };

  static Future<void> initializeCaller(String callId, WebSocketChannel signalingChannel) async {
    try {
      _logger.info('Initializing caller');
      _signalingChannel = signalingChannel;
      _currentCallId = callId;

      _peerConnection = await createPeerConnection(_iceServers, _config);

      _peerConnection!.onIceCandidate = (candidate) {
        _sendSignalingMessage({
          'type': 'ice-candidate',
          'callId': callId,
          'candidate': candidate.toMap(),
        });
      };

      _peerConnection!.onConnectionState = (state) {
        _logger.info('Connection State: $state');
      };

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });

      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      await _sendSignalingMessage({
        'type': 'offer',
        'callId': callId,
        'offer': offer.toMap(),
      });
    } catch (e, stack) {
      _logger.severe('Error initializing caller', e, stack);
      await _cleanup();
      rethrow;
    }
  }

  static Future<void> initializeReceiver({
    required String callId,
    required WebSocketChannel signalingChannel,
    required Function(MediaStream) onRemoteStream,
    required Function(String) onStreamUrl,
  }) async {
    try {
      await _cleanup();
      _signalingChannel = signalingChannel;
      _currentCallId = callId;

      _peerConnection = await createPeerConnection(
        _iceServers,
        {
          ..._config,
          'bundlePolicy': 'max-bundle',
          'rtcpMuxPolicy': 'require',
        },
      );

      _peerConnection!.onIceCandidate = (candidate) {
        _sendSignalingMessage({
          'type': 'ice_candidate',
          'callId': callId,
          'candidate': candidate.toMap(),
          'timestamp': DateTime.now().toIso8601String(),
        });
      };

      _peerConnection!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          final stream = event.streams[0];
          onRemoteStream(stream);
          if (stream.id.startsWith('http')) {
            onStreamUrl(stream.id);
          }
        }
      };

      _peerConnection!.onConnectionState = (state) => _logger.info('Conn state: $state');

      await _peerConnection!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    } catch (e, stack) {
      _logger.severe('Error initializing receiver', e, stack);
      await _cleanup();
      rethrow;
    }
  }

  static Future<void> handleSignalingMessage(Map<String, dynamic> message) async {
    try {
      final type = message['type'];
      final callId = message['callId'];

      switch (type) {
        case 'offer':
          final offer = RTCSessionDescription(
            message['offer']['sdp'],
            message['offer']['type'],
          );
          await _peerConnection!.setRemoteDescription(offer);
          final answer = await _peerConnection!.createAnswer();
          await _peerConnection!.setLocalDescription(answer);
          await _sendSignalingMessage({
            'type': 'answer',
            'callId': callId,
            'answer': answer.toMap(),
          });
          break;

        case 'answer':
          final answer = RTCSessionDescription(
            message['answer']['sdp'],
            message['answer']['type'],
          );
          await _peerConnection!.setRemoteDescription(answer);
          break;

        case 'ice-candidate':
          await _peerConnection!.addCandidate(RTCIceCandidate(
            message['candidate']['candidate'],
            message['candidate']['sdpMid'],
            message['candidate']['sdpMLineIndex'],
          ));
          break;
      }
    } catch (e, stack) {
      _logger.severe('Error handling signaling message', e, stack);
    }
  }

  static Future<void> startLiveAudioStream(String callId) async {
    try {
      if (_isLiveStreamActive) return;

      _localStream ??= await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        });

      _localStream!.getAudioTracks().forEach((track) => track.enabled = true);
      _isLiveStreamActive = true;

      await _sendSignalingMessage({
        'type': 'live_stream_started',
        'callId': callId,
        'stream_url': 'webrtc://$callId',
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e, stack) {
      _logger.severe('Failed to start live stream', e, stack);
      _isLiveStreamActive = false;
      rethrow;
    }
  }

  static Future<void> stopLiveAudioStream() async {
    try {
      if (!_isLiveStreamActive) return;
      _localStream?.getAudioTracks().forEach((track) => track.enabled = false);

      if (WebSocketHelper.isConnected && _currentCallId != null) {
        await _sendSignalingMessage({
          'type': 'live_stream_ended',
          'callId': _currentCallId,
          'timestamp': DateTime.now().toIso8601String(),
        });
      }

      _isLiveStreamActive = false;
    } catch (e, stack) {
      _logger.severe('Failed to stop live stream', e, stack);
      _isLiveStreamActive = false;
      rethrow;
    }
  }

  static Future<void> _sendSignalingMessage(Map<String, dynamic> message) async {
    try {
      if (_signalingChannel?.closeCode != null) throw Exception('WebSocket closed');
      _signalingChannel?.sink.add(json.encode(message));
    } catch (e, stack) {
      _logger.severe('Failed to send signaling message', e, stack);
      rethrow;
    }
  }

  static Future<void> _cleanup() async {
    try {
      await _peerConnection?.close();
      await _localStream?.dispose();
      _peerConnection = null;
      _localStream = null;
      _currentCallId = null;
    } catch (e, stack) {
      _logger.warning('Error during cleanup', e, stack);
    }
  }

  static Future<void> cleanup() async => await _cleanup();

  static bool get isLiveStreamActive => _isLiveStreamActive;
}