import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';

class OrderManagementPage extends StatefulWidget {
  final int initialTab;

  const OrderManagementPage({super.key, this.initialTab = 0});

  @override
  State<OrderManagementPage> createState() => _OrderManagementPageState();
}

class _OrderManagementPageState extends State<OrderManagementPage> {
  final _db = ErpDatabase.instance;
  final _orderRemarksCtrl = TextEditingController();
  final _lineQtyCtrl = TextEditingController();
  final _purchaseInvoiceCtrl = TextEditingController();
  final _reportDateFmt = DateFormat('dd-MM-yyyy');

  bool _loading = true;
  bool _savingOrder = false;
  bool _savingPurchase = false;
  bool _loadingPurchaseLines = false;
  bool _loadingReport = false;

  DateTime _orderDate = DateTime.now();
  DateTime _purchaseDate = DateTime.now();
  DateTime? _reportFrom;
  DateTime? _reportTo;

  List<Map<String, dynamic>> _firms = [];
  List<Party> _parties = [];
  List<Product> _products = [];
  List<Map<String, dynamic>> _shades = [];

  int? _selectedFirmId;
  int? _selectedPartyId;
  int? _lineProductId;
  int? _lineShadeId;
  int _nextOrderNo = 1;
  final List<_DraftOrderLine> _draftLines = [];

  String _reportStatus = 'all';
  List<Map<String, dynamic>> _reportRows = [];
  List<Map<String, dynamic>> _reportShadeRows = [];

  List<Map<String, dynamic>> _openOrders = [];
  int? _selectedOrderNo;
  Map<String, dynamic>? _selectedOrderMaster;
  List<Map<String, dynamic>> _selectedOrderLines = [];
  final Map<int, TextEditingController> _purchaseQtyCtrls = {};

  @override
  void initState() {
    super.initState();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    _orderRemarksCtrl.dispose();
    _lineQtyCtrl.dispose();
    _purchaseInvoiceCtrl.dispose();
    for (final c in _purchaseQtyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    unawaited(_refreshData(preserveOrderSelection: true));
  }

  Future<void> _initialize() async {
    await _refreshData(preserveOrderSelection: false);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _refreshData({required bool preserveOrderSelection}) async {
    await Future.wait([
      _loadMasters(),
      _loadNextOrderNo(),
      _loadOpenOrders(preserveSelection: preserveOrderSelection),
      _loadReportRows(),
    ]);
  }

  Future<void> _loadMasters() async {
    final results = await Future.wait([
      _db.getFirms(),
      _db.getParties(),
      _db.getProducts(),
      _db.getFabricShades(),
    ]);

    final firms = results[0] as List<Map<String, dynamic>>;
    final parties = (results[1] as List<Party>)
        .where((p) => p.partyType == 'Purchase')
        .toList();
    final products = results[2] as List<Product>;
    final shades = results[3] as List<Map<String, dynamic>>;

    if (!mounted) return;
    setState(() {
      _firms = firms;
      _parties = parties;
      _products = products;
      _shades = shades;

      if (_selectedFirmId != null &&
          !_firms.any((f) => _asInt(f['id']) == _selectedFirmId)) {
        _selectedFirmId = null;
      }
      if (_selectedPartyId != null &&
          !_parties.any((p) => p.id == _selectedPartyId)) {
        _selectedPartyId = null;
      }
      if (_lineProductId != null &&
          !_products.any((p) => p.id == _lineProductId)) {
        _lineProductId = null;
      }
      if (_lineShadeId != null &&
          !_shades.any((s) => _asInt(s['id']) == _lineShadeId)) {
        _lineShadeId = null;
      }
    });
  }

  Future<void> _loadNextOrderNo() async {
    final next = await _db.getNextOrderNo();
    if (!mounted) return;
    setState(() => _nextOrderNo = next);
  }

  Future<void> _loadOpenOrders({required bool preserveSelection}) async {
    final rows = await _db.getOrderSummaries(status: 'open');
    if (!mounted) return;

    setState(() {
      _openOrders = rows;
    });

    if (!preserveSelection || _selectedOrderNo == null) return;

    final stillOpen = rows.any((r) => _asInt(r['order_no']) == _selectedOrderNo);
    if (!stillOpen) {
      _clearSelectedOrder();
      _msg('Selected order is fully closed.');
      return;
    }

    await _loadPurchaseLinesForOrder(_selectedOrderNo!);
  }

  Future<void> _loadReportRows() async {
    if (_loadingReport && mounted) return;
    if (mounted) {
      setState(() => _loadingReport = true);
    }
    final toDateMs = _reportTo == null
        ? null
        : DateTime(_reportTo!.year, _reportTo!.month, _reportTo!.day, 23, 59)
            .millisecondsSinceEpoch;

    final results = await Future.wait([
      _db.getOrderSummaries(
        status: _reportStatus,
        fromDateMs: _reportFrom?.millisecondsSinceEpoch,
        toDateMs: toDateMs,
      ),
      _db.getOrderShadeWiseSummaries(
        status: _reportStatus,
        fromDateMs: _reportFrom?.millisecondsSinceEpoch,
        toDateMs: toDateMs,
      ),
    ]);

    final rows = results[0] as List<Map<String, dynamic>>;
    final shadeRows = results[1] as List<Map<String, dynamic>>;

    if (!mounted) return;
    setState(() {
      _reportRows = rows;
      _reportShadeRows = shadeRows;
      _loadingReport = false;
    });
  }

  Future<void> _pickOrderDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _orderDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _orderDate = picked);
  }

  Future<void> _pickPurchaseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _purchaseDate = picked);
  }

  Future<void> _pickReportFromDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _reportFrom ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _reportFrom = picked);
    await _loadReportRows();
  }

  Future<void> _pickReportToDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _reportTo ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _reportTo = picked);
    await _loadReportRows();
  }

  void _clearSelectedOrder() {
    for (final c in _purchaseQtyCtrls.values) {
      c.dispose();
    }
    _purchaseQtyCtrls.clear();
    if (!mounted) return;
    setState(() {
      _selectedOrderNo = null;
      _selectedOrderMaster = null;
      _selectedOrderLines = [];
    });
  }

  void _addDraftLine() {
    final productId = _lineProductId;
    final qty = double.tryParse(_lineQtyCtrl.text.trim()) ?? 0;
    if (productId == null) {
      _msg('Select product first.');
      return;
    }
    if (qty <= 0) {
      _msg('Enter valid quantity.');
      return;
    }
    final shadeId = _lineShadeId;

    final existing = _draftLines
        .where((e) => e.productId == productId && e.shadeId == shadeId)
        .toList();

    setState(() {
      if (existing.isNotEmpty) {
        existing.first.qty += qty;
      } else {
        _draftLines.add(
          _DraftOrderLine(productId: productId, shadeId: shadeId, qty: qty),
        );
      }
      _lineQtyCtrl.clear();
      _lineShadeId = null;
    });
  }

  Future<void> _saveOrder() async {
    if (_selectedFirmId == null) {
      _msg('Select firm.');
      return;
    }
    if (_selectedPartyId == null) {
      _msg('Select party.');
      return;
    }
    if (_draftLines.isEmpty) {
      _msg('Add at least one line item.');
      return;
    }
    if (_savingOrder) return;

    setState(() => _savingOrder = true);
    try {
      final orderNo = await _db.getNextOrderNo();
      final totalQty = _draftLines.fold<double>(0, (a, b) => a + b.qty);

      await _db.insertOrderMaster({
        'order_no': orderNo,
        'firm_id': _selectedFirmId,
        'order_date': _orderDate.millisecondsSinceEpoch,
        'party_id': _selectedPartyId,
        'remarks': _orderRemarksCtrl.text.trim(),
        'status': 'open',
        'total_qty': totalQty,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      for (final line in _draftLines) {
        await _db.insertOrderItem({
          'order_no': orderNo,
          'product_id': line.productId,
          'shade_id': line.shadeId,
          'qty': line.qty,
        });
      }

      await _db.refreshOrderStatusByNo(orderNo);

      if (!mounted) return;
      setState(() {
        _draftLines.clear();
        _lineProductId = null;
        _lineShadeId = null;
        _lineQtyCtrl.clear();
        _orderRemarksCtrl.clear();
      });

      _msg('Order #$orderNo saved.');
      await _refreshData(preserveOrderSelection: true);
    } catch (e) {
      _msg('Failed to save order: $e');
    } finally {
      if (mounted) {
        setState(() => _savingOrder = false);
      }
    }
  }

  Future<void> _loadPurchaseLinesForOrder(int orderNo) async {
    if (_loadingPurchaseLines) return;
    setState(() => _loadingPurchaseLines = true);
    try {
      final master = await _db.getOrderMasterByNo(orderNo);
      final lines = await _db.getOrderLineProgress(orderNo);

      for (final c in _purchaseQtyCtrls.values) {
        c.dispose();
      }
      _purchaseQtyCtrls.clear();

      for (final line in lines) {
        final lineId = _asInt(line['id']);
        if (lineId == null) continue;
        final pending = _asDouble(line['pending_qty']);
        _purchaseQtyCtrls[lineId] = TextEditingController(
          text: pending > 0 ? pending.toStringAsFixed(2) : '',
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedOrderNo = orderNo;
        _selectedOrderMaster = master;
        _selectedOrderLines = lines;
      });
    } catch (e) {
      _msg('Failed to load order lines: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingPurchaseLines = false);
      }
    }
  }

  Future<void> _savePurchaseAgainstOrder() async {
    final orderNo = _selectedOrderNo;
    final master = _selectedOrderMaster;
    if (orderNo == null || master == null) {
      _msg('Select order number.');
      return;
    }
    if (_savingPurchase) return;

    final firmId = _asInt(master['firm_id']);
    final partyId = _asInt(master['party_id']);
    if (firmId == null || partyId == null) {
      _msg('Order is missing firm/party.');
      return;
    }

    final items = <Map<String, dynamic>>[];
    for (final line in _selectedOrderLines) {
      final lineId = _asInt(line['id']);
      final productId = _asInt(line['product_id']);
      if (lineId == null || productId == null) continue;
      final pending = _asDouble(line['pending_qty']);
      final ctrl = _purchaseQtyCtrls[lineId];
      final qty = double.tryParse(ctrl?.text.trim() ?? '') ?? 0;
      if (qty <= 0) continue;
      if (qty > pending + 0.0001) {
        _msg(
            'Purchase qty cannot be more than pending for ${line['product_name']} / ${line['shade_no']}.');
        return;
      }

      items.add({
        'product_id': productId,
        'shade_id': _asInt(line['shade_id']),
        'qty': qty,
      });
    }

    if (items.isEmpty) {
      _msg('Enter at least one purchase quantity.');
      return;
    }

    setState(() => _savingPurchase = true);
    try {
      final purchaseNo = await _db.createPurchaseFromOrder(
        orderNo: orderNo,
        firmId: firmId,
        partyId: partyId,
        purchaseDateMs: _purchaseDate.millisecondsSinceEpoch,
        invoiceNo: _purchaseInvoiceCtrl.text.trim(),
        items: items,
      );

      _purchaseInvoiceCtrl.clear();
      _msg('Purchase saved (No: $purchaseNo).');

      await _refreshData(preserveOrderSelection: true);
      if (_selectedOrderNo != null) {
        await _loadPurchaseLinesForOrder(_selectedOrderNo!);
      }
    } catch (e) {
      _msg('Failed to save purchase: $e');
    } finally {
      if (mounted) {
        setState(() => _savingPurchase = false);
      }
    }
  }

  Future<void> _openOrderDetailDialog(int orderNo) async {
    final lines = await _db.getOrderLineProgress(orderNo);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Order #$orderNo Details'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: DataTable(
                columnSpacing: 14,
                columns: const [
                  DataColumn(label: Text('Product')),
                  DataColumn(label: Text('Shade')),
                  DataColumn(label: Text('Order')),
                  DataColumn(label: Text('Purchased')),
                  DataColumn(label: Text('Pending')),
                ],
                rows: lines
                    .map(
                      (r) => DataRow(
                        cells: [
                          DataCell(Text((r['product_name'] ?? '').toString())),
                          DataCell(Text((r['shade_no'] ?? 'NO SHADE').toString())),
                          DataCell(Text(_asDouble(r['order_qty']).toStringAsFixed(2))),
                          DataCell(
                              Text(_asDouble(r['purchase_qty']).toStringAsFixed(2))),
                          DataCell(
                              Text(_asDouble(r['pending_qty']).toStringAsFixed(2))),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openEditOrder(int orderNo) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _OrderEditPage(orderNo: orderNo)),
    );
    if (changed != true || !mounted) return;

    await _refreshData(preserveOrderSelection: true);
    if (_selectedOrderNo == orderNo) {
      await _loadPurchaseLinesForOrder(orderNo);
    }
  }

  Future<void> _confirmDeleteOrder(int orderNo) async {
    final purchaseCount = await _db.getOrderPurchaseCount(orderNo);
    if (!mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Delete Order #$orderNo?'),
          content: Text(
            purchaseCount > 0
                ? 'This order has $purchaseCount linked purchase record(s). '
                    'Order delete will also delete linked purchases and stock entries.'
                : 'This will permanently delete this order.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    try {
      await _db.deleteOrderByNo(orderNo);
      if (!mounted) return;
      if (_selectedOrderNo == orderNo) {
        _clearSelectedOrder();
      }
      _msg('Order #$orderNo deleted.');
      await _refreshData(preserveOrderSelection: true);
    } catch (e) {
      _msg('Delete failed: $e');
    }
  }

  Future<pw.ThemeData> _pdfTheme() async {
    try {
      final base = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      return pw.ThemeData.withFont(base: base, bold: bold);
    } catch (_) {
      return pw.ThemeData.base();
    }
  }

  Future<void> _exportReportPdf() async {
    if (_reportRows.isEmpty) {
      _msg('No report data to export.');
      return;
    }

    final totalOrders = _reportRows.length;
    final closed = _reportRows
        .where((r) => (r['status'] ?? '').toString().toLowerCase() == 'closed')
        .length;
    final open = totalOrders - closed;
    final orderedQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['order_qty']));
    final purchasedQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['purchase_qty']));
    final pendingQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['pending_qty']));

    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());
    final fromText =
        _reportFrom == null ? 'Any' : _reportDateFmt.format(_reportFrom!);
    final toText = _reportTo == null ? 'Any' : _reportDateFmt.format(_reportTo!);

    final doc = pw.Document(theme: await _pdfTheme());
    pw.MemoryImage? logoImage;
    try {
      final logoBytes =
          (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
      logoImage = pw.MemoryImage(logoBytes);
    } catch (_) {}

    final rows = _reportRows
        .map((r) => [
              (r['order_no'] ?? '').toString(),
              _dateFromMs(r['order_date']),
              (r['firm_name'] ?? '').toString(),
              (r['party_name'] ?? '').toString(),
              (r['status'] ?? '').toString().toUpperCase(),
              _asDouble(r['order_qty']).toStringAsFixed(2),
              _asDouble(r['purchase_qty']).toStringAsFixed(2),
              _asDouble(r['pending_qty']).toStringAsFixed(2),
            ])
        .toList();

    final shadeRows = _reportShadeRows
        .map((r) => [
              (r['order_no'] ?? '').toString(),
              (r['product_name'] ?? '').toString(),
              (r['shade_no'] ?? 'NO SHADE').toString(),
              _asDouble(r['order_qty']).toStringAsFixed(2),
              _asDouble(r['purchase_qty']).toStringAsFixed(2),
              _asDouble(r['pending_qty']).toStringAsFixed(2),
            ])
        .toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => [
          if (logoImage != null)
            pw.Center(child: pw.Image(logoImage, width: 46, height: 46)),
          pw.SizedBox(height: 6),
          pw.Text(
            'Order Report',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Generated: $now',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.Text(
            'Filters - Status: ${_reportStatus.toUpperCase()}, From: $fromText, To: $toText',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pdfMetric('Orders', '$totalOrders'),
              _pdfMetric('Open', '$open'),
              _pdfMetric('Closed', '$closed'),
              _pdfMetric('Ordered', orderedQty.toStringAsFixed(2)),
              _pdfMetric('Purchased', purchasedQty.toStringAsFixed(2)),
              _pdfMetric('Pending', pendingQty.toStringAsFixed(2)),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: const [
              'Order No',
              'Date',
              'Firm',
              'Party',
              'Status',
              'Ordered',
              'Purchased',
              'Pending',
            ],
            data: rows,
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.blueGrey100),
            cellAlignment: pw.Alignment.centerLeft,
          ),
          if (shadeRows.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              'Shade-wise Details',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headers: const [
                'Order No',
                'Product',
                'Shade',
                'Ordered',
                'Purchased',
                'Pending',
              ],
              data: shadeRows,
              headerStyle: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
              ),
              cellStyle: const pw.TextStyle(fontSize: 8.5),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.blueGrey100),
              cellAlignment: pw.Alignment.centerLeft,
            ),
          ],
        ],
      ),
    );

    await Printing.layoutPdf(
      name: 'Order_Report.pdf',
      onLayout: (_) => doc.save(),
    );
  }

  pw.Widget _pdfMetric(String title, String value) {
    return pw.Container(
      width: 110,
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.blueGrey300),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(title, style: const pw.TextStyle(fontSize: 8)),
          pw.SizedBox(height: 2),
          pw.Text(
            value,
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Future<void> _exportOrderNoPdf(int orderNo) async {
    final master = await _db.getOrderMasterByNo(orderNo);
    final lines = await _db.getOrderLineProgress(orderNo);
    if (master == null || lines.isEmpty) {
      _msg('Order data not found for PDF.');
      return;
    }

    final doc = pw.Document(theme: await _pdfTheme());
    final now = DateFormat('dd-MM-yyyy HH:mm').format(DateTime.now());

    final orderQty = lines.fold<double>(
        0, (s, r) => s + ((r['order_qty'] as num?)?.toDouble() ?? 0));
    final purchasedQty = lines.fold<double>(
        0, (s, r) => s + ((r['purchase_qty'] as num?)?.toDouble() ?? 0));
    final pendingQty = lines.fold<double>(
        0, (s, r) => s + ((r['pending_qty'] as num?)?.toDouble() ?? 0));

    final tableRows = lines
        .map((r) => [
              (r['product_name'] ?? '').toString(),
              (r['shade_no'] ?? 'NO SHADE').toString(),
              _asDouble(r['order_qty']).toStringAsFixed(2),
              _asDouble(r['purchase_qty']).toStringAsFixed(2),
              _asDouble(r['pending_qty']).toStringAsFixed(2),
            ])
        .toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (ctx) => [
          pw.Text(
            'Order No Report - #$orderNo',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text('Generated: $now', style: const pw.TextStyle(fontSize: 9)),
          pw.Text(
            'Date: ${_dateFromMs(master['order_date'])}    '
            'Status: ${(master['status'] ?? '').toString().toUpperCase()}',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.Text('Firm: ${(master['firm_name'] ?? '').toString()}',
              style: const pw.TextStyle(fontSize: 9)),
          pw.Text('Party: ${(master['party_name'] ?? '').toString()}',
              style: const pw.TextStyle(fontSize: 9)),
          if ((master['remarks'] ?? '').toString().trim().isNotEmpty)
            pw.Text('Remarks: ${(master['remarks'] ?? '').toString()}',
                style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 8),
          pw.Row(
            children: [
              _pdfMetric('Ordered', orderQty.toStringAsFixed(2)),
              pw.SizedBox(width: 8),
              _pdfMetric('Purchased', purchasedQty.toStringAsFixed(2)),
              pw.SizedBox(width: 8),
              _pdfMetric('Pending', pendingQty.toStringAsFixed(2)),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: const ['Product', 'Shade', 'Order', 'Purchased', 'Pending'],
            data: tableRows,
            headerStyle:
                pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.blueGrey100),
            cellAlignment: pw.Alignment.centerLeft,
          ),
        ],
      ),
    );

    await Printing.layoutPdf(
      name: 'Order_$orderNo.pdf',
      onLayout: (_) => doc.save(),
    );
  }

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _asDouble(dynamic value) {
    if (value == null) return 0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  String _dateFromMs(dynamic ms) {
    final value = _asInt(ms);
    if (value == null || value <= 0) return '-';
    return _reportDateFmt.format(DateTime.fromMillisecondsSinceEpoch(value));
  }

  String _partyNameById(int? id) {
    if (id == null) return '';
    for (final party in _parties) {
      if (party.id == id) return party.name;
    }
    return '';
  }

  String _productNameById(int? id) {
    if (id == null) return '';
    final p = _products.cast<Product?>().firstWhere(
          (e) => e?.id == id,
          orElse: () => null,
        );
    return p?.name ?? '';
  }

  String _unitByProductId(int? id) {
    if (id == null) return 'Qty';
    final p = _products.cast<Product?>().firstWhere(
          (e) => e?.id == id,
          orElse: () => null,
        );
    return p?.unit ?? 'Qty';
  }

  String _shadeNameById(int? id) {
    if (id == null || id == 0) return 'NO SHADE';
    final s = _shades.cast<Map<String, dynamic>?>().firstWhere(
          (e) => _asInt(e?['id']) == id,
          orElse: () => null,
        );
    return (s?['shade_no'] ?? 'NO SHADE').toString();
  }

  @override
  Widget build(BuildContext context) {
    final initialTab = widget.initialTab < 0
        ? 0
        : (widget.initialTab > 2 ? 2 : widget.initialTab);

    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Order Management'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Create Order'),
              Tab(text: 'Purchase by Order'),
              Tab(text: 'Report'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _buildCreateOrderTab(),
                  _buildPurchaseByOrderTab(),
                  _buildReportTab(),
                ],
              ),
      ),
    );
  }

  Widget _buildCreateOrderTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Next Order No: $_nextOrderNo',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickOrderDate,
                        icon: const Icon(Icons.calendar_month),
                        label: Text(_reportDateFmt.format(_orderDate)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _selectedFirmId,
                    decoration: const InputDecoration(labelText: 'Firm'),
                    items: _firms
                        .map(
                          (f) => DropdownMenuItem<int>(
                            value: _asInt(f['id']),
                            child: Text((f['firm_name'] ?? '').toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedFirmId = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _selectedPartyId,
                    decoration: const InputDecoration(labelText: 'Party'),
                    items: _parties
                        .where((p) => p.id != null)
                        .map(
                          (p) => DropdownMenuItem<int>(
                            value: p.id!,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedPartyId = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _orderRemarksCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Remarks (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Add Line Item',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _lineProductId,
                    decoration: const InputDecoration(labelText: 'Product'),
                    items: _products
                        .where((p) => p.id != null)
                        .map(
                          (p) => DropdownMenuItem<int>(
                            value: p.id!,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _lineProductId = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    value: _lineShadeId,
                    decoration: const InputDecoration(labelText: 'Shade'),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('NO SHADE'),
                      ),
                      ..._shades.map(
                        (s) => DropdownMenuItem<int?>(
                          value: _asInt(s['id']),
                          child: Text((s['shade_no'] ?? '').toString()),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _lineShadeId = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _lineQtyCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Qty (${_unitByProductId(_lineProductId)})',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _addDraftLine,
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Order Items',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text('Total: ${_draftLines.length}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_draftLines.isEmpty)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('No items added yet.'),
                    )
                  else
                    ..._draftLines.asMap().entries.map((entry) {
                      final index = entry.key;
                      final line = entry.value;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_productNameById(line.productId)),
                        subtitle: Text(
                          '${_shadeNameById(line.shadeId)}  |  ${line.qty.toStringAsFixed(2)} ${_unitByProductId(line.productId)}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() => _draftLines.removeAt(index));
                          },
                        ),
                      );
                    }),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _savingOrder ? null : _saveOrder,
                      icon: _savingOrder
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save),
                      label: Text(_savingOrder ? 'Saving...' : 'Save Order'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPurchaseByOrderTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  DropdownButtonFormField<int>(
                    value: _selectedOrderNo,
                    decoration: const InputDecoration(labelText: 'Order No'),
                    items: _openOrders
                        .map(
                          (o) => DropdownMenuItem<int>(
                            value: _asInt(o['order_no']),
                            child: Text(
                              '#${o['order_no']}  -  ${(o['party_name'] ?? '').toString()}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) {
                        _clearSelectedOrder();
                        return;
                      }
                      unawaited(_loadPurchaseLinesForOrder(v));
                    },
                  ),
                  if (_openOrders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('No open orders found.'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _purchaseInvoiceCtrl,
                    decoration: const InputDecoration(labelText: 'Bill No'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Purchase Date:'),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _pickPurchaseDate,
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: Text(_reportDateFmt.format(_purchaseDate)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_selectedOrderMaster != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Order #${_selectedOrderMaster?['order_no'] ?? ''}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                        ),
                        Text(
                          (_selectedOrderMaster?['status'] ?? '')
                              .toString()
                              .toUpperCase(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.teal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Party: ${(_selectedOrderMaster?['party_name'] ?? _partyNameById(_asInt(_selectedOrderMaster?['party_id']))).toString()}',
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Date: ${_dateFromMs(_selectedOrderMaster?['order_date'])}',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _selectedOrderNo == null
                            ? null
                            : () => _exportOrderNoPdf(_selectedOrderNo!),
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('Order No PDF'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Pending Lines',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_loadingPurchaseLines)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_selectedOrderNo == null)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Select order to load pending lines.'),
                    )
                  else if (_selectedOrderLines.isEmpty)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('No lines found for this order.'),
                    )
                  else ..._selectedOrderLines.map((line) {
                    final pending = _asDouble(line['pending_qty']);
                    if (pending <= 0) {
                      return const SizedBox.shrink();
                    }
                    final lineId = _asInt(line['id']);
                    if (lineId == null) return const SizedBox.shrink();
                    final ctrl = _purchaseQtyCtrls[lineId];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${line['product_name']}  |  ${line['shade_no']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Order: ${_asDouble(line['order_qty']).toStringAsFixed(2)}   '
                              'Purchased: ${_asDouble(line['purchase_qty']).toStringAsFixed(2)}   '
                              'Pending: ${pending.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: ctrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: InputDecoration(
                                labelText:
                                    'Purchase qty (${(line['product_unit'] ?? 'Qty').toString()})',
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          _savingPurchase ? null : _savePurchaseAgainstOrder,
                      icon: _savingPurchase
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.shopping_bag),
                      label:
                          Text(_savingPurchase ? 'Saving...' : 'Save Purchase'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportTab() {
    final totalOrders = _reportRows.length;
    final closed = _reportRows
        .where((r) => (r['status'] ?? '').toString().toLowerCase() == 'closed')
        .length;
    final open = totalOrders - closed;
    final orderedQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['order_qty']));
    final purchasedQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['purchase_qty']));
    final pendingQty =
        _reportRows.fold<double>(0, (s, r) => s + _asDouble(r['pending_qty']));
    final shadeByOrderNo = <int, List<Map<String, dynamic>>>{};
    for (final row in _reportShadeRows) {
      final orderNo = _asInt(row['order_no']);
      if (orderNo == null) continue;
      shadeByOrderNo.putIfAbsent(orderNo, () => <Map<String, dynamic>>[]).add(row);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _reportStatus,
                          decoration:
                              const InputDecoration(labelText: 'Status'),
                          items: const [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text('All'),
                            ),
                            DropdownMenuItem(
                              value: 'open',
                              child: Text('Open'),
                            ),
                            DropdownMenuItem(
                              value: 'closed',
                              child: Text('Closed'),
                            ),
                          ],
                          onChanged: (v) async {
                            if (v == null) return;
                            setState(() => _reportStatus = v);
                            await _loadReportRows();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Refresh',
                        onPressed: _loadReportRows,
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        tooltip: 'Export PDF',
                        onPressed: _exportReportPdf,
                        icon: const Icon(Icons.picture_as_pdf),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickReportFromDate,
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            _reportFrom == null
                                ? 'From Date'
                                : _reportDateFmt.format(_reportFrom!),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickReportToDate,
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(
                            _reportTo == null
                                ? 'To Date'
                                : _reportDateFmt.format(_reportTo!),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Clear date filters',
                        onPressed: () async {
                          setState(() {
                            _reportFrom = null;
                            _reportTo = null;
                          });
                          await _loadReportRows();
                        },
                        icon: const Icon(Icons.clear),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statCard('Orders', '$totalOrders'),
              _statCard('Open', '$open'),
              _statCard('Closed', '$closed'),
              _statCard('Ordered Qty', orderedQty.toStringAsFixed(2)),
              _statCard('Purchased Qty', purchasedQty.toStringAsFixed(2)),
              _statCard('Pending Qty', pendingQty.toStringAsFixed(2)),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingReport)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            )
          else if (_reportRows.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No report data found.'),
                ),
              ),
            )
          else
            ..._reportRows.map((row) {
              final orderNo = _asInt(row['order_no']) ?? 0;
              final status = (row['status'] ?? '').toString();
              final shadeRows = shadeByOrderNo[orderNo] ?? const <Map<String, dynamic>>[];
              return Card(
                child: ListTile(
                  onTap: () => _openOrderDetailDialog(orderNo),
                  title: Text(
                      'Order #$orderNo  |  ${(row['party_name'] ?? '').toString()}'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Date: ${_dateFromMs(row['order_date'])}',
                      ),
                      Text(
                        'Status: ${status.toUpperCase()}  |  '
                        'Ordered: ${_asDouble(row['order_qty']).toStringAsFixed(2)}   '
                        'Purchased: ${_asDouble(row['purchase_qty']).toStringAsFixed(2)}   '
                        'Pending: ${_asDouble(row['pending_qty']).toStringAsFixed(2)}',
                      ),
                      if (shadeRows.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        const Text(
                          'Shade-wise:',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        ...shadeRows.map(
                          (s) => Text(
                            '${(s['product_name'] ?? '').toString()} | ${(s['shade_no'] ?? 'NO SHADE').toString()}'
                            ' : O ${_asDouble(s['order_qty']).toStringAsFixed(2)}'
                            ' / P ${_asDouble(s['purchase_qty']).toStringAsFixed(2)}'
                            ' / B ${_asDouble(s['pending_qty']).toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Order Actions',
                    onSelected: (value) {
                      if (value == 'view') {
                        _openOrderDetailDialog(orderNo);
                      } else if (value == 'edit') {
                        _openEditOrder(orderNo);
                      } else if (value == 'pdf') {
                        _exportOrderNoPdf(orderNo);
                      } else if (value == 'delete') {
                        _confirmDeleteOrder(orderNo);
                      }
                    },
                    itemBuilder: (ctx) => const [
                      PopupMenuItem(
                        value: 'view',
                        child: Text('View Details'),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit Order'),
                      ),
                      PopupMenuItem(
                        value: 'pdf',
                        child: Text('Order No PDF'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete Order'),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      width: 165,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _DraftOrderLine {
  final int productId;
  final int? shadeId;
  double qty;

  _DraftOrderLine({
    required this.productId,
    required this.shadeId,
    required this.qty,
  });
}

class _OrderEditPage extends StatefulWidget {
  final int orderNo;

  const _OrderEditPage({required this.orderNo});

  @override
  State<_OrderEditPage> createState() => _OrderEditPageState();
}

class _OrderEditPageState extends State<_OrderEditPage> {
  final _db = ErpDatabase.instance;
  final _dateFmt = DateFormat('dd-MM-yyyy');
  final _remarksCtrl = TextEditingController();
  final _addQtyCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  DateTime _orderDate = DateTime.now();
  int? _firmId;
  int? _partyId;
  int? _addProductId;
  int? _addShadeId;

  List<Map<String, dynamic>> _firms = [];
  List<Party> _parties = [];
  List<Product> _products = [];
  List<Map<String, dynamic>> _shades = [];
  final List<_EditableOrderLine> _lines = [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    _addQtyCtrl.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _asDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  String _lineKey(int productId, int? shadeId) => '$productId:${shadeId ?? 0}';

  String _productNameById(int productId) {
    for (final p in _products) {
      if (p.id == productId) return p.name;
    }
    return 'Product $productId';
  }

  String _unitByProductId(int productId) {
    for (final p in _products) {
      if (p.id == productId) return p.unit;
    }
    return 'Qty';
  }

  String _shadeNoById(int? shadeId) {
    if (shadeId == null || shadeId == 0) return 'NO SHADE';
    for (final s in _shades) {
      if (_asInt(s['id']) == shadeId) {
        return (s['shade_no'] ?? 'NO SHADE').toString();
      }
    }
    return 'NO SHADE';
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _db.getFirms(),
      _db.getParties(),
      _db.getProducts(),
      _db.getFabricShades(),
      _db.getOrderMasterByNo(widget.orderNo),
      _db.getOrderLineProgress(widget.orderNo),
    ]);

    final firms = results[0] as List<Map<String, dynamic>>;
    final parties = (results[1] as List<Party>)
        .where((p) => p.partyType == 'Purchase')
        .toList();
    final products = results[2] as List<Product>;
    final shades = results[3] as List<Map<String, dynamic>>;
    final master = results[4] as Map<String, dynamic>?;
    final lines = results[5] as List<Map<String, dynamic>>;

    if (master == null) {
      if (!mounted) return;
      _msg('Order not found.');
      Navigator.pop(context);
      return;
    }

    for (final line in _lines) {
      line.dispose();
    }
    _lines.clear();

    for (final row in lines) {
      final productId = _asInt(row['product_id']);
      if (productId == null) continue;
      final shadeId = _asInt(row['shade_id']);
      final orderQty = _asDouble(row['order_qty']);
      final purchasedQty = _asDouble(row['purchase_qty']);

      _lines.add(
        _EditableOrderLine(
          productId: productId,
          shadeId: shadeId,
          purchasedQty: purchasedQty,
          productName: (row['product_name'] ?? '').toString(),
          shadeNo: (row['shade_no'] ?? 'NO SHADE').toString(),
          unit: (row['product_unit'] ?? 'Qty').toString(),
          qtyCtrl: TextEditingController(
            text: orderQty > 0 ? orderQty.toStringAsFixed(2) : '',
          ),
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _firms = firms;
      _parties = parties;
      _products = products;
      _shades = shades;

      _firmId = _asInt(master['firm_id']);
      _partyId = _asInt(master['party_id']);
      _remarksCtrl.text = (master['remarks'] ?? '').toString();
      final orderDateMs = _asInt(master['order_date']);
      if (orderDateMs != null) {
        _orderDate = DateTime.fromMillisecondsSinceEpoch(orderDateMs);
      }
      _loading = false;
    });
  }

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickOrderDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _orderDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _orderDate = picked);
  }

  void _addLine() {
    final productId = _addProductId;
    final qty = double.tryParse(_addQtyCtrl.text.trim()) ?? 0;
    if (productId == null) {
      _msg('Select product first.');
      return;
    }
    if (qty <= 0) {
      _msg('Enter valid quantity.');
      return;
    }
    final shadeId = _addShadeId;
    final key = _lineKey(productId, shadeId);

    final index = _lines.indexWhere((l) => _lineKey(l.productId, l.shadeId) == key);
    if (index >= 0) {
      final existing = _lines[index];
      final oldQty = double.tryParse(existing.qtyCtrl.text.trim()) ?? 0;
      existing.qtyCtrl.text = (oldQty + qty).toStringAsFixed(2);
    } else {
      _lines.add(
        _EditableOrderLine(
          productId: productId,
          shadeId: shadeId,
          purchasedQty: 0,
          productName: _productNameById(productId),
          shadeNo: _shadeNoById(shadeId),
          unit: _unitByProductId(productId),
          qtyCtrl: TextEditingController(text: qty.toStringAsFixed(2)),
        ),
      );
    }

    setState(() {
      _addQtyCtrl.clear();
      _addShadeId = null;
    });
  }

  void _removeLine(int index) {
    final line = _lines[index];
    if (line.purchasedQty > 0) {
      _msg('Cannot delete line with purchased qty.');
      return;
    }
    setState(() {
      line.dispose();
      _lines.removeAt(index);
    });
  }

  Future<void> _save() async {
    if (_firmId == null) {
      _msg('Select firm.');
      return;
    }
    if (_partyId == null) {
      _msg('Select party.');
      return;
    }
    if (_lines.isEmpty) {
      _msg('Add at least one line.');
      return;
    }
    if (_saving) return;

    final items = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final qty = double.tryParse(line.qtyCtrl.text.trim()) ?? 0;
      if (qty <= 0) {
        _msg('Order qty must be greater than zero.');
        return;
      }
      if (qty + 0.0001 < line.purchasedQty) {
        _msg(
          'Order qty cannot be less than purchased qty for ${line.productName} / ${line.shadeNo}.',
        );
        return;
      }
      items.add({
        'product_id': line.productId,
        'shade_id': line.shadeId,
        'qty': qty,
      });
    }

    setState(() => _saving = true);
    try {
      await _db.updateOrderByNo(
        orderNo: widget.orderNo,
        firmId: _firmId!,
        partyId: _partyId!,
        orderDateMs: _orderDate.millisecondsSinceEpoch,
        remarks: _remarksCtrl.text.trim(),
        items: items,
      );
      if (!mounted) return;
      _msg('Order updated.');
      Navigator.pop(context, true);
    } catch (e) {
      _msg('Update failed: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Order #${widget.orderNo}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Order Header',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _pickOrderDate,
                                icon: const Icon(Icons.calendar_today, size: 18),
                                label: Text(_dateFmt.format(_orderDate)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int>(
                            value: _firmId,
                            decoration: const InputDecoration(labelText: 'Firm'),
                            items: _firms
                                .map(
                                  (f) => DropdownMenuItem<int>(
                                    value: _asInt(f['id']),
                                    child:
                                        Text((f['firm_name'] ?? '').toString()),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _firmId = v),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int>(
                            value: _partyId,
                            decoration: const InputDecoration(labelText: 'Party'),
                            items: _parties
                                .where((p) => p.id != null)
                                .map(
                                  (p) => DropdownMenuItem<int>(
                                    value: p.id!,
                                    child: Text(p.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _partyId = v),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _remarksCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Remarks',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Add Line',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int>(
                            value: _addProductId,
                            decoration:
                                const InputDecoration(labelText: 'Product'),
                            items: _products
                                .where((p) => p.id != null)
                                .map(
                                  (p) => DropdownMenuItem<int>(
                                    value: p.id!,
                                    child: Text(p.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(() => _addProductId = v),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int?>(
                            value: _addShadeId,
                            decoration: const InputDecoration(labelText: 'Shade'),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('NO SHADE'),
                              ),
                              ..._shades.map(
                                (s) => DropdownMenuItem<int?>(
                                  value: _asInt(s['id']),
                                  child: Text((s['shade_no'] ?? '').toString()),
                                ),
                              ),
                            ],
                            onChanged: (v) => setState(() => _addShadeId = v),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _addQtyCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: 'Qty',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: _addLine,
                                icon: const Icon(Icons.add),
                                label: const Text('Add'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Order Lines',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_lines.isEmpty)
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('No lines available.'),
                            )
                          else
                            ..._lines.asMap().entries.map((entry) {
                              final index = entry.key;
                              final line = entry.value;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${line.productName} | ${line.shadeNo}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () => _removeLine(index),
                                          icon:
                                              const Icon(Icons.delete_outline),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      'Purchased: ${line.purchasedQty.toStringAsFixed(2)} ${line.unit}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    const SizedBox(height: 4),
                                    TextField(
                                      controller: line.qtyCtrl,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      decoration: InputDecoration(
                                        labelText: 'Order Qty (${line.unit})',
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save),
                              label:
                                  Text(_saving ? 'Saving...' : 'Save Changes'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _EditableOrderLine {
  final int productId;
  final int? shadeId;
  final double purchasedQty;
  final String productName;
  final String shadeNo;
  final String unit;
  final TextEditingController qtyCtrl;

  _EditableOrderLine({
    required this.productId,
    required this.shadeId,
    required this.purchasedQty,
    required this.productName,
    required this.shadeNo,
    required this.unit,
    required this.qtyCtrl,
  });

  void dispose() {
    qtyCtrl.dispose();
  }
}
