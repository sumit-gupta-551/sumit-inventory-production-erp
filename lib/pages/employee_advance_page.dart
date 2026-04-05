// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

class EmployeeAdvancePage extends StatefulWidget {
  const EmployeeAdvancePage({super.key});

  @override
  State<EmployeeAdvancePage> createState() => _EmployeeAdvancePageState();
}

class _EmployeeAdvancePageState extends State<EmployeeAdvancePage> {
  List<Map<String, dynamic>> employees = [];
  List<Map<String, dynamic>> advances = [];
  bool loading = true;

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _toDate = DateTime.now();

  static const advanceModes = ['cash', 'transfer', 'neft'];
  static const modeLabels = {
    'cash': 'Cash',
    'transfer': 'Transfer',
    'neft': 'NEFT'
  };
  static const modeIcons = {
    'cash': Icons.money,
    'transfer': Icons.swap_horiz,
    'neft': Icons.account_balance,
  };
  static const modeColors = {
    'cash': Colors.green,
    'transfer': Colors.blue,
    'neft': Colors.purple,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final empList = await ErpDatabase.instance.getEmployees(status: 'active');
      final fromMs = DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
          .millisecondsSinceEpoch;
      final toMs = DateTime(_toDate.year, _toDate.month, _toDate.day)
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
      final rows = await ErpDatabase.instance.getSalaryAdvances(
        fromMs: fromMs,
        toMs: toMs,
      );
      if (!mounted) return;
      setState(() {
        employees = empList;
        advances = rows;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _pickFrom() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _fromDate = d);
      _load();
    }
  }

  Future<void> _pickTo() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _toDate = d);
      _load();
    }
  }

  Future<void> _addAdvance({Map<String, dynamic>? existing}) async {
    int? selEmpId = existing != null ? existing['employee_id'] as int? : null;
    final amountCtrl = TextEditingController(
        text: existing != null
            ? (existing['amount'] as num?)?.toStringAsFixed(0) ?? ''
            : '');
    final remarksCtrl =
        TextEditingController(text: (existing?['remarks'] ?? '').toString());
    String advMode = (existing?['payment_mode'] ?? 'cash').toString();
    DateTime advDate = existing != null
        ? DateTime.fromMillisecondsSinceEpoch(existing['date'] as int)
        : DateTime.now();

    // Payroll summary for selected employee
    Map<String, dynamic>? empSummary;

    Future<Map<String, dynamic>?> fetchSummary(int empId) async {
      final fromMs = DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
          .millisecondsSinceEpoch;
      final toMs = DateTime(_toDate.year, _toDate.month, _toDate.day)
          .millisecondsSinceEpoch;
      try {
        // Try saved payroll first
        final savedRows = await ErpDatabase.instance.getSavedPayroll(
          fromMs: fromMs,
          toMs: toMs,
          employeeId: empId,
        );
        if (savedRows.isNotEmpty) {
          final s = Map<String, dynamic>.from(savedRows.first);
          s['_source'] = 'saved';
          return s;
        }
        // Fallback to live calculation
        final calcToMs = DateTime(_toDate.year, _toDate.month, _toDate.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch;
        final s = await ErpDatabase.instance.getEmployeeSalarySummary(
          employeeId: empId,
          fromMs: fromMs,
          toMs: calcToMs,
        );
        s['_source'] = 'live';
        return s;
      } catch (_) {
        return null;
      }
    }

    // Pre-fetch if editing
    if (selEmpId != null) {
      empSummary = await fetchSummary(selEmpId);
    }

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDState) {
            Widget summaryWidget() {
              if (empSummary == null) return const SizedBox.shrink();
              final netSalary =
                  (empSummary!['net_salary'] as num?)?.toDouble() ?? 0;
              final baseSalary =
                  (empSummary!['base_salary'] as num?)?.toDouble() ?? 0;
              final totalBonus =
                  (empSummary!['total_all_bonus'] as num?)?.toDouble() ?? 0;
              final totalAdvance =
                  (empSummary!['total_advance'] as num?)?.toDouble() ?? 0;
              final isSaved = empSummary!['_source'] == 'saved';
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isSaved ? Colors.green.shade50 : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isSaved
                          ? Colors.green.shade200
                          : Colors.orange.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(isSaved ? Icons.check_circle : Icons.info_outline,
                          size: 14,
                          color: isSaved ? Colors.green : Colors.orange),
                      const SizedBox(width: 4),
                      Text(isSaved ? 'Payroll (Saved)' : 'Payroll (Not Saved)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: isSaved
                                  ? Colors.green.shade800
                                  : Colors.orange.shade800)),
                    ]),
                    const SizedBox(height: 4),
                    _payrollRow(
                        'Base Salary', '₹${baseSalary.toStringAsFixed(0)}'),
                    _payrollRow('Bonus', '₹${totalBonus.toStringAsFixed(0)}'),
                    _payrollRow(
                        'Total Advance', '₹${totalAdvance.toStringAsFixed(0)}',
                        color: Colors.red),
                    const Divider(height: 8),
                    _payrollRow(
                        'Net Payable', '₹${netSalary.toStringAsFixed(0)}',
                        bold: true),
                  ],
                ),
              );
            }

            return AlertDialog(
              title: Text(existing == null ? 'Add Advance' : 'Edit Advance'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      value: selEmpId,
                      decoration: const InputDecoration(
                        labelText: 'Employee *',
                        border: OutlineInputBorder(),
                      ),
                      isExpanded: true,
                      items: employees
                          .map((e) => DropdownMenuItem<int>(
                                value: e['id'] as int,
                                child: Text(
                                    '${e['name']}  (${e['designation'] ?? ''})'),
                              ))
                          .toList(),
                      onChanged: (v) async {
                        selEmpId = v;
                        if (v != null) {
                          empSummary = await fetchSummary(v);
                        } else {
                          empSummary = null;
                        }
                        setDState(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    summaryWidget(),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Amount (₹) *',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: advMode,
                      decoration: const InputDecoration(
                        labelText: 'Mode',
                        border: OutlineInputBorder(),
                      ),
                      items: advanceModes
                          .map((m) => DropdownMenuItem<String>(
                                value: m,
                                child: Row(
                                  children: [
                                    Icon(modeIcons[m],
                                        size: 18, color: modeColors[m]),
                                    const SizedBox(width: 8),
                                    Text(modeLabels[m] ?? m),
                                  ],
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setDState(() => advMode = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: advDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) setDState(() => advDate = d);
                      },
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(
                        'Date: ${DateFormat('dd-MM-yyyy').format(advDate)}',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: remarksCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Remarks',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    if (selEmpId == null) {
      _msg('Select an employee');
      return;
    }
    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      _msg('Enter a valid amount');
      return;
    }

    final data = {
      'employee_id': selEmpId,
      'amount': amount,
      'payment_mode': advMode,
      'date': DateTime(advDate.year, advDate.month, advDate.day)
          .millisecondsSinceEpoch,
      'remarks': remarksCtrl.text.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };

    if (existing == null) {
      await ErpDatabase.instance.insertSalaryAdvance(data);
      _msg('Advance added');
    } else {
      await ErpDatabase.instance
          .updateSalaryAdvance(data, existing['id'] as int);
      _msg('Advance updated');
    }
    _load();
  }

  Future<void> _deleteAdvance(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Advance?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ErpDatabase.instance.deleteSalaryAdvance(id);
    _msg('Deleted');
    _load();
  }

  double get _totalAdvance => advances.fold(
      0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));

  Map<String, double> get _modeWiseTotals {
    final map = <String, double>{};
    for (final a in advances) {
      final mode = (a['payment_mode'] ?? 'cash').toString();
      map[mode] = (map[mode] ?? 0) + ((a['amount'] as num?)?.toDouble() ?? 0);
    }
    return map;
  }

  Widget _payrollRow(String label, String value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee Advance'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addAdvance(),
        child: const Icon(Icons.add),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Date filter
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: _pickFrom,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 10),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('From',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600)),
                                const SizedBox(height: 2),
                                Text(
                                  DateFormat('dd MMM yyyy').format(_fromDate),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward,
                            size: 18, color: Colors.grey),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: _pickTo,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 10),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('To',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600)),
                                const SizedBox(height: 2),
                                Text(
                                  DateFormat('dd MMM yyyy').format(_toDate),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Total
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.red.shade50,
                  child: Column(
                    children: [
                      Text(
                        'Total Advance: ₹${_totalAdvance.toStringAsFixed(0)}  (${advances.length} entries)',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      if (_modeWiseTotals.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: _modeWiseTotals.entries.map((e) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(modeIcons[e.key],
                                        size: 14, color: modeColors[e.key]),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${modeLabels[e.key]}: ₹${e.value.toStringAsFixed(0)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: modeColors[e.key],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // List
                Expanded(
                  child: advances.isEmpty
                      ? const Center(child: Text('No advances found'))
                      : ListView.builder(
                          itemCount: advances.length,
                          itemBuilder: (_, i) {
                            final a = advances[i];
                            final amt = (a['amount'] as num?)?.toDouble() ?? 0;
                            final dateMs = a['date'] as int? ?? 0;
                            final date =
                                DateTime.fromMillisecondsSinceEpoch(dateMs);
                            final remarks = (a['remarks'] ?? '').toString();
                            final mode =
                                (a['payment_mode'] ?? 'cash').toString();

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 3),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      (modeColors[mode] ?? Colors.red)
                                          .withAlpha(30),
                                  child: Icon(
                                      modeIcons[mode] ?? Icons.money_off,
                                      color: modeColors[mode] ?? Colors.red,
                                      size: 20),
                                ),
                                title: Text(
                                  (a['employee_name'] ?? '').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  '${DateFormat('dd-MM-yyyy').format(date)}  •  ${modeLabels[mode] ?? mode}'
                                  '${remarks.isNotEmpty ? '  •  $remarks' : ''}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '₹${amt.toStringAsFixed(0)}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: Colors.red),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          size: 18, color: Colors.blue),
                                      onPressed: () => _addAdvance(existing: a),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 18, color: Colors.red),
                                      onPressed: () =>
                                          _deleteAdvance(a['id'] as int),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
