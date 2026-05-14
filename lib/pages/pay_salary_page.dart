// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:month_picker_dialog/month_picker_dialog.dart';
import 'dart:async';

import '../data/erp_database.dart';

class PaySalaryPage extends StatefulWidget {
  const PaySalaryPage({super.key});

  @override
  State<PaySalaryPage> createState() => _PaySalaryPageState();
}

class _PaySalaryPageState extends State<PaySalaryPage> {
  Timer? _debounceTimer;
  List<Map<String, dynamic>> employees = [];
  List<Map<String, dynamic>> payments = [];
  List<Map<String, dynamic>> employeeStatuses = [];
  bool loading = true;
  bool _unpaidOnlyReport = true;

  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  final DateFormat _monthFmt = DateFormat('MMM yyyy');

  static const paymentModes = ['cash', 'transfer', 'neft'];
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
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onDataChanged() {
    debugPrint('PaySalaryPage: _onDataChanged called (debounced)');
    if (!mounted) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        debugPrint('PaySalaryPage: _load called (debounced)');
        _load();
      }
    });
  }

  Future<void> _load() async {
    debugPrint('PaySalaryPage: _load called');
    setState(() => loading = true);
    try {
      final empList = await ErpDatabase.instance.getEmployees(status: 'active');
      final rows = await ErpDatabase.instance.getSalaryPayments(
        salaryMonthMs: _periodFromMs,
      );
      final summaries = await ErpDatabase.instance.getAllEmployeeSalarySummaries(
        fromMs: _periodFromMs,
        toMs: _periodToMsExclusive,
      );

      final paidByEmp = <int, double>{};
      for (final p in rows) {
        final empId = (p['employee_id'] as num?)?.toInt();
        if (empId == null) continue;
        final amt = (p['amount'] as num?)?.toDouble() ?? 0;
        paidByEmp[empId] = (paidByEmp[empId] ?? 0) + amt;
      }

      final statusRows = <Map<String, dynamic>>[];
      for (final emp in empList) {
        final empId = (emp['id'] as num?)?.toInt();
        if (empId == null) continue;
        final s = summaries[empId];
        final payable = (s?['net_salary'] as num?)?.toDouble() ?? 0;
        final paid = paidByEmp[empId] ?? 0;
        final remaining = payable - paid;
        final isPaid = paid > 0.5 && remaining <= 0.5;
        statusRows.add({
          'employee_id': empId,
          'employee_name': (emp['name'] ?? '').toString(),
          'designation': (emp['designation'] ?? '').toString(),
          'payable': payable,
          'paid': paid,
          'remaining': remaining,
          'is_paid': isPaid,
        });
      }
      statusRows.sort((a, b) {
        final aPaid = a['is_paid'] == true;
        final bPaid = b['is_paid'] == true;
        if (aPaid != bPaid) return aPaid ? 1 : -1;
        return (a['employee_name'] as String)
            .toLowerCase()
            .compareTo((b['employee_name'] as String).toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        employees = empList;
        payments = rows;
        employeeStatuses = statusRows;
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

  DateTime get _monthStart =>
      DateTime(_selectedMonth.year, _selectedMonth.month, 1);
  DateTime get _nextMonthStart =>
      DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
  int get _periodFromMs => _monthStart.millisecondsSinceEpoch;
  int get _periodToMsExclusive => _nextMonthStart.millisecondsSinceEpoch;

  Future<void> _pickMonth() async {
    final d = await showMonthPicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _selectedMonth = DateTime(d.year, d.month));
      _load();
    }
  }

  Future<void> _addPayment({Map<String, dynamic>? existing}) async {
    int? selEmpId = existing != null ? existing['employee_id'] as int? : null;
    final existingFromMonth = (existing?['from_date'] as num?)?.toInt();
    DateTime salaryMonth = existingFromMonth != null && existingFromMonth > 0
        ? DateTime.fromMillisecondsSinceEpoch(existingFromMonth)
        : _selectedMonth;
    final amountCtrl = TextEditingController(
        text: existing != null
            ? (existing['amount'] as num?)?.toStringAsFixed(0) ?? ''
            : '');
    final remarksCtrl =
        TextEditingController(text: (existing?['remarks'] ?? '').toString());
    String paymentMode = (existing?['payment_mode'] ?? 'cash').toString();
    DateTime payDate = existing != null
        ? DateTime.fromMillisecondsSinceEpoch(existing['date'] as int)
        : DateTime.now();

    // Payroll summary for selected employee
    Map<String, dynamic>? empSummary;

    Future<Map<String, dynamic>?> fetchSummary(int empId, DateTime month) async {
      final fromMs = DateTime(month.year, month.month, 1).millisecondsSinceEpoch;
      final toMsExclusive =
          DateTime(month.year, month.month + 1, 1).millisecondsSinceEpoch;
      try {
        // Always use live calculation so latest advances reflect immediately.
        final s = await ErpDatabase.instance.getEmployeeSalarySummary(
          employeeId: empId,
          fromMs: fromMs,
          toMs: toMsExclusive,
        );
        s['_source'] = 'live';

        // Also get total already paid in this period
        final paidRows = await ErpDatabase.instance.getSalaryPayments(
          employeeId: empId,
          salaryMonthMs: fromMs,
        );
        final totalPaid = paidRows.fold<double>(
            0.0, (sum, r) => sum + ((r['amount'] as num?)?.toDouble() ?? 0));
        s['total_paid'] = totalPaid;
        return s;
      } catch (_) {
        return null;
      }
    }

    // Pre-fetch if editing
    if (selEmpId != null) {
      empSummary = await fetchSummary(selEmpId, salaryMonth);
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
              final totalAdvance =
                  (empSummary!['total_advance'] as num?)?.toDouble() ?? 0;
              final totalPaid =
                  (empSummary!['total_paid'] as num?)?.toDouble() ?? 0;
              final baseSalary =
                  (empSummary!['base_salary'] as num?)?.toDouble() ?? 0;
              final totalBonus =
                  (empSummary!['total_all_bonus'] as num?)?.toDouble() ?? 0;
              final remaining = netSalary - totalPaid;
              return Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.bolt, size: 14, color: Colors.blue.shade700),
                      const SizedBox(width: 4),
                      Text('Live Payroll Snapshot',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Colors.blue.shade800)),
                    ]),
                    const SizedBox(height: 4),
                    _summaryRow('Base Salary',
                        '\u20b9${baseSalary.toStringAsFixed(0)}'),
                    _summaryRow(
                        'Bonus', '\u20b9${totalBonus.toStringAsFixed(0)}'),
                    _summaryRow(
                        'Advance', '\u20b9${totalAdvance.toStringAsFixed(0)}',
                        color: Colors.red),
                    const Divider(height: 8),
                    _summaryRow(
                        'Net Payable', '\u20b9${netSalary.toStringAsFixed(0)}',
                        bold: true),
                    _summaryRow(
                        'Already Paid', '\u20b9${totalPaid.toStringAsFixed(0)}',
                        color: Colors.green),
                    const Divider(height: 8),
                    _summaryRow(
                      'Remaining',
                      '\u20b9${remaining.toStringAsFixed(0)}',
                      bold: true,
                      color: remaining > 0 ? Colors.deepOrange : Colors.green,
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              title: Text(
                '${existing == null ? 'Pay Salary' : 'Edit Payment'} (${_monthFmt.format(salaryMonth)})',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selEmpId,
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
                          empSummary = await fetchSummary(v, salaryMonth);
                          // Auto-fill remaining as amount
                          if (existing == null && empSummary != null) {
                            final net = (empSummary!['net_salary'] as num?)
                                    ?.toDouble() ??
                                0;
                            final paid = (empSummary!['total_paid'] as num?)
                                    ?.toDouble() ??
                                0;
                            final rem = net - paid;
                            if (rem > 0) {
                              amountCtrl.text = rem.toStringAsFixed(0);
                            }
                          }
                        } else {
                          empSummary = null;
                        }
                        setDState(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    summaryWidget(),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showMonthPicker(
                          context: ctx,
                          initialDate: salaryMonth,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked == null) return;
                        salaryMonth = DateTime(picked.year, picked.month);
                        if (selEmpId != null) {
                          empSummary =
                              await fetchSummary(selEmpId!, salaryMonth);
                        }
                        setDState(() {});
                      },
                      icon: const Icon(Icons.event_note, size: 16),
                      label:
                          Text('Salary Month: ${_monthFmt.format(salaryMonth)}'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Amount (\u20b9) *',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Current Page Month: ${_monthFmt.format(_selectedMonth)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blueGrey.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Payment mode
                    DropdownButtonFormField<String>(
                      initialValue: paymentMode,
                      decoration: const InputDecoration(
                        labelText: 'Payment Mode',
                        border: OutlineInputBorder(),
                      ),
                      items: paymentModes
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
                        if (v != null) setDState(() => paymentMode = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: payDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) setDState(() => payDate = d);
                      },
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(
                        'Paid Date: ${DateFormat('dd-MM-yyyy').format(payDate)}',
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
      'payment_mode': paymentMode,
      'date': DateTime(payDate.year, payDate.month, payDate.day)
          .millisecondsSinceEpoch,
      'from_date':
          DateTime(salaryMonth.year, salaryMonth.month, 1).millisecondsSinceEpoch,
      'to_date': DateTime(salaryMonth.year, salaryMonth.month + 1, 1)
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch,
      'remarks': remarksCtrl.text.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };

    if (existing == null) {
      await ErpDatabase.instance.insertSalaryPayment(data);
      _msg('Payment recorded');
    } else {
      await ErpDatabase.instance
          .updateSalaryPayment(data, existing['id'] as int);
      _msg('Payment updated');
    }
    setState(() {
      _selectedMonth = DateTime(salaryMonth.year, salaryMonth.month);
    });
    _load();
  }

  Future<void> _deletePayment(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Payment?'),
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
    await ErpDatabase.instance.deleteSalaryPayment(id);
    _msg('Deleted');
    _load();
  }

  double get _totalPaid => payments.fold(
      0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));

  int get _paidEmployeesCount =>
      employeeStatuses.where((e) => e['is_paid'] == true).length;
  int get _unpaidEmployeesCount =>
      employeeStatuses.where((e) => e['is_paid'] != true).length;
  List<Map<String, dynamic>> get _payableReportRows {
    if (_unpaidOnlyReport) {
      return employeeStatuses.where((e) {
        final remaining = (e['remaining'] as num?)?.toDouble() ?? 0;
        return remaining > 0.5;
      }).toList();
    }
    return employeeStatuses;
  }

  double get _payableTotalDue => _payableReportRows.fold(
      0.0, (s, e) => s + ((e['remaining'] as num?)?.toDouble() ?? 0));

  Map<String, double> get _modeWiseTotals {
    final map = <String, double>{};
    for (final p in payments) {
      final mode = (p['payment_mode'] ?? 'cash').toString();
      map[mode] = (map[mode] ?? 0) + ((p['amount'] as num?)?.toDouble() ?? 0);
    }
    return map;
  }

  Widget _summaryRow(String label, String value,
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
    final modeTotals = _modeWiseTotals;
    return Scaffold(
      appBar: AppBar(
        title: Text('Pay Salary - ${_monthFmt.format(_selectedMonth)}'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addPayment(),
        child: const Icon(Icons.add),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Month filter
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: InkWell(
                    onTap: _pickMonth,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Month',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey.shade600)),
                          const SizedBox(height: 2),
                          Text(
                            _monthFmt.format(_selectedMonth),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Totals
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.green.shade50,
                  child: Column(
                    children: [
                      Text(
                        'Total Paid: \u20b9${_totalPaid.toStringAsFixed(0)}  (${payments.length} payments)',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      if (modeTotals.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: modeTotals.entries.map((e) {
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
                                      '${modeLabels[e.key]}: \u20b9${e.value.toStringAsFixed(0)}',
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
                Container(
                  width: double.infinity,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Payable Salary Report (${_monthFmt.format(_selectedMonth)})',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.blue.shade800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Paid $_paidEmployeesCount  |  Unpaid $_unpaidEmployeesCount  |  Due ₹${_payableTotalDue.toStringAsFixed(0)}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.blueGrey.shade700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Unpaid Only'),
                            selected: _unpaidOnlyReport,
                            onSelected: (_) =>
                                setState(() => _unpaidOnlyReport = true),
                          ),
                          ChoiceChip(
                            label: const Text('All Employees'),
                            selected: !_unpaidOnlyReport,
                            onSelected: (_) =>
                                setState(() => _unpaidOnlyReport = false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 170,
                        child: _payableReportRows.isEmpty
                            ? Center(
                                child: Text(
                                  _unpaidOnlyReport
                                      ? 'All employees are fully paid for this month.'
                                      : 'No employees found',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.separated(
                                itemCount: _payableReportRows.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final r = _payableReportRows[i];
                                  final isPaid = r['is_paid'] == true;
                                  final payable =
                                      (r['payable'] as num?)?.toDouble() ?? 0;
                                  final paid =
                                      (r['paid'] as num?)?.toDouble() ?? 0;
                                  final remaining =
                                      (r['remaining'] as num?)?.toDouble() ?? 0;
                                  return ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 2, vertical: 0),
                                    title: Text(
                                      (r['employee_name'] ?? '').toString(),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      'Payable \u20b9${payable.toStringAsFixed(0)}  |  Paid \u20b9${paid.toStringAsFixed(0)}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    trailing: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isPaid
                                                ? Colors.green.shade100
                                                : Colors.red.shade100,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            isPaid ? 'Paid' : 'Unpaid',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              color: isPaid
                                                  ? Colors.green.shade800
                                                  : Colors.red.shade800,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Due \u20b9${remaining > 0 ? remaining.toStringAsFixed(0) : '0'}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: isPaid
                                                ? Colors.green.shade700
                                                : Colors.red.shade700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // List
                Expanded(
                  child: payments.isEmpty
                      ? const Center(child: Text('No payments found'))
                      : ListView.builder(
                          itemCount: payments.length,
                          itemBuilder: (_, i) {
                            final p = payments[i];
                            final amt = (p['amount'] as num?)?.toDouble() ?? 0;
                            final dateMs = p['date'] as int? ?? 0;
                            final date =
                                DateTime.fromMillisecondsSinceEpoch(dateMs);
                            final mode =
                                (p['payment_mode'] ?? 'cash').toString();
                            final remarks = (p['remarks'] ?? '').toString();
                            final salaryMonthMs =
                                (p['from_date'] as num?)?.toInt();
                            final salaryMonthDate = salaryMonthMs != null &&
                                    salaryMonthMs > 0
                                ? DateTime.fromMillisecondsSinceEpoch(
                                    salaryMonthMs)
                                : date;

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 3),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      (modeColors[mode] ?? Colors.grey)
                                          .withAlpha(30),
                                  child: Icon(modeIcons[mode],
                                      color: modeColors[mode], size: 20),
                                ),
                                title: Text(
                                  (p['employee_name'] ?? '').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  'For ${_monthFmt.format(salaryMonthDate)} | Paid ${DateFormat('dd-MM-yyyy').format(date)} | ${modeLabels[mode] ?? mode}'
                                  '${remarks.isNotEmpty ? ' | $remarks' : ''}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '\u20b9${amt.toStringAsFixed(0)}',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: modeColors[mode]),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          size: 18, color: Colors.blue),
                                      onPressed: () => _addPayment(existing: p),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 18, color: Colors.red),
                                      onPressed: () =>
                                          _deletePayment(p['id'] as int),
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
