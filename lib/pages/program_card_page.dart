// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../widgets/passcode_gate.dart';

/// Public constants for the Program Card module — used by the report page too.
class ProgramCardConstants {
  ProgramCardConstants._();

  /// Fixed list of companies for the Company dropdown.
  static const companies = ['SLH', 'MS', 'SI', 'MS-SI'];

  /// Status workflow steps in order. (db column → display label)
  static const statusFlow = <MapEntry<String, String>>[
    MapEntry('status_dhaga_cutting', 'Dhaga Cutting'),
    MapEntry('status_checking', 'Checking'),
    MapEntry('status_alter', 'Alter'),
    MapEntry('status_cutting', 'Cutting'),
    MapEntry('status_shoulder_cutting', 'Shoulder Cutting'),
    MapEntry('status_stiching', 'Stiching'),
    MapEntry('status_ready_dispatch', 'Ready to Dispatch'),
  ];

  /// Color per step (parallel to [statusFlow]).
  static const stepColors = [
    Color(0xFF6366F1), // dhaga cutting
    Color(0xFF14B8A6), // checking
    Color(0xFFF59E0B), // alter
    Color(0xFFEC4899), // cutting
    Color(0xFF7C3AED), // shoulder cutting
    Color(0xFF0EA5E9), // stiching
    Color(0xFF22C55E), // ready to dispatch
  ];
}

class ProgramCardPage extends StatefulWidget {
  const ProgramCardPage({super.key});

  @override
  State<ProgramCardPage> createState() => _ProgramCardPageState();
}

class _ProgramCardPageState extends State<ProgramCardPage> {
  // ── Companies (fixed) ──
  static const companies = ProgramCardConstants.companies;

  // ── Status workflow (in order) ──
  static const statusFlow = ProgramCardConstants.statusFlow;

  static String labelForKey(String key) =>
      statusFlow.firstWhere((e) => e.key == key).value;

  List<Map<String, dynamic>> _cards = [];
  List<Party> _parties = [];
  List<Product> _products = [];
  bool _loading = true;

  String? _filterCompany;
  String? _filterStatus;
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    if (mounted && _cards.isEmpty) setState(() => _loading = true);
    try {
      final cards = await ErpDatabase.instance.getProgramCards(
        company: _filterCompany,
        status: _filterStatus,
        search: _searchCtrl.text.trim().isEmpty
            ? null
            : _searchCtrl.text.trim(),
      );
      final parties = await ErpDatabase.instance.getParties();
      final products = await ErpDatabase.instance.getProducts();
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _parties = parties;
        _products = products;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _msg('Error loading: $e');
    }
  }

  void _msg(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String _partyName(int? id) {
    if (id == null) return '';
    return _parties.firstWhere(
      (p) => p.id == id,
      orElse: () => Party(name: '', address: '', mobile: ''),
    ).name;
  }

  String _productName(int? id) {
    if (id == null) return '';
    final found = _products.where((p) => p.id == id);
    return found.isEmpty ? '' : found.first.name;
  }

  // ── Status helpers ──
  /// Returns the latest completed status key, or null if none completed.
  String? _currentStatusKey(Map<String, dynamic> card) {
    String? latest;
    for (final s in statusFlow) {
      if (card[s.key] != null) latest = s.key;
    }
    return latest;
  }

  Color _statusColor(String? key) {
    if (key == null) return Colors.grey;
    final idx = statusFlow.indexWhere((e) => e.key == key);
    return idx >= 0 ? ProgramCardConstants.stepColors[idx] : Colors.grey;
  }

  /// Computed Qty for a card = TP × Line (numeric portion of line_no).
  /// Returns 0 when either is missing / non-numeric.
  static double cardQty(Map<String, dynamic> card) {
    final tp = (card['tp'] as num?)?.toDouble() ?? 0;
    final lineRaw = (card['line_no'] ?? '').toString();
    final m = RegExp(r'[-+]?\d*\.?\d+').firstMatch(lineRaw);
    final line = m == null ? 0.0 : (double.tryParse(m.group(0)!) ?? 0);
    return tp * line;
  }

  static String fmtQty(double v) {
    if (v == 0) return '0';
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  double get _grandQty =>
      _cards.fold(0.0, (s, c) => s + cardQty(c));

  // ── Actions ──
  Future<void> _openEditor({Map<String, dynamic>? card}) async {
    if (_parties.isEmpty) {
      _msg('Please add Parties in master first');
      return;
    }
    // Editing existing card requires passcode.
    if (card != null) {
      final ok = await requirePasscode(context, action: 'Edit');
      if (!ok) return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _ProgramCardEditorPage(
          card: card,
          parties: _parties,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> card) async {
    final pass = await requirePasscode(context, action: 'Delete');
    if (!pass) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Card'),
        content: Text('Delete card #${card['card_no']} ?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ErpDatabase.instance.deleteProgramCard(card['id'] as int);
    _msg('Card deleted');
    _load();
  }

  /// Opens a sheet to mark each status step done/undone with a date.
  Future<void> _editStatus(Map<String, dynamic> card) async {
    final cardId = card['id'] as int;
    // Working copy of completion timestamps.
    final values = <String, int?>{
      for (final s in statusFlow) s.key: card[s.key] as int?,
    };

    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (_, scrollController) {
            return StatefulBuilder(
              builder: (ctx, setSheet) {
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 10, bottom: 6),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.checklist_rounded,
                                color: Color(0xFF1565C0)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Status — #${card['card_no']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollController,
                          itemCount: statusFlow.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final s = statusFlow[i];
                            final ts = values[s.key];
                            final done = ts != null;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: done
                                    ? _statusColor(s.key)
                                    : Colors.grey.shade300,
                                child: done
                                    ? const Icon(Icons.check,
                                        color: Colors.white, size: 18)
                                    : Text('${i + 1}',
                                        style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontWeight: FontWeight.w700)),
                              ),
                              title: Text(s.value,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: done
                                  ? Text(
                                      'Completed: ${DateFormat('dd MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(ts))}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: _statusColor(s.key)),
                                    )
                                  : const Text('Pending',
                                      style: TextStyle(fontSize: 12)),
                              trailing: Wrap(
                                spacing: 4,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.event_available,
                                        size: 20),
                                    tooltip: done
                                        ? 'Change date'
                                        : 'Mark complete',
                                    onPressed: () async {
                                      final picked = await showDatePicker(
                                        context: ctx,
                                        initialDate: done
                                            ? DateTime
                                                .fromMillisecondsSinceEpoch(ts)
                                            : DateTime.now(),
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime(2100),
                                      );
                                      if (picked != null) {
                                        setSheet(() => values[s.key] =
                                            picked.millisecondsSinceEpoch);
                                      }
                                    },
                                  ),
                                  if (done)
                                    IconButton(
                                      icon: const Icon(Icons.clear,
                                          size: 20, color: Colors.red),
                                      tooltip: 'Clear',
                                      onPressed: () => setSheet(
                                          () => values[s.key] = null),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.save_rounded),
                                  label: const Text('Save'),
                                  onPressed: () => Navigator.pop(ctx, true),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );

    if (changed != true) return;

    // Determine new "current status" = latest completed.
    String? latest;
    for (final s in statusFlow) {
      if (values[s.key] != null) latest = s.value;
    }

    // If card is already Completed (closed), never overwrite back to a
    // step status — closed means closed.
    if ((card['status'] ?? '') == 'Completed') {
      latest = 'Completed';
    }

    final updateData = <String, dynamic>{
      for (final s in statusFlow) s.key: values[s.key],
      'status': latest,
    };
    await ErpDatabase.instance.updateProgramCard(cardId, updateData);
    _msg('Status updated');
    _load();
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Program Card'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('New Card'),
      ),
      bottomNavigationBar: _loading
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withValues(alpha: 0.10),
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    const Icon(Icons.summarize_rounded,
                        color: Color(0xFF1565C0)),
                    const SizedBox(width: 8),
                    Text('Cards: ${_cards.length}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const Text('Grand Qty (TP×Line): ',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(fmtQty(_grandQty),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F766E))),
                  ],
                ),
              ),
            ),
      body: Column(
        children: [
          // ── Filters ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _filterCompany,
                    decoration: const InputDecoration(
                      labelText: 'Company',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('All')),
                      ...companies.map(
                        (c) => DropdownMenuItem<String?>(
                            value: c, child: Text(c)),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() => _filterCompany = v);
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    value: _filterStatus,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('All')),
                      ...statusFlow.map(
                        (s) => DropdownMenuItem<String?>(
                            value: s.value, child: Text(s.value)),
                      ),
                    ],
                    onChanged: (v) {
                      setState(() => _filterStatus = v);
                      _load();
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search Card # / Design / Line',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchCtrl.clear();
                          _load();
                        },
                      ),
              ),
              onChanged: (_) {
                _searchDebounce?.cancel();
                _searchDebounce = Timer(
                    const Duration(milliseconds: 350), _load);
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _cards.isEmpty
                    ? const Center(child: Text('No program cards'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                        itemCount: _cards.length,
                        itemBuilder: (_, i) => _cardTile(_cards[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _cardTile(Map<String, dynamic> card) {
    final dateMs = card['program_date'] as int?;
    final dateStr = dateMs != null
        ? DateFormat('dd MMM yyyy')
            .format(DateTime.fromMillisecondsSinceEpoch(dateMs))
        : '—';
    final company = (card['company'] ?? '').toString();
    final cardNo = (card['card_no'] ?? '').toString();
    final designNo = (card['design_no'] ?? '').toString();
    final lineNo = (card['line_no'] ?? '').toString();
    final tp = (card['tp'] as num?)?.toDouble() ?? 0;
    final partyName = _partyName(card['party_id'] as int?);

    final currentKey = _currentStatusKey(card);
    final currentLabel =
        currentKey == null ? 'Pending' : labelForKey(currentKey);
    final color = _statusColor(currentKey);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _editStatus(card),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: Card # + Company chip + menu
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '#$cardNo',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1565C0),
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (company.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        company,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Text(dateStr,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      final isCompleted =
                          (card['status'] ?? '') == 'Completed';
                      if (isCompleted && (v == 'edit' || v == 'status')) {
                        _msg('Card is Completed (closed) and cannot be reopened.');
                        return;
                      }
                      if (v == 'edit') _openEditor(card: card);
                      if (v == 'status') _editStatus(card);
                      if (v == 'delete') _delete(card);
                    },
                    itemBuilder: (_) {
                      final isCompleted =
                          (card['status'] ?? '') == 'Completed';
                      return [
                        PopupMenuItem(
                            value: 'status',
                            enabled: !isCompleted,
                            child: const Text('Update Status')),
                        PopupMenuItem(
                            value: 'edit',
                            enabled: !isCompleted,
                            child: const Text('Edit Details')),
                        const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete',
                                style: TextStyle(color: Colors.red))),
                      ];
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Party
              if (partyName.isNotEmpty)
                Text(partyName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 4),
              // Design / Line / TP
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (_productName(card['product_id'] as int?).isNotEmpty)
                    _infoChip(Icons.inventory_2_outlined,
                        'Product: ${_productName(card['product_id'] as int?)}'),
                  if (designNo.isNotEmpty)
                    _infoChip(Icons.draw_outlined, 'Design: $designNo'),
                  if (lineNo.isNotEmpty)
                    _infoChip(Icons.linear_scale, 'Line: $lineNo'),
                  if (tp > 0)
                    _infoChip(Icons.production_quantity_limits,
                        'TP: ${tp.toStringAsFixed(tp.truncateToDouble() == tp ? 0 : 2)}'),
                  if (cardQty(card) > 0)
                    _infoChip(Icons.calculate_outlined,
                        'Qty: ${fmtQty(cardQty(card))}'),
                ],
              ),
              const SizedBox(height: 8),
              // Status row
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(currentLabel,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: color,
                          fontSize: 13)),
                  const Spacer(),
                  Text(
                    '${_completedCount(card)}/${statusFlow.length} steps',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Step pills
              SizedBox(
                height: 26,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: statusFlow.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final s = statusFlow[i];
                    final done = card[s.key] != null;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: done
                            ? _statusColor(s.key).withValues(alpha: 0.12)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: done
                              ? _statusColor(s.key).withValues(alpha: 0.4)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            done
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 12,
                            color: done
                                ? _statusColor(s.key)
                                : Colors.grey.shade500,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            s.value,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: done
                                  ? _statusColor(s.key)
                                  : Colors.grey.shade700,
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
        ),
      ),
    );
  }

  int _completedCount(Map<String, dynamic> card) {
    var n = 0;
    for (final s in statusFlow) {
      if (card[s.key] != null) n++;
    }
    return n;
  }

  Widget _infoChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade700),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade800)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Editor: Add / Edit a Program Card (details only, status separate)
// ═══════════════════════════════════════════════════════════════
class _ProgramCardEditorPage extends StatefulWidget {
  final Map<String, dynamic>? card;
  final List<Party> parties;

  const _ProgramCardEditorPage({
    this.card,
    required this.parties,
  });

  @override
  State<_ProgramCardEditorPage> createState() =>
      _ProgramCardEditorPageState();
}

class _ProgramCardEditorPageState extends State<_ProgramCardEditorPage> {
  final _formKey = GlobalKey<FormState>();

  late DateTime _date;
  String? _company;
  int? _partyId;
  int? _productId;
  List<Product> _products = [];
  final _designCtrl = TextEditingController();
  final _cardNoCtrl = TextEditingController();
  final _tpCtrl = TextEditingController();
  final _lineCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();

  bool _saving = false;

  bool get _isEdit => widget.card != null;

  @override
  void initState() {
    super.initState();
    final c = widget.card;
    if (c != null) {
      _date = DateTime.fromMillisecondsSinceEpoch(
          (c['program_date'] as int?) ?? DateTime.now().millisecondsSinceEpoch);
      _company = (c['company'] as String?);
      _partyId = c['party_id'] as int?;
      _productId = c['product_id'] as int?;
      _designCtrl.text = (c['design_no'] ?? '').toString();
      _cardNoCtrl.text = (c['card_no'] ?? '').toString();
      final tp = (c['tp'] as num?)?.toDouble() ?? 0;
      _tpCtrl.text = tp == 0 ? '' : tp.toString();
      _lineCtrl.text = (c['line_no'] ?? '').toString();
      _remarksCtrl.text = (c['remarks'] ?? '').toString();
    } else {
      _date = DateTime.now();
    }
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    final list = await ErpDatabase.instance.getProducts();
    if (!mounted) return;
    setState(() => _products = list);
  }

  @override
  void dispose() {
    _designCtrl.dispose();
    _cardNoCtrl.dispose();
    _tpCtrl.dispose();
    _lineCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_company == null) {
      _msg('Select Company');
      return;
    }
    if (_partyId == null) {
      _msg('Select Party');
      return;
    }
    setState(() => _saving = true);

    final data = <String, dynamic>{
      'program_date': _date.millisecondsSinceEpoch,
      'company': _company,
      'party_id': _partyId,
      'product_id': _productId,
      'design_no': _designCtrl.text.trim(),
      'card_no': _cardNoCtrl.text.trim(),
      'tp': double.tryParse(_tpCtrl.text.trim()) ?? 0,
      'line_no': _lineCtrl.text.trim(),
      'remarks': _remarksCtrl.text.trim(),
    };

    try {
      if (_isEdit) {
        // Preserve Completed (closed) status — cannot be reopened.
        final existingStatus =
            (widget.card!['status'] ?? '').toString();
        if (existingStatus == 'Completed') {
          data['status'] = 'Completed';
        }
        await ErpDatabase.instance
            .updateProgramCard(widget.card!['id'] as int, data);
      } else {
        // For new cards there's no completed status yet.
        data['status'] = null;
        await ErpDatabase.instance.insertProgramCard(data);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      _msg('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _msg(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Program Card' : 'New Program Card'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Date
            InkWell(
              onTap: _pickDate,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date',
                  prefixIcon: Icon(Icons.calendar_today_rounded),
                  border: OutlineInputBorder(),
                ),
                child: Text(DateFormat('dd MMM yyyy').format(_date)),
              ),
            ),
            const SizedBox(height: 12),
            // Company
            DropdownButtonFormField<String>(
              value: _company,
              decoration: const InputDecoration(
                labelText: 'Company *',
                prefixIcon: Icon(Icons.business_rounded),
                border: OutlineInputBorder(),
              ),
              items: _ProgramCardPageState.companies
                  .map((c) =>
                      DropdownMenuItem<String>(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) => setState(() => _company = v),
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            // Party
            DropdownButtonFormField<int>(
              value: _partyId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Party Code *',
                prefixIcon: Icon(Icons.person_pin_rounded),
                border: OutlineInputBorder(),
              ),
              items: widget.parties
                  .where((p) => p.id != null)
                  .map((p) => DropdownMenuItem<int>(
                      value: p.id, child: Text(p.name)))
                  .toList(),
              onChanged: (v) => setState(() => _partyId = v),
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            // Product
            DropdownButtonFormField<int>(
              value: _productId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Product',
                prefixIcon: Icon(Icons.inventory_2_outlined),
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<int>(
                    value: null, child: Text('— None —')),
                ..._products
                    .where((p) => p.id != null)
                    .map((p) => DropdownMenuItem<int>(
                        value: p.id, child: Text(p.name))),
              ],
              onChanged: (v) => setState(() => _productId = v),
            ),
            const SizedBox(height: 12),
            // Card No (with # prefix as decoration)
            TextFormField(
              controller: _cardNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Card No *',
                prefixText: '# ',
                prefixIcon: Icon(Icons.confirmation_number_rounded),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            // Design No
            TextFormField(
              controller: _designCtrl,
              decoration: const InputDecoration(
                labelText: 'Design No',
                prefixIcon: Icon(Icons.draw_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // TP
            TextFormField(
              controller: _tpCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'TP (Quantity)',
                prefixIcon: Icon(Icons.production_quantity_limits),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // Line
            TextFormField(
              controller: _lineCtrl,
              decoration: const InputDecoration(
                labelText: 'Line',
                prefixIcon: Icon(Icons.linear_scale),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // Remarks
            TextFormField(
              controller: _remarksCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Remarks',
                prefixIcon: Icon(Icons.notes_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded),
              label: Text(_isEdit ? 'Update' : 'Save'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
