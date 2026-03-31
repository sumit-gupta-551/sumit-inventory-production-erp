import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class IssueChallanPage extends StatefulWidget {
  const IssueChallanPage({super.key});

  @override
  State<IssueChallanPage> createState() => _IssueChallanPageState();
}

class _IssueChallanPageState extends State<IssueChallanPage> {
  List<Map<String, dynamic>> allRows = [];
  List<Map<String, dynamic>> reqRows = [];
  List<Map<String, dynamic>> parties = [];
  bool loading = true;

  // Grouped challans
  List<_ChallanGroup> challans = [];
  int? filterPartyId;

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
        sl.product_id,
        sl.fabric_shade_id,
        p.name AS product_name,
        fs.shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      WHERE UPPER(sl.type) = 'OUT'
      ORDER BY sl.date DESC, sl.id DESC
    ''');

    final nextReqs = await db.rawQuery('''
      SELECT
        cr.id,
        cr.challan_no,
        cr.party_id,
        cr.party_name,
        cr.product_id,
        cr.fabric_shade_id,
        cr.qty,
        cr.date,
        cr.status,
        p.name AS product_name,
        fs.shade_no
      FROM challan_requirements cr
      LEFT JOIN products p ON p.id = cr.product_id
      LEFT JOIN fabric_shades fs ON fs.id = cr.fabric_shade_id
      ORDER BY cr.date DESC, cr.id DESC
    ''');

    final nextParties = await db.query(
      'parties',
      columns: ['id', 'name'],
      orderBy: 'name',
    );

    if (!mounted) return;

    setState(() {
      allRows = nextRows;
      reqRows = nextReqs;
      parties = nextParties;
      loading = false;
    });

    _buildChallans();
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

  String _partyNameById(int? id) {
    if (id == null) return '';
    final found = parties.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == id,
          orElse: () => null,
        );
    return (found?['name'] ?? '').toString();
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  void _buildChallans() {
    // Group stock_ledger OUT rows by reference (issue reference = timestamp)
    final grouped = <String, _ChallanGroup>{};

    for (final row in allRows) {
      final ref = (row['reference'] ?? '').toString().trim();
      if (ref.isEmpty) continue;

      final remarks = _parseRemarks(row['remarks']?.toString());
      final partyName = _remarkValue(remarks, ['Party']);
      final chNo = _remarkValue(remarks, ['ChNo', 'Ch No', 'Ch']);
      final dateMs = row['date'] as int?;
      final productName = (row['product_name'] ?? '-').toString();

      if (filterPartyId != null) {
        final filterName = _partyNameById(filterPartyId).trim().toLowerCase();
        if (partyName.trim().toLowerCase() != filterName) continue;
      }

      final group = grouped.putIfAbsent(
        ref,
        () => _ChallanGroup(
          reference: ref,
          challanNo: chNo,
          partyName: partyName,
          productName: productName,
          dateMs: dateMs,
        ),
      );

      group.stockItems.add(_ChallanItem(
        shadeNo: (row['shade_no'] ?? '-').toString(),
        qty: (row['qty'] as num?)?.toDouble() ?? 0,
      ));
    }

    // Attach requirement items to matching challan groups
    for (final req in reqRows) {
      final chNo = (req['challan_no'] ?? '').toString().trim();
      if (chNo.isEmpty || chNo == '-') continue;

      // Find group by challan_no match
      for (final g in grouped.values) {
        if (g.challanNo.trim() == chNo) {
          g.reqItems.add(_ChallanItem(
            shadeNo: (req['shade_no'] ?? '-').toString(),
            qty: (req['qty'] as num?)?.toDouble() ?? 0,
            status: (req['status'] ?? 'pending').toString(),
          ));
          break;
        }
      }
    }

    // Also add requirement items that have no matching stock group
    final matchedChNos = grouped.values.map((g) => g.challanNo.trim()).toSet();
    final reqByChNo = <String, _ChallanGroup>{};
    for (final req in reqRows) {
      final chNo = (req['challan_no'] ?? '').toString().trim();
      if (chNo.isEmpty || chNo == '-') continue;
      if (matchedChNos.contains(chNo)) continue;

      final partyName = (req['party_name'] ?? '-').toString();
      if (filterPartyId != null) {
        final filterName = _partyNameById(filterPartyId).trim().toLowerCase();
        if (partyName.trim().toLowerCase() != filterName) continue;
      }

      final group = reqByChNo.putIfAbsent(
        chNo,
        () => _ChallanGroup(
          reference: chNo,
          challanNo: chNo,
          partyName: partyName,
          productName: (req['product_name'] ?? '-').toString(),
          dateMs: req['date'] as int?,
        ),
      );

      group.reqItems.add(_ChallanItem(
        shadeNo: (req['shade_no'] ?? '-').toString(),
        qty: (req['qty'] as num?)?.toDouble() ?? 0,
        status: (req['status'] ?? 'pending').toString(),
      ));
    }

    final all = [...grouped.values, ...reqByChNo.values];
    all.sort((a, b) => (b.dateMs ?? 0).compareTo(a.dateMs ?? 0));

    setState(() {
      challans = all;
    });
  }

  // -------- PDF GENERATION --------
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

  Future<void> _generateChallanPdf(_ChallanGroup challan) async {
    final doc = pw.Document(theme: await _pdfTheme());
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());

    // Build stock items table data
    final stockData = <List<String>>[];
    var sr = 1;
    double stockTotal = 0;
    for (final item in challan.stockItems) {
      stockTotal += item.qty;
      stockData.add([
        sr.toString(),
        item.shadeNo,
        item.qty.toStringAsFixed(2),
      ]);
      sr++;
    }

    // Build requirement items table data
    final reqData = <List<String>>[];
    sr = 1;
    double reqTotal = 0;
    for (final item in challan.reqItems) {
      reqTotal += item.qty;
      reqData.add([
        sr.toString(),
        item.shadeNo,
        item.qty.toStringAsFixed(2),
        item.status ?? 'pending',
      ]);
      sr++;
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Issue Challan',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Challan No: ${challan.challanNo}',
                        style: pw.TextStyle(
                          fontSize: 12,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        'Party: ${challan.partyName}',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'Date: ${_fmtDate(challan.dateMs)}',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        'Product: ${challan.productName}',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Generated: $now',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.Text(
              'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];

          // ---- Stock Items (Shade-wise) ----
          if (stockData.isNotEmpty) {
            widgets.add(
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: PdfColors.green50,
                child: pw.Row(
                  children: [
                    pw.Text(
                      'Stock Items (Issued)',
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.green900,
                      ),
                    ),
                    pw.Spacer(),
                    pw.Text(
                      '${stockData.length} shades | ${stockTotal.toStringAsFixed(2)} mtr',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.green800,
                      ),
                    ),
                  ],
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                ),
                cellStyle: const pw.TextStyle(fontSize: 10),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColors.green100),
                cellAlignments: {
                  0: pw.Alignment.center,
                  1: pw.Alignment.centerLeft,
                  2: pw.Alignment.centerRight,
                },
                columnWidths: {
                  0: const pw.FixedColumnWidth(40),
                  1: const pw.FlexColumnWidth(3),
                  2: const pw.FlexColumnWidth(1.5),
                },
                headers: ['Sr', 'Shade No', 'Mtr'],
                data: stockData,
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  'Stock Total: ${stockTotal.toStringAsFixed(2)} mtr',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            );
          }

          // ---- Requirement Items ----
          if (reqData.isNotEmpty) {
            widgets.add(pw.SizedBox(height: 20));
            widgets.add(
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                color: PdfColors.orange50,
                child: pw.Row(
                  children: [
                    pw.Text(
                      'Requirement Items',
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.orange900,
                      ),
                    ),
                    pw.Spacer(),
                    pw.Text(
                      '${reqData.length} shades | ${reqTotal.toStringAsFixed(2)} mtr',
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.orange800,
                      ),
                    ),
                  ],
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 4));
            widgets.add(
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                ),
                cellStyle: const pw.TextStyle(fontSize: 10),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColors.orange100),
                cellAlignments: {
                  0: pw.Alignment.center,
                  1: pw.Alignment.centerLeft,
                  2: pw.Alignment.centerRight,
                  3: pw.Alignment.center,
                },
                columnWidths: {
                  0: const pw.FixedColumnWidth(40),
                  1: const pw.FlexColumnWidth(3),
                  2: const pw.FlexColumnWidth(1.5),
                  3: const pw.FlexColumnWidth(1.5),
                },
                headers: ['Sr', 'Shade No', 'Mtr', 'Status'],
                data: reqData,
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.Align(
                alignment: pw.Alignment.centerRight,
                child: pw.Text(
                  'Requirement Total: ${reqTotal.toStringAsFixed(2)} mtr',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            );
          }

          // ---- Grand Total ----
          if (stockData.isNotEmpty || reqData.isNotEmpty) {
            widgets.add(pw.SizedBox(height: 16));
            widgets.add(pw.Divider(thickness: 1.5));
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Grand Total',
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    '${(stockTotal + reqTotal).toStringAsFixed(2)} mtr',
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }

          // ---- Signature area ----
          widgets.add(pw.SizedBox(height: 50));
          widgets.add(
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  children: [
                    pw.Container(
                      width: 140,
                      decoration: const pw.BoxDecoration(
                        border: pw.Border(
                          top: pw.BorderSide(color: PdfColors.grey600),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text('Issued By',
                        style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
                pw.Column(
                  children: [
                    pw.Container(
                      width: 140,
                      decoration: const pw.BoxDecoration(
                        border: pw.Border(
                          top: pw.BorderSide(color: PdfColors.grey600),
                        ),
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text('Received By',
                        style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
              ],
            ),
          );

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name:
          'issue_challan_${challan.challanNo}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      onLayout: (format) => doc.save(),
    );
  }

  // -------- UI --------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Row(
          children: [
            Icon(Icons.receipt_long_outlined, color: Colors.white),
            SizedBox(width: 10),
            Text(
              'Issue Challans',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => loading = true);
              _load();
            },
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ---- PARTY FILTER ----
                Container(
                  margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          value: filterPartyId,
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: 'Filter by Party',
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(),
                          ),
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
                            setState(() => filterPartyId = v);
                            _buildChallans();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${challans.length} challans',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),

                // ---- CHALLAN LIST ----
                Expanded(
                  child: challans.isEmpty
                      ? const Center(
                          child: Text(
                            'No issue challans found',
                            style:
                                TextStyle(fontSize: 14, color: Colors.black45),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                          itemCount: challans.length,
                          itemBuilder: (ctx, i) =>
                              _buildChallanCard(challans[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildChallanCard(_ChallanGroup ch) {
    final stockQty = ch.stockItems.fold<double>(
      0,
      (sum, item) => sum + item.qty,
    );
    final reqQty = ch.reqItems.fold<double>(
      0,
      (sum, item) => sum + item.qty,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 2,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFF1A237E).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.receipt_outlined,
              color: Color(0xFF1A237E),
              size: 22,
            ),
          ),
          title: Text(
            'Ch No: ${ch.challanNo}',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            '${ch.partyName}  |  ${_fmtDate(ch.dateMs)}',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          trailing: IconButton(
            tooltip: 'Download PDF',
            onPressed: () => _generateChallanPdf(ch),
            icon: const Icon(
              Icons.picture_as_pdf,
              color: Colors.redAccent,
              size: 24,
            ),
          ),
          children: [
            // ---- Product ----
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Product: ${ch.productName}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ---- Stock Items Grid ----
            if (ch.stockItems.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(6)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.inventory_2_outlined,
                        size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Stock Items',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: Colors.green.shade800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Total: ${stockQty.toStringAsFixed(2)} mtr',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green.shade200),
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(6)),
                ),
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(36),
                    1: FlexColumnWidth(3),
                    2: FlexColumnWidth(1.5),
                  },
                  border: TableBorder(
                    horizontalInside:
                        BorderSide(color: Colors.green.shade100, width: 0.5),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: Colors.green.shade100),
                      children: const [
                        _TableHeader('Sr'),
                        _TableHeader('Shade No'),
                        _TableHeader('Mtr', align: TextAlign.right),
                      ],
                    ),
                    ...ch.stockItems.asMap().entries.map((e) {
                      final idx = e.key;
                      final item = e.value;
                      return TableRow(
                        children: [
                          _TableCell('${idx + 1}'),
                          _TableCell(item.shadeNo),
                          _TableCell(
                            item.qty.toStringAsFixed(2),
                            align: TextAlign.right,
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ---- Requirement Items Grid ----
            if (ch.reqItems.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(6)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.pending_actions_outlined,
                        size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Requirement Items',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: Colors.orange.shade800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Total: ${reqQty.toStringAsFixed(2)} mtr',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                        color: Colors.orange.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orange.shade200),
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(6)),
                ),
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(36),
                    1: FlexColumnWidth(3),
                    2: FlexColumnWidth(1.5),
                    3: FlexColumnWidth(1.5),
                  },
                  border: TableBorder(
                    horizontalInside:
                        BorderSide(color: Colors.orange.shade100, width: 0.5),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: Colors.orange.shade100),
                      children: const [
                        _TableHeader('Sr'),
                        _TableHeader('Shade No'),
                        _TableHeader('Mtr', align: TextAlign.right),
                        _TableHeader('Status', align: TextAlign.center),
                      ],
                    ),
                    ...ch.reqItems.asMap().entries.map((e) {
                      final idx = e.key;
                      final item = e.value;
                      return TableRow(
                        children: [
                          _TableCell('${idx + 1}'),
                          _TableCell(item.shadeNo),
                          _TableCell(
                            item.qty.toStringAsFixed(2),
                            align: TextAlign.right,
                          ),
                          _TableCell(
                            item.status ?? 'pending',
                            align: TextAlign.center,
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ---- Summary row ----
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEDE7F6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text(
                    'Stock: ${stockQty.toStringAsFixed(2)} mtr',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Req: ${reqQty.toStringAsFixed(2)} mtr',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Colors.deepOrange,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Total: ${(stockQty + reqQty).toStringAsFixed(2)} mtr',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: Color(0xFF1A237E),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

// -------- DATA MODELS --------
class _ChallanGroup {
  final String reference;
  final String challanNo;
  final String partyName;
  final String productName;
  final int? dateMs;
  final List<_ChallanItem> stockItems = [];
  final List<_ChallanItem> reqItems = [];

  _ChallanGroup({
    required this.reference,
    required this.challanNo,
    required this.partyName,
    required this.productName,
    this.dateMs,
  });
}

class _ChallanItem {
  final String shadeNo;
  final double qty;
  final String? status;

  _ChallanItem({
    required this.shadeNo,
    required this.qty,
    this.status,
  });
}

// -------- TABLE CELL WIDGETS --------
class _TableHeader extends StatelessWidget {
  final String text;
  final TextAlign align;
  const _TableHeader(this.text, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Text(
        text,
        textAlign: align,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _TableCell extends StatelessWidget {
  final String text;
  final TextAlign align;
  const _TableCell(this.text, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Text(
        text,
        textAlign: align,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}
