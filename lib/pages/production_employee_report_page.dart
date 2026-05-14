// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class ProductionEmployeeReportPage extends StatefulWidget {
  const ProductionEmployeeReportPage({super.key});

  @override
  State<ProductionEmployeeReportPage> createState() =>
      _ProductionEmployeeReportPageState();
}

class _ProductionEmployeeReportPageState
    extends State<ProductionEmployeeReportPage> {
  final DateFormat _df = DateFormat('dd-MM-yyyy');

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _toDate = DateTime.now();

  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  int _loadVersion = 0;
  Timer? _reloadDebounce;

  // 0 = Top All
  int _topLimit = 10;

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

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  int get _fromMs => DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
      .millisecondsSinceEpoch;
  int get _toMsExclusive => DateTime(_toDate.year, _toDate.month, _toDate.day)
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch;

  Future<void> _load({bool showLoader = false}) async {
    final loadVersion = ++_loadVersion;
    final shouldShowLoader = showLoader || _entries.isEmpty;
    if (mounted && shouldShowLoader) setState(() => _loading = true);

    try {
      final entries = await ErpDatabase.instance
          .getProductionEntries(fromMs: _fromMs, toMs: _toMsExclusive);
      if (!mounted || loadVersion != _loadVersion) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || loadVersion != _loadVersion) return;
      setState(() => _loading = false);
      _msg('Unable to load report');
    }
  }

  Future<void> _pickFrom() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      _fromDate = d;
      if (_fromDate.isAfter(_toDate)) _toDate = _fromDate;
    });
    _load(showLoader: _entries.isEmpty);
  }

  Future<void> _pickTo() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      _toDate = d;
      if (_toDate.isBefore(_fromDate)) _fromDate = _toDate;
    });
    _load(showLoader: _entries.isEmpty);
  }

  String _topLabel(int value) => value == 0 ? 'Top All' : 'Top $value';
  String _statusForRank(int rank) => 'Top $rank';

  String _machineNoFromRow(Map<String, dynamic> row) {
    final code = (row['machine_code'] ?? '').toString().trim();
    if (code.isNotEmpty) return code;
    final name = (row['machine_name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    return '';
  }

  List<Map<String, dynamic>> get _employeeTotalsSorted {
    final byEmp = <int, Map<String, dynamic>>{};
    for (final row in _entries) {
      final empId = (row['employee_id'] as num?)?.toInt();
      if (empId == null) continue;
      final curr = byEmp.putIfAbsent(empId, () {
        return {
          'employee_id': empId,
          'employee_name':
              (row['employee_name'] ?? 'Employee #$empId').toString(),
          'unit_name': (row['unit_name'] ?? '').toString(),
          'total_stitch': 0,
          'total_bonus': 0.0,
          'total_incentive': 0.0,
          'total_all_bonus': 0.0,
        };
      });
      curr['total_stitch'] =
          ((curr['total_stitch'] as num?)?.toInt() ?? 0) +
          ((row['stitch'] as num?)?.toInt() ?? 0);
      curr['total_bonus'] =
          ((curr['total_bonus'] as num?)?.toDouble() ?? 0) +
          ((row['bonus'] as num?)?.toDouble() ?? 0);
      curr['total_incentive'] =
          ((curr['total_incentive'] as num?)?.toDouble() ?? 0) +
          ((row['incentive_bonus'] as num?)?.toDouble() ?? 0);
      curr['total_all_bonus'] =
          ((curr['total_all_bonus'] as num?)?.toDouble() ?? 0) +
          ((row['total_bonus'] as num?)?.toDouble() ?? 0);
    }

    final list = byEmp.values.toList();
    list.sort((a, b) {
      final stitchCmp = ((b['total_stitch'] as num?)?.toInt() ?? 0)
          .compareTo((a['total_stitch'] as num?)?.toInt() ?? 0);
      if (stitchCmp != 0) return stitchCmp;
      final totalCmp = ((b['total_all_bonus'] as num?)?.toDouble() ?? 0)
          .compareTo((a['total_all_bonus'] as num?)?.toDouble() ?? 0);
      if (totalCmp != 0) return totalCmp;
      return (a['employee_name'] as String)
          .toLowerCase()
          .compareTo((b['employee_name'] as String).toLowerCase());
    });
    return list;
  }

  List<int> get _topOptions {
    final employeeCount = _employeeTotalsSorted.length;
    if (employeeCount <= 0) return const [0];
    final options = List<int>.generate(employeeCount, (i) => i + 1);
    options.add(0);
    return options;
  }

  List<Map<String, dynamic>> get _selectedTopEmployees {
    final all = _employeeTotalsSorted;
    if (_topLimit <= 0) return all;
    final n = math.min(_topLimit, all.length);
    return all.take(n).toList();
  }

  List<int> get _daysInRange {
    final start = DateTime(_fromDate.year, _fromDate.month, _fromDate.day);
    final end = DateTime(_toDate.year, _toDate.month, _toDate.day);
    final days = <int>[];
    var d = start;
    while (!d.isAfter(end)) {
      days.add(d.millisecondsSinceEpoch);
      d = d.add(const Duration(days: 1));
    }
    return days;
  }

  Map<int, Map<int, Map<String, dynamic>>> get _dailyByEmployee {
    final map = <int, Map<int, Map<String, dynamic>>>{};
    for (final row in _entries) {
      final empId = (row['employee_id'] as num?)?.toInt();
      final rawDate = (row['date'] as num?)?.toInt() ?? 0;
      if (empId == null || rawDate <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(rawDate);
      final dayMs = DateTime(dt.year, dt.month, dt.day).millisecondsSinceEpoch;

      final dayMap = map.putIfAbsent(empId, () => {});
      final curr = dayMap.putIfAbsent(dayMs, () {
        return {
          'stitch': 0,
          'bonus': 0.0,
          'incentive_bonus': 0.0,
          'total_bonus': 0.0,
          'machines': <String>{},
        };
      });

      curr['stitch'] =
          ((curr['stitch'] as num?)?.toInt() ?? 0) +
          ((row['stitch'] as num?)?.toInt() ?? 0);
      curr['bonus'] =
          ((curr['bonus'] as num?)?.toDouble() ?? 0) +
          ((row['bonus'] as num?)?.toDouble() ?? 0);
      curr['incentive_bonus'] =
          ((curr['incentive_bonus'] as num?)?.toDouble() ?? 0) +
          ((row['incentive_bonus'] as num?)?.toDouble() ?? 0);
      curr['total_bonus'] =
          ((curr['total_bonus'] as num?)?.toDouble() ?? 0) +
          ((row['total_bonus'] as num?)?.toDouble() ?? 0);

      final machine = _machineNoFromRow(row);
      if (machine.isNotEmpty) {
        final set = curr['machines'] as Set<String>;
        set.add(machine);
      }
    }
    return map;
  }

  List<Map<String, dynamic>> get _employeeDayRows {
    final selected = _selectedTopEmployees;
    final days = _daysInRange;
    final daily = _dailyByEmployee;

    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < selected.length; i++) {
      final rank = i + 1;
      final emp = selected[i];
      final empId = (emp['employee_id'] as num?)?.toInt();
      if (empId == null) continue;

      for (var dayIndex = 0; dayIndex < days.length; dayIndex++) {
        final dayMs = days[dayIndex];
        final d = daily[empId]?[dayMs];
        out.add({
          'rank': rank,
          'show_rank': dayIndex == 0,
          'status': _statusForRank(rank),
          'date_ms': dayMs,
          'unit_name': (emp['unit_name'] ?? '').toString(),
          'employee_name': (emp['employee_name'] ?? '').toString(),
          'machine_no':
              d == null
                  ? '-'
                  : ((d['machines'] as Set<String>).isEmpty
                      ? '-'
                      : (((d['machines'] as Set<String>).toList()..sort())
                          .join(', '))),
          'stitch': (d?['stitch'] as num?)?.toInt() ?? 0,
          'bonus': (d?['bonus'] as num?)?.toDouble() ?? 0,
          'incentive_bonus': (d?['incentive_bonus'] as num?)?.toDouble() ?? 0,
          'total_bonus': (d?['total_bonus'] as num?)?.toDouble() ?? 0,
        });
      }
    }
    return out;
  }

  int get _selectedTotalStitch {
    var total = 0;
    for (final e in _employeeDayRows) {
      total += (e['stitch'] as num?)?.toInt() ?? 0;
    }
    return total;
  }

  double get _selectedTotalBonus {
    var total = 0.0;
    for (final e in _employeeDayRows) {
      total += (e['total_bonus'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  Future<void> _exportPdf() async {
    final rows = _employeeDayRows;
    if (rows.isEmpty) {
      _msg('No data to export');
      return;
    }

    final doc = pw.Document();
    final hStyle = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10);
    const cellStyle = pw.TextStyle(fontSize: 9);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.Text(
              'Production Employee Day-wise Report',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'From ${_df.format(_fromDate)} to ${_df.format(_toDate)}  |  Showing: ${_topLabel(_topLimit)}',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Employees: ${_selectedTopEmployees.length}  |  Rows: ${rows.length}  |  Stitch: $_selectedTotalStitch  |  Total Bonus: Rs ${_selectedTotalBonus.toStringAsFixed(0)}',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 8),
          ];

          final tableRows = <pw.TableRow>[
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                _pdfCell('Sr', hStyle),
                _pdfCell('Rank', hStyle),
                _pdfCell('Status', hStyle),
                _pdfCell('Date', hStyle),
                _pdfCell('Unit', hStyle),
                _pdfCell('Employee', hStyle),
                _pdfCell('Machine No', hStyle),
                _pdfCell('Stitch', hStyle, align: pw.TextAlign.right),
                _pdfCell('Bonus', hStyle, align: pw.TextAlign.right),
                _pdfCell('Incentive', hStyle, align: pw.TextAlign.right),
                _pdfCell('Total Bonus', hStyle, align: pw.TextAlign.right),
              ],
            ),
          ];

          for (var i = 0; i < rows.length; i++) {
            final sr = i + 1;
            final r = rows[i];
            final dayMs = (r['date_ms'] as num?)?.toInt() ?? 0;
            final showRank = r['show_rank'] == true;
            final rank = (r['rank'] as num?)?.toInt() ?? 0;

            tableRows.add(
              pw.TableRow(
                children: [
                  _pdfCell('$sr', cellStyle),
                  _pdfCell(showRank ? '$rank' : '', cellStyle),
                  _pdfCell(showRank ? _statusForRank(rank) : '', cellStyle),
                  _pdfCell(
                    dayMs > 0
                        ? _df.format(DateTime.fromMillisecondsSinceEpoch(dayMs))
                        : '-',
                    cellStyle,
                  ),
                  _pdfCell(
                    (r['unit_name'] ?? '').toString().trim().isEmpty
                        ? '-'
                        : (r['unit_name'] ?? '').toString(),
                    cellStyle,
                  ),
                  _pdfCell((r['employee_name'] ?? '').toString(), cellStyle),
                  _pdfCell((r['machine_no'] ?? '-').toString(), cellStyle),
                  _pdfCell(
                    '${(r['stitch'] as num?)?.toInt() ?? 0}',
                    cellStyle,
                    align: pw.TextAlign.right,
                  ),
                  _pdfCell(
                    'Rs ${((r['bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    cellStyle,
                    align: pw.TextAlign.right,
                  ),
                  _pdfCell(
                    'Rs ${((r['incentive_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    cellStyle,
                    align: pw.TextAlign.right,
                  ),
                  _pdfCell(
                    'Rs ${((r['total_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    cellStyle,
                    align: pw.TextAlign.right,
                  ),
                ],
              ),
            );
          }

          widgets.add(
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
              columnWidths: const {
                0: pw.FixedColumnWidth(28),
                1: pw.FixedColumnWidth(28),
                2: pw.FixedColumnWidth(46),
                3: pw.FixedColumnWidth(58),
                4: pw.FlexColumnWidth(0.95),
                5: pw.FlexColumnWidth(1.25),
                6: pw.FlexColumnWidth(1.0),
                7: pw.FixedColumnWidth(50),
                8: pw.FixedColumnWidth(50),
                9: pw.FixedColumnWidth(56),
                10: pw.FixedColumnWidth(60),
              },
              children: tableRows,
            ),
          );

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name:
          'production_employee_report_${DateFormat('yyyyMMdd').format(_fromDate)}_${DateFormat('yyyyMMdd').format(_toDate)}.pdf',
      onLayout: (_) => doc.save(),
    );
  }

  pw.Widget _pdfCell(
    String text,
    pw.TextStyle style, {
    pw.TextAlign align = pw.TextAlign.left,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(text, style: style, textAlign: align),
    );
  }

  Widget _headerCard() {
    final rows = _employeeDayRows;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _pickFrom,
            icon: const Icon(Icons.event, size: 16),
            label: Text('From ${_df.format(_fromDate)}'),
          ),
          OutlinedButton.icon(
            onPressed: _pickTo,
            icon: const Icon(Icons.event_available, size: 16),
            label: Text('To ${_df.format(_toDate)}'),
          ),
          SizedBox(
            width: 130,
            child: DropdownButtonFormField<int>(
              initialValue:
                  _topOptions.contains(_topLimit) ? _topLimit : _topOptions.last,
              decoration: const InputDecoration(
                labelText: 'Show',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _topOptions
                  .map((v) => DropdownMenuItem<int>(
                        value: v,
                        child: Text(_topLabel(v)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => _topLimit = v);
              },
            ),
          ),
          Text(
            'Employees: ${_selectedTopEmployees.length}  |  Rows: ${rows.length}  |  Stitch: $_selectedTotalStitch  |  Total Bonus: Rs ${_selectedTotalBonus.toStringAsFixed(0)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _reportTable() {
    final rows = _employeeDayRows;
    if (rows.isEmpty) {
      return const Center(child: Text('No production data found'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 34,
          dataRowMaxHeight: 42,
          headingRowColor: WidgetStatePropertyAll(Colors.indigo.shade50),
          columns: const [
            DataColumn(label: Text('Sr')),
            DataColumn(label: Text('Rank')),
            DataColumn(label: Text('Status')),
            DataColumn(label: Text('Date')),
            DataColumn(label: Text('Unit')),
            DataColumn(label: Text('Employee')),
            DataColumn(label: Text('Machine No')),
            DataColumn(label: Text('Stitch')),
            DataColumn(label: Text('Bonus')),
            DataColumn(label: Text('Incentive')),
            DataColumn(label: Text('Total Bonus')),
          ],
          rows: List.generate(rows.length, (i) {
            final sr = i + 1;
            final r = rows[i];
            final dayMs = (r['date_ms'] as num?)?.toInt() ?? 0;
            final rank = (r['rank'] as num?)?.toInt() ?? 0;
            final showRank = r['show_rank'] == true;
            return DataRow(cells: [
              DataCell(Text('$sr')),
              DataCell(Text(showRank ? '$rank' : '')),
              DataCell(
                showRank
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _statusForRank(rank),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.green.shade900,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              DataCell(
                Text(
                  dayMs > 0
                      ? _df.format(DateTime.fromMillisecondsSinceEpoch(dayMs))
                      : '-',
                ),
              ),
              DataCell(Text((r['unit_name'] ?? '').toString().isEmpty
                  ? '-'
                  : (r['unit_name'] ?? '').toString())),
              DataCell(Text((r['employee_name'] ?? '').toString())),
              DataCell(Text((r['machine_no'] ?? '-').toString())),
              DataCell(Text('${(r['stitch'] as num?)?.toInt() ?? 0}')),
              DataCell(Text(
                  'Rs ${((r['bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}')),
              DataCell(Text(
                  'Rs ${((r['incentive_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}')),
              DataCell(Text(
                  'Rs ${((r['total_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}')),
            ]);
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Production Employee Report'),
        actions: [
          IconButton(
            onPressed: _exportPdf,
            tooltip: 'Export PDF',
            icon: const Icon(Icons.picture_as_pdf),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _headerCard(),
                Expanded(child: _reportTable()),
              ],
            ),
    );
  }
}
