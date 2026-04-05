// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class ShadeMovementReportPage extends StatefulWidget {
  const ShadeMovementReportPage({super.key});

  @override
  State<ShadeMovementReportPage> createState() =>
      _ShadeMovementReportPageState();
}

class _ShadeMovementReportPageState extends State<ShadeMovementReportPage> {
  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> filteredRows = [];

  List<Map<String, dynamic>> parties = [];
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

    final nextRows = await db.rawQuery('''
      SELECT
        sl.id,
        sl.date,
        sl.reference,
        sl.remarks,
        sl.qty,
        sl.type,
        sl.product_id,
        sl.fabric_shade_id,
        p.name AS product_name,
        COALESCE(p.unit, 'Mtr') AS product_unit,
        fs.shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      ORDER BY sl.date DESC, sl.id DESC
    ''');

    final nextParties = await db.query(
      'parties',
      columns: ['id', 'name'],
      orderBy: 'name',
    );

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
      parties = nextParties;
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
      final key = seg.substring(0, idx).trim();
      final value = seg.substring(idx + 1).trim();
      map[key] = value;
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

  String _productNameById(int? productId) {
    if (productId == null) return '';
    final found = products.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == productId,
          orElse: () => null,
        );
    return (found?['name'] ?? '').toString();
  }

  String _shadeNoById(int? shadeId) {
    if (shadeId == null) return '';
    final found = shades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == shadeId,
          orElse: () => null,
        );
    return (found?['shade_no'] ?? '').toString();
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

    setState(() {
      filteredRows = rows;
    });
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
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: fromDate ?? now,
    );
    if (d == null) return;
    setState(() => fromDate = d);
    _applyFilters();
  }

  Future<void> _pickToDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: toDate ?? fromDate ?? now,
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
    setState(() {
      reportGenerated = true;
    });
  }

  // ---- build grouped data by shade ----

  /// Returns a list of shade groups. Each group has:
  /// shade_no, inRows, outRows, totalIn, totalOut
  List<Map<String, dynamic>> _buildShadeGroups() {
    final groupMap = <String, Map<String, dynamic>>{};

    for (final row in filteredRows) {
      final shadeNo = (row['shade_no'] ?? '-').toString();
      final type = (row['type'] ?? '').toString();
      final qty = (row['qty'] as num?)?.toDouble() ?? 0;

      final group = groupMap.putIfAbsent(
          shadeNo,
          () => {
                'shade_no': shadeNo,
                'inRows': <Map<String, dynamic>>[],
                'outRows': <Map<String, dynamic>>[],
                'totalIn': 0.0,
                'totalOut': 0.0,
              });

      if (type == 'IN') {
        (group['inRows'] as List<Map<String, dynamic>>).add(row);
        group['totalIn'] = (group['totalIn'] as double) + qty;
      } else if (type == 'OUT') {
        (group['outRows'] as List<Map<String, dynamic>>).add(row);
        group['totalOut'] = (group['totalOut'] as double) + qty;
      }
    }

    final groups = groupMap.values.toList();
    groups.sort((a, b) {
      final aNum = int.tryParse(a['shade_no'].toString()) ?? 999999;
      final bNum = int.tryParse(b['shade_no'].toString()) ?? 999999;
      return aNum.compareTo(bNum);
    });
    return groups;
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

    final groups = _buildShadeGroups();

    final totalIn =
        groups.fold<double>(0, (s, g) => s + (g['totalIn'] as double));
    final totalOut =
        groups.fold<double>(0, (s, g) => s + (g['totalOut'] as double));

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
              'Shade Movement Report',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Generated: $now'),
            pw.Text('Date range: $fromText to $toText'),
            pw.Text('Product: $productText  |  Shade: $shadeText'),
            pw.Text(
              'Total Inward: ${totalIn.toStringAsFixed(2)} $unit  |  '
              'Total Outward: ${totalOut.toStringAsFixed(2)} $unit',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
          ];

          for (final g in groups) {
            final shadeNo = g['shade_no'].toString();
            final inRows = (g['inRows'] as List<Map<String, dynamic>>);
            final outRows = (g['outRows'] as List<Map<String, dynamic>>);
            final gTotalIn = (g['totalIn'] as double);
            final gTotalOut = (g['totalOut'] as double);

            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 10, bottom: 6),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: PdfColors.grey200,
                child: pw.Text(
                  'Shade: $shadeNo   |   Inward: ${gTotalIn.toStringAsFixed(2)} $unit   |   Outward: ${gTotalOut.toStringAsFixed(2)} $unit',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ),
            );

            // Inward table
            if (inRows.isNotEmpty) {
              widgets.add(pw.Text('  Inward (Purchase)',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 10)));
              final inData = inRows.map((r) {
                final product = (r['product_name'] ?? '-').toString();
                final ref = (r['reference'] ?? '-').toString();
                final qty =
                    ((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);
                final date = _fmtDate(r['date'] as int?);
                return [date, product, ref, qty];
              }).toList();

              widgets.add(
                pw.TableHelper.fromTextArray(
                  headers: const ['Date', 'Product', 'Invoice / Ref', 'Qty'],
                  data: inData,
                  headerStyle:
                      pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                  cellStyle: const pw.TextStyle(fontSize: 9),
                  cellAlignment: pw.Alignment.centerLeft,
                  headerAlignment: pw.Alignment.centerLeft,
                  cellPadding:
                      const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  columnWidths: {
                    0: const pw.FlexColumnWidth(1.5),
                    1: const pw.FlexColumnWidth(2),
                    2: const pw.FlexColumnWidth(2),
                    3: const pw.FlexColumnWidth(1),
                  },
                ),
              );
            }

            // Outward table
            if (outRows.isNotEmpty) {
              widgets.add(pw.SizedBox(height: 4));
              widgets.add(pw.Text('  Outward (Issue)',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, fontSize: 10)));
              final outData = outRows.map((r) {
                final parsed = _parseRemarks(r['remarks']?.toString());
                final party = _remarkValue(parsed, ['Party']);
                final chNo = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
                final product = (r['product_name'] ?? '-').toString();
                final qty =
                    ((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);
                final date = _fmtDate(r['date'] as int?);
                return [date, product, party, chNo, qty];
              }).toList();

              widgets.add(
                pw.TableHelper.fromTextArray(
                  headers: const [
                    'Date',
                    'Product',
                    'Party',
                    'Challan No',
                    'Qty'
                  ],
                  data: outData,
                  headerStyle:
                      pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
                  cellStyle: const pw.TextStyle(fontSize: 9),
                  cellAlignment: pw.Alignment.centerLeft,
                  headerAlignment: pw.Alignment.centerLeft,
                  cellPadding:
                      const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  columnWidths: {
                    0: const pw.FlexColumnWidth(1.5),
                    1: const pw.FlexColumnWidth(1.8),
                    2: const pw.FlexColumnWidth(2),
                    3: const pw.FlexColumnWidth(1.2),
                    4: const pw.FlexColumnWidth(1),
                  },
                ),
              );
            }

            widgets.add(pw.SizedBox(height: 6));
          }

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name:
          'shade_movement_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  // ---- build UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shade Movement Report'),
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
    final groups = _buildShadeGroups();
    if (groups.isEmpty) {
      return const Center(child: Text('No entries found'));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final g = groups[index];
        final shadeNo = g['shade_no'].toString();
        final inRows = (g['inRows'] as List<Map<String, dynamic>>);
        final outRows = (g['outRows'] as List<Map<String, dynamic>>);
        final totalIn = (g['totalIn'] as double);
        final totalOut = (g['totalOut'] as double);

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            title: Text(
              'Shade: $shadeNo',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            subtitle: Text(
              'In: ${totalIn.toStringAsFixed(2)}  |  Out: ${totalOut.toStringAsFixed(2)}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
            children: [
              if (inRows.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Colors.green.shade50,
                  child: const Text(
                    'Inward (Purchase)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Product')),
                      DataColumn(label: Text('Invoice/Ref')),
                      DataColumn(label: Text('Qty')),
                    ],
                    rows: inRows.map((r) {
                      final date = _fmtDate(r['date'] as int?);
                      final product = (r['product_name'] ?? '-').toString();
                      final ref = (r['reference'] ?? '-').toString();
                      final qty = ((r['qty'] as num?)?.toDouble() ?? 0)
                          .toStringAsFixed(2);
                      return DataRow(cells: [
                        DataCell(
                            Text(date, style: const TextStyle(fontSize: 12))),
                        DataCell(Text(product,
                            style: const TextStyle(fontSize: 12))),
                        DataCell(
                            Text(ref, style: const TextStyle(fontSize: 12))),
                        DataCell(
                            Text(qty, style: const TextStyle(fontSize: 12))),
                      ]);
                    }).toList(),
                  ),
                ),
              ],
              if (outRows.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Colors.red.shade50,
                  child: const Text(
                    'Outward (Issue)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Product')),
                      DataColumn(label: Text('Party')),
                      DataColumn(label: Text('Ch No')),
                      DataColumn(label: Text('Qty')),
                    ],
                    rows: outRows.map((r) {
                      final date = _fmtDate(r['date'] as int?);
                      final product = (r['product_name'] ?? '-').toString();
                      final parsed = _parseRemarks(r['remarks']?.toString());
                      final party = _remarkValue(parsed, ['Party']);
                      final chNo =
                          _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
                      final qty = ((r['qty'] as num?)?.toDouble() ?? 0)
                          .toStringAsFixed(2);
                      return DataRow(cells: [
                        DataCell(
                            Text(date, style: const TextStyle(fontSize: 12))),
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
              if (inRows.isEmpty && outRows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No entries for this shade'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
