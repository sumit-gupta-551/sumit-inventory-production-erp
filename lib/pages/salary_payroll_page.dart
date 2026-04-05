// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
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
  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _toDate = DateTime(DateTime.now().year, DateTime.now().month + 1)
      .subtract(const Duration(days: 1));
  List<Map<String, dynamic>> employees = [];
  Map<int, Map<String, dynamic>> salaryData = {}; // empId -> salary summary
  bool loading = true;
  bool _payrollSaved = false; // whether payroll is saved for current period

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final fromMs = DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
          .millisecondsSinceEpoch;
      final toMs = DateTime(_toDate.year, _toDate.month, _toDate.day)
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;

      // Single bulk query instead of N+1
      final data = await ErpDatabase.instance.getAllEmployeeSalarySummaries(
        fromMs: fromMs,
        toMs: toMs,
      );

      final empList = await ErpDatabase.instance.getEmployees(status: 'active');

      if (!mounted) return;
      setState(() {
        employees = empList;
        salaryData = data;
        loading = false;
      });

      // Check if payroll already saved for this period
      final fMs = DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
          .millisecondsSinceEpoch;
      final tMs = DateTime(_toDate.year, _toDate.month, _toDate.day)
          .millisecondsSinceEpoch;
      final saved = await ErpDatabase.instance.isPayrollSaved(fMs, tMs);
      if (mounted) setState(() => _payrollSaved = saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error loading payroll: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _fromDate = picked);
      _load();
    }
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _toDate = picked);
      _load();
    }
  }

  String _dateLabel() =>
      '${DateFormat('dd MMM yyyy').format(_fromDate)} — ${DateFormat('dd MMM yyyy').format(_toDate)}';

  int get _fromMs => DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
      .millisecondsSinceEpoch;
  int get _toMs =>
      DateTime(_toDate.year, _toDate.month, _toDate.day).millisecondsSinceEpoch;

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

  void _showDetail(Map<String, dynamic> emp) {
    final empId = emp['id'] as int;
    final s = salaryData[empId];
    if (s == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final basePay = (s['base_pay'] as num?)?.toDouble() ?? 0;
        final salaryType = (s['salary_type'] ?? 'monthly').toString();
        final present = (s['present_days'] as num?)?.toInt() ?? 0;
        final halfDays = (s['half_days'] as num?)?.toInt() ?? 0;
        final absent = (s['absent_days'] as num?)?.toInt() ?? 0;
        final doubleDays = (s['double_days'] as num?)?.toInt() ?? 0;
        final effectiveDays = (s['effective_days'] as num?)?.toDouble() ?? 0;
        final totalBonus = (s['total_bonus'] as num?)?.toDouble() ?? 0;
        final totalIncentive = (s['total_incentive'] as num?)?.toDouble() ?? 0;
        final totalAllBonus = (s['total_all_bonus'] as num?)?.toDouble() ?? 0;
        final baseSalary = (s['base_salary'] as num?)?.toDouble() ?? 0;
        final totalAdvance = (s['total_advance'] as num?)?.toDouble() ?? 0;
        final netSalary = (s['net_salary'] as num?)?.toDouble() ?? 0;

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (emp['name'] ?? '').toString(),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Text(
                  '${_dateLabel()}  •  ${salaryType == 'monthly' ? 'Monthly' : 'Daily Wage'}',
                  style: const TextStyle(color: Colors.grey)),
              const Divider(height: 20),
              _detRow(
                  'Base Pay',
                  salaryType == 'monthly'
                      ? '₹${basePay.toStringAsFixed(0)}/month'
                      : '₹${basePay.toStringAsFixed(0)}/day'),
              _detRow('Base Days',
                  '${(s['salary_base_days'] as num?)?.toInt() ?? 30}'),
              _detRow('Present Days', '$present'),
              _detRow('Half Days', '$halfDays'),
              _detRow('Double Days', '$doubleDays'),
              _detRow('Absent Days', '$absent'),
              _detRow('Effective Days', effectiveDays.toStringAsFixed(1)),
              const Divider(),
              _detRow('Base Salary', '₹${baseSalary.toStringAsFixed(2)}'),
              _detRow('Bonus', '₹${totalBonus.toStringAsFixed(2)}'),
              _detRow(
                  'Incentive Bonus', '₹${totalIncentive.toStringAsFixed(2)}'),
              _detRow('Total (Salary + Bonus)',
                  '₹${(baseSalary + totalAllBonus).toStringAsFixed(2)}'),
              const Divider(),
              _detRow('Advance Amount', '₹${totalAdvance.toStringAsFixed(2)}',
                  bold: totalAdvance > 0, fontSize: totalAdvance > 0 ? 15 : 14),
              const Divider(),
              _detRow(
                'Net Payable',
                '₹${netSalary.toStringAsFixed(2)}',
                bold: true,
                fontSize: 16,
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
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
    final cellStyle = const pw.TextStyle(fontSize: 7);
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
      name:
          'salary_${DateFormat('yyyyMMdd').format(_fromDate)}_${DateFormat('yyyyMMdd').format(_toDate)}.pdf',
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
                // ── Date Range Selector ──
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

                // ── Grand Total ──
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

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: ListTile(
                                onTap: () => _showDetail(emp),
                                leading: CircleAvatar(
                                  child: Text(
                                    (emp['name'] ?? '?')
                                        .toString()
                                        .substring(0, 1)
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(
                                  (emp['name'] ?? '').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  'Days: ${effDays.toStringAsFixed(1)}  |  Base: ₹${baseSal.toStringAsFixed(0)}  |  Bonus: ₹${bonus.toStringAsFixed(0)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  '₹${net.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.green),
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
