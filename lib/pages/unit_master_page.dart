import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class UnitMasterPage extends StatefulWidget {
  const UnitMasterPage({super.key});

  @override
  State<UnitMasterPage> createState() => _UnitMasterPageState();
}

class _UnitMasterPageState extends State<UnitMasterPage> {
  List<Map<String, dynamic>> units = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ErpDatabase.instance.getUnits();
      if (!mounted) return;
      setState(() {
        units = data;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final ctrl =
        TextEditingController(text: (existing?['name'] ?? '').toString());

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add Unit' : 'Edit Unit'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Unit Name *',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      _msg('Unit name is required');
      return;
    }

    if (existing == null) {
      await ErpDatabase.instance.insertUnit(name);
      _msg('Unit added');
    } else {
      await ErpDatabase.instance.updateUnit(existing['id'] as int, name);
      _msg('Unit updated');
    }
    _load();
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Unit?'),
        content: Text('Remove "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ErpDatabase.instance.deleteUnit(id);
    _msg('Deleted');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unit Master')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : units.isEmpty
              ? const Center(child: Text('No units added'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: units.length,
                  itemBuilder: (_, i) {
                    final u = units[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: ListTile(
                        leading: const Icon(Icons.factory),
                        title: Text(
                          u['name'] ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _openForm(existing: u),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 20, color: Colors.red),
                              onPressed: () => _delete(
                                  u['id'] as int, (u['name'] ?? '').toString()),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
