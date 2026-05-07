import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import 'package:sssj/data/firebase_sync_service.dart';

class IssueInventoryHistoryPage extends StatefulWidget {
  const IssueInventoryHistoryPage({super.key});

  @override
  State<IssueInventoryHistoryPage> createState() =>
      _IssueInventoryHistoryPageState();
}

class _IssueInventoryHistoryPageState extends State<IssueInventoryHistoryPage> {
  static const String _editPasscode = '1234';

  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>> reqRows = [];
  List<Map<String, dynamic>> parties = [];
  List<Map<String, dynamic>> products = [];
  List<Map<String, dynamic>> shades = [];
  bool loading = true;
  bool editUnlocked = false;

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

    List<Map<String, dynamic>> nextReqRows = [];
    try {
      nextReqRows = await db.rawQuery('''
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
          COALESCE(fs.shade_no, 'NO SHADE') AS shade_no
        FROM challan_requirements cr
        LEFT JOIN products p ON p.id = cr.product_id
        LEFT JOIN fabric_shades fs ON fs.id = cr.fabric_shade_id
        ORDER BY cr.date DESC, cr.id DESC
      ''');
    } catch (e) {
      debugPrint('Error loading requirements: $e');
    }

    if (!mounted) return;
    setState(() {
      rows = nextRows;
      reqRows = nextReqRows;
      parties = nextParties;
      products = nextProducts;
      shades = nextShades;
      loading = false;
    });
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

  int? _partyIdByName(String partyName) {
    final found = parties.cast<Map<String, dynamic>?>().firstWhere(
          (p) =>
              (p?['name'] ?? '').toString().trim().toLowerCase() ==
              partyName.trim().toLowerCase(),
          orElse: () => null,
        );
    return found?['id'] as int?;
  }

  String _partyNameById(int? partyId) {
    if (partyId == null) return '';
    final found = parties.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['id'] == partyId,
          orElse: () => null,
        );
    return (found?['name'] ?? '').toString();
  }

  String _shadeLabel(int? shadeId) {
    if (shadeId == null) return '';
    final found = shades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == shadeId,
          orElse: () => null,
        );
    if (found == null) return '';

    final shadeNo = (found['shade_no'] ?? '').toString();
    final shadeName = (found['shade_name'] ?? '').toString();
    if (shadeName.isEmpty) return shadeNo;
    return '$shadeNo - $shadeName';
  }

  String _fmtDate(int? ms) {
    if (ms == null) return '-';
    return DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  String _qtyText(double qty) {
    if (qty == qty.roundToDouble()) return qty.toStringAsFixed(0);
    return qty.toStringAsFixed(2);
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
      const SnackBar(content: Text('Issue editing unlocked')),
    );
    return true;
  }

  Future<void> _editIssuedEntry(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    final parsed = _parseRemarks(row['remarks']?.toString());

    int? productId = row['product_id'] as int?;
    int? shadeId = row['fabric_shade_id'] as int?;
    int? partyId = _partyIdByName(_remarkValue(parsed, ['Party']));

    final qtyCtrl = TextEditingController(
      text: ((row['qty'] as num?)?.toDouble() ?? 0).toString(),
    );

    final currentCh = _remarkValue(parsed, ['ChNo', 'Ch No', 'Ch']);
    final chNoCtrl = TextEditingController(
      text: currentCh == '-' ? '' : currentCh,
    );

    var saving = false;

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Issued Entry'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      value: partyId,
                      decoration: const InputDecoration(labelText: 'Party'),
                      items: parties
                          .map(
                            (p) => DropdownMenuItem<int>(
                              value: p['id'] as int,
                              child: Text((p['name'] ?? '').toString()),
                            ),
                          )
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => setDialogState(() => partyId = v),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: productId,
                      decoration: const InputDecoration(labelText: 'Product'),
                      items: products
                          .map(
                            (p) => DropdownMenuItem<int>(
                              value: p['id'] as int,
                              child: Text((p['name'] ?? '').toString()),
                            ),
                          )
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => setDialogState(() => productId = v),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: shadeId,
                      decoration: const InputDecoration(labelText: 'Shade'),
                      items: shades
                          .map(
                            (s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text(_shadeLabel(s['id'] as int)),
                            ),
                          )
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => setDialogState(() => shadeId = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: chNoCtrl,
                      enabled: !saving,
                      decoration: const InputDecoration(labelText: 'Ch No'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: qtyCtrl,
                      enabled: !saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty'),
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
                          if (partyId == null ||
                              productId == null ||
                              shadeId == null ||
                              qty <= 0) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Fill valid Party, Product, Shade, Qty',
                                ),
                              ),
                            );
                            return;
                          }

                          setDialogState(() => saving = true);

                          // Check if new qty/shade causes negative balance
                          final oldQty = (row['qty'] as num?)?.toDouble() ?? 0;
                          final oldShadeId = row['fabric_shade_id'] as int?;
                          final oldProductId = row['product_id'] as int?;

                          // If shade or product changed, check both old (removing OUT) and new (adding OUT)
                          if (productId != oldProductId ||
                              shadeId != oldShadeId ||
                              qty > oldQty) {
                            final current = await ErpDatabase.instance
                                .getCurrentStockBalance(
                              productId: productId!,
                              fabricShadeId: shadeId!,
                            );
                            // If same shade: projected = current - (qty - oldQty)
                            // If different shade: projected = current - qty (full new OUT)
                            final diff = (productId == oldProductId &&
                                    shadeId == oldShadeId)
                                ? qty - oldQty
                                : qty;
                            final projected = current - diff;
                            if (projected < 0) {
                              if (!mounted) {
                                setDialogState(() => saving = false);
                                return;
                              }
                              final proceed = await showDialog<bool>(
                                context: context,
                                builder: (dlgCtx) => AlertDialog(
                                  title: const Text('Negative Balance Warning'),
                                  content: Text(
                                    'This change will make balance ${projected.toStringAsFixed(2)}.\nProceed?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dlgCtx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.pop(dlgCtx, true),
                                      child: const Text('Proceed'),
                                    ),
                                  ],
                                ),
                              );
                              if (proceed != true) {
                                setDialogState(() => saving = false);
                                return;
                              }
                            }
                          }

                          await ErpDatabase.instance.updateLedgerFull(
                            id: row['id'] as int,
                            productId: productId!,
                            fabricShadeId: shadeId!,
                            type: 'OUT',
                            qty: qty,
                            remarks:
                                'Party: ${_partyNameById(partyId)} | ChNo: ${chNoCtrl.text.trim()}',
                          );

                          if (!mounted) return;

                          Navigator.pop(ctx);
                          await _load();
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Issued entry updated')),
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

  Future<void> _deleteIssuedEntry(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;

    if (!mounted) return;

    final firstOk = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete Confirmation 1/2'),
          content: const Text(
            'This will permanently delete this issued row. Continue to final confirmation?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (firstOk != true) return;
    if (!mounted) return;

    final secondOk = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete Confirmation 2/2'),
          content: const Text('Final step: delete this entry now?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, Delete'),
            ),
          ],
        );
      },
    );

    if (secondOk != true) return;

    await ErpDatabase.instance.deleteLedgerEntry(row['id'] as int);

    if (!mounted) return;

    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Issued entry deleted')),
    );
  }

  List<Map<String, dynamic>> _groupByDate() {
    final grouped = <int, Map<String, List<Map<String, dynamic>>>>{};

    for (final row in rows) {
      final ms = row['date'] as int?;
      if (ms == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      final dayMs = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
      grouped.putIfAbsent(dayMs, () => {'stock': [], 'req': []});
      grouped[dayMs]!['stock']!.add(row);
    }

    for (final row in reqRows) {
      final ms = row['date'] as int?;
      if (ms == null) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      final dayMs = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
      grouped.putIfAbsent(dayMs, () => {'stock': [], 'req': []});
      grouped[dayMs]!['req']!.add(row);
    }

    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return keys.map((k) {
      final stockRows = grouped[k]!['stock']!;
      final reqRowsDay = grouped[k]!['req']!;
      final totalStockQty = stockRows.fold<double>(
        0,
        (sum, r) => sum + ((r['qty'] as num?)?.toDouble() ?? 0),
      );
      final totalReqQty = reqRowsDay.fold<double>(
        0,
        (sum, r) => sum + ((r['qty'] as num?)?.toDouble() ?? 0),
      );
      return {
        'dayMs': k,
        'rows': stockRows,
        'reqRows': reqRowsDay,
        'count': stockRows.length + reqRowsDay.length,
        'totalQty': totalStockQty + totalReqQty,
      };
    }).toList();
  }

  Future<void> _openDatePreview(
    int dayMs,
    List<Map<String, dynamic>> dateRows,
    List<Map<String, dynamic>> dateReqRows,
  ) async {
    final grouped = <String, Map<String, dynamic>>{};

    for (final row in dateRows) {
      final remarks = _parseRemarks(row['remarks']?.toString());
      final party = _remarkValue(remarks, ['Party']);
      final chNo = _remarkValue(remarks, ['ChNo', 'Ch No', 'Ch']);
      final product = (row['product_name'] ?? '-').toString();
      final shadeNo = (row['shade_no'] ?? '-').toString();
      final qty = ((row['qty'] as num?)?.toDouble() ?? 0);

      final key = '$party|$chNo|$product';
      final bucket = grouped.putIfAbsent(
        key,
        () => {
          'party': party,
          'chNo': chNo,
          'product': product,
          'shadeQty': <String, double>{},
          'reqShadeQty': <String, double>{},
          'rows': <Map<String, dynamic>>[],
          'reqRows': <Map<String, dynamic>>[],
        },
      );

      final shadeQty = bucket['shadeQty'] as Map<String, double>;
      shadeQty[shadeNo] = (shadeQty[shadeNo] ?? 0) + qty;
      (bucket['rows'] as List<Map<String, dynamic>>).add(row);
    }

    for (final row in dateReqRows) {
      final party = (row['party_name'] ?? '-').toString();
      final chNo = (row['challan_no'] ?? '-').toString();
      final product = (row['product_name'] ?? '-').toString();
      final shadeNo = (row['shade_no'] ?? '-').toString();
      final qty = ((row['qty'] as num?)?.toDouble() ?? 0);

      final key = '$party|$chNo|$product';
      final bucket = grouped.putIfAbsent(
        key,
        () => {
          'party': party,
          'chNo': chNo,
          'product': product,
          'shadeQty': <String, double>{},
          'reqShadeQty': <String, double>{},
          'rows': <Map<String, dynamic>>[],
          'reqRows': <Map<String, dynamic>>[],
        },
      );

      final reqShadeQty = bucket['reqShadeQty'] as Map<String, double>;
      reqShadeQty[shadeNo] = (reqShadeQty[shadeNo] ?? 0) + qty;
      (bucket['reqRows'] as List<Map<String, dynamic>>).add(row);
    }

    final groupedList = grouped.values.toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Date: ${_fmtDate(dayMs)}'),
          content: SizedBox(
            width: 760,
            height: 460,
            child: groupedList.isEmpty
                ? const Center(child: Text('No entries'))
                : ListView.builder(
                    itemCount: groupedList.length,
                    itemBuilder: (_, i) {
                      final g = groupedList[i];
                      final shadeQty = g['shadeQty'] as Map<String, double>;
                      final shadeRows = shadeQty.entries.toList()
                        ..sort((a, b) => a.key.compareTo(b.key));
                      final reqShadeQty =
                          g['reqShadeQty'] as Map<String, double>;
                      final reqShadeRows = reqShadeQty.entries.toList()
                        ..sort((a, b) => a.key.compareTo(b.key));
                      final groupStockRows =
                          (g['rows'] as List<Map<String, dynamic>>).toList();
                      final groupReqRows =
                          (g['reqRows'] as List<Map<String, dynamic>>).toList();

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Party: ${g['party']}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _editFullIssueBill(
                                        groupStockRows,
                                        g['party'] as String,
                                        g['chNo'] as String,
                                        g['product'] as String,
                                        dayMs,
                                      );
                                    },
                                    child: const Text('Edit Full Bill'),
                                  ),
                                  const SizedBox(width: 4),
                                  TextButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _openGroupEntries(
                                        groupStockRows,
                                        groupReqRows,
                                      );
                                    },
                                    child: const Text('Edit/Delete'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text('Ch No: ${g['chNo']}'),
                              Text('Product: ${g['product']}'),
                              if (shadeRows.isNotEmpty) ...[
                                const Divider(height: 14),
                                const Text(
                                  'Issue Shades:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ...shadeRows.map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(
                                        '${e.key} - ${_qtyText(e.value)} mtr'),
                                  ),
                                ),
                              ],
                              if (reqShadeRows.isNotEmpty) ...[
                                const Divider(height: 14),
                                const Text(
                                  'Requirement Shades:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: Colors.deepOrange,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ...reqShadeRows.map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(
                                      '${e.key} - ${_qtyText(e.value)} mtr',
                                      style: const TextStyle(
                                        color: Colors.deepOrange,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
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

  Future<void> _openGroupEntries(
    List<Map<String, dynamic>> groupRows,
    List<Map<String, dynamic>> groupReqRows,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Manage Issue Entries'),
          content: SizedBox(
            width: 760,
            height: 440,
            child: (groupRows.isEmpty && groupReqRows.isEmpty)
                ? const Center(child: Text('No entries'))
                : ListView(
                    children: [
                      if (groupRows.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6, top: 4),
                          child: Text(
                            'Issue Items',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        ...groupRows.map((row) {
                          final m = _parseRemarks(row['remarks']?.toString());
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              title: Text(
                                'Shade: ${row['shade_no'] ?? '-'}   Qty: ${_qtyText(((row['qty'] as num?)?.toDouble() ?? 0))} mtr',
                              ),
                              subtitle: Text(
                                'Party: ${_remarkValue(m, [
                                      'Party'
                                    ])} | Ch No: ${_remarkValue(m, [
                                      'ChNo',
                                      'Ch No',
                                      'Ch'
                                    ])}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _editIssuedEntry(row);
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _deleteIssuedEntry(row);
                                    },
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                      if (groupReqRows.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6, top: 10),
                          child: Text(
                            'Requirement Items',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.deepOrange,
                            ),
                          ),
                        ),
                        ...groupReqRows.map((row) {
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            color: Colors.orange.shade50,
                            child: ListTile(
                              title: Text(
                                'Shade: ${row['shade_no'] ?? '-'}   Qty: ${_qtyText(((row['qty'] as num?)?.toDouble() ?? 0))} mtr',
                              ),
                              subtitle: Text(
                                'Party: ${row['party_name'] ?? '-'} | Ch No: ${row['challan_no'] ?? '-'} | ${row['status'] ?? 'pending'}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _editRequirementEntry(row);
                                    },
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      color: Colors.deepOrange,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () async {
                                      Navigator.pop(ctx);
                                      await _deleteRequirementEntry(row);
                                    },
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.deepOrange,
                                    ),
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

  Future<void> _editFullIssueBill(
    List<Map<String, dynamic>> groupRows,
    String partyName,
    String chNo,
    String productName,
    int dayMs,
  ) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    // Determine current party, product, chNo from group
    final firstRow = groupRows.isNotEmpty ? groupRows.first : null;
    int? productId = firstRow?['product_id'] as int?;
    int? partyId = _partyIdByName(partyName);
    final currentChNo = (chNo == '-') ? '' : chNo;

    // Build edit items
    final editItems = groupRows.map((row) {
      return {
        'ledger_id': row['id'] as int?,
        'shade_id': row['fabric_shade_id'] as int?,
        'qty': (row['qty'] as num?)?.toDouble() ?? 0,
        'old_shade_id': row['fabric_shade_id'] as int?,
        'old_qty': (row['qty'] as num?)?.toDouble() ?? 0,
        'is_new': false,
      };
    }).toList();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullIssueEditPage(
          editItems: editItems,
          partyId: partyId,
          productId: productId,
          chNo: currentChNo,
          issueDate: DateTime.fromMillisecondsSinceEpoch(dayMs),
          parties: parties,
          products: products,
          shades: shades,
        ),
      ),
    );

    if (!mounted) return;
    await _load();
  }

  Future<void> _editRequirementEntry(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    int? shadeId = row['fabric_shade_id'] as int?;
    final qtyCtrl = TextEditingController(
      text: ((row['qty'] as num?)?.toDouble() ?? 0).toString(),
    );
    var saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Requirement Entry'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Party: ${row['party_name'] ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text('Ch No: ${row['challan_no'] ?? '-'}'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: shadeId,
                      decoration: const InputDecoration(labelText: 'Shade'),
                      items: shades
                          .map(
                            (s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text(_shadeLabel(s['id'] as int)),
                            ),
                          )
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => setDialogState(() => shadeId = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: qtyCtrl,
                      enabled: !saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty'),
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
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Select a valid shade and qty'),
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

                          if (!mounted) return;
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Requirement entry updated'),
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

  Future<void> _deleteRequirementEntry(Map<String, dynamic> row) async {
    if (!await _ensureUnlocked()) return;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete Requirement?'),
          content: Text(
            'Delete requirement: Shade ${row['shade_no'] ?? '-'}, '
            'Qty ${_qtyText(((row['qty'] as num?)?.toDouble() ?? 0))} mtr?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    await ErpDatabase.instance.deleteChallanRequirement(row['id'] as int);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Requirement entry deleted')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByDate();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Issue History'),
        actions: [
          IconButton(
            tooltip: editUnlocked ? 'Lock Editing' : 'Unlock Editing',
            onPressed: () async {
              if (editUnlocked) {
                setState(() => editUnlocked = false);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Issue editing locked')),
                );
                return;
              }
              await _ensureUnlocked();
            },
            icon: Icon(editUnlocked ? Icons.lock_open : Icons.lock),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () async {
              setState(() => loading = true);
              await _load();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : grouped.isEmpty
              ? const Center(child: Text('No issue entries found'))
              : ListView.builder(
                  itemCount: grouped.length,
                  itemBuilder: (_, i) {
                    final g = grouped[i];
                    final dayMs = g['dayMs'] as int;
                    final count = g['count'] as int;
                    final totalQty = g['totalQty'] as double;
                    final dateRows =
                        (g['rows'] as List).cast<Map<String, dynamic>>();
                    final dateReqRows =
                        (g['reqRows'] as List).cast<Map<String, dynamic>>();

                    return InkWell(
                      onTap: () =>
                          _openDatePreview(dayMs, dateRows, dateReqRows),
                      borderRadius: BorderRadius.circular(12),
                      child: Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Date: ${_fmtDate(dayMs)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Text('Rows: $count'),
                              const SizedBox(width: 14),
                              Text('Qty: ${totalQty.toStringAsFixed(2)}'),
                              const SizedBox(width: 6),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ==================== FULL ISSUE EDIT PAGE ====================
class _FullIssueEditPage extends StatefulWidget {
  final List<Map<String, dynamic>> editItems;
  final int? partyId;
  final int? productId;
  final String chNo;
  final DateTime issueDate;
  final List<Map<String, dynamic>> parties;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> shades;

  const _FullIssueEditPage({
    required this.editItems,
    required this.partyId,
    required this.productId,
    required this.chNo,
    required this.issueDate,
    required this.parties,
    required this.products,
    required this.shades,
  });

  @override
  State<_FullIssueEditPage> createState() => _FullIssueEditPageState();
}

class _FullIssueEditPageState extends State<_FullIssueEditPage> {
  late int? partyId;
  late int? productId;
  late DateTime issueDate;
  late TextEditingController chNoCtrl;
  late List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> deleted = [];
  bool saving = false;

  // Add-row fields
  int? addShadeId;
  final addQtyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    partyId = widget.partyId;
    productId = widget.productId;
    issueDate = widget.issueDate;
    chNoCtrl = TextEditingController(text: widget.chNo);
    items = widget.editItems.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  @override
  void dispose() {
    chNoCtrl.dispose();
    addQtyCtrl.dispose();
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
    final no = (s?['shade_no'] ?? '-').toString();
    final name = (s?['shade_name'] ?? '').toString();
    if (name.isEmpty) return no;
    return '$no - $name';
  }

  String _partyNameById(int? pid) {
    if (pid == null) return '';
    final p = widget.parties.where((p) => p['id'] == pid).firstOrNull;
    return (p?['name'] ?? '').toString();
  }

  void _addRow() {
    final qty = double.tryParse(addQtyCtrl.text.trim());
    if (addShadeId == null || qty == null || qty <= 0) {
      _msg('Select shade and enter valid qty');
      return;
    }
    setState(() {
      items.add({
        'ledger_id': null,
        'shade_id': addShadeId,
        'qty': qty,
        'is_new': true,
      });
      addShadeId = null;
      addQtyCtrl.clear();
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
      initialDate: issueDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => issueDate = d);
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
        issueDate.year,
        issueDate.month,
        issueDate.day,
      ).millisecondsSinceEpoch;
      final chNo = chNoCtrl.text.trim();
      final partyName = _partyNameById(partyId);
      final remarks = 'Party: $partyName | ChNo: $chNo';

      // Mark deleted rows as pending delete BEFORE the transaction
      // so real-time listeners won't re-insert them
      final sync = FirebaseSyncService.instance;
      if (ErpDatabase.instance.syncEnabled && sync.isInitialized) {
        for (final d in deleted) {
          final ledgerId = d['ledger_id'] as int?;
          if (ledgerId != null)
            await sync.addPendingDelete('stock_ledger', ledgerId);
        }
      }

      await sync.beginLocalDbWrite();
      try {
        await db.transaction((txn) async {
          // 1. Delete removed rows
          for (final d in deleted) {
            final ledgerId = d['ledger_id'] as int?;
            if (ledgerId == null) continue;
            await txn
                .delete('stock_ledger', where: 'id=?', whereArgs: [ledgerId]);
          }

          // 2. Update existing rows
          for (final item in items) {
            if (item['is_new'] == true) continue;
            final ledgerId = item['ledger_id'] as int?;
            if (ledgerId == null) continue;

            final newQty = (item['qty'] as num?)?.toDouble() ?? 0;
            final newShade = item['shade_id'] as int?;

            await txn.update(
              'stock_ledger',
              {
                'product_id': productId,
                'fabric_shade_id': newShade,
                'qty': newQty,
                'date': newDateMs,
                'remarks': remarks,
              },
              where: 'id=?',
              whereArgs: [ledgerId],
            );
          }

          // 3. Insert new rows
          for (final item in items) {
            if (item['is_new'] != true) continue;
            final newQty = (item['qty'] as num?)?.toDouble() ?? 0;
            final newShade = item['shade_id'] as int?;

            final newId = await txn.insert('stock_ledger', {
              'product_id': productId,
              'fabric_shade_id': newShade,
              'qty': newQty,
              'type': 'OUT',
              'date': newDateMs,
              'reference': '',
              'remarks': remarks,
            });
            item['ledger_id'] = newId;
          }
        });
      } finally {
        await sync.endLocalDbWrite();
      }

      ErpDatabase.instance.dataVersion.value++;

      // Push changes to Firebase after transaction succeeds
      if (ErpDatabase.instance.syncEnabled && sync.isInitialized) {
        for (final d in deleted) {
          final ledgerId = d['ledger_id'] as int?;
          if (ledgerId != null)
            await sync.deleteRecord('stock_ledger', ledgerId);
        }
        for (final item in items) {
          final ledgerId = item['ledger_id'] as int?;
          if (ledgerId == null) continue;
          final newQty = (item['qty'] as num?)?.toDouble() ?? 0;
          final newShade = item['shade_id'] as int?;
          final data = {
            'id': ledgerId,
            'product_id': productId,
            'fabric_shade_id': newShade,
            'qty': newQty,
            'type': 'OUT',
            'date': newDateMs,
            'reference': '',
            'remarks': remarks,
          };
          await sync.pushRecord('stock_ledger', ledgerId, data);
        }
      }

      if (!mounted) return;
      _msg('Issue bill updated successfully');
      Navigator.pop(context);
    } catch (e) {
      debugPrint('Error saving issue edit: $e');
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
        title: const Text('Edit Issue Bill'),
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
                      controller: chNoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Challan No',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Issue Date',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(DateFormat('dd-MM-yyyy').format(issueDate)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // --- Existing Shade Rows ---
            Text(
              'Shade Rows (${items.length})  |  Total: ${totalQty.toStringAsFixed(2)} mtr',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 6),
            ...items.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              final shade = _shadeName(item['shade_id'] as int?);
              final qty = (item['qty'] as num?)?.toDouble() ?? 0;
              final isNew = item['is_new'] == true;

              return Card(
                color: isNew ? const Color(0xFFE8F5E9) : null,
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  title: Text(
                    '$shade  |  Qty: ${qty.toStringAsFixed(2)} mtr',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  subtitle: isNew
                      ? const Text('NEW',
                          style: TextStyle(color: Colors.green, fontSize: 11))
                      : null,
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
                  flex: 4,
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
                              child: Text(
                                _shadeName(s['id'] as int),
                              ),
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
                              child: Text(
                                _shadeName(s['id'] as int),
                              ),
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
    if (newQty == null || newQty <= 0) {
      _msg('Enter valid qty');
      return;
    }

    setState(() {
      items[index]['shade_id'] = dlgShadeId;
      items[index]['qty'] = newQty;
    });
  }
}
