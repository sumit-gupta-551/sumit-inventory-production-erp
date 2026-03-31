import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

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
        4: FlexColumnWidth(1.2),
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
                'Actions',
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () async {
                        await _editRow(r);
                      },
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.red),
                      onPressed: () async {
                        await _deleteRow(r);
                      },
                    ),
                  ],
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

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    final shadeName = (row['shade_no'] ?? '-').toString();
    final productName = (row['product_name'] ?? '-').toString();
    final qty = ((row['qty'] as num?)?.toDouble() ?? 0).toStringAsFixed(2);

    final firstOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Confirmation 1/2'),
        content: Text(
          'Delete this purchase row?\n\nShade: $shadeName\nProduct: $productName\nQty: $qty\n\nThis will also remove the stock ledger entry.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (firstOk != true || !mounted) return;

    final secondOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Confirmation 2/2'),
        content: const Text('Final step: delete this entry permanently?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Delete'),
          ),
        ],
      ),
    );
    if (secondOk != true) return;

    await ErpDatabase.instance.deletePurchaseRow(
      purchaseItemId: row['purchase_item_id'] as int,
      purchaseNo: row['purchase_no'] as int,
      productId: row['product_id'] as int?,
      shadeId: row['shade_id'] as int?,
      purchaseDate: row['purchase_date'] as int?,
      invoiceNo: (row['invoice_no'] ?? '').toString(),
      qty: (row['qty'] as num?)?.toDouble() ?? 0,
    );

    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Purchase row deleted')),
    );
  }

  Future<void> _deleteFullInvoice(int purchaseNo) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    final firstOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Full Invoice 1/2'),
        content: const Text(
          'This will delete the ENTIRE purchase invoice and all its items and stock entries. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (firstOk != true || !mounted) return;

    final secondOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Full Invoice 2/2'),
        content:
            const Text('Final step: permanently delete this entire invoice?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Delete'),
          ),
        ],
      ),
    );
    if (secondOk != true) return;

    await ErpDatabase.instance.deletePurchase(purchaseNo);

    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Full invoice deleted')),
    );
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
                                if (editUnlocked)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.red,
                                        ),
                                        icon: const Icon(Icons.delete_forever,
                                            size: 20),
                                        label:
                                            const Text('Delete Full Invoice'),
                                        onPressed: () async {
                                          final pNo = groupRows
                                              .first['purchase_no'] as int;
                                          await _deleteFullInvoice(pNo);
                                        },
                                      ),
                                    ),
                                  ),
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
