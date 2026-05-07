// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/erp_database.dart';
import 'package:month_picker_dialog/month_picker_dialog.dart';
import '../data/sync_helper.dart';
import '../data/permission_service.dart';

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  /// Debug: Cleanup duplicate attendance and enforce unique index
  Future<void> _cleanupAttendanceDuplicates() async {
    await ErpDatabase.instance.cleanupDuplicateAttendance();
    await ErpDatabase.instance.ensureAttendanceUniqueIndex();
    _msg(
        'Attendance cleanup done. Duplicates removed and unique index enforced.');
    _load();
  }

  bool _syncingProductionAttendance = false;
  DateTime _selectedDate = DateTime.now();
  List<Map<String, dynamic>> allEmployees = [];
  List<Map<String, dynamic>> units = [];
  Map<int, Map<String, dynamic>> attendance = {}; // empId -> record
  // Local pending changes (not yet saved)
  Map<int, Map<String, dynamic>> _pending =
      {}; // empId -> {status, shift, remarks}
  bool loading = true;
  bool _hasLoadedOnce = false;
  bool _loadingData = false;
  bool _saving = false;
  bool _hasChanges = false;
  String? _selectedUnit; // null = All
  Timer? _reloadDebounce;
  int _editVersion = 0;

  static const statusOptions = ['present', 'absent', 'half_day', 'double'];

  static const statusLabels = {
    'present': 'P',
    'absent': 'A',
    'half_day': 'HD',
    'double': 'D',
  };
  static const statusFullLabels = {
    'present': 'Present',
    'absent': 'Absent',
    'half_day': 'Half Day',
    'double': 'Double',
  };
  static const statusColors = {
    'present': Colors.green,
    'absent': Colors.red,
    'half_day': Colors.orange,
    'double': Colors.blue,
  };

  List<Map<String, dynamic>> get _filteredEmployees {
    final allowed = PermissionService.instance.allowedAttendanceUnits;
    Iterable<Map<String, dynamic>> list = allEmployees;
    if (allowed != null) {
      // Restrict to allowed units only.
      list = list.where(
          (e) => allowed.contains((e['unit_name'] ?? '').toString()));
    }
    if (_selectedUnit != null) {
      list = list
          .where((e) => (e['unit_name'] ?? '').toString() == _selectedUnit);
    }
    return list.toList();
  }

  @override
  void initState() {
    super.initState();
    _autoCleanupAndLoad();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  /// Automatically cleanup duplicates and load attendance
  Future<void> _autoCleanupAndLoad() async {
    if (!mounted) return;
    setState(() => loading = true);
    try {
      await ErpDatabase.instance.cleanupDuplicateAttendance();
      await ErpDatabase.instance.ensureAttendanceUniqueIndex();
      // Only sync new production rows since last processed production id.
      final lastSyncProdId = await SyncHelper.getLastAttendanceSync() ?? 0;
      final maxProdId = await ErpDatabase.instance.getMaxProductionEntryId();
      await ErpDatabase.instance
          .updateAttendanceFromProductionSince(lastSyncProdId);
      await SyncHelper.setLastAttendanceSync(maxProdId);
    } catch (e) {
      debugPrint('Attendance startup sync error: $e');
    }
    await _load(showLoading: true);
  }

  Future<void> _fullMonthSync() async {
    debugPrint('FullMonthSync: Button pressed');
    try {
      final picked =
          await showMonthPicker(context: context, initialDate: DateTime.now());
      debugPrint(
          'FullMonthSync: Picked month: \\${picked?.year}-\\${picked?.month}');
      if (picked == null) return;
      final from = DateTime(picked.year, picked.month, 1);
      final to = DateTime(picked.year, picked.month + 1, 1)
          .subtract(const Duration(milliseconds: 1));
      if (!mounted) return;
      setState(() {
        loading = true;
        _syncingProductionAttendance = true;
      });
      await ErpDatabase.instance
          .updateAttendanceFromProductionSince(null, from: from, to: to);
      final maxProdId = await ErpDatabase.instance.getMaxProductionEntryId();
      await SyncHelper.setLastAttendanceSync(maxProdId);
      if (!mounted) return;
      setState(() {
        loading = false;
        _syncingProductionAttendance = false;
      });
      _msg(
          'Full sync for ${picked.year}-${picked.month.toString().padLeft(2, '0')} complete!');
      await _load();
    } catch (e, st) {
      debugPrint('FullMonthSync: ERROR: $e\n$st');
      if (!mounted) return;
      setState(() {
        loading = false;
        _syncingProductionAttendance = false;
      });
      _msg('Error during month sync: $e');
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted || _syncingProductionAttendance || loading || _saving) return;
    if (_hasChanges || _loadingData) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _load(showLoading: false),
    );
  }

  Future<void> _load({bool showLoading = false}) async {
    if (_syncingProductionAttendance || _loadingData) return;
    final loadEditVersion = _editVersion;
    final shouldKeepPending = !showLoading && _pending.isNotEmpty;
    _loadingData = true;
    final shouldShowLoading = showLoading || !_hasLoadedOnce;
    if (shouldShowLoading && mounted) {
      setState(() => loading = true);
    }
    try {
      final empList = await ErpDatabase.instance.getEmployees(status: 'active');
      final unitList = await ErpDatabase.instance.getUnits();

      final dayStart =
          DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      final dayEnd = dayStart.add(const Duration(days: 1));

      final attRows = await ErpDatabase.instance.getAttendance(
        fromMs: dayStart.millisecondsSinceEpoch,
        toMs: dayEnd.millisecondsSinceEpoch,
      );
      final attMap = <int, Map<String, dynamic>>{};
      for (final r in attRows) {
        final empId = r['employee_id'] as int?;
        if (empId != null) attMap[empId] = r;
      }

      // Always show all active employees, even if no attendance or production
      final combinedEmployees = {for (var e in empList) e['id']: e};

      if (!mounted) return;
      if (_hasChanges && loadEditVersion != _editVersion) {
        return;
      }
      setState(() {
        allEmployees =
            combinedEmployees.values.toList().cast<Map<String, dynamic>>();
        // Restrict the units list to those this user is allowed to see.
        final allowed = PermissionService.instance.allowedAttendanceUnits;
        if (allowed == null) {
          units = unitList;
        } else {
          units = unitList
              .where((u) => allowed.contains((u['name'] ?? '').toString()))
              .toList();
        }
        // If the current unit filter is no longer allowed, reset it.
        if (_selectedUnit != null &&
            !units.any((u) => (u['name'] ?? '').toString() == _selectedUnit)) {
          _selectedUnit = null;
        }
        attendance = attMap;
        if (!shouldKeepPending) {
          _pending = {};
          _hasChanges = false;
        }
        _hasLoadedOnce = true;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error loading attendance: $e');
    } finally {
      _loadingData = false;
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _selectedDate = d);
      _load(showLoading: true);
    }
  }

  void _prevDay() {
    setState(
        () => _selectedDate = _selectedDate.subtract(const Duration(days: 1)));
    _load(showLoading: true);
  }

  void _nextDay() {
    setState(() => _selectedDate = _selectedDate.add(const Duration(days: 1)));
    _load(showLoading: true);
  }

  int get _dateMs =>
      DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)
          .millisecondsSinceEpoch;

  // Get effective value: pending overrides saved DB value
  String _getStatus(int empId) {
    return (_pending[empId]?['status'] ??
            attendance[empId]?['status'] ??
            'absent')
        .toString();
  }

  String _getShift(int empId) {
    return (_pending[empId]?['shift'] ?? attendance[empId]?['shift'] ?? 'day')
        .toString();
  }

  String _getRemarks(int empId) {
    return (_pending[empId]?['remarks'] ?? attendance[empId]?['remarks'] ?? '')
        .toString();
  }

  // Local-only changes (no DB write)
  void _setStatus(int empId, String status) {
    setState(() {
      _editVersion++;
      _pending[empId] = {
        ...(_pending[empId] ?? {}),
        'status': status,
      };
      attendance[empId] = {
        ...attendance[empId] ?? {},
        'employee_id': empId,
        'date': _dateMs,
        'status': status,
      };
      _hasChanges = true;
    });
  }

  void _toggleShift(int empId) {
    final current = _getShift(empId);
    final next = current == 'day' ? 'night' : 'day';
    setState(() {
      _editVersion++;
      _pending[empId] = {
        ...(_pending[empId] ?? {}),
        'shift': next,
      };
      _hasChanges = true;
    });
  }

  void _editRemarks(int empId) async {
    final ctrl = TextEditingController(text: _getRemarks(empId));

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remarks'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: 'Enter remarks...',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK')),
        ],
      ),
    );
    if (saved != true) return;

    setState(() {
      _editVersion++;
      _pending[empId] = {
        ...(_pending[empId] ?? {}),
        'remarks': ctrl.text.trim(),
      };
      _hasChanges = true;
    });
  }

  void _markAll(String status) {
    final emps = _filteredEmployees;
    setState(() {
      _editVersion++;
      for (final emp in emps) {
        final empId = emp['id'] as int;
        _pending[empId] = {
          ...(_pending[empId] ?? {}),
          'status': status,
        };
      }
      _hasChanges = true;
    });
    final label = _selectedUnit != null ? '($_selectedUnit)' : '';
    _msg('All set to ${statusFullLabels[status]} $label — tap Save');
  }

  /// Save all pending changes to DB
  Future<void> _saveAll() async {
    if (_syncingProductionAttendance) {
      _msg('Please wait for sync to finish.');
      return;
    }
    if (!_hasChanges || _pending.isEmpty) return;
    setState(() => _saving = true);

    try {
      for (final entry in _pending.entries) {
        final empId = entry.key;
        final changes = entry.value;
        final existing = attendance[empId];

        final status =
            (changes['status'] ?? existing?['status'] ?? 'absent').toString();
        final shift =
            (changes['shift'] ?? existing?['shift'] ?? 'day').toString();
        final remarks =
            (changes['remarks'] ?? existing?['remarks'] ?? '').toString();

        if (existing != null && existing['id'] != null) {
          await ErpDatabase.instance.updateAttendance(
            {
              'employee_id': empId,
              'date': _dateMs,
              'status': status,
              'shift': shift,
              'remarks': remarks
            },
            existing['id'] as int,
          );
        } else {
          final id = await ErpDatabase.instance.insertAttendance({
            'employee_id': empId,
            'date': _dateMs,
            'status': status,
            'shift': shift,
            'remarks': remarks,
          });
          attendance[empId] = {
            'id': id,
            'employee_id': empId,
            'date': _dateMs,
          };
        }

        // Merge into attendance map
        attendance[empId] = {
          ...attendance[empId] ?? {},
          'status': status,
          'shift': shift,
          'remarks': remarks,
        };
      }

      setState(() {
        _pending = {};
        _hasChanges = false;
        _saving = false;
      });
      _msg('Attendance saved ✓');
    } catch (e) {
      setState(() => _saving = false);
      _msg('Save error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredEmployees;

    // Counts based on filtered employees
    final counts = <String, int>{};
    for (final s in statusOptions) {
      counts[s] = 0;
    }
    for (final e in filtered) {
      final empId = e['id'] as int;
      final st = _getStatus(empId);
      counts[st] = (counts[st] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Full Sync by Month',
            onPressed: _fullMonthSync,
          ),

// ...existing code...

          PopupMenuButton<String>(
            icon: const Icon(Icons.checklist_rounded),
            tooltip: 'Mark All',
            onSelected: (v) => _markAll(v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'present', child: Text('Mark All Present')),
              const PopupMenuItem(
                  value: 'absent', child: Text('Mark All Absent')),
              const PopupMenuItem(
                  value: 'half_day', child: Text('Mark All Half Day')),
            ],
          ),
          // Debug: Cleanup Attendance
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'Cleanup Attendance Duplicates',
            onPressed: _cleanupAttendanceDuplicates,
          ),
        ],
      ),
      body: _syncingProductionAttendance
          ? const Center(
              child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Syncing attendance with production...'),
              ],
            ))
          : loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    // ── Date Navigation ──
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _prevDay,
                            tooltip: 'Previous Day',
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: _pickDate,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: Colors.grey.shade300),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.calendar_today,
                                        size: 18, color: Colors.grey),
                                    const SizedBox(width: 8),
                                    Text(
                                      DateFormat('dd MMM yyyy (EEEE)')
                                          .format(_selectedDate),
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _nextDay,
                            tooltip: 'Next Day',
                          ),
                        ],
                      ),
                    ),

                    // ── Unit Filter ──
                    if (units.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        child: DropdownButtonFormField<String>(
                          value: _selectedUnit,
                          decoration: const InputDecoration(
                            labelText: 'Filter by Unit',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            isDense: true,
                          ),
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('All Units'),
                            ),
                            ...units.map((u) => DropdownMenuItem<String>(
                                  value: u['name'] as String,
                                  child: Text(u['name'] as String),
                                )),
                          ],
                          onChanged: (v) => setState(() => _selectedUnit = v),
                        ),
                      ),
                    const SizedBox(height: 4),

                    // ── Summary Bar ──
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Total: ${filtered.length}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const Spacer(),
                          ...statusOptions.map((s) => Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: statusColors[s],
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '${statusLabels[s]}: ${counts[s]}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: statusColors[s],
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),

                    // ── Employee List ──
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('No employees found'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              padding: const EdgeInsets.only(bottom: 12),
                              itemBuilder: (_, i) {
                                final emp = filtered[i];
                                final empId = emp['id'] as int;
                                final status = _getStatus(empId);
                                final shift = _getShift(empId);
                                final remarks = _getRemarks(empId);
                                final unitName =
                                    (emp['unit_name'] ?? '').toString();
                                final isPending = _pending.containsKey(empId);

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 3),
                                  elevation: isPending ? 2 : 1,
                                  color:
                                      isPending ? Colors.amber.shade50 : null,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: BorderSide(
                                      color: isPending
                                          ? Colors.amber.shade400
                                          : (statusColors[status] ??
                                                  Colors.grey)
                                              .withAlpha(60),
                                      width: isPending ? 1.5 : 1,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // ── Row 1: Name, Unit, Shift ──
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    '${i + 1}. ${emp['name'] ?? ''}',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 14),
                                                  ),
                                                  if ((emp['designation'] ?? '')
                                                          .toString()
                                                          .isNotEmpty ||
                                                      unitName.isNotEmpty)
                                                    Text(
                                                      [
                                                        if ((emp['designation'] ??
                                                                '')
                                                            .toString()
                                                            .isNotEmpty)
                                                          emp['designation'],
                                                        if (unitName.isNotEmpty)
                                                          unitName,
                                                      ].join('  •  '),
                                                      style: TextStyle(
                                                          fontSize: 11,
                                                          color: Colors
                                                              .grey.shade600),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            // Shift toggle
                                            InkWell(
                                              onTap: () => _toggleShift(empId),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: shift == 'night'
                                                      ? Colors.indigo.shade50
                                                      : Colors.teal.shade50,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: shift == 'night'
                                                        ? Colors.indigo.shade200
                                                        : Colors.teal.shade200,
                                                  ),
                                                ),
                                                child: Text(
                                                  shift == 'night'
                                                      ? '🌙 Night'
                                                      : '☀ Day',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: shift == 'night'
                                                        ? Colors.indigo
                                                        : Colors.teal,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            // Remarks button
                                            IconButton(
                                              icon: Icon(
                                                remarks.isNotEmpty
                                                    ? Icons.sticky_note_2
                                                    : Icons
                                                        .sticky_note_2_outlined,
                                                size: 20,
                                                color: remarks.isNotEmpty
                                                    ? Colors.amber.shade700
                                                    : Colors.grey,
                                              ),
                                              tooltip: 'Remarks',
                                              onPressed: () =>
                                                  _editRemarks(empId),
                                              constraints:
                                                  const BoxConstraints(),
                                              padding: const EdgeInsets.all(6),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),

                                        // ── Row 2: Status Chips ──
                                        Row(
                                          children: statusOptions.map((s) {
                                            final isActive = status == s;
                                            return Expanded(
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 2),
                                                child: GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onDoubleTap: () =>
                                                      _setStatus(empId, s),
                                                  child: Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: isActive
                                                          ? (statusColors[s] ??
                                                              Colors.grey)
                                                          : (statusColors[s] ??
                                                                  Colors.grey)
                                                              .withAlpha(20),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      border: Border.all(
                                                        color:
                                                            (statusColors[s] ??
                                                                    Colors.grey)
                                                                .withAlpha(
                                                                    isActive
                                                                        ? 255
                                                                        : 60),
                                                      ),
                                                    ),
                                                    child: Center(
                                                      child: Text(
                                                        statusLabels[s] ?? s,
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: isActive
                                                              ? Colors.white
                                                              : (statusColors[
                                                                      s] ??
                                                                  Colors.grey),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),

                                        // ── Remarks text ──
                                        if (remarks.isNotEmpty)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 4),
                                            child: Text(
                                              remarks,
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  fontStyle: FontStyle.italic,
                                                  color: Colors.grey.shade600),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),

                    // ── Save Button ──
                    if (_hasChanges)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(20),
                              blurRadius: 8,
                              offset: const Offset(0, -2),
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _saving ? null : _saveAll,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.save),
                          label: Text(
                            _saving
                                ? 'Saving...'
                                : 'Save Attendance (${_pending.length} changed)',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
