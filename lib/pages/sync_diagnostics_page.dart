import 'dart:async';

import 'package:flutter/material.dart';

import '../data/firebase_sync_service.dart';

class SyncDiagnosticsPage extends StatefulWidget {
  const SyncDiagnosticsPage({super.key});

  @override
  State<SyncDiagnosticsPage> createState() => _SyncDiagnosticsPageState();
}

class _SyncDiagnosticsPageState extends State<SyncDiagnosticsPage> {
  final _sync = FirebaseSyncService.instance;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (_sync.healthReport.value == null) {
      unawaited(_runHealthCheck(showSnack: false));
    }
  }

  Future<void> _runHealthCheck({bool showSnack = true}) async {
    setState(() => _loading = true);
    try {
      final report = await _sync.runHealthCheck();
      if (!mounted) return;
      if (showSnack) {
        final message = report.mismatchCount == 0
            ? 'Health check passed'
            : 'Health check found ${report.mismatchCount} mismatch(es)';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Health check failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmtDate(DateTime? value) {
    if (value == null) return '-';
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    final ss = value.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final pullStats = _sync.lastPullStats.values.toList()
      ..sort((a, b) => a.table.compareTo(b.table));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Diagnostics'),
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _runHealthCheck(),
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.health_and_safety_rounded),
            tooltip: 'Run Health Check',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sync Status',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  _line(
                    'Last Full Sync Start',
                    _fmtDate(_sync.lastFullSyncStartedAt),
                  ),
                  _line(
                    'Last Full Sync End',
                    _fmtDate(_sync.lastFullSyncFinishedAt),
                  ),
                  _line(
                    'Last Full Sync Result',
                    _sync.lastFullSyncSucceeded == null
                        ? '-'
                        : (_sync.lastFullSyncSucceeded! ? 'SUCCESS' : 'FAILED'),
                  ),
                  _line('Last Sync Error', _sync.lastSyncError ?? '-'),
                  ValueListenableBuilder<int>(
                    valueListenable: _sync.pendingSyncCount,
                    builder: (_, count, __) =>
                        _line('Pending Queue', count.toString()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last Pull Stats',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (pullStats.isEmpty)
                    const Text('No full sync stats available yet.')
                  else
                    for (final stat in pullStats)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${stat.table}: remote=${stat.remoteRows}, upsert=${stat.upsertedRows}, delete=${stat.deletedRows}, status=${stat.success ? 'OK' : 'FAIL'}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<SyncHealthReport?>(
            valueListenable: _sync.healthReport,
            builder: (_, report, __) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Health Check',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      if (report == null)
                        const Text('No health check run yet.')
                      else ...[
                        _line('Checked At', _fmtDate(report.checkedAt)),
                        _line('Mismatch Count', report.mismatchCount.toString()),
                        const SizedBox(height: 8),
                        for (final row in report.rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              row.error != null
                                  ? '${row.table}: ERROR ${row.error}'
                                  : '${row.table}: local=${row.localCount}, remote=${row.remoteCount}, status=${row.inSync ? 'OK' : 'MISMATCH'}',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text('$label: $value'),
    );
  }
}
