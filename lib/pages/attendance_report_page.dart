// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class AttendanceReportPage extends StatefulWidget {
  const AttendanceReportPage({super.key});

  @override
  State<AttendanceReportPage> createState() => _AttendanceReportPageState();
}

class _AttendanceReportPageState extends State<AttendanceReportPage> {
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _data = [];
  bool _loading = true;
  String _groupBy = 'unit'; // 'unit' or 'designation'

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final from = DateTime(_selectedMonth.year, _selectedMonth.month, 1);
    final to =
        DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0, 23, 59, 59);
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;

    final rows = await ErpDatabase.instance.getAttendanceReport(
      fromMs: fromMs,
      toMs: toMs,
    );

    if (!mounted) return;
    setState(() {
      _data = rows;
      _loading = false;
    });
  }

  void _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month + 1, 0),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null) {
      _selectedMonth = DateTime(picked.year, picked.month);
      _load();
    }
  }

  Map<String, List<Map<String, dynamic>>> get _grouped {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in _data) {
      final key = _groupBy == 'unit'
          ? (row['unit_name'] as String?) ?? 'No Unit'
          : (row['designation'] as String?) ?? 'No Designation';
      map.putIfAbsent(key, () => []).add(row);
    }
    return map;
  }

  int get _totalPresent =>
      _data.fold(0, (s, r) => s + ((r['present_days'] as num?)?.toInt() ?? 0));
  int get _totalAbsent =>
      _data.fold(0, (s, r) => s + ((r['absent_days'] as num?)?.toInt() ?? 0));
  int get _totalHalf =>
      _data.fold(0, (s, r) => s + ((r['half_days'] as num?)?.toInt() ?? 0));
  int get _totalDouble =>
      _data.fold(0, (s, r) => s + ((r['double_days'] as num?)?.toInt() ?? 0));

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

  Future<void> _generatePdf() async {
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedMonth);
    final doc = pw.Document(theme: await _pdfTheme());
    final grouped = _grouped;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Attendance Report',
                    style: pw.TextStyle(
                        fontSize: 18, fontWeight: pw.FontWeight.bold)),
                pw.Text(monthLabel,
                    style: pw.TextStyle(
                        fontSize: 14, fontWeight: pw.FontWeight.bold)),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Row(
              children: [
                pw.Text(
                    'Grouped by: ${_groupBy == 'unit' ? 'Unit' : 'Designation'}',
                    style: const pw.TextStyle(fontSize: 10)),
                pw.SizedBox(width: 20),
                pw.Text(
                    'Total:  P: $_totalPresent  |  A: $_totalAbsent  |  H: $_totalHalf  |  D: $_totalDouble',
                    style: const pw.TextStyle(fontSize: 10)),
              ],
            ),
            pw.Divider(),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
                'Generated: ${DateFormat('dd-MM-yyyy hh:mm a').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
          ],
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];

          for (final entry in grouped.entries) {
            final groupName = entry.key;
            final employees = entry.value;
            final gPresent = employees.fold<int>(
                0, (s, r) => s + ((r['present_days'] as num?)?.toInt() ?? 0));
            final gAbsent = employees.fold<int>(
                0, (s, r) => s + ((r['absent_days'] as num?)?.toInt() ?? 0));
            final gHalf = employees.fold<int>(
                0, (s, r) => s + ((r['half_days'] as num?)?.toInt() ?? 0));
            final gDouble = employees.fold<int>(
                0, (s, r) => s + ((r['double_days'] as num?)?.toInt() ?? 0));

            // Group header
            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: const pw.BoxDecoration(
                    color: PdfColors.grey200,
                    borderRadius: pw.BorderRadius.all(pw.Radius.circular(4))),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(groupName,
                        style: pw.TextStyle(
                            fontSize: 11, fontWeight: pw.FontWeight.bold)),
                    pw.Text(
                        '${employees.length} emp  |  P:$gPresent  A:$gAbsent  H:$gHalf  D:$gDouble',
                        style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
              ),
            );

            // Table
            final tableData = <List<String>>[
              [
                '#',
                'Employee',
                _groupBy == 'unit' ? 'Designation' : 'Unit',
                'P',
                'A',
                'H',
                'D'
              ],
            ];
            for (var i = 0; i < employees.length; i++) {
              final row = employees[i];
              final subtitle = _groupBy == 'unit'
                  ? (row['designation'] as String?) ?? ''
                  : (row['unit_name'] as String?) ?? '';
              tableData.add([
                '${i + 1}',
                (row['employee_name'] ?? '') as String,
                subtitle,
                '${(row['present_days'] as num?)?.toInt() ?? 0}',
                '${(row['absent_days'] as num?)?.toInt() ?? 0}',
                '${(row['half_days'] as num?)?.toInt() ?? 0}',
                '${(row['double_days'] as num?)?.toInt() ?? 0}',
              ]);
            }

            widgets.add(
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                headerStyle:
                    pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                cellStyle: const pw.TextStyle(fontSize: 9),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColors.grey300),
                cellAlignments: {
                  0: pw.Alignment.center,
                  3: pw.Alignment.center,
                  4: pw.Alignment.center,
                  5: pw.Alignment.center,
                  6: pw.Alignment.center,
                },
                columnWidths: {
                  0: const pw.FixedColumnWidth(24),
                  1: const pw.FlexColumnWidth(3),
                  2: const pw.FlexColumnWidth(2),
                  3: const pw.FixedColumnWidth(28),
                  4: const pw.FixedColumnWidth(28),
                  5: const pw.FixedColumnWidth(28),
                  6: const pw.FixedColumnWidth(28),
                },
                data: tableData,
              ),
            );
          }
          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name:
          'attendance_report_${DateFormat('MMM_yyyy').format(_selectedMonth)}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedMonth);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Report'),
        actions: [
          IconButton(
            tooltip: 'Download PDF',
            onPressed: _data.isEmpty ? null : _generatePdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
          IconButton(
            tooltip: 'Pick Month',
            onPressed: _pickMonth,
            icon: const Icon(Icons.calendar_month),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Month + Group By controls
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF120230),
                    border: Border(
                      bottom: BorderSide(
                        color: const Color(0xFF00F5FF).withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Month selector
                      InkWell(
                        onTap: _pickMonth,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D0221),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFF00F5FF)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.calendar_month,
                                  size: 18, color: Color(0xFF00F5FF)),
                              const SizedBox(width: 8),
                              Text(
                                monthLabel,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF00F5FF),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_drop_down,
                                  color: Color(0xFF00F5FF)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Group By toggle
                      Row(
                        children: [
                          const Text('Group by:',
                              style: TextStyle(
                                  color: Color(0xFF94A3B8), fontSize: 13)),
                          const SizedBox(width: 10),
                          _groupChip('Unit', 'unit'),
                          const SizedBox(width: 8),
                          _groupChip('Designation', 'designation'),
                          const Spacer(),
                          // Employee count
                          Text(
                            '${_data.length} employees',
                            style: const TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Summary bar
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: const Color(0xFF1A043D),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _summaryChip('P', _totalPresent, const Color(0xFF51CF66)),
                      _summaryChip('A', _totalAbsent, const Color(0xFFFF6B6B)),
                      _summaryChip('H', _totalHalf, const Color(0xFFFFB74D)),
                      _summaryChip('D', _totalDouble, const Color(0xFF7B61FF)),
                    ],
                  ),
                ),

                // Grouped list
                Expanded(
                  child: _data.isEmpty
                      ? const Center(
                          child: Text(
                            'No attendance data for this month',
                            style: TextStyle(color: Color(0xFF94A3B8)),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(10),
                          children: _grouped.entries.map((entry) {
                            final groupName = entry.key;
                            final employees = entry.value;
                            final groupPresent = employees.fold<int>(
                                0,
                                (s, r) =>
                                    s +
                                    ((r['present_days'] as num?)?.toInt() ??
                                        0));
                            return _buildGroup(
                                groupName, employees, groupPresent);
                          }).toList(),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _groupChip(String label, String value) {
    final selected = _groupBy == value;
    return GestureDetector(
      onTap: () => setState(() => _groupBy = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00F5FF) : const Color(0xFF0D0221),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color:
                const Color(0xFF00F5FF).withValues(alpha: selected ? 1 : 0.3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? const Color(0xFF0D0221) : const Color(0xFF00F5FF),
          ),
        ),
      ),
    );
  }

  Widget _summaryChip(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: color.withValues(alpha: 0.7),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildGroup(String groupName, List<Map<String, dynamic>> employees,
      int groupPresent) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF120230),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFF00F5FF).withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Group header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00F5FF).withValues(alpha: 0.12),
                  const Color(0xFF7B61FF).withValues(alpha: 0.08),
                ],
              ),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Icon(
                  _groupBy == 'unit' ? Icons.business : Icons.badge,
                  size: 18,
                  color: const Color(0xFF00F5FF),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF8FAFC),
                    ),
                  ),
                ),
                Text(
                  '${employees.length} emp  •  P: $groupPresent',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF51CF66),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: const Color(0xFF0D0221).withValues(alpha: 0.5),
            child: const Row(
              children: [
                SizedBox(
                    width: 30,
                    child: Text('#',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF94A3B8)))),
                Expanded(
                    flex: 3,
                    child: Text('Employee',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF94A3B8)))),
                SizedBox(
                    width: 36,
                    child: Text('P',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF51CF66)))),
                SizedBox(
                    width: 36,
                    child: Text('A',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFF6B6B)))),
                SizedBox(
                    width: 36,
                    child: Text('H',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFFB74D)))),
                SizedBox(
                    width: 36,
                    child: Text('D',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF7B61FF)))),
              ],
            ),
          ),

          // Employee rows
          ...employees.asMap().entries.map((e) {
            final idx = e.key;
            final row = e.value;
            final present = (row['present_days'] as num?)?.toInt() ?? 0;
            final absent = (row['absent_days'] as num?)?.toInt() ?? 0;
            final half = (row['half_days'] as num?)?.toInt() ?? 0;
            final double_ = (row['double_days'] as num?)?.toInt() ?? 0;
            final name = (row['employee_name'] ?? '') as String;
            final subtitle = _groupBy == 'unit'
                ? (row['designation'] as String?) ?? ''
                : (row['unit_name'] as String?) ?? '';

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: const Color(0xFF00F5FF).withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 30,
                    child: Text(
                      '${idx + 1}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF94A3B8)),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFF8FAFC)),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: const TextStyle(
                                fontSize: 10, color: Color(0xFF94A3B8)),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '$present',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: present > 0
                            ? const Color(0xFF51CF66)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '$absent',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: absent > 0
                            ? const Color(0xFFFF6B6B)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '$half',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: half > 0
                            ? const Color(0xFFFFB74D)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '$double_',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: double_ > 0
                            ? const Color(0xFF7B61FF)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
