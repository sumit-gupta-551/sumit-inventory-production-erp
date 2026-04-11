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

  // Filters
  String? _filterAction;
  String? _filterTable;
  String? _filterUser;
  DateTime? _filterFrom;
  DateTime? _filterTo;
  final _searchCtrl = TextEditingController();
  bool _showFilters = false;

  // Filter options
  List<String> _userOptions = [];
  List<String> _tableOptions = [];

  static const _actionOptions = ['INSERT', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT'];

  @override
  void initState() {
    super.initState();
    _loadFilterOptions();
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _loadFilterOptions() async {
    final db = ErpDatabase.instance;
    final users = await db.getActivityLogUsers();
    final tables = await db.getActivityLogTables();
    if (!mounted) return;
    setState(() {
      _userOptions = users;
      _tableOptions = tables;
    });
  }

  Future<void> _load() async {
    if (loading && logs.isNotEmpty) return; // already loading
    setState(() => loading = logs.isEmpty);
    try {
      final result = await ErpDatabase.instance.getActivityLogs(
        limit: pageSize,
        offset: 0,
        action: _filterAction,
        tableName: _filterTable,
        userName: _filterUser,
        fromMs: _filterFrom?.millisecondsSinceEpoch,
        toMs: _filterTo != null
            ? _filterTo!.add(const Duration(days: 1)).millisecondsSinceEpoch
            : null,
        search: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
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
      action: _filterAction,
      tableName: _filterTable,
      userName: _filterUser,
      fromMs: _filterFrom?.millisecondsSinceEpoch,
      toMs: _filterTo != null
          ? _filterTo!.add(const Duration(days: 1)).millisecondsSinceEpoch
          : null,
      search: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      logs.addAll(result);
      offset += result.length;
      hasMore = result.length == pageSize;
    });
  }

  void _clearFilters() {
    setState(() {
      _filterAction = null;
      _filterTable = null;
      _filterUser = null;
      _filterFrom = null;
      _filterTo = null;
      _searchCtrl.clear();
    });
    _load();
  }

  bool get _hasActiveFilters =>
      _filterAction != null ||
      _filterTable != null ||
      _filterUser != null ||
      _filterFrom != null ||
      _filterTo != null ||
      _searchCtrl.text.trim().isNotEmpty;

  String _fmtTime(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy  HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _fmtDate(DateTime d) => DateFormat('dd MMM yyyy').format(d);

  Color _actionColor(String action) {
    switch (action.toUpperCase()) {
      case 'INSERT':
        return const Color(0xFF10B981);
      case 'UPDATE':
        return const Color(0xFFF59E0B);
      case 'DELETE':
        return const Color(0xFFEF4444);
      case 'LOGIN':
        return const Color(0xFF3B82F6);
      case 'LOGOUT':
        return const Color(0xFF8B5CF6);
      default:
        return const Color(0xFF6B7280);
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
      case 'LOGIN':
        return Icons.login_rounded;
      case 'LOGOUT':
        return Icons.logout_rounded;
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

  Future<void> _pickDate(bool isFrom) async {
    final initial = isFrom
        ? (_filterFrom ?? DateTime.now())
        : (_filterTo ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _filterFrom = picked;
      } else {
        _filterTo = picked;
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Log'),
        actions: [
          if (_hasActiveFilters)
            IconButton(
              tooltip: 'Clear Filters',
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off, size: 22),
            ),
          IconButton(
            tooltip: _showFilters ? 'Hide Filters' : 'Show Filters',
            onPressed: () => setState(() => _showFilters = !_showFilters),
            icon: Icon(
              _showFilters ? Icons.filter_list_off : Icons.filter_list,
              color: _hasActiveFilters ? Colors.amber : null,
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              _loadFilterOptions();
              _load();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search Bar ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search logs...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _load();
                        },
                      )
                    : null,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onSubmitted: (_) => _load(),
            ),
          ),

          // ── Filters Panel ──
          if (_showFilters) _buildFilters(),

          // ── Active Filter Chips ──
          if (_hasActiveFilters) _buildActiveChips(),

          // ── Log Count ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${logs.length}${hasMore ? '+' : ''} logs',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600),
                ),
                const Spacer(),
              ],
            ),
          ),

          // ── Log List ──
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : logs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.history, size: 64,
                                color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text(
                              _hasActiveFilters
                                  ? 'No logs match filters'
                                  : 'No activity logs yet',
                              style: TextStyle(color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: logs.length + (hasMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == logs.length) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: OutlinedButton.icon(
                                  onPressed: _loadMore,
                                  icon: const Icon(Icons.expand_more),
                                  label: const Text('Load More'),
                                ),
                              ),
                            );
                          }
                          return _buildLogTile(logs[i]);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  // ── Filters Panel ──
  Widget _buildFilters() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          // Action filter
          _filterDropdown<String>(
            label: 'Action',
            value: _filterAction,
            items: _actionOptions
                .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                .toList(),
            onChanged: (v) {
              setState(() => _filterAction = v);
              _load();
            },
          ),

          // Table filter
          _filterDropdown<String>(
            label: 'Table',
            value: _filterTable,
            items: _tableOptions
                .map((t) => DropdownMenuItem(
                    value: t, child: Text(_friendlyTable(t))))
                .toList(),
            onChanged: (v) {
              setState(() => _filterTable = v);
              _load();
            },
          ),

          // User filter
          _filterDropdown<String>(
            label: 'User',
            value: _filterUser,
            items: _userOptions
                .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                .toList(),
            onChanged: (v) {
              setState(() => _filterUser = v);
              _load();
            },
          ),

          // Date range
          _dateButton('From', _filterFrom, () => _pickDate(true)),
          _dateButton('To', _filterTo, () => _pickDate(false)),
        ],
      ),
    );
  }

  Widget _filterDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        isExpanded: true,
        style: const TextStyle(fontSize: 13, color: Colors.black87),
      ),
    );
  }

  Widget _dateButton(String label, DateTime? date, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              date != null ? _fmtDate(date) : label,
              style: TextStyle(
                fontSize: 13,
                color: date != null ? Colors.black87 : Colors.grey.shade500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Active Filter Chips ──
  Widget _buildActiveChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          if (_filterAction != null)
            _chip(_filterAction!, () {
              setState(() => _filterAction = null);
              _load();
            }),
          if (_filterTable != null)
            _chip(_friendlyTable(_filterTable), () {
              setState(() => _filterTable = null);
              _load();
            }),
          if (_filterUser != null)
            _chip('User: $_filterUser', () {
              setState(() => _filterUser = null);
              _load();
            }),
          if (_filterFrom != null)
            _chip('From: ${_fmtDate(_filterFrom!)}', () {
              setState(() => _filterFrom = null);
              _load();
            }),
          if (_filterTo != null)
            _chip('To: ${_fmtDate(_filterTo!)}', () {
              setState(() => _filterTo = null);
              _load();
            }),
        ],
      ),
    );
  }

  Widget _chip(String label, VoidCallback onDelete) {
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      deleteIcon: const Icon(Icons.close, size: 14),
      onDeleted: onDelete,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.only(left: 6),
    );
  }

  // ── Single Log Tile ──
  Widget _buildLogTile(Map<String, dynamic> log) {
    final action = (log['action'] ?? '').toString();
    final table = log['table_name']?.toString();
    final recordId = log['record_id'];
    final details = (log['details'] ?? '').toString();
    final user = (log['user_name'] ?? '').toString();
    final ts = log['timestamp'] as int?;
    final color = _actionColor(action);
    final isLoginLogout =
        action.toUpperCase() == 'LOGIN' || action.toUpperCase() == 'LOGOUT';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color.withValues(alpha: 0.2)),
      ),
      child: ExpansionTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_actionIcon(action), color: color, size: 20),
        ),
        title: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                action,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isLoginLogout
                    ? (details.isNotEmpty ? details : action)
                    : '${_friendlyTable(table)}${recordId != null ? '  #$recordId' : ''}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.access_time, size: 12, color: Colors.grey.shade500),
              const SizedBox(width: 4),
              Text(
                _fmtTime(ts),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              if (user.isNotEmpty) ...[
                const SizedBox(width: 10),
                Icon(Icons.person_outline,
                    size: 12, color: Colors.grey.shade500),
                const SizedBox(width: 3),
                Text(
                  user,
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
        children: [
          if (details.isNotEmpty && !isLoginLogout)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                details,
                style: const TextStyle(fontSize: 11, color: Colors.black54,
                    fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }
}
