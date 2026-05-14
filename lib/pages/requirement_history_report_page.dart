// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class RequirementHistoryReportPage extends StatefulWidget {
  const RequirementHistoryReportPage({super.key});

  @override
  State<RequirementHistoryReportPage> createState() =>
      _RequirementHistoryReportPageState();
}

class _RequirementHistoryReportPageState
    extends State<RequirementHistoryReportPage> {
  static const int _rowsPerPage = 100;

  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> filteredRows = [];
  List<Map<String, dynamic>> parties = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];

  DateTime? fromDate;
  DateTime? toDate;
  int? selectedPartyId;
  int? selectedProductId;
  int? selectedShadeId;
  String statusFilter = 'all'; // all, pending, closed
  bool loading = true;
  bool reportGenerated = false;
  Timer? _reloadDebounce;
  int _loadVersion = 0;
  int _currentPage = 1;

  @override
  void initState() {
    super.initState();
    _bootstrapAndLoad();
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
      () async {
        await ErpDatabase.instance.repairClosedRequirementLedgers();
        await ErpDatabase.instance.repairClosedRequirementDataFromLedger();
        await _load(showLoader: false);
      },
    );
  }

  Future<void> _bootstrapAndLoad() async {
    await ErpDatabase.instance.repairClosedRequirementLedgers();
    await ErpDatabase.instance.repairClosedRequirementDataFromLedger();
    await _load(showLoader: true);
  }

  Future<void> _load({bool showLoader = false}) async {
    final loadVersion = ++_loadVersion;
    if (mounted && showLoader) setState(() => loading = true);
    final db = await ErpDatabase.instance.database;

    final nextRows = await db.rawQuery('''
      SELECT
        cr.id,
        cr.challan_no,
        cr.party_id,
        cr.party_name,
        COALESCE(cr.product_id, sl.product_id) AS product_id,
        COALESCE(cr.fabric_shade_id, sl.fabric_shade_id) AS fabric_shade_id,
        CASE
          WHEN COALESCE(cr.qty, 0) > 0 THEN cr.qty
          ELSE COALESCE(sl.qty, 0)
        END AS qty,
        COALESCE(cr.date, sl.date, cr.closed_date) AS date,
        cr.status,
        cr.closed_date,
        sl.remarks AS close_ledger_remarks,
        p.name AS product_name,
        COALESCE(p.unit, 'Mtr') AS product_unit,
        COALESCE(fs.shade_no, 'NO SHADE') AS shade_no
      FROM challan_requirements cr
      LEFT JOIN stock_ledger sl
        ON sl.id = (
          SELECT sl2.id
          FROM stock_ledger sl2
          WHERE sl2.reference = ('REQ-CLOSE-' || cr.id)
            AND UPPER(sl2.type) = 'OUT'
            AND (sl2.is_deleted IS NULL OR sl2.is_deleted = 0)
          ORDER BY sl2.id DESC
          LIMIT 1
        )
      LEFT JOIN products p ON p.id = COALESCE(cr.product_id, sl.product_id)
      LEFT JOIN fabric_shades fs
        ON fs.id = COALESCE(cr.fabric_shade_id, sl.fabric_shade_id)
      ORDER BY cr.date DESC, cr.id DESC
    ''');

    final nextParties =
        await db.query('parties', columns: ['id', 'name'], orderBy: 'name');
    final nextProducts =
        await db.query('products', columns: ['id', 'name'], orderBy: 'name');
    final nextShades = await db.query('fabric_shades',
        columns: ['id', 'shade_no', 'shade_name'], orderBy: 'shade_no');

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

  // ---- helpers ----

  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final asString = value.toString().trim();
    final direct = int.tryParse(asString);
    if (direct != null) return direct;
    final asDouble = double.tryParse(asString);
    return asDouble?.toInt();
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim()) ?? 0;
  }

  String _status(dynamic value) => (value ?? '').toString().trim().toLowerCase();

  String _fmtDate(dynamic ms) {
    final value = _toInt(ms);
    if (value == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(value));
  }

  String _fmtDateChip(DateTime? d) {
    if (d == null) return 'Any';
    return DateFormat('dd-MM-yyyy').format(d);
  }

  String _displayText(dynamic value, {String fallback = '-'}) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  int _daysBetween(int? createMs, int? closeMs) {
    if (createMs == null || closeMs == null) return 0;
    final create = DateTime.fromMillisecondsSinceEpoch(createMs);
    final close = DateTime.fromMillisecondsSinceEpoch(closeMs);
    return close.difference(create).inDays;
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
      // Date filter — use closed_date for closed, date for pending
      final status = _status(row['status']);
      final dateMs = status == 'closed'
          ? (_toInt(row['closed_date']) ?? _toInt(row['date']))
          : _toInt(row['date']);
      if (fromMs != null && (dateMs == null || dateMs < fromMs)) return false;
      if (toMs != null && (dateMs == null || dateMs > toMs)) return false;

      if (selectedPartyId != null && _toInt(row['party_id']) != selectedPartyId) {
        return false;
      }
      if (selectedProductId != null &&
          _toInt(row['product_id']) != selectedProductId) {
        return false;
      }
      if (selectedShadeId != null &&
          _toInt(row['fabric_shade_id']) != selectedShadeId) {
        return false;
      }
      if (statusFilter != 'all' && status != statusFilter) {
        return false;
      }
      return true;
    }).toList();

    final totalPages = rows.isEmpty ? 1 : ((rows.length - 1) ~/ _rowsPerPage) + 1;
    final safePage = _currentPage > totalPages ? totalPages : _currentPage;
    setState(() {
      filteredRows = rows;
      _currentPage = safePage;
    });
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
      selectedPartyId = null;
      selectedProductId = null;
      selectedShadeId = null;
      statusFilter = 'all';
      reportGenerated = false;
      _currentPage = 1;
    });
    _applyFilters();
  }

  void _showReport() {
    _currentPage = 1;
    _applyFilters();
    setState(() => reportGenerated = true);
  }

  // ---- summary ----

  Map<String, dynamic> _buildSummary() {
    int totalPending = 0;
    int totalClosed = 0;
    double pendingQty = 0;
    double closedQty = 0;
    int totalDaysToClose = 0;
    int closedWithDates = 0;

    // Monthly breakdown of closed requirements
    final monthlyMap = <String, Map<String, dynamic>>{};

    for (final row in filteredRows) {
      final status = _status(row['status']);
      final qty = _toDouble(row['qty']);

      if (status == 'closed') {
        totalClosed++;
        closedQty += qty;

        final closeMs = _toInt(row['closed_date']);
        final createMs = _toInt(row['date']);
        if (closeMs != null) {
          final closeDate = DateTime.fromMillisecondsSinceEpoch(closeMs);
          final monthKey = DateFormat('MMM yyyy').format(closeDate);
          final m =
              monthlyMap.putIfAbsent(monthKey, () => {'count': 0, 'qty': 0.0});
          m['count'] = (m['count'] as int) + 1;
          m['qty'] = (m['qty'] as double) + qty;

          if (createMs != null) {
            totalDaysToClose += _daysBetween(createMs, closeMs);
            closedWithDates++;
          }
        }
      } else {
        totalPending++;
        pendingQty += qty;
      }
    }

    final avgDays = closedWithDates > 0
        ? (totalDaysToClose / closedWithDates).toStringAsFixed(1)
        : '-';

    return {
      'totalPending': totalPending,
      'totalClosed': totalClosed,
      'pendingQty': pendingQty,
      'closedQty': closedQty,
      'avgDays': avgDays,
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
                pw.Text('Requirement History Report',
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
            pw.Text('Date: $fromText to $toText  |  Status: $statusFilter',
                style: const pw.TextStyle(fontSize: 9)),
            pw.Text(
              'Pending: ${summary['totalPending']} (${(summary['pendingQty'] as double).toStringAsFixed(2)} $unit)  |  '
              'Closed: ${summary['totalClosed']} (${(summary['closedQty'] as double).toStringAsFixed(2)} $unit)  |  '
              'Avg days to close: ${summary['avgDays']}',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
          ];

          // Monthly summary table
          final monthly =
              summary['monthly'] as Map<String, Map<String, dynamic>>;
          if (monthly.isNotEmpty) {
            widgets.add(pw.Text('Monthly Fulfilled Summary',
                style: pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold)));
            final monthData = monthly.entries.map((e) {
              return [
                e.key,
                (e.value['count'] as int).toString(),
                (e.value['qty'] as double).toStringAsFixed(2),
              ];
            }).toList();
            widgets.add(pw.TableHelper.fromTextArray(
              headers: const ['Month', 'Count', 'Qty'],
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
              },
            ));
            widgets.add(pw.SizedBox(height: 10));
          }

          // Detail table
          widgets.add(pw.Text('Detail',
              style:
                  pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)));
          final data = filteredRows.map((r) {
            final status = _status(r['status']);
            final days = status == 'closed'
                ? _daysBetween(_toInt(r['date']), _toInt(r['closed_date']))
                    .toString()
                : '-';
            return [
              (r['challan_no'] ?? '-').toString(),
              (r['party_name'] ?? '-').toString(),
              (r['product_name'] ?? '-').toString(),
              (r['shade_no'] ?? '-').toString(),
              _toDouble(r['qty']).toStringAsFixed(2),
              _fmtDate(r['date']),
              status == 'closed' ? _fmtDate(r['closed_date']) : '-',
              status.toUpperCase(),
              days,
            ];
          }).toList();

          widgets.add(pw.TableHelper.fromTextArray(
            headers: const [
              'Ch No',
              'Party',
              'Product',
              'Shade',
              'Qty',
              'Created',
              'Closed',
              'Status',
              'Days',
            ],
            data: data,
            headerStyle:
                pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            columnWidths: {
              0: const pw.FlexColumnWidth(1),
              1: const pw.FlexColumnWidth(1.8),
              2: const pw.FlexColumnWidth(1.5),
              3: const pw.FlexColumnWidth(0.8),
              4: const pw.FlexColumnWidth(0.8),
              5: const pw.FlexColumnWidth(1.3),
              6: const pw.FlexColumnWidth(1.3),
              7: const pw.FlexColumnWidth(0.8),
              8: const pw.FlexColumnWidth(0.6),
            },
          ));

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name: 'requirement_history_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  // ---- build UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Requirement History'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: (loading || !reportGenerated) ? null : _exportPdf,
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
                      // Party + Status
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: selectedPartyId,
                              decoration: const InputDecoration(
                                labelText: 'Party',
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
                                    child: Text((p['name'] ?? '').toString(),
                                        overflow: TextOverflow.ellipsis),
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
                            child: DropdownButtonFormField<String>(
                              initialValue: statusFilter,
                              decoration: const InputDecoration(
                                labelText: 'Status',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: 'all', child: Text('All')),
                                DropdownMenuItem(
                                    value: 'pending', child: Text('Pending')),
                                DropdownMenuItem(
                                    value: 'closed', child: Text('Closed')),
                              ],
                              onChanged: (v) {
                                setState(() {
                                  statusFilter = v ?? 'all';
                                  reportGenerated = false;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Product + Shade
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
                                    child:
                                        Text((s['shade_no'] ?? '').toString()),
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
          child: Center(child: Text('No requirements found')),
        ),
      ];
    }

    final summary = _buildSummary();
    final unit = filteredRows.isNotEmpty
        ? (filteredRows.first['product_unit'] ?? 'Mtr').toString()
        : 'Mtr';
    final monthly = summary['monthly'] as Map<String, Map<String, dynamic>>;
    final totalRows = filteredRows.length;
    final totalPages =
        totalRows == 0 ? 1 : ((totalRows - 1) ~/ _rowsPerPage) + 1;
    final currentPage = _currentPage.clamp(1, totalPages);
    final startIndex = (currentPage - 1) * _rowsPerPage;
    final endIndex = (startIndex + _rowsPerPage) > totalRows
        ? totalRows
        : (startIndex + _rowsPerPage);
    final pageRows = filteredRows.sublist(startIndex, endIndex);

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
                      'Pending',
                      '${summary['totalPending']} (${(summary['pendingQty'] as double).toStringAsFixed(2)} $unit)',
                      Colors.orange),
                  const SizedBox(width: 12),
                  _summaryChip(
                      'Closed',
                      '${summary['totalClosed']} (${(summary['closedQty'] as double).toStringAsFixed(2)} $unit)',
                      Colors.green),
                ],
              ),
              const SizedBox(height: 6),
              Text('Avg days to fulfil: ${summary['avgDays']}',
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
                const Text('Monthly Fulfilled',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 24,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('Month')),
                      DataColumn(label: Text('Count')),
                      DataColumn(label: Text('Qty')),
                    ],
                    rows: monthly.entries.map((e) {
                      return DataRow(cells: [
                        DataCell(
                            Text(e.key, style: const TextStyle(fontSize: 12))),
                        DataCell(Text('${e.value['count']}',
                            style: const TextStyle(fontSize: 12))),
                        DataCell(Text(
                            (e.value['qty'] as double).toStringAsFixed(2),
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Text(
                'Rows ${startIndex + 1}-$endIndex of $totalRows',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Previous Page',
                onPressed: currentPage > 1
                    ? () => setState(() => _currentPage = currentPage - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text(
                '$currentPage / $totalPages',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              IconButton(
                tooltip: 'Next Page',
                onPressed: currentPage < totalPages
                    ? () => setState(() => _currentPage = currentPage + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
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
                DataColumn(label: Text('Ch No')),
                DataColumn(label: Text('Party')),
                DataColumn(label: Text('Product')),
                DataColumn(label: Text('Shade')),
                DataColumn(label: Text('Qty')),
                DataColumn(label: Text('Created')),
                DataColumn(label: Text('Closed')),
                DataColumn(label: Text('Status')),
                DataColumn(label: Text('Days')),
              ],
              rows: pageRows.map((r) {
                final status = _status(r['status']);
                final isClosed = status == 'closed';
                final days = isClosed
                    ? _daysBetween(_toInt(r['date']), _toInt(r['closed_date']))
                        .toString()
                    : '-';
                return DataRow(cells: [
                  DataCell(Text(_displayText(r['challan_no']),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_displayText(r['party_name']),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_displayText(r['product_name']),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_displayText(r['shade_no']),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(
                      _toDouble(r['qty']).toStringAsFixed(2),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(_fmtDate(r['date']),
                      style: const TextStyle(fontSize: 12))),
                  DataCell(Text(
                      isClosed ? _fmtDate(r['closed_date']) : '-',
                      style: const TextStyle(fontSize: 12))),
                  DataCell(
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isClosed
                            ? Colors.green.shade100
                            : Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        status.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isClosed
                              ? Colors.green.shade800
                              : Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ),
                  DataCell(Text(days, style: const TextStyle(fontSize: 12))),
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
