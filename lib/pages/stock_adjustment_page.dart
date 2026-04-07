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

  final dateCtrl = TextEditingController();

  final qtyCtrl = TextEditingController();
  final reasonCtrl = TextEditingController();
  final List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
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

        await ErpDatabase.instance.insertLedger({
          'product_id': productId,
          'fabric_shade_id': rowShadeId,
          'qty': rowQty,
          'type': rowType, // IN or OUT per row
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
        type = 'IN';
        editingIndex = null;
        dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
        qtyCtrl.clear();
        reasonCtrl.clear();
        items.clear();
      });

      _msg('$savedCount shade(s) adjusted successfully');
      if (warningLines.isNotEmpty) {
        _msg(
          'Warning: Negative balance\n${warningLines.join(', ')}',
        );
      }
    } catch (e) {
      debugPrint('Stock adjustment error: $e');
      _msg('Error saving adjustment: $e');
    }
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
                shadeId = null; // reset shade when product changes
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
              onChanged:
                  productId == null ? null : (v) => setState(() => shadeId = v),
            ),

            // Show current stock balance for selected product+shade
            if (productId != null && shadeId != null)
              FutureBuilder<double>(
                future: ErpDatabase.instance.getCurrentStockBalance(
                  productId: productId!,
                  fabricShadeId: shadeId!,
                ),
                builder: (ctx, snap) {
                  final bal = snap.data ?? 0;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Current Stock: ${bal.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: bal <= 0 ? Colors.red : Colors.green.shade700,
                        ),
                      ),
                    ),
                  );
                },
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
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    dateCtrl.dispose();
    qtyCtrl.dispose();
    reasonCtrl.dispose();
    super.dispose();
  }
}
