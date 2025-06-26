
import 'dart:io';

import 'package:flutter/services.dart';

class PhoneService {
  static const EventChannel _eventChannel = EventChannel('com.example.event/events');
  static const MethodChannel _helperChannel = MethodChannel('flutter.event/helper');

  static Future<String?> getMyPhoneNumber({bool forDisplay = false}) async {
    try {
      if (Platform.isAndroid) {
        final String? number = await _helperChannel.invokeMethod('getMyPhoneNumber');
        return forDisplay ? "My Number: $number" : number;
      }
      return forDisplay ? "Not Supported" : null;
    } catch (e) {
      print("Error getting my phone number: $e");
      return forDisplay ? "Error" : null;
    }
  }

  static Stream<Map<String, String>> get phoneEvents {
    return _eventChannel.receiveBroadcastStream().map((event) {
      String eventStr = event as String;
      if (eventStr.startsWith("MY_PHONE_NUMBER:")) {
        return {"type": "my_number", "number": eventStr.substring(16)};
      } else if (eventStr.startsWith("INCOMING_CALL:")) {
        String number = eventStr.substring(13);
        Map<String, String> data = {
          "type": "incoming_call",
          "number": number == "none" ? "" : number ?? "",
        };
        return data;
      }
      return {};
    });
  }
}

// Usage
void listenPhoneEvents() {
  PhoneService.phoneEvents.listen((event) {
    if (event["type"] == "my_number") {
      print("My number: ${event["number"]}");
    } else if (event["type"] == "incoming_call") {
      print("Incoming call: ${event["number"]}");
    }
  });
}