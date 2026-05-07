// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../widgets/passcode_gate.dart';
import 'program_card_page.dart' show ProgramCardConstants;

/// =================================================================
///  DISPATCH GOODS — bills + multiple design rows per bill.
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
  Map<int, int> _itemCount = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final parties = await _db.getParties();
    _partyById = {for (final p in parties) if (p.id != null) p.id!: p};
    final bills = await _db.getDispatchBills(
      search: _searchCtrl.text.trim().isEmpty ? null : _searchCtrl.text.trim(),
    );
    final counts = <int, int>{};
    final dbi = await _db.database;
    for (final b in bills) {
      final id = b['id'] as int;
      final r = await dbi.rawQuery(
          'SELECT COUNT(*) c FROM dispatch_items WHERE bill_id = ?', [id]);
      counts[id] = (r.first['c'] as int?) ?? 0;
    }
    if (!mounted) return;
    setState(() {
      _bills = bills;
      _itemCount = counts;
      _loading = false;
    });
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

  Future<void> _delete(Map<String, dynamic> bill) async {
    final pass = await requirePasscode(context, action: 'Delete');
    if (!pass) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Bill?'),
        content: Text('Delete bill ${bill['bill_no'] ?? ''} and all its items?'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch Goods'),
        backgroundColor: const Color(0xFF0EA5E9),
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: const Color(0xFF0EA5E9),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Bill'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by Bill No.',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _bills.isEmpty
                    ? const Center(
                        child: Text('No dispatch bills yet.\nTap "New Bill".',
                            textAlign: TextAlign.center))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                        itemCount: _bills.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final b = _bills[i];
                          final id = b['id'] as int;
                          final pid = b['party_id'] as int?;
                          final party = pid != null ? _partyById[pid] : null;
                          final dt = b['bill_date'] as int?;
                          return Card(
                            elevation: 1,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            child: ListTile(
                              onTap: () => _openEditor(bill: b),
                              leading: CircleAvatar(
                                backgroundColor: const Color(0xFF0EA5E9),
                                foregroundColor: Colors.white,
                                child: Text('${_itemCount[id] ?? 0}'),
                              ),
                              title: Text(
                                  'Bill #${b['bill_no'] ?? ''}  •  ${party?.name ?? '-'}'),
                              subtitle: Text(
                                  '${dt != null ? _df.format(DateTime.fromMillisecondsSinceEpoch(dt)) : ''}   ·   ${_itemCount[id] ?? 0} item(s)'),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'edit') _openEditor(bill: b);
                                  if (v == 'delete') _delete(b);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'edit', child: Text('Edit')),
                                  PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete',
                                          style:
                                              TextStyle(color: Colors.red))),
                                ],
                              ),
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

/// =================================================================
///  EDITOR — one bill, many cards, many Qty×Pcs sub-rows per card.
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

/// One Qty × Pcs entry under a card. Each one is persisted as a separate
/// dispatch_items row in the DB.
class _QtyRow {
  int? id; // existing dispatch_items.id (null = new)
  final TextEditingController qtyCtrl;
  final TextEditingController pcsCtrl;

  _QtyRow({this.id, double qty = 0, double pcs = 0})
      : qtyCtrl = TextEditingController(text: _fmtNum(qty)),
        pcsCtrl = TextEditingController(text: _fmtNum(pcs));

  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;
  double get pcs => double.tryParse(pcsCtrl.text.trim()) ?? 0;
  double get total => qty * pcs;

  void dispose() {
    qtyCtrl.dispose();
    pcsCtrl.dispose();
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
  /// passcode 0056 is entered to unlock.
  bool locked;

  _CardGroup({
    this.programCardId,
    this.company,
    this.productId,
    this.designNo = '',
    this.cardNo = '',
    List<_QtyRow>? qtyRows,
    this.locked = false,
  }) : qtyRows = qtyRows ?? [_QtyRow()];

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

  /// All program cards currently in "Ready to Dispatch".
  List<Map<String, dynamic>> _readyCards = [];

  final List<_CardGroup> _cards = [];
  final List<int> _removedItemIds = [];
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
    _parties = await _db.getParties();
    _products = await _db.getProducts();
    _readyCards = await _db.getProgramCards(status: 'Ready to Dispatch');

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
    if (mounted) setState(() => _loading = false);
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
          content: Text(
              'No program cards are in "Ready to Dispatch" status.')));
      return;
    }
    final picked = _cards
        .where((g) => g != group && g.programCardId != null)
        .map((g) => g.programCardId)
        .toSet();
    final available =
        _readyCards.where((c) => !picked.contains(c['id'] as int?)).toList();

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CardPickerSheet(
        cards: available,
        partyById: {for (final p in _parties) if (p.id != null) p.id!: p},
        productById: {
          for (final p in _products) if (p.id != null) p.id!: p,
        },
      ),
    );
    if (chosen == null) return;

    setState(() {
      group.programCardId = chosen['id'] as int?;
      group.company = (chosen['company'] ?? '').toString();
      group.productId = chosen['product_id'] as int?;
      group.designNo = (chosen['design_no'] ?? '').toString();
      group.cardNo = (chosen['card_no'] ?? '').toString();
      if (_party == null) {
        final pid = chosen['party_id'] as int?;
        if (pid != null) {
          final found = _parties.where((p) => p.id == pid);
          if (found.isNotEmpty) _party = found.first;
        }
      }
    });
  }

  void _addCard() => setState(() => _cards.add(_CardGroup()));

  /// Lock a card (called by per-card "Save Card" button).
  /// Shows a confirmation dialog with programmed vs dispatched qty,
  /// and offers to close (mark Completed) the program card.
  Future<void> _lockCard(_CardGroup g) async {
    if (g.programCardId == null &&
        g.designNo.trim().isEmpty &&
        g.cardNo.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a card first.')));
      return;
    }
    final hasQty = g.qtyRows.any((r) => r.qty > 0 || r.pcs > 0);
    if (!hasQty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least one Qty × Pcs.')));
      return;
    }

    // Compute programmed (TP × Line) and dispatched totals.
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
    final thisBill =
        g.qtyRows.fold<double>(0, (s, r) => s + (r.qty * r.pcs));
    final newTotal = already + thisBill;
    final remaining = programmed - newTotal;

    String f(double v) => v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);

    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('Programmed (TP × Line)', f(programmed)),
            _kv('Already Dispatched', f(already)),
            _kv('This Bill', f(thisBill)),
            const Divider(),
            _kv('Total After Save', f(newTotal),
                bold: true,
                color: newTotal > programmed ? Colors.red : null),
            _kv('Remaining', f(remaining),
                bold: true,
                color: remaining < 0
                    ? Colors.red
                    : (remaining == 0 ? Colors.green : null)),
            const SizedBox(height: 12),
            const Text('Do you want to CLOSE this card?',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Text(
              'Closed cards move to Completed and will no longer appear in '
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

    if (choice == 'yes' && pcId != null) {
      await _db.updateProgramCard(pcId, {'status': 'Completed'});
      // Remove from local Ready list so picker won't show it anymore.
      _readyCards.removeWhere((c) => c['id'] == pcId);
    }
    if (!mounted) return;
    setState(() => g.locked = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(choice == 'yes'
            ? 'Card saved & closed (Completed).'
            : 'Card saved (locked).')));
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

  /// Unlock by passcode 0056.
  Future<void> _unlockCard(_CardGroup g) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Passcode'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Passcode',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unlock')),
        ],
      ),
    );
    if (ok != true) return;
    if (ctrl.text.trim() == '0056') {
      setState(() => g.locked = false);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong passcode.')));
    }
  }

  void _removeCard(int idx) {
    setState(() {
      final g = _cards.removeAt(idx);
      for (final r in g.qtyRows) {
        if (r.id != null) _removedItemIds.add(r.id!);
      }
      g.disposeAll();
      if (_cards.isEmpty) _cards.add(_CardGroup());
    });
  }

  void _addQtyRow(_CardGroup g) =>
      setState(() => g.qtyRows.add(_QtyRow()));

  void _removeQtyRow(_CardGroup g, int rIdx) {
    setState(() {
      final row = g.qtyRows.removeAt(rIdx);
      if (row.id != null) _removedItemIds.add(row.id!);
      row.dispose();
      if (g.qtyRows.isEmpty) g.qtyRows.add(_QtyRow());
    });
  }

  double get _grandTotal =>
      _cards.fold(0.0, (s, g) => s + g.total);

  Future<void> _save() async {
    if (_billNoCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bill No. is required.')));
      return;
    }
    if (_party == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Party is required.')));
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

    setState(() => _saving = true);
    try {
      final billData = <String, dynamic>{
        'bill_date': DateTime(_date.year, _date.month, _date.day)
            .millisecondsSinceEpoch,
        'bill_no': _billNoCtrl.text.trim(),
        'party_id': _party?.id,
        'remarks': _remarksCtrl.text.trim(),
      };

      int billId;
      if (_isEdit) {
        billId = widget.bill!['id'] as int;
        await _db.updateDispatchBill(billId, billData);
      } else {
        billId = await _db.insertDispatchBill(billData);
      }

      for (final id in _removedItemIds) {
        await _db.deleteDispatchItem(id);
      }

      for (final g in validCards) {
        for (final r in g.qtyRows) {
          // Skip blank rows on new cards
          if (r.id == null && r.qty == 0 && r.pcs == 0) continue;
          final data = <String, dynamic>{
            'bill_id': billId,
            'program_card_id': g.programCardId,
            'company': g.company,
            'product_id': g.productId,
            'design_no': g.designNo,
            'card_no': g.cardNo,
            'qty': r.qty,
            'pcs': r.pcs,
          };
          if (r.id == null) {
            await _db.insertDispatchItem(data);
          } else {
            await _db.updateDispatchItem(r.id!, data);
          }
        }
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Bill' : 'New Bill'),
        backgroundColor: const Color(0xFF0EA5E9),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    const Text('Grand Total',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(_fmtNum(_grandTotal).isEmpty
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
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
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
                              decoration: const InputDecoration(
                                labelText: 'Bill No.',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 10),
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
                                    child:
                                        Text(p.name, overflow: TextOverflow.ellipsis),
                                  ))
                              .toList(),
                          onChanged: (v) => setState(() => _party = v),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _remarksCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Remarks',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Cards',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: _addCard,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Card'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._cards.asMap().entries.map((e) {
                  final idx = e.key;
                  final g = e.value;
                  return Card(
                    key: ValueKey('card_${g.programCardId ?? idx}_$idx'),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 14,
                                backgroundColor: const Color(0xFF0EA5E9),
                                foregroundColor: Colors.white,
                                child: Text('${idx + 1}',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: g.locked
                                      ? null
                                      : () => _pickCardForGroup(g),
                                  icon: const Icon(Icons.style_rounded,
                                      size: 18),
                                  label: Text(
                                    g.programCardId == null
                                        ? 'Select Ready Card'
                                        : '${g.company ?? ''} · ${g.designNo} · #${g.cardNo}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (g.locked)
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Icon(Icons.lock,
                                      size: 18, color: Color(0xFF0F766E)),
                                ),
                              IconButton(
                                tooltip: 'Remove Card',
                                onPressed: g.locked
                                    ? null
                                    : () => _removeCard(idx),
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red),
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
                                  _chip('Product',
                                      _productNameOf(g.productId)),
                                _chip('Design', g.designNo),
                                _chip('Card', '#${g.cardNo}'),
                              ],
                            ),
                          ],
                          const SizedBox(height: 10),
                          // Qty × Pcs sub-rows
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
                                      readOnly: g.locked,
                                      keyboardType: const TextInputType
                                          .numberWithOptions(decimal: true),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                            RegExp(r'[0-9.]'))
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: 'Qty',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ),
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(horizontal: 6),
                                    child: Text('×',
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: r.pcsCtrl,
                                      readOnly: g.locked,
                                      keyboardType: const TextInputType
                                          .numberWithOptions(decimal: true),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                            RegExp(r'[0-9.]'))
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: 'Pcs',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 60,
                                    child: Text(
                                      _fmtNum(r.total).isEmpty
                                          ? '—'
                                          : _fmtNum(r.total),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove row',
                                    onPressed: g.locked
                                        ? null
                                        : () => _removeQtyRow(g, rIdx),
                                    icon: const Icon(Icons.close,
                                        size: 18, color: Colors.red),
                                  ),
                                ],
                              ),
                            );
                          }),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: g.locked
                                    ? null
                                    : () => _addQtyRow(g),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add Qty Row'),
                              ),
                              const Spacer(),
                              Text('Card Total: ',
                                  style: TextStyle(
                                      color: Colors.grey.shade700)),
                              Text(
                                _fmtNum(g.total).isEmpty
                                    ? '0'
                                    : _fmtNum(g.total),
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F766E)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: double.infinity,
                            child: g.locked
                                ? OutlinedButton.icon(
                                    onPressed: () => _unlockCard(g),
                                    icon: const Icon(Icons.lock_open,
                                        size: 18),
                                    label: const Text(
                                        'Edit (Passcode required)'),
                                  )
                                : FilledButton.icon(
                                    onPressed: () => _lockCard(g),
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          const Color(0xFF0EA5E9),
                                    ),
                                    icon: const Icon(Icons.save_rounded,
                                        size: 18),
                                    label: const Text('Save Card'),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 80),
              ],
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
      child: Text('$label: $value',
          style: const TextStyle(fontSize: 11)),
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
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
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
                    ...ProgramCardConstants.companies.map((c) =>
                        DropdownMenuItem(value: c, child: Text(c))),
                  ],
                  onChanged: (v) =>
                      setState(() => _company = v ?? 'All'),
                ),
              ],
            ),
          ),
          if (filtered.isEmpty)
            const Expanded(
                child: Center(
                    child: Text('No matching Ready-to-Dispatch cards.')))
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
                  final party =
                      pid != null ? widget.partyById[pid] : null;
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
                      child: Text((c['company'] ?? '?')
                          .toString()
                          .substring(
                              0,
                              (c['company'] ?? '?').toString().length > 2
                                  ? 2
                                  : (c['company'] ?? '?').toString().length)),
                    ),
                    title: Text(
                        '${c['design_no'] ?? ''}  ·  #${c['card_no'] ?? ''}'),
                    subtitle: Text(
                        '${party?.name ?? '-'}${productName.isEmpty ? '' : '  ·  $productName'}  ·  Line ${c['line_no'] ?? '-'}  ·  ${dt != null ? _df.format(DateTime.fromMillisecondsSinceEpoch(dt)) : ''}'),
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
