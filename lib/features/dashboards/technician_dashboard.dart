import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/auth_notifier.dart';
import '../jobs/application/job_controller.dart';
import '../notifications/application/notification_controller.dart';

class TechnicianDashboard extends ConsumerStatefulWidget {
  const TechnicianDashboard({super.key});

  @override
  ConsumerState<TechnicianDashboard> createState() =>
      _TechnicianDashboardState();
}

class _TechnicianDashboardState extends ConsumerState<TechnicianDashboard>
    with WidgetsBindingObserver {
  static const int _jobsPageSize = 4;
  final Set<int> _acceptingJobIds = <int>{};
  final Set<int> _finishingJobIds = <int>{};
  Timer? _jobsRefreshTimer;
  Timer? _notificationTimer;
  bool _isForeground = true;
  bool _notificationPollBusy = false;
  int _lastSeenNotificationId = 0;
  int? _syncedTrackingJobId;
  int _visibleJobCount = _jobsPageSize;

  int? _extractJobId(Map<String, dynamic> job) {
    for (final key in const ['job_id', 'id']) {
      final value = job[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  String _extractStatus(Map<String, dynamic> job) {
    final raw = (job['status'] ?? job['job_status'] ?? '').toString().trim();
    return raw.isEmpty ? 'pending' : raw;
  }

  bool _canAccept(String status) {
    final lower = status.toLowerCase();
    return lower == 'assigned' ||
        lower == 'pending' ||
        lower == 'open' ||
        lower == 'new';
  }

  bool _canFinish(String status) {
    final lower = status.toLowerCase();
    return lower == 'accepted' ||
        lower == 'in_progress' ||
        lower == 'active' ||
        lower == 'ongoing';
  }

  DateTime? _extractJobDate(Map<String, dynamic> job) {
    const keys = [
      'job_date',
      'scheduled_date',
      'scheduled_at',
      'created_at',
      'assigned_at',
      'updated_at',
    ];

    for (final key in keys) {
      final raw = job[key];
      if (raw == null) continue;

      final text = raw.toString().trim();
      if (text.isEmpty) continue;

      final parsed = DateTime.tryParse(text) ??
          DateTime.tryParse(text.replaceFirst(' ', 'T'));
      if (parsed != null) return parsed;
    }

    return null;
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isBusy() => _acceptingJobIds.isNotEmpty || _finishingJobIds.isNotEmpty;

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
    return cleaned
        .split(RegExp(r'\s+'))
        .map((word) {
          if (word.isEmpty) return word;
          return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
        })
        .join(' ');
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
      default:
        return const Color(0xFF64748B);
    }
  }

  String _jobTimingLabel(Map<String, dynamic> job) {
    final date = _extractJobDate(job)?.toLocal();
    if (date == null) return 'Schedule not available';
    final now = DateTime.now();
    if (_isSameDate(date, now)) return 'Scheduled for today';
    if (_isSameDate(date, now.add(const Duration(days: 1)))) {
      return 'Scheduled for tomorrow';
    }
    return 'Scheduled ${_timeAgo(date)}';
  }

  String _jobSupportText(String status) {
    if (_canAccept(status)) {
      return 'Accept to start tracking.';
    }
    if (_canFinish(status)) {
      return 'Tracking is active.';
    }
    if (status.toLowerCase() == 'completed') {
      return 'Completed successfully.';
    }
    return 'Waiting for update.';
  }

  Future<void> _refreshDashboard({bool showFeedback = false}) async {
    _refreshJobs();
    await Future.wait([
      ref.refresh(myJobsProvider.future),
      ref.refresh(adminTechnicianLiveProvider.future),
    ]);
    if (showFeedback && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jobs refreshed')),
      );
    }
  }

  void _refreshJobs() {
    ref.invalidate(myJobsProvider);
    ref.invalidate(adminTechnicianLiveProvider);
  }

  bool _shouldAutoRefresh() {
    if (!mounted || !_isForeground || _isBusy()) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
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

  Future<void> _bootstrapNotificationCursor() async {
    try {
      final latest =
          await ref.read(notificationPollingControllerProvider).fetchLatest();
      if (latest.isNotEmpty) {
        _lastSeenNotificationId = _notificationId(latest.first);
      }
    } catch (_) {
      // Ignore startup polling failure.
    }
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
          SnackBar(
            content: Text(_notificationBody(item)),
          ),
        );
      }
    } catch (_) {
      // Ignore transient polling failures.
    } finally {
      _notificationPollBusy = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_bootstrapNotificationCursor);
    _jobsRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_shouldAutoRefresh()) return;
      unawaited(_refreshDashboard());
    });
    _notificationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _pollNotifications();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    unawaited(ref.read(technicianTrackingServiceProvider).stopTracking());
    _jobsRefreshTimer?.cancel();
    _notificationTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _acceptJob(Map<String, dynamic> job) async {
    final jobId = _extractJobId(job);
    if (jobId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Missing job id. Cannot accept this job.')),
      );
      return;
    }

    setState(() => _acceptingJobIds.add(jobId));
    try {
      final message = await ref
          .read(jobActionControllerProvider)
          .acceptJobAndShareLocation(jobId: jobId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      ref.invalidate(myJobsProvider);
      ref.invalidate(adminTechnicianLiveProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _acceptingJobIds.remove(jobId));
      }
    }
  }

  Future<void> _finishJob(Map<String, dynamic> job) async {
    final jobId = _extractJobId(job);
    if (jobId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Missing job id. Cannot finish this job.')),
      );
      return;
    }

    setState(() => _finishingJobIds.add(jobId));
    try {
      final message = await ref
          .read(jobActionControllerProvider)
          .finishJobAndStopTracking(jobId: jobId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      ref.invalidate(myJobsProvider);
      ref.invalidate(adminTechnicianLiveProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _finishingJobIds.remove(jobId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(myJobsProvider);
    final jobsData = jobsAsync.valueOrNull ?? const <dynamic>[];
    final now = DateTime.now();

    var totalJobs = 0;
    var activeJobs = 0;
    var completedJobs = 0;
    var todaysJobs = 0;
    var waitingJobs = 0;
    var hasDateData = false;
    int? activeTrackingJobId;

    for (final item in jobsData) {
      if (item is! Map<String, dynamic>) continue;
      totalJobs++;
      final status = _extractStatus(item).toLowerCase();
      if (_canAccept(status)) waitingJobs++;
      if (_canFinish(status)) activeJobs++;
      if (status == 'completed') completedJobs++;
      if (activeTrackingJobId == null && _canFinish(status)) {
        activeTrackingJobId = _extractJobId(item);
      }

      final date = _extractJobDate(item);
      if (date != null) {
        hasDateData = true;
        if (_isSameDate(date, now)) {
          todaysJobs++;
        }
      }
    }

    if (!hasDateData) {
      todaysJobs = totalJobs;
    }

    final showLoadingStats =
        jobsAsync.isLoading && jobsAsync.valueOrNull == null;
    final todaysJobsText = showLoadingStats ? '...' : todaysJobs.toString();
    final waitingJobsText = showLoadingStats ? '...' : waitingJobs.toString();
    final activeJobsText = showLoadingStats ? '...' : activeJobs.toString();
    final completedJobsText =
        showLoadingStats ? '...' : completedJobs.toString();
    final trackingStatusText = activeTrackingJobId == null
        ? 'No live tracking active'
        : 'Tracking Job ID $activeTrackingJobId';

    if (_syncedTrackingJobId != activeTrackingJobId) {
      _syncedTrackingJobId = activeTrackingJobId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          ref
              .read(jobActionControllerProvider)
              .syncTrackingForActiveJob(activeJobId: activeTrackingJobId),
        );
      });
    }

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFD9E9FF),
              Color(0xFFF6FAFF),
            ],
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
                  // ── HEADER: Logo + FSM text (left) | Logout (right) ──
                  _TechnicianHeader(
                    onLogout: () {
                      unawaited(
                        ref
                            .read(technicianTrackingServiceProvider)
                            .stopTracking(),
                      );
                      ref.read(authProvider.notifier).logout();
                    },
                  ),
                  const SizedBox(height: 20),

                  // ── OVERVIEW CARD ──
                  _TechnicianOverviewCard(
                    onRefresh: () => _refreshDashboard(showFeedback: true),
                    trackingStatus: trackingStatusText,
                    metrics: [
                      const _OverviewMetric(
                        label: 'Today',
                        helper: 'Assigned today',
                      ).copyWith(value: todaysJobsText),
                      const _OverviewMetric(
                        label: 'Waiting',
                        helper: 'Need action',
                      ).copyWith(value: waitingJobsText),
                      const _OverviewMetric(
                        label: 'Active',
                        helper: 'In progress',
                      ).copyWith(value: activeJobsText),
                      const _OverviewMetric(
                        label: 'Done',
                        helper: 'Completed',
                      ).copyWith(value: completedJobsText),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // ── MY JOBS SECTION ──
                  _SectionLabel(
                    title: 'My Jobs',
                    subtitle: 'Your latest assigned work.',
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: _cardDecoration(),
                    child: jobsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Text(
                        'Unable to load jobs: ${e.toString().replaceFirst('Exception: ', '')}',
                        style: const TextStyle(color: Color(0xFF7C2D12)),
                      ),
                      data: (jobs) {
                        if (jobs.isEmpty) {
                          return const _EmptyBlock(
                            icon: Icons.work_outline,
                            title: 'No jobs assigned',
                            subtitle:
                                'New assignments will appear here when work is assigned to you.',
                          );
                        }

                        final visibleCount = _visibleJobCount > jobs.length
                            ? jobs.length
                            : _visibleJobCount;
                        final cards = <Widget>[];
                        for (var i = 0; i < visibleCount; i++) {
                          final dynamic item = jobs[i];
                          final job = item is Map<String, dynamic>
                              ? item
                              : <String, dynamic>{};
                          final title =
                              (job['title'] ?? job['job_title'] ?? 'Untitled job')
                                  .toString();
                          final status = _extractStatus(job);
                          final jobId = _extractJobId(job);
                          final isAccepting =
                              jobId != null && _acceptingJobIds.contains(jobId);
                          final isFinishing =
                              jobId != null && _finishingJobIds.contains(jobId);
                          final canAccept = _canAccept(status);
                          final canFinish = _canFinish(status);

                          cards.add(
                            Container(
                              margin: EdgeInsets.only(
                                bottom: i == visibleCount - 1 ? 0 : 10,
                              ),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8FAFC),
                                borderRadius: BorderRadius.circular(16),
                                border:
                                    Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                      ),
                                      _StatusTag(
                                        label: _titleCase(status),
                                        color: _statusColor(status),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  if (jobId != null)
                                    Text(
                                      'Job ID: $jobId',
                                      style: const TextStyle(
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _jobTimingLabel(job),
                                    style: const TextStyle(
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _jobSupportText(status),
                                    style: const TextStyle(
                                      color: Color(0xFF64748B),
                                      fontSize: 12,
                                      height: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      if (canAccept)
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: isAccepting
                                                ? null
                                                : () => _acceptJob(job),
                                            icon: isAccepting
                                                ? const SizedBox(
                                                    height: 16,
                                                    width: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: Colors.white,
                                                    ),
                                                  )
                                                : const Icon(
                                                    Icons.check_circle_outline),
                                            label: Text(
                                              isAccepting
                                                  ? 'Accepting...'
                                                  : 'Accept',
                                            ),
                                          ),
                                        ),
                                      if (canAccept && canFinish)
                                        const SizedBox(width: 10),
                                      if (canFinish)
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: isFinishing
                                                ? null
                                                : () => _finishJob(job),
                                            icon: isFinishing
                                                ? const SizedBox(
                                                    height: 16,
                                                    width: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                                  )
                                                : const Icon(Icons.flag_outlined),
                                            label: Text(
                                              isFinishing
                                                  ? 'Finishing...'
                                                  : 'Finish',
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        }

                        return Column(
                          children: [
                            ...cards,
                            if (jobs.length > visibleCount) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: IconButton.filledTonal(
                                  onPressed: () {
                                    setState(() {
                                      _visibleJobCount += _jobsPageSize;
                                    });
                                  },
                                  tooltip: 'View 4 more jobs',
                                  icon: const Icon(Icons.keyboard_arrow_down),
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
                  // ── OLD BOTTOM LOGOUT BUTTON REMOVED ──
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── NEW: Header widget with logo + FSM text + Logout ──────────────────────────
class _TechnicianHeader extends StatelessWidget {
  const _TechnicianHeader({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Logo
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

        // FSM text
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

        // Logout button
        FilledButton.icon(
          onPressed: onLogout,
          icon: const Icon(Icons.logout, size: 18),
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

// ── UNCHANGED WIDGETS BELOW ───────────────────────────────────────────────────

class _OverviewMetric {
  const _OverviewMetric({
    required this.label,
    required this.helper,
    this.value = '-',
  });

  final String label;
  final String helper;
  final String value;

  _OverviewMetric copyWith({
    String? label,
    String? helper,
    String? value,
  }) {
    return _OverviewMetric(
      label: label ?? this.label,
      helper: helper ?? this.helper,
      value: value ?? this.value,
    );
  }
}

class _TechnicianOverviewCard extends StatelessWidget {
  const _TechnicianOverviewCard({
    required this.onRefresh,
    required this.trackingStatus,
    required this.metrics,
  });

  final VoidCallback onRefresh;
  final String trackingStatus;
  final List<_OverviewMetric> metrics;

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
                      'Technician Dashboard',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Your jobs and tracking status in one place.',
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
                tooltip: 'Refresh jobs',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _StatusTag(
            label: trackingStatus,
            color: const Color(0xFF0F766E),
          ),
          const SizedBox(height: 16),
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
                            border: Border.all(
                              color: const Color(0xFFE2E8F0),
                            ),
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
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF4F7DF3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'TECHNICIAN',
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _DashboardHero extends StatelessWidget {
  const _DashboardHero({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.highlights,
    required this.action,
  });

  final String title;
  final String subtitle;
  final Widget badge;
  final List<_HeroItem> highlights;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0F172A),
            Color(0xFF0F766E),
          ],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x220F172A),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    badge,
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFFCCFBF1),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              action,
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: highlights
                .map(
                  (item) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${item.label}: ${item.value}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _HeroItem {
  const _HeroItem({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
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
            style: const TextStyle(
              color: Color(0xFF64748B),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final Color badgeColor;

  const _StatCard({
    required this.title,
    required this.value,
    required this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: badgeColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData leftIcon;
  final String leftText;
  final VoidCallback? onLeftTap;
  final IconData rightIcon;
  final String rightText;
  final VoidCallback? onRightTap;

  const _ActionRow({
    required this.leftIcon,
    required this.leftText,
    this.onLeftTap,
    required this.rightIcon,
    required this.rightText,
    this.onRightTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: leftIcon,
            text: leftText,
            onTap: onLeftTap,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _ActionButton(
            icon: rightIcon,
            text: rightText,
            onTap: onRightTap,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.text,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF475569)),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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