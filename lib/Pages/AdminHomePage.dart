import 'package:crm_new/Pages/AdminLogin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../APIServices.dart';


class AdminHomePage extends StatefulWidget {
  const AdminHomePage({super.key});

  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  List<Map<String, dynamic>> callList = [];
  List<Map<String, dynamic>> filteredCallList = [];
  bool isLoading = true;
  bool isRefreshing = false;
  String? errorMessage;
  late AudioPlayer _audioPlayer;
  bool _isPlaying = false;
  String? _currentPlayingUrl;
  final TextEditingController _searchController = TextEditingController();

  DateTime? _startDate;
  DateTime? _endDate;

  String? _myPhoneNumber;

  String? _selectedStatusFilter;
  String? _selectedCallTypeFilter;

  String? callId;

  int _currentPage = 50;
  bool _isLoadingMore = false;
  bool _hasMoreData = false;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initializeAudioPlayer();
    _scrollController.addListener(_scrollListener);
    _loadData();
    _searchController.addListener(_filterCalls);
    _loadMyPhoneNumber();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_hasMoreData && !_isLoadingMore && !isRefreshing) {
        _loadData();
      }
    }
  }


  Future<void> _loadMyPhoneNumber() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _myPhoneNumber = prefs.getString('my_phone_number');
    });
  }

  void _filterCalls() {
    final query = _searchController.text.trim().toLowerCase();
    final normalizedQuery = query.replaceAll(RegExp(r'[^\d+]'), '');

    setState(() {
      filteredCallList = callList.where((call) {
        // Phone number matching
        final sender = _normalizePhoneNumber(call['sender_ph']?.toString() ?? '');
        final receiver = _normalizePhoneNumber(call['receiver_ph']?.toString() ?? '');
        final phoneMatches = query.isEmpty ||
            sender.contains(normalizedQuery) ||
            receiver.contains(normalizedQuery);

        // Date filtering
        if (call['start_time'] == null) return false;
        DateTime? callDate;
        try {
          callDate = DateTime.parse(call['start_time']).toLocal();
        } catch (_) {
          return false;
        }
        final startOk = _startDate == null || !callDate.isBefore(_startDate!);
        final endOk = _endDate == null || !callDate.isAfter(_endDate!);

        // Status filtering
        final rawStatus = call['status'];
        final status = rawStatus.toString().toLowerCase();
        final statusFilter = _selectedStatusFilter?.toLowerCase();
        final statusMatches = statusFilter == null ||
            (statusFilter == 'pending' && (status == 'pending' || status == '0')) ||
            (statusFilter == 'complete' && (status == 'complete' || status == '1'));

        // Call type filtering
        final isIncoming = call['receiver_ph'] == _myPhoneNumber;
        final callTypeMatches = _selectedCallTypeFilter == null ||
            (_selectedCallTypeFilter == 'Incoming' && isIncoming) ||
            (_selectedCallTypeFilter == 'Outgoing' && !isIncoming);

        return phoneMatches && startOk && endOk && statusMatches && callTypeMatches;
      }).toList();
    });
  }


  // void _filterCalls() {
  //   final query = _searchController.text.trim().toLowerCase();
  //   final normalizedQuery = query.replaceAll(RegExp(r'[^\d+]'), '');
  //
  //   setState(() {
  //     filteredCallList = callList.where((call) {
  //       // Phone number matching
  //       final sender = _normalizePhoneNumber(call['sender_ph']?.toString() ?? '');
  //       final receiver = _normalizePhoneNumber(call['receiver_ph']?.toString() ?? '');
  //       final phoneMatches = query.isEmpty ||
  //           sender.contains(normalizedQuery) ||
  //           receiver.contains(normalizedQuery);
  //
  //       // Date filtering
  //       if (call['start_time'] == null) return false;
  //       DateTime? callDate;
  //       try {
  //         callDate = DateTime.parse(call['start_time']).toLocal();
  //       } catch (_) {
  //         return false;
  //       }
  //
  //       final startOk = _startDate == null || !callDate.isBefore(_startDate!);
  //       final endOk = _endDate == null || !callDate.isAfter(_endDate!);
  //
  //       // Status filtering - handles both string and integer status values
  //       final rawStatus = call['status'];
  //       final status = rawStatus.toString().toLowerCase();
  //       final statusFilter = _selectedStatusFilter?.toLowerCase();
  //       final statusMatches = statusFilter == null ||
  //           (statusFilter == 'pending' && (status == 'pending' || status == '0')) ||
  //           (statusFilter == 'complete' && (status == 'complete' || status == '1'));
  //
  //       return phoneMatches && startOk && endOk && statusMatches;
  //     }).toList();
  //   });
  // }



  String _normalizePhoneNumber(String phoneNumber) {
    return phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
  }

  Future<void> _initializeAudioPlayer() async {
    try {
      _audioPlayer = AudioPlayer();
      _setupAudioPlayerListeners();
    } catch (e) {
      debugPrint("Failed to initialize audio player: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio player initialization failed. Audio playback will be disabled.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _setupAudioPlayerListeners() {
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
          if (state.processingState == ProcessingState.completed) {
            _isPlaying = false;
            _currentPlayingUrl = null;
          }
        });
      }
    });
  }

  Future<void> _loadData() async {
    if (_isLoadingMore) return;

    setState(() {
      isLoading = _currentPage == 1;
      errorMessage = null;
      _isLoadingMore = true;
    });

    try {
      final response = await API.getCallDetails(page: _currentPage);

      if (response == null || response.isEmpty) {
        if (_currentPage == 1) {
          setState(() {
            errorMessage = "No call data available";
            callList.clear(); // Clear the list only if it's the first page and no data is available
            filteredCallList.clear();
          });
        }
        _hasMoreData = false; // No more data for the next page
      } else {
        final sortedList = List<Map<String, dynamic>>.from(response);
        sortedList.sort((a, b) {
          final aTime = DateTime.tryParse(a['start_time'] ?? '') ?? DateTime(1970);
          final bTime = DateTime.tryParse(b['start_time'] ?? '') ?? DateTime(1970);
          return bTime.compareTo(aTime); // newest first
        });

        setState(() {
          if (_currentPage == 1) {
            callList.clear(); // Clear existing data only when refreshing or loading the first page
          }
          callList.addAll(sortedList); // Append new page data
          filteredCallList = List<Map<String, dynamic>>.from(callList);
          _currentPage++; // Increment page number for the next load
          _hasMoreData = sortedList.length == 10; // Assuming your API returns 10 items per page
        });
      }
    } catch (e) {
      setState(() {
        errorMessage = "Failed to load data. Please try again.";
      });
    } finally {
      setState(() {
        isLoading = false;
        isRefreshing = false;
        _isLoadingMore = false;
      });
    }
  }



  // Future<void> _loadData() async {
  //   if (_isLoadingMore) return;
  //
  //   setState(() {
  //     isLoading = _currentPage == 1;
  //     errorMessage = null;
  //     _isLoadingMore = true;
  //     if (_currentPage == 1) {
  //       callList.clear();
  //       filteredCallList.clear();
  //     }
  //   });
  //
  //   try {
  //     final response = await API.getCallDetails(page: _currentPage);
  //     print("RESPONSE CALL (Page $_currentPage): $response");
  //
  //     if (response == null || response.isEmpty) {
  //       if (_currentPage == 1) {
  //         setState(() {
  //           errorMessage = "No call data available";
  //         });
  //       }
  //       _hasMoreData = false; // No more data for the next page
  //     } else {
  //       final sortedList = List<Map<String, dynamic>>.from(response);
  //       sortedList.sort((a, b) {
  //         final aTime = DateTime.tryParse(a['start_time'] ?? '') ?? DateTime(1970);
  //         final bTime = DateTime.tryParse(b['start_time'] ?? '') ?? DateTime(1970);
  //         return bTime.compareTo(aTime); // newest first
  //       });
  //
  //       setState(() {
  //         callList.addAll(sortedList); // Append new page data
  //         filteredCallList = List<Map<String, dynamic>>.from(callList);
  //         _currentPage++; // Increment page number for the next load
  //       });
  //     }
  //   } catch (e) {
  //     setState(() {
  //       errorMessage = "Failed to load data. Please try again.";
  //     });
  //   } finally {
  //     setState(() {
  //       isLoading = false;
  //       isRefreshing = false;
  //       _isLoadingMore = false;
  //     });
  //   }
  // }


  String _formatDateTime(String isoString) {
    try {
      final dateTime = DateTime.parse(isoString).toLocal();
      return DateFormat('MMM dd, yyyy • hh:mm a').format(dateTime);
    } catch (e) {
      return isoString;
    }
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    if (duration.inHours > 0) {
      return "${duration.inHours}h ${duration.inMinutes % 60}m";
    }
    return "${duration.inMinutes}m ${duration.inSeconds % 60}s";
  }

  Widget _buildStatusDropdown(Map<String, dynamic> call) {
    final theme = Theme.of(context);

    const statusMap = {
      'pending': 'Pending',
      'complete': 'Complete',
      'Pending': 'Pending',
      'Complete': 'Complete',
    };

    final allowedStatuses = ['Pending', 'Complete'];

    final rawStatus = call['status'];
    final currentStatus = statusMap[rawStatus] ?? 'Pending';

    return DropdownButton<String>(
      value: currentStatus,
      icon: const Icon(Icons.arrow_drop_down),
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      style: theme.textTheme.bodyMedium,
      underline: const SizedBox(height: 0),
      onChanged: (String? newStatus) async {
        if (newStatus != null && newStatus != currentStatus) {
          final oldStatus = call['status'];
          setState(() => call['status'] = newStatus);

          try {
            final statusToSend = newStatus == 'Pending' ? "pending" : "complete";
            await API.updateCallStatus(call['id'].toString(), statusToSend.toString());
            _showSnackBar("Status updated to $newStatus");
          } catch (e) {
            print("ERROR UPDATE STATUS: $e");
            _showSnackBar("Failed to update status");
            setState(() => call['status'] = oldStatus);
          }
        }
      },
      items: allowedStatuses.map((value) {
        final color = value == 'Pending' ? Colors.orange : Colors.green;
        return DropdownMenuItem<String>(
          value: value,
          child: Row(
            children: [
              Icon(value == 'Pending' ? Icons.timelapse : Icons.check_circle,
                  size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                value,
                style: TextStyle(color: color, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }



  Widget _buildCallItem(Map<String, dynamic> call, int index) {
    final theme = Theme.of(context);
    final isEven = index % 2 == 0;

    final isIncoming = call['receiver_ph'] == _myPhoneNumber;
    final icon = isIncoming ? Icons.call_received : Icons.call_made;
    final iconColor = isIncoming ? Colors.green : Colors.blue;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEven ? theme.cardColor : theme.cardColor.withOpacity(0.95),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Leading Icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor),
              ),
              const SizedBox(width: 12),

              // Call Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      call['sender_ph'] ?? 'Unknown',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'To: ${call['receiver_ph'] ?? 'Unknown'}',
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      call['start_time_formatted'] ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // Duration Chip
              const SizedBox(width: 8),
              Chip(
                label: Text(_formatDuration(call['duration'] ?? 0)),
                backgroundColor: theme.primaryColor.withOpacity(0.1),
                labelStyle: TextStyle(
                  color: theme.primaryColor,
                  fontSize: 12,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Bottom Row: Audio + Status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildPlayButton(call) ?? const SizedBox.shrink(),
              SizedBox(
                height: 36,
                child: _buildStatusDropdown(call),
              ),
            ],
          ),
        ],
      ),
    );
  }



  // Widget _buildCallItem(Map<String, dynamic> call, int index) {
  //   final theme = Theme.of(context);
  //   final isEven = index % 2 == 0;
  //   return Container(
  //     decoration: BoxDecoration(
  //       color: isEven ? theme.cardColor : theme.cardColor.withOpacity(0.9),
  //     ),
  //     child: ListTile(
  //       contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  //       leading: Container(
  //         padding: const EdgeInsets.all(8),
  //         decoration: BoxDecoration(
  //           color: theme.primaryColor.withOpacity(0.1),
  //           shape: BoxShape.circle,
  //         ),
  //         child: Icon(
  //           Icons.call,
  //           color: theme.primaryColor,
  //         ),
  //       ),
  //       title: Row(
  //         children: [
  //           Expanded(
  //             child: Text(
  //               call['sender_ph'] ?? 'Unknown',
  //               style: theme.textTheme.titleMedium?.copyWith(
  //                 fontWeight: FontWeight.w500,
  //               ),
  //             ),
  //           ),
  //           Chip(
  //             label: Text(_formatDuration(call['duration'] ?? 0)),
  //             backgroundColor: theme.primaryColor.withOpacity(0.1),
  //             labelStyle: TextStyle(
  //               color: theme.primaryColor,
  //               fontSize: 12,
  //             ),
  //             padding: const EdgeInsets.symmetric(horizontal: 8),
  //           ),
  //         ],
  //       ),
  //       subtitle: Column(
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         children: [
  //           const SizedBox(height: 4),
  //           Text(
  //             'To: ${call['receiver_ph'] ?? 'Unknown'}',
  //             style: theme.textTheme.bodyMedium,
  //           ),
  //           const SizedBox(height: 2),
  //           Text(
  //             call['start_time_formatted'] ?? '',
  //             style: theme.textTheme.bodySmall?.copyWith(
  //               color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
  //             ),
  //           ),
  //         ],
  //       ),
  //       onTap: () => _showCallDetails(context, call),
  //       trailing: _buildPlayButton(call),
  //     ),
  //   );
  // }

  Widget? _buildPlayButton(Map<String, dynamic> call) {
    if (call['audio_file'] == null) return null;
    final audioUrl = call['audio_file'] as String;
    final isCurrentlyPlaying = _isPlaying && _currentPlayingUrl == audioUrl;
    return IconButton(
      icon: Icon(
        isCurrentlyPlaying ? Icons.stop : Icons.play_arrow,
        color: isCurrentlyPlaying ? Colors.red : null,
      ),
      onPressed: () {
        if (isCurrentlyPlaying) {
          _stopAudio();
        } else {
          _playAudio(audioUrl);
        }
      },
    );
  }

  Future<void> _playAudio(String url) async {
    try {
      if (_audioPlayer.playing) {
        await _audioPlayer.stop();
      }
      setState(() {
        _currentPlayingUrl = url;
        _isPlaying = false;
      });
      await _audioPlayer.setUrl(url);
      await _audioPlayer.play();
      setState(() => _isPlaying = true);
    } on PlayerException catch (e) {
      _showSnackBar('Playback failed: ${e.message}');
    } on Exception catch (e) {
      _showSnackBar('Failed to play audio: $e');
    }
  }

  Future<void> _stopAudio() async {
    if (!_isPlaying) return;
    try {
      await _audioPlayer.stop();
      setState(() {
        _isPlaying = false;
        _currentPlayingUrl = null;
      });
    } catch (e) {
      debugPrint("Error stopping audio: $e");
      if (mounted) {
        _showSnackBar('Failed to stop audio playback');
      }
    }
  }

  void _showSnackBar(String message, {Duration? duration}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 2),
      ),
    );
  }

  void _showCallDetails(BuildContext context, Map<String, dynamic> call) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => CallDetailsSheet(call: call),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Call Logs"),
        centerTitle: false,
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AdminLogin()),
              );
            },
            icon: const Icon(Icons.admin_panel_settings_rounded),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (!isRefreshing) {
                setState(() => isRefreshing = true);
                _loadData();
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async{
          setState(() {
            // _currentPage = 1;
            callList.clear();
            filteredCallList.clear();
          });
          await _loadData();
        },
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              errorMessage!,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadData,
              child: const Text("Retry"),
            ),
          ],
        ),
      );
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _buildSearchBar(),
          const SizedBox(height: 16),
          _buildStatsHeader(),
          const SizedBox(height: 16),
          if (filteredCallList.isEmpty && _searchController.text.isNotEmpty)
            _buildEmptySearchResult()
          else
            AnimationLimiter(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filteredCallList.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => AnimationConfiguration.staggeredList(
                  position: index,
                  duration: const Duration(milliseconds: 375),
                  child: SlideAnimation(
                    verticalOffset: 50.0,
                    child: FadeInAnimation(
                      child: _buildCallItem(filteredCallList[index], index),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }


  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by phone number...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  _filterCalls();
                },
              )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
            ),
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
            ],
            onChanged: (value) => _filterCalls(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.date_range),
                  label: Text(_startDate == null
                      ? 'Start Date'
                      : DateFormat('yyyy-MM-dd').format(_startDate!)),
                  onPressed: () => _pickDate(context, isStart: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.date_range),
                  label: Text(_endDate == null
                      ? 'End Date'
                      : DateFormat('yyyy-MM-dd').format(_endDate!)),
                  onPressed: () => _pickDate(context, isStart: false),
                ),
              ),
              if (_startDate != null || _endDate != null)
                IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    setState(() {
                      _startDate = null;
                      _endDate = null;
                    });
                    _filterCalls();
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedStatusFilter,
                  decoration: InputDecoration(
                    labelText: 'Filter by Status',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                  ),
                  items: ['All', 'Pending', 'Complete']
                      .map((status) => DropdownMenuItem(
                    value: status == 'All' ? null : status,
                    child: Text(status),
                  ))
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedStatusFilter = value;
                    });
                    _filterCalls();
                  },
                ),
              ),
              SizedBox(width: 10,),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedCallTypeFilter,
                  decoration: InputDecoration(
                    labelText: 'Filter by Call Type',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                  ),
                  items: ['All', 'Incoming', 'Outgoing']
                      .map((type) => DropdownMenuItem(
                    value: type == 'All' ? null : type,
                    child: Text(type),
                  ))
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedCallTypeFilter = value;
                    });
                    _filterCalls();
                  },
                ),
              ),
            ],
          )

        ],
      ),
    );
  }


  // Widget _buildSearchBar() {
  //   return Padding(
  //     padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
  //     child: Column(
  //       crossAxisAlignment: CrossAxisAlignment.stretch,
  //       children: [
  //         TextField(
  //           controller: _searchController,
  //           decoration: InputDecoration(
  //             hintText: 'Search by phone number...',
  //             prefixIcon: const Icon(Icons.search),
  //             suffixIcon: _searchController.text.isNotEmpty
  //                 ? IconButton(
  //               icon: const Icon(Icons.clear),
  //               onPressed: () {
  //                 _searchController.clear();
  //                 _filterCalls();
  //               },
  //             )
  //                 : null,
  //             border: OutlineInputBorder(
  //               borderRadius: BorderRadius.circular(12),
  //               borderSide: BorderSide.none,
  //             ),
  //             filled: true,
  //             contentPadding: const EdgeInsets.symmetric(vertical: 4),
  //           ),
  //           keyboardType: TextInputType.phone,
  //           inputFormatters: [
  //             FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
  //           ],
  //           onChanged: (value) => _filterCalls(),
  //         ),
  //         const SizedBox(height: 12),
  //         Row(
  //           children: [
  //             Expanded(
  //               child: OutlinedButton.icon(
  //                 icon: const Icon(Icons.date_range),
  //                 label: Text(_startDate == null
  //                     ? 'Start Date'
  //                     : DateFormat('yyyy-MM-dd').format(_startDate!)),
  //                 onPressed: () => _pickDate(context, isStart: true),
  //               ),
  //             ),
  //             const SizedBox(width: 8),
  //             Expanded(
  //               child: OutlinedButton.icon(
  //                 icon: const Icon(Icons.date_range),
  //                 label: Text(_endDate == null
  //                     ? 'End Date'
  //                     : DateFormat('yyyy-MM-dd').format(_endDate!)),
  //                 onPressed: () => _pickDate(context, isStart: false),
  //               ),
  //             ),
  //             if (_startDate != null || _endDate != null)
  //               IconButton(
  //                 icon: const Icon(Icons.clear),
  //                 onPressed: () {
  //                   setState(() {
  //                     _startDate = null;
  //                     _endDate = null;
  //                   });
  //                   _filterCalls();
  //                 },
  //               ),
  //           ],
  //         ),
  //         const SizedBox(height: 12),
  //       ],
  //     ),
  //   );
  // }


  Future<void> _pickDate(BuildContext context, {required bool isStart}) async {
    final initialDate = isStart ? _startDate ?? DateTime.now() : _endDate ?? DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
      _filterCalls(); // Apply filtering when dates are selected
    }
  }


  Widget _buildEmptySearchResult() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No calls found for "${_searchController.text}"',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _searchController.clear(),
            child: const Text('Clear search'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsHeader() {
    final callsToDisplay = filteredCallList;
    final totalDuration = callsToDisplay.fold(0, (sum, call) => sum + (call['duration'] as int? ?? 0));
    final avgDuration = callsToDisplay.isEmpty ? 0 : totalDuration ~/ callsToDisplay.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withOpacity(0.05),
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withOpacity(0.1),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            value: callsToDisplay.length.toString(),
            label: "Total Calls",
          ),
          _StatItem(
            value: _formatDuration(totalDuration),
            label: "Total Duration",
          ),
          _StatItem(
            value: _formatDuration(avgDuration),
            label: "Avg Duration",
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;

  const _StatItem({
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6),
          ),
        ),
      ],
    );
  }
}

class CallDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> call;


  const CallDetailsSheet({super.key, required this.call});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(16),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "Call Details",
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 24),
            _DetailRow(
              icon: Icons.call_made,
              label: "From",
              value: call['sender_ph'] ?? 'Unknown',
            ),
            _DetailRow(
              icon: Icons.call_received,
              label: "To",
              value: call['receiver_ph'] ?? 'Unknown',
            ),
            _DetailRow(
              icon: Icons.access_time,
              label: "Started",
              value: call['start_time_formatted'] ?? '',
            ),
            _DetailRow(
              icon: Icons.timer,
              label: "Duration",
              value: _formatDuration(call['duration'] ?? 0),
            ),
            if (call['audio_file'] != null) ...[
              // const SizedBox(height: 16),
              _DetailRow(
                icon: Icons.audiotrack,
                label: "Audio",
                value: "Available",
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text("Close"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    if (duration.inHours > 0) {
      return "${duration.inHours}h ${duration.inMinutes % 60}m";
    }
    return "${duration.inMinutes}m ${duration.inSeconds % 60}s";
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).primaryColor),
          const SizedBox(width: 16),
          Text(
            "$label: ",
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}














// import 'dart:io';
// import 'package:device_info_plus/device_info_plus.dart';
// import 'package:flutter/foundation.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:http/http.dart' as http;
// import 'package:intl/intl.dart';
// import 'package:just_audio/just_audio.dart';
//
// import '../APIServices.dart';
// import 'AdminDashboard.dart';
//
// void main() {
//   runApp(MaterialApp(
//     home: AdminHomePage(),
//   ));
// }
//
// class AdminHomePage extends StatefulWidget {
//   const AdminHomePage({super.key});
//
//   @override
//   State<AdminHomePage> createState() => _AdminHomePageState();
// }
//
// class _AdminHomePageState extends State<AdminHomePage> {
//   List<Map<String, dynamic>> callList = [];
//   List<Map<String, dynamic>> filteredCallList = [];
//   bool isLoading = true;
//   bool isRefreshing = false;
//   String? errorMessage;
//
//   late AudioPlayer _audioPlayer;
//   bool _isPlaying = false;
//   String? _currentPlayingUrl;
//
//   final TextEditingController _searchController = TextEditingController();
//
//   @override
//   void initState() {
//     super.initState();
//     _checkAndroidVersion();
//     _initializeAudioPlayer();
//     _loadData();
//     _searchController.addListener(_filterCalls);
//   }
//
//   void _filterCalls() {
//     final query = _searchController.text.trim().toLowerCase();
//
//     if (query.isEmpty) {
//       setState(() => filteredCallList = List.from(callList));
//       return;
//     }
//
//     final normalizedQuery = query.replaceAll(RegExp(r'[^\d+]'), '');
//
//     setState(() {
//       filteredCallList = callList.where((call) {
//         final sender = _normalizePhoneNumber(call['sender_ph']?.toString() ?? '');
//         final receiver = _normalizePhoneNumber(call['receiver_ph']?.toString() ?? '');
//
//         return sender.contains(normalizedQuery) || receiver.contains(normalizedQuery);
//       }).toList();
//     });
//   }
//
//   String _normalizePhoneNumber(String phoneNumber) {
//     return phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
//   }
//
//   Future<void> _checkAndroidVersion() async {
//     if (Platform.isAndroid) {
//       final androidInfo = await DeviceInfoPlugin().androidInfo;
//       if (androidInfo.version.sdkInt >= 28) {
//         _showSnackBar(
//           'Android ${androidInfo.version.release} detected - HTTP may be blocked',
//           duration: const Duration(seconds: 3),
//         );
//       }
//     }
//   }
//
//   Future<void> _initializeAudioPlayer() async {
//     try {
//       _audioPlayer = AudioPlayer();
//       _setupAudioPlayerListeners();
//     } catch (e) {
//       if (kDebugMode) {
//         print("Failed to initialize audio player: $e");
//       }
//       if (mounted) {
//         ScaffoldMessenger.of(context).showSnackBar(
//           const SnackBar(
//             content: Text('Audio player initialization failed. Audio playback will be disabled.'),
//             duration: Duration(seconds: 3),
//           ),
//         );
//       }
//     }
//   }
//
//   @override
//   void dispose() {
//     _audioPlayer.dispose();
//     _searchController.dispose();
//     super.dispose();
//   }
//
//   void _setupAudioPlayerListeners() {
//     _audioPlayer.playerStateStream.listen((state) {
//       if (mounted) {
//         setState(() {
//           _isPlaying = state.playing;
//           if (state.processingState == ProcessingState.completed) {
//             _isPlaying = false;
//             _currentPlayingUrl = null;
//           }
//         });
//       }
//     });
//   }
//
//   Future<void> _loadData() async {
//     setState(() {
//       isLoading = true;
//       errorMessage = null;
//     });
//
//     try {
//       final response = await API.getCallDetails();
//
//       if (response == null || response.isEmpty) {
//         setState(() {
//           errorMessage = "No call data available";
//         });
//       } else {
//         final reversedList = List<Map<String, dynamic>>.from(response.reversed);
//         setState(() {
//           callList = reversedList;
//           filteredCallList = List<Map<String, dynamic>>.from(reversedList);
//         });
//       }
//     } catch (e) {
//       setState(() {
//         errorMessage = "Failed to load data. Please try again.";
//       });
//     } finally {
//       setState(() {
//         isLoading = false;
//         isRefreshing = false;
//       });
//     }
//   }
//
//   String _formatDateTime(String isoString) {
//     try {
//       final dateTime = DateTime.parse(isoString).toLocal();
//       return DateFormat('MMM dd, yyyy • hh:mm a').format(dateTime);
//     } catch (e) {
//       return isoString;
//     }
//   }
//
//   String _formatDuration(int seconds) {
//     final duration = Duration(seconds: seconds);
//     if (duration.inHours > 0) {
//       return "${duration.inHours}h ${duration.inMinutes % 60}m";
//     }
//     return "${duration.inMinutes}m ${duration.inSeconds % 60}s";
//   }
//
//   Widget _buildCallItem(Map<String, dynamic> call, int index) {
//     final theme = Theme.of(context);
//     final isEven = index % 2 == 0;
//
//     return Container(
//       decoration: BoxDecoration(
//         color: isEven ? theme.cardColor : theme.cardColor.withOpacity(0.9),
//       ),
//       child: ListTile(
//         contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
//         leading: Container(
//           padding: const EdgeInsets.all(8),
//           decoration: BoxDecoration(
//             color: theme.primaryColor.withOpacity(0.1),
//             shape: BoxShape.circle,
//           ),
//           child: Icon(
//             Icons.call,
//             color: theme.primaryColor,
//           ),
//         ),
//         title: Row(
//           children: [
//             Expanded(
//               child: Text(
//                 call['sender_ph'] ?? 'Unknown',
//                 style: theme.textTheme.titleMedium?.copyWith(
//                   fontWeight: FontWeight.w500,
//                 ),
//               ),
//             ),
//             Chip(
//               label: Text(_formatDuration(call['duration'] ?? 0)),
//               backgroundColor: theme.primaryColor.withOpacity(0.1),
//               labelStyle: TextStyle(
//                 color: theme.primaryColor,
//                 fontSize: 12,
//               ),
//               padding: const EdgeInsets.symmetric(horizontal: 8),
//             ),
//           ],
//         ),
//         subtitle: Column(
//           crossAxisAlignment: CrossAxisAlignment.start,
//           children: [
//             const SizedBox(height: 4),
//             Text(
//               'To: ${call['receiver_ph'] ?? 'Unknown'}',
//               style: theme.textTheme.bodyMedium,
//             ),
//             const SizedBox(height: 2),
//             Text(
//               call['start_time_formatted'] ?? '',
//               style: theme.textTheme.bodySmall?.copyWith(
//                 color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
//               ),
//             ),
//           ],
//         ),
//         onTap: () => _showCallDetails(context, call),
//         trailing: _buildPlayButton(call),
//       ),
//     );
//   }
//
//   Widget? _buildPlayButton(Map<String, dynamic> call) {
//     if (call['audio_file'] == null) return null;
//
//     final audioUrl = call['audio_file'] as String;
//     final isCurrentlyPlaying = _isPlaying && _currentPlayingUrl == audioUrl;
//
//     return IconButton(
//       icon: Icon(
//         isCurrentlyPlaying ? Icons.stop : Icons.play_arrow,
//         color: isCurrentlyPlaying ? Colors.red : null,
//       ),
//       onPressed: () {
//         if (isCurrentlyPlaying) {
//           _stopAudio();
//         } else {
//           _playAudio(audioUrl);
//         }
//       },
//     );
//   }
//
//   Future<void> _playAudio(String url) async {
//     try {
//       if (_audioPlayer.playing) {
//         await _audioPlayer.stop();
//       }
//
//       setState(() {
//         _currentPlayingUrl = url;
//         _isPlaying = false;
//       });
//
//       await _audioPlayer.setUrl(url);
//       await _audioPlayer.play();
//       setState(() => _isPlaying = true);
//     } on PlayerException catch (e) {
//       _showSnackBar('Playback failed: ${e.message}');
//     } on Exception catch (e) {
//       _showSnackBar('Failed to play audio: $e');
//     }
//   }
//
//   Future<void> _stopAudio() async {
//     if (!_isPlaying) return;
//
//     try {
//       await _audioPlayer.stop();
//       setState(() {
//         _isPlaying = false;
//         _currentPlayingUrl = null;
//       });
//     } catch (e) {
//       if (kDebugMode) {
//         print("Error stopping audio: $e");
//       }
//       if (mounted) {
//         _showSnackBar('Failed to stop audio playback');
//       }
//     }
//   }
//
//   void _showSnackBar(String message, {Duration? duration}) {
//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(
//         content: Text(message),
//         duration: duration ?? const Duration(seconds: 2),
//       ),
//     );
//   }
//
//   void _showCallDetails(BuildContext context, Map<String, dynamic> call) {
//     showModalBottomSheet(
//       context: context,
//       isScrollControlled: true,
//       builder: (context) => CallDetailsSheet(call: call),
//     );
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text("Call Logs"),
//         centerTitle: false,
//         actions: [
//           IconButton(
//             onPressed: () {
//               Navigator.push(
//                 context,
//                 MaterialPageRoute(builder: (context) => AdminDashboard()),
//               );
//             },
//             icon: Icon(Icons.admin_panel_settings_rounded),
//           ),
//           IconButton(
//             icon: const Icon(Icons.refresh),
//             onPressed: () {
//               if (!isRefreshing) {
//                 setState(() => isRefreshing = true);
//                 _loadData();
//               }
//             },
//           ),
//         ],
//       ),
//       body: RefreshIndicator(
//         onRefresh: _loadData,
//         child: _buildContent(),
//       ),
//     );
//   }
//
//   Widget _buildContent() {
//     if (isLoading) {
//       return const Center(child: CircularProgressIndicator());
//     }
//
//     if (errorMessage != null) {
//       return Center(
//         child: Column(
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             Text(
//               errorMessage!,
//               style: Theme.of(context).textTheme.bodyLarge,
//             ),
//             const SizedBox(height: 16),
//             ElevatedButton(
//               onPressed: _loadData,
//               child: const Text("Retry"),
//             ),
//           ],
//         ),
//       );
//     }
//
//     return Column(
//       children: [
//         _buildSearchBar(),
//         _buildStatsHeader(),
//         Expanded(
//           child: filteredCallList.isEmpty && _searchController.text.isNotEmpty
//               ? _buildEmptySearchResult()
//               : ListView.separated(
//             itemCount: filteredCallList.length,
//             separatorBuilder: (_, __) => const Divider(height: 1),
//             itemBuilder: (context, index) => _buildCallItem(filteredCallList[index], index),
//           ),
//         ),
//       ],
//     );
//   }
//
//   Widget _buildSearchBar() {
//     return Padding(
//       padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
//       child: TextField(
//         controller: _searchController,
//         decoration: InputDecoration(
//           hintText: 'Search by phone number...',
//           prefixIcon: const Icon(Icons.search),
//           suffixIcon: _searchController.text.isNotEmpty
//               ? IconButton(
//             icon: const Icon(Icons.clear),
//             onPressed: () {
//               _searchController.clear();
//               _filterCalls();
//             },
//           )
//               : null,
//           border: OutlineInputBorder(
//             borderRadius: BorderRadius.circular(12),
//             borderSide: BorderSide.none,
//           ),
//           filled: true,
//           contentPadding: const EdgeInsets.symmetric(vertical: 4),
//         ),
//         keyboardType: TextInputType.phone,
//         inputFormatters: [
//           FilteringTextInputFormatter.allow(RegExp(r'[\d+]')),
//         ],
//         onChanged: (value) => _filterCalls(),
//       ),
//     );
//   }
//
//   Widget _buildEmptySearchResult() {
//     return Center(
//       child: Column(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           Icon(
//             Icons.search_off,
//             size: 48,
//             color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
//           ),
//           const SizedBox(height: 16),
//           Text(
//             'No calls found for "${_searchController.text}"',
//             style: Theme.of(context).textTheme.bodyLarge,
//           ),
//           const SizedBox(height: 8),
//           TextButton(
//             onPressed: () => _searchController.clear(),
//             child: const Text('Clear search'),
//           ),
//         ],
//       ),
//     );
//   }
//
//   Widget _buildStatsHeader() {
//     final callsToDisplay = _searchController.text.isEmpty ? callList : filteredCallList;
//     final totalDuration = callsToDisplay.fold(0, (sum, call) => sum + (call['duration'] as int? ?? 0));
//     final avgDuration = callsToDisplay.isEmpty ? 0 : totalDuration ~/ callsToDisplay.length;
//
//     return Container(
//       padding: const EdgeInsets.all(16),
//       decoration: BoxDecoration(
//         color: Theme.of(context).primaryColor.withOpacity(0.05),
//         border: Border(
//           bottom: BorderSide(
//             color: Theme.of(context).dividerColor.withOpacity(0.1),
//           ),
//         ),
//       ),
//       child: Row(
//         mainAxisAlignment: MainAxisAlignment.spaceAround,
//         children: [
//           _StatItem(
//             value: callsToDisplay.length.toString(),
//             label: "Total Calls",
//           ),
//           _StatItem(
//             value: _formatDuration(totalDuration),
//             label: "Total Duration",
//           ),
//           _StatItem(
//             value: _formatDuration(avgDuration),
//             label: "Avg Duration",
//           ),
//         ],
//       ),
//     );
//   }
// }
//
// class _StatItem extends StatelessWidget {
//   final String value;
//   final String label;
//
//   const _StatItem({
//     required this.value,
//     required this.label,
//   });
//
//   @override
//   Widget build(BuildContext context) {
//     return Column(
//       mainAxisSize: MainAxisSize.min,
//       children: [
//         Text(
//           value,
//           style: Theme.of(context).textTheme.titleLarge?.copyWith(
//             fontWeight: FontWeight.bold,
//           ),
//         ),
//         const SizedBox(height: 4),
//         Text(
//           label,
//           style: Theme.of(context).textTheme.bodySmall?.copyWith(
//             color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6),
//           ),
//         ),
//       ],
//     );
//   }
// }
//
// class CallDetailsSheet extends StatelessWidget {
//   final Map<String, dynamic> call;
//
//   const CallDetailsSheet({super.key, required this.call});
//
//   @override
//   Widget build(BuildContext context) {
//     final theme = Theme.of(context);
//
//     return Padding(
//       padding: EdgeInsets.only(
//         bottom: MediaQuery.of(context).viewInsets.bottom,
//       ),
//       child: Container(
//         padding: const EdgeInsets.all(24),
//         decoration: BoxDecoration(
//           color: theme.cardColor,
//           borderRadius: const BorderRadius.vertical(
//             top: Radius.circular(16),
//           ),
//         ),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           crossAxisAlignment: CrossAxisAlignment.start,
//           children: [
//             Center(
//               child: Container(
//                 width: 40,
//                 height: 4,
//                 decoration: BoxDecoration(
//                   color: theme.dividerColor,
//                   borderRadius: BorderRadius.circular(2),
//                 ),
//               ),
//             ),
//             const SizedBox(height: 16),
//             Text(
//               "Call Details",
//               style: theme.textTheme.titleLarge,
//             ),
//             const SizedBox(height: 24),
//             _DetailRow(
//               icon: Icons.call_made,
//               label: "From",
//               value: call['sender_ph'] ?? 'Unknown',
//             ),
//             _DetailRow(
//               icon: Icons.call_received,
//               label: "To",
//               value: call['receiver_ph'] ?? 'Unknown',
//             ),
//             _DetailRow(
//               icon: Icons.access_time,
//               label: "Started",
//               value: call['start_time_formatted'] ?? '',
//             ),
//             _DetailRow(
//               icon: Icons.timer,
//               label: "Duration",
//               value: _formatDuration(call['duration'] ?? 0),
//             ),
//             if (call['audio_file'] != null) ...[
//               const SizedBox(height: 16),
//               _DetailRow(
//                 icon: Icons.audiotrack,
//                 label: "Audio",
//                 value: "Available",
//               ),
//             ],
//             const SizedBox(height: 24),
//             SizedBox(
//               width: double.infinity,
//               child: ElevatedButton(
//                 style: ElevatedButton.styleFrom(
//                   padding: const EdgeInsets.symmetric(vertical: 16),
//                   shape: RoundedRectangleBorder(
//                     borderRadius: BorderRadius.circular(12),
//                   ),
//                 ),
//                 onPressed: () => Navigator.pop(context),
//                 child: const Text("Close"),
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
//
//   String _formatDuration(int seconds) {
//     final duration = Duration(seconds: seconds);
//     if (duration.inHours > 0) {
//       return "${duration.inHours}h ${duration.inMinutes % 60}m";
//     }
//     return "${duration.inMinutes}m ${duration.inSeconds % 60}s";
//   }
// }
//
// class _DetailRow extends StatelessWidget {
//   final IconData icon;
//   final String label;
//   final String value;
//
//   const _DetailRow({
//     required this.icon,
//     required this.label,
//     required this.value,
//   });
//
//   @override
//   Widget build(BuildContext context) {
//     return Padding(
//       padding: const EdgeInsets.symmetric(vertical: 8),
//       child: Row(
//         children: [
//           Icon(icon, size: 20, color: Theme.of(context).primaryColor),
//           const SizedBox(width: 16),
//           Text(
//             "$label: ",
//             style: Theme.of(context).textTheme.bodyMedium?.copyWith(
//               fontWeight: FontWeight.bold,
//             ),
//           ),
//           Expanded(
//             child: Text(
//               value,
//               style: Theme.of(context).textTheme.bodyMedium,
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
