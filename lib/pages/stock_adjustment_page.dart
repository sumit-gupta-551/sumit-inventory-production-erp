import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/erp_database.dart';

class StockAdjustmentPage extends StatefulWidget {
  const StockAdjustmentPage({super.key});

  @override
  State<StockAdjustmentPage> createState() => _StockAdjustmentPageState();
}

class _StockAdjustmentPageState extends State<StockAdjustmentPage> {
  // ---------------- MASTER DATA ----------------
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];
  Map<int, Set<int>> productShadeIds = {};

  int? productId;
  int? shadeId;
  String type = 'IN';
  int? editingIndex;
  double? _stockBalance;

  final dateCtrl = TextEditingController();

  final qtyCtrl = TextEditingController();
  final reasonCtrl = TextEditingController();
  final List<Map<String, dynamic>> items = [];

  // ---- PAST ADJUSTMENTS ----
  List<Map<String, dynamic>> pastAdjustments = [];
  bool showPast = false;
  int? _editingPastId;
  final _pastQtyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    final db = await ErpDatabase.instance.database;
    final results = await Future.wait([
      db.query('products'),
      db.query('fabric_shades'),
      db.rawQuery('''
        SELECT DISTINCT product_id, shade_id
        FROM purchase_items
        WHERE product_id IS NOT NULL AND shade_id IS NOT NULL
      '''),
      db.rawQuery('''
        SELECT DISTINCT product_id, fabric_shade_id AS shade_id
        FROM stock_ledger
        WHERE product_id IS NOT NULL AND fabric_shade_id IS NOT NULL
      '''),
    ]);
    products = results[0] as List<Map<String, dynamic>>;
    shades = results[1] as List<Map<String, dynamic>>;

    final map = <int, Set<int>>{};
    for (final list in [results[2], results[3]]) {
      for (final r in list as List<Map<String, dynamic>>) {
        final pid = r['product_id'] as int?;
        final sid = r['shade_id'] as int?;
        if (pid == null || sid == null) continue;
        map.putIfAbsent(pid, () => <int>{}).add(sid);
      }
    }
    productShadeIds = map;

    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> _filteredShades() {
    if (productId == null) return [];
    final productName = products
            .cast<Map<String, dynamic>?>()
            .firstWhere((p) => p?['id'] == productId,
                orElse: () => null)?['name']
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';

    final byName = shades.where((s) {
      final n = (s['shade_name'] ?? '').toString().trim().toLowerCase();
      return n == productName;
    });

    final linkedIds = productShadeIds[productId!] ?? <int>{};
    final byHistory = shades.where((s) {
      final id = s['id'] as int?;
      return id != null && linkedIds.contains(id);
    });

    final merged = <int, Map<String, dynamic>>{};
    for (final s in byName) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }
    for (final s in byHistory) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }

    final list = merged.values.toList();
    list.sort((a, b) => (a['shade_no'] ?? '')
        .toString()
        .compareTo((b['shade_no'] ?? '').toString()));
    return list;
  }

  int _dateMillis() {
    try {
      return DateFormat('dd-MM-yyyy')
          .parse(dateCtrl.text)
          .millisecondsSinceEpoch;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateFormat('dd-MM-yyyy').parse(dateCtrl.text),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected != null) {
      setState(() {
        dateCtrl.text = DateFormat('dd-MM-yyyy').format(selected);
      });
    }
  }

  Future<void> _refreshBalance() async {
    if (productId == null || shadeId == null) {
      if (_stockBalance != null) setState(() => _stockBalance = null);
      return;
    }
    final bal = await ErpDatabase.instance.getCurrentStockBalance(
      productId: productId!,
      fabricShadeId: shadeId!,
    );
    if (!mounted) return;
    setState(() => _stockBalance = bal);
  }

  String _shadeNo(int? id) {
    if (id == null) return '-';
    final found = shades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == id,
          orElse: () => null,
        );
    return (found?['shade_no'] ?? '-').toString();
  }

  void _addOrUpdateRow() {
    final qty = double.tryParse(qtyCtrl.text.trim());

    if (productId == null || shadeId == null || qty == null || qty <= 0) {
      _msg('Please fill all fields correctly');
      return;
    }

    setState(() {
      if (editingIndex != null) {
        items[editingIndex!] = {
          'shade_id': shadeId,
          'shade_no': _shadeNo(shadeId),
          'qty': qty,
          'type': type,
        };
      } else {
        items.add({
          'shade_id': shadeId,
          'shade_no': _shadeNo(shadeId),
          'qty': qty,
          'type': type,
        });
      }

      editingIndex = null;
      shadeId = null;
      qtyCtrl.clear();
    });
  }

  void _startEditRow(int index) {
    final row = items[index];
    setState(() {
      editingIndex = index;
      shadeId = row['shade_id'] as int?;
      type = (row['type'] as String?) ?? 'IN';
      qtyCtrl.text = ((row['qty'] as num?)?.toDouble() ?? 0).toString();
    });
  }

  void _cancelEdit() {
    setState(() {
      editingIndex = null;
      shadeId = null;
      qtyCtrl.clear();
    });
  }

  // ---------------- SAVE ADJUSTMENT ----------------
  Future<void> _saveAll() async {
    if (productId == null || items.isEmpty) {
      _msg('Select product and add at least one shade row');
      return;
    }

    final warningLines = <String>[];
    int savedCount = 0;

    try {
      // Pre-check for negative balances
      for (final row in items) {
        final rowShadeId = row['shade_id'] as int?;
        final rowQty = (row['qty'] as num?)?.toDouble() ?? 0;
        final rowType = (row['type'] as String?) ?? 'IN';
        if (rowShadeId == null || rowQty <= 0) continue;

        if (rowType == 'OUT') {
          final current = await ErpDatabase.instance.getCurrentStockBalance(
            productId: productId!,
            fabricShadeId: rowShadeId,
          );
          final projected = current - rowQty;
          if (projected < 0) {
            warningLines.add(
              '${_shadeNo(rowShadeId)}: ${projected.toStringAsFixed(2)}',
            );
          }
        }
      }

      if (warningLines.isNotEmpty) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
              'These shades will go negative:\n${warningLines.join('\n')}\n\nProceed anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Proceed'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }

      for (final row in items) {
        final rowShadeId = row['shade_id'] as int?;
        final rowQty = (row['qty'] as num?)?.toDouble() ?? 0;
        final rowType = (row['type'] as String?) ?? 'IN';
        if (rowShadeId == null || rowQty <= 0) continue;

        await ErpDatabase.instance.insertLedger({
          'product_id': productId,
          'fabric_shade_id': rowShadeId,
          'qty': rowQty,
          'type': rowType,
          'date': _dateMillis(),
          'reference': 'ADJUSTMENT',
          'remarks': reasonCtrl.text.trim(),
        });
        savedCount++;
      }

      // reset form
      setState(() {
        productId = null;
        shadeId = null;
        _stockBalance = null;
        type = 'IN';
        editingIndex = null;
        dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
        qtyCtrl.clear();
        reasonCtrl.clear();
        items.clear();
      });

      _msg('$savedCount shade(s) adjusted successfully');
    } catch (e) {
      debugPrint('Stock adjustment error: $e');
      _msg('Error saving adjustment: $e');
    }
  }

  void _msg(String text) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(text)));
    } catch (_) {}
  }

  // ---- PAST ADJUSTMENTS ----
  Future<void> _loadPastAdjustments() async {
    final db = await ErpDatabase.instance.database;
    final rows = await db.rawQuery('''
      SELECT sl.id, sl.product_id, sl.fabric_shade_id, sl.qty, sl.type,
             sl.date, sl.remarks,
             p.name AS product_name, fs.shade_no
      FROM stock_ledger sl
      LEFT JOIN products p ON p.id = sl.product_id
      LEFT JOIN fabric_shades fs ON fs.id = sl.fabric_shade_id
      WHERE sl.reference = 'ADJUSTMENT'
      ORDER BY sl.date DESC, sl.id DESC
    ''');
    if (!mounted) return;
    setState(() => pastAdjustments =
        rows.map((r) => Map<String, dynamic>.from(r)).toList());
  }

  Future<void> _toggleType(Map<String, dynamic> entry) async {
    final id = entry['id'] as int;
    final currentType = (entry['type'] ?? 'IN').toString();
    final newType = currentType == 'IN' ? 'OUT' : 'IN';
    final qty = (entry['qty'] as num?)?.toDouble() ?? 0;
    final pId = entry['product_id'] as int;
    final sId = entry['fabric_shade_id'] as int;

    // If changing to OUT (or from IN→OUT which swings by 2x qty), check balance
    if (newType == 'OUT') {
      final current = await ErpDatabase.instance.getCurrentStockBalance(
        productId: pId,
        fabricShadeId: sId,
      );
      // Swing = remove old IN (+qty) and add new OUT (-qty) = -2*qty
      final projected = current - (2 * qty);
      if (projected < 0) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
              'Changing to OUT will make balance ${projected.toStringAsFixed(2)}.\nProceed?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Proceed'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    await ErpDatabase.instance.updateLedgerFull(
      id: id,
      productId: pId,
      fabricShadeId: sId,
      type: newType,
      qty: qty,
      remarks: entry['remarks']?.toString(),
    );
    if (!mounted) return;
    await _loadPastAdjustments();
    _msg('Changed to $newType');
  }

  void _startEditPast(Map<String, dynamic> entry) {
    setState(() {
      _editingPastId = entry['id'] as int;
      _pastQtyCtrl.text =
          ((entry['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);
    });
  }

  void _cancelEditPast() {
    setState(() {
      _editingPastId = null;
      _pastQtyCtrl.clear();
    });
  }

  Future<void> _saveEditPast(Map<String, dynamic> entry) async {
    final id = entry['id'] as int;
    final newQty = double.tryParse(_pastQtyCtrl.text.trim());
    if (newQty == null || newQty <= 0) {
      _msg('Enter a valid qty');
      return;
    }

    final entryType = (entry['type'] ?? 'IN').toString();
    final oldQty = (entry['qty'] as num?)?.toDouble() ?? 0;
    final pId = entry['product_id'] as int;
    final sId = entry['fabric_shade_id'] as int;

    // Check if increasing OUT qty or decreasing IN qty causes negative balance
    if (entryType == 'OUT' && newQty > oldQty) {
      final current = await ErpDatabase.instance
          .getCurrentStockBalance(productId: pId, fabricShadeId: sId);
      final projected = current - (newQty - oldQty);
      if (projected < 0) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
                'Increasing OUT qty will make balance ${projected.toStringAsFixed(2)}.\nProceed?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Proceed')),
            ],
          ),
        );
        if (proceed != true) return;
      }
    } else if (entryType == 'IN' && newQty < oldQty) {
      final current = await ErpDatabase.instance
          .getCurrentStockBalance(productId: pId, fabricShadeId: sId);
      final projected = current - (oldQty - newQty);
      if (projected < 0) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
                'Reducing IN qty will make balance ${projected.toStringAsFixed(2)}.\nProceed?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Proceed')),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    await ErpDatabase.instance.updateLedgerFull(
      id: id,
      productId: pId,
      fabricShadeId: sId,
      type: entryType,
      qty: newQty,
      remarks: entry['remarks']?.toString(),
    );
    if (!mounted) return;
    setState(() {
      _editingPastId = null;
      _pastQtyCtrl.clear();
    });
    await _loadPastAdjustments();
    _msg('Qty updated');
  }

  Future<void> _deletePastEntry(Map<String, dynamic> entry) async {
    final id = entry['id'] as int;
    final entryType = (entry['type'] ?? 'IN').toString();
    final qty = (entry['qty'] as num?)?.toDouble() ?? 0;
    final pId = entry['product_id'] as int;
    final sId = entry['fabric_shade_id'] as int;

    // Deleting an IN entry reduces balance; check for negative
    if (entryType == 'IN' && qty > 0) {
      final current = await ErpDatabase.instance
          .getCurrentStockBalance(productId: pId, fabricShadeId: sId);
      final projected = current - qty;
      if (projected < 0) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
                'Deleting this IN entry will make balance ${projected.toStringAsFixed(2)}.\nProceed?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Proceed')),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    await ErpDatabase.instance.deleteLedgerEntry(id);
    if (!mounted) return;
    _msg('Entry deleted from app and Firebase');
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stock Adjustment')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Adjustment Date',
                        border: OutlineInputBorder(),
                      ),
                      child: Text(dateCtrl.text),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ---------------- PRODUCT ----------------
            DropdownButtonFormField<int>(
              value: productId,
              decoration: const InputDecoration(
                labelText: 'Product',
                border: OutlineInputBorder(),
              ),
              items: products.map<DropdownMenuItem<int>>((p) {
                return DropdownMenuItem<int>(
                  value: p['id'] as int,
                  child: Text(p['name']),
                );
              }).toList(),
              onChanged: (v) => setState(() {
                productId = v;
                shadeId = null;
                _stockBalance = null;
              }),
            ),

            const SizedBox(height: 12),

            // ---------------- FABRIC SHADE (filtered by product) ----------------
            DropdownButtonFormField<int>(
              key: ValueKey('shade_$productId'),
              value: shadeId,
              decoration: InputDecoration(
                labelText:
                    productId == null ? 'Select product first' : 'Fabric Shade',
                border: const OutlineInputBorder(),
              ),
              items: _filteredShades().map<DropdownMenuItem<int>>((s) {
                return DropdownMenuItem<int>(
                  value: s['id'] as int,
                  child: Text(s['shade_no']),
                );
              }).toList(),
              onChanged: productId == null
                  ? null
                  : (v) {
                      setState(() => shadeId = v);
                      _refreshBalance();
                    },
            ),

            // Show current stock balance for selected product+shade
            if (productId != null && shadeId != null && _stockBalance != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Current Stock: ${_stockBalance!.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _stockBalance! <= 0
                          ? Colors.red
                          : Colors.green.shade700,
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 12),

            // ---------------- TYPE ----------------
            DropdownButtonFormField<String>(
              value: type,
              decoration: const InputDecoration(
                labelText: 'Adjustment Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'IN', child: Text('ADJUST IN')),
                DropdownMenuItem(value: 'OUT', child: Text('ADJUST OUT')),
              ],
              onChanged: (v) => setState(() => type = v!),
            ),

            const SizedBox(height: 12),

            // ---------------- QTY ----------------
            TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Quantity',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 12),

            // ---------------- REASON ----------------
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _addOrUpdateRow,
                    child: Text(
                      editingIndex == null ? 'ADD SHADE ROW' : 'UPDATE ROW',
                    ),
                  ),
                ),
                if (editingIndex != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _cancelEdit,
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 10),

            if (items.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('No shade rows added'),
              )
            else
              ...items.asMap().entries.map((entry) {
                final i = entry.key;
                final item = entry.value;
                final qty = (item['qty'] as num).toDouble();
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text('Shade: ${item['shade_no']}'),
                    subtitle: Text(
                      '${item['type'] ?? 'IN'}  |  Qty: ${qty.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: (item['type'] ?? 'IN') == 'OUT'
                            ? Colors.red
                            : Colors.green.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _startEditRow(i),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() {
                              if (editingIndex == i) {
                                _cancelEdit();
                              } else if (editingIndex != null &&
                                  editingIndex! > i) {
                                editingIndex = editingIndex! - 1;
                              }
                              items.removeAt(i);
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                );
              }),

            const SizedBox(height: 10),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _saveAll,
                child: const Text(
                  'SAVE ADJUSTMENT',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

            const SizedBox(height: 24),
            const Divider(thickness: 2),

            // ---- PAST ADJUSTMENTS SECTION ----
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Past Adjustments',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () {
                    if (!showPast) _loadPastAdjustments();
                    setState(() => showPast = !showPast);
                  },
                  icon: Icon(showPast ? Icons.expand_less : Icons.expand_more),
                  label: Text(showPast ? 'Hide' : 'Show'),
                ),
              ],
            ),

            if (showPast) ...[
              if (pastAdjustments.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No past adjustments found'),
                )
              else
                ...pastAdjustments.map((entry) {
                  final isOut = (entry['type'] ?? 'IN') == 'OUT';
                  return Card(
                    key: ValueKey('past_${entry['id']}'),
                    margin: const EdgeInsets.only(bottom: 6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isOut
                                      ? Colors.red.shade50
                                      : Colors.green.shade50,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  isOut ? 'OUT' : 'IN',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isOut
                                        ? Colors.red
                                        : Colors.green.shade700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${entry['product_name'] ?? '-'}  ·  Shade ${entry['shade_no'] ?? '-'}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              Text(
                                _fmtDate(entry['date'] as int?),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          if (_editingPastId == entry['id'])
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _pastQtyCtrl,
                                    keyboardType: TextInputType.number,
                                    autofocus: true,
                                    decoration: const InputDecoration(
                                      labelText: 'New Qty',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 8),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ElevatedButton(
                                  onPressed: () => _saveEditPast(entry),
                                  style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12)),
                                  child: const Text('Save',
                                      style: TextStyle(fontSize: 12)),
                                ),
                                const SizedBox(width: 4),
                                OutlinedButton(
                                  onPressed: _cancelEditPast,
                                  style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10)),
                                  child: const Text('X',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ],
                            )
                          else
                            Row(
                              children: [
                                Text(
                                  'Qty: ${((entry['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                if ((entry['remarks'] ?? '')
                                    .toString()
                                    .isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      '  ·  ${entry['remarks']}',
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.grey),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _toggleType(entry),
                                icon: const Icon(Icons.swap_horiz, size: 16),
                                label: Text('Flip to ${isOut ? "IN" : "OUT"}',
                                    style: const TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _startEditPast(entry),
                                icon: const Icon(Icons.edit, size: 16),
                                label: const Text('Qty',
                                    style: TextStyle(fontSize: 12)),
                                style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _deletePastEntry(entry),
                                icon: const Icon(Icons.delete,
                                    size: 16, color: Colors.red),
                                label: const Text('Delete',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.red)),
                                style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    dateCtrl.dispose();
    qtyCtrl.dispose();
    reasonCtrl.dispose();
    _pastQtyCtrl.dispose();
    super.dispose();
  }
}
