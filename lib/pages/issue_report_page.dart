import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class IssueReportPage extends StatefulWidget {
  const IssueReportPage({super.key});

  @override
  State<IssueReportPage> createState() => _IssueReportPageState();
}

class _IssueReportPageState extends State<IssueReportPage> {
  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> filteredRows = [];
  List<Map<String, dynamic>> reportGridRows = [];

  List<Map<String, dynamic>> parties = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];

  DateTime? fromDate;
  DateTime? toDate;
  int? selectedPartyId;
  int? selectedProductId;
  String? selectedChNo;
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
        sl.date,
        sl.reference,
        sl.remarks,
        sl.qty,
        sl.product_id,
        sl.fabric_shade_id,
        p.name AS product_name,
        fs.shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      WHERE sl.type = 'OUT'
        AND (sl.is_deleted IS NULL OR sl.is_deleted = 0)
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

    if (!mounted || loadVersion != _loadVersion) return;

    setState(() {
      allRows = nextRows;
      parties = nextParties;
      products = nextProducts;
      shades = nextShades;
      loading = false;
    });

    _applyFilters();
  }

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

  String _partyNameById(int? partyId) {
    if (partyId == null) return '';
    final found = parties.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == partyId,
          orElse: () => null,
        );
    return (found?['name'] ?? '').toString();
  }

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

      final parsed = _parseRemarks(row['remarks']?.toString());
      final partyName = _remarkValue(parsed, ['Party']);
      final chNo = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);

      if (selectedPartyId != null) {
        final selectedName =
            _partyNameById(selectedPartyId).trim().toLowerCase();
        final rowParty = partyName.trim().toLowerCase();
        if (selectedName.isEmpty || rowParty != selectedName) return false;
      }

      if (selectedChNo != null && selectedChNo!.trim().isNotEmpty) {
        if (chNo.trim().toLowerCase() != selectedChNo!.trim().toLowerCase()) {
          return false;
        }
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
      selectedPartyId = null;
      selectedProductId = null;
      selectedChNo = null;
      reportGenerated = false;
      reportGridRows = [];
    });
  }

  List<String> _availableChNos() {
    final set = <String>{};
    for (final row in allRows) {
      final parsed = _parseRemarks(row['remarks']?.toString());
      final chNo = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']).trim();
      if (chNo.isEmpty || chNo == '-') continue;
      set.add(chNo);
    }
    final list = set.toList()..sort((a, b) => a.compareTo(b));
    return list;
  }

  String _productNameById(int? productId) {
    if (productId == null) return '';
    final found = products.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == productId,
          orElse: () => null,
        );
    return (found?['name'] ?? '').toString();
  }

  String _activeFilterSummary() {
    final party =
        selectedPartyId == null ? 'All' : _partyNameById(selectedPartyId);
    final product =
        selectedProductId == null ? 'All' : _productNameById(selectedProductId);
    final chNo = (selectedChNo ?? '').trim().isEmpty ? 'All' : selectedChNo!;
    return 'Party: $party | Product: $product | Ch No: $chNo';
  }

  String _reportPartyHeader() {
    final name = _partyNameById(selectedPartyId).trim();
    return name.isEmpty ? 'All Parties' : name;
  }

  String _reportProductHeader() {
    final name = _productNameById(selectedProductId).trim();
    return name.isEmpty ? 'All Products' : name;
  }

  List<Map<String, dynamic>> _buildReportGridRows() {
    final grouped = <String, Map<String, dynamic>>{};

    for (final row in filteredRows) {
      final parsed = _parseRemarks(row['remarks']?.toString());
      final chNo = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
      final shadeNo = (row['shade_no'] ?? '-').toString();
      final qty = (row['qty'] as num?)?.toDouble() ?? 0;

      final key = '$chNo|$shadeNo';

      final bucket = grouped.putIfAbsent(
        key,
        () => {
          'chNo': chNo,
          'shadeNo': shadeNo,
          'qty': 0.0,
        },
      );
      bucket['qty'] = (bucket['qty'] as double) + qty;
    }

    final rows = grouped.values.toList();
    rows.sort((a, b) {
      final c1 = (a['chNo'] as String).compareTo(b['chNo'] as String);
      if (c1 != 0) return c1;
      final c2 = (a['shadeNo'] as String).compareTo(b['shadeNo'] as String);
      if (c2 != 0) return c2;
      return 0;
    });

    return rows;
  }

  void _showReport() {
    _applyFilters();
    setState(() {
      reportGenerated = true;
      reportGridRows = _buildReportGridRows();
    });
  }

  List<Map<String, dynamic>> _groupByDate() {
    final grouped = <int, List<Map<String, dynamic>>>{};

    for (final row in filteredRows) {
      final ms = row['date'] as int?;
      if (ms == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      final dayMs = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
      grouped.putIfAbsent(dayMs, () => <Map<String, dynamic>>[]).add(row);
    }

    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return keys.map((k) {
      final rows = grouped[k]!;
      final totalQty = rows.fold<double>(
        0,
        (sum, r) => sum + ((r['qty'] as num?)?.toDouble() ?? 0),
      );
      return {
        'dayMs': k,
        'rows': rows,
        'count': rows.length,
        'totalQty': totalQty,
      };
    }).toList();
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
    if (filteredRows.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No issue entries to export')),
      );
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);
    final grouped = _groupByDate();
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final fromText =
        fromDate == null ? 'Any' : DateFormat('dd-MM-yyyy').format(fromDate!);
    final toText =
        toDate == null ? 'Any' : DateFormat('dd-MM-yyyy').format(toDate!);
    final totalQty = filteredRows.fold<double>(
      0,
      (sum, r) => sum + ((r['qty'] as num?)?.toDouble() ?? 0),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
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
                pw.Text('Issue Report',
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
            pw.Text('Date: $fromText to $toText  |  ${_activeFilterSummary()}',
                style: const pw.TextStyle(fontSize: 9)),
            pw.Text(
              'Total rows: ${filteredRows.length}  |  Total qty: ${totalQty.toStringAsFixed(2)} mtr',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
          ];

          for (final g in grouped) {
            final dayMs = g['dayMs'] as int;
            final dayRows = (g['rows'] as List).cast<Map<String, dynamic>>();
            final dayCount = g['count'] as int;
            final dayQty = g['totalQty'] as double;

            final data = dayRows.map((row) {
              final remarks = _parseRemarks(row['remarks']?.toString());
              final party = _remarkValue(remarks, ['Party']);
              final chNo = _remarkValue(remarks, ['ChNo', 'Ch No', 'Ch']);
              final product = (row['product_name'] ?? '-').toString();
              final shade = (row['shade_no'] ?? '-').toString();
              final qty =
                  ((row['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);

              return [party, chNo, product, shade, qty];
            }).toList();

            widgets.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 10, bottom: 6),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: PdfColors.grey200,
                child: pw.Text(
                  'Date: ${_fmtDate(dayMs)}   Rows: $dayCount   Qty: ${dayQty.toStringAsFixed(2)} mtr',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ),
            );

            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: const ['Party', 'Ch No', 'Product', 'Shade', 'Qty'],
                data: data,
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                cellAlignment: pw.Alignment.centerLeft,
                headerAlignment: pw.Alignment.centerLeft,
                cellPadding:
                    const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                columnWidths: {
                  0: const pw.FlexColumnWidth(2.2),
                  1: const pw.FlexColumnWidth(1.2),
                  2: const pw.FlexColumnWidth(1.8),
                  3: const pw.FlexColumnWidth(1.5),
                  4: const pw.FlexColumnWidth(0.9),
                },
              ),
            );
          }

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name: 'issue_report_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chNoOptions = _availableChNos();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Issue Report'),
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
                                  if (!mounted) return;
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
                                  if (!mounted) return;
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
                                initialValue: selectedPartyId,
                                decoration: const InputDecoration(
                                  labelText: 'Party Filter',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                isExpanded: true,
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text('All Parties'),
                                  ),
                                  ...parties.map(
                                    (p) => DropdownMenuItem<int?>(
                                      value: p['id'] as int,
                                      child: Text((p['name'] ?? '').toString()),
                                    ),
                                  ),
                                ],
                                onChanged: (v) {
                                  setState(() {
                                    selectedPartyId = v;
                                    reportGenerated = false;
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: selectedProductId,
                                decoration: const InputDecoration(
                                  labelText: 'Product Filter',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                isExpanded: true,
                                items: products
                                    .map(
                                      (p) => DropdownMenuItem<int>(
                                        value: p['id'] as int,
                                        child:
                                            Text((p['name'] ?? '').toString()),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() {
                                    selectedProductId = v;
                                    reportGenerated = false;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String?>(
                          initialValue: selectedChNo,
                          decoration: const InputDecoration(
                            labelText: 'Ch No Filter',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('All Ch No'),
                            ),
                            ...chNoOptions.map(
                              (ch) => DropdownMenuItem<String?>(
                                value: ch,
                                child: Text(ch),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() {
                              selectedChNo = v;
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
                ),
                Expanded(
                  child: !reportGenerated
                      ? const Center(
                          child: Text('Select filters and tap Show Report'),
                        )
                      : reportGridRows.isEmpty
                          ? const Center(child: Text('No issue entries found'))
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.black12),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'Party: ${_reportPartyHeader()}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            'Product: ${_reportProductHeader()}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                            textAlign: TextAlign.end,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SingleChildScrollView(
                                      child: DataTable(
                                        columns: const [
                                          DataColumn(label: Text('Ch No')),
                                          DataColumn(label: Text('Shade No')),
                                          DataColumn(label: Text('Qty')),
                                        ],
                                        rows: reportGridRows.map((r) {
                                          final qty =
                                              ((r['qty'] as num?)?.toDouble() ??
                                                      0)
                                                  .toStringAsFixed(2);

                                          return DataRow(
                                            cells: [
                                              DataCell(Text((r['chNo'] ?? '-')
                                                  .toString())),
                                              DataCell(Text(
                                                  (r['shadeNo'] ?? '-')
                                                      .toString())),
                                              DataCell(Text(qty)),
                                            ],
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                ),
              ],
            ),
    );
  }
}
