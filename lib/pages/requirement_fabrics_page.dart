import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';

class RequirementFabricsPage extends StatefulWidget {
  const RequirementFabricsPage({super.key});

  @override
  State<RequirementFabricsPage> createState() => _RequirementFabricsPageState();
}

class _RequirementFabricsPageState extends State<RequirementFabricsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  List<Map<String, dynamic>> challanRows = [];
  bool loading = true;
  String _selectedParty = 'All';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _repairOldEntriesAndLoad();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    _tabCtrl.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) _load();
  }

  Future<void> _repairOldEntriesAndLoad() async {
    await ErpDatabase.instance.repairClosedRequirementLedgers();
    await ErpDatabase.instance.repairClosedRequirementDataFromLedger();
    await _load();
  }

  Future<void> _load() async {
    final cr = await ErpDatabase.instance.getPendingChallanRequirements();
    if (!mounted) return;
    setState(() {
      challanRows = cr;
      loading = false;
    });
  }

  // -------- Grouping helpers --------
  Map<String, List<Map<String, dynamic>>> _groupByChallan() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final r in challanRows) {
      final ch = (r['challan_no'] ?? '-').toString();
      map.putIfAbsent(ch, () => []).add(r);
    }
    return map;
  }

  List<String> _partyNames() {
    final set = <String>{};
    for (final r in challanRows) {
      final p = (r['party_name'] ?? '').toString().trim();
      if (p.isNotEmpty) set.add(p);
    }
    final list = set.toList()..sort();
    return ['All', ...list];
  }

  List<Map<String, dynamic>> get _filteredRows {
    if (_selectedParty == 'All') return challanRows;
    return challanRows
        .where((r) => (r['party_name'] ?? '').toString() == _selectedParty)
        .toList();
  }

  Map<String, Map<String, double>> _groupByProductShade() {
    final map = <String, Map<String, double>>{};
    for (final r in _filteredRows) {
      final product = (r['product_name'] ?? '-').toString();
      final shade = (r['shade_no'] ?? '-').toString();
      final qty = (r['qty'] as num?)?.toDouble() ?? 0;
      map.putIfAbsent(product, () => {});
      map[product]![shade] = (map[product]![shade] ?? 0) + qty;
    }
    return map;
  }

  String _fmtDate(dynamic ms) {
    if (ms == null) return '';
    try {
      final d = DateTime.fromMillisecondsSinceEpoch(ms as int);
      return DateFormat('dd-MM-yyyy').format(d);
    } catch (_) {
      return '';
    }
  }

  Future<void> _closeItem(Map<String, dynamic> row) async {
    await ErpDatabase.instance.closeChallanRequirementWithLedger(row);
    setState(() => loading = true);
    _load();
  }

  Future<void> _closeChallan(String challanNo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Challan?'),
        content: Text(
          'Mark all pending requirements of Ch No "$challanNo" as closed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Close All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await ErpDatabase.instance.closeChallanRequirementsByChallan(challanNo);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ch No "$challanNo" closed')),
    );
    setState(() => loading = true);
    _load();
  }

  Future<void> _editRequirement(Map<String, dynamic> row) async {
    final db = await ErpDatabase.instance.database;
    final allShades = await db.query('fabric_shades',
        columns: ['id', 'shade_no', 'shade_name'], orderBy: 'shade_no');

    int? shadeId = row['fabric_shade_id'] as int?;
    final qtyCtrl = TextEditingController(
      text: ((row['qty'] as num?)?.toDouble() ?? 0).toString(),
    );
    var saving = false;

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Requirement'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Ch No: ${row['challan_no'] ?? '-'}  •  Party: ${row['party_name'] ?? '-'}',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: shadeId,
                      decoration: const InputDecoration(
                        labelText: 'Shade',
                        border: OutlineInputBorder(),
                      ),
                      isExpanded: true,
                      items: allShades.map((s) {
                        final no = (s['shade_no'] ?? '').toString();
                        final name = (s['shade_name'] ?? '').toString();
                        final label = name.isEmpty ? no : '$no - $name';
                        return DropdownMenuItem<int>(
                          value: s['id'] as int,
                          child: Text(label),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (v) => setDialogState(() => shadeId = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: qtyCtrl,
                      enabled: !saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Qty',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: saving
                      ? null
                      : () async {
                          final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;
                          if (shadeId == null || qty <= 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content:
                                    Text('Select shade and enter valid qty'),
                              ),
                            );
                            return;
                          }
                          setDialogState(() => saving = true);

                          await ErpDatabase.instance.updateChallanRequirement(
                            row['id'] as int,
                            {
                              'fabric_shade_id': shadeId,
                              'qty': qty,
                            },
                          );

                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          setState(() => loading = true);
                          _load();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Requirement updated'),
                            ),
                          );
                        },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // -------- PDF Generation --------
  Future<void> _generatePdf() async {
    final grouped = _groupByProductShade();
    if (grouped.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No requirement data to export')),
      );
      return;
    }

    final pdf = pw.Document();
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final filterLabel =
        _selectedParty == 'All' ? 'All Parties' : _selectedParty;

    // Build table rows
    final tableRows = <List<String>>[];
    var sr = 1;
    double grandTotal = 0;
    for (final product in grouped.keys.toList()..sort()) {
      final shades = grouped[product]!;
      for (final shade in shades.keys.toList()..sort()) {
        final qty = shades[shade]!;
        grandTotal += qty;
        tableRows.add([
          sr.toString(),
          product,
          shade,
          qty.toStringAsFixed(2),
        ]);
        sr++;
      }
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (ctx.pageNumber == 1) ...[
              pw.Center(
                child: pw.Image(logoImage, width: 50, height: 50),
              ),
              pw.SizedBox(height: 4),
            ],
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Requirement Report',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'Party: $filterLabel  |  Generated: $now',
                  style:
                      const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                ),
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
        build: (ctx) => [
          pw.TableHelper.fromTextArray(
            border: pw.TableBorder.all(color: PdfColors.grey400),
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 11,
            ),
            cellStyle: const pw.TextStyle(fontSize: 10),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColors.grey200,
            ),
            cellAlignments: {
              0: pw.Alignment.center,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerLeft,
              3: pw.Alignment.centerRight,
            },
            headers: ['Sr', 'Product', 'Shade', 'Req Qty'],
            data: tableRows,
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.Text(
                'Grand Total: ${grandTotal.toStringAsFixed(2)}',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      onLayout: (format) => pdf.save(),
      name:
          'Requirement_Report_${DateFormat('yyyyMMdd').format(DateTime.now())}',
    );
  }

  // ================= BUILD =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fabric Requirement'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: _generatePdf,
            icon: const Icon(Icons.picture_as_pdf),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => loading = true);
              _load();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Challan-wise'),
            Tab(text: 'Requirement Report'),
          ],
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabCtrl,
              children: [
                _buildChallanTab(),
                _buildReportTab(),
              ],
            ),
    );
  }

  // -------- TAB 1: Challan-wise Requirements --------
  Widget _buildChallanTab() {
    final grouped = _groupByChallan();
    if (grouped.isEmpty) {
      return const Center(
        child: Text('No pending challan requirements.'),
      );
    }

    final challanNos = grouped.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: challanNos.length,
        itemBuilder: (_, ci) {
          final chNo = challanNos[ci];
          final items = grouped[chNo]!;
          final party = items.first['party_name'] ?? '-';
          final date = _fmtDate(items.first['date']);
          final totalQty = items.fold<double>(
            0,
            (s, r) => s + ((r['qty'] as num?)?.toDouble() ?? 0),
          );

          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ExpansionTile(
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              // ---- Collapsed: Party + Ch No only ----
              title: Text(
                party,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
              subtitle: Text(
                'Ch No: $chNo',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.deepOrange.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Text(
                totalQty.toStringAsFixed(2),
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              // ---- Expanded: Full details ----
              children: [
                const Divider(height: 1),
                const SizedBox(height: 10),
                // Date + Product info
                Row(
                  children: [
                    Text(
                      'Date: $date',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        'Product: ${items.map((r) => r['product_name'] ?? '-').toSet().join(', ')}',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // ---- Shade table ----
                Table(
                  border: TableBorder.all(
                    color: Colors.grey.shade300,
                    width: 1,
                  ),
                  columnWidths: const {
                    0: FlexColumnWidth(3),
                    1: FlexColumnWidth(2),
                    2: FlexColumnWidth(3),
                  },
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                      ),
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(
                              vertical: 10, horizontal: 12),
                          child: Text(
                            'Shade No',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                          child: Text(
                            'Qty',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                          child: Text(
                            'Action',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    ...items.map((r) {
                      final qty = ((r['qty'] as num?)?.toDouble() ?? 0)
                          .toStringAsFixed(2);
                      return TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 12),
                            child: Text(
                              (r['shade_no'] ?? '-').toString(),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 8),
                            child: Text(
                              qty,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: Colors.red,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 6, horizontal: 4),
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 4,
                              runSpacing: 4,
                              children: [
                                SizedBox(
                                  height: 28,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.blue,
                                      side:
                                          const BorderSide(color: Colors.blue),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      textStyle: const TextStyle(fontSize: 10),
                                    ),
                                    onPressed: () => _editRequirement(r),
                                    child: const Text('EDIT'),
                                  ),
                                ),
                                SizedBox(
                                  height: 28,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.green,
                                      side:
                                          const BorderSide(color: Colors.green),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6),
                                      textStyle: const TextStyle(fontSize: 10),
                                    ),
                                    onPressed: () async {
                                      final ok = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Close Shade?'),
                                          content: Text(
                                            'Close ${r['shade_no']} '
                                            '(Qty: $qty) from Ch No $chNo?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Cancel'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text('Close'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (ok == true) {
                                        _closeItem(r);
                                      }
                                    },
                                    child: const Text('CLOSE'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
                const SizedBox(height: 12),
                // ---- Footer: Total + Close All ----
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total: ${totalQty.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _closeChallan(chNo),
                      child: const Text('CLOSE ALL'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // -------- TAB 2: Requirement Report (Product + Shade wise) --------
  Widget _buildReportTab() {
    final partyList = _partyNames();
    final grouped = _groupByProductShade();
    if (challanRows.isEmpty) {
      return const Center(
        child: Text('No pending requirements.'),
      );
    }

    final products = grouped.keys.toList()..sort();
    double grandTotal = 0;
    for (final shades in grouped.values) {
      for (final qty in shades.values) {
        grandTotal += qty;
      }
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Party filter
          DropdownButtonFormField<String>(
            value: _selectedParty,
            decoration: const InputDecoration(
              labelText: 'Filter by Party',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            items: partyList
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _selectedParty = v);
            },
          ),
          const SizedBox(height: 10),
          // Summary header
          Card(
            color: Colors.deepOrange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Products: ${products.length}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    'Total Req: ${grandTotal.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.deepOrange,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Product-wise cards
          ...products.map((product) {
            final shades = grouped[product]!;
            final shadeNames = shades.keys.toList()..sort();
            final productTotal = shades.values.fold<double>(0, (s, q) => s + q);

            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(
                  product,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${shadeNames.length} shade(s)',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                trailing: Text(
                  productTotal.toStringAsFixed(2),
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                children: shadeNames.map((shade) {
                  final qty = shades[shade]!;
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.circle,
                        size: 8, color: Colors.deepOrange),
                    title: Text(shade),
                    trailing: Text(
                      qty.toStringAsFixed(2),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.red,
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          }),
        ],
      ),
    );
  }
}
