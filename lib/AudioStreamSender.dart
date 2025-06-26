import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class AudioStreamSender {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer(logLevel: Level.nothing);

  final WebSocketChannel _channel;
  bool _isRecording = false;

  final StreamController<Uint8List> _pcmController = StreamController<Uint8List>();
  StreamSubscription? _progressSubscription;
  StreamSubscription? _pcmSubscription;
  StreamSubscription? _socketSubscription;

  final List<Uint8List> _receivedChunks = [];

  AudioStreamSender(String backendWsUrl)
      : _channel = WebSocketChannel.connect(Uri.parse(backendWsUrl));

  Future<void> init() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw Exception("Microphone permission denied");
    }

    await _recorder.openRecorder();
    await _player.openPlayer();
    
    _socketSubscription = _channel.stream.listen((message) {
      // print("📥 Raw WebSocket Message: $message");

      try {
        final decoded = jsonDecode(message);
        if (decoded['type'] == 'pcm') {
          final chunk = base64Decode(decoded['chunk']);
          // print("🔻 Received PCM chunk (${chunk.length} bytes)");

          _receivedChunks.add(chunk);
          _player.startPlayer(
            fromDataBuffer: chunk,
            codec: Codec.pcm16,
            sampleRate: 16000,
            numChannels: 1,
          );
        }
      } catch (e) {
        print("❌ Error handling incoming PCM: $e");
      }
    });
  }

  Future<void> startRecording() async {
    if (_isRecording) return;

    _isRecording = true;

    await _recorder.startRecorder(
      toStream: _pcmController.sink,
      codec: Codec.pcm16,
      sampleRate: 16000,
      numChannels: 1,
    );

    _pcmSubscription = _pcmController.stream.listen((chunk) {
      // print("📦 Chunk sent: ${chunk.length} bytes");

      final alignedChunk = Uint8List.fromList(chunk); // ensures 0 offset
      final samples = alignedChunk.buffer.asInt16List();
      // print("🔊 PCM Samples (first 20): ${samples.take(20).toList()}");


      _channel.sink.add(jsonEncode({
        'type': 'pcm',
        'chunk': base64Encode(chunk),
      }));
    });

    _progressSubscription = _recorder.onProgress?.listen((event) {
      // print("⏱️ Duration: ${event.duration.inMilliseconds}ms | 🔊 dB: ${event.decibels?.toStringAsFixed(2) ?? 'N/A'}");
    });
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    _isRecording = false;

    await _recorder.stopRecorder();
    await _progressSubscription?.cancel();
    await _pcmSubscription?.cancel();
    await _pcmController.close();
  }

  Future<void> dispose() async {
    await stopRecording();
    await _recorder.closeRecorder();
    await _socketSubscription?.cancel();
    await _channel.sink.close();
    await _player.closePlayer();
  }

  List<Uint8List> get receivedChunks => _receivedChunks;
}
