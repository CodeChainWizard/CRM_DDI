import 'dart:convert';
import 'dart:io';
import 'package:http_parser/http_parser.dart';
import 'package:http/http.dart' as http;

class API {
  static final String _baseUrl = "http://192.168.1.6:8001";

  static Future<Map<String, dynamic>?> sendOtp(String phoneNumber) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/send-otp/'),
        body: {'mobileno': phoneNumber},
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        return {'error': 'Failed to send OTP: ${response.statusCode}'};
      }
    } catch (e) {
      return {'error': 'Exception: $e'};
    }
  }

  static Future<Map<String, dynamic>?> verifyOtp({required String phoneNumber,required String otp,}) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/verify-otp/'),
        body: {
          'mobileno': phoneNumber,
          'otp': otp,
        },
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        return {'error': 'OTP verification failed: ${response.statusCode}'};
      }
    } catch (e) {
      return {'error': 'Exception: $e'};
    }
  }

  static Future<bool> adminLogin({required String email,required String password,}) async {
    try {
      final response = await http.post(
        Uri.parse("$_baseUrl/api/admin/"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data is bool) {
          return data;
        } else if (data is Map && data['login'] != null) {
          return data['login'] == true;
        } else {
          print("Unexpected response format: $data");
          return false;
        }
      } else {
        print("Login failed with status: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      print("Error while Admin login: $e");
      return false;
    }
  }


  static Future<bool> sendCallData({
    required String callId,
    required String senderNumber,
    required String receiverNumber,
    required DateTime callStartTime,
    required Duration duration,
    required File audioFile,
  }) async {
    try {
      print("------------> Starting call data upload...");
      print("Call Id: $callId");
      print("Sender: $senderNumber");
      print("Receiver: $receiverNumber");
      print("Start time: ${callStartTime.toIso8601String()}");
      print("Duration: ${duration.inSeconds} seconds");
      print("Audio file: ${audioFile}");

      if (!await audioFile.exists()) {
        print("Audio file does not exist: ${audioFile.path}");
        return false;
      }

      int fileSize = await audioFile.length();
      print(
        "File size: ${fileSize} bytes (${(fileSize / 1024 / 1024).toStringAsFixed(2)} MB)",
      );

      final uri = Uri.parse("$_baseUrl/api/calls/");
      final request = http.MultipartRequest("POST", uri);

      request.fields["callId"] = callId;
      request.fields['sender_ph'] = senderNumber;
      request.fields['receiver_ph'] = receiverNumber;
      request.fields['start_time'] = callStartTime.toIso8601String();
      request.fields['duration'] = duration.inSeconds.toString();

      request.files.add(
        await http.MultipartFile.fromPath(
          'audio_file',
          audioFile.path,
          contentType: MediaType('audio', 'm4a'),
        ),
      );

      request.headers.addAll({'Accept': 'application/json'});

      print("Sending request to: $uri");

      final response = await request.send().timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          print("Request timeout after 5 minutes");
          throw Exception("Upload timeout");
        },
      );

      String responseBody = await response.stream.bytesToString();

      print("Response status: ${response.statusCode}");
      print("Response headers: ${response.headers}");
      print("Response body: $responseBody");

      if (response.statusCode == 200 || response.statusCode == 201) {
        print("Call data uploaded successfully");

        try {
          Map<String, dynamic> jsonResponse = jsonDecode(responseBody);
          if (jsonResponse.containsKey('id')) {
            print("Call ID: ${jsonResponse['id']}");
          }
          if (jsonResponse.containsKey('message')) {
            print("Server message: ${jsonResponse['message']}");
          }
        } catch (e) {
          print("Could not parse JSON response: $e");
        }

        return true;
      } else {
        print("Upload failed with status: ${response.statusCode}");
        print("Error response: $responseBody");
        return false;
      }
    } catch (e) {
      print("Exception during upload: $e");
      return false;
    }
  }

  static Future<Map<String, dynamic>?> addUserByAdmin(
    String phoneNumber,
  ) async {
    try {
      final url = Uri.parse("$_baseUrl/api/users/");
      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"mobileno": phoneNumber}),
          )
          .timeout(const Duration(seconds: 15));

      print("Status: ${response.statusCode}, Body: ${response.body}");

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        data['statusCode'] = response.statusCode; // attach status code
        return data;
      } else {
        return {"statusCode": response.statusCode, "error": response.body};
      }
    } catch (e) {
      print("Error adding user: $e");
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getCallDetailsByNumber(String phoneNumber,) async {
    try {
      print("Fetching call details for: $phoneNumber");

      final url = Uri.parse("$_baseUrl/api/users/$phoneNumber");

      final response = await http
          .get(url, headers: {"Content-Type": "application/json"})
          .timeout(const Duration(seconds: 15));

      print("GET Response: ${response.statusCode}");
      print("Response body: ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        print("Successfully fetched call details");
        return data;
      } else {
        print("Failed to fetch details: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Error fetching call details: $e");
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>?> getCallDetailsUser() async {
    try {
      final url = Uri.parse("$_baseUrl/api/users/");

      final response = await http
          .get(url, headers: {"Content-Type": "application/json"})
          .timeout(const Duration(seconds: 15));

      print("GET Response: ${response.statusCode}");
      print("Response body: ${response.body}");

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body);
        final users = decoded.cast<Map<String, dynamic>>();
        print("Successfully fetched user list");
        return users;
      } else {
        print("Failed to fetch details: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Error fetching call details: $e");
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>?> getCallNumberAccess() async {
    try {
      final response = await http.get(
        Uri.parse("$_baseUrl/api/recording_mobile/"),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body) as List;
        return data.map((item) => item as Map<String, dynamic>).toList();
      } else {
        print("Failed to load Number of Access user: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Error fetching call number: $e");
      return null;
    }
  }

  static Future<bool> updateUserStatus(
    String mobileNo,
    Map<String, dynamic> statusData,
  ) async {
    try {
      final url = Uri.parse("$_baseUrl/api/users/$mobileNo/");
      final response = await http.put(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(statusData),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        print("Successfully updated user status: $data");
        return true;
      } else {
        print("Failed to update user status: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      print("Error updating status: $e");
      return false;
    }
  }

  static Future<Map<String, dynamic>?> sendSelectedNumbers(
    String phoneNumber,
    List<String> selectedNumbers,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/access/$phoneNumber/'),
        headers: <String, String>{
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, dynamic>{'access_mobile': selectedNumbers}),
      );

      print("PAYLOAD ACCESS: $selectedNumbers");

      if (response.statusCode == 201) {
        print("User Access: ${response.body}");
        return jsonDecode(response.body);
      } else {
        print('Failed to send selected numbers: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Error sending selected numbers: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> DeleteSelectedNumbers(
    String phoneNumber,
    List<String> selectedNumbers,
  ) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/api/access/$phoneNumber/'),
        headers: <String, String>{
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: jsonEncode(<String, dynamic>{'access_mobile': selectedNumbers}),
      );

      print("PAYLOAD ACCESS: $selectedNumbers");

      if (response.statusCode == 200) {
        print("User Access: ${response.body}");
        return jsonDecode(response.body);
      } else {
        print('Failed to send selected numbers: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Error sending selected numbers: $e');
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>?> getCallDetails({
    required int page,
    int limit = 0,
    String? phoneNumber,
  }) async {
    try {
      print("Fetching call details (page: $page, limit: $limit)...");

      final queryParams = {
        'skip': '$limit',
        'take': '$page',
        if (phoneNumber != null && phoneNumber.isNotEmpty) 'phoneNumber': phoneNumber,
      };

      final uri = Uri.parse("$_baseUrl/api/calls").replace(queryParameters: queryParams);

      final response = await http
          .get(uri, headers: {"Content-Type": "application/json"})
          .timeout(const Duration(seconds: 15));

      print("GET Response: ${response.statusCode}");
      print("Response body: ${response.body}");

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body);
        final List<Map<String, dynamic>> callList =
        decoded.cast<Map<String, dynamic>>();
        print("Fetched ${callList.length} calls on page $page");
        return callList;
      } else {
        print("Failed to fetch details: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Error fetching call details: $e");
      return null;
    }
  }


  // static Future<List<Map<String, dynamic>>?> getCallDetails() async {
  //   try {
  //     print("Fetching all call details...");
  //
  //     final url = Uri.parse("$_baseUrl/api/calls");
  //
  //     final response = await http
  //         .get(url, headers: {"Content-Type": "application/json"})
  //         .timeout(const Duration(seconds: 15));
  //
  //     print("GET Response: ${response.statusCode}");
  //     print("Response body: ${response.body}");
  //
  //     if (response.statusCode == 200) {
  //       final List<dynamic> decoded = jsonDecode(response.body);
  //       final List<Map<String, dynamic>> callList =
  //           decoded.cast<Map<String, dynamic>>();
  //       print("Successfully fetched ${callList.length} call records");
  //       return callList;
  //     } else {
  //       print("Failed to fetch details: ${response.statusCode}");
  //       return null;
  //     }
  //   } catch (e) {
  //     print("Error fetching call details: $e");
  //     return null;
  //   }
  // }

  static Future<bool> testConnection() async {
    try {
      print("Testing backend connection...");

      final response = await http
          .get(
            Uri.parse("$_baseUrl/api/calls"),
            headers: {"Content-Type": "application/json"},
          )
          .timeout(const Duration(seconds: 10));

      print("Connection test result: ${response.statusCode}");

      if (response.statusCode == 200) {
        print("Backend is reachable");
        return true;
      } else {
        print("Backend responded with: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      print("Backend connection failed: $e");
      return false;
    }
  }

  static Future<List<String>?> getAccessNumberByUser(String phoneNumber) async {
    try {
      final response = await http.get(
        Uri.parse("$_baseUrl/api/access/$phoneNumber/"),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Expecting: { "access_mobile": ["+9119033020277"] }
        if (data is Map && data['access_mobile'] is List) {
          return List<String>.from(data['access_mobile']);
        } else {
          print("Unexpected response format: $data");
          return null;
        }
      } else {
        print("HTTP error: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Access get Number error: $phoneNumber - $e");
      return null;
    }
  }

  static Future<bool> deleteCall(String callId) async {
    try {
      print("🗑Deleting call: $callId");

      final url = Uri.parse("$_baseUrl/api/calls/$callId");
      final response = await http
          .delete(url, headers: {"Content-Type": "application/json"})
          .timeout(const Duration(seconds: 15));

      print("Delete response: ${response.statusCode}");

      if (response.statusCode == 200 || response.statusCode == 204) {
        print("Call deleted successfully");
        return true;
      } else {
        print("Failed to delete call: ${response.statusCode}");
        return false;
      }
    } catch (e) {
      print("Error deleting call: $e");
      return false;
    }
  }

  static Future<void> debugNetworkInfo() async {
    try {
      print("Network Debug Info:");
      print("Base URL: $_baseUrl");

      // Try to resolve the host
      final addresses = await InternetAddress.lookup('192.168.1.7');
      print(
        "IP Resolution: ${addresses.map((addr) => addr.address).join(', ')}",
      );

      // Test basic connectivity
      final socket = await Socket.connect(
        '192.168.1.7',
        8001,
        timeout: const Duration(seconds: 5),
      );
      print("Socket connection successful");
      socket.destroy();
    } catch (e) {
      print("Network debug failed: $e");
    }
  }

  static Future<void> updateCallStatus(String callId, String status) async {
    final response = await http.put(
      Uri.parse("$_baseUrl/api/calls/$callId/"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"status": status}),
    );

    if (response.statusCode != 200) {
      print("ERROR WHILE UPDATE STATUS: ${response.body}");
      throw Exception('Failed to update call status');
    }
  }
}

// import 'dart:convert';
// import 'dart:io';
// import 'package:http_parser/http_parser.dart';
// import 'package:http/http.dart' as http;
//
// class API {
//   static final String _baseUrl = "http://192.168.1.7:8001";
//
//   static Future<bool> sendCallData({
//     required String senderNumber,
//     required String receiverNumber,
//     required DateTime callStartTime,
//     required Duration duration,
//     required File audioFile,
//   }) async {
//     final uri = Uri.parse("$_baseUrl/api/calls/");
//
//     final request = http.MultipartRequest("POST", uri);
//
//     request.fields['sender_ph'] = senderNumber;
//     request.fields['receiver_ph'] = receiverNumber;
//     request.fields['start_time'] = callStartTime.toIso8601String();
//     request.fields['duration'] = duration.inSeconds.toString();
//
//     request.files.add(
//       await http.MultipartFile.fromPath(
//         'recording',
//         audioFile.path,
//         contentType: MediaType('audio', 'm4a'),
//       ),
//     );
//
//     try {
//       final response = await request.send();
//       print("Send status code: ${response.statusCode}");
//       return response.statusCode == 200;
//     } catch (e) {
//       print("Error sending call data: $e");
//       return false;
//     }
//   }
//
//   // static Future<bool> sendCallData({
//   //   required String senderNumber,
//   //   required String receiverNumber,
//   //   required DateTime callStartTime,
//   //   required Duration duration,
//   //   required File audioFile
//   // }) async {
//   //   final url = Uri.parse("$_baseUrl/api/calls/");
//   //   final body = jsonEncode({
//   //     "sender_ph": senderNumber,
//   //     "receiver_ph": receiverNumber,
//   //     "start_time": callStartTime.toIso8601String(),
//   //     "duration": duration.inSeconds,
//   //   });
//   //
//   //   try {
//   //     final response = await http.post(
//   //       url,
//   //       headers: {
//   //         "Content-Type": "application/json",
//   //       },
//   //       body: body,
//   //     );
//   //
//   //     print("API Response: ${response.statusCode} ${response.body}");
//   //
//   //     return response.statusCode == 200 || response.statusCode == 201;
//   //   } catch (e) {
//   //     print("API call failed: $e");
//   //     return false;
//   //   }
//   // }
//
//   static Future<Map<String, dynamic>?> getCallDetailsByNumber(
//     String phoneNumber,
//   ) async {
//     final url = Uri.parse("$_baseUrl/api/calls?number=$phoneNumber");
//
//     try {
//       final response = await http.get(
//         url,
//         headers: {"Content-Type": "application/json"},
//       );
//
//       print("GET Response: ${response.statusCode} ${response.body}");
//
//       if (response.statusCode == 200) {
//         return jsonDecode(response.body) as Map<String, dynamic>;
//       } else {
//         print("Failed to fetch details");
//         return null;
//       }
//     } catch (e) {
//       print("Error fetching call details: $e");
//       return null;
//     }
//   }
//
//   static Future<List<Map<String, dynamic>>?> getCallDetails() async {
//     final url = Uri.parse("$_baseUrl/api/calls");
//
//     try {
//       final response = await http.get(
//         url,
//         headers: {"Content-Type": "application/json"},
//       );
//
//       print("GET Response: ${response.statusCode} ${response.body}");
//
//       if (response.statusCode == 200) {
//         final List<dynamic> decoded = jsonDecode(response.body);
//         return decoded.cast<Map<String, dynamic>>();
//       } else {
//         print("Failed to fetch details");
//         return null;
//       }
//     } catch (e) {
//       print("Error fetching call details: $e");
//       return null;
//     }
//   }
// }
