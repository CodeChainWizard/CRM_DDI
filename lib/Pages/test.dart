import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:phone_state/phone_state.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(MaterialApp(
    title: 'Call Note App',
    home: CallNoteApp(),
    debugShowCheckedModeBanner: false,
  ));
}

class CallNoteApp extends StatefulWidget {
  @override
  _CallNoteAppState createState() => _CallNoteAppState();
}

class _CallNoteAppState extends State<CallNoteApp> {
  String? callStatus;
  String? noteText;
  String? currentNumber;
  PhoneStateStatus? _currentCallStatus;
  bool _isDialogShown = false;
  bool _isCallActive = false;
  StreamSubscription<PhoneState>? _phoneStateSubscription;

  @override
  void initState() {
    super.initState();
    _requestPermissionAndListen();
  }

  @override
  void dispose() {
    _phoneStateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissionAndListen() async {
    await Permission.phone.request();

    _phoneStateSubscription?.cancel();

    _phoneStateSubscription = PhoneState.stream.listen((PhoneState event) {
      if (!mounted) return;

      final status = event.status;
      final number = event.number ?? 'Unknown';

      setState(() {
        callStatus = status.toString();
        currentNumber = number;
      });

      _handleCallStateChange(status);
    }, onError: (error) {
      print("Phone state error: $error");
    });
  }

  void _handleCallStateChange(PhoneStateStatus status) {
    if (!mounted) return; // Safety check

    // Handle call start
    if ((status == PhoneStateStatus.CALL_INCOMING ||
        status == PhoneStateStatus.CALL_STARTED) &&
        !_isCallActive) {
      _isCallActive = true;
      _currentCallStatus = status;
      _showNoteTakingDialog();
    }
    // Handle call end
    else if (status == PhoneStateStatus.CALL_ENDED ||
        status == PhoneStateStatus.NOTHING) {
      if (_isCallActive) {
        _isCallActive = false;
        _submitNoteToBackend();
      }
    }
  }

  void _showNoteTakingDialog() {
    if (_isDialogShown || !mounted) return;

    _isDialogShown = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text("Call Note for $currentNumber"),
          content: SingleChildScrollView(
            child: TextField(
              autofocus: true,
              maxLines: 5,
              onChanged: (val) => noteText = val,
              decoration: InputDecoration(
                hintText: "Write your notes about this call...",
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              child: Text("Save & Close"),
              onPressed: () {
                Navigator.pop(context);
                if (mounted) {
                  setState(() {
                    _isDialogShown = false;
                  });
                }
              },
            ),
          ],
        );
      },
    ).then((_) {
      if (mounted) {
        setState(() {
          _isDialogShown = false;
        });
      }
    });
  }

  Future<void> _submitNoteToBackend() async {
    if (noteText != null && noteText!.trim().isNotEmpty && mounted) {
      try {
        print("📞 Sending note to backend...");
        final response = await http.post(
          Uri.parse("http://192.168.1.23:8001/api/notes/"),
          body: {
            "note": noteText!,
            "caller": currentNumber ?? "Unknown",
            "call_status": _currentCallStatus.toString(),
            "timestamp": DateTime.now().toIso8601String(),
          },
        );

        if (response.statusCode == 200) {
          print("Note sent successfully!");
          _showSuccessMessage();
        } else {
          print("Failed to send note. Status: ${response.statusCode}");
          _showErrorMessage("Failed to save note");
        }
      } catch (e) {
        print("Error sending note: $e");
        _showErrorMessage("Connection error: ${e.toString()}");
      }
    } else {
      print("Note is empty or widget is not mounted");
    }

    // Reset for next call
    if (mounted) {
      setState(() {
        noteText = null;
      });
    }
  }

  void _showSuccessMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Note saved successfully!"),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _showErrorMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Call Note App"),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _requestPermissionAndListen,
            tooltip: "Refresh call listener",
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Current Call Status:",
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 10),
            Text(
              callStatus ?? 'Idle',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: _getStatusColor(),
              ),
            ),
            SizedBox(height: 20),
            if (currentNumber != null)
              Text(
                "Number: $currentNumber",
                style: TextStyle(fontSize: 16),
              ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor() {
    switch (_currentCallStatus) {
      case PhoneStateStatus.CALL_INCOMING:
        return Colors.blue;
      case PhoneStateStatus.CALL_STARTED:
        return Colors.green;
      case PhoneStateStatus.CALL_ENDED:
        return Colors.red;
      default:
        return Colors.black;
    }
  }
}