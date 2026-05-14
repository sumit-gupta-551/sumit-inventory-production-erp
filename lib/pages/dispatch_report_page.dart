// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';

/// Flattened dispatch row: one entry per dispatch_items qty-row.
class _DispatchRow {
  final int billId;
  final String billNo;
  final DateTime? date;
  final String company;
  final int? partyId;
  final int? productId;
  final String designNo;
  final String cardNo;
  final double tp;
  final String lineNo;
  final double qty; // qty entered on the row
  final double pcs; // pcs entered on the row
  double get total => qty * pcs;

  _DispatchRow({
    required this.billId,
    required this.billNo,
    required this.date,
    required this.company,
    required this.partyId,
    required this.productId,
    required this.designNo,
    required this.cardNo,
    required this.tp,
    required this.lineNo,
    required this.qty,
    required this.pcs,
  });
}

/// One card on a bill aggregated across all its qty entries.
class _GroupedRow {
  final int billId;
  final String billNo;
  final DateTime? date;
  final String company;
  final int? partyId;
  final int? productId;
  final String designNo;
  final String cardNo;
  final double tp;
  final String lineNo;
  final List<_DispatchRow> entries;

  _GroupedRow({
    required this.billId,
    required this.billNo,
    required this.date,
    required this.company,
    required this.partyId,
    required this.productId,
    required this.designNo,
    required this.cardNo,
    required this.tp,
    required this.lineNo,
    required this.entries,
  });

  double get totalQty => entries.fold(0.0, (s, e) => s + e.qty);
  double get totalPcs => entries.fold(0.0, (s, e) => s + e.pcs);
  double get total => entries.fold(0.0, (s, e) => s + e.total);
}

enum _DateRange { all, today, yesterday, thisWeek, thisMonth, custom }

class DispatchReportPage extends StatefulWidget {
  const DispatchReportPage({super.key});

  @override
  State<DispatchReportPage> createState() => _DispatchReportPageState();
}

class _DispatchReportPageState extends State<DispatchReportPage> {
  final _db = ErpDatabase.instance;
  final _df = DateFormat('dd-MM-yyyy');

  bool _loading = true;
  List<_DispatchRow> _rows = [];
  List<Party> _parties = [];
  List<Product> _products = [];

  // Filters
  _DateRange _dateRange = _DateRange.all;
  DateTime? _fromDate;
  DateTime? _toDate;
  String? _filterCompany;
  int? _filterPartyId;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
    _db.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    _db.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) _load();
  }

  int? _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v == null) return null;
    return int.tryParse(v.toString().trim());
  }

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v == null) return 0;
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      await _db.restoreRecentlyDeletedDispatchBillsNow();
      await _db.reopenOrphanClosedDispatchCardsNow();
      final reportRows = await _db.getDispatchReportRows();
      final parties = await _db.getParties();
      final products = await _db.getProducts();

      final rows = <_DispatchRow>[];
      for (final r in reportRows) {
        final itemId = _toInt(r['item_id']) ?? (rows.length + 1);
        final billId = _toInt(r['bill_id']) ?? (-itemId);
        final billNo = (r['bill_no'] ?? '').toString();
        final dtMs = _toInt(r['bill_date']);
        final date =
            dtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(dtMs);
        final partyId = _toInt(r['party_id']);
        final companyRaw = (r['company'] ?? '').toString().trim();
        final designRaw = (r['design_no'] ?? '').toString().trim();
        final cardRaw = (r['card_no'] ?? '').toString().trim();
        final qty = _toDouble(r['qty']);
        final pcs = _toDouble(r['pcs']);
        final isEmptyBillPlaceholder =
            companyRaw.isEmpty && designRaw.isEmpty && cardRaw.isEmpty && qty == 0 && pcs == 0;
        rows.add(_DispatchRow(
          billId: billId,
          billNo: billNo,
          date: date,
          company: companyRaw.isEmpty ? '-' : companyRaw,
          partyId: partyId,
          productId: _toInt(r['product_id']),
          designNo: isEmptyBillPlaceholder
              ? '(No dispatch rows)'
              : (designRaw.isEmpty ? '-' : designRaw),
          cardNo: cardRaw.isEmpty ? '-' : cardRaw,
          tp: _toDouble(r['tp']),
          lineNo: (r['line_no'] ?? '').toString(),
          qty: qty,
          pcs: pcs,
        ));
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _parties = parties;
        _products = products;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load dispatch report: $e')),
      );
    }
  }

  String _partyName(int? id) {
    if (id == null) return '';
    final f = _parties.where((p) => p.id == id);
    return f.isEmpty ? '' : f.first.name;
  }

  String _productName(int? id) {
    if (id == null) return '';
    final f = _products.where((p) => p.id == id);
    return f.isEmpty ? '' : f.first.name;
  }

  String _f(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  String _companyKey(String company) => company.trim().toUpperCase();

  List<_DispatchRow> get _filtered {
    final q = _search.trim().toLowerCase();
    return _rows.where((r) {
      if (_filterCompany != null &&
          _filterCompany!.isNotEmpty &&
          _companyKey(r.company) != _companyKey(_filterCompany!)) {
        return false;
      }
      if (_filterPartyId != null && r.partyId != _filterPartyId) return false;
      if (_fromDate != null &&
          (r.date == null || r.date!.isBefore(_fromDate!))) {
        return false;
      }
      if (_toDate != null) {
        final end =
            DateTime(_toDate!.year, _toDate!.month, _toDate!.day, 23, 59, 59);
        if (r.date == null || r.date!.isAfter(end)) return false;
      }
      if (q.isNotEmpty) {
        final blob =
            '${r.billNo} ${r.designNo} ${r.cardNo} ${r.company} ${_partyName(r.partyId)} ${_productName(r.productId)}'
                .toLowerCase();
        if (!blob.contains(q)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final co = _companyKey(a.company).compareTo(_companyKey(b.company));
        if (co != 0) return co;
        final ad = a.date?.millisecondsSinceEpoch ?? 0;
        final bd = b.date?.millisecondsSinceEpoch ?? 0;
        final dt = bd.compareTo(ad);
        if (dt != 0) return dt;
        final dsg = a.designNo.compareTo(b.designNo);
        if (dsg != 0) return dsg;
        return a.cardNo.compareTo(b.cardNo);
      });
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final init = (isFrom ? _fromDate : _toDate) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      _dateRange = _DateRange.custom;
      if (isFrom) {
        _fromDate = d;
      } else {
        _toDate = d;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _dateRange = _DateRange.all;
      _fromDate = null;
      _toDate = null;
      _filterCompany = null;
      _filterPartyId = null;
      _search = '';
    });
  }

  void _applyDateRangePreset(_DateRange r) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _dateRange = r;
      switch (r) {
        case _DateRange.all:
          _fromDate = null;
          _toDate = null;
          break;
        case _DateRange.today:
          _fromDate = today;
          _toDate = today;
          break;
        case _DateRange.yesterday:
          final y = today.subtract(const Duration(days: 1));
          _fromDate = y;
          _toDate = y;
          break;
        case _DateRange.thisWeek:
          // Week starts Monday.
          final start = today.subtract(Duration(days: today.weekday - 1));
          _fromDate = start;
          _toDate = today;
          break;
        case _DateRange.thisMonth:
          _fromDate = DateTime(now.year, now.month, 1);
          _toDate = today;
          break;
        case _DateRange.custom:
          // Keep existing custom dates.
          break;
      }
    });
  }

  /// Group filtered rows by bill + card so multiple qty entries on the
  /// same card collapse into a single row.
  List<_GroupedRow> _group(List<_DispatchRow> list) {
    final map = <String, _GroupedRow>{};
    final order = <String>[];
    for (final r in list) {
      final key =
          '${r.billId}|${r.designNo}|${r.cardNo}|${r.company}|${r.productId ?? ''}';
      final g = map[key];
      if (g == null) {
        map[key] = _GroupedRow(
          billId: r.billId,
          billNo: r.billNo,
          date: r.date,
          company: r.company,
          partyId: r.partyId,
          productId: r.productId,
          designNo: r.designNo,
          cardNo: r.cardNo,
          tp: r.tp,
          lineNo: r.lineNo,
          entries: [r],
        );
        order.add(key);
      } else {
        g.entries.add(r);
      }
    }
    return [for (final k in order) map[k]!];
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final groups = _group(list);
    final grandTp = groups.fold<double>(0, (s, g) => s + g.tp);
    final grandQty = list.fold<double>(0, (s, r) => s + r.qty);
    final grandPcs = list.fold<double>(0, (s, r) => s + r.pcs);
    final grandTotal = list.fold<double>(0, (s, r) => s + r.total);

    final companiesByKey = <String, String>{};
    for (final r in _rows) {
      final company = r.company.trim();
      if (company.isEmpty) continue;
      companiesByKey.putIfAbsent(_companyKey(company), () => company);
    }
    final companies = companiesByKey.values.toList()
      ..sort((a, b) => _companyKey(a).compareTo(_companyKey(b)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch Report'),
        backgroundColor: const Color(0xFF0EA5E9),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            icon: const Icon(Icons.picture_as_pdf_rounded),
            onPressed: _loading ? null : _exportPdf,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Clear filters',
            icon: const Icon(Icons.filter_alt_off_rounded),
            onPressed: _clearFilters,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _filtersBar(companies),
                _summaryBar(groups.length, grandTp, grandQty, grandPcs, grandTotal),
                const Divider(height: 1),
                Expanded(
                  child: groups.isEmpty
                      ? const Center(child: Text('No dispatch records.'))
                      : _table(groups),
                ),
              ],
            ),
    );
  }

  Widget _filtersBar(List<String> companies) {
    String dateLabel(_DateRange r) {
      switch (r) {
        case _DateRange.all:
          return 'All Dates';
        case _DateRange.today:
          return 'Today';
        case _DateRange.yesterday:
          return 'Yesterday';
        case _DateRange.thisWeek:
          return 'This Week';
        case _DateRange.thisMonth:
          return 'This Month';
        case _DateRange.custom:
          return 'Custom';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<_DateRange>(
                  initialValue: _dateRange,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Date Range',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: [
                    for (final r in _DateRange.values)
                      DropdownMenuItem(value: r, child: Text(dateLabel(r))),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _applyDateRangePreset(v);
                  },
                ),
              ),
            ],
          ),
          if (_dateRange == _DateRange.custom) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isFrom: true),
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_fromDate == null
                        ? 'From'
                        : 'From: ${_df.format(_fromDate!)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(isFrom: false),
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                        _toDate == null ? 'To' : 'To: ${_df.format(_toDate!)}'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterCompany,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Company',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All')),
                    for (final c in companies)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _filterCompany = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<int?>(
                  initialValue: _filterPartyId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Party',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All')),
                    for (final p in _parties)
                      if (p.id != null)
                        DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => setState(() => _filterPartyId = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search bill / design / card / product',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ],
      ),
    );
  }

  Widget _summaryBar(
      int cards, double tp, double qty, double pcs, double total) {
    Widget stat(String k, String v) => Text(
          '$k: $v',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1F2937),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFCBD5E1)),
        ),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            stat('Total Cards', '$cards'),
            stat('Total TP', _f(tp)),
            stat('Total Qty', _f(qty)),
            stat('Total Pcs', _f(pcs)),
            stat('Grand Total', _f(total)),
          ],
        ),
      ),
    );
  }

  /// Format like "5x25" or "5x10 / 5x10".
  String _entriesText(_GroupedRow g) =>
      g.entries.map((e) => '${_f(e.qty)}x${_f(e.pcs)}').join(' / ');

  Widget _table(List<_GroupedRow> groups) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(minWidth: MediaQuery.of(context).size.width),
        child: SingleChildScrollView(
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(Colors.blueGrey.shade50),
            columnSpacing: 12,
            horizontalMargin: 8,
            headingTextStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            dataTextStyle: const TextStyle(fontSize: 12),
            columns: const [
              DataColumn(label: Text('#')),
              DataColumn(label: Text('Date')),
              DataColumn(label: Text('Bill #')),
              DataColumn(label: SizedBox(width: 72, child: Text('Co.'))),
              DataColumn(label: SizedBox(width: 72, child: Text('Party'))),
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Design')),
              DataColumn(label: Text('Card #')),
              DataColumn(
                  label: SizedBox(width: 42, child: Text('TP')),
                  numeric: true),
              DataColumn(label: SizedBox(width: 46, child: Text('Line'))),
              DataColumn(label: Text('Qty x Pcs')),
              DataColumn(label: Text('Total'), numeric: true),
              DataColumn(label: SizedBox(width: 92, child: Text(''))),
            ],
            rows: [
              for (var i = 0; i < groups.length; i++)
                DataRow(cells: [
                  DataCell(Text('${i + 1}')),
                  DataCell(Text(groups[i].date == null
                      ? '-'
                      : _df.format(groups[i].date!))),
                  DataCell(Text(groups[i].billNo)),
                  DataCell(SizedBox(
                    width: 72,
                    child: Text(
                      groups[i].company,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )),
                  DataCell(SizedBox(
                    width: 72,
                    child: Text(
                      _partyName(groups[i].partyId),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )),
                  DataCell(Text(_productName(groups[i].productId))),
                  DataCell(Text(groups[i].designNo)),
                  DataCell(Text('#${groups[i].cardNo}')),
                  DataCell(SizedBox(
                    width: 42,
                    child: Text(_f(groups[i].tp), overflow: TextOverflow.fade),
                  )),
                  DataCell(SizedBox(
                    width: 46,
                    child:
                        Text(groups[i].lineNo, overflow: TextOverflow.ellipsis),
                  )),
                  DataCell(Text(_entriesText(groups[i]))),
                  DataCell(Text(_f(groups[i].total),
                      style: const TextStyle(fontWeight: FontWeight.bold))),
                  const DataCell(SizedBox(width: 92, child: Text(''))),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    final list = _filtered;
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No records to export')),
      );
      return;
    }
    final groups = _group(list);
    final df = DateFormat('dd MMM yyyy');
    final genAt = DateFormat('dd MMM yyyy hh:mm a').format(DateTime.now());
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);

    final grandTp = groups.fold<double>(0, (s, g) => s + g.tp);
    final grandQty = list.fold<double>(0, (s, r) => s + r.qty);
    final grandPcs = list.fold<double>(0, (s, r) => s + r.pcs);
    final grandTotal = list.fold<double>(0, (s, r) => s + r.total);

    // Build a friendly date-range label for the header.
    String dateRangeLabel() {
      switch (_dateRange) {
        case _DateRange.all:
          return 'All Dates';
        case _DateRange.today:
          return 'Today';
        case _DateRange.yesterday:
          return 'Yesterday';
        case _DateRange.thisWeek:
          return 'This Week';
        case _DateRange.thisMonth:
          return 'This Month';
        case _DateRange.custom:
          if (_fromDate != null && _toDate != null) {
            return '${df.format(_fromDate!)} to ${df.format(_toDate!)}';
          }
          if (_fromDate != null) return 'From ${df.format(_fromDate!)}';
          if (_toDate != null) return 'Up to ${df.format(_toDate!)}';
          return 'Custom';
      }
    }

    final filterParts = <String>['Period: ${dateRangeLabel()}'];
    if (_filterCompany != null) filterParts.add('Co: $_filterCompany');
    if (_filterPartyId != null) {
      filterParts.add('Party: ${_partyName(_filterPartyId)}');
    }
    if (_search.trim().isNotEmpty) {
      filterParts.add('Search: "${_search.trim()}"');
    }
    final filterLine = filterParts.join('   |   ');

    final headers = [
      '#',
      'Date',
      'Co.',
      'Party',
      'Design',
      'Product',
      'Card #',
      'TP',
      'Line',
      'Qty x Pcs',
      'Total',
      '',
    ];
    final data = <List<String>>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      data.add([
        '${i + 1}',
        g.date == null ? '-' : df.format(g.date!),
        g.company,
        _partyName(g.partyId),
        g.designNo,
        _productName(g.productId),
        '#${g.cardNo}',
        _f(g.tp),
        g.lineNo,
        _entriesText(g),
        _f(g.total),
        '',
      ]);
    }

    final headerTotals =
        'Cards: ${groups.length}   Total TP: ${_f(grandTp)}   Total Qty: ${_f(grandQty)}   Sum Pcs: ${_f(grandPcs)}   Grand Total: ${_f(grandTotal)}';

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Image(logoImage, width: 42, height: 42),
                pw.Text('Dispatch Report',
                    style: pw.TextStyle(
                        fontSize: 18, fontWeight: pw.FontWeight.bold)),
                pw.Text('Generated: $genAt',
                    style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(filterLine, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Text(
              headerTotals,
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Dispatch Report', style: const pw.TextStyle(fontSize: 8)),
            pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8)),
          ],
        ),
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.blueGrey700),
            headerAlignment: pw.Alignment.center,
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellHeight: 18,
            cellAlignment: pw.Alignment.center,
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.center,
              2: pw.Alignment.center,
              3: pw.Alignment.centerLeft,
              4: pw.Alignment.center,
              5: pw.Alignment.centerLeft,
              6: pw.Alignment.center,
              7: pw.Alignment.center,
              8: pw.Alignment.center,
              9: pw.Alignment.center,
              10: pw.Alignment.centerRight,
              11: pw.Alignment.center,
            },
            oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
            columnWidths: {
              0: const pw.FlexColumnWidth(0.4), // #
              1: const pw.FlexColumnWidth(1.1), // Date
              2: const pw.FlexColumnWidth(0.7), // Co.
              3: const pw.FlexColumnWidth(0.7), // Party
              4: const pw.FlexColumnWidth(1.0), // Design
              5: const pw.FlexColumnWidth(1.5), // Product
              6: const pw.FlexColumnWidth(0.9), // Card #
              7: const pw.FlexColumnWidth(0.45), // TP
              8: const pw.FlexColumnWidth(0.55), // Line
              9: const pw.FlexColumnWidth(2.5), // Qty x Pcs
              10: const pw.FlexColumnWidth(0.8), // Total
              11: const pw.FlexColumnWidth(0.9), // Blank
            },
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
          ),
          pw.SizedBox(height: 6),
          // Highlighted Grand Total bar
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const pw.BoxDecoration(
              color: PdfColors.blueGrey800,
              borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('GRAND TOTAL',
                    style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white)),
                pw.Text(
                    'Cards: ${groups.length}    Total TP: ${_f(grandTp)}    Total Qty: ${_f(grandQty)}    Sum Pcs: ${_f(grandPcs)}    Total: ${_f(grandTotal)}',
                    style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white)),
              ],
            ),
          ),
        ],
      ),
    );

    final fname =
        'dispatch_report_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf';
    await Printing.layoutPdf(
      onLayout: (fmt) => doc.save(),
      name: fname,
    );
  }
}
