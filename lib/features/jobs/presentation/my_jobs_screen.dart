import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/job_controller.dart';
import 'technician_map_screen.dart'; // adjust path if needed

class MyJobsScreen extends ConsumerStatefulWidget {
  const MyJobsScreen({super.key});

  @override
  ConsumerState<MyJobsScreen> createState() => _MyJobsScreenState();
}

class _MyJobsScreenState extends ConsumerState<MyJobsScreen> {
  final Set<int> _acceptingJobIds = <int>{};

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
    if (raw.isEmpty) return 'pending';
    return raw;
  }

  bool _canAccept(String status) {
    final lower = status.toLowerCase();
    return lower != 'accepted' &&
        lower != 'in_progress' &&
        lower != 'completed' &&
        lower != 'cancelled';
  }

  bool _isCompletedStatus(String status) {
    final lower = status.toLowerCase();
    return lower == 'completed' ||
        lower == 'finished' ||
        lower == 'ended' ||
        lower == 'closed' ||
        lower == 'done';
  }

  Future<void> _acceptJob(Map<String, dynamic> job) async {
    final jobId = _extractJobId(job);
    if (jobId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing job id. Cannot accept this job.')),
      );
      return;
    }

    setState(() => _acceptingJobIds.add(jobId));
    try {
      final response = await ref
          .read(jobActionControllerProvider)
          .acceptJobAndShareLocation(jobId: jobId);

      final message =
          response['message']?.toString() ?? 'Job accepted successfully';

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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

  void _openLocationMap(
    BuildContext context, {
    required int jobId,
    required String jobTitle,
    required bool isCompleted,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TechnicianLocationsMapScreen(
          jobIdFilter: jobId,
          jobTitleHint: jobTitle,
          offlineHistoryOnly: isCompleted,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(myJobsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Jobs'),
      ),
      body: jobsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (jobs) {
          if (jobs.isEmpty) {
            return const Center(child: Text('No jobs assigned'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final dynamic item = jobs[index];
              final job = item is Map<String, dynamic>
                  ? item
                  : <String, dynamic>{};

              final status = _extractStatus(job);
              final jobId = _extractJobId(job);
              final accepting =
                  jobId != null && _acceptingJobIds.contains(jobId);
              final showAccept = _canAccept(status);
              final isCompleted = _isCompletedStatus(status);

              final jobTitle =
                  (job['title'] ?? job['job_title'] ?? 'Job ${jobId ?? ''}')
                      .toString();

              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 10,
                      offset: Offset(0, 4),
                      color: Color(0x14000000),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── TITLE ROW + LOCATION ICON ──────────────────────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            jobTitle,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (jobId != null)
                          Tooltip(
                            message: isCompleted
                                ? 'View offline route history'
                                : 'View live location',
                            child: IconButton(
                              icon: Icon(
                                isCompleted
                                    ? Icons.history_toggle_off_outlined
                                    : Icons.location_on_outlined,
                                color: isCompleted
                                    ? const Color(0xFF64748B)
                                    : const Color(0xFF2563EB),
                              ),
                              onPressed: () => _openLocationMap(
                                context,
                                jobId: jobId,
                                jobTitle: jobTitle,
                                isCompleted: isCompleted,
                              ),
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    // ── STATUS CHIP ────────────────────────────────────────
                    _StatusChip(status: status),

                    // ── ACCEPT BUTTON ──────────────────────────────────────
                    if (showAccept) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton.icon(
                          onPressed: accepting ? null : () => _acceptJob(job),
                          icon: accepting
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.check_circle_outline),
                          label: Text(
                              accepting ? 'Accepting...' : 'Accept Job'),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  STATUS CHIP
// ════════════════════════════════════════════════════════════

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  Color _chipColor() {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'finished':
      case 'done':
      case 'ended':
        return const Color(0xFF16A34A);
      case 'in_progress':
      case 'active':
      case 'accepted':
        return const Color(0xFF2563EB);
      case 'cancelled':
      case 'rejected':
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFF64748B);
    }
  }

  String _chipLabel() {
    final cleaned = status.trim().replaceAll('_', ' ');
    if (cleaned.isEmpty) return '-';
    return cleaned
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final color = _chipColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _chipLabel(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}