// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class AdjustmentHistoryReportPage extends StatefulWidget {
  const AdjustmentHistoryReportPage({super.key});

  @override
  State<AdjustmentHistoryReportPage> createState() =>
      _AdjustmentHistoryReportPageState();
}

class _AdjustmentHistoryReportPageState
    extends State<AdjustmentHistoryReportPage> {
  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> filteredRows = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];

  DateTime? fromDate;
  DateTime? toDate;
  int? selectedProductId;
  int? selectedShadeId;
  String typeFilter = 'all'; // all, IN, OUT
  bool loading = true;
  bool reportGenerated = false;
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

  Future<void> _load({bool showLoader = false}) async {
    final loadVersion = ++_loadVersion;
    if (mounted && showLoader) setState(() => loading = true);
    final db = await ErpDatabase.instance.database;

    final nextRows = await db.rawQuery('''
      SELECT
        sl.id,
        sl.product_id,
        sl.fabric_shade_id,
        sl.qty,
        sl.type,
        sl.date,
        sl.remarks,
        p.name AS product_name,
        COALESCE(p.unit, 'Mtr') AS product_unit,
        COALESCE(fs.shade_no, 'NO SHADE') AS shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      WHERE sl.reference = 'ADJUSTMENT'
        AND (sl.is_deleted IS NULL OR sl.is_deleted = 0)
      ORDER BY sl.date DESC, sl.id DESC
    ''');

    final nextProducts =
        await db.query('products', columns: ['id', 'name'], orderBy: 'name');
    final nextShades = await db.query('fabric_shades',
        columns: ['id', 'shade_no', 'shade_name'], orderBy: 'shade_no');

    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      allRows = nextRows;
      products = nextProducts;
      shades = nextShades;
      loading = false;
    });
    _applyFilters();
  }

  // ---- helpers ----

  String _fmtDate(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _fmtDateChip(DateTime? d) {
    if (d == null) return 'Any';
    return DateFormat('dd-MM-yyyy').format(d);
  }

  // ---- filters ----

  void _applyFilters() {
    final fromMs = fromDate == null
        ? null
        : DateTime(fromDate!.year, fromDate!.month, fromDate!.day)
            .millisecondsSinceEpoch;
    final toMs = toDate == null
        ? null
        : DateTime(toDate!.year, toDate!.month, toDate!.day, 23, 59, 59, 999)
            .millisecondsSinceEpoch;

    final rows = allRows.where((row) {
      final dateMs = row['date'] as int?;
      if (fromMs != null && dateMs != null && dateMs < fromMs) return false;
      if (toMs != null && dateMs != null && dateMs > toMs) return false;

      if (selectedProductId != null && row['product_id'] != selectedProductId) {
        return false;
      }
      if (selectedShadeId != null &&
          row['fabric_shade_id'] != selectedShadeId) {
        return false;
      }
      if (typeFilter != 'all' &&
          (row['type'] ?? '').toString().toUpperCase() !=
              typeFilter.toUpperCase()) {
        return false;
      }
      return true;
    }).toList();

    setState(() => filteredRows = rows);
  }

  Future<void> _pickFromDate() async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: fromDate ?? DateTime.now(),
    );
    if (d == null) return;
    setState(() => fromDate = d);
    _applyFilters();
  }

  Future<void> _pickToDate() async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: toDate ?? fromDate ?? DateTime.now(),
    );
    if (d == null) return;
    setState(() => toDate = d);
    _applyFilters();
  }

  void _clearFilters() {
    setState(() {
      fromDate = null;
      toDate = null;
      selectedProductId = null;
      selectedShadeId = null;
      typeFilter = 'all';
      reportGenerated = false;
    });
  }

  void _showReport() {
    _applyFilters();
    setState(() => reportGenerated = true);
  }

  // ---- summary ----

  Map<String, dynamic> _buildSummary() {
    int totalIn = 0;
    int totalOut = 0;
    double inQty = 0;
    double outQty = 0;

    final monthlyMap = <String, Map<String, dynamic>>{};

    for (final row in filteredRows) {
      final type = (row['type'] ?? '').toString().toUpperCase();
      final qty = (row['qty'] as num?)?.toDouble() ?? 0;

      if (type == 'IN') {
        totalIn++;
        inQty += qty;
      } else {
        totalOut++;
        outQty += qty;
      }

      final dateMs = row['date'] as int?;
      if (dateMs != null) {
        final date = DateTime.fromMillisecondsSinceEpoch(dateMs);
        final monthKey = DateFormat('MMM yyyy').format(date);
        final m = monthlyMap.putIfAbsent(monthKey,
            () => {'inCount': 0, 'outCount': 0, 'inQty': 0.0, 'outQty': 0.0});
        if (type == 'IN') {
          m['inCount'] = (m['inCount'] as int) + 1;
          m['inQty'] = (m['inQty'] as double) + qty;
        } else {
          m['outCount'] = (m['outCount'] as int) + 1;
          m['outQty'] = (m['outQty'] as double) + qty;
        }
      }
    }

    return {
      'totalIn': totalIn,
      'totalOut': totalOut,
      'inQty': inQty,
      'outQty': outQty,
      'netQty': inQty - outQty,
      'monthly': monthlyMap,
    };
  }

  // ---- PDF ----

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
    if (filteredRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No entries to export')),
      );
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);

    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final fromText =
        fromDate == null ? 'Any' : DateFormat('dd-MM-yyyy').format(fromDate!);
    final toText =
        toDate == null ? 'Any' : DateFormat('dd-MM-yyyy').format(toDate!);

    final summary = _buildSummary();
    final unit = filteredRows.isNotEmpty
        ? (filteredRows.first['product_unit'] ?? 'Mtr').toString()
        : 'Mtr';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (ctx.pageNumber == 1) ...[
              pw.Center(child: pw.Image(logoImage, width: 50, height: 50)),
              pw.SizedBox(height: 4),
            ],
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Adjustment History Report',
                    style: pw.TextStyle(
                        fontSize: 12, fontWeight: pw.FontWeight.bold)),
                pw.Text('Generated: $now',
                    style: const pw.TextStyle(fontSize: 8)),
              ],
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
        build: (ctx) {
          final widgets = <pw.Widget>[
            pw.Text(
                'Date: $fromText to $toText  |  Type: ${typeFilter.toUpperCase()}',
                style: const pw.TextStyle(fontSize: 9)),
            pw.Text(
              'IN: ${summary['totalIn']} (${(summary['inQty'] as double).toStringAsFixed(2)} $unit)  |  '
              'OUT: ${summary['totalOut']} (${(summary['outQty'] as double).toStringAsFixed(2)} $unit)  |  '
              'Net: ${(summary['netQty'] as double).toStringAsFixed(2)} $unit',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
          ];

          // Monthly summary table
          final monthly =
              summary['monthly'] as Map<String, Map<String, dynamic>>;
          if (monthly.isNotEmpty) {
            widgets.add(pw.Text('Monthly Adjustment Summary',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)));
            final monthData = monthly.entries.map((e) {
              return [
                e.key,
                '${e.value['inCount']}',
                (e.value['inQty'] as double).toStringAsFixed(2),
                '${e.value['outCount']}',
                (e.value['outQty'] as double).toStringAsFixed(2),
              ];
            }).toList();
            widgets.add(pw.TableHelper.fromTextArray(
              headers: const [
                'Month',
                'IN Count',
                'IN Qty',
                'OUT Count',
                'OUT Qty'
              ],
              data: monthData,
              headerStyle:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellPadding:
                  const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              columnWidths: {
                0: const pw.FlexColumnWidth(2),
                1: const pw.FlexColumnWidth(1),
                2: const pw.FlexColumnWidth(1),
                3: const pw.FlexColumnWidth(1),
                4: const pw.FlexColumnWidth(1),
              },
            ));
            widgets.add(pw.SizedBox(height: 10));
          }

          // Detail table
          widgets.add(pw.Text('Detail',
              style:
                  pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)));
          final data = filteredRows.map((r) {
            return [
              _fmtDate(r['date'] as int?),
              (r['product_name'] ?? '-').toString(),
              (r['shade_no'] ?? '-').toString(),
              (r['type'] ?? '-').toString().toUpperCase(),
              ((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
              (r['remarks'] ?? '-').toString(),
            ];
          }).toList();

          widgets.add(pw.TableHelper.fromTextArray(
            headers: const [
              'Date',
              'Product',
              'Shade',
              'Type',
              'Qty',
              'Remarks',
            ],
            data: data,
            headerStyle:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            columnWidths: {
              0: const pw.FlexColumnWidth(1.3),
              1: const pw.FlexColumnWidth(1.5),
              2: const pw.FlexColumnWidth(1),
              3: const pw.FlexColumnWidth(0.6),
              4: const pw.FlexColumnWidth(0.8),
              5: const pw.FlexColumnWidth(2),
            },
          ));

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name: 'adjustment_history_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  // ---- build UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adjustment History'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: loading ? null : _exportPdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Filters
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.white,
                  ),
                  child: Column(
                    children: [
                      // Date row
                      Row(
                        children: [
                          Expanded(
                            child: ActionChip(
                              avatar:
                                  const Icon(Icons.calendar_today, size: 16),
                              label: Text('From: ${_fmtDateChip(fromDate)}',
                                  style: const TextStyle(fontSize: 12)),
                              onPressed: _pickFromDate,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ActionChip(
                              avatar:
                                  const Icon(Icons.calendar_today, size: 16),
                              label: Text('To: ${_fmtDateChip(toDate)}',
                                  style: const TextStyle(fontSize: 12)),
                              onPressed: _pickToDate,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Product + Type
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: selectedProductId,
                              decoration: const InputDecoration(
                                labelText: 'Product',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              isExpanded: true,
                              items: [
                                const DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text('All Products'),
                                ),
                                ...products.map(
                                  (p) => DropdownMenuItem<int?>(
                                    value: p['id'] as int,
                                    child: Text((p['name'] ?? '').toString(),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                              ],
                              onChanged: (v) {
                                setState(() {
                                  selectedProductId = v;
                                  reportGenerated = false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: typeFilter,
                              decoration: const InputDecoration(
                                labelText: 'Type',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: 'all', child: Text('All')),
                                DropdownMenuItem(
                                    value: 'IN', child: Text('IN')),
                                DropdownMenuItem(
                                    value: 'OUT', child: Text('OUT')),
                              ],
                              onChanged: (v) {
                                setState(() {
                                  typeFilter = v ?? 'all';
                                  reportGenerated = false;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Shade
                      DropdownButtonFormField<int?>(
                        initialValue: selectedShadeId,
                        decoration: const InputDecoration(
                          labelText: 'Shade',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('All Shades'),
                          ),
                          ...shades.map(
                            (s) => DropdownMenuItem<int?>(
                              value: s['id'] as int,
                              child: Text((s['shade_no'] ?? '').toString()),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          setState(() {
                            selectedShadeId = v;
                            reportGenerated = false;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _showReport,
                          icon: const Icon(Icons.grid_view),
                          label: const Text('Show Report'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _clearFilters,
                          child: const Text('Clear Filters'),
                        ),
                      ),
                    ],
                  ),
                ),
                // Results
                if (!reportGenerated)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: Center(
                        child: Text('Select filters and tap Show Report')),
                  )
                else
                  ..._buildReportWidgets(),
              ],
            ),
    );
  }

  List<Widget> _buildReportWidgets() {
    if (filteredRows.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(child: Text('No adjustments found')),
        ),
      ];
    }

    final summary = _buildSummary();
    final unit = filteredRows.isNotEmpty
        ? (filteredRows.first['product_unit'] ?? 'Mtr').toString()
        : 'Mtr';
    final monthly = summary['monthly'] as Map<String, Map<String, dynamic>>;

    return [
      // Summary card
      Card(
        color: Colors.blue.shade50,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Summary',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _summaryChip(
                      'IN',
                      '${summary['totalIn']} (${(summary['inQty'] as double).toStringAsFixed(2)} $unit)',
                      Colors.green),
                  const SizedBox(width: 12),
                  _summaryChip(
                      'OUT',
                      '${summary['totalOut']} (${(summary['outQty'] as double).toStringAsFixed(2)} $unit)',
                      Colors.red),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                  'Net adjustment: ${(summary['netQty'] as double).toStringAsFixed(2)} $unit',
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
      // Monthly breakdown
      if (monthly.isNotEmpty) ...[
        const SizedBox(height: 8),
        Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Monthly Adjustments',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 20,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('Month')),
                      DataColumn(label: Text('IN')),
                      DataColumn(label: Text('IN Qty')),
                      DataColumn(label: Text('OUT')),
                      DataColumn(label: Text('OUT Qty')),
                    ],
                    rows: monthly.entries.map((e) {
                      return DataRow(cells: [
                        DataCell(
                            Text(e.key, style: const TextStyle(fontSize: 12))),
                        DataCell(Text('${e.value['inCount']}',
                            style: const TextStyle(fontSize: 12))),
                        DataCell(Text(
                            (e.value['inQty'] as double).toStringAsFixed(2),
                            style: const TextStyle(fontSize: 12))),
                        DataCell(Text('${e.value['outCount']}',
                            style: const TextStyle(fontSize: 12))),
                        DataCell(Text(
                            (e.value['outQty'] as double).toStringAsFixed(2),
                            style: const TextStyle(fontSize: 12))),
                      ]);
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      // Detail table
      const SizedBox(height: 8),
      Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 14,
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 44,
              columns: const [
                DataColumn(label: Text('Date')),
                DataColumn(label: Text('Product')),
                DataColumn(label: Text('Shade')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Qty')),
                DataColumn(label: Text('Remarks')),
              ],
              rows: filteredRows.map((r) {
                final type = (r['type'] ?? '').toString().toUpperCase();
                final isIn = type == 'IN';
                return DataRow(cells: [
                  DataCell(Text(_fmtDate(r['date'] as int?),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text((r['product_name'] ?? '-').toString(),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text((r['shade_no'] ?? '-').toString(),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            isIn ? Colors.green.shade100 : Colors.red.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isIn
                              ? Colors.green.shade800
                              : Colors.red.shade800,
                        ),
                      ),
                    ),
                  ),
                  DataCell(Text(
                      ((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text((r['remarks'] ?? '-').toString(),
                      style: const TextStyle(fontSize: 12))),
                ]);
              }).toList(),
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  Widget _summaryChip(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color.withValues(alpha: 0.8))),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(fontSize: 13, color: color),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

