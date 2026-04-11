import 'package:flutter/material.dart';
import '../data/erp_database.dart';
import '../models/party.dart';
import 'party_form_page.dart';

class PartyMasterPage extends StatefulWidget {
  const PartyMasterPage({super.key});

  @override
  State<PartyMasterPage> createState() => _PartyMasterPageState();
}

class _PartyMasterPageState extends State<PartyMasterPage> {
  List<Party> parties = [];
  List<Party> filtered = [];
  bool loading = true;
  String _selectedType = 'All'; // 'All', 'Sales', 'Purchase'
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadParties();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _loadParties();
  }

  Future<void> _loadParties() async {
    final data = await ErpDatabase.instance.getParties();

    if (!mounted) return;

    setState(() {
      parties = data;
      _applyFilters();
      loading = false;
    });
  }

  void _applyFilters() {
    final q = _searchQuery.toLowerCase();
    filtered = parties.where((p) {
      final matchesType =
          _selectedType == 'All' || p.partyType == _selectedType;
      final matchesSearch = q.isEmpty ||
          p.name.toLowerCase().contains(q) ||
          p.mobile.contains(_searchQuery);
      return matchesType && matchesSearch;
    }).toList();
  }

  void _search(String text) {
    setState(() {
      _searchQuery = text;
      _applyFilters();
    });
  }

  void _filterByType(String type) {
    setState(() {
      _selectedType = type;
      _applyFilters();
    });
  }

  Future<void> _deleteParty(Party p) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Party'),
        content: Text('Delete "${p.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await ErpDatabase.instance.deleteParty(p.id!);
    _loadParties();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Party Master'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PartyFormPage()),
          );
          _loadParties();
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Party'),
      ),
      body: Column(
        children: [
          /// SEARCH
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: _search,
              decoration: const InputDecoration(
                hintText: 'Search party...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),

          /// FILTER TABS
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _filterChip('All'),
                const SizedBox(width: 8),
                _filterChip('Sales'),
                const SizedBox(width: 8),
                _filterChip('Purchase'),
              ],
            ),
          ),
          const SizedBox(height: 8),

          /// LIST
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? const Center(child: Text('No parties found'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (_, i) => _partyTile(filtered[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _partyTile(Party p) {
    return Card(
      elevation: 1,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              p.partyType == 'Sales' ? Colors.blue.shade50 : Colors.orange.shade50,
          child: Icon(
            p.partyType == 'Sales' ? Icons.sell : Icons.shopping_cart,
            color: p.partyType == 'Sales' ? Colors.blue : Colors.orange,
          ),
        ),
        title: Text(
          p.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${p.partyType} • ${p.mobile}'),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'edit') {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PartyFormPage(party: p),
                ),
              );
              _loadParties();
            } else if (v == 'delete') {
              _deleteParty(p);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'edit',
              child: Text('Edit'),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label) {
    final isSelected = _selectedType == label;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => _filterByType(label),
      selectedColor: Colors.blue.shade100,
    );
  }
}
