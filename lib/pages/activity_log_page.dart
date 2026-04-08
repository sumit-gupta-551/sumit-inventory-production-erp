import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

class ActivityLogPage extends StatefulWidget {
  const ActivityLogPage({super.key});

  @override
  State<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends State<ActivityLogPage> {
  List<Map<String, dynamic>> logs = [];
  bool loading = true;
  int offset = 0;
  static const int pageSize = 100;
  bool hasMore = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final result = await ErpDatabase.instance.getActivityLogs(
        limit: pageSize,
        offset: 0,
      );
      if (!mounted) return;
      setState(() {
        logs = result;
        offset = result.length;
        hasMore = result.length == pageSize;
        loading = false;
      });
    } catch (e) {
      debugPrint('Error loading activity logs: $e');
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _loadMore() async {
    final result = await ErpDatabase.instance.getActivityLogs(
      limit: pageSize,
      offset: offset,
    );
    if (!mounted) return;
    setState(() {
      logs.addAll(result);
      offset += result.length;
      hasMore = result.length == pageSize;
    });
  }

  String _fmtTime(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy  HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  Color _actionColor(String action) {
    switch (action.toUpperCase()) {
      case 'INSERT':
        return Colors.green;
      case 'UPDATE':
        return Colors.orange;
      case 'DELETE':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  IconData _actionIcon(String action) {
    switch (action.toUpperCase()) {
      case 'INSERT':
        return Icons.add_circle_outline;
      case 'UPDATE':
        return Icons.edit_outlined;
      case 'DELETE':
        return Icons.delete_outline;
      default:
        return Icons.info_outline;
    }
  }

  String _friendlyTable(String? table) {
    if (table == null || table.isEmpty) return '-';
    return table
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty
            ? '${w[0].toUpperCase()}${w.substring(1)}'
            : '')
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Log'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : logs.isEmpty
              ? const Center(child: Text('No activity logs yet'))
              : ListView.builder(
                  itemCount: logs.length + (hasMore ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == logs.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: ElevatedButton(
                            onPressed: _loadMore,
                            child: const Text('Load More'),
                          ),
                        ),
                      );
                    }

                    final log = logs[i];
                    final action = (log['action'] ?? '').toString();
                    final table = log['table_name']?.toString();
                    final recordId = log['record_id'];
                    final details = (log['details'] ?? '').toString();
                    final user = (log['user_name'] ?? '-').toString();
                    final ts = log['timestamp'] as int?;

                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      child: ExpansionTile(
                        leading: Icon(
                          _actionIcon(action),
                          color: _actionColor(action),
                          size: 22,
                        ),
                        title: Text(
                          '$action  ${_friendlyTable(table)}  #${recordId ?? '-'}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _actionColor(action),
                          ),
                        ),
                        subtitle: Text(
                          '${_fmtTime(ts)}  |  User: ${user.isEmpty ? '-' : user}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        children: [
                          if (details.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  details,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black54),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
