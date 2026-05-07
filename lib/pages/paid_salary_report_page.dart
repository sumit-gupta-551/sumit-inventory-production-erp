// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class PaidSalaryReportPage extends StatefulWidget {
  const PaidSalaryReportPage({super.key});

  @override
  State<PaidSalaryReportPage> createState() => _PaidSalaryReportPageState();
}

class _PaidSalaryReportPageState extends State<PaidSalaryReportPage> {
  final _df = DateFormat('dd-MM-yyyy');
  final _mf = DateFormat('MMM yyyy');

  DateTime _fromDate = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _toDate = DateTime.now();
  String _groupBy = 'employee';
  String? _modeFilter;
  int? _selectedEmployeeId;

  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;
  Timer? _reloadDebounce;
  int _loadVersion = 0;

  static const _modeLabels = {
    'cash': 'Cash',
    'transfer': 'Transfer',
    'neft': 'NEFT',
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

  List<Map<String, dynamic>> get _visiblePayments {
    return _payments.where((payment) {
      if (_selectedEmployeeId != null &&
          (payment['employee_id'] as num?)?.toInt() != _selectedEmployeeId) {
        return false;
      }
      if (_modeFilter != null &&
          (payment['payment_mode'] ?? '').toString() != _modeFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  List<MapEntry<int, String>> get _employeeChoices {
    final names = <int, String>{};
    for (final payment in _payments) {
      final id = (payment['employee_id'] as num?)?.toInt();
      if (id == null) continue;
      final name = (payment['employee_name'] as String?)?.trim();
      names[id] = (name == null || name.isEmpty) ? 'Employee #$id' : name;
    }
    final list = names.entries.toList();
    list.sort((a, b) => a.value.compareTo(b.value));
    return list;
  }

  Future<void> _load({bool showLoader = false}) async {
    final version = ++_loadVersion;
    if (mounted && (showLoader || _payments.isEmpty)) {
      setState(() => _loading = true);
    }

    final rows = await ErpDatabase.instance.getSalaryPayments(
      fromMs: _fromMs,
      toMs: _toMs,
    );

    if (!mounted || version != _loadVersion) return;
    setState(() {
      _payments = rows;
      _loading = false;
    });
  }

  Future<void> _reloadForFilters() async {
    await _load(showLoader: _payments.isEmpty);
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _fromDate = picked);
    _reloadForFilters();
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _toDate = picked);
    _reloadForFilters();
  }

  String _dateText(dynamic ms) {
    final value = (ms as num?)?.toInt();
    if (value == null || value <= 0) return '-';
    return _df.format(DateTime.fromMillisecondsSinceEpoch(value));
  }

  String _monthText(dynamic ms) {
    final value = (ms as num?)?.toInt();
    if (value == null || value <= 0) return '-';
    return _mf.format(DateTime.fromMillisecondsSinceEpoch(value));
  }

  String _modeText(dynamic mode) {
    final key = (mode ?? 'cash').toString();
    return _modeLabels[key] ?? key;
  }

  double _totalAmount(List<Map<String, dynamic>> rows) {
    var total = 0.0;
    for (final row in rows) {
      total += (row['amount'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  Map<String, List<Map<String, dynamic>>> _groupRows() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in _visiblePayments) {
      final key = switch (_groupBy) {
        'unit' => (row['unit_name'] ?? 'No Unit').toString(),
        'mode' => _modeText(row['payment_mode']),
        'month' => _monthText(row['date']),
        _ => (row['employee_name'] ?? 'Unknown').toString(),
      };
      map.putIfAbsent(key, () => []).add(row);
    }
    final sorted = map.entries.toList();
    sorted.sort((a, b) {
      if (_groupBy == 'month') {
        return _mf.parse(a.key).compareTo(_mf.parse(b.key));
      }
      return a.key.compareTo(b.key);
    });
    return Map.fromEntries(sorted);
  }

  Future<void> _exportPdf() async {
    final rows = _visiblePayments;
    if (rows.isEmpty) return;

    final doc = pw.Document();
    final font = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final style = pw.TextStyle(font: font, fontSize: 9);
    final hStyle = pw.TextStyle(font: bold, fontSize: 10);

    pw.MemoryImage? logoImage;
    try {
      final logoData = await rootBundle.load('assets/logo.png');
      logoImage = pw.MemoryImage(logoData.buffer.asUint8List());
    } catch (_) {}

    final tableRows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          _pdfCell('#', hStyle),
          _pdfCell('Date', hStyle),
          _pdfCell('Employee', hStyle),
          _pdfCell('Unit', hStyle),
          _pdfCell('Mode', hStyle),
          _pdfCell('Period', hStyle),
          _pdfCell('Amount', hStyle, align: pw.TextAlign.right),
          _pdfCell('Remarks', hStyle),
        ],
      ),
    ];

    var index = 0;
    for (final row in rows) {
      index++;
      final period =
          '${_dateText(row['from_date'])} - ${_dateText(row['to_date'])}';
      tableRows.add(
        pw.TableRow(
          children: [
            _pdfCell('$index', style),
            _pdfCell(_dateText(row['date']), style),
            _pdfCell((row['employee_name'] ?? 'Unknown').toString(), style),
            _pdfCell((row['unit_name'] ?? '-').toString(), style),
            _pdfCell(_modeText(row['payment_mode']), style),
            _pdfCell(period, style),
            _pdfCell(
              ((row['amount'] as num?)?.toDouble() ?? 0).toStringAsFixed(0),
              style,
              align: pw.TextAlign.right,
            ),
            _pdfCell((row['remarks'] ?? '').toString(), style),
          ],
        ),
      );
    }

    tableRows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey100),
        children: [
          _pdfCell('', hStyle),
          _pdfCell('Grand Total', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('', hStyle),
          _pdfCell('${rows.length} payments', hStyle),
          _pdfCell(_totalAmount(rows).toStringAsFixed(0), hStyle,
              align: pw.TextAlign.right),
          _pdfCell('', hStyle),
        ],
      ),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (ctx) => pw.Column(
          children: [
            if (ctx.pageNumber == 1 && logoImage != null) ...[
              pw.Image(logoImage, width: 50, height: 50),
              pw.SizedBox(height: 4),
            ],
            pw.Text('Paid Salary Report',
                style: pw.TextStyle(font: bold, fontSize: 14)),
            pw.Text('${_df.format(_fromDate)} - ${_df.format(_toDate)}',
                style: pw.TextStyle(font: font, fontSize: 9)),
            pw.Divider(),
          ],
        ),
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ),
        build: (ctx) => [
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: {
              0: const pw.FlexColumnWidth(0.4),
              1: const pw.FlexColumnWidth(1.0),
              2: const pw.FlexColumnWidth(1.7),
              3: const pw.FlexColumnWidth(1.2),
              4: const pw.FlexColumnWidth(0.9),
              5: const pw.FlexColumnWidth(1.8),
              6: const pw.FlexColumnWidth(1.0),
              7: const pw.FlexColumnWidth(1.8),
            },
            children: tableRows,
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) => doc.save(),
      name: 'Paid_Salary_Report.pdf',
    );
  }

  pw.Widget _pdfCell(String text, pw.TextStyle style,
      {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(5),
      child: pw.Text(text, style: style, textAlign: align),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupRows();
    final rows = _visiblePayments;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paid Salary Report'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: rows.isEmpty ? null : _exportPdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilters(),
          _buildSummary(rows),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                    ? const Center(child: Text('No paid salary found'))
                    : ListView(
                        padding: const EdgeInsets.all(12),
                        children: grouped.entries
                            .map((entry) => _groupCard(entry.key, entry.value))
                            .toList(),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickFrom,
                  icon: const Icon(Icons.date_range),
                  label: Text('From: ${_df.format(_fromDate)}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTo,
                  icon: const Icon(Icons.date_range),
                  label: Text('To: ${_df.format(_toDate)}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int?>(
            value: _selectedEmployeeId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Employee',
              prefixIcon: Icon(Icons.person_search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('All Employees'),
              ),
              ..._employeeChoices.map(
                (e) => DropdownMenuItem<int?>(
                  value: e.key,
                  child: Text(e.value),
                ),
              ),
            ],
            onChanged: (value) => setState(() => _selectedEmployeeId = value),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _groupBy,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Group By',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'employee', child: Text('Employee')),
                    DropdownMenuItem(value: 'unit', child: Text('Unit')),
                    DropdownMenuItem(
                        value: 'mode', child: Text('Payment Mode')),
                    DropdownMenuItem(value: 'month', child: Text('Month')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _groupBy = value);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  value: _modeFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Mode',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem<String?>(
                        value: null, child: Text('All Modes')),
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                    DropdownMenuItem(
                        value: 'transfer', child: Text('Transfer')),
                    DropdownMenuItem(value: 'neft', child: Text('NEFT')),
                  ],
                  onChanged: (value) => setState(() => _modeFilter = value),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(List<Map<String, dynamic>> rows) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _stat('Payments', '${rows.length}', Colors.indigo),
          _stat(
              'Employees',
              '${rows.map((r) => r['employee_id']).toSet().length}',
              Colors.teal),
          _stat('Total Paid', 'Rs ${_totalAmount(rows).toStringAsFixed(0)}',
              Colors.green),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade700)),
      ],
    );
  }

  Widget _groupCard(String title, List<Map<String, dynamic>> rows) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${rows.length} payments  |  Rs ${_totalAmount(rows).toStringAsFixed(0)}',
        ),
        children: rows.map(_paymentTile).toList(),
      ),
    );
  }

  Widget _paymentTile(Map<String, dynamic> row) {
    final amount = (row['amount'] as num?)?.toDouble() ?? 0;
    final remarks = (row['remarks'] ?? '').toString().trim();
    return ListTile(
      dense: true,
      title: Text(
        '${row['employee_name'] ?? 'Unknown'}  -  Rs ${amount.toStringAsFixed(0)}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          '${_dateText(row['date'])}  |  ${row['unit_name'] ?? '-'}  |  ${_modeText(row['payment_mode'])}',
          'Period: ${_dateText(row['from_date'])} - ${_dateText(row['to_date'])}',
          if (remarks.isNotEmpty) 'Remarks: $remarks',
        ].join('\n'),
      ),
    );
  }
}
