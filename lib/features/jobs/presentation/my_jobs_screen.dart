import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/job_controller.dart';

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
      final message = await ref
          .read(jobActionControllerProvider)
          .acceptJobAndShareLocation(jobId: jobId);

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
              final accepting = jobId != null && _acceptingJobIds.contains(jobId);
              final showAccept = _canAccept(status);

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
                    Text(
                      (job['title'] ?? job['job_title'] ?? 'Untitled job')
                          .toString(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      status,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
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
                          label: Text(accepting ? 'Accepting...' : 'Accept Job'),
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
