import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

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
        AND (sl.fabric_shade_id IS NULL OR sl.fabric_shade_id = 0 OR fs.id IS NOT NULL)
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
    } catch (_) {}

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
