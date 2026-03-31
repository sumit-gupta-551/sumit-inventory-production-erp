import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import 'add_shade_page.dart';

class ThreadShadeMasterPage extends StatefulWidget {
  const ThreadShadeMasterPage({super.key});

  @override
  State<ThreadShadeMasterPage> createState() => _ThreadShadeMasterPageState();
}

class _ThreadShadeMasterPageState extends State<ThreadShadeMasterPage> {
  List<Map<String, dynamic>> threadShades = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadThreadShades();
  }

  Future<void> _loadThreadShades() async {
    final data = await ErpDatabase.instance.getThreadShades();

    if (!mounted) return;

    setState(() {
      threadShades = data;
      loading = false;
    });
  }

  Future<void> _openAddShade() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddShadePage()),
    );

    if (!mounted) return;
    await _loadThreadShades();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread Shade Master'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Shade',
            onPressed: _openAddShade,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : threadShades.isEmpty
              ? const Center(child: Text('No thread shades found'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: threadShades.length,
                  itemBuilder: (_, i) {
                    final s = threadShades[i];

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.palette),
                        title: Text(
                          s['shade_no'] ?? '',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Company: ${s['company_name'] ?? '-'}',
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                      ),
                    );
                  },
                ),
    );
  }
}
