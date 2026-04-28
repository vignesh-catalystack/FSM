import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fsm/core/auth/auth_notifier.dart';
import 'package:fsm/features/jobs/application/job_controller.dart';
import 'package:fsm/features/jobs/application/tracking_presence.dart';
import 'package:fsm/features/jobs/presentation/technician_locations_map_screen.dart';
import 'package:fsm/features/notifications/application/notification_controller.dart';

class AdminDashboard extends ConsumerStatefulWidget {
  const AdminDashboard({super.key});

  @override
  ConsumerState<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends ConsumerState<AdminDashboard>
    with WidgetsBindingObserver {
  static const int _jobsPageSize = 4;

  bool loading = false;
  int _visibleJobCount = _jobsPageSize;
  Timer? _liveRefreshTimer;
  Timer? _notificationTimer;
  bool _refreshInProgress = false;
  bool _isForeground = true;
  bool _notificationPollBusy = false;
  int _lastSeenNotificationId = 0;
  final Set<int> _locallyHiddenJobIds = <int>{};
  final Set<int> _deletingJobIds = <int>{};
  final Map<int, Timer> _pendingDeleteTimers = <int, Timer>{};

  String _asText(dynamic value, {String fallback = '-'}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  String _asCount(dynamic value, {required bool loading}) {
    if (loading) return '...';
    if (value == null) return '-';
    if (value is num) return value.toInt().toString();
    final parsed = int.tryParse(value.toString());
    if (parsed != null) return parsed.toString();
    return '-';
  }

  String _coord(double? value) =>
      value == null ? '-' : value.toStringAsFixed(5);

  DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text) ??
        DateTime.tryParse(text.replaceFirst(' ', 'T'));
  }

  String _timeAgo(dynamic value) {
    final date = _asDateTime(value)?.toLocal();
    if (date == null) return 'Unknown';

    final difference = DateTime.now().difference(date);
    if (difference.inSeconds < 45) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
  }

  String _titleCase(String value) {
    final cleaned = value.trim().replaceAll('_', ' ');
    if (cleaned.isEmpty) return '-';
    return cleaned.split(RegExp(r'\s+')).map((word) {
      if (word.isEmpty) return word;
      return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'finished':
      case 'closed':
        return const Color(0xFF15803D);
      case 'accepted':
      case 'in_progress':
      case 'active':
      case 'ongoing':
        return const Color(0xFF2563EB);
      case 'pending':
      case 'assigned':
      case 'open':
      case 'new':
        return const Color(0xFFF59E0B);
      case 'deleted':
      case 'archived':
        return const Color(0xFF64748B);
      default:
        return const Color(0xFF475569);
    }
  }

  Color _trackingColor(String trackingStatus) {
    switch (trackingStatus.toLowerCase()) {
      case 'active':
      case 'accepted':
      case 'in_progress':
      case 'ongoing':
      case 'enroute':
      case 'on_the_way':
      case 'working':
      case 'started':
        return const Color(0xFF0F9D58);
      case 'ended':
      case 'completed':
      case 'inactive':
      case 'off':
        return const Color(0xFF94A3B8);
      default:
        return const Color(0xFFF59E0B);
    }
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return false;
    return text == '1' ||
        text == 'true' ||
        text == 'yes' ||
        text == 'y' ||
        text == 'on' ||
        text == 'active';
  }

  bool _hasDisplayValue(String? value) {
    final normalized = value?.trim();
    return normalized != null && normalized.isNotEmpty && normalized != '-';
  }

  String _presencePillLabel(TrackingSnapshot snapshot) {
    if (snapshot.isLive) return 'Live now';
    if (snapshot.updatedAt == null) return 'Sync unknown';
    return 'Seen ${_timeAgo(snapshot.updatedAt!.toIso8601String())}';
  }

  Color _presencePillColor(TrackingSnapshot snapshot) {
    if (snapshot.isLive) return const Color(0xFF0F9D58);
    if (snapshot.updatedAt == null) return const Color(0xFFF59E0B);
    return snapshot.isFromCache
        ? const Color(0xFF64748B)
        : const Color(0xFFB45309);
  }

  String _presenceSupportText(TrackingSnapshot snapshot) {
    if (snapshot.isLive) {
      return 'Receiving live GPS updates from the technician device.';
    }
    if (snapshot.updatedAt == null) {
      return 'Tracking session exists, but the last sync time is unavailable.';
    }
    final lastSeen = _timeAgo(snapshot.updatedAt!.toIso8601String());
    return 'Last device update arrived $lastSeen. Showing the most recent synced point until tracking resumes.';
  }

  // ─── BATTERY HELPERS ────────────────────────────────────────────────────────

  /// Safely resolves battery level from a row map.
  /// Returns null if not present or out of [0, 100] range.
int? _getBatteryLevel(Map<String, dynamic> row) {
  // Try all possible field names
  final value = row['battery_level'] ?? 
                row['battery'] ?? 
                row['battery_percentage'] ?? 
                row['batteryLevel'];  // Added more options
  
  print("🔋 Raw battery value: $value");  // Debug
  
  if (value == null) return null;
  
  final num? parsed = value is num ? value : num.tryParse(value.toString());
  if (parsed == null) return null;
  
  final int level = parsed.toInt();
  if (level < 0 || level > 100) return null;
  
  return level;
}

  /// Safely resolves charging state from a row map. Returns null if missing.
  bool? _getIsCharging(Map<String, dynamic> row) {
    final chargingValue =
        row['is_charging'] ?? row['charging'] ?? row['battery_charging'];
    if (chargingValue == null) return null;

    if (chargingValue is bool) return chargingValue;
    if (chargingValue is int) return chargingValue == 1;
    if (chargingValue is String) {
      final lower = chargingValue.toLowerCase();
      return lower == '1' || lower == 'true' || lower == 'yes';
    }
    return null;
  }

  /// FIX: Match using BOTH technician_id AND job_id to ensure correct row
  Map<String, dynamic>? _findLiveRowForTechnicianAndJob(
    int techId,
    int jobId,
    List<Map<String, dynamic>> rawLiveRows,
  ) {
    for (final e in rawLiveRows) {
      final rawTechId = e['technician_id'];
      final rawJobId = e['job_id'];
      
      if (rawTechId == null || rawJobId == null) continue;

      final int? parsedTechId =
          rawTechId is int ? rawTechId : int.tryParse(rawTechId.toString().trim());
      final int? parsedJobId =
          rawJobId is int ? rawJobId : int.tryParse(rawJobId.toString().trim());

      if (parsedTechId == techId && parsedJobId == jobId) return e;
    }
    return null;
  }

  /// FIX: Choose the source that actually has battery data.
  /// Priority: liveRow (if it has battery) → assignmentRow → null
  Map<String, dynamic> _resolveBatterySource(
    Map<String, dynamic>? liveMatch,
    Map<String, dynamic> assignmentRow,
  ) {
    if (liveMatch != null && _getBatteryLevel(liveMatch) != null) {
      return liveMatch;
    }
    if (_getBatteryLevel(assignmentRow) != null) {
      return assignmentRow;
    }
    // Both missing battery — return liveMatch if available, else assignment
    return liveMatch ?? assignmentRow;
  }

  // ─── TRACKING FEED ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _buildTrackingFeed(
    List<Map<String, dynamic>> liveRows,
    List<Map<String, dynamic>> jobAssignments,
  ) {
    final assignmentsByJobId = <int, Map<String, dynamic>>{};
    for (final row in jobAssignments) {
      final jobId = _extractJobId(row['job_id'] ?? row['id']);
      if (jobId != null) {
        assignmentsByJobId[jobId] = row;
      }
    }

    final feed = <Map<String, dynamic>>[];
    for (final row in liveRows) {
      final latitude = _asDouble(row['latitude']);
      final longitude = _asDouble(row['longitude']);
      if (latitude == null || longitude == null) continue;

      final jobId = _extractJobId(row['job_id'] ?? row['id']);
      final assignment = jobId == null ? null : assignmentsByJobId[jobId];
      final merged = <String, dynamic>{...row};

      if (assignment != null) {
        final assignmentStatus = _asText(assignment['status'], fallback: '');
        final assignmentTracking =
            _asText(assignment['tracking_status'], fallback: '');
        final assignmentTitle = _asText(assignment['job_title'], fallback: '');
        final liveStatus = _asText(merged['status'], fallback: '');
        final liveTracking = _asText(merged['tracking_status'], fallback: '');
        final liveTitle = _asText(merged['job_title'], fallback: '');

        if (!_hasDisplayValue(liveStatus) &&
            assignmentStatus.isNotEmpty &&
            assignmentStatus != '-') {
          merged['status'] = assignmentStatus;
        }
        if (!_hasDisplayValue(liveTracking) &&
            assignmentTracking.isNotEmpty &&
            assignmentTracking != '-') {
          merged['tracking_status'] = assignmentTracking;
        }
        if (!_hasDisplayValue(liveTitle) &&
            assignmentTitle.isNotEmpty &&
            assignmentTitle != '-') {
          merged['job_title'] = assignmentTitle;
        }

        // FIX: Merge battery fields from assignment if live row is missing them
        for (final key in [
          'battery_level',
          'battery',
          'battery_percentage',
          'is_charging',
          'charging',
          'battery_charging',
        ]) {
          if (merged[key] == null && assignment[key] != null) {
            merged[key] = assignment[key];
          }
        }
      }

      final snapshot = TrackingPresence.evaluate(merged);
      if (!snapshot.shouldAppearInFeed) continue;

      final isOfflineHistory = snapshot.isOffline;

      feed.add(<String, dynamic>{
        ...merged,
        'is_live_now': snapshot.isLive,
        'is_offline_history': isOfflineHistory,
        'needs_attention': !snapshot.isLive,
      });
    }

    feed.sort((a, b) {
      final aOffline = _asBool(a['is_offline_history']);
      final bOffline = _asBool(b['is_offline_history']);
      if (aOffline != bOffline) return aOffline ? 1 : -1;

      final aUpdated = _asDateTime(a['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bUpdated = _asDateTime(b['updated_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bUpdated.compareTo(aUpdated);
    });

    return feed;
  }

  // ─── DASHBOARD ACTIONS ──────────────────────────────────────────────────────

  Future<void> _refreshDashboard({bool showFeedback = false}) async {
    if (_refreshInProgress) return;
    if (mounted) {
      setState(() => _refreshInProgress = true);
    } else {
      _refreshInProgress = true;
    }

    try {
      await Future.wait([
        ref.refresh(adminTechnicianLiveProvider.future),
        ref.refresh(adminDashboardSummaryProvider.future),
        ref.refresh(adminJobAssignmentsProvider.future),
        ref.refresh(adminDeletedJobsProvider.future),
      ]);

      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dashboard refreshed')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshInProgress = false);
      } else {
        _refreshInProgress = false;
      }
    }
  }

  Future<void> _openLiveMap(List<Map<String, dynamic>> liveRows) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TechnicianLocationsMapScreen(
          liveOnly: true,
          seedRows: liveRows,
        ),
      ),
    );
  }

  Future<void> _openTechnicianMap({
    required int jobId,
    required int? technicianId,
    required String jobTitle,
    required String technicianName,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TechnicianLocationsMapScreen(
          jobIdFilter: jobId,
          technicianIdFilter: technicianId,
          jobTitleHint: jobTitle,
          technicianNameHint: technicianName,
        ),
      ),
    );
  }

  String _cleanLiveError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    final lower = text.toLowerCase();
    if (lower.contains('<!doctype html') || lower.contains('<html>')) {
      return 'Live tracking endpoint returned HTML instead of JSON. Please verify API path.';
    }
    if (text.length > 180) return '${text.substring(0, 180)}...';
    return text;
  }

  int _notificationId(Map<String, dynamic> item) {
    final value = item['id'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _notificationBody(Map<String, dynamic> item) {
    return item['body']?.toString().trim().isNotEmpty == true
        ? item['body'].toString()
        : 'You have a new update.';
  }

  int? _extractJobId(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  void _queueSoftDelete(Map<String, dynamic> jobRow) {
    final jobId = _extractJobId(jobRow['job_id'] ?? jobRow['id']);
    if (jobId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Missing job id. Cannot delete this job.')),
      );
      return;
    }
    if (_pendingDeleteTimers.containsKey(jobId) ||
        _deletingJobIds.contains(jobId)) {
      return;
    }

    setState(() {
      _locallyHiddenJobIds.add(jobId);
    });

    _pendingDeleteTimers[jobId] = Timer(const Duration(seconds: 3), () {
      unawaited(_commitSoftDelete(jobId));
    });

    final jobTitle = _asText(jobRow['job_title'], fallback: 'Job $jobId');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('"$jobTitle" will be moved to deleted jobs'),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () => _undoDelete(jobId),
        ),
      ),
    );
  }

  void _undoDelete(int jobId) {
    final timer = _pendingDeleteTimers.remove(jobId);
    timer?.cancel();
    if (!mounted) return;
    setState(() {
      _locallyHiddenJobIds.remove(jobId);
    });
  }

  Future<void> _commitSoftDelete(int jobId) async {
    final timer = _pendingDeleteTimers.remove(jobId);
    timer?.cancel();

    if (!mounted) return;
    setState(() {
      _deletingJobIds.add(jobId);
    });

    try {
      final message = await ref
          .read(jobActionControllerProvider)
          .softDeleteJob(jobId: jobId);
      if (!mounted) return;
      setState(() {
        _locallyHiddenJobIds.remove(jobId);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      ref.invalidate(adminJobAssignmentsProvider);
      ref.invalidate(adminDeletedJobsProvider);
      ref.invalidate(adminDashboardSummaryProvider);
      ref.invalidate(adminTechnicianLiveProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locallyHiddenJobIds.remove(jobId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deletingJobIds.remove(jobId);
        });
      }
    }
  }

  Future<void> _bootstrapNotificationCursor() async {
    try {
      final latest =
          await ref.read(notificationPollingControllerProvider).fetchLatest();
      if (latest.isNotEmpty) {
        _lastSeenNotificationId = _notificationId(latest.first);
      }
    } catch (_) {}
  }

  Future<void> _pollNotifications() async {
    if (!mounted || !_isForeground || _notificationPollBusy) return;
    _notificationPollBusy = true;

    try {
      final items = await ref
          .read(notificationPollingControllerProvider)
          .fetchNewSince(lastId: _lastSeenNotificationId);

      if (items.isEmpty) return;

      final sorted = [...items]
        ..sort((a, b) => _notificationId(a).compareTo(_notificationId(b)));

      for (final item in sorted) {
        final id = _notificationId(item);
        if (id <= _lastSeenNotificationId) continue;
        _lastSeenNotificationId = id;
        if (!mounted) continue;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_notificationBody(item))),
        );
      }
    } catch (_) {
    } finally {
      _notificationPollBusy = false;
    }
  }

  bool _shouldAutoRefresh() {
    if (!mounted || !_isForeground || loading || _refreshInProgress) {
      return false;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery != null && mediaQuery.viewInsets.bottom > 0) return false;

    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_bootstrapNotificationCursor);
    _liveRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_shouldAutoRefresh()) return;
      unawaited(_refreshDashboard());
    });
    _notificationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollNotifications();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    for (final timer in _pendingDeleteTimers.values) {
      timer.cancel();
    }
    _pendingDeleteTimers.clear();
    _liveRefreshTimer?.cancel();
    _notificationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ─── CREATE JOB ─────────────────────────────────────────────────────────────

  Future<void> _createJob({
    required String title,
    required int technicianId,
  }) async {
    try {
      setState(() => loading = true);
      final message = await ref.read(jobActionControllerProvider).createJob(
            title: title,
            technicianId: technicianId,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      ref.invalidate(adminDashboardSummaryProvider);
      ref.invalidate(adminTechnicianLiveProvider);
      ref.invalidate(adminJobAssignmentsProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _showCreateJobDialog() {
    final titleController = TextEditingController();
    final techIdController = TextEditingController();
    String? dialogError;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Create Job'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Job Title',
                  hintText: 'Installation visit',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: techIdController,
                decoration: const InputDecoration(
                  labelText: 'Technician ID',
                  hintText: 'Enter numeric technician id',
                ),
                keyboardType: TextInputType.number,
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 12),
                Text(
                  dialogError!,
                  style: const TextStyle(
                    color: Color(0xFFB42318),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final title = titleController.text.trim();
                final techId = int.tryParse(techIdController.text.trim());

                if (title.length < 3) {
                  setDialogState(() {
                    dialogError =
                        'Enter a job title with at least 3 characters.';
                  });
                  return;
                }
                if (techId == null || techId <= 0) {
                  setDialogState(() {
                    dialogError = 'Enter a valid technician id.';
                  });
                  return;
                }

                Navigator.pop(dialogContext);
                _createJob(title: title, technicianId: techId);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final liveTrackingAsync = ref.watch(adminTechnicianLiveProvider);
    final summaryAsync = ref.watch(adminDashboardSummaryProvider);
    final jobAssignmentsAsync = ref.watch(adminJobAssignmentsProvider);
    final deletedJobsAsync = ref.watch(adminDeletedJobsProvider);

    final summary = summaryAsync.valueOrNull ?? const <String, dynamic>{};
    final rawLiveRows =
        liveTrackingAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final assignmentRows =
        jobAssignmentsAsync.valueOrNull ?? const <Map<String, dynamic>>[];

    final liveRows = _buildTrackingFeed(rawLiveRows, assignmentRows);

    final totalTechnicians =
        _asCount(summary['total_technicians'], loading: summaryAsync.isLoading);
    final totalJobs =
        _asCount(summary['total_jobs'], loading: summaryAsync.isLoading);
    final completedJobs =
        _asCount(summary['completed_jobs'], loading: summaryAsync.isLoading);
    final liveNowCount =
        liveRows.where((row) => !_asBool(row['is_offline_history'])).length;
    final offlineHistoryCount =
        liveRows.where((row) => _asBool(row['is_offline_history'])).length;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFD9E9FF), Color(0xFFF6FAFF)],
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () => _refreshDashboard(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AdminTopBar(
                    loading: loading,
                    onLogout: () {
                      ref.read(authProvider.notifier).logout();
                    },
                  ),
                  const SizedBox(height: 14),
                  _AdminOverviewCard(
                    onRefresh: _refreshInProgress
                        ? null
                        : () => _refreshDashboard(showFeedback: true),
                    onCreateJob: _showCreateJobDialog,
                    onOpenLiveMap: () => _openLiveMap(liveRows),
                    metrics: [
                      const _OverviewMetric(
                        label: 'Jobs',
                        helper: 'Current workload',
                      ).copyWith(value: totalJobs),
                      const _OverviewMetric(
                        label: 'Completed',
                        helper: 'Closed successfully',
                      ).copyWith(value: completedJobs),
                      const _OverviewMetric(
                        label: 'Technicians',
                        helper: 'Available in system',
                      ).copyWith(value: totalTechnicians),
                      const _OverviewMetric(
                        label: 'Live now',
                        helper: 'Actively syncing',
                      ).copyWith(value: '$liveNowCount'),
                    ],
                    summaryError: summaryAsync.hasError
                        ? summaryAsync.error
                            .toString()
                            .replaceFirst('Exception: ', '')
                        : null,
                    refreshInProgress: _refreshInProgress,
                  ),
                  const SizedBox(height: 18),

                  // ── Jobs & Assigned Technician ──────────────────────────────
                  _SectionLabel(
                    title: 'Jobs & Assigned Technician',
                    subtitle:
                        'Current work ownership, technician pairing, and latest status updates.',
                    action: IconButton(
                      onPressed: () => _refreshDashboard(showFeedback: true),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh jobs',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: _cardDecoration(),
                    child: jobAssignmentsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Text(
                        'Unable to load jobs: ${e.toString().replaceFirst('Exception: ', '')}',
                        style: const TextStyle(color: Color(0xFF7C2D12)),
                      ),
                      data: (rows) {
                        final visibleRows = rows.where((row) {
                          final jobId =
                              _extractJobId(row['job_id'] ?? row['id']);
                          if (jobId == null) return true;
                          return !_locallyHiddenJobIds.contains(jobId);
                        }).toList(growable: false);

                        if (visibleRows.isEmpty) {
                          return const _EmptyBlock(
                            icon: Icons.work_outline,
                            title: 'No assigned jobs yet',
                            subtitle:
                                'Newly created jobs will appear here with technician ownership.',
                          );
                        }

                        final visibleCount =
                            _visibleJobCount > visibleRows.length
                                ? visibleRows.length
                                : _visibleJobCount;
                        final cards = <Widget>[];

                        for (var i = 0; i < visibleCount; i++) {
                          final row = visibleRows[i];
                          final jobId = _asText(row['job_id']);
                          final jobIdValue =
                              _extractJobId(row['job_id'] ?? row['id']);
                          final technicianIdValue =
                              _extractJobId(row['technician_id']);
                          final job = _asText(row['job_title']);
                          final status = _asText(row['status']);
                          final technician = _asText(row['technician_name']);
                          final tracking =
                              _asText(row['tracking_status'], fallback: '');
                          final updated = _timeAgo(row['updated_at']);
                          final pendingDelete = jobIdValue != null &&
                              _pendingDeleteTimers.containsKey(jobIdValue);
                          final deleting = jobIdValue != null &&
                              _deletingJobIds.contains(jobIdValue);

                          // ── FIX: Resolve battery source using BOTH tech_id AND job_id ──────────
                          int? battery;
                          bool? isCharging;

                          if (technicianIdValue != null && jobIdValue != null) {
                            final liveMatch = _findLiveRowForTechnicianAndJob(
                              technicianIdValue,
                              jobIdValue,
                              rawLiveRows,
                            );
                            final source =
                                _resolveBatterySource(liveMatch, row);
                            battery = _getBatteryLevel(source);
                            isCharging = _getIsCharging(source);
                          }
                          // ─────────────────────────────────────────────────

                          cards.add(
                            Container(
                              margin: EdgeInsets.only(
                                bottom: i == visibleCount - 1 ? 0 : 10,
                              ),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    job,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 16,
                                                      color: Color(0xFF0F172A),
                                                    ),
                                                  ),
                                                ),
                                                // ── Battery badge in job card
                                                Padding(
  padding: const EdgeInsets.only(left: 8),
  child: _BatteryBadge(
    level: battery ?? -1,
    charging: isCharging ?? false,
  ),
),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _StatusTag(
                                                  label: _titleCase(status),
                                                  color: _statusColor(status),
                                                ),
                                                if (_hasDisplayValue(tracking))
                                                  _StatusTag(
                                                    label:
                                                        _titleCase(tracking),
                                                    color: _trackingColor(
                                                        tracking),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(
                                        width: 44,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            IconButton(
                                              tooltip: 'Delete with undo',
                                              padding: EdgeInsets.zero,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 36,
                                              ),
                                              onPressed: deleting
                                                  ? null
                                                  : pendingDelete
                                                      ? () => _undoDelete(
                                                          jobIdValue!)
                                                      : () => _queueSoftDelete(
                                                          row),
                                              icon: deleting
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                              strokeWidth: 2),
                                                    )
                                                  : Icon(
                                                      pendingDelete
                                                          ? Icons.undo
                                                          : Icons.delete_outline,
                                                      color: const Color(
                                                          0xFFB91C1C),
                                                    ),
                                            ),
                                            const SizedBox(height: 6),
                                            IconButton(
                                              tooltip:
                                                  'Open technician location map',
                                              padding: EdgeInsets.zero,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 36,
                                              ),
                                              onPressed: jobIdValue == null
                                                  ? null
                                                  : () => _openTechnicianMap(
                                                        jobId: jobIdValue,
                                                        technicianId:
                                                            technicianIdValue,
                                                        jobTitle: job,
                                                        technicianName:
                                                            technician,
                                                      ),
                                              icon: const Icon(
                                                Icons.location_on_outlined,
                                                color: Color(0xFF2563EB),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text('Job ID: $jobId',
                                      style: const TextStyle(
                                          color: Color(0xFF475569))),
                                  const SizedBox(height: 4),
                                  Text('Technician: $technician',
                                      style: const TextStyle(
                                          color: Color(0xFF475569))),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Updated: $updated',
                                    style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return Column(
                          children: [
                            ...cards,
                            if (visibleRows.length > visibleCount) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: IconButton.filledTonal(
                                  onPressed: () {
                                    setState(() {
                                      _visibleJobCount += _jobsPageSize;
                                    });
                                  },
                                  tooltip: 'View 4 more jobs',
                                  icon: const Icon(
                                      Icons.keyboard_arrow_down),
                                ),
                              ),
                            ],
                            if (visibleCount > _jobsPageSize) ...[
                              const SizedBox(height: 4),
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _visibleJobCount = _jobsPageSize;
                                  });
                                },
                                icon: const Icon(Icons.keyboard_arrow_up),
                                label: const Text('Show less'),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ── Technician Tracking Feed ────────────────────────────────
                  _SectionLabel(
                    title: 'Technician Tracking Feed',
                    subtitle:
                        'Current location status for active technicians.',
                    action: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _openLiveMap(liveRows),
                          icon: const Icon(Icons.map_outlined),
                          tooltip: 'View on map',
                        ),
                        IconButton(
                          onPressed: () =>
                              _refreshDashboard(showFeedback: true),
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Refresh',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: _cardDecoration(),
                    child: liveTrackingAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Text(
                        'Unable to load live technician data: ${_cleanLiveError(e)}',
                        style: const TextStyle(color: Color(0xFF7C2D12)),
                      ),
                      data: (_) {
                        if (liveRows.isEmpty) {
                          return const _EmptyBlock(
                            icon: Icons.location_disabled_outlined,
                            title: 'No active technician updates',
                            subtitle:
                                'Only active tracking sessions appear here. Completed jobs move out of the live feed automatically.',
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _StatusTag(
                                  label: '$liveNowCount Live',
                                  color: const Color(0xFF2563EB),
                                ),
                                if (offlineHistoryCount > 0)
                                  _StatusTag(
                                    label: '$offlineHistoryCount Offline',
                                    color: const Color(0xFF64748B),
                                  ),
                                const _StatusTag(
                                  label: 'Refresh 10s',
                                  color: Color(0xFF0F9D58),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ...liveRows.map((row) {
                              final name = _asText(row['technician_name']);
                              final job = _asText(row['job_title']);
                              final status = _asText(row['status']);
                              final lat = _asDouble(row['latitude']);
                              final lng = _asDouble(row['longitude']);
                              final snapshot =
                                  TrackingPresence.evaluate(row);
                              final lastSeen = snapshot.updatedAt == null
                                  ? 'Unknown'
                                  : _timeAgo(snapshot.updatedAt!
                                      .toIso8601String());
                              final isOfflineHistory =
                                  _asBool(row['is_offline_history']);
                              final needsAttention =
                                  _asBool(row['needs_attention']);
                              final battery = _getBatteryLevel(row);
                              final isCharging = _getIsCharging(row);

                              return _TrackingFeedCard(
                                technicianName: name,
                                jobTitle: job,
                                jobStatusLabel: _titleCase(status),
                                jobStatusColor: _statusColor(status),
                                sourceLabel: isOfflineHistory
                                    ? 'Offline history'
                                    : 'Live now',
                                sourceColor: isOfflineHistory
                                    ? const Color(0xFF64748B)
                                    : const Color(0xFF2563EB),
                                trackingLabel:
                                    _presencePillLabel(snapshot),
                                trackingColor:
                                    _presencePillColor(snapshot),
                                coordinateLabel:
                                    '${_coord(lat)}, ${_coord(lng)}',
                                updatedLabel: lastSeen,
                                toneColor: isOfflineHistory
                                    ? const Color(0xFFF1F5F9)
                                    : const Color(0xFFE0F2FE),
                                supportText:
                                    _presenceSupportText(snapshot),
                                needsAttention: needsAttention,
                                battery: battery,
                                isCharging: isCharging,
                              );
                            }).toList(growable: false),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),

                  // ── Deleted Jobs ────────────────────────────────────────────
                  _SectionLabel(
                    title: 'Deleted Jobs',
                    subtitle:
                        'Recently removed jobs kept for audit visibility.',
                    action: IconButton(
                      onPressed: () =>
                          ref.invalidate(adminDeletedJobsProvider),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh deleted jobs',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: _cardDecoration(),
                    child: deletedJobsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) {
                        final message = e
                            .toString()
                            .replaceFirst('Exception: ', '')
                            .trim();
                        if (message.toLowerCase().contains('not found')) {
                          return const _EmptyBlock(
                            icon: Icons.inventory_2_outlined,
                            title: 'Deleted jobs API unavailable',
                            subtitle:
                                'This section will populate when the server exposes deleted jobs data.',
                          );
                        }
                        return Text(
                          'Unable to load deleted jobs: $message',
                          style:
                              const TextStyle(color: Color(0xFF7C2D12)),
                        );
                      },
                      data: (rows) {
                        if (rows.isEmpty) {
                          return const _EmptyBlock(
                            icon: Icons.delete_sweep_outlined,
                            title: 'No deleted jobs',
                            subtitle:
                                'Deleted jobs will appear here for review.',
                          );
                        }

                        final cards = rows.map((row) {
                          final jobId = _asText(row['job_id']);
                          final title = _asText(row['job_title']);
                          final tech = _asText(row['technician_name']);
                          final deletedAt = _asText(row['deleted_at']);
                          return _DeletedJobCard(
                            title: title,
                            jobId: jobId,
                            technician: tech,
                            deletedAtLabel: _timeAgo(deletedAt),
                          );
                        }).toList(growable: false);

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SectionBanner(
                              icon: Icons.inventory_2_outlined,
                              title:
                                  '${rows.length} archived job record(s)',
                              subtitle:
                                  'Removed jobs stay visible here for audit review and traceability.',
                              tint: const Color(0xFFFEE2E2),
                              iconColor: const Color(0xFFB91C1C),
                            ),
                            const SizedBox(height: 12),
                            ...cards,
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPONENTS
// ═══════════════════════════════════════════════════════════════════════════════

class _AdminTopBar extends StatelessWidget {
  const _AdminTopBar({
    required this.loading,
    required this.onLogout,
  });

  final bool loading;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Semantics(
          label: 'FSM logo',
          image: true,
          child: Container(
            width: 58,
            height: 58,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 18,
                  offset: Offset(0, 8),
                  color: Color(0x14000000),
                ),
              ],
            ),
            child: Image.asset(
              'assets/logo/app_launcher.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.business_center_rounded,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'FSM',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
            letterSpacing: 1.2,
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: loading ? null : onLogout,
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.logout, size: 18),
          label: const Text('Logout'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0F172A),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ],
    );
  }
}

class _OverviewMetric {
  const _OverviewMetric({
    required this.label,
    required this.helper,
    this.value = '-',
  });

  final String label;
  final String helper;
  final String value;

  _OverviewMetric copyWith({String? label, String? helper, String? value}) {
    return _OverviewMetric(
      label: label ?? this.label,
      helper: helper ?? this.helper,
      value: value ?? this.value,
    );
  }
}

class _AdminOverviewCard extends StatelessWidget {
  const _AdminOverviewCard({
    required this.onRefresh,
    required this.onCreateJob,
    required this.onOpenLiveMap,
    required this.metrics,
    required this.refreshInProgress,
    this.summaryError,
  });

  final VoidCallback? onRefresh;
  final VoidCallback onCreateJob;
  final VoidCallback onOpenLiveMap;
  final List<_OverviewMetric> metrics;
  final bool refreshInProgress;
  final String? summaryError;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Admin Dashboard',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'A simple workspace for jobs, technician activity, and audit history.',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filled(
                onPressed: onRefresh,
                tooltip: 'Refresh dashboard',
                icon: refreshInProgress
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: metrics
                    .map(
                      (metric) => SizedBox(
                        width: itemWidth,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                metric.label,
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                metric.value,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                metric.helper,
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onCreateJob,
                  icon: const Icon(Icons.add_task),
                  label: const Text('Create Job'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onOpenLiveMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Open Live Map'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0F172A),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (summaryError != null && summaryError!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              summaryError!,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFB45309),
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF64748B),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SectionBanner extends StatelessWidget {
  const _SectionBanner({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tint,
    required this.iconColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeletedJobCard extends StatelessWidget {
  const _DeletedJobCard({
    required this.title,
    required this.jobId,
    required this.technician,
    required this.deletedAtLabel,
  });

  final String title;
  final String jobId;
  final String technician;
  final String deletedAtLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFBFB), Color(0xFFF8FAFC)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1D5DB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.delete_outline_rounded,
                  color: Color(0xFFB91C1C),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        const _StatusTag(
                          label: 'Deleted',
                          color: Color(0xFFB91C1C),
                        ),
                        _StatusTag(
                          label: 'ID $jobId',
                          color: const Color(0xFF64748B),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MetaRow(
                  icon: Icons.engineering_outlined,
                  label: 'Assigned technician',
                  value: technician,
                ),
                const SizedBox(height: 10),
                _MetaRow(
                  icon: Icons.history_toggle_off_rounded,
                  label: 'Removed from active queue',
                  value: deletedAtLabel,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingFeedCard extends StatelessWidget {
  const _TrackingFeedCard({
    required this.technicianName,
    required this.jobTitle,
    required this.jobStatusLabel,
    required this.jobStatusColor,
    required this.sourceLabel,
    required this.sourceColor,
    required this.trackingLabel,
    required this.trackingColor,
    required this.coordinateLabel,
    required this.updatedLabel,
    required this.toneColor,
    required this.supportText,
    required this.needsAttention,
    this.battery,
    this.isCharging,
  });

  final String technicianName;
  final String jobTitle;
  final String jobStatusLabel;
  final Color jobStatusColor;
  final String sourceLabel;
  final Color sourceColor;
  final String trackingLabel;
  final Color trackingColor;
  final String coordinateLabel;
  final String updatedLabel;
  final Color toneColor;
  final String supportText;
  final bool needsAttention;
  final int? battery;
  final bool? isCharging;

  @override
  Widget build(BuildContext context) {
    final initial = technicianName.trim().isEmpty
        ? 'T'
        : technicianName.trim()[0].toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, toneColor],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: sourceColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: sourceColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(15),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: TextStyle(
                    color: sourceColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            technicianName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      
                          const SizedBox(width: 8),
                          _BatteryBadge(
                            level: battery ?? -1,
                            charging: isCharging ?? false,
                          ),
                        ],
                      
                    ),
                    const SizedBox(height: 4),
                    Text(
                      jobTitle,
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusTag(label: jobStatusLabel, color: jobStatusColor),
              _StatusTag(label: sourceLabel, color: sourceColor),
              _StatusTag(label: trackingLabel, color: trackingColor),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            supportText,
            style: const TextStyle(color: Color(0xFF334155), height: 1.4),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                _MetaRow(
                  icon: Icons.place_outlined,
                  label: 'Last known coordinates',
                  value: coordinateLabel,
                ),
                const SizedBox(height: 10),
                _MetaRow(
                  icon: needsAttention
                      ? Icons.warning_amber_rounded
                      : Icons.schedule_rounded,
                  label: needsAttention ? 'Sync delay' : 'Last synced',
                  value: updatedLabel,
                  valueColor: needsAttention
                      ? const Color(0xFFB45309)
                      : const Color(0xFF0F172A),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF0F172A),
  });

  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF64748B)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Icon(icon, size: 34, color: const Color(0xFF94A3B8)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF64748B), height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// Shared card decoration
BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: Colors.white.withValues(alpha: 0.85),
    borderRadius: BorderRadius.circular(20),
    boxShadow: const [
      BoxShadow(
        blurRadius: 20,
        offset: Offset(0, 10),
        color: Color(0x14000000),
      ),
    ],
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// 🔋 _BatteryBadge — animated charging bolt + colour-coded level
// ═══════════════════════════════════════════════════════════════════════════════

class _BatteryBadge extends StatefulWidget {
  const _BatteryBadge({
    required this.level,
    required this.charging,
  });

  final int level;
  final bool charging;

  @override
  State<_BatteryBadge> createState() => _BatteryBadgeState();
}

class _BatteryBadgeState extends State<_BatteryBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulse = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.charging) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_BatteryBadge old) {
    super.didUpdateWidget(old);
    if (widget.charging && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.charging && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

 Color get _levelColor {
  if (widget.level < 0) return const Color(0xFF94A3B8); // UNKNOWN (grey)
  if (widget.level <= 15) return const Color(0xFFDC2626);
  if (widget.level <= 30) return const Color(0xFFEA580C);
  if (widget.level <= 50) return const Color(0xFFF59E0B);
  return const Color(0xFF10B981);
}

IconData get _batteryIcon {
  if (widget.level < 0) return Icons.battery_unknown;
  if (widget.charging) return Icons.battery_charging_full;
  if (widget.level >= 90) return Icons.battery_full;
  if (widget.level >= 70) return Icons.battery_6_bar;
  if (widget.level >= 50) return Icons.battery_5_bar;
  if (widget.level >= 30) return Icons.battery_4_bar;
  if (widget.level >= 15) return Icons.battery_3_bar;
  if (widget.level >= 5) return Icons.battery_2_bar;
  return Icons.battery_alert;
}

  @override
  Widget build(BuildContext context) {
    final color = _levelColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Battery body icon
          Icon(_batteryIcon, size: 14, color: color),
          const SizedBox(width: 4),
          // Percentage text
          Text(
            '${widget.level}%',
            style: TextStyle(
              fontSize: 11,
              fontWeight:
                  widget.level <= 15 ? FontWeight.w700 : FontWeight.w600,
              color: color,
            ),
          ),
          // Animated bolt when charging
          if (widget.charging) ...[
            const SizedBox(width: 3),
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Opacity(
                opacity: _pulse.value,
                child: Icon(
                  Icons.flash_on_rounded,
                  size: 11,
                  color: color,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}