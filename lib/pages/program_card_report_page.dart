// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'program_card_page.dart';

class ProgramCardReportPage extends StatefulWidget {
  const ProgramCardReportPage({super.key});

  @override
  State<ProgramCardReportPage> createState() => _ProgramCardReportPageState();
}

class _ProgramCardReportPageState extends State<ProgramCardReportPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  bool _loading = true;
  List<Map<String, dynamic>> _cards = [];
  List<Party> _parties = [];
  List<Product> _products = [];

  // Filters
  String? _filterCompany; // null = all
  String? _filterStatus; // null = all (uses display label)
  DateTime? _fromDate;
  DateTime? _toDate;

  static const _pendingLabel = 'Pending';
  static const _closedLabel = 'Dispatched';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    _tab.dispose();
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    if (_cards.isEmpty && mounted) setState(() => _loading = true);
    try {
      final cards = await ErpDatabase.instance.getProgramCards();
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
    }
  }

  // â”€â”€ Helpers â”€â”€
  String _partyName(int? id) {
    if (id == null) return '';
    return _parties
        .firstWhere(
          (p) => p.id == id,
          orElse: () => Party(name: '', address: '', mobile: ''),
        )
        .name;
  }

  String _productName(int? id) {
    if (id == null) return '';
    final f = _products.where((p) => p.id == id);
    return f.isEmpty ? '' : f.first.name;
  }

  bool _isDispatchedCard(Map<String, dynamic> card) {
    final s = (card['status'] ?? '').toString().trim().toLowerCase();
    return s == 'dispatched' || s == 'completed';
  }

  /// Returns current status display label.
  String _currentStatusLabel(Map<String, dynamic> card) {
    if (_isDispatchedCard(card)) return _closedLabel;
    String? latest;
    for (final s in ProgramCardConstants.statusFlow) {
      if (card[s.key] != null) latest = s.value;
    }
    return latest ?? _pendingLabel;
  }

  Color _statusColor(String label) {
    if (label == _closedLabel) return const Color(0xFF334155);
    if (label == _pendingLabel) return Colors.grey;
    final idx =
        ProgramCardConstants.statusFlow.indexWhere((e) => e.value == label);
    return idx >= 0 ? ProgramCardConstants.stepColors[idx] : Colors.grey;
  }

  /// Apply filters (company, status, date range) and return matching cards.
  List<Map<String, dynamic>> get _filtered {
    return _cards.where((c) {
      if (_filterCompany != null &&
          (c['company'] ?? '').toString() != _filterCompany) {
        return false;
      }
      if (_filterStatus != null && _currentStatusLabel(c) != _filterStatus) {
        return false;
      }
      final ms = c['program_date'] as int?;
      if (ms != null) {
        final d = DateTime.fromMillisecondsSinceEpoch(ms);
        if (_fromDate != null && d.isBefore(_fromDate!)) return false;
        if (_toDate != null) {
          final end =
              DateTime(_toDate!.year, _toDate!.month, _toDate!.day, 23, 59, 59);
          if (d.isAfter(end)) return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final init = (isFrom ? _fromDate : _toDate) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _fromDate = d;
      } else {
        _toDate = d;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _filterCompany = null;
      _filterStatus = null;
      _fromDate = null;
      _toDate = null;
    });
  }

  // â”€â”€ UI â”€â”€
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Program Card Report'),
        actions: [
          IconButton(
            tooltip: 'Export PDF',
            onPressed: _loading ? null : _exportPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Clear filters',
            onPressed: _clearFilters,
            icon: const Icon(Icons.filter_alt_off_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.business), text: 'Company'),
            Tab(icon: Icon(Icons.person_pin_rounded), text: 'Party'),
            Tab(icon: Icon(Icons.flag_rounded), text: 'Status'),
            Tab(icon: Icon(Icons.calendar_month_rounded), text: 'Date'),
            Tab(icon: Icon(Icons.list_alt_rounded), text: 'All'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _filtersBar(),
                _summaryBar(),
                const Divider(height: 1),
                Expanded(
                  child: TabBarView(
                    controller: _tab,
                    children: [
                      _byCompanyView(),
                      _byPartyView(),
                      _byStatusView(),
                      _byDateView(),
                      _allCardsView(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _filtersBar() {
    final df = DateFormat('dd MMM yy');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterCompany,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Company',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 15, vertical: 6),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All')),
                    ...ProgramCardConstants.companies.map(
                      (c) =>
                          DropdownMenuItem<String?>(value: c, child: Text(c)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _filterCompany = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _filterStatus,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All')),
                    const DropdownMenuItem<String?>(
                        value: _pendingLabel, child: Text(_pendingLabel)),
                    const DropdownMenuItem<String?>(
                        value: _closedLabel, child: Text(_closedLabel)),
                    ...ProgramCardConstants.statusFlow.map(
                      (s) => DropdownMenuItem<String?>(
                          value: s.value, child: Text(s.value)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _filterStatus = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(isFrom: true),
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(
                    _fromDate == null
                        ? 'From'
                        : 'From ${df.format(_fromDate!)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(isFrom: false),
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(
                    _toDate == null ? 'To' : 'To ${df.format(_toDate!)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryBar() {
    final list = _filtered;
    final total = list.length;
    final pending =
        list.where((c) => _currentStatusLabel(c) == _pendingLabel).length;
    final ready =
        list.where((c) => _currentStatusLabel(c) == 'Ready to Dispatch').length;
    final dispatched =
        list.where((c) => _currentStatusLabel(c) == _closedLabel).length;
    final progress = total - pending - ready - dispatched;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        children: [
          _summaryChip('Total', total, const Color(0xFF1565C0)),
          const SizedBox(width: 6),
          _summaryChip('Pending', pending, Colors.grey),
          const SizedBox(width: 6),
          _summaryChip('In Progress', progress, const Color(0xFFF59E0B)),
          const SizedBox(width: 6),
          _summaryChip('Ready', ready, const Color(0xFF22C55E)),
          const SizedBox(width: 6),
          _summaryChip('Dispatched', dispatched, const Color(0xFF334155)),
        ],
      ),
    );
  }

  Widget _summaryChip(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Text('$value',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: color)),
            Text(label,
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  // â”€â”€ View 1: grouped by Company â”€â”€
  Widget _byCompanyView() {
    final list = _filtered;
    if (list.isEmpty) return const Center(child: Text('No records'));

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final c in list) {
      final key = (c['company'] ?? '-').toString();
      groups.putIfAbsent(key, () => []).add(c);
    }

    final keys = groups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final company = keys[i];
        final cards = groups[company]!;

        // Per-status counts within this company
        final statusCounts = <String, int>{_pendingLabel: 0};
        statusCounts[_closedLabel] = 0;
        for (final s in ProgramCardConstants.statusFlow) {
          statusCounts[s.value] = 0;
        }
        for (final c in cards) {
          final st = _currentStatusLabel(c);
          statusCounts[st] = (statusCounts[st] ?? 0) + 1;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            title: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(company,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1565C0))),
                ),
                const SizedBox(width: 10),
                Text('${cards.length} cards',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: statusCounts.entries
                    .where((e) => e.value > 0)
                    .map((e) => _miniStatusChip(e.key, e.value))
                    .toList(),
              ),
            ),
            children: cards.map(_cardRow).toList(),
          ),
        );
      },
    );
  }

  // â”€â”€ View 2: grouped by Status â”€â”€
  Widget _byStatusView() {
    final list = _filtered;
    if (list.isEmpty) return const Center(child: Text('No records'));

    // Initialize buckets in display order so headers always appear in workflow order.
    final orderedKeys = [
      ...ProgramCardConstants.statusFlow.map((s) => s.value),
      _closedLabel,
      _pendingLabel,
    ];
    final groups = <String, List<Map<String, dynamic>>>{
      for (final k in orderedKeys) k: [],
    };
    for (final c in list) {
      groups[_currentStatusLabel(c)]!.add(c);
    }

    final visible = orderedKeys.where((k) => groups[k]!.isNotEmpty).toList();
    if (visible.isEmpty) return const Center(child: Text('No records'));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final st = visible[i];
        final cards = groups[st]!;
        final color = _statusColor(st);
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ExpansionTile(
            initiallyExpanded: i < 2,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            title: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(st,
                      style:
                          TextStyle(fontWeight: FontWeight.w700, color: color)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${cards.length}',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: color,
                          fontSize: 12)),
                ),
              ],
            ),
            children: cards.map(_cardRow).toList(),
          ),
        );
      },
    );
  }

  // â”€â”€ View 3: All cards â”€â”€
  Widget _allCardsView() {
    final list = _filtered;
    if (list.isEmpty) return const Center(child: Text('No records'));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
      itemCount: list.length,
      itemBuilder: (_, i) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: _cardRow(list[i]),
      ),
    );
  }

  Widget _miniStatusChip(String label, int count) {
    final color = _statusColor(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text('$label: $count',
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _cardRow(Map<String, dynamic> card) {
    final dateMs = card['program_date'] as int?;
    final dateStr = dateMs != null
        ? DateFormat('dd MMM yyyy')
            .format(DateTime.fromMillisecondsSinceEpoch(dateMs))
        : '-';
    final st = _currentStatusLabel(card);
    final color = _statusColor(st);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1565C0).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('#${card['card_no'] ?? ''}',
            style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF1565C0),
                fontSize: 12)),
      ),
      title: Text(
        _partyName(card['party_id'] as int?).isEmpty
            ? '(No party)'
            : _partyName(card['party_id'] as int?),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Text(
        [
          if ((card['company'] ?? '').toString().isNotEmpty)
            'Co: ${card['company']}',
          if (_productName(card['product_id'] as int?).isNotEmpty)
            'Product: ${_productName(card['product_id'] as int?)}',
          if ((card['design_no'] ?? '').toString().isNotEmpty)
            'Design: ${card['design_no']}',
          if ((card['line_no'] ?? '').toString().isNotEmpty)
            'Line: ${card['line_no']}',
          'Date: $dateStr',
        ].join('  |  '),
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(st,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 11)),
      ),
    );
  }

  // â”€â”€ View: by Party â”€â”€
  Widget _byPartyView() {
    final list = _filtered;
    if (list.isEmpty) return const Center(child: Text('No records'));

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final c in list) {
      final name = _partyName(c['party_id'] as int?).isEmpty
          ? '(No party)'
          : _partyName(c['party_id'] as int?);
      groups.putIfAbsent(name, () => []).add(c);
    }
    final keys = groups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final party = keys[i];
        final cards = groups[party]!;
        final ready = cards
            .where((c) => _currentStatusLabel(c) == 'Ready to Dispatch')
            .length;
        final pending =
            cards.where((c) => _currentStatusLabel(c) == _pendingLabel).length;
        final dispatched =
            cards.where((c) => _currentStatusLabel(c) == _closedLabel).length;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            title: Row(
              children: [
                const Icon(Icons.person_pin_rounded,
                    color: Color(0xFF1565C0), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(party,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${cards.length}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1565C0),
                          fontSize: 12)),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Pending: $pending  |  Ready: $ready  |  Dispatched: $dispatched',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
            children: cards.map(_cardRow).toList(),
          ),
        );
      },
    );
  }

  // â”€â”€ View: by Date â”€â”€
  Widget _byDateView() {
    final list = _filtered;
    if (list.isEmpty) return const Center(child: Text('No records'));

    final groups = <String, List<Map<String, dynamic>>>{};
    final keyDates = <String, DateTime>{};
    for (final c in list) {
      final ms = c['program_date'] as int?;
      String key;
      DateTime keyDate;
      if (ms == null) {
        key = '-';
        keyDate = DateTime(1970);
      } else {
        final d = DateTime.fromMillisecondsSinceEpoch(ms);
        keyDate = DateTime(d.year, d.month, d.day);
        key = DateFormat('dd MMM yyyy (EEE)').format(keyDate);
      }
      groups.putIfAbsent(key, () => []).add(c);
      keyDates[key] = keyDate;
    }

    final keys = groups.keys.toList()
      ..sort((a, b) => keyDates[b]!.compareTo(keyDates[a]!));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
      itemCount: keys.length,
      itemBuilder: (_, i) {
        final key = keys[i];
        final cards = groups[key]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ExpansionTile(
            initiallyExpanded: i < 3,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            title: Row(
              children: [
                const Icon(Icons.calendar_month_rounded,
                    color: Color(0xFF1565C0), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(key,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                Text('${cards.length} cards',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
            children: cards.map(_cardRow).toList(),
          ),
        );
      },
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PDF EXPORT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Returns a friendly label for the currently active grouping tab.
  String get _activeGroupLabel {
    switch (_tab.index) {
      case 0:
        return 'Company';
      case 1:
        return 'Party';
      case 2:
        return 'Status';
      case 3:
        return 'Date';
      default:
        return 'All';
    }
  }

  /// Build {groupName -> [cards]} matching the active tab's grouping.
  /// Returns groups sorted in display order.
  List<MapEntry<String, List<Map<String, dynamic>>>> _buildPdfGroups(
      List<Map<String, dynamic>> list) {
    String key(Map<String, dynamic> c) {
      switch (_tab.index) {
        case 0:
          return (c['company'] ?? '-').toString();
        case 1:
          final n = _partyName(c['party_id'] as int?);
          return n.isEmpty ? '(No party)' : n;
        case 2:
          return _currentStatusLabel(c);
        case 3:
          final ms = c['program_date'] as int?;
          if (ms == null) return '-';
          return DateFormat('dd MMM yyyy')
              .format(DateTime.fromMillisecondsSinceEpoch(ms));
        default:
          return 'All';
      }
    }

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final c in list) {
      groups.putIfAbsent(key(c), () => []).add(c);
    }

    // Sort all cards globally by date ascending, then card_no ascending
    int cardNum(Map<String, dynamic> c) =>
        int.tryParse((c['card_no'] ?? '').toString()) ?? 0;
    int dateMs(Map<String, dynamic> c) => c['program_date'] as int? ?? 0;
    for (final entry in groups.entries) {
      entry.value.sort((a, b) {
        final cmp = dateMs(a).compareTo(dateMs(b));
        if (cmp != 0) return cmp;
        return cardNum(a).compareTo(cardNum(b));
      });
    }

    final entries = groups.entries.toList();

    if (_tab.index == 2) {
      // Status order
      final order = [
        ...ProgramCardConstants.statusFlow.map((s) => s.value),
        _closedLabel,
        _pendingLabel,
      ];
      entries
          .sort((a, b) => order.indexOf(a.key).compareTo(order.indexOf(b.key)));
    } else if (_tab.index == 3) {
      // Date asc (oldest first)
      DateTime parse(String s) {
        try {
          return DateFormat('dd MMM yyyy').parse(s);
        } catch (_) {
          return DateTime(1970);
        }
      }

      entries.sort((a, b) => parse(a.key).compareTo(parse(b.key)));
    } else {
      entries.sort((a, b) => a.key.compareTo(b.key));
    }

    return entries;
  }

  Future<void> _exportPdf() async {
    final list = _filtered;
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No records to export')),
      );
      return;
    }

    final groupLabel = _activeGroupLabel;
    final groups = _buildPdfGroups(list);
    final df = DateFormat('dd MMM yyyy');
    final genAt = DateFormat('dd MMM yyyy hh:mm a').format(DateTime.now());

    final pendingCount =
        list.where((c) => _currentStatusLabel(c) == _pendingLabel).length;
    final readyCount =
        list.where((c) => _currentStatusLabel(c) == 'Ready to Dispatch').length;
    final dispatchedCount =
        list.where((c) => _currentStatusLabel(c) == _closedLabel).length;
    final progressCount =
        list.length - pendingCount - readyCount - dispatchedCount;

    final filterParts = <String>[];
    if (_filterCompany != null) filterParts.add('Company: $_filterCompany');
    if (_filterStatus != null) filterParts.add('Status: $_filterStatus');
    if (_fromDate != null) filterParts.add('From: ${df.format(_fromDate!)}');
    if (_toDate != null) filterParts.add('To: ${df.format(_toDate!)}');
    final filterLine =
        filterParts.isEmpty ? 'All records' : filterParts.join('   |   ');

    final doc = pw.Document();
    final logoBytes =
        (await rootBundle.load('assets/mslogo.png')).buffer.asUint8List();
    final logoImage = pw.MemoryImage(logoBytes);

    pw.Widget headerRow(String label, String value, {bool bold = false}) =>
        pw.Row(children: [
          pw.Text('$label: ',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight:
                      bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ]);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Image(logoImage, width: 42, height: 42),
                pw.Text('Program Card Report',
                    style: pw.TextStyle(
                        fontSize: 18, fontWeight: pw.FontWeight.bold)),
                pw.Text('Grouped by $groupLabel',
                    style: pw.TextStyle(
                        fontSize: 12, fontWeight: pw.FontWeight.bold)),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(filterLine, style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 4),
            pw.Row(
              children: [
                headerRow('Total', '${list.length}', bold: true),
                pw.SizedBox(width: 16),
                headerRow('Pending', '$pendingCount'),
                pw.SizedBox(width: 16),
                headerRow('In Progress', '$progressCount'),
                pw.SizedBox(width: 16),
                headerRow('Ready', '$readyCount'),
                pw.SizedBox(width: 16),
                headerRow('Dispatched', '$dispatchedCount'),
              ],
            ),
            pw.Divider(),
          ],
        ),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Generated: $genAt',
                style: const pw.TextStyle(fontSize: 8)),
            pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8)),
          ],
        ),
        build: (ctx) {
          final widgets = <pw.Widget>[];

          for (final entry in groups) {
            final cards = entry.value;

            // Group sub-summary
            int groupReady = 0, groupPending = 0, groupDispatched = 0;
            for (final c in cards) {
              final st = _currentStatusLabel(c);
              if (st == 'Ready to Dispatch') groupReady++;
              if (st == _pendingLabel) groupPending++;
              if (st == _closedLabel) groupDispatched++;
            }

            widgets.add(pw.Container(
              margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const pw.BoxDecoration(
                color: PdfColors.blue50,
                borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('$groupLabel: ${entry.key}',
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  pw.Text(
                      'Cards: ${cards.length}   Pending: $groupPending   Ready: $groupReady   Dispatched: $groupDispatched',
                      style: const pw.TextStyle(fontSize: 9)),
                ],
              ),
            ));

            // Table for this group
            final tableHeaders = [
              '#',
              'Date',
              'Co.',
              'Party',
              'Product',
              'Design',
              'Card #',
              'TP',
              'Line/Miter',
              'Qty',
              'Status',
            ];
            final tableData = <List<String>>[];
            for (var i = 0; i < cards.length; i++) {
              final c = cards[i];
              final ms = c['program_date'] as int?;
              final tp = (c['tp'] as num?)?.toDouble() ?? 0;
              final lineNum =
                  double.tryParse((c['line_no'] ?? '').toString()) ?? 0;
              final qty = tp * lineNum;
              tableData.add([
                '${i + 1}',
                ms == null
                    ? '-'
                    : df.format(DateTime.fromMillisecondsSinceEpoch(ms)),
                (c['company'] ?? '').toString(),
                _partyName(c['party_id'] as int?),
                _productName(c['product_id'] as int?),
                (c['design_no'] ?? '').toString(),
                '#${(c['card_no'] ?? '').toString()}',
                tp == 0
                    ? ''
                    : tp.toStringAsFixed(tp.truncateToDouble() == tp ? 0 : 2),
                (c['line_no'] ?? '').toString(),
                qty == 0
                    ? ''
                    : qty
                        .toStringAsFixed(qty.truncateToDouble() == qty ? 0 : 2),
                _currentStatusLabel(c),
              ]);
            }

            widgets.add(pw.TableHelper.fromTextArray(
              headers: tableHeaders,
              data: tableData,
              cellAlignment: pw.Alignment.centerLeft,
              headerStyle: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.blueGrey700),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellHeight: 18,
              columnWidths: {
                0: const pw.FixedColumnWidth(22),
                1: const pw.FixedColumnWidth(70),
                2: const pw.FixedColumnWidth(50),
                3: const pw.FlexColumnWidth(1.2),
                4: const pw.FlexColumnWidth(1.1),
                5: const pw.FlexColumnWidth(1.1),
                6: const pw.FixedColumnWidth(60),
                7: const pw.FixedColumnWidth(28),
                8: const pw.FlexColumnWidth(0.7),
                9: const pw.FixedColumnWidth(34),
                10: const pw.FlexColumnWidth(1.4),
              },
              rowDecoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
                ),
              ),
              cellAlignments: {
                0: pw.Alignment.center,
                1: pw.Alignment.center,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
                6: pw.Alignment.center,
                7: pw.Alignment.center,
                8: pw.Alignment.center,
                9: pw.Alignment.center,
                10: pw.Alignment.center,
              },
            ));
          }

          return widgets;
        },
      ),
    );

    await Printing.layoutPdf(
      name: 'program_card_report_${_activeGroupLabel.toLowerCase()}.pdf',
      onLayout: (format) async => doc.save(),
    );
  }
}
