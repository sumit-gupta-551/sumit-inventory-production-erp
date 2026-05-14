// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart';

import '../data/erp_database.dart';

class AdvanceReportPage extends StatefulWidget {
  const AdvanceReportPage({super.key});

  @override
  State<AdvanceReportPage> createState() => _AdvanceReportPageState();
}

class _AdvanceReportPageState extends State<AdvanceReportPage> {
  final _db = ErpDatabase.instance;
  final _df = DateFormat('dd-MM-yyyy');
  final _mf = DateFormat('MMM yyyy');

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _toDate = DateTime.now();

  List<Map<String, dynamic>> _advances = [];
  bool _loading = true;
  Timer? _reloadDebounce;
  int _loadVersion = 0;

  // Group-by mode
  String _groupBy = 'month'; // month, unit, mode

  static const _modeLabels = {
    'cash': 'Cash',
    'transfer': 'Transfer',
    'neft': 'NEFT',
  };
  static const _modeIcons = {
    'cash': Icons.money,
    'transfer': Icons.swap_horiz,
    'neft': Icons.account_balance,
  };
  static const _modeColors = {
    'cash': Colors.green,
    'transfer': Colors.blue,
    'neft': Colors.purple,
  };

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

  int get _fromMs => DateTime(_fromDate.year, _fromDate.month, _fromDate.day)
      .millisecondsSinceEpoch;
  int get _toMs => DateTime(_toDate.year, _toDate.month, _toDate.day)
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch;

  Future<void> _load({bool showLoader = false}) async {
    final loadVersion = ++_loadVersion;
    final shouldShowLoader = showLoader || _advances.isEmpty;
    if (mounted && shouldShowLoader) setState(() => _loading = true);
    final list = await _db.getSalaryAdvances(fromMs: _fromMs, toMs: _toMs);
    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      _advances = list;
      _loading = false;
    });
  }

  Future<void> _reloadForFilters() async {
    await _load(showLoader: _advances.isEmpty);
  }

  // ─── helpers ───
  String _dateStr(int ms) =>
      _df.format(DateTime.fromMillisecondsSinceEpoch(ms));
  String _monthStr(int ms) =>
      _mf.format(DateTime.fromMillisecondsSinceEpoch(ms));

  double _totalAmt(List<Map<String, dynamic>> rows) {
    double t = 0;
    for (final r in rows) {
      t += (r['amount'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  // ─── Grouping ───
  Map<String, List<Map<String, dynamic>>> get _grouped {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final a in _advances) {
      String key;
      switch (_groupBy) {
        case 'unit':
          key = (a['unit_name'] as String?) ?? 'No Unit';
          break;
        case 'mode':
          final m = (a['payment_mode'] as String?) ?? 'cash';
          key = _modeLabels[m] ?? m;
          break;
        default: // month
          key = _monthStr(a['date'] as int? ?? 0);
      }
      map.putIfAbsent(key, () => []).add(a);
    }
    final sorted = map.entries.toList();
    if (_groupBy == 'month') {
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

  /// Mode-wise breakdown inside a group
  Map<String, double> _modeBreakdown(List<Map<String, dynamic>> rows) {
    final m = <String, double>{};
    for (final r in rows) {
      final mode = (r['payment_mode'] as String?) ?? 'cash';
      m[mode] = (m[mode] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
    }
    return m;
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
      _reloadForFilters();
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
      _reloadForFilters();
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

    final groupByLabel = {
      'month': 'Month Wise',
      'unit': 'Unit Wise',
      'mode': 'Mode Wise',
    }[_groupBy]!;

    final grouped = _grouped;
    double grandTotal = 0;

    final pageContent = <pw.Widget>[];

    for (final entry in grouped.entries) {
      final groupRows = entry.value;
      final groupTotal = _totalAmt(groupRows);
      final mb = _modeBreakdown(groupRows);
      grandTotal += groupTotal;

      // Group header
      pageContent.add(pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 8),
        color: PdfColors.blue50,
        child: pw.Text(
            '${entry.key}  —  Count: ${groupRows.length}  |  Cash: \u20b9${(mb['cash'] ?? 0).toStringAsFixed(0)}  |  Transfer: \u20b9${(mb['transfer'] ?? 0).toStringAsFixed(0)}  |  NEFT: \u20b9${(mb['neft'] ?? 0).toStringAsFixed(0)}  |  Total: \u20b9${groupTotal.toStringAsFixed(0)}',
            style: pw.TextStyle(font: fontBold, fontSize: 9)),
      ));

      // Detail table with employee names
      final tRows = <pw.TableRow>[];
      tRows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          _pdfCell('#', hStyle),
          _pdfCell('Employee', hStyle),
          _pdfCell('Date', hStyle),
          _pdfCell('Unit', hStyle),
          _pdfCell('Mode', hStyle, align: pw.TextAlign.center),
          _pdfCell('Amount', hStyle, align: pw.TextAlign.right),
        ],
      ));

      int idx = 0;
      for (final r in groupRows) {
        idx++;
        final mode = (r['payment_mode'] as String?) ?? 'cash';
        tRows.add(pw.TableRow(children: [
          _pdfCell('$idx', style),
          _pdfCell((r['employee_name'] as String?) ?? 'Unknown', style),
          _pdfCell(_dateStr(r['date'] as int), style),
          _pdfCell((r['unit_name'] as String?) ?? '', style),
          _pdfCell(_modeLabels[mode] ?? mode, style,
              align: pw.TextAlign.center),
          _pdfCell(
              '\u20b9${((r['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
              style,
              align: pw.TextAlign.right),
        ]));
      }

      // Group subtotal row
      tRows.add(pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey100),
        children: [
          _pdfCell('', hStyle),
          _pdfCell('Subtotal', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('${groupRows.length}', hStyle, align: pw.TextAlign.center),
          _pdfCell('\u20b9${groupTotal.toStringAsFixed(0)}', hStyle,
              align: pw.TextAlign.right),
        ],
      ));

      pageContent.add(pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(0.4),
          1: const pw.FlexColumnWidth(2.5),
          2: const pw.FlexColumnWidth(1.2),
          3: const pw.FlexColumnWidth(1.5),
          4: const pw.FlexColumnWidth(1),
          5: const pw.FlexColumnWidth(1.3),
        },
        children: tRows,
      ));
      pageContent.add(pw.SizedBox(height: 10));
    }

    // Grand total bar
    final allMb = _modeBreakdown(_advances);
    pageContent.add(pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      color: PdfColors.grey200,
      child: pw.Text(
          'Grand Total  —  Count: ${_advances.length}  |  Cash: \u20b9${(allMb['cash'] ?? 0).toStringAsFixed(0)}  |  Transfer: \u20b9${(allMb['transfer'] ?? 0).toStringAsFixed(0)}  |  NEFT: \u20b9${(allMb['neft'] ?? 0).toStringAsFixed(0)}  |  Total: \u20b9${grandTotal.toStringAsFixed(0)}',
          style: pw.TextStyle(font: fontBold, fontSize: 11)),
    ));

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
                'Employee Advance Report — $groupByLabel  (${_df.format(_fromDate)} - ${_df.format(_toDate)})',
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
      build: (ctx) => pageContent,
    ));

    await Printing.layoutPdf(
        onLayout: (format) => doc.save(), name: 'Advance_Report.pdf');
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
        title: const Text('Advance Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_rounded),
            tooltip: 'Export PDF',
            onPressed: _advances.isEmpty ? null : _exportPdf,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildDateRow(),
          _buildGroupChips(),
          _buildSummaryBar(),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _advances.isEmpty
                    ? const Center(
                        child: Text('No advances found',
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
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today,
                      size: 16, color: Colors.orange.shade700),
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
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_today,
                      size: 16, color: Colors.orange.shade700),
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
      ('month', 'Month', Icons.date_range),
      ('unit', 'Unit', Icons.business),
      ('mode', 'Mode', Icons.payment),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: modes.map((m) {
          final selected = _groupBy == m.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              avatar: Icon(m.$3,
                  size: 16,
                  color: selected ? Colors.white : Colors.orange.shade700),
              label: Text(m.$2,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : Colors.orange.shade700)),
              selected: selected,
              selectedColor: Colors.orange.shade700,
              backgroundColor: Colors.orange.shade50,
              onSelected: (_) {
                setState(() => _groupBy = m.$1);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSummaryBar() {
    final total = _totalAmt(_advances);
    final mb = _modeBreakdown(_advances);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _statCol('Count', '${_advances.length}', Colors.orange),
          _statCol('Cash', '\u20b9${(mb['cash'] ?? 0).toStringAsFixed(0)}',
              Colors.green),
          _statCol('Transfer',
              '\u20b9${(mb['transfer'] ?? 0).toStringAsFixed(0)}', Colors.blue),
          _statCol('NEFT', '\u20b9${(mb['neft'] ?? 0).toStringAsFixed(0)}',
              Colors.purple),
          _statCol('Total', '\u20b9${total.toStringAsFixed(0)}', Colors.red),
        ],
      ),
    );
  }

  Widget _statCol(String label, String value, Color c) {
    return Column(
      children: [
        Text(value,
            style:
                TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildGroupedList() {
    final grouped = _grouped;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: grouped.length,
      itemBuilder: (_, i) {
        final key = grouped.keys.elementAt(i);
        final rows = grouped[key]!;
        final total = _totalAmt(rows);
        final mb = _modeBreakdown(rows);

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: Colors.orange.shade100,
              child: Text('${i + 1}',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.orange.shade800,
                      fontSize: 13)),
            ),
            title: Text(key,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            subtitle: Text(
                'Count: ${rows.length}  |  Cash: \u20b9${(mb['cash'] ?? 0).toStringAsFixed(0)}  |  Transfer: \u20b9${(mb['transfer'] ?? 0).toStringAsFixed(0)}  |  NEFT: \u20b9${(mb['neft'] ?? 0).toStringAsFixed(0)}  |  Total: \u20b9${total.toStringAsFixed(0)}',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            children: rows.map((r) {
              final mode = (r['payment_mode'] as String?) ?? 'cash';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(_modeIcons[mode] ?? Icons.money,
                        size: 16, color: _modeColors[mode] ?? Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${r['employee_name'] ?? 'Unknown'}'
                        '${_groupBy != 'unit' ? '  ·  ${r['unit_name'] ?? ''}' : ''}'
                        '${_groupBy != 'month' ? '  ·  ${_dateStr(r['date'] as int)}' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Text(
                      '\u20b9${((r['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.red.shade700),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
