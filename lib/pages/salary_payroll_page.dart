// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:month_picker_dialog/month_picker_dialog.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class SalaryPayrollPage extends StatefulWidget {
  const SalaryPayrollPage({super.key});

  @override
  State<SalaryPayrollPage> createState() => _SalaryPayrollPageState();
}

class _SalaryPayrollPageState extends State<SalaryPayrollPage> {
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  final DateFormat _monthFmt = DateFormat('MMM yyyy');
  List<Map<String, dynamic>> employees = [];
  Map<int, Map<String, dynamic>> salaryData = {}; // empId -> salary summary
  Map<int, double> paidByEmployee = {}; // empId -> total paid in selected month
  bool loading = true;
  bool _payrollSaved = false; // whether payroll is saved for current period
  bool _loadInProgress = false;
  static const _paymentModes = ['cash', 'transfer', 'neft'];
  static const _paymentModeLabels = {
    'cash': 'Cash',
    'transfer': 'Transfer',
    'neft': 'NEFT',
  };
  static const _paymentModeIcons = {
    'cash': Icons.money,
    'transfer': Icons.swap_horiz,
    'neft': Icons.account_balance,
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
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    if (_loadInProgress) return;
    _loadInProgress = true;
    if (employees.isEmpty) setState(() => loading = true);
    try {
      final fromMs = _fromMs;
      final toMs = _toMsExclusive;

      // Single bulk query instead of N+1
      final data = await ErpDatabase.instance.getAllEmployeeSalarySummaries(
        fromMs: fromMs,
        toMs: toMs,
      );

      final empList = await ErpDatabase.instance.getEmployees(status: 'active');
      final paymentRows = await ErpDatabase.instance.getSalaryPayments(
        salaryMonthMs: fromMs,
      );
      final paidMap = <int, double>{};
      for (final row in paymentRows) {
        final empId = (row['employee_id'] as num?)?.toInt();
        if (empId == null) continue;
        final amount = (row['amount'] as num?)?.toDouble() ?? 0;
        paidMap[empId] = (paidMap[empId] ?? 0) + amount;
      }

      if (!mounted) return;
      setState(() {
        employees = empList;
        salaryData = data;
        paidByEmployee = paidMap;
        loading = false;
      });

      // Check if payroll already saved for this period
      final saved = await ErpDatabase.instance.isPayrollSaved(_fromMs, _toMs);
      if (mounted) setState(() => _payrollSaved = saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error loading payroll: $e');
    } finally {
      _loadInProgress = false;
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _pickMonth() async {
    final picked = await showMonthPicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _selectedMonth = DateTime(picked.year, picked.month));
      _load();
    }
  }

  String _dateLabel() => _monthFmt.format(_selectedMonth);

  DateTime get _monthStart =>
      DateTime(_selectedMonth.year, _selectedMonth.month, 1);
  DateTime get _nextMonthStart =>
      DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
  int get _fromMs => _monthStart.millisecondsSinceEpoch;
  int get _toMs =>
      _nextMonthStart.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
  int get _toMsExclusive => _nextMonthStart.millisecondsSinceEpoch;

  /// Save payroll for a single employee
  Future<void> _saveOnePayroll(Map<String, dynamic> emp) async {
    final empId = emp['id'] as int;
    final s = salaryData[empId];
    if (s == null) return;

    final data = {
      'employee_id': empId,
      'from_date': _fromMs,
      'to_date': _toMs,
      'base_pay': s['base_pay'],
      'salary_type': s['salary_type'],
      'salary_base_days': s['salary_base_days'],
      'present_days': s['present_days'],
      'half_days': s['half_days'],
      'absent_days': s['absent_days'],
      'double_days': s['double_days'],
      'effective_days': s['effective_days'],
      'base_salary': s['base_salary'],
      'total_bonus': s['total_bonus'],
      'total_incentive': s['total_incentive'],
      'total_all_bonus': s['total_all_bonus'],
      'total_advance': s['total_advance'],
      'net_salary': s['net_salary'],
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
    await ErpDatabase.instance.insertSavedPayroll(data);
  }

  /// Save all employees' payroll (bulk). Deletes existing records for this period first.
  Future<void> _saveAllPayroll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Payroll?'),
        content: Text(
            'Save payroll for all ${employees.length} employees for ${_dateLabel()}?\n\nThis will overwrite any previously saved payroll for this period.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save All'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // Delete old saved payroll for this period
    await ErpDatabase.instance.deleteSavedPayrollForPeriod(_fromMs, _toMs);

    for (final emp in employees) {
      await _saveOnePayroll(emp);
    }
    _msg('Payroll saved for ${employees.length} employees');
    setState(() => _payrollSaved = true);
  }

  Future<void> _openQuickPayDialog(Map<String, dynamic> emp) async {
    final empId = emp['id'] as int?;
    if (empId == null) return;

    final empName = (emp['name'] ?? '').toString();
    final payable = _employeePayable(empId);
    final alreadyPaid = _employeePaid(empId);
    final due = payable - alreadyPaid;
    final suggestedAmount = due > 0 ? due : 0;

    final amountCtrl = TextEditingController(
      text: suggestedAmount > 0 ? suggestedAmount.toStringAsFixed(0) : '',
    );
    final remarksCtrl = TextEditingController();
    String paymentMode = _paymentModes.first;
    DateTime payDate = DateTime.now();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: Text('Pay Salary - $empName'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Month: ${_dateLabel()}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('Payable: ₹${payable.toStringAsFixed(0)}'),
                      Text('Already Paid: ₹${alreadyPaid.toStringAsFixed(0)}'),
                      Text(
                        'Due: ₹${(due > 0 ? due : 0).toStringAsFixed(0)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color:
                              due > 0 ? Colors.deepOrange.shade700 : Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
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
                  initialValue: paymentMode,
                  decoration: const InputDecoration(
                    labelText: 'Payment Mode',
                    border: OutlineInputBorder(),
                  ),
                  items: _paymentModes
                      .map((m) => DropdownMenuItem<String>(
                            value: m,
                            child: Row(
                              children: [
                                Icon(_paymentModeIcons[m], size: 18),
                                const SizedBox(width: 8),
                                Text(_paymentModeLabels[m] ?? m),
                              ],
                            ),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setDState(() => paymentMode = v);
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: payDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked == null) return;
                    setDState(() => payDate = picked);
                  },
                  icon: const Icon(Icons.calendar_month, size: 16),
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
              child: const Text('Pay Now'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      _msg('Enter a valid amount');
      return;
    }

    final data = {
      'employee_id': empId,
      'amount': amount,
      'payment_mode': paymentMode,
      'date': DateTime(payDate.year, payDate.month, payDate.day)
          .millisecondsSinceEpoch,
      'from_date': _fromMs,
      'to_date': _toMs,
      'remarks': remarksCtrl.text.trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };

    await ErpDatabase.instance.insertSalaryPayment(data);
    _msg('Payment recorded for $empName');
    _load();
  }

  void _showDetail(Map<String, dynamic> emp) {
    final empId = emp['id'] as int;
    final s = salaryData[empId];
    if (s == null) return;

    final name = (emp['name'] ?? '').toString();
    final designation = (emp['designation'] as String?) ?? '';
    final unitName = (emp['unit_name'] as String?) ?? '';

    final basePay = (s['base_pay'] as num?)?.toDouble() ?? 0;
    final salaryType = (s['salary_type'] ?? 'monthly').toString();
    final present = (s['present_days'] as num?)?.toInt() ?? 0;
    final absent = (s['absent_days'] as num?)?.toInt() ?? 0;
    final half = (s['half_days'] as num?)?.toInt() ?? 0;
    final double_ = (s['double_days'] as num?)?.toInt() ?? 0;
    final nightShifts = (s['night_shifts'] as num?)?.toInt() ?? 0;
    final effectiveDays = (s['effective_days'] as num?)?.toDouble() ?? 0;
    final totalBonus = (s['total_bonus'] as num?)?.toDouble() ?? 0;
    final totalIncentive = (s['total_incentive'] as num?)?.toDouble() ?? 0;
    final baseSalary = (s['base_salary'] as num?)?.toDouble() ?? 0;
    final totalAdvance = (s['total_advance'] as num?)?.toDouble() ?? 0;
    final netSalary = (s['net_salary'] as num?)?.toDouble() ?? 0;
    final totalStitch = (s['total_stitch'] as num?)?.toInt() ?? 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Employee header card
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1565C0), Color(0xFF1976D2)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.2),
                            radius: 22,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name,
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white)),
                                if (designation.isNotEmpty ||
                                    unitName.isNotEmpty)
                                  Text(
                                    [designation, unitName]
                                        .where((x) => x.isNotEmpty)
                                        .join(' • '),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white
                                            .withValues(alpha: 0.8)),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${_dateLabel()}  •  ${salaryType == 'monthly' ? 'Monthly' : 'Daily'}',
                        style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 10),
                      // Attendance summary badges
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _statBadge('Present', present, const Color(0xFF81C784)),
                          _statBadge('Absent', absent, const Color(0xFFEF9A9A)),
                          _statBadge('Half', half, const Color(0xFFFFCC80)),
                          _statBadge('Double', double_, const Color(0xFFCE93D8)),
                          _statBadge('Night', nightShifts, const Color(0xFF90CAF9)),
                        ],
                      ),
                    ],
                  ),
                ),

                // Net salary highlight
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color:
                            const Color(0xFF4CAF50).withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Net Payable',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2E7D32))),
                      Text('₹${netSalary.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF2E7D32))),
                    ],
                  ),
                ),

                // Salary breakdown
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.receipt_long,
                              size: 16, color: Color(0xFF757575)),
                          SizedBox(width: 6),
                          Text('Salary Breakdown',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF424242))),
                        ],
                      ),
                      const Divider(height: 16),
                      _detRow(
                          'Base Pay',
                          salaryType == 'monthly'
                              ? '₹${basePay.toStringAsFixed(0)}/mo'
                              : '₹${basePay.toStringAsFixed(0)}/day'),
                      _detRow('Base Days',
                          '${(s['salary_base_days'] as num?)?.toInt() ?? 30}'),
                      _detRow('Effective Days',
                          effectiveDays.toStringAsFixed(1)),
                      const Divider(height: 12),
                      _detRow('Base Salary',
                          '₹${baseSalary.toStringAsFixed(0)}'),
                      if (totalStitch > 0)
                        _detRow('Total Stitch', '$totalStitch'),
                      _detRow('Bonus', '₹${totalBonus.toStringAsFixed(0)}'),
                      _detRow(
                          'Incentive', '₹${totalIncentive.toStringAsFixed(0)}'),
                      if (totalAdvance > 0)
                        _detRow('Advance (−)',
                            '₹${totalAdvance.toStringAsFixed(0)}',
                            bold: true),
                      const Divider(height: 12),
                      _detRow('Net Payable',
                          '₹${netSalary.toStringAsFixed(0)}',
                          bold: true, fontSize: 15),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statBadge(String label, int count, Color color) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800, color: color)),
        ),
        const SizedBox(height: 3),
        Text(label,
            style: TextStyle(
                fontSize: 10, color: Colors.white.withValues(alpha: 0.7))),
      ],
    );
  }

  Widget _detRow(String label, String value,
      {bool bold = false, double fontSize = 14}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  fontSize: fontSize)),
          Text(value,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  fontSize: fontSize)),
        ],
      ),
    );
  }

  double get _grandTotal {
    double total = 0;
    for (final e in employees) {
      final s = salaryData[e['id'] as int];
      total += (s?['net_salary'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  double _employeePayable(int empId) {
    return (salaryData[empId]?['net_salary'] as num?)?.toDouble() ?? 0;
  }

  double _employeePaid(int empId) {
    return paidByEmployee[empId] ?? 0;
  }

  double _employeeRemaining(int empId) {
    final remaining = _employeePayable(empId) - _employeePaid(empId);
    return remaining > 0 ? remaining : 0;
  }

  bool _employeeIsPaid(int empId) {
    return _employeePaid(empId) > 0.5 && _employeeRemaining(empId) <= 0.5;
  }

  // ── PDF Export ──────────────────────────────────────────────

  Future<pw.ThemeData> _pdfTheme() async {
    try {
      final base = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      final italic = await PdfGoogleFonts.notoSansItalic();
      final boldItalic = await PdfGoogleFonts.notoSansBoldItalic();
      return pw.ThemeData.withFont(
          base: base, bold: bold, italic: italic, boldItalic: boldItalic);
    } catch (_) {
      return pw.ThemeData.base();
    }
  }

  Future<void> _exportPdf() async {
    if (employees.isEmpty) {
      _msg('No data to export');
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());

    pw.MemoryImage? logoImage;
    try {
      final logoBytes =
          (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
      logoImage = pw.MemoryImage(logoBytes);
    } catch (_) {}

    final headerStyle =
        pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold);
    const cellStyle = pw.TextStyle(fontSize: 7);
    final boldCell = pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold);
    final unitHeaderStyle =
        pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);

    // Group employees by unit_name, sort within each unit by designation
    final unitMap = <String, List<Map<String, dynamic>>>{};
    for (final emp in employees) {
      final unit = (emp['unit_name'] ?? 'Unassigned').toString();
      unitMap.putIfAbsent(unit, () => []).add(emp);
    }
    final sortedUnits = unitMap.keys.toList()..sort();
    for (final unit in sortedUnits) {
      unitMap[unit]!.sort((a, b) => (a['designation'] ?? '')
          .toString()
          .compareTo((b['designation'] ?? '').toString()));
    }

    final headers = [
      '#',
      'Name',
      'Designation',
      'Salary',
      'Base Day',
      'Present Days',
      'Bonus',
      'Incentive Bonus',
      'Total',
      'Advance Amt',
      'Net Payable',
    ];

    double grandTotal = 0;
    int serial = 0;
    final unitTotals = <String, double>{};

    for (final unit in sortedUnits) {
      final emps = unitMap[unit]!;

      final List<pw.Widget> pageContent = [];

      if (logoImage != null) {
        pageContent
            .add(pw.Center(child: pw.Image(logoImage, width: 60, height: 60)));
        pageContent.add(pw.SizedBox(height: 6));
      }
      pageContent.add(pw.Center(
        child: pw.Text('Salary Payroll — ${_dateLabel()}',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      ));
      pageContent.add(pw.SizedBox(height: 12));

      // Unit header row
      pageContent.add(pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        color: PdfColors.blue50,
        child: pw.Text('Unit: $unit', style: unitHeaderStyle),
      ));

      final rows = <pw.TableRow>[
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: headers
              .map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.all(3),
                    child: pw.Text(h, style: headerStyle),
                  ))
              .toList(),
        ),
      ];

      double unitTotal = 0;
      for (final emp in emps) {
        serial++;
        final s = salaryData[emp['id'] as int];
        if (s == null) continue;
        final baseSal = (s['base_salary'] as num?)?.toDouble() ?? 0;
        final bonus = (s['total_bonus'] as num?)?.toDouble() ?? 0;
        final incentive = (s['total_incentive'] as num?)?.toDouble() ?? 0;
        final total = baseSal + bonus + incentive;
        final advance = (s['total_advance'] as num?)?.toDouble() ?? 0;
        final net = (s['net_salary'] as num?)?.toDouble() ?? 0;
        grandTotal += net;
        unitTotal += net;

        final vals = [
          '$serial',
          (emp['name'] ?? '').toString(),
          (emp['designation'] ?? '').toString(),
          (s['base_pay'] as num?)?.toStringAsFixed(0) ?? '0',
          '${(s['salary_base_days'] as num?)?.toInt() ?? 30}',
          '${(s['present_days'] as num?)?.toInt() ?? 0}',
          bonus.toStringAsFixed(0),
          incentive.toStringAsFixed(0),
          total.toStringAsFixed(0),
          advance.toStringAsFixed(0),
          net.toStringAsFixed(0),
        ];

        rows.add(pw.TableRow(
          children: vals
              .asMap()
              .entries
              .map((e) => pw.Padding(
                    padding: const pw.EdgeInsets.all(3),
                    child: pw.Text(e.value,
                        style: e.key == 10 ? boldCell : cellStyle),
                  ))
              .toList(),
        ));
      }

      // Unit subtotal row
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey100),
        children: [
          pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text('')),
          pw.Padding(
              padding: const pw.EdgeInsets.all(3),
              child: pw.Text('Subtotal ($unit)', style: headerStyle)),
          ...List.generate(
              8,
              (_) => pw.Padding(
                  padding: const pw.EdgeInsets.all(3), child: pw.Text(''))),
          pw.Padding(
              padding: const pw.EdgeInsets.all(3),
              child: pw.Text(unitTotal.toStringAsFixed(0), style: headerStyle)),
        ],
      ));

      pageContent.add(pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(0.6), // #
          1: const pw.FlexColumnWidth(2.5), // Name
          2: const pw.FlexColumnWidth(1.8), // Designation
          3: const pw.FlexColumnWidth(1.3), // Salary
          4: const pw.FlexColumnWidth(1), // Base Day
          5: const pw.FlexColumnWidth(1.2), // Present Days
          6: const pw.FlexColumnWidth(1.2), // Bonus
          7: const pw.FlexColumnWidth(1.3), // Incentive Bonus
          8: const pw.FlexColumnWidth(1.3), // Total
          9: const pw.FlexColumnWidth(1.3), // Advance Amt
          10: const pw.FlexColumnWidth(1.5), // Net Payable
        },
        children: rows,
      ));

      unitTotals[unit] = unitTotal;

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(24),
          build: (ctx) => pageContent,
        ),
      );
    }

    // Grand total summary page — each unit total + grand total
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            if (logoImage != null)
              pw.Center(child: pw.Image(logoImage, width: 60, height: 60)),
            pw.SizedBox(height: 8),
            pw.Center(
              child: pw.Text('Salary Payroll — ${_dateLabel()}',
                  style: pw.TextStyle(
                      fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Text('Grand Total Summary',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 16),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              columnWidths: {
                0: const pw.FlexColumnWidth(1),
                1: const pw.FlexColumnWidth(4),
                2: const pw.FlexColumnWidth(2),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('#',
                            style: pw.TextStyle(
                                fontSize: 10, fontWeight: pw.FontWeight.bold))),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Unit',
                            style: pw.TextStyle(
                                fontSize: 10, fontWeight: pw.FontWeight.bold))),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Total',
                            style: pw.TextStyle(
                                fontSize: 10, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right)),
                  ],
                ),
                ...unitTotals.entries.toList().asMap().entries.map((entry) {
                  final idx = entry.key + 1;
                  final unitName = entry.value.key;
                  final total = entry.value.value;
                  return pw.TableRow(
                    children: [
                      pw.Padding(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text('$idx',
                              style: const pw.TextStyle(fontSize: 9))),
                      pw.Padding(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text(unitName,
                              style: const pw.TextStyle(fontSize: 9))),
                      pw.Padding(
                          padding: const pw.EdgeInsets.all(6),
                          child: pw.Text('\u20b9${total.toStringAsFixed(0)}',
                              style: const pw.TextStyle(fontSize: 9),
                              textAlign: pw.TextAlign.right)),
                    ],
                  );
                }),
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                  children: [
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('')),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('Grand Total',
                            style: pw.TextStyle(
                                fontSize: 11, fontWeight: pw.FontWeight.bold))),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(6),
                        child: pw.Text('\u20b9${grandTotal.toStringAsFixed(0)}',
                            style: pw.TextStyle(
                                fontSize: 11, fontWeight: pw.FontWeight.bold),
                            textAlign: pw.TextAlign.right)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await Printing.layoutPdf(
      name: 'salary_${DateFormat('yyyyMM').format(_selectedMonth)}.pdf',
      onLayout: (_) => doc.save(),
    );
  }

  // ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salary / Payroll'),
        actions: [
          IconButton(
            icon: Icon(_payrollSaved ? Icons.check_circle : Icons.save_rounded,
                color: _payrollSaved ? Colors.green : null),
            tooltip: _payrollSaved ? 'Payroll Saved' : 'Save Payroll',
            onPressed: _saveAllPayroll,
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Export PDF',
            onPressed: _exportPdf,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Month Selector
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

                // Grand Total ──
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: _payrollSaved
                      ? Colors.green.shade50
                      : Colors.indigo.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_payrollSaved)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(Icons.check_circle,
                              size: 16, color: Colors.green),
                        ),
                      Flexible(
                        child: Text(
                          'Total Payroll: ₹${_grandTotal.toStringAsFixed(2)}'
                          '${_payrollSaved ? '  (Saved)' : ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // ── Employee Salary List ──
                Expanded(
                  child: employees.isEmpty
                      ? const Center(child: Text('No employees'))
                      : ListView.builder(
                          itemCount: employees.length,
                          itemBuilder: (_, i) {
                            final emp = employees[i];
                            final empId = emp['id'] as int;
                            final s = salaryData[empId];
                            final net =
                                (s?['net_salary'] as num?)?.toDouble() ?? 0;
                            final baseSal =
                                (s?['base_salary'] as num?)?.toDouble() ?? 0;
                            final bonus =
                                (s?['total_all_bonus'] as num?)?.toDouble() ??
                                    0;
                            final effDays =
                                (s?['effective_days'] as num?)?.toDouble() ?? 0;
                            final paid = _employeePaid(empId);
                            final remaining = _employeeRemaining(empId);
                            final isPaid = _employeeIsPaid(empId);

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: InkWell(
                                onTap: () => _showDetail(emp),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 10, 12, 10),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      CircleAvatar(
                                        child: Text(
                                          (emp['name'] ?? '?')
                                              .toString()
                                              .substring(0, 1)
                                              .toUpperCase(),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    (emp['name'] ?? '')
                                                        .toString(),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: isPaid
                                                        ? Colors.green.shade100
                                                        : Colors
                                                            .orange.shade100,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            10),
                                                  ),
                                                  child: Text(
                                                    isPaid
                                                        ? 'Paid'
                                                        : 'Unpaid',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: isPaid
                                                          ? Colors
                                                              .green.shade800
                                                          : Colors
                                                              .orange.shade800,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Days: ${effDays.toStringAsFixed(1)}  |  Base: \u20b9${baseSal.toStringAsFixed(0)}  |  Bonus: \u20b9${bonus.toStringAsFixed(0)}\nPaid: \u20b9${paid.toStringAsFixed(0)}  |  Due: \u20b9${remaining.toStringAsFixed(0)}',
                                              style:
                                                  const TextStyle(fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(minWidth: 76),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              '\u20b9${net.toStringAsFixed(0)}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                  color: Colors.green),
                                            ),
                                            const SizedBox(height: 4),
                                            SizedBox(
                                              height: 28,
                                              child: FilledButton.tonal(
                                                onPressed: () =>
                                                    _openQuickPayDialog(emp),
                                                style:
                                                    FilledButton.styleFrom(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  tapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 10),
                                                  minimumSize:
                                                      const Size(0, 28),
                                                ),
                                                child: const Text(
                                                  'Pay',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
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

