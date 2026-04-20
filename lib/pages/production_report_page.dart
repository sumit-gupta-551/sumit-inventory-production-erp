// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart';

import '../data/erp_database.dart';

class ProductionReportPage extends StatefulWidget {
  const ProductionReportPage({super.key});

  @override
  State<ProductionReportPage> createState() => _ProductionReportPageState();
}

class _ProductionReportPageState extends State<ProductionReportPage> {
  final _db = ErpDatabase.instance;
  final _df = DateFormat('dd-MM-yyyy');
  final _mf = DateFormat('MMM yyyy');

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _toDate = DateTime.now();

  List<Map<String, dynamic>> _entries = [];

  bool _loading = true;

  // Group-by mode
  String _groupBy = 'date'; // date, employee, unit, month, date_unit_employee

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

  int get _fromMs => DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
      .millisecondsSinceEpoch;
  int get _toMs =>
      DateTime(_toDate.year, _toDate.month, _toDate.day)
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;

  Future<void> _load() async {
    if (_entries.isEmpty) setState(() => _loading = true);
    final entries =
        await _db.getProductionEntries(fromMs: _fromMs, toMs: _toMs);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  // ─── helpers ───
  String _dateStr(int ms) =>
      _df.format(DateTime.fromMillisecondsSinceEpoch(ms));
  String _monthStr(int ms) =>
      _mf.format(DateTime.fromMillisecondsSinceEpoch(ms));

  /// Running days = distinct dates that have at least one entry
  int _runningDays(List<Map<String, dynamic>> rows) {
    final dates = <int>{};
    for (final r in rows) {
      final d = r['date'] as int? ?? 0;
      // normalise to day start
      final dt = DateTime.fromMillisecondsSinceEpoch(d);
      dates.add(DateTime(dt.year, dt.month, dt.day).millisecondsSinceEpoch);
    }
    return dates.length;
  }

  // ─── Grouping logic ───
  Map<String, List<Map<String, dynamic>>> get _grouped {
    if (_groupBy == 'date_unit_employee') {
      // Nested grouping: Date → Unit → Employee
      // We'll flatten keys as 'date||unit' for display
      final map = <String, List<Map<String, dynamic>>>{};
      for (final e in _entries) {
        final date = _dateStr(e['date'] as int? ?? 0);
        final unit = (e['unit_name'] as String?) ?? 'No Unit';
        final key = '$date || $unit';
        map.putIfAbsent(key, () => []).add(e);
      }
      // Sort by date then unit
      final sorted = map.entries.toList();
      sorted.sort((a, b) {
        final da = a.key.split(' || ')[0];
        final db = b.key.split(' || ')[0];
        final ua = a.key.split(' || ')[1];
        final ub = b.key.split(' || ')[1];
        final cmp = _df.parse(da).compareTo(_df.parse(db));
        return cmp != 0 ? cmp : ua.compareTo(ub);
      });
      return Map.fromEntries(sorted);
    } else {
      final map = <String, List<Map<String, dynamic>>>{};
      for (final e in _entries) {
        String key;
        switch (_groupBy) {
          case 'employee':
            key = (e['employee_name'] as String?) ?? 'Unknown';
            break;
          case 'unit':
            key = (e['unit_name'] as String?) ?? 'No Unit';
            break;
          case 'month':
            key = _monthStr(e['date'] as int? ?? 0);
            break;
          default: // date
            key = _dateStr(e['date'] as int? ?? 0);
        }
        map.putIfAbsent(key, () => []).add(e);
      }

      // Sort keys
      final sorted = map.entries.toList();
      if (_groupBy == 'date') {
        sorted.sort((a, b) {
          final da = _df.parse(a.key);
          final db2 = _df.parse(b.key);
          return da.compareTo(db2);
        });
      } else if (_groupBy == 'month') {
        sorted.sort((a, b) {
          final da = _mf.parse(a.key);
          final db2 = _mf.parse(b.key);
          return da.compareTo(db2);
        });
      } else {
        sorted.sort((a, b) => a.key.compareTo(b.key));
      }
      return Map.fromEntries(sorted);
    }
  }

  /// Machine-wise running days for a set of rows
  Map<String, int> _machineRunningDays(List<Map<String, dynamic>> rows) {
    final map = <String, Set<int>>{};
    for (final r in rows) {
      final machine = (r['machine_name'] as String?)?.isNotEmpty == true
          ? r['machine_name'] as String
          : (r['machine_code'] as String?) ?? 'No Machine';
      final d = r['date'] as int? ?? 0;
      final dt = DateTime.fromMillisecondsSinceEpoch(d);
      final dayMs = DateTime(dt.year, dt.month, dt.day).millisecondsSinceEpoch;
      map.putIfAbsent(machine, () => {}).add(dayMs);
    }
    final result = <String, int>{};
    final sorted = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    for (final e in sorted) {
      result[e.key] = e.value.length;
    }
    return result;
  }

  int _totalStitch(List<Map<String, dynamic>> rows) {
    int s = 0;
    for (final r in rows) s += (r['stitch'] as int?) ?? 0;
    return s;
  }

  double _totalBonus(List<Map<String, dynamic>> rows) {
    double b = 0;
    for (final r in rows) b += (r['bonus'] as num?)?.toDouble() ?? 0;
    return b;
  }

  double _totalIncentive(List<Map<String, dynamic>> rows) {
    double b = 0;
    for (final r in rows) b += (r['incentive_bonus'] as num?)?.toDouble() ?? 0;
    return b;
  }

  double _totalAllBonus(List<Map<String, dynamic>> rows) {
    double b = 0;
    for (final r in rows) b += (r['total_bonus'] as num?)?.toDouble() ?? 0;
    return b;
  }

  // ─── Date pickers ───
  Future<void> _pickFrom() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
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
      lastDate: DateTime(2030),
    );
    if (d != null) {
      setState(() => _toDate = d);
      _load();
    }
  }

  // ─── PDF Export ───
  Future<void> _exportPdf() async {
    final doc = pw.Document();
    final font = await PdfGoogleFonts.notoSansRegular();
    final fontBold = await PdfGoogleFonts.notoSansBold();
    final style = pw.TextStyle(font: font, fontSize: 9);
    final hStyle = pw.TextStyle(font: fontBold, fontSize: 10);

    pw.MemoryImage? logoImage;
    try {
      final logoData = await rootBundle.load('assets/logo.png');
      logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
    } catch (_) {}

    String groupByLabel;
    final grouped = _grouped;
    double grandStitch = 0;
    double grandBonus = 0;
    double grandIncentive = 0;
    double grandAllBonus = 0;
    final rows = <pw.TableRow>[];

    if (_groupBy == 'date_unit_employee') {
      groupByLabel = 'Date + Unit + Employee';
      // Header
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          _pdfCell('#', hStyle),
          _pdfCell('Date', hStyle),
          _pdfCell('Unit', hStyle),
          _pdfCell('Employee', hStyle),
          _pdfCell('Machine', hStyle),
          _pdfCell('Stitch', hStyle, align: pw.TextAlign.right),
          _pdfCell('Bonus', hStyle, align: pw.TextAlign.right),
          _pdfCell('Incentive', hStyle, align: pw.TextAlign.right),
          _pdfCell('Total Bonus', hStyle, align: pw.TextAlign.right),
        ],
      ));
      int idx = 0;
      for (final entry in grouped.entries) {
        final parts = entry.key.split(' || ');
        final date = parts[0];
        final unit = parts[1];
        for (final r in entry.value) {
          idx++;
          final stitch = (r['stitch'] as int?) ?? 0;
          final bonus = (r['bonus'] as num?)?.toDouble() ?? 0;
          final incentive = (r['incentive_bonus'] as num?)?.toDouble() ?? 0;
          final allBonus = (r['total_bonus'] as num?)?.toDouble() ?? 0;
          grandStitch += stitch;
          grandBonus += bonus;
          grandIncentive += incentive;
          grandAllBonus += allBonus;
          rows.add(pw.TableRow(children: [
            _pdfCell('$idx', style),
            _pdfCell(date, style),
            _pdfCell(unit, style),
            _pdfCell((r['employee_name'] as String?) ?? '', style),
            _pdfCell((r['machine_name'] as String?) ?? '', style),
            _pdfCell(stitch.toString(), style, align: pw.TextAlign.right),
            _pdfCell('\u20b9${bonus.toStringAsFixed(0)}', style, align: pw.TextAlign.right),
            _pdfCell('\u20b9${incentive.toStringAsFixed(0)}', style, align: pw.TextAlign.right),
            _pdfCell('\u20b9${allBonus.toStringAsFixed(0)}', style, align: pw.TextAlign.right),
          ]));
        }
      }
      // Grand total row
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey100),
        children: [
          _pdfCell('', hStyle),
          _pdfCell('Grand Total', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('', hStyle),
          _pdfCell(grandStitch.toStringAsFixed(0), hStyle, align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandBonus.toStringAsFixed(0)}', hStyle, align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandIncentive.toStringAsFixed(0)}', hStyle, align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandAllBonus.toStringAsFixed(0)}', hStyle, align: pw.TextAlign.right),
        ],
      ));
    } else {
      groupByLabel = {
        'date': 'Date Wise',
        'employee': 'Employee Wise',
        'unit': 'Unit Wise',
        'month': 'Month Wise',
      }[_groupBy]!;
      // ...existing code for other groupings...
      // (original code block for other groupings goes here)
      int idx = 0;
      for (final entry in grouped.entries) {
        idx++;
        final stitch = _totalStitch(entry.value);
        final bonus = _totalBonus(entry.value);
        final incentive = _totalIncentive(entry.value);
        final allBonus = _totalAllBonus(entry.value);
        final days = _runningDays(entry.value);
        grandStitch += stitch;
        grandBonus += bonus;
        grandIncentive += incentive;
        grandAllBonus += allBonus;

        rows.add(pw.TableRow(children: [
          _pdfCell('$idx', style),
          _pdfCell(entry.key, style),
          _pdfCell('$days', style, align: pw.TextAlign.center),
          _pdfCell('${entry.value.length}', style, align: pw.TextAlign.center),
          _pdfCell(stitch.toString(), style, align: pw.TextAlign.right),
          _pdfCell('\u20b9${bonus.toStringAsFixed(0)}', style,
              align: pw.TextAlign.right),
          _pdfCell('\u20b9${incentive.toStringAsFixed(0)}', style,
              align: pw.TextAlign.right),
          _pdfCell('\u20b9${allBonus.toStringAsFixed(0)}', style,
              align: pw.TextAlign.right),
        ]));

        // For unit-wise: add machine running days sub-rows
        if (_groupBy == 'unit') {
          final machDays = _machineRunningDays(entry.value);
          for (final m in machDays.entries) {
            rows.add(pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.blue50),
              children: [
                _pdfCell('', style),
                _pdfCell('   ↳ ${m.key}', style),
                _pdfCell('${m.value}', style, align: pw.TextAlign.center),
                _pdfCell('', style),
                _pdfCell('', style),
                _pdfCell('', style),
                _pdfCell('', style),
                _pdfCell('', style),
              ],
            ));
          }
        }

        // For employee-wise: add date-wise detail sub-rows + employee total
        if (_groupBy == 'employee') {
          final sortedRows = List<Map<String, dynamic>>.from(entry.value)
            ..sort((a, b) =>
                (a['date'] as int? ?? 0).compareTo(b['date'] as int? ?? 0));
          int subIdx = 0;
          for (final r in sortedRows) {
            subIdx++;
            rows.add(pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.amber50),
              children: [
                _pdfCell('', style),
                _pdfCell(
                    '   $subIdx. ${_dateStr(r['date'] as int)} · ${r['unit_name'] ?? ''} · ${r['machine_name'] ?? ''}',
                    style),
                _pdfCell('', style),
                _pdfCell('', style),
                _pdfCell('${(r['stitch'] as int?) ?? 0}', style,
                    align: pw.TextAlign.right),
                _pdfCell(
                    '\u20b9${((r['bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    style,
                    align: pw.TextAlign.right),
                _pdfCell(
                    '\u20b9${((r['incentive_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    style,
                    align: pw.TextAlign.right),
                _pdfCell(
                    '\u20b9${((r['total_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                    style,
                    align: pw.TextAlign.right),
              ],
            ));
          }
          // Employee subtotal
          rows.add(pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey100),
            children: [
              _pdfCell('', hStyle),
              _pdfCell('   Total (${entry.key})', hStyle),
              _pdfCell('$days', hStyle, align: pw.TextAlign.center),
              _pdfCell('${entry.value.length}', hStyle,
                  align: pw.TextAlign.center),
              _pdfCell(stitch.toString(), hStyle, align: pw.TextAlign.right),
              _pdfCell('\u20b9${bonus.toStringAsFixed(0)}', hStyle,
                  align: pw.TextAlign.right),
              _pdfCell('\u20b9${incentive.toStringAsFixed(0)}', hStyle,
                  align: pw.TextAlign.right),
              _pdfCell('\u20b9${allBonus.toStringAsFixed(0)}', hStyle,
                  align: pw.TextAlign.right),
            ],
          ));
        }
      }

      // Grand total row
      rows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey100),
        children: [
          _pdfCell('', hStyle),
          _pdfCell('Grand Total', hStyle),
          _pdfCell('${_runningDays(_entries)}', hStyle,
              align: pw.TextAlign.center),
          _pdfCell('${_entries.length}', hStyle, align: pw.TextAlign.center),
          _pdfCell(grandStitch.toStringAsFixed(0), hStyle,
              align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandBonus.toStringAsFixed(0)}', hStyle,
              align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandIncentive.toStringAsFixed(0)}', hStyle,
              align: pw.TextAlign.right),
          _pdfCell('\u20b9${grandAllBonus.toStringAsFixed(0)}', hStyle,
              align: pw.TextAlign.right),
        ],
      ));
    }

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      header: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (ctx.pageNumber == 1 && logoImage != null) ...[
            pw.Center(child: pw.Image(logoImage, width: 50, height: 50)),
            pw.SizedBox(height: 4),
          ],
          pw.Center(
            child: pw.Text(
                'Production Report — $groupByLabel  (${_df.format(_fromDate)} - ${_df.format(_toDate)})',
                style: pw.TextStyle(font: fontBold, fontSize: 14)),
          ),
          pw.Divider(),
        ],
      ),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ],
      ),
      build: (ctx) => [
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: _groupBy == 'date_unit_employee'
              ? {
                  0: const pw.FlexColumnWidth(0.4),
                  1: const pw.FlexColumnWidth(1.2),
                  2: const pw.FlexColumnWidth(1.2),
                  3: const pw.FlexColumnWidth(1.7),
                  4: const pw.FlexColumnWidth(1.2),
                  5: const pw.FlexColumnWidth(1.0),
                  6: const pw.FlexColumnWidth(1.0),
                  7: const pw.FlexColumnWidth(1.0),
                  8: const pw.FlexColumnWidth(1.0),
                }
              : {
                  0: const pw.FlexColumnWidth(0.4),
                  1: const pw.FlexColumnWidth(2.5),
                  2: const pw.FlexColumnWidth(0.8),
                  3: const pw.FlexColumnWidth(0.7),
                  4: const pw.FlexColumnWidth(1.2),
                  5: const pw.FlexColumnWidth(1.2),
                  6: const pw.FlexColumnWidth(1.2),
                  7: const pw.FlexColumnWidth(1.2),
                },
          children: rows,
        ),
      ],
    ));

    await Printing.layoutPdf(
        onLayout: (format) => doc.save(), name: 'Production_Report.pdf');
  }

  pw.Widget _pdfCell(String text, pw.TextStyle style,
      {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(5),
      child: pw.Text(text, style: style, textAlign: align),
    );
  }

  // ─── BUILD ───
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Production Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_rounded),
            tooltip: 'Export PDF',
            onPressed: _entries.isEmpty ? null : _exportPdf,
          ),
        ],
      ),
      body: Column(
        children: [
          // Date range row
          _buildDateRow(),
          // Group-by chips
          _buildGroupChips(),
          // Summary bar
          _buildSummaryBar(),
          const Divider(height: 1),
          // Grouped list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                    ? const Center(
                        child: Text('No production entries found',
                            style: TextStyle(color: Colors.grey)))
                    : _buildGroupedList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDateRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _pickFrom,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  const Icon(Icons.calendar_today,
                      size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(_df.format(_fromDate),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('to', style: TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: InkWell(
              onTap: _pickTo,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  const Icon(Icons.calendar_today,
                      size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(_df.format(_toDate),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChips() {
    const modes = [
      ('date', 'Date', Icons.calendar_month),
      ('employee', 'Employee', Icons.person),
      ('unit', 'Unit', Icons.business),
      ('month', 'Month', Icons.date_range),
      ('date_unit_employee', 'Date+Unit+Employee', Icons.table_chart),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: modes.map((m) {
            final selected = _groupBy == m.$1;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(m.$3,
                    size: 16,
                    color: selected ? Colors.white : Colors.blue.shade700),
                label: Text(m.$2,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : Colors.blue.shade700)),
                selected: selected,
                selectedColor: Colors.blue.shade700,
                backgroundColor: Colors.blue.shade50,
                onSelected: (_) {
                  setState(() => _groupBy = m.$1);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildSummaryBar() {
    final totalStitch = _totalStitch(_entries);
    final totalBonus = _totalBonus(_entries);
    final totalIncentive = _totalIncentive(_entries);
    final totalAll = _totalAllBonus(_entries);
    final days = _runningDays(_entries);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _statCol('Entries', '${_entries.length}', Colors.indigo),
          _statCol('Days', '$days', Colors.teal),
          _statCol('Stitch', '$totalStitch', Colors.deepPurple),
          _statCol(
              'Bonus', '\u20b9${totalBonus.toStringAsFixed(0)}', Colors.blue),
          _statCol('Incentive', '\u20b9${totalIncentive.toStringAsFixed(0)}',
              Colors.purple),
          _statCol(
              'Total', '\u20b9${totalAll.toStringAsFixed(0)}', Colors.green),
        ],
      ),
    );
  }

  Widget _statCol(String label, String value, Color c) {
    return Column(
      children: [
        Text(value,
            style:
                TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildGroupedList() {
    final grouped = _grouped;
    if (_groupBy == 'date_unit_employee') {
      // Flat table: Date | Unit | Employee | Stitch | Bonus | Incentive | Total Bonus
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: grouped.length,
        itemBuilder: (_, i) {
          final key = grouped.keys.elementAt(i);
          final rows = grouped[key]!;
          final parts = key.split(' || ');
          final date = parts[0];
          final unit = parts[1];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 14),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: Colors.blue.shade100,
                child: Text('${i + 1}',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.blue.shade800,
                        fontSize: 13)),
              ),
              title: Text('$date  •  $unit',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: Text('Entries: ${rows.length}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              children: [
                ...rows.map((r) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text('${r['employee_name'] ?? ''} · ${r['machine_name'] ?? ''}',
                              style: const TextStyle(fontSize: 12)),
                        ),
                        SizedBox(
                          width: 50,
                          child: Text('${r['stitch'] ?? 0}',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                        SizedBox(
                          width: 55,
                          child: Text(
                              '\u20b9${((r['bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                              textAlign: TextAlign.right,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.blue.shade700)),
                        ),
                        SizedBox(
                          width: 55,
                          child: Text(
                              '\u20b9${((r['incentive_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                              textAlign: TextAlign.right,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.purple.shade700)),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(
                              '\u20b9${((r['total_bonus'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                              textAlign: TextAlign.right,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green.shade700)),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          );
        },
      );
    }
    // ...existing code for other groupings...
    final groupedList = grouped;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: groupedList.length,
      itemBuilder: (_, i) {
        final key = groupedList.keys.elementAt(i);
        final rows = groupedList[key]!;
        final stitch = _totalStitch(rows);
        final bonus = _totalBonus(rows);
        final days = _runningDays(rows);
        // ...existing code...
        // (rest of the original _buildGroupedList implementation)
      },
    );
  }
}
