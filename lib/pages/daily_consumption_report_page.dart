// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class DailyConsumptionReportPage extends StatefulWidget {
  const DailyConsumptionReportPage({super.key});

  @override
  State<DailyConsumptionReportPage> createState() =>
      _DailyConsumptionReportPageState();
}

class _DailyConsumptionReportPageState
    extends State<DailyConsumptionReportPage> {
  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> filteredRows = [];

  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];

  DateTime? fromDate;
  DateTime? toDate;
  int? selectedProductId;
  int? selectedShadeId;
  bool loading = true;
  bool reportGenerated = false;

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
    final db = await ErpDatabase.instance.database;

    // Only OUT entries = consumption
    final nextRows = await db.rawQuery('''
      SELECT
        sl.id,
        sl.date,
        sl.reference,
        sl.remarks,
        sl.qty,
        sl.product_id,
        sl.fabric_shade_id,
        p.name AS product_name,
        COALESCE(p.unit, 'Mtr') AS product_unit,
        fs.shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      WHERE sl.type = 'OUT'
      ORDER BY sl.date DESC, sl.id DESC
    ''');

    final nextProducts = await db.query(
      'products',
      columns: ['id', 'name'],
      orderBy: 'name',
    );

    final nextShades = await db.query(
      'fabric_shades',
      columns: ['id', 'shade_no', 'shade_name'],
      orderBy: 'shade_no',
    );

    if (!mounted) return;

    setState(() {
      allRows = nextRows;
      products = nextProducts;
      shades = nextShades;
      loading = false;
    });

    _applyFilters();
  }

  // ---- helpers ----

  Map<String, String> _parseRemarks(String? remarks) {
    final map = <String, String>{};
    final text = (remarks ?? '').trim();
    if (text.isEmpty) return map;
    final parts = text.split('|');
    for (final part in parts) {
      final seg = part.trim();
      final idx = seg.indexOf(':');
      if (idx <= 0) continue;
      map[seg.substring(0, idx).trim()] = seg.substring(idx + 1).trim();
    }
    return map;
  }

  String _remarkValue(Map<String, String> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null && v.trim().isNotEmpty) return v;
      final alt = map.entries.firstWhere(
        (e) => e.key.trim().toLowerCase() == k.trim().toLowerCase(),
        orElse: () => const MapEntry('', ''),
      );
      if (alt.value.trim().isNotEmpty) return alt.value;
    }
    return '-';
  }

  String _productNameById(int? id) {
    if (id == null) return '';
    final f = products.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == id,
          orElse: () => null,
        );
    return (f?['name'] ?? '').toString();
  }

  String _shadeNoById(int? id) {
    if (id == null) return '';
    final f = shades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == id,
          orElse: () => null,
        );
    return (f?['shade_no'] ?? '').toString();
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
      return true;
    }).toList();

    setState(() => filteredRows = rows);
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _fmtDateChip(DateTime? d) {
    if (d == null) return 'Any';
    return DateFormat('dd-MM-yyyy').format(d);
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
      reportGenerated = false;
    });
  }

  void _showReport() {
    _applyFilters();
    setState(() => reportGenerated = true);
  }

  // ---- build data: date → shade → qty ----

  /// Returns list of day groups sorted newest first.
  /// Each: { dayMs, dayLabel, shades: [ {shade_no, qty, rows: [...]} ], totalQty }
  List<Map<String, dynamic>> _buildDailyShadeGroups() {
    // group by day → shade
    final dayMap = <int, Map<String, Map<String, dynamic>>>{};

    for (final row in filteredRows) {
      final ms = row['date'] as int?;
      if (ms == null) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final dayMs = DateTime(dt.year, dt.month, dt.day).millisecondsSinceEpoch;
      final shadeNo = (row['shade_no'] ?? '-').toString();
      final qty = (row['qty'] as num?)?.toDouble() ?? 0;

      final shadeMap = dayMap.putIfAbsent(dayMs, () => {});
      final bucket = shadeMap.putIfAbsent(
          shadeNo,
          () => {
                'shade_no': shadeNo,
                'qty': 0.0,
                'rows': <Map<String, dynamic>>[],
              });
      bucket['qty'] = (bucket['qty'] as double) + qty;
      (bucket['rows'] as List<Map<String, dynamic>>).add(row);
    }

    final dayKeys = dayMap.keys.toList()..sort((a, b) => b.compareTo(a));

    return dayKeys.map((dayMs) {
      final shadeMap = dayMap[dayMs]!;
      final shadeList = shadeMap.values.toList();
      // sort shades numerically
      shadeList.sort((a, b) {
        final aNum = int.tryParse(a['shade_no'].toString()) ?? 999999;
        final bNum = int.tryParse(b['shade_no'].toString()) ?? 999999;
        return aNum.compareTo(bNum);
      });
      final totalQty =
          shadeList.fold<double>(0, (s, g) => s + (g['qty'] as double));
      return {
        'dayMs': dayMs,
        'dayLabel': _fmtDate(dayMs),
        'shades': shadeList,
        'totalQty': totalQty,
      };
    }).toList();
  }

  // ---- PDF ----

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
    final productText = selectedProductId == null
        ? 'All Products'
        : _productNameById(selectedProductId);
    final shadeText =
        selectedShadeId == null ? 'All Shades' : _shadeNoById(selectedShadeId);

    final days = _buildDailyShadeGroups();
    final grandTotal =
        days.fold<double>(0, (s, d) => s + (d['totalQty'] as double));

    // Determine unit
    String unit = 'Mtr';
    for (final row in filteredRows) {
      final u = (row['product_unit'] ?? '').toString();
      if (u.isNotEmpty) {
        unit = u;
        break;
      }
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) {
          final widgets = <pw.Widget>[
            pw.Center(child: pw.Image(logoImage, width: 80, height: 80)),
            pw.SizedBox(height: 8),
            pw.Text(
              'Daily Consumption Report (Shade Wise)',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Generated: $now'),
            pw.Text('Date range: $fromText to $toText'),
            pw.Text('Product: $productText  |  Shade: $shadeText'),
            pw.Text(
              'Grand Total Consumption: ${grandTotal.toStringAsFixed(2)} $unit',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
          ];

          for (final day in days) {
            final dayLabel = day['dayLabel'] as String;
            final shadeList = day['shades'] as List<Map<String, dynamic>>;
            final dayTotal = (day['totalQty'] as double);

            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: PdfColors.grey200,
                child: pw.Text(
                  'Date: $dayLabel   |   Total: ${dayTotal.toStringAsFixed(2)} $unit',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ),
            );

            final tableData = <List<String>>[];
            for (final sg in shadeList) {
              final shadeNo = sg['shade_no'].toString();
              final rows = sg['rows'] as List<Map<String, dynamic>>;
              for (final r in rows) {
                final parsed = _parseRemarks(r['remarks']?.toString());
                final party = _remarkValue(parsed, ['Party']);
                final chNo = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
                final product = (r['product_name'] ?? '-').toString();
                final qty =
                    ((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);
                tableData.add([shadeNo, product, party, chNo, qty]);
              }
            }

            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: const [
                  'Shade',
                  'Product',
                  'Party',
                  'Challan No',
                  'Qty'
                ],
                data: tableData,
                headerStyle:
                    pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                cellStyle: const pw.TextStyle(fontSize: 9),
                cellAlignment: pw.Alignment.centerLeft,
                headerAlignment: pw.Alignment.centerLeft,
                cellPadding:
                    const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(1.8),
                  2: const pw.FlexColumnWidth(2),
                  3: const pw.FlexColumnWidth(1.2),
                  4: const pw.FlexColumnWidth(1),
                },
              ),
            );
          }

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name: 'daily_consumption_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Consumption Report'),
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
          : Column(
              children: [
                // Filters
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white,
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  await _pickFromDate();
                                  setState(() => reportGenerated = false);
                                },
                                icon: const Icon(Icons.date_range),
                                label: Text('From: ${_fmtDateChip(fromDate)}'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  await _pickToDate();
                                  setState(() => reportGenerated = false);
                                },
                                icon: const Icon(Icons.date_range),
                                label: Text('To: ${_fmtDateChip(toDate)}'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int?>(
                                value: selectedProductId,
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
                                      child: Text((p['name'] ?? '').toString()),
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
                              child: DropdownButtonFormField<int?>(
                                value: selectedShadeId,
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
                                      child: Text(
                                          (s['shade_no'] ?? '').toString()),
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
                            ),
                          ],
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
                ),
                // Results
                Expanded(
                  child: !reportGenerated
                      ? const Center(
                          child: Text('Select filters and tap Show Report'),
                        )
                      : _buildReportBody(),
                ),
              ],
            ),
    );
  }

  Widget _buildReportBody() {
    final days = _buildDailyShadeGroups();
    if (days.isEmpty) {
      return const Center(child: Text('No consumption entries found'));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: days.length,
      itemBuilder: (context, index) {
        final day = days[index];
        final dayLabel = day['dayLabel'] as String;
        final shadeList = day['shades'] as List<Map<String, dynamic>>;
        final dayTotal = (day['totalQty'] as double);

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            title: Text(
              dayLabel,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            subtitle: Text(
              'Total: ${dayTotal.toStringAsFixed(2)}  |  Shades: ${shadeList.length}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
            children: [
              for (final sg in shadeList) ...[
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Colors.orange.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Shade: ${sg['shade_no']}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        'Qty: ${(sg['qty'] as double).toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 34,
                    dataRowMinHeight: 30,
                    dataRowMaxHeight: 38,
                    columns: const [
                      DataColumn(label: Text('Product')),
                      DataColumn(label: Text('Party')),
                      DataColumn(label: Text('Ch No')),
                      DataColumn(label: Text('Qty')),
                    ],
                    rows: (sg['rows'] as List<Map<String, dynamic>>).map((r) {
                      final product = (r['product_name'] ?? '-').toString();
                      final parsed = _parseRemarks(r['remarks']?.toString());
                      final party = _remarkValue(parsed, ['Party']);
                      final chNo =
                          _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
                      final qty = ((r['qty'] as num?)?.toDouble() ?? 0)
                          .toStringAsFixed(2);
                      return DataRow(cells: [
                        DataCell(Text(product,
                            style: const TextStyle(fontSize: 12))),
                        DataCell(
                            Text(party, style: const TextStyle(fontSize: 12))),
                        DataCell(
                            Text(chNo, style: const TextStyle(fontSize: 12))),
                        DataCell(
                            Text(qty, style: const TextStyle(fontSize: 12))),
                      ]);
                    }).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
