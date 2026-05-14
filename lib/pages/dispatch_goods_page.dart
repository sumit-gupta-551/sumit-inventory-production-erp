// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../widgets/inventory_form_card.dart';
import '../widgets/passcode_gate.dart';
import 'program_card_page.dart' show ProgramCardConstants;

/// =================================================================
///  DISPATCH GOODS - bills + multiple design rows per bill.
///  Only program-cards in "Ready to Dispatch" status are selectable.
/// =================================================================
class DispatchGoodsPage extends StatefulWidget {
  const DispatchGoodsPage({super.key});

  @override
  State<DispatchGoodsPage> createState() => _DispatchGoodsPageState();
}

class _DispatchGoodsPageState extends State<DispatchGoodsPage> {
  final _db = ErpDatabase.instance;
  final _df = DateFormat('dd-MM-yyyy');
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _bills = [];
  Map<int, Party> _partyById = {};
  Map<int, Product> _productById = {};
  Map<int, int> _cardCountByBill = {};
  Map<int, int> _rowCountByBill = {};
  final Set<int> _expandedBillIds = <int>{};
  final Set<int> _loadingPreviewBillIds = <int>{};
  final Map<int, List<Map<String, dynamic>>> _billPreviewByBillId = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _db.dataVersion.addListener(_onDataChanged);
    _load();
  }

  @override
  void dispose() {
    _db.dataVersion.removeListener(_onDataChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  int get _totalCards =>
      _cardCountByBill.values.fold<int>(0, (sum, value) => sum + value);

  int get _totalRows =>
      _rowCountByBill.values.fold<int>(0, (sum, value) => sum + value);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await _db.restoreRecentlyDeletedDispatchBillsNow();
      await _db.reopenOrphanClosedDispatchCardsNow();
      final parties = await _db.getParties();
      final products = await _db.getProducts();
      final bills = await _db.getDispatchBills(
        search:
            _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
      );
      final dbi = await _db.database;
      final grouped = await dbi.rawQuery('''
        SELECT
          bill_id,
          COUNT(*) AS row_count,
          COUNT(DISTINCT COALESCE(
            CAST(program_card_id AS TEXT),
            COALESCE(company, '') || '|' || COALESCE(design_no, '') || '|' || COALESCE(card_no, '')
          )) AS card_count
        FROM dispatch_items
        GROUP BY bill_id
      ''');
      final rowCounts = <int, int>{
        for (final row in grouped)
          if ((row['bill_id'] as num?) != null)
            (row['bill_id'] as num).toInt():
                ((row['row_count'] as num?) ?? 0).toInt(),
      };
      final cardCounts = <int, int>{
        for (final row in grouped)
          if ((row['bill_id'] as num?) != null)
            (row['bill_id'] as num).toInt():
                ((row['card_count'] as num?) ?? 0).toInt(),
      };
      if (!mounted) return;
      setState(() {
        final validIds = <int>{};
        for (final bill in bills) {
          final bid = bill['id'] as int?;
          if (bid != null) validIds.add(bid);
        }
        _partyById = {
          for (final p in parties)
            if (p.id != null) p.id!: p
        };
        _productById = {
          for (final p in products)
            if (p.id != null) p.id!: p
        };
        _bills = bills;
        _rowCountByBill = rowCounts;
        _cardCountByBill = cardCounts;
        _expandedBillIds.removeWhere((id) => !validIds.contains(id));
        _loadingPreviewBillIds.removeWhere((id) => !validIds.contains(id));
        _billPreviewByBillId.removeWhere((id, _) => !validIds.contains(id));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to load bills: $e')));
    }
  }

  Future<void> _unlockTodayDispatchCards() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final restored = await _db.restoreRecentlyDeletedDispatchBillsNow();
      final reopenedToday =
          await _db.reopenOrphanClosedDispatchCardsForDayNow(DateTime.now());
      var reopenedExtra = 0;
      if (reopenedToday == 0) {
        reopenedExtra = await _db.reopenOrphanClosedDispatchCardsNow();
      }
      await _load();
      if (!mounted) return;
      final reopenedTotal = reopenedToday + reopenedExtra;
      final msg = (reopenedTotal > 0 || restored > 0)
          ? 'Unlock done: reopened $reopenedTotal card(s), restored $restored bill(s).'
          : 'No locked orphan cards found for today.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Unlock failed: $e')));
    }
  }

  Future<void> _openEditor({Map<String, dynamic>? bill}) async {
    // Editing an existing bill requires passcode.
    if (bill != null) {
      final ok = await requirePasscode(context, action: 'Edit');
      if (!ok) return;
    }
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _DispatchEditorPage(bill: bill),
      ),
    );
    if (ok == true) _load();
  }

  Future<void> _toggleBillExpansion(Map<String, dynamic> bill) async {
    final billId = bill['id'] as int?;
    if (billId == null) return;
    final isExpanded = _expandedBillIds.contains(billId);
    setState(() {
      if (isExpanded) {
        _expandedBillIds.remove(billId);
      } else {
        _expandedBillIds.add(billId);
      }
    });
    if (!isExpanded) {
      await _ensureBillPreviewLoaded(billId);
    }
  }

  Future<void> _ensureBillPreviewLoaded(int billId) async {
    if (_billPreviewByBillId.containsKey(billId) ||
        _loadingPreviewBillIds.contains(billId)) {
      return;
    }

    setState(() => _loadingPreviewBillIds.add(billId));
    try {
      final items = await _db.getDispatchItems(billId);
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final it in items) {
        final pcId = it['program_card_id'] as int?;
        final key = pcId != null
            ? 'pc_$pcId'
            : 'd_${it['company'] ?? ''}|${it['design_no'] ?? ''}|${it['card_no'] ?? ''}|${it['product_id'] ?? ''}';
        grouped.putIfAbsent(key, () => []).add(it);
      }

      final preview = grouped.values.map((rows) {
        final first = rows.first;
        final productId = first['product_id'] as int?;
        final productName =
            productId == null ? '' : (_productById[productId]?.name ?? '');
        final qtyTotal = rows.fold<double>(
          0,
          (s, r) => s + ((r['qty'] as num?)?.toDouble() ?? 0),
        );
        final pcsTotal = rows.fold<double>(
          0,
          (s, r) => s + ((r['pcs'] as num?)?.toDouble() ?? 0),
        );
        final total = rows.fold<double>(0, (s, r) {
          final q = (r['qty'] as num?)?.toDouble() ?? 0;
          final p = (r['pcs'] as num?)?.toDouble() ?? 0;
          return s + (q * p);
        });
        return <String, dynamic>{
          'company': (first['company'] ?? '').toString(),
          'design_no': (first['design_no'] ?? '').toString(),
          'card_no': (first['card_no'] ?? '').toString(),
          'product_name': productName,
          'row_count': rows.length,
          'qty_total': qtyTotal,
          'pcs_total': pcsTotal,
          'total': total,
        };
      }).toList()
        ..sort((a, b) {
          final aa = '${a['company']}|${a['design_no']}|${a['card_no']}';
          final bb = '${b['company']}|${b['design_no']}|${b['card_no']}';
          return aa.compareTo(bb);
        });

      if (!mounted) return;
      setState(() => _billPreviewByBillId[billId] = preview);
    } finally {
      if (mounted) {
        setState(() => _loadingPreviewBillIds.remove(billId));
      }
    }
  }

  Widget _buildInlineBillPreview(Map<String, dynamic> bill) {
    final billId = bill['id'] as int?;
    if (billId == null) return const SizedBox.shrink();
    if (_loadingPreviewBillIds.contains(billId)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final groups = _billPreviewByBillId[billId] ?? const [];
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'No dispatch rows in this bill.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
      );
    }

    return Column(
      children: groups.map((g) {
        final total = (g['total'] as num?)?.toDouble() ?? 0;
        final qty = (g['qty_total'] as num?)?.toDouble() ?? 0;
        final pcs = (g['pcs_total'] as num?)?.toDouble() ?? 0;
        final rows = (g['row_count'] as num?)?.toInt() ?? 0;
        final productName = (g['product_name'] ?? '').toString();
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blueGrey.shade100),
          ),
          child: ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            title: Text(
              '${g['company'] ?? ''} - ${g['design_no'] ?? ''} - #${g['card_no'] ?? ''}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${productName.isEmpty ? 'Product: -' : 'Product: $productName'}\nRows: $rows  |  Qty: ${_fmtNum(qty).isEmpty ? '0' : _fmtNum(qty)}  |  Pcs: ${_fmtNum(pcs).isEmpty ? '0' : _fmtNum(pcs)}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Text(
              _fmtNum(total).isEmpty ? '0' : _fmtNum(total),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F766E),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _delete(Map<String, dynamic> bill) async {
    final pass = await requirePasscode(context, action: 'Delete');
    if (!pass) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Bill?'),
        content:
            Text('Delete bill ${bill['bill_no'] ?? ''} and all its items?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) {
      await _db.deleteDispatchBill(bill['id'] as int);
      _load();
    }
  }

  Future<void> _openBillDetails(Map<String, dynamic> bill) async {
    final billId = bill['id'] as int;
    final items = await _db.getDispatchItems(billId);
    final products = await _db.getProducts();
    if (!mounted) return;

    final productById = <int, Product>{
      for (final p in products)
        if (p.id != null) p.id!: p,
    };

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      final pcId = it['program_card_id'] as int?;
      final key = pcId != null
          ? 'pc_$pcId'
          : 'd_${it['company'] ?? ''}|${it['design_no'] ?? ''}|${it['card_no'] ?? ''}|${it['product_id'] ?? ''}';
      grouped.putIfAbsent(key, () => []).add(it);
    }

    final groups = grouped.values.map((rows) {
      final first = rows.first;
      final productId = first['product_id'] as int?;
      final productName =
          productId == null ? '' : (productById[productId]?.name ?? '');
      final total = rows.fold<double>(0, (s, r) {
        final q = (r['qty'] as num?)?.toDouble() ?? 0;
        final p = (r['pcs'] as num?)?.toDouble() ?? 0;
        return s + (q * p);
      });
      return <String, dynamic>{
        'company': (first['company'] ?? '').toString(),
        'design_no': (first['design_no'] ?? '').toString(),
        'card_no': (first['card_no'] ?? '').toString(),
        'product_name': productName,
        'rows': rows,
        'total': total,
      };
    }).toList();

    final cardCount = groups.length;
    final rowCount = items.length;
    final grandTotal = groups.fold<double>(
      0,
      (s, g) => s + ((g['total'] as num?)?.toDouble() ?? 0),
    );
    final dt = bill['bill_date'] as int?;
    final partyId = bill['party_id'] as int?;
    final partyName =
        partyId == null ? '-' : (_partyById[partyId]?.name ?? '-');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.96,
        expand: false,
        builder: (_, scrollCtrl) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Row(
                  children: [
                    const Icon(Icons.receipt_long_rounded,
                        color: Color(0xFF0284C7)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Bill #${bill['bill_no'] ?? ''} Details',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0F2FE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Date: ${dt == null ? '-' : _df.format(DateTime.fromMillisecondsSinceEpoch(dt))}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Party: $partyName',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if ((bill['remarks'] ?? '')
                              .toString()
                              .trim()
                              .isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Remarks: ${(bill['remarks'] ?? '').toString()}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            'Cards: $cardCount  |  Rows: $rowCount  |  Total: ${_fmtNum(grandTotal).isEmpty ? '0' : _fmtNum(grandTotal)}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0C4A6E),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (groups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Center(
                            child: Text('No dispatch rows in this bill.')),
                      )
                    else
                      ...groups.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final g = entry.value;
                        final rows =
                            (g['rows'] as List).cast<Map<String, dynamic>>();
                        final productName =
                            (g['product_name'] ?? '').toString();
                        final groupTotal =
                            ((g['total'] as num?) ?? 0).toDouble();
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: Colors.blueGrey.shade100),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${idx + 1}. ${g['company'] ?? ''} - ${g['design_no'] ?? ''} - #${g['card_no'] ?? ''}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${productName.isEmpty ? 'Product: -' : 'Product: $productName'}  |  Rows: ${rows.length}  |  Total: ${_fmtNum(groupTotal).isEmpty ? '0' : _fmtNum(groupTotal)}',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF475569)),
                                ),
                                const SizedBox(height: 6),
                                ...rows.map((r) {
                                  final qty =
                                      (r['qty'] as num?)?.toDouble() ?? 0;
                                  final pcs =
                                      (r['pcs'] as num?)?.toDouble() ?? 0;
                                  final rowTotal = qty * pcs;
                                  return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${_fmtNum(qty).isEmpty ? '0' : _fmtNum(qty)} x ${_fmtNum(pcs).isEmpty ? '0' : _fmtNum(pcs)}',
                                            style:
                                                const TextStyle(fontSize: 12),
                                          ),
                                        ),
                                        Text(
                                          _fmtNum(rowTotal).isEmpty
                                              ? '0'
                                              : _fmtNum(rowTotal),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF0F766E),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch Goods'),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A1A2E), Color(0xFF0C4A6E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Unlock Today Cards',
            onPressed: _unlockTodayDispatchCards,
            icon: const Icon(Icons.lock_open_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: const Color(0xFF0EA5E9),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Bill'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF8FAFC), Color(0xFFE0F2FE), Color(0xFFF8FAFC)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Column(
                children: [
                  TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search by Bill No.',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                _load();
                              }),
                    ),
                    onSubmitted: (_) => _load(),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _statPill(Icons.receipt_long_rounded, 'Bills',
                          '${_bills.length}'),
                      const SizedBox(width: 8),
                      _statPill(Icons.style_rounded, 'Cards', '$_totalCards'),
                      const SizedBox(width: 8),
                      _statPill(Icons.view_list_rounded, 'Rows', '$_totalRows'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _bills.isEmpty
                      ? const Center(
                          child: Text('No dispatch bills yet.\nTap "New Bill".',
                              textAlign: TextAlign.center))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                            itemCount: _bills.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final b = _bills[i];
                              final id = b['id'] as int;
                              final pid = b['party_id'] as int?;
                              final party =
                                  pid != null ? _partyById[pid] : null;
                              final dt = b['bill_date'] as int?;
                              final cardCount = _cardCountByBill[id] ?? 0;
                              final rowCount = _rowCountByBill[id] ?? 0;
                              final isExpanded =
                                  _expandedBillIds.contains(id);
                              return Card(
                                elevation: 1,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                child: Column(
                                  children: [
                                    ListTile(
                                      onTap: () => _toggleBillExpansion(b),
                                      leading: CircleAvatar(
                                        backgroundColor:
                                            const Color(0xFF0EA5E9),
                                        foregroundColor: Colors.white,
                                        child: Text('$cardCount'),
                                      ),
                                      title: Text(
                                          'Bill #${b['bill_no'] ?? ''}  -  ${party?.name ?? '-'}'),
                                      subtitle: Text(
                                          '${dt != null ? _df.format(DateTime.fromMillisecondsSinceEpoch(dt)) : ''}  -  $cardCount card(s)  -  $rowCount row(s)'),
                                      trailing: PopupMenuButton<String>(
                                        onSelected: (v) {
                                          if (v == 'view') _openBillDetails(b);
                                          if (v == 'edit') _openEditor(bill: b);
                                          if (v == 'delete') _delete(b);
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                              value: 'view',
                                              child: Text('View Details')),
                                          PopupMenuItem(
                                              value: 'edit',
                                              child: Text('Edit')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete',
                                                  style: TextStyle(
                                                      color: Colors.red))),
                                        ],
                                      ),
                                    ),
                                    if (isExpanded)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            12, 0, 12, 10),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  'Dispatch Entries',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.grey.shade700,
                                                  ),
                                                ),
                                                const Spacer(),
                                                TextButton(
                                                  onPressed: () =>
                                                      _openBillDetails(b),
                                                  child:
                                                      const Text('Full View'),
                                                ),
                                              ],
                                            ),
                                            _buildInlineBillPreview(b),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statPill(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0EA5E9).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: const Color(0xFF0EA5E9)),
            const SizedBox(width: 6),
            Text('$label: ',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0369A1))),
            ),
          ],
        ),
      ),
    );
  }
}

/// =================================================================
///  EDITOR - one bill, many cards, many Qty x Pcs sub-rows per card.
/// =================================================================
class _DispatchEditorPage extends StatefulWidget {
  final Map<String, dynamic>? bill;
  const _DispatchEditorPage({this.bill});

  @override
  State<_DispatchEditorPage> createState() => _DispatchEditorPageState();
}

String _fmtNum(double v) {
  if (v == 0) return '';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString();
}

/// One Qty x Pcs entry under a card. Each one is persisted as a separate
/// dispatch_items row in the DB.
class _QtyRow {
  int? id; // existing dispatch_items.id (null = new)
  final TextEditingController qtyCtrl;
  final TextEditingController pcsCtrl;
  final FocusNode qtyFocus = FocusNode();
  final FocusNode pcsFocus = FocusNode();

  _QtyRow({this.id, double qty = 0, double pcs = 0})
      : qtyCtrl = TextEditingController(text: _fmtNum(qty)),
        pcsCtrl = TextEditingController(text: _fmtNum(pcs));

  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  double get pcs => double.tryParse(pcsCtrl.text.trim()) ?? 0;
  double get total => qty * pcs;

  void dispose() {
    qtyCtrl.dispose();
    pcsCtrl.dispose();
    qtyFocus.dispose();
    pcsFocus.dispose();
  }
}

/// A single card on the bill, with one or more [_QtyRow]s.
class _CardGroup {
  int? programCardId;
  String? company;
  int? productId;
  String designNo;
  String cardNo;
  final List<_QtyRow> qtyRows;

  /// True once user pressed "Save Card". Becomes uneditable until
  /// passcode is entered to unlock.
  bool locked;

  /// Whether this card should be marked Dispatched when final bill save runs.
  bool closeOnSave;

  _CardGroup({
    this.programCardId,
    this.company,
    this.productId,
    this.designNo = '',
    this.cardNo = '',
    List<_QtyRow>? qtyRows,
    this.locked = false,
  })  : qtyRows = qtyRows ?? [_QtyRow()],
        closeOnSave = false;

  double get total => qtyRows.fold(0.0, (s, r) => s + r.total);

  void disposeAll() {
    for (final r in qtyRows) {
      r.dispose();
    }
  }
}

class _DispatchEditorPageState extends State<_DispatchEditorPage> {
  final _db = ErpDatabase.instance;
  final _df = DateFormat('dd-MM-yyyy');

  final _billNoCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  DateTime _date = DateTime.now();
  Party? _party;
  List<Party> _parties = [];
  List<Product> _products = [];

  String _productNameOf(int? id) {
    if (id == null) return '';
    final f = _products.where((p) => p.id == id);
    return f.isEmpty ? '' : f.first.name;
  }

  /// All program cards currently ready and not closed (Dispatched/Completed).
  List<Map<String, dynamic>> _readyCards = [];

  final List<_CardGroup> _cards = [];
  final List<int> _removedItemIds = [];
  int? _activeCardIndex;
  bool _loading = true;
  bool _saving = false;

  bool get _isEdit => widget.bill != null;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _billNoCtrl.dispose();
    _remarksCtrl.dispose();
    for (final c in _cards) {
      c.disposeAll();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await _db.restoreRecentlyDeletedDispatchBillsNow();
      await _db.reopenOrphanClosedDispatchCardsNow();
      _parties = await _db.getParties();
      _products = await _db.getProducts();
      _readyCards = await _db.getDispatchSelectableProgramCards();

      if (_isEdit) {
        final b = widget.bill!;
        _billNoCtrl.text = (b['bill_no'] ?? '').toString();
        _remarksCtrl.text = (b['remarks'] ?? '').toString();
        final dt = b['bill_date'] as int?;
        if (dt != null) _date = DateTime.fromMillisecondsSinceEpoch(dt);
        final pid = b['party_id'] as int?;
        if (pid != null) {
          final found = _parties.where((p) => p.id == pid);
          if (found.isNotEmpty) _party = found.first;
        }
        // group existing dispatch_items by (program_card_id ?? card_no+design)
        final items = await _db.getDispatchItems(b['id'] as int);
        final groups = <String, _CardGroup>{};
        for (final it in items) {
          final pcId = it['program_card_id'] as int?;
          final key = pcId != null
              ? 'pc_$pcId'
              : 'd_${it['design_no']}_${it['card_no']}';
          final qtyRow = _QtyRow(
            id: it['id'] as int?,
            qty: ((it['qty'] as num?) ?? 0).toDouble(),
            pcs: ((it['pcs'] as num?) ?? 0).toDouble(),
          );
          final existing = groups[key];
          if (existing == null) {
            groups[key] = _CardGroup(
              programCardId: pcId,
              company: it['company'] as String?,
              productId: it['product_id'] as int?,
              designNo: (it['design_no'] ?? '').toString(),
              cardNo: (it['card_no'] ?? '').toString(),
              qtyRows: [qtyRow],
              locked: true,
            );
          } else {
            existing.qtyRows.add(qtyRow);
          }
        }
        _cards.addAll(groups.values);
      }
      if (_cards.isEmpty) _cards.add(_CardGroup());
      _activeCardIndex = _suggestedActiveIndex();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load bill editor: $e')),
      );
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickCardForGroup(_CardGroup group) async {
    if (_readyCards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No open cards are available in Ready to Dispatch.')));
      return;
    }
    final selectedPartyId = _party?.id;
    final picked = _cards
        .where((g) => g != group && g.programCardId != null)
        .map((g) => g.programCardId)
        .toSet();
    final available = _readyCards.where((c) {
      final id = c['id'] as int?;
      if (picked.contains(id)) return false;
      if (selectedPartyId != null && c['party_id'] != selectedPartyId) {
        return false;
      }
      return true;
    }).toList();
    if (available.isEmpty) {
      final message = selectedPartyId == null
          ? 'All ready cards are already selected in this bill.'
          : 'No Ready-to-Dispatch cards available for selected party.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CardPickerSheet(
        cards: available,
        partyById: {
          for (final p in _parties)
            if (p.id != null) p.id!: p
        },
        productById: {
          for (final p in _products)
            if (p.id != null) p.id!: p,
        },
      ),
    );
    if (chosen == null) return;

    setState(() {
      _activeCardIndex = _cards.indexOf(group);
      group.programCardId = chosen['id'] as int?;
      group.company = (chosen['company'] ?? '').toString();
      group.productId = chosen['product_id'] as int?;
      group.designNo = (chosen['design_no'] ?? '').toString();
      group.cardNo = (chosen['card_no'] ?? '').toString();
      group.closeOnSave = false;
      if (_party == null) {
        final pid = chosen['party_id'] as int?;
        if (pid != null) {
          final found = _parties.where((p) => p.id == pid);
          if (found.isNotEmpty) _party = found.first;
        }
      }
    });
  }

  Future<void> _addCard() async {
    final g = _CardGroup();
    setState(() {
      _cards.add(g);
      _activeCardIndex = _cards.length - 1;
    });
    await _pickCardForGroup(g);
    if (!mounted) return;
    if (!_isSelectedGroup(g) && _cards.length > 1) {
      setState(() {
        _cards.remove(g);
        g.disposeAll();
        _activeCardIndex = _suggestedActiveIndex();
      });
    }
  }

  /// Lock a card (called by per-card "Save Card" button).
  /// Shows a confirmation dialog with programmed vs dispatched qty,
  /// and offers to close (mark Dispatched) the program card.
  Future<void> _lockCard(_CardGroup g) async {
    if (g.programCardId == null &&
        g.designNo.trim().isEmpty &&
        g.cardNo.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pick a card first.')));
      return;
    }
    final hasQty = g.qtyRows.any((r) => r.qty > 0 || r.pcs > 0);
    if (!hasQty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least one Qty x Pcs.')));
      return;
    }

    // Compute programmed (TP x Line) and dispatched totals.
    double programmed = 0;
    double already = 0;
    final pcId = g.programCardId;
    if (pcId != null) {
      final card = await _db.getProgramCardById(pcId);
      if (card != null) {
        final tp = (card['tp'] as num?)?.toDouble() ?? 0;
        final lineStr = (card['line_no'] ?? '').toString();
        final m = RegExp(r'[-+]?\d*\.?\d+').firstMatch(lineStr);
        final line = m == null ? 0.0 : double.tryParse(m.group(0)!) ?? 0.0;
        programmed = tp * line;
      }
      already = await _db.getDispatchedQtyForCard(pcId,
          excludeBillId: widget.bill?['id'] as int?);
    }
    final thisBill = g.qtyRows.fold<double>(0, (s, r) => s + (r.qty * r.pcs));
    final newTotal = already + thisBill;
    final remaining = programmed - newTotal;

    String f(double v) =>
        v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('Programmed (TP x Line)', f(programmed)),
            _kv('Already Dispatched', f(already)),
            _kv('This Bill', f(thisBill)),
            const Divider(),
            _kv('Total After Save', f(newTotal),
                bold: true, color: newTotal > programmed ? Colors.red : null),
            _kv('Remaining', f(remaining),
                bold: true,
                color: remaining < 0
                    ? Colors.red
                    : (remaining == 0 ? Colors.green : null)),
            const SizedBox(height: 12),
            const Text('Do you want to CLOSE this card?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Text(
              'Closed cards move to Dispatched and will no longer appear in '
              'Ready-to-Dispatch.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'no'),
              child: const Text('No, Keep Open')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'yes'),
              child: const Text('Yes, Close Card')),
        ],
      ),
    );

    if (choice == null || choice == 'cancel') return;

    if (!mounted) return;
    setState(() {
      g.locked = true;
      g.closeOnSave = choice == 'yes' && pcId != null;
      if (_cards.isNotEmpty && identical(_cards.last, g)) {
        _cards.add(_CardGroup());
        _activeCardIndex = _cards.length - 1;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(g.closeOnSave
            ? 'Card locked. It will be closed when final bill is saved.'
            : 'Card locked (kept open).')));
  }

  Widget _kv(String k, String v, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 16),
          Text(v,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  color: color)),
        ],
      ),
    );
  }

  /// Unlock by configured passcode policy.
  Future<void> _unlockCard(_CardGroup g) async {
    final ok = await requirePasscode(context, action: 'Edit');
    if (ok != true || !mounted) return;
    setState(() {
      g.locked = false;
      g.closeOnSave = false;
    });
  }

  void _removeCard(int idx) {
    setState(() {
      final g = _cards.removeAt(idx);
      for (final r in g.qtyRows) {
        if (r.id != null) _removedItemIds.add(r.id!);
      }
      g.disposeAll();
      if (_cards.isEmpty) _cards.add(_CardGroup());
      _activeCardIndex = _suggestedActiveIndex();
    });
  }

  void _addQtyRow(_CardGroup g, {bool focusQty = false}) {
    final row = _QtyRow();
    setState(() => g.qtyRows.add(row));
    if (focusQty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) row.qtyFocus.requestFocus();
      });
    }
  }

  void _removeQtyRow(_CardGroup g, int rIdx) {
    setState(() {
      final row = g.qtyRows.removeAt(rIdx);
      if (row.id != null) _removedItemIds.add(row.id!);
      row.dispose();
      if (g.qtyRows.isEmpty) g.qtyRows.add(_QtyRow());
    });
  }

  bool _isSelectedGroup(_CardGroup g) =>
      g.programCardId != null ||
      g.designNo.trim().isNotEmpty ||
      g.cardNo.trim().isNotEmpty;

  int _suggestedActiveIndex() {
    if (_cards.isEmpty) return 0;
    final existing = _activeCardIndex;
    if (existing != null && existing >= 0 && existing < _cards.length) {
      return existing;
    }
    final firstUnlocked =
        _cards.indexWhere((g) => _isSelectedGroup(g) && !g.locked);
    if (firstUnlocked >= 0) return firstUnlocked;
    final firstSelected = _cards.indexWhere(_isSelectedGroup);
    if (firstSelected >= 0) return firstSelected;
    return 0;
  }

  int get _resolvedActiveIndex => _suggestedActiveIndex();

  int get _selectedCardCount => _cards.where(_isSelectedGroup).length;

  int get _effectiveRowCount => _cards.where(_isSelectedGroup).fold<int>(0,
      (sum, g) => sum + g.qtyRows.where((r) => r.qty > 0 && r.pcs > 0).length);

  double get _grandTotal =>
      _cards.where(_isSelectedGroup).fold(0.0, (s, g) => s + g.total);

  int get _lockedCount =>
      _cards.where((g) => _isSelectedGroup(g) && g.locked).length;

  Future<void> _save() async {
    if (_billNoCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Bill No. is required.')));
      return;
    }
    if (_party == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Party is required.')));
      return;
    }
    final validCards = _cards
        .where((g) =>
            g.programCardId != null ||
            g.designNo.trim().isNotEmpty ||
            g.cardNo.trim().isNotEmpty)
        .toList();
    if (validCards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least one card.')));
      return;
    }

    final upsertItems = <Map<String, dynamic>>[];
    final autoRemovedIds = <int>{};
    final closeCardIds = <int>{};
    var effectiveRows = 0;

    for (final g in validCards) {
      if (g.closeOnSave && g.programCardId != null) {
        closeCardIds.add(g.programCardId!);
      }
      for (final r in g.qtyRows) {
        final qty = r.qty;
        final pcs = r.pcs;
        if (qty <= 0 || pcs <= 0) {
          if (r.id != null) autoRemovedIds.add(r.id!);
          continue;
        }
        effectiveRows++;
        upsertItems.add({
          'id': r.id,
          'program_card_id': g.programCardId,
          'company': g.company,
          'product_id': g.productId,
          'design_no': g.designNo,
          'card_no': g.cardNo,
          'qty': qty,
          'pcs': pcs,
        });
      }
    }

    if (effectiveRows == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter at least one row with Qty and Pcs > 0.')));
      return;
    }

    setState(() => _saving = true);
    try {
      final billData = <String, dynamic>{
        'bill_date':
            DateTime(_date.year, _date.month, _date.day).millisecondsSinceEpoch,
        'bill_no': _billNoCtrl.text.trim(),
        'party_id': _party?.id,
        'remarks': _remarksCtrl.text.trim(),
      };

      final removedIds = <int>{..._removedItemIds, ...autoRemovedIds}.toList();
      await _db.saveDispatchBillAtomic(
        existingBillId: _isEdit ? widget.bill!['id'] as int : null,
        billData: billData,
        itemRows: upsertItems,
        removedItemIds: removedIds,
        closeProgramCardIds: closeCardIds,
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Bill' : 'New Bill'),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A1A2E), Color(0xFF0C4A6E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Save',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
          ),
        ],
      ),
      bottomNavigationBar: _loading
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0EA5E9).withValues(alpha: 0.10),
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    const Icon(Icons.summarize_rounded,
                        color: Color(0xFF0EA5E9)),
                    const SizedBox(width: 8),
                    const Text('Total',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Cards $_selectedCardCount  |  Rows $_effectiveRowCount',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        _fmtNum(_grandTotal).isEmpty
                            ? '0'
                            : _fmtNum(_grandTotal),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F766E))),
                  ],
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFF5F5F5),
                    Color(0xFFE3F2FD),
                    Color(0xFFF5F5F5)
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  InventoryFormCard(
                    title: 'BILL HEADER',
                    backgroundColor: const Color(0xFFE8F5E9),
                    borderColor: const Color(0xFF81C784),
                    padding: const EdgeInsets.all(10),
                    children: [
                      Row(children: [
                        Expanded(
                          child: InkWell(
                            onTap: _pickDate,
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Date',
                                isDense: true,
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.calendar_today),
                              ),
                              child: Text(_df.format(_date)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _billNoCtrl,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Bill No.',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<Party>(
                        initialValue: _party,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Party',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: _parties
                            .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(p.name,
                                      overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _party = v),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _remarksCtrl,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Remarks',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  InventoryFormCard(
                    title: 'DISPATCH CARDS',
                    backgroundColor: const Color(0xFFE3F2FD),
                    borderColor: const Color(0xFF90CAF9),
                    padding: const EdgeInsets.all(10),
                    titleTrailing: Text(
                      'Locked $_lockedCount/$_selectedCardCount',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0C4A6E)),
                    ),
                    children: [
                      Row(
                        children: [
                          const Text('Quick Entry',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0EA5E9),
                            ),
                            icon: _saving
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.save, size: 16),
                            label: const Text('Save Bill'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _addCard(),
                            icon: const Icon(Icons.add),
                            label: const Text('Add Card'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _editorStatPill(
                              icon: Icons.style_rounded,
                              label: 'Cards',
                              value: '$_selectedCardCount',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _editorStatPill(
                              icon: Icons.view_list_rounded,
                              label: 'Rows',
                              value: '$_effectiveRowCount',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _editorStatPill(
                              icon: Icons.calculate_rounded,
                              label: 'Total',
                              value: _fmtNum(_grandTotal).isEmpty
                                  ? '0'
                                  : _fmtNum(_grandTotal),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_selectedCardCount == 0)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.blueGrey.shade100),
                          ),
                          child: const Text(
                            'No card selected yet. Tap "Add Card" to pick from Ready-to-Dispatch.',
                            style: TextStyle(fontSize: 13),
                          ),
                        )
                      else
                        ..._cards
                            .asMap()
                            .entries
                            .where((e) => _isSelectedGroup(e.value))
                            .map((e) => _selectedCardTile(e.key, e.value)),
                      const SizedBox(height: 10),
                      _buildCardEditorPanel(
                        _resolvedActiveIndex,
                        _cards[_resolvedActiveIndex],
                      ),
                    ],
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }

  Widget _editorStatPill({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueGrey.shade100),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF0284C7)),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0C4A6E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectedCardTile(int idx, _CardGroup g) {
    final isActive = idx == _resolvedActiveIndex;
    final rowCount = g.qtyRows.where((r) => r.qty > 0 && r.pcs > 0).length;
    final totalText = _fmtNum(g.total).isEmpty ? '0' : _fmtNum(g.total);
    final statusText = !g.locked
        ? 'Open'
        : (g.closeOnSave ? 'Locked - closes on save' : 'Locked');

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: isActive ? const Color(0xFFE0F2FE) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isActive ? const Color(0xFF38BDF8) : Colors.blueGrey.shade100,
        ),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -1),
        onTap: () => setState(() => _activeCardIndex = idx),
        leading: CircleAvatar(
          radius: 14,
          backgroundColor:
              isActive ? const Color(0xFF0284C7) : const Color(0xFF0EA5E9),
          foregroundColor: Colors.white,
          child: Text('${idx + 1}', style: const TextStyle(fontSize: 11)),
        ),
        title: Text(
          '${g.company ?? ''} - ${g.designNo} - #${g.cardNo}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'Rows: $rowCount  |  Total: $totalText  |  $statusText',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: SizedBox(
          width: 94,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (g.locked)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.lock, size: 16, color: Color(0xFF0F766E)),
                ),
              IconButton(
                tooltip: 'Edit',
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: () => setState(() => _activeCardIndex = idx),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Delete',
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: g.locked ? null : () => _removeCard(idx),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardEditorPanel(int idx, _CardGroup g) {
    return Card(
      key: ValueKey('editor_${g.programCardId ?? idx}_$idx'),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blueGrey.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  child:
                      Text('${idx + 1}', style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Card Entry',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (_selectedCardCount > 1)
                  Text(
                    'Tap tile above to switch',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: g.locked ? null : () => _pickCardForGroup(g),
                    icon: const Icon(Icons.style_rounded, size: 18),
                    label: Text(
                      g.programCardId == null
                          ? 'Select Ready Card'
                          : '${g.company ?? ''} - ${g.designNo} - #${g.cardNo}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (g.locked)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.lock, size: 18, color: Color(0xFF0F766E)),
                  ),
                IconButton(
                  tooltip: 'Remove Card',
                  onPressed: g.locked ? null : () => _removeCard(idx),
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                ),
              ],
            ),
            if (g.programCardId != null) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _chip('Co.', g.company ?? '-'),
                  if (_productNameOf(g.productId).isNotEmpty)
                    _chip('Product', _productNameOf(g.productId)),
                  _chip('Design', g.designNo),
                  _chip('Card', '#${g.cardNo}'),
                ],
              ),
            ],
            if (g.locked && g.programCardId != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: g.closeOnSave
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  g.closeOnSave
                      ? 'Will close this card after final bill save.'
                      : 'Card will stay open after final bill save.',
                  style: TextStyle(
                    fontSize: 12,
                    color: g.closeOnSave
                        ? const Color(0xFF166534)
                        : const Color(0xFF9A3412),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            ...g.qtyRows.asMap().entries.map((re) {
              final rIdx = re.key;
              final r = re.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: r.qtyCtrl,
                        focusNode: r.qtyFocus,
                        readOnly: g.locked,
                        textInputAction: TextInputAction.next,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Qty',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (!g.locked) {
                            FocusScope.of(context).requestFocus(r.pcsFocus);
                          }
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        'x',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: r.pcsCtrl,
                        focusNode: r.pcsFocus,
                        readOnly: g.locked,
                        textInputAction: TextInputAction.done,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Pcs',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (!g.locked) _addQtyRow(g, focusQty: true);
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 60,
                      child: Text(
                        _fmtNum(r.total).isEmpty ? '-' : _fmtNum(r.total),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove row',
                      onPressed: g.locked ? null : () => _removeQtyRow(g, rIdx),
                      icon:
                          const Icon(Icons.close, size: 18, color: Colors.red),
                    ),
                  ],
                ),
              );
            }),
            Row(
              children: [
                TextButton.icon(
                  onPressed:
                      g.locked ? null : () => _addQtyRow(g, focusQty: true),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Qty Row'),
                ),
                const Spacer(),
                Text(
                  'Card Total: ',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                Text(
                  _fmtNum(g.total).isEmpty ? '0' : _fmtNum(g.total),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F766E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: g.locked
                  ? OutlinedButton.icon(
                      onPressed: () => _unlockCard(g),
                      icon: const Icon(Icons.lock_open, size: 18),
                      label: Text(g.closeOnSave
                          ? 'Edit (Will Close on Save)'
                          : 'Edit (Keep Open)'),
                    )
                  : FilledButton.icon(
                      onPressed: () => _lockCard(g),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0EA5E9),
                      ),
                      icon: const Icon(Icons.save_rounded, size: 18),
                      label: const Text('Save Card'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 11)),
    );
  }
}

/// =================================================================
///  Bottom-sheet picker showing ONLY Ready-to-Dispatch program cards.
/// =================================================================
class _CardPickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> cards;
  final Map<int, Party> partyById;
  final Map<int, Product> productById;
  const _CardPickerSheet(
      {required this.cards,
      required this.partyById,
      required this.productById});

  @override
  State<_CardPickerSheet> createState() => _CardPickerSheetState();
}

class _CardPickerSheetState extends State<_CardPickerSheet> {
  final _df = DateFormat('dd-MM-yyyy');
  final _searchCtrl = TextEditingController();
  String _company = 'All';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = widget.cards.where((c) {
      if (_company != 'All' && (c['company'] ?? '') != _company) return false;
      if (q.isEmpty) return true;
      final s =
          '${c['design_no']} ${c['card_no']} ${c['line_no']} ${c['company']}'
              .toLowerCase();
      return s.contains(q);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(4))),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.style_rounded, color: Color(0xFF0EA5E9)),
                SizedBox(width: 8),
                Text('Select Ready-to-Dispatch Card',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search design / card / line',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _company,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem(
                        value: 'All', child: Text('All Co.')),
                    ...ProgramCardConstants.companies
                        .map((c) => DropdownMenuItem(value: c, child: Text(c))),
                  ],
                  onChanged: (v) => setState(() => _company = v ?? 'All'),
                ),
              ],
            ),
          ),
          if (filtered.isEmpty)
            const Expanded(
                child:
                    Center(child: Text('No matching Ready-to-Dispatch cards.')))
          else
            Expanded(
              child: ListView.separated(
                controller: ctrl,
                itemCount: filtered.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 16, endIndent: 16),
                itemBuilder: (_, i) {
                  final c = filtered[i];
                  final pid = c['party_id'] as int?;
                  final party = pid != null ? widget.partyById[pid] : null;
                  final prodId = c['product_id'] as int?;
                  final productName = prodId == null
                      ? ''
                      : (widget.productById[prodId]?.name ?? '');
                  final dt = c['program_date'] as int?;
                  return ListTile(
                    onTap: () => Navigator.pop(context, c),
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF0EA5E9),
                      foregroundColor: Colors.white,
                      child: Text((c['company'] ?? '?').toString().substring(
                          0,
                          (c['company'] ?? '?').toString().length > 2
                              ? 2
                              : (c['company'] ?? '?').toString().length)),
                    ),
                    title: Text(
                        '${c['design_no'] ?? ''}  -  #${c['card_no'] ?? ''}'),
                    subtitle: Text(
                        '${party?.name ?? '-'}${productName.isEmpty ? '' : '  -  $productName'}  -  Line ${c['line_no'] ?? '-'}  -  ${dt != null ? _df.format(DateTime.fromMillisecondsSinceEpoch(dt)) : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
