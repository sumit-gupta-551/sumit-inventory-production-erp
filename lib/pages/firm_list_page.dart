import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import 'add_inventory_page.dart';

class FirmListPage extends StatefulWidget {
  const FirmListPage({super.key});

  @override
  State<FirmListPage> createState() => _FirmListPageState();
}

class _FirmListPageState extends State<FirmListPage> {
  List<Map<String, dynamic>> firms = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadFirms();
  }

  // ================= LOAD FIRMS =================
  Future<void> _loadFirms() async {
    try {
      final data = await ErpDatabase.instance.getFirms();

      if (!mounted) return;

      setState(() {
        firms = data;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading firms: $e')),
      );
    }
  }

  // ================= ADD FIRM (FINAL SAFE) =================
  Future<void> _addFirmDialog() async {
    String firmName = '';

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add Firm'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Firm Name',
            ),
            onChanged: (value) {
              firmName = value.trim();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx, firmName);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    // ❌ cancelled or empty
    if (result == null || result.isEmpty) return;

    try {
      final db = await ErpDatabase.instance.database;

      // 🔍 check duplicate
      final existing = await db.query(
        'firms',
        where: 'firm_name = ?',
        whereArgs: [result],
      );

      if (existing.isNotEmpty) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Firm already exists")),
          );
        });
        return;
      }

      // ✅ insert (synced)
      await ErpDatabase.instance.insertFirmRaw({'firm_name': result});

      if (!mounted) return;

      // 🔄 refresh after dialog transition/frame settles
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadFirms();
      });
    } catch (e) {
      if (!mounted) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      });
    }
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Firm'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addFirmDialog,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : firms.isEmpty
              ? const Center(child: Text('No firms found'))
              : ListView.builder(
                  itemCount: firms.length,
                  itemBuilder: (_, i) {
                    final f = firms[i];

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.business),
                        title: Text(
                          f['firm_name'] ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AddInventoryPage(
                                firmId: f['id'] as int,
                              ),
                            ),
                          );

                          if (!mounted) return;

                          // Refresh after route transition completes.
                          await _loadFirms();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
