// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../data/erp_database.dart';

class StockLedgerPage extends StatefulWidget {
  const StockLedgerPage({super.key});

  @override
  State<StockLedgerPage> createState() => _StockLedgerPageState();
}

class _StockLedgerPageState extends State<StockLedgerPage> {
  List<Map<String, dynamic>> ledger = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];
  Map<int, double> runningBalanceByRowId = {};
  Map<String, double> currentBalanceByKey = {};
  int? selectedProductId;
  int? selectedShadeId;
  DateTime? fromDate;
  DateTime? toDate;
  bool loading = true;

  List<Map<String, dynamic>> _applyProductShadeFilters(
    List<Map<String, dynamic>> rows,
  ) {
    return rows.where((r) {
      final pid = r['productId'] as int?;
      final sid = r['shadeId'] as int?;
      if (selectedProductId != null && pid != selectedProductId) {
        return false;
      }
      if (selectedShadeId != null && sid != selectedShadeId) {
        return false;
      }
      return true;
    }).toList();
  }

  String _fmtDateChip(DateTime? date) {
    if (date == null) return 'Any';
    return DateFormat('dd-MM-yyyy').format(date);
  }

  Future<void> _pickFromDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: fromDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() => fromDate = d);
  }

  Future<void> _pickToDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: toDate ?? fromDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() => toDate = d);
  }

  Future<pw.ThemeData> _pdfTheme() async {
    try {
      final base = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      final italic = await PdfGoogleFonts.notoSansItalic();
      final boldItalic = await PdfGoogleFonts.notoSansBoldItalic();
      return pw.ThemeData.withFont(
        base: base,
        bold: bold,
        italic: italic,
        boldItalic: boldItalic,
      );
    } catch (_) {
      return pw.ThemeData.base();
    }
  }

  Future<void> _exportPdf(List<Map<String, dynamic>> filteredRows) async {
    if (filteredRows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No stock report data to export')),
      );
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());
    final logoBytes = (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final dateRange = '${_fmtDateChip(fromDate)} to ${_fmtDateChip(toDate)}';

    final grouped = _groupByProduct(filteredRows);
    final tableRows = filteredRows.map((r) {
      final bal = ((r['balance'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);
      return [
        (r['product'] ?? '-').toString(),
        (r['shade'] ?? '-').toString(),
        bal,
      ];
    }).toList();

    // Add total row
    final grandTotal = filteredRows.fold<double>(
      0,
      (sum, r) => sum + ((r['balance'] as num?)?.toDouble() ?? 0),
    );
    tableRows.add(['', 'TOTAL', grandTotal.toStringAsFixed(2)]);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (context) {
          final widgets = <pw.Widget>[
            pw.Center(
              child: pw.Image(logoImage, width: 80, height: 80),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Stock Ledger Report',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Generated: $now'),
            pw.Text('Date range: $dateRange'),
            pw.Text(
              'Product filter: ${selectedProductId == null ? 'All Products' : 'Applied'}',
            ),
            pw.Text(
              'Shade filter: ${selectedShadeId == null ? 'All Shades' : 'Applied'}',
            ),
            pw.SizedBox(height: 12),
          ];

          // Product-wise sections with totals
          for (final entry in grouped.entries) {
            final productName = entry.key;
            final rows = entry.value;
            final productTotal = rows.fold<double>(
              0,
              (sum, r) => sum + ((r['balance'] as num?)?.toDouble() ?? 0),
            );
            final shadeRows = rows
                .map((r) => [
                      (r['shade'] ?? '-').toString(),
                      ((r['balance'] as num?)?.toDouble() ?? 0)
                          .toStringAsFixed(2),
                    ])
                .toList();
            shadeRows.add(['TOTAL', productTotal.toStringAsFixed(2)]);

            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 12),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Product: $productName   |   Total Qty: ${productTotal.toStringAsFixed(2)}',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.SizedBox(height: 4),
                    pw.TableHelper.fromTextArray(
                      headers: const ['Shade', 'Balance'],
                      data: shadeRows,
                      headerStyle:
                          pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      cellAlignment: pw.Alignment.center,
                      cellAlignments: {
                        0: pw.Alignment.center,
                        1: pw.Alignment.center,
                      },
                      columnWidths: {
                        0: const pw.FlexColumnWidth(2),
                        1: const pw.FlexColumnWidth(1),
                      },
                    ),
                  ],
                ),
              ),
            );
          }

          // Grand total
          widgets.add(
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey200,
                border: pw.Border.all(color: PdfColors.grey400),
              ),
              child: pw.Text(
                'Grand Total Qty: ${grandTotal.toStringAsFixed(2)}',
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
                textAlign: pw.TextAlign.center,
              ),
            ),
          );

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) async => doc.save(),
      name: 'stock_ledger_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
  }

  List<Map<String, dynamic>> _buildBalanceSummaryRows() {
    final labelByKey = <String, Map<String, dynamic>>{};
    for (final r in ledger) {
      final pid = r['product_id'] is int
          ? r['product_id'] as int
          : int.tryParse('${r['product_id']}');
      final sid = r['fabric_shade_id'] is int
          ? r['fabric_shade_id'] as int
          : int.tryParse('${r['fabric_shade_id']}') ?? 0;
      if (pid == null) continue;
      final key = '${pid}_$sid';
      labelByKey[key] = {
        'productId': pid,
        'shadeId': sid,
        'product': (r['product_name'] ?? 'Product #$pid').toString(),
        'shade': (r['shade_no'] ?? (sid == 0 ? 'NO SHADE' : 'Shade #$sid'))
            .toString(),
      };
    }

    final rows = <Map<String, dynamic>>[];
    currentBalanceByKey.forEach((key, bal) {
      final parts = key.split('_');
      final pid = parts.isNotEmpty ? int.tryParse(parts[0]) : null;
      final sid = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (pid == null || sid == null) return;
      final labels = labelByKey[key];

      rows.add({
        'productId': pid,
        'shadeId': sid,
        'product': (labels?['product'] ?? 'Product #$pid').toString(),
        'shade': (labels?['shade'] ?? (sid == 0 ? 'NO SHADE' : 'Shade #$sid'))
            .toString(),
        'balance': bal,
      });
    });

    rows.sort((a, b) {
      final p = (a['product'] as String).compareTo(b['product'] as String);
      if (p != 0) return p;
      return (a['shade'] as String).compareTo(b['shade'] as String);
    });

    return rows;
  }

  Map<String, List<Map<String, dynamic>>> _groupByProduct(
    List<Map<String, dynamic>> rows,
  ) {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final product = (row['product'] ?? '-').toString();
      map.putIfAbsent(product, () => []);
      map[product]!.add(row);
    }
    return map;
  }

  Widget _shadeBalanceGrid(List<Map<String, dynamic>> rows) {
    return Table(
      border: TableBorder.all(color: Colors.black12),
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(1),
      },
      children: [
        const TableRow(
          decoration: BoxDecoration(color: Color(0xFFF3F4F6)),
          children: [
            Padding(
              padding: EdgeInsets.all(10),
              child: Text(
                'Shade No',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(10),
              child: Text(
                'Balance',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        ...rows.map((s) {
          final bal = (s['balance'] as num?)?.toDouble() ?? 0;
          final isZero = bal.abs() < 0.000001;
          return TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  (s['shade'] ?? '-').toString(),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  bal.toStringAsFixed(2),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isZero ? Colors.red : Colors.green.shade700,
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

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
    if (mounted) _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final db = await ErpDatabase.instance.database;

    final fromMs = fromDate == null
        ? null
        : DateTime(fromDate!.year, fromDate!.month, fromDate!.day)
            .millisecondsSinceEpoch;
    final toMs = toDate == null
        ? null
        : DateTime(toDate!.year, toDate!.month, toDate!.day, 23, 59, 59, 999)
            .millisecondsSinceEpoch;

    ledger = await db.rawQuery('''
      SELECT l.*, 
             p.name AS product_name,
             COALESCE(f.shade_no, 'NO SHADE') AS shade_no
      FROM stock_ledger l
      JOIN products p ON p.id = l.product_id
      LEFT JOIN fabric_shades f ON f.id = l.fabric_shade_id
      WHERE (? IS NULL OR l.date >= ?)
        AND (? IS NULL OR l.date <= ?)
        AND (l.fabric_shade_id IS NULL OR l.fabric_shade_id = 0 OR f.id IS NOT NULL)
      ORDER BY l.date DESC, l.id DESC
    ''', [
      fromMs,
      fromMs,
      toMs,
      toMs,
    ]);

    products = await db.query('products');
    shades = await db.query('fabric_shades');

    // Build running balance (chronological) and current balance
    final chrono = List<Map<String, dynamic>>.from(ledger)
      ..sort((a, b) {
        final da = (a['date'] as int?) ?? 0;
        final dbb = (b['date'] as int?) ?? 0;
        if (da != dbb) return da.compareTo(dbb);
        final ia = (a['id'] as int?) ?? 0;
        final ib = (b['id'] as int?) ?? 0;
        return ia.compareTo(ib);
      });

    final liveBal = <String, double>{};
    final runById = <int, double>{};

    for (final r in chrono) {
      final pid = r['product_id'] is int
          ? r['product_id'] as int
          : int.tryParse('${r['product_id']}');
      final sid = r['fabric_shade_id'] is int
          ? r['fabric_shade_id'] as int
          : int.tryParse('${r['fabric_shade_id']}') ?? 0;
      if (pid == null) continue;
      final key = '${pid}_$sid';
      final qty = ((r['qty'] as num?)?.toDouble() ?? 0);
      final signed =
          ((r['type'] ?? '').toString().toUpperCase() == 'OUT') ? -qty : qty;
      final next = (liveBal[key] ?? 0) + signed;
      liveBal[key] = next;

      final rowId = r['id'] as int?;
      if (rowId != null) {
        runById[rowId] = next;
      }
    }

    runningBalanceByRowId = runById;
    currentBalanceByKey = liveBal;

    if (mounted) {
      setState(() => loading = false);
    }
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    final summaryRows = _buildBalanceSummaryRows();
    final productFilterItems = {
      for (final r in summaryRows)
        if (r['productId'] is int)
          r['productId'] as int: (r['product'] ?? '').toString(),
    }.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final shadeFilterItems = {
      for (final r in summaryRows)
        if (r['shadeId'] is int &&
            (selectedProductId == null || r['productId'] == selectedProductId))
          r['shadeId'] as int: (r['shade'] ?? '').toString(),
    }.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final filteredRows = _applyProductShadeFilters(summaryRows);
    final grouped = _groupByProduct(filteredRows);
    final productTitle = selectedProductId == null
        ? 'All Products'
        : productFilterItems
                .cast<MapEntry<int, String>?>()
                .firstWhere(
                  (e) => e?.key == selectedProductId,
                  orElse: () => null,
                )
                ?.value ??
            'All Products';

    return Scaffold(
      appBar: AppBar(
        title: Text('Product Name: $productTitle'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: () => _exportPdf(filteredRows),
            icon: const Icon(Icons.picture_as_pdf),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.filter_alt_outlined, size: 18),
                            SizedBox(width: 6),
                            Text(
                              'Report Filters',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _pickFromDate,
                                icon: const Icon(Icons.date_range),
                                label: Text('From: ${_fmtDateChip(fromDate)}'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _pickToDate,
                                icon: const Icon(Icons.date_range),
                                label: Text('To: ${_fmtDateChip(toDate)}'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          value: selectedProductId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Product (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('All Products'),
                            ),
                            ...productFilterItems.map((p) {
                              return DropdownMenuItem<int?>(
                                value: p.key,
                                child: Text(p.value),
                              );
                            }),
                          ],
                          onChanged: (v) {
                            setState(() {
                              selectedProductId = v;
                              if (selectedShadeId != null) {
                                final found = summaryRows.any((r) {
                                  final sid = r['shadeId'] as int?;
                                  final pid = r['productId'] as int?;
                                  return sid == selectedShadeId &&
                                      (selectedProductId == null ||
                                          pid == selectedProductId);
                                });
                                if (!found) selectedShadeId = null;
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          value: selectedShadeId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Shade (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('All Shades'),
                            ),
                            ...shadeFilterItems.map((s) {
                              return DropdownMenuItem<int?>(
                                value: s.key,
                                child: Text(s.value),
                              );
                            }),
                          ],
                          onChanged: (v) => setState(() => selectedShadeId = v),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  setState(() {
                                    fromDate = null;
                                    toDate = null;
                                    selectedProductId = null;
                                    selectedShadeId = null;
                                  });
                                  _load();
                                },
                                child: const Text('Clear'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _load,
                                child: const Text('Apply'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: filteredRows.isEmpty
                      ? const Center(
                          child: Text('No product-wise balance data found'))
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 12),
                          children: grouped.entries.map((entry) {
                            final productName = entry.key;
                            final rows = entry.value;
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: ExpansionTile(
                                initiallyExpanded: selectedProductId != null,
                                title: Text(
                                  productName,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  'Shades: ${rows.length}  |  Total Qty: ${rows.fold<double>(0, (sum, r) => sum + ((r['balance'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2)}',
                                  textAlign: TextAlign.center,
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        12, 4, 12, 12),
                                    child: _shadeBalanceGrid(rows),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            ),
    );
  }
}
