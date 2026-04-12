import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../data/firebase_sync_service.dart';

class FirmInventoryHistoryPage extends StatefulWidget {
  final int firmId;
  final String firmName;

  const FirmInventoryHistoryPage({
    super.key,
    required this.firmId,
    required this.firmName,
  });

  @override
  State<FirmInventoryHistoryPage> createState() =>
      _FirmInventoryHistoryPageState();
}

class _FirmInventoryHistoryPageState extends State<FirmInventoryHistoryPage> {
  static const String _editPasscode = '1234';

  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>> parties = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];
  bool loading = true;
  bool editUnlocked = false;

  Map<String, List<Map<String, dynamic>>> _groupByPartyInvoice() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final party = (r['party_name'] ?? '-').toString();
      final invoice = (r['invoice_no'] ?? '-').toString();
      final key = '$party||$invoice';
      map.putIfAbsent(key, () => []);
      map[key]!.add(r);
    }
    return map;
  }

  Widget _shadeGrid(List<Map<String, dynamic>> groupRows) {
    return Table(
      border: TableBorder.all(color: Colors.black12),
      columnWidths: const {
        0: FlexColumnWidth(1.3),
        1: FlexColumnWidth(1.9),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(0.8),
      },
      children: [
        const TableRow(
          decoration: BoxDecoration(color: Color(0xFFF3F4F6)),
          children: [
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Shade',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Product',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Qty',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Rate',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Edit',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
            ),
          ],
        ),
        ...groupRows.map((r) {
          return TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  (r['shade_no'] ?? '-').toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  (r['product_name'] ?? '-').toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  (((r['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  (((r['rate'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Center(
                child: IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () async {
                    await _editRow(r);
                  },
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

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

    final masterParties = await db.query('parties', orderBy: 'name');
    final masterProducts = await db.query('products', orderBy: 'name');
    final masterShades = await db.query('fabric_shades', orderBy: 'shade_no');

    final data = await db.rawQuery('''
      SELECT 
        pm.purchase_no,
        pm.party_id,
        pi.id AS purchase_item_id,
        pi.rate,
        pi.amount,
        pi.product_id,
        pi.shade_id,
        pm.purchase_date,
        pm.invoice_no,
        COALESCE(p.name, '-') AS party_name,
        COALESCE(pr.name, 'Unknown Product') AS product_name,
        COALESCE(fs.shade_no, 'Unknown Shade') AS shade_no,
        pi.qty
      FROM purchase_master pm
      JOIN purchase_items pi ON pi.purchase_no = pm.purchase_no
      LEFT JOIN products pr ON pr.id = pi.product_id
      LEFT JOIN fabric_shades fs ON fs.id = pi.shade_id
      LEFT JOIN parties p ON p.id = pm.party_id
      WHERE pm.firm_id = ?
      ORDER BY pm.purchase_date DESC
    ''', [widget.firmId]);

    if (!mounted) return;

    setState(() {
      parties = masterParties;
      products = masterProducts;
      shades = masterShades;
      rows = data;
      loading = false;
    });
  }

  String _fmtDate(dynamic value) {
    if (value == null) return '-';

    try {
      return DateFormat('dd-MM-yyyy')
          .format(DateTime.fromMillisecondsSinceEpoch(value as int));
    } catch (_) {
      return '-';
    }
  }

  Future<bool> _ensureUnlocked() async {
    if (editUnlocked) return true;

    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Enter Edit Passcode'),
          content: TextField(
            controller: passCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passcode',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unlock'),
            ),
          ],
        );
      },
    );

    if (ok != true) return false;

    if (passCtrl.text.trim() != _editPasscode) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid passcode')),
      );
      return false;
    }

    if (!mounted) return false;
    setState(() => editUnlocked = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Editing unlocked')),
    );
    return true;
  }

  Future<void> _editRow(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    final qtyCtrl = TextEditingController(
      text: ((row['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
    );
    final rateCtrl = TextEditingController(
      text: ((row['rate'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
    );
    final invoiceCtrl = TextEditingController(
      text: (row['invoice_no'] ?? '').toString(),
    );

    int? partyId = row['party_id'] as int?;
    int? productId = row['product_id'] as int?;
    int? shadeId = row['shade_id'] as int?;
    DateTime purchaseDate = DateTime.fromMillisecondsSinceEpoch(
      (row['purchase_date'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            return AlertDialog(
              title: const Text('Edit Purchase Entry'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      value: partyId,
                      decoration: const InputDecoration(
                        labelText: 'Party',
                        border: OutlineInputBorder(),
                      ),
                      items: parties
                          .map(
                            (p) => DropdownMenuItem<int>(
                              value: p['id'] as int,
                              child: Text((p['name'] ?? '').toString()),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setDialog(() => partyId = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: productId,
                      decoration: const InputDecoration(
                        labelText: 'Product',
                        border: OutlineInputBorder(),
                      ),
                      items: products
                          .map(
                            (p) => DropdownMenuItem<int>(
                              value: p['id'] as int,
                              child: Text((p['name'] ?? '').toString()),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setDialog(() => productId = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: shadeId,
                      decoration: const InputDecoration(
                        labelText: 'Shade',
                        border: OutlineInputBorder(),
                      ),
                      items: shades
                          .map(
                            (s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text((s['shade_no'] ?? '').toString()),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setDialog(() => shadeId = v),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: invoiceCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Invoice No',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          initialDate: purchaseDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (d != null) {
                          setDialog(() => purchaseDate = d);
                        }
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Purchase Date',
                          border: OutlineInputBorder(),
                        ),
                        child:
                            Text(DateFormat('dd-MM-yyyy').format(purchaseDate)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: qtyCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: rateCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Rate',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    final newQty = double.tryParse(qtyCtrl.text.trim());
    final newRate = double.tryParse(rateCtrl.text.trim());
    if (newQty == null || newQty <= 0 || newRate == null || newRate <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid quantity/rate')),
      );
      return;
    }

    final purchaseNo = row['purchase_no'] as int?;
    final purchaseItemId = row['purchase_item_id'] as int?;
    final oldProductId = row['product_id'] as int?;
    final oldShadeId = row['shade_id'] as int?;
    final oldPurchaseDate = row['purchase_date'] as int?;
    final oldInvoiceNo = (row['invoice_no'] ?? '').toString();
    final oldQty = ((row['qty'] as num?)?.toDouble() ?? 0);
    final newPurchaseDate = DateTime(
      purchaseDate.year,
      purchaseDate.month,
      purchaseDate.day,
    ).millisecondsSinceEpoch;

    if (purchaseNo == null ||
        purchaseItemId == null ||
        oldProductId == null ||
        oldShadeId == null ||
        oldPurchaseDate == null ||
        partyId == null ||
        productId == null ||
        shadeId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to update this row')),
      );
      return;
    }

    final db = await ErpDatabase.instance.database;

    await db.transaction((txn) async {
      await txn.update(
        'purchase_master',
        {
          'party_id': partyId,
          'invoice_no': invoiceCtrl.text.trim(),
          'purchase_date': newPurchaseDate,
        },
        where: 'purchase_no=?',
        whereArgs: [purchaseNo],
      );

      await txn.update(
        'purchase_items',
        {
          'product_id': productId,
          'shade_id': shadeId,
          'qty': newQty,
          'rate': newRate,
          'amount': newQty * newRate,
        },
        where: 'id=?',
        whereArgs: [purchaseItemId],
      );

      final direct = await txn.rawQuery(
        '''
        SELECT id FROM stock_ledger
        WHERE product_id=?
          AND fabric_shade_id=?
          AND type='IN'
          AND date=?
          AND reference=?
          AND remarks='Purchase'
          AND ABS(COALESCE(qty, 0) - ?) < 0.000001
        ORDER BY id DESC
        LIMIT 1
        ''',
        [oldProductId, oldShadeId, oldPurchaseDate, oldInvoiceNo, oldQty],
      );

      int? ledgerId;
      if (direct.isNotEmpty) {
        ledgerId = direct.first['id'] as int?;
      } else {
        final fallback = await txn.rawQuery(
          '''
          SELECT id FROM stock_ledger
          WHERE product_id=?
            AND fabric_shade_id=?
            AND type='IN'
            AND date=?
            AND reference=?
            AND remarks='Purchase'
          ORDER BY id DESC
          LIMIT 1
          ''',
          [oldProductId, oldShadeId, oldPurchaseDate, oldInvoiceNo],
        );
        if (fallback.isNotEmpty) {
          ledgerId = fallback.first['id'] as int?;
        }
      }

      if (ledgerId != null) {
        await txn.update(
          'stock_ledger',
          {
            'product_id': productId,
            'fabric_shade_id': shadeId,
            'qty': newQty,
            'date': newPurchaseDate,
            'reference': invoiceCtrl.text.trim(),
          },
          where: 'id=?',
          whereArgs: [ledgerId],
        );
      }
    });

    await _load();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Purchase history updated')),
    );
  }

  // ---------- FULL PURCHASE EDIT ----------
  Future<void> _editFullPurchase(List<Map<String, dynamic>> groupRows) async {
    if (!await _ensureUnlocked()) return;
    if (groupRows.isEmpty || !mounted) return;

    final first = groupRows.first;
    final purchaseNo = first['purchase_no'] as int?;
    if (purchaseNo == null) return;

    int? partyId = first['party_id'] as int?;
    String invoiceNo = (first['invoice_no'] ?? '').toString();
    DateTime purchaseDate = DateTime.fromMillisecondsSinceEpoch(
      (first['purchase_date'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );
    int? productId = first['product_id'] as int?;

    // Build editable shade list from existing rows
    final editItems = <Map<String, dynamic>>[];
    for (final r in groupRows) {
      editItems.add({
        'purchase_item_id': r['purchase_item_id'],
        'shade_id': r['shade_id'] as int?,
        'qty': (r['qty'] as num?)?.toDouble() ?? 0,
        'rate': (r['rate'] as num?)?.toDouble() ?? 0,
        'is_new': false,
        'old_product_id': r['product_id'],
        'old_shade_id': r['shade_id'],
        'old_qty': (r['qty'] as num?)?.toDouble() ?? 0,
        'old_date': r['purchase_date'],
        'old_invoice': (r['invoice_no'] ?? '').toString(),
      });
    }

    final deleted = <Map<String, dynamic>>[];

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullPurchaseEditPage(
          purchaseNo: purchaseNo,
          partyId: partyId,
          invoiceNo: invoiceNo,
          purchaseDate: purchaseDate,
          productId: productId,
          editItems: editItems,
          deleted: deleted,
          parties: parties,
          products: products,
          shades: shades,
          firmId: widget.firmId,
        ),
      ),
    );

    // Reload after returning
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByPartyInvoice();

    return Scaffold(
      appBar: AppBar(
        title: Text('Inventory – ${widget.firmName}'),
        actions: [
          IconButton(
            tooltip: editUnlocked ? 'Lock Edit' : 'Unlock Edit',
            icon: Icon(editUnlocked ? Icons.lock_open : Icons.lock_outline),
            onPressed: () async {
              if (editUnlocked) {
                setState(() => editUnlocked = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Editing locked')),
                );
              } else {
                await _ensureUnlocked();
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (editUnlocked) {
            setState(() => editUnlocked = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Editing locked')),
            );
          } else {
            await _ensureUnlocked();
          }
        },
        icon: Icon(editUnlocked ? Icons.lock_open : Icons.lock_outline),
        label: Text(editUnlocked ? 'Lock Edit' : 'Unlock Edit'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: () async {
                if (editUnlocked) {
                  setState(() => editUnlocked = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Editing locked')),
                  );
                } else {
                  await _ensureUnlocked();
                }
              },
              icon: Icon(editUnlocked ? Icons.lock_open : Icons.lock_outline),
              label: Text(editUnlocked ? 'Lock Edit' : 'Unlock Edit'),
            ),
          ),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : rows.isEmpty
              ? const Center(child: Text('No inventory found'))
              : Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: editUnlocked
                            ? Colors.green.shade50
                            : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: editUnlocked
                              ? Colors.green.shade200
                              : Colors.red.shade200,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            editUnlocked ? Icons.lock_open : Icons.lock_outline,
                            color: editUnlocked ? Colors.green : Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              editUnlocked
                                  ? 'Edit mode unlocked. You can edit all fields.'
                                  : 'Edit mode locked. Tap Unlock Edit to edit.',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              if (editUnlocked) {
                                setState(() => editUnlocked = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Editing locked')),
                                );
                              } else {
                                await _ensureUnlocked();
                              }
                            },
                            child: Text(editUnlocked ? 'Lock' : 'Unlock'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: grouped.entries.length,
                        itemBuilder: (_, i) {
                          final entry = grouped.entries.elementAt(i);
                          final key = entry.key;
                          final party = key.split('||').first;
                          final invoice = key.split('||').length > 1
                              ? key.split('||')[1]
                              : '-';
                          final groupRows = entry.value;
                          final invoiceDate = groupRows.isEmpty
                              ? '-'
                              : _fmtDate(groupRows.first['purchase_date']);

                          return Card(
                            margin: const EdgeInsets.symmetric(
                              vertical: 6,
                              horizontal: 8,
                            ),
                            child: ExpansionTile(
                              title: Text(
                                'Party: $party',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                'Invoice: $invoice  |  Date: $invoiceDate  |  Shades: ${groupRows.length}',
                              ),
                              childrenPadding:
                                  const EdgeInsets.fromLTRB(10, 0, 10, 12),
                              children: [
                                _shadeGrid(groupRows),
                                if (editUnlocked) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF1565C0),
                                        foregroundColor: Colors.white,
                                      ),
                                      onPressed: () =>
                                          _editFullPurchase(groupRows),
                                      icon:
                                          const Icon(Icons.edit_note, size: 20),
                                      label: const Text('Edit Full Purchase'),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ==================== FULL PURCHASE EDIT PAGE ====================
class _FullPurchaseEditPage extends StatefulWidget {
  final int purchaseNo;
  final int? partyId;
  final String invoiceNo;
  final DateTime purchaseDate;
  final int? productId;
  final List<Map<String, dynamic>> editItems;
  final List<Map<String, dynamic>> deleted;
  final List<Map<String, dynamic>> parties;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> shades;
  final int firmId;

  const _FullPurchaseEditPage({
    required this.purchaseNo,
    required this.partyId,
    required this.invoiceNo,
    required this.purchaseDate,
    required this.productId,
    required this.editItems,
    required this.deleted,
    required this.parties,
    required this.products,
    required this.shades,
    required this.firmId,
  });

  @override
  State<_FullPurchaseEditPage> createState() => _FullPurchaseEditPageState();
}

class _FullPurchaseEditPageState extends State<_FullPurchaseEditPage> {
  late int? partyId;
  late int? productId;
  late DateTime purchaseDate;
  late TextEditingController invoiceCtrl;
  late List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> deleted = [];
  bool saving = false;

  // Add-row fields
  int? addShadeId;
  final addQtyCtrl = TextEditingController();
  final addRateCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    partyId = widget.partyId;
    productId = widget.productId;
    purchaseDate = widget.purchaseDate;
    invoiceCtrl = TextEditingController(text: widget.invoiceNo);
    items = widget.editItems.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  void dispose() {
    invoiceCtrl.dispose();
    addQtyCtrl.dispose();
    addRateCtrl.dispose();
    super.dispose();
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  String _shadeName(int? id) {
    if (id == null) return '-';
    final s = widget.shades.where((s) => s['id'] == id).firstOrNull;
    return (s?['shade_no'] ?? '-').toString();
  }

  String _productName(int? id) {
    if (id == null) return '-';
    final p = widget.products.where((p) => p['id'] == id).firstOrNull;
    return (p?['name'] ?? '-').toString();
  }

  void _addRow() {
    final qty = double.tryParse(addQtyCtrl.text.trim());
    final rate = double.tryParse(addRateCtrl.text.trim()) ?? 0;
    if (addShadeId == null || qty == null || qty <= 0) {
      _msg('Select shade and enter valid qty');
      return;
    }
    setState(() {
      items.add({
        'purchase_item_id': null,
        'shade_id': addShadeId,
        'qty': qty,
        'rate': rate,
        'is_new': true,
      });
      addShadeId = null;
      addQtyCtrl.clear();
      addRateCtrl.clear();
    });
  }

  void _removeRow(int index) {
    final item = items[index];
    setState(() {
      if (item['is_new'] != true) {
        deleted.add(item);
      }
      items.removeAt(index);
    });
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: purchaseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => purchaseDate = d);
  }

  Future<void> _save() async {
    if (partyId == null || productId == null || items.isEmpty) {
      _msg('Party, product, and at least one shade required');
      return;
    }
    setState(() => saving = true);

    try {
      final db = await ErpDatabase.instance.database;
      final newDateMs = DateTime(
        purchaseDate.year,
        purchaseDate.month,
        purchaseDate.day,
      ).millisecondsSinceEpoch;
      final inv = invoiceCtrl.text.trim();

      // Track IDs for Firebase sync after transaction
      final deletedPurchaseItemIds = <int>[];
      final deletedLedgerIds = <int>[];
      final updatedPurchaseItems = <int, Map<String, dynamic>>{};
      final updatedLedgerItems = <int, Map<String, dynamic>>{};
      final insertedPurchaseItems = <int, Map<String, dynamic>>{};
      final insertedLedgerItems = <int, Map<String, dynamic>>{};

      // Mark rows pending delete BEFORE the transaction
      // so real-time listeners won't re-insert them
      final sync = FirebaseSyncService.instance;
      if (ErpDatabase.instance.syncEnabled && sync.isInitialized) {
        for (final d in deleted) {
          final itemId = d['purchase_item_id'] as int?;
          if (itemId != null) sync.addPendingDelete('purchase_items', itemId);
        }
      }

      await db.transaction((txn) async {
        // 1. Update purchase_master header
        final headerData = {
          'party_id': partyId,
          'invoice_no': inv,
          'purchase_date': newDateMs,
        };
        await txn.update(
          'purchase_master',
          headerData,
          where: 'purchase_no=?',
          whereArgs: [widget.purchaseNo],
        );
        updatedPurchaseItems[-1] = {
          ...headerData,
          'purchase_no': widget.purchaseNo
        };

        // 2. Delete removed rows
        for (final d in deleted) {
          final itemId = d['purchase_item_id'] as int?;
          if (itemId == null) continue;

          // Delete purchase_item
          await txn
              .delete('purchase_items', where: 'id=?', whereArgs: [itemId]);
          deletedPurchaseItemIds.add(itemId);

          // Find and delete matching ledger entry
          final oldPid = d['old_product_id'] as int?;
          final oldSid = d['old_shade_id'] as int?;
          final oldQty = (d['old_qty'] as num?)?.toDouble() ?? 0;
          final oldDate = d['old_date'] as int?;
          final oldInv = (d['old_invoice'] ?? '').toString();

          if (oldPid != null && oldSid != null && oldDate != null) {
            final ledger = await txn.rawQuery('''
              SELECT id FROM stock_ledger
              WHERE product_id=? AND fabric_shade_id=? AND type='IN'
                AND date=? AND reference=? AND remarks='Purchase'
                AND ABS(COALESCE(qty,0) - ?) < 0.001
              ORDER BY id DESC LIMIT 1
            ''', [oldPid, oldSid, oldDate, oldInv, oldQty]);
            if (ledger.isNotEmpty) {
              final ledgerId = ledger.first['id'] as int;
              if (ErpDatabase.instance.syncEnabled && sync.isInitialized) {
                sync.addPendingDelete('stock_ledger', ledgerId);
              }
              await txn
                  .delete('stock_ledger', where: 'id=?', whereArgs: [ledgerId]);
              deletedLedgerIds.add(ledgerId);
            }
          }
        }

        // 3. Update existing rows
        for (final item in items) {
          if (item['is_new'] == true) continue;
          final itemId = item['purchase_item_id'] as int?;
          if (itemId == null) continue;

          final newQty = (item['qty'] as num?)?.toDouble() ?? 0;
          final newRate = (item['rate'] as num?)?.toDouble() ?? 0;
          final newShade = item['shade_id'] as int?;

          final piData = {
            'product_id': productId,
            'shade_id': newShade,
            'qty': newQty,
            'rate': newRate,
            'amount': newQty * newRate,
          };
          await txn.update('purchase_items', piData,
              where: 'id=?', whereArgs: [itemId]);
          updatedPurchaseItems[itemId] = {
            ...piData,
            'id': itemId,
            'purchase_no': widget.purchaseNo
          };

          // Update matching ledger
          final oldPid = item['old_product_id'] as int?;
          final oldSid = item['old_shade_id'] as int?;
          final oldQty = (item['old_qty'] as num?)?.toDouble() ?? 0;
          final oldDate = item['old_date'] as int?;
          final oldInv = (item['old_invoice'] ?? '').toString();

          if (oldPid != null && oldSid != null && oldDate != null) {
            final ledger = await txn.rawQuery('''
              SELECT id FROM stock_ledger
              WHERE product_id=? AND fabric_shade_id=? AND type='IN'
                AND date=? AND reference=? AND remarks='Purchase'
                AND ABS(COALESCE(qty,0) - ?) < 0.001
              ORDER BY id DESC LIMIT 1
            ''', [oldPid, oldSid, oldDate, oldInv, oldQty]);
            if (ledger.isNotEmpty) {
              final ledgerId = ledger.first['id'] as int;
              final slData = {
                'product_id': productId,
                'fabric_shade_id': newShade,
                'qty': newQty,
                'date': newDateMs,
                'reference': inv,
              };
              await txn.update('stock_ledger', slData,
                  where: 'id=?', whereArgs: [ledgerId]);
              updatedLedgerItems[ledgerId] = {
                ...slData,
                'id': ledgerId,
                'type': 'IN',
                'remarks': 'Purchase'
              };
            }
          }
        }

        // 4. Insert new rows
        for (final item in items) {
          if (item['is_new'] != true) continue;
          final newQty = (item['qty'] as num?)?.toDouble() ?? 0;
          final newRate = (item['rate'] as num?)?.toDouble() ?? 0;
          final newShade = item['shade_id'] as int?;

          final piData = {
            'purchase_no': widget.purchaseNo,
            'product_id': productId,
            'shade_id': newShade,
            'qty': newQty,
            'rate': newRate,
            'amount': newQty * newRate,
          };
          final piId = await txn.insert('purchase_items', piData);
          insertedPurchaseItems[piId] = {...piData, 'id': piId};

          final slData = {
            'product_id': productId,
            'fabric_shade_id': newShade,
            'qty': newQty,
            'type': 'IN',
            'date': newDateMs,
            'reference': inv,
            'remarks': 'Purchase',
          };
          final slId = await txn.insert('stock_ledger', slData);
          insertedLedgerItems[slId] = {...slData, 'id': slId};
        }
      });

      ErpDatabase.instance.dataVersion.value++;

      // Push changes to Firebase after transaction succeeds
      if (ErpDatabase.instance.syncEnabled && sync.isInitialized) {
        for (final id in deletedPurchaseItemIds) {
          await sync.deleteRecord('purchase_items', id);
        }
        for (final id in deletedLedgerIds) {
          await sync.deleteRecord('stock_ledger', id);
        }
        // Push purchase_master update
        if (updatedPurchaseItems.containsKey(-1)) {
          await sync.pushRecord(
              'purchase_master', widget.purchaseNo, updatedPurchaseItems[-1]!);
        }
        for (final e in updatedPurchaseItems.entries) {
          if (e.key == -1) continue;
          await sync.pushRecord('purchase_items', e.key, e.value);
        }
        for (final e in updatedLedgerItems.entries) {
          await sync.pushRecord('stock_ledger', e.key, e.value);
        }
        for (final e in insertedPurchaseItems.entries) {
          await sync.pushRecord('purchase_items', e.key, e.value);
        }
        for (final e in insertedLedgerItems.entries) {
          await sync.pushRecord('stock_ledger', e.key, e.value);
        }
      }

      if (!mounted) return;
      _msg('Purchase updated successfully');
      Navigator.pop(context);
    } catch (e) {
      debugPrint('Error saving purchase edit: $e');
      _msg('Error: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalQty = items.fold<double>(
        0, (s, e) => s + ((e['qty'] as num?)?.toDouble() ?? 0));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Purchase'),
        actions: [
          TextButton.icon(
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save, color: Colors.white),
            label: const Text('SAVE', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Header Fields ---
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    DropdownButtonFormField<int>(
                      value: partyId,
                      decoration: const InputDecoration(
                        labelText: 'Party',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      isExpanded: true,
                      items: widget.parties
                          .map((p) => DropdownMenuItem<int>(
                                value: p['id'] as int,
                                child: Text((p['name'] ?? '').toString()),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => partyId = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: productId,
                      decoration: const InputDecoration(
                        labelText: 'Product',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      isExpanded: true,
                      items: widget.products
                          .map((p) => DropdownMenuItem<int>(
                                value: p['id'] as int,
                                child: Text((p['name'] ?? '').toString()),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => productId = v),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: invoiceCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Invoice No',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Purchase Date',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child:
                            Text(DateFormat('dd-MM-yyyy').format(purchaseDate)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // --- Existing Shade Rows ---
            Text(
              'Shade Rows (${items.length})  |  Total: ${totalQty.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 6),
            ...items.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              final shade = _shadeName(item['shade_id'] as int?);
              final qty = (item['qty'] as num?)?.toDouble() ?? 0;
              final rate = (item['rate'] as num?)?.toDouble() ?? 0;
              final isNew = item['is_new'] == true;

              return Card(
                color: isNew ? const Color(0xFFE8F5E9) : null,
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: Text(
                    '$shade  |  Qty: ${qty.toStringAsFixed(2)}  |  Rate: ${rate.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: isNew
                      ? const Text('NEW',
                          style: TextStyle(color: Colors.green, fontSize: 11))
                      : Text('Product: ${_productName(productId)}',
                          style: const TextStyle(fontSize: 11)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 20,
                        icon:
                            const Icon(Icons.edit_outlined, color: Colors.blue),
                        onPressed: () => _editItemDialog(i),
                      ),
                      IconButton(
                        iconSize: 20,
                        icon:
                            const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _removeRow(i),
                      ),
                    ],
                  ),
                ),
              );
            }),

            const SizedBox(height: 12),
            const Divider(),

            // --- Add New Row ---
            const Text('Add Shade Row',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<int>(
                    value: addShadeId,
                    decoration: const InputDecoration(
                      labelText: 'Shade',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    isExpanded: true,
                    items: widget.shades
                        .map((s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text((s['shade_no'] ?? '').toString()),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => addShadeId = v),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: addQtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Qty',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: addRateCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Rate',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: _addRow,
                    child: const Text('ADD'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editItemDialog(int index) async {
    final item = items[index];
    int? dlgShadeId = item['shade_id'] as int?;
    final dlgQtyCtrl = TextEditingController(
      text: ((item['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
    );
    final dlgRateCtrl = TextEditingController(
      text: ((item['rate'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlg) {
            return AlertDialog(
              title: const Text('Edit Shade Row'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<int>(
                    value: dlgShadeId,
                    decoration: const InputDecoration(
                      labelText: 'Shade',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: widget.shades
                        .map((s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text((s['shade_no'] ?? '').toString()),
                            ))
                        .toList(),
                    onChanged: (v) => setDlg(() => dlgShadeId = v),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: dlgQtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: dlgRateCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Rate',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    final newQty = double.tryParse(dlgQtyCtrl.text.trim());
    final newRate = double.tryParse(dlgRateCtrl.text.trim()) ?? 0;
    if (newQty == null || newQty <= 0) {
      _msg('Enter valid qty');
      return;
    }

    setState(() {
      items[index]['shade_id'] = dlgShadeId;
      items[index]['qty'] = newQty;
      items[index]['rate'] = newRate;
    });
  }
}
