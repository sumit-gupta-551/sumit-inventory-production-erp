// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';
import '../data/permission_service.dart';

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
  Timer? _reloadDebounce;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _load(showLoader: true);
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _load(showLoader: false),
    );
  }

  void _showAttendanceCard(Map<String, dynamic> row) async {
    final empId = (row['employee_id'] as num?)?.toInt();
    if (empId == null) return;

    final name = (row['employee_name'] ?? '') as String;
    final designation = (row['designation'] as String?) ?? '';
    final unitName = (row['unit_name'] as String?) ?? '';

    final from = DateTime(_selectedMonth.year, _selectedMonth.month, 1);
    final to = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
    final daysInMonth = to.subtract(const Duration(days: 1)).day;
    final monthLabel = DateFormat('MMMM yyyy').format(_selectedMonth);

    final rows = await ErpDatabase.instance.getAttendance(
      fromMs: from.millisecondsSinceEpoch,
      toMs: to.millisecondsSinceEpoch,
      employeeId: empId,
    );

    if (!mounted) return;

    // Build a map of day -> status for quick lookup
    // and compute counts from actual data
    final dayStatus = <int, String>{};
    final dayShift = <int, String>{};
    int present = 0;
    int absent = 0;
    int half = 0;
    int double_ = 0;
    for (final r in rows) {
      final dateMs = (r['date'] as num?)?.toInt() ?? 0;
      final dt = DateTime.fromMillisecondsSinceEpoch(dateMs);
      final status = (r['status'] as String?) ?? 'present';
      dayStatus[dt.day] = status;
      dayShift[dt.day] = (r['shift'] as String?) ?? '';
      switch (status) {
        case 'present':
          present++;
          break;
        case 'absent':
          absent++;
          break;
        case 'half_day':
          half++;
          break;
        case 'double':
          double_++;
          break;
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (_, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
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
                                          .where((s) => s.isNotEmpty)
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
                        const SizedBox(height: 14),
                        Text(monthLabel,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.7))),
                        const SizedBox(height: 8),
                        // Summary row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _cardStat(
                                'Present', present, const Color(0xFF81C784)),
                            _cardStat(
                                'Absent', absent, const Color(0xFFEF9A9A)),
                            _cardStat('Half', half, const Color(0xFFFFCC80)),
                            _cardStat(
                                'Double', double_, const Color(0xFFCE93D8)),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Calendar grid header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children:
                          ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
                              .map((d) => Expanded(
                                    child: Center(
                                      child: Text(d,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF757575))),
                                    ),
                                  ))
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Calendar grid
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: _buildCalendarGrid(
                          from, daysInMonth, dayStatus, dayShift),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _cardStat(String label, int count, Color color) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                fontSize: 10, color: Colors.white.withValues(alpha: 0.7))),
      ],
    );
  }

  List<Widget> _buildCalendarGrid(DateTime monthStart, int daysInMonth,
      Map<int, String> dayStatus, Map<int, String> dayShift) {
    final firstWeekday = monthStart.weekday % 7; // 0=Sun
    final cells = <Widget>[];

    // Leading empty cells
    for (var i = 0; i < firstWeekday; i++) {
      cells.add(const SizedBox());
    }

    for (var day = 1; day <= daysInMonth; day++) {
      final status = dayStatus[day];
      final shift = dayShift[day] ?? '';

      Color bgColor;
      Color textColor;
      String shortLabel;
      IconData? icon;

      if (status == null) {
        // No record
        bgColor = const Color(0xFFF5F5F5);
        textColor = const Color(0xFFBDBDBD);
        shortLabel = '';
      } else {
        switch (status) {
          case 'present':
            bgColor = const Color(0xFFE8F5E9);
            textColor = const Color(0xFF2E7D32);
            shortLabel = 'P';
            icon = Icons.check_circle_outline;
            break;
          case 'absent':
            bgColor = const Color(0xFFFFEBEE);
            textColor = const Color(0xFFC62828);
            shortLabel = 'A';
            icon = Icons.cancel_outlined;
            break;
          case 'half_day':
            bgColor = const Color(0xFFFFF3E0);
            textColor = const Color(0xFFE65100);
            shortLabel = 'H';
            icon = Icons.timelapse;
            break;
          case 'double':
            bgColor = const Color(0xFFF3E5F5);
            textColor = const Color(0xFF6A1B9A);
            shortLabel = 'D';
            icon = Icons.add_circle_outline;
            break;
          default:
            bgColor = const Color(0xFFF5F5F5);
            textColor = const Color(0xFF757575);
            shortLabel = status[0].toUpperCase();
        }
      }

      cells.add(
        Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: status != null
                ? Border.all(color: textColor.withValues(alpha: 0.3))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$day',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: status != null
                          ? textColor
                          : const Color(0xFFBDBDBD))),
              if (icon != null) Icon(icon, size: 14, color: textColor),
              if (status != null)
                Text(shortLabel,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: textColor)),
              if (shift.isNotEmpty)
                Text(shift == 'night' ? 'N' : 'D',
                    style: TextStyle(
                        fontSize: 8, color: textColor.withValues(alpha: 0.6))),
            ],
          ),
        ),
      );
    }

    // Build rows of 7
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      final rowCells = <Widget>[];
      for (var j = 0; j < 7; j++) {
        if (i + j < cells.length) {
          rowCells.add(Expanded(child: cells[i + j]));
        } else {
          rowCells.add(const Expanded(child: SizedBox()));
        }
      }
      rows.add(
        SizedBox(
          height: 64,
          child: Row(children: rowCells),
        ),
      );
    }

    // Legend
    rows.add(const SizedBox(height: 16));
    rows.add(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            _legendItem(const Color(0xFF2E7D32), 'Present'),
            _legendItem(const Color(0xFFC62828), 'Absent'),
            _legendItem(const Color(0xFFE65100), 'Half Day'),
            _legendItem(const Color(0xFF6A1B9A), 'Double'),
            _legendItem(const Color(0xFFBDBDBD), 'No Record'),
          ],
        ),
      ),
    );
    rows.add(const SizedBox(height: 20));

    return rows;
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: color, width: 1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }

  Future<void> _load({bool showLoader = false}) async {
    final loadVersion = ++_loadVersion;
    final shouldShowLoader = showLoader || _data.isEmpty;
    if (mounted && shouldShowLoader) setState(() => _loading = true);

    final from = DateTime(_selectedMonth.year, _selectedMonth.month, 1);
    final to = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
    final fromMs = from.millisecondsSinceEpoch;
    final toMs = to.millisecondsSinceEpoch;

    final rows = await ErpDatabase.instance.getAttendanceReport(
      fromMs: fromMs,
      toMs: toMs,
    );

    // Restrict report rows to units the current user is allowed to see
    // in Attendance (mirrors the per-user unit access on the Attendance page).
    final allowed = PermissionService.instance.allowedAttendanceUnits;
    final filtered = allowed == null
        ? rows
        : rows
            .where((r) => allowed.contains((r['unit_name'] ?? '').toString()))
            .toList();

    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      _data = filtered;
      _loading = false;
    });
  }

  Future<void> _reloadForFilters() async {
    await _load(showLoader: _data.isEmpty);
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
      setState(() {
        _selectedMonth = DateTime(picked.year, picked.month);
        _data = [];
      });
      _reloadForFilters();
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
                    color: const Color(0xFFFFFFFF),
                    border: Border(
                      bottom: BorderSide(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.15),
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
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFF1565C0)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.calendar_month,
                                  size: 18, color: Color(0xFF1565C0)),
                              const SizedBox(width: 8),
                              Text(
                                monthLabel,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1565C0),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_drop_down,
                                  color: Color(0xFF1565C0)),
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
                                  color: Color(0xFF757575), fontSize: 13)),
                          const SizedBox(width: 10),
                          _groupChip('Unit', 'unit'),
                          const SizedBox(width: 8),
                          _groupChip('Designation', 'designation'),
                          const Spacer(),
                          // Employee count
                          Text(
                            '${_data.length} employees',
                            style: const TextStyle(
                                color: Color(0xFF757575), fontSize: 12),
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
                  color: const Color(0xFFFFFFFF),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _summaryChip('P', _totalPresent, const Color(0xFF4CAF50)),
                      _summaryChip('A', _totalAbsent, const Color(0xFFE53935)),
                      _summaryChip('H', _totalHalf, const Color(0xFFFFB74D)),
                      _summaryChip('D', _totalDouble, const Color(0xFF673AB7)),
                    ],
                  ),
                ),

                // Grouped list
                Expanded(
                  child: _data.isEmpty
                      ? const Center(
                          child: Text(
                            'No attendance data for this month',
                            style: TextStyle(color: Color(0xFF757575)),
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
          color: selected ? const Color(0xFF1565C0) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color:
                const Color(0xFF1565C0).withValues(alpha: selected ? 1 : 0.3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? const Color(0xFFF5F5F5) : const Color(0xFF1565C0),
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
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: const Color(0xFF1565C0).withValues(alpha: 0.15)),
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
                  const Color(0xFF1565C0).withValues(alpha: 0.12),
                  const Color(0xFF673AB7).withValues(alpha: 0.08),
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
                  color: const Color(0xFF1565C0),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    groupName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF212121),
                    ),
                  ),
                ),
                Text(
                  '${employees.length} emp  •  P: $groupPresent',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF4CAF50),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // Table header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: const Color(0xFFF5F5F5).withValues(alpha: 0.5),
            child: const Row(
              children: [
                SizedBox(
                    width: 30,
                    child: Text('#',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF757575)))),
                Expanded(
                    flex: 3,
                    child: Text('Employee',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF757575)))),
                SizedBox(
                    width: 36,
                    child: Text('P',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF4CAF50)))),
                SizedBox(
                    width: 36,
                    child: Text('A',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE53935)))),
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
                            color: Color(0xFF673AB7)))),
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

            return InkWell(
              onTap: () => _showAttendanceCard(row),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.06),
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
                            fontSize: 12, color: Color(0xFF757575)),
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
                                color: Color(0xFF212121)),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              style: const TextStyle(
                                  fontSize: 10, color: Color(0xFF757575)),
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
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFF757575),
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
                              ? const Color(0xFFE53935)
                              : const Color(0xFF757575),
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
                              : const Color(0xFF757575),
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
                              ? const Color(0xFF673AB7)
                              : const Color(0xFF757575),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
