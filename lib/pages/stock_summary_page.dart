import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../data/erp_database.dart';

enum StockSummaryReportMode { invoiceWise, productWise, both }

class StockSummaryPage extends StatefulWidget {
  const StockSummaryPage({super.key});

  @override
  State<StockSummaryPage> createState() => _StockSummaryPageState();
}

class _StockSummaryPageState extends State<StockSummaryPage> {
  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>> parties = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];

  int? selectedPartyId;
  int? selectedProductId;
  int? selectedShadeId;
  StockSummaryReportMode reportMode = StockSummaryReportMode.both;

  DateTime? fromDate;
  DateTime? toDate;
  bool loading = true;
  Timer? _reloadDebounce;
  int _loadVersion = 0;

  String _fmtDateChip(DateTime? d) {
    if (d == null) return 'Any';
    return DateFormat('dd-MM-yyyy').format(d);
  }

  String _fmtDayFromMs(int ms) {
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _partyNameById(int? id) {
    if (id == null) return 'All';
    final found = parties.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == id,
          orElse: () => null,
        );
    return (found?['name'] ?? 'All').toString();
  }

  String _productNameById(int? id) {
    if (id == null) return 'All';
    final found = products.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == id,
          orElse: () => null,
        );
    return (found?['name'] ?? 'All').toString();
  }

  String _shadeNoById(int? id) {
    if (id == null) return 'All';
    final found = shades.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == id,
          orElse: () => null,
        );
    return (found?['shade_no'] ?? 'All').toString();
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
  }

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
    final shouldShowLoader = showLoader || rows.isEmpty;
    if (mounted && shouldShowLoader) {
      setState(() => loading = true);
    }

    final db = await ErpDatabase.instance.database;

    final nextParties =
        await db.query('parties', columns: ['id', 'name'], orderBy: 'name');
    final nextProducts =
        await db.query('products', columns: ['id', 'name'], orderBy: 'name');
    final nextShades = await db.query(
      'fabric_shades',
      columns: ['id', 'shade_no'],
      orderBy: 'shade_no',
    );

    final fromMs = fromDate == null
        ? null
        : DateTime(fromDate!.year, fromDate!.month, fromDate!.day)
            .millisecondsSinceEpoch;
    final toMs = toDate == null
        ? null
        : DateTime(toDate!.year, toDate!.month, toDate!.day, 23, 59, 59, 999)
            .millisecondsSinceEpoch;

    final nextRows = await db.rawQuery('''
      SELECT
        pm.purchase_no,
        pm.purchase_date,
        pm.invoice_no,
        pm.party_id,
        COALESCE(pa.name, '-') AS party_name,
        pi.product_id,
        pi.shade_id,
        COALESCE(pr.name, '-') AS product_name,
        COALESCE(fs.shade_no, 'NO SHADE') AS shade_no,
        SUM(COALESCE(pi.qty, 0)) AS qty
      FROM purchase_master pm
      JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
      LEFT JOIN parties pa ON pa.id = pm.party_id
      LEFT JOIN products pr ON pr.id = pi.product_id
      LEFT JOIN fabric_shades fs ON fs.id = pi.shade_id
      WHERE (? IS NULL OR pm.purchase_date >= ?)
        AND (? IS NULL OR pm.purchase_date <= ?)
        AND (? IS NULL OR pm.party_id = ?)
        AND (? IS NULL OR pi.product_id = ?)
        AND (? IS NULL OR pi.shade_id = ?)
      GROUP BY
        pm.purchase_no,
        pm.purchase_date,
        pm.invoice_no,
        pm.party_id,
        pa.name,
        pi.product_id,
        pi.shade_id,
        pr.name,
        fs.shade_no
      ORDER BY pm.purchase_date DESC, pm.purchase_no DESC, pr.name, fs.shade_no
    ''', [
      fromMs,
      fromMs,
      toMs,
      toMs,
      selectedPartyId,
      selectedPartyId,
      selectedProductId,
      selectedProductId,
      selectedShadeId,
      selectedShadeId,
    ]);

    if (!mounted || loadVersion != _loadVersion) return;
    setState(() {
      parties = nextParties;
      products = nextProducts;
      shades = nextShades;
      rows = nextRows;
      loading = false;
    });
  }

  Future<void> _refresh() async {
    await _load(showLoader: true);
  }

  Future<void> _reloadForFilters() async {
    await _load(showLoader: rows.isEmpty);
  }

  List<Map<String, dynamic>> _buildDateWiseSections() {
    final byDate = <int, Map<String, dynamic>>{};

    for (final r in rows) {
      final dateMs = (r['purchase_date'] as int?) ?? 0;
      final d = DateTime.fromMillisecondsSinceEpoch(dateMs);
      final dayMs = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

      final dateBucket = byDate.putIfAbsent(
        dayMs,
        () => {
          'dayMs': dayMs,
          'entries': <String, Map<String, dynamic>>{},
        },
      );

      final purchaseNo = (r['purchase_no'] ?? '').toString();
      final productId = (r['product_id'] ?? '').toString();
      final entryKey = '$purchaseNo|$productId';

      final entries =
          dateBucket['entries'] as Map<String, Map<String, dynamic>>;
      final entry = entries.putIfAbsent(
        entryKey,
        () => {
          'purchaseNo': purchaseNo,
          'purchaseDate': dateMs,
          'invoiceNo': (r['invoice_no'] ?? '-').toString(),
          'partyName': (r['party_name'] ?? '-').toString(),
          'productName': (r['product_name'] ?? '-').toString(),
          'shadeQty': <String, double>{},
        },
      );

      final shadeNo = (r['shade_no'] ?? 'NO SHADE').toString();
      final qty = (r['qty'] as num?)?.toDouble() ?? 0;
      final shadeMap = entry['shadeQty'] as Map<String, double>;
      shadeMap[shadeNo] = (shadeMap[shadeNo] ?? 0) + qty;
    }

    final sections = byDate.values.toList();
    sections.sort((a, b) => (b['dayMs'] as int).compareTo(a['dayMs'] as int));

    for (final sec in sections) {
      final entriesMap =
          sec['entries'] as Map<String, Map<String, dynamic>>;
      // Drop zero-stock shades from each entry; drop entries that end up empty.
      entriesMap.removeWhere((_, e) {
        final shadeMap = e['shadeQty'] as Map<String, double>;
        shadeMap.removeWhere((_, v) => v.abs() <= 0.0001);
        return shadeMap.isEmpty;
      });
      final entries = entriesMap.values.toList();
      entries.sort((a, b) {
        final p =
            (a['partyName'] as String).compareTo(b['partyName'] as String);
        if (p != 0) return p;
        final pr =
            (a['productName'] as String).compareTo(b['productName'] as String);
        if (pr != 0) return pr;
        return (a['invoiceNo'] as String).compareTo(b['invoiceNo'] as String);
      });
      sec['entryList'] = entries;
    }

    // Drop date sections that have no remaining entries.
    sections.removeWhere((sec) => (sec['entryList'] as List).isEmpty);

    return sections;
  }

  List<Map<String, dynamic>> _buildProductWiseSections() {
    final map = <String, Map<String, dynamic>>{};

    for (final r in rows) {
      final product = (r['product_name'] ?? '-').toString();
      final shade = (r['shade_no'] ?? 'NO SHADE').toString();
      final qty = (r['qty'] as num?)?.toDouble() ?? 0;

      final bucket = map.putIfAbsent(
        product,
        () => {
          'productName': product,
          'shadeQty': <String, double>{},
          'totalQty': 0.0,
        },
      );

      final shadeMap = bucket['shadeQty'] as Map<String, double>;
      shadeMap[shade] = (shadeMap[shade] ?? 0) + qty;
      bucket['totalQty'] = (bucket['totalQty'] as double) + qty;
    }

    final sections = map.values.toList();
    // Drop zero-stock shades from each product; drop products with no remaining shades.
    for (final p in sections) {
      final shadeMap = p['shadeQty'] as Map<String, double>;
      shadeMap.removeWhere((_, v) => v.abs() <= 0.0001);
    }
    sections.removeWhere(
        (p) => (p['shadeQty'] as Map<String, double>).isEmpty);
    sections.sort(
      (a, b) =>
          (a['productName'] as String).compareTo(b['productName'] as String),
    );
    return sections;
  }

  Widget _shadeGrid(Map<String, double> shadeQty) {
    // Hide shades with zero (or negligible) stock.
    final shadeRows = shadeQty.entries
        .where((e) => e.value.abs() > 0.0001)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (shadeRows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'No stock available',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

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
              padding: EdgeInsets.all(8),
              child: Text(
                'Shade No',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Qty',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        ...shadeRows.map(
          (e) => TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(e.key, textAlign: TextAlign.center),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  e.value.toStringAsFixed(2),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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

  Future<void> _exportPdf() async {
    final invoiceSections = _buildDateWiseSections();
    final productSections = _buildProductWiseSections();

    if (invoiceSections.isEmpty && productSections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to export')),
      );
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (ctx) => pw.Column(children: [
          if (ctx.pageNumber == 1)
            pw.Center(child: pw.Image(logoImage, width: 50, height: 50)),
          pw.Text(
            'Stock Summary Purchase Report',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.Divider(thickness: 0.5),
        ]),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8)),
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[
            pw.Text('Generated: $now', style: const pw.TextStyle(fontSize: 8)),
            pw.Text(
              'Date filter: ${_fmtDateChip(fromDate)} to ${_fmtDateChip(toDate)}',
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.Text('Party filter: ${_partyNameById(selectedPartyId)}',
                style: const pw.TextStyle(fontSize: 8)),
            pw.Text('Product filter: ${_productNameById(selectedProductId)}',
                style: const pw.TextStyle(fontSize: 8)),
            pw.Text('Shade filter: ${_shadeNoById(selectedShadeId)}',
                style: const pw.TextStyle(fontSize: 8)),
            pw.SizedBox(height: 8),
          ];

          if (reportMode != StockSummaryReportMode.productWise) {
            widgets.add(
              pw.Text(
                'Invoice-wise Report',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            );

            for (final sec in invoiceSections) {
              final dayMs = sec['dayMs'] as int;
              final entries =
                  (sec['entryList'] as List).cast<Map<String, dynamic>>();

              widgets.add(
                pw.Container(
                  margin: const pw.EdgeInsets.only(top: 8, bottom: 6),
                  padding:
                      const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  color: PdfColors.grey200,
                  child: pw.Text(
                    'Date: ${_fmtDayFromMs(dayMs)}',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ),
              );

              for (final e in entries) {
                final shadeMap = (e['shadeQty'] as Map<String, double>);
                final tableData = shadeMap.entries
                    .where((s) => s.value.abs() > 0.0001)
                    .map((s) => [s.key, s.value.toStringAsFixed(2)])
                    .toList();
                if (tableData.isEmpty) continue;

                widgets.add(
                  pw.Container(
                    margin: const pw.EdgeInsets.only(top: 4, bottom: 8),
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey300),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                            'Date: ${_fmtDayFromMs(e['purchaseDate'] as int)}'),
                        pw.Text('Party: ${e['partyName']}'),
                        pw.Text('Product: ${e['productName']}'),
                        pw.Text('Invoice No: ${e['invoiceNo']}'),
                        pw.SizedBox(height: 6),
                        pw.TableHelper.fromTextArray(
                          headers: const ['Shade No', 'Qty'],
                          data: tableData,
                          headerStyle:
                              pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          cellAlignment: pw.Alignment.center,
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
            }
          }

          if (reportMode != StockSummaryReportMode.invoiceWise) {
            widgets.add(pw.SizedBox(height: 8));
            widgets.add(
              pw.Text(
                'Product-wise Merged Report',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            );

            for (final p in productSections) {
              final shadeMap = (p['shadeQty'] as Map<String, double>);
              final tableData = shadeMap.entries
                  .where((s) => s.value.abs() > 0.0001)
                  .map((s) => [s.key, s.value.toStringAsFixed(2)])
                  .toList();
              if (tableData.isEmpty) continue;

              widgets.add(
                pw.Container(
                  margin: const pw.EdgeInsets.only(top: 6, bottom: 8),
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey300),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Product: ${p['productName']}   Total Qty: ${(p['totalQty'] as double).toStringAsFixed(2)}',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 6),
                      pw.TableHelper.fromTextArray(
                        headers: const ['Shade No', 'Qty'],
                        data: tableData,
                        headerStyle:
                            pw.TextStyle(fontWeight: pw.FontWeight.bold),
                        cellAlignment: pw.Alignment.center,
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
          }

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) async => doc.save(),
      name:
          'stock_summary_purchase_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _buildDateWiseSections();
    final productSections = _buildProductWiseSections();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Summary'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: _exportPdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
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
                              'Date Filter',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Report Type',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('Invoice Wise'),
                              selected: reportMode ==
                                  StockSummaryReportMode.invoiceWise,
                              onSelected: (_) {
                                setState(
                                  () => reportMode =
                                      StockSummaryReportMode.invoiceWise,
                                );
                              },
                            ),
                            ChoiceChip(
                              label: const Text('Product Wise'),
                              selected: reportMode ==
                                  StockSummaryReportMode.productWise,
                              onSelected: (_) {
                                setState(
                                  () => reportMode =
                                      StockSummaryReportMode.productWise,
                                );
                              },
                            ),
                            ChoiceChip(
                              label: const Text('Both'),
                              selected:
                                  reportMode == StockSummaryReportMode.both,
                              onSelected: (_) {
                                setState(
                                  () =>
                                      reportMode = StockSummaryReportMode.both,
                                );
                              },
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
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int?>(
                          initialValue: selectedPartyId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Party (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('All Parties'),
                            ),
                            ...parties.map(
                              (p) => DropdownMenuItem<int?>(
                                value: p['id'] as int,
                                child: Text((p['name'] ?? '-').toString()),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => selectedPartyId = v),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          initialValue: selectedProductId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Product (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('All Products'),
                            ),
                            ...products.map(
                              (p) => DropdownMenuItem<int?>(
                                value: p['id'] as int,
                                child: Text((p['name'] ?? '-').toString()),
                              ),
                            ),
                          ],
                          onChanged: (v) =>
                              setState(() => selectedProductId = v),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          initialValue: selectedShadeId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Shade (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('All Shades'),
                            ),
                            ...shades.map(
                              (s) => DropdownMenuItem<int?>(
                                value: s['id'] as int,
                                child: Text((s['shade_no'] ?? '-').toString()),
                              ),
                            ),
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
                                    selectedPartyId = null;
                                    selectedProductId = null;
                                    selectedShadeId = null;
                                    reportMode = StockSummaryReportMode.both;
                                  });
                                  _reloadForFilters();
                                },
                                child: const Text('Clear'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _reloadForFilters,
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
                  child: (sections.isEmpty && productSections.isEmpty)
                      ? const Center(
                          child: Text('No purchase report data found'))
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 12),
                          children: [
                            if (reportMode == StockSummaryReportMode.both)
                              const Padding(
                                padding: EdgeInsets.fromLTRB(12, 8, 12, 2),
                                child: Text(
                                  'Invoice-wise Section',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            if (reportMode !=
                                StockSummaryReportMode.productWise)
                              ...sections.map((sec) {
                                final dayMs = sec['dayMs'] as int;
                                final entries = (sec['entryList'] as List)
                                    .cast<Map<String, dynamic>>();

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Date: ${_fmtDayFromMs(dayMs)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        ...entries.map((e) {
                                          final shadeMap = (e['shadeQty']
                                              as Map<String, double>);

                                          return Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 10),
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                  color: Colors.black12),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  'Date: ${_fmtDayFromMs(e['purchaseDate'] as int)}',
                                                ),
                                                Text(
                                                  'Party: ${e['partyName']}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                Text(
                                                    'Product: ${e['productName']}'),
                                                Text(
                                                    'Invoice No: ${e['invoiceNo']}'),
                                                const SizedBox(height: 8),
                                                _shadeGrid(shadeMap),
                                              ],
                                            ),
                                          );
                                        }),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            if (reportMode == StockSummaryReportMode.both)
                              const Padding(
                                padding: EdgeInsets.fromLTRB(12, 10, 12, 2),
                                child: Text(
                                  'Product-wise Merged Section',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            if (reportMode !=
                                StockSummaryReportMode.invoiceWise)
                              ...productSections.map((p) {
                                final shadeMap =
                                    (p['shadeQty'] as Map<String, double>);
                                final totalQty = (p['totalQty'] as double);

                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Product: ${p['productName']}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                                        Text(
                                          'Total Qty: ${totalQty.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                        const SizedBox(height: 8),
                                        _shadeGrid(shadeMap),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
