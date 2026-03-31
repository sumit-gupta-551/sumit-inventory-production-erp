import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class MachineMasterPage extends StatefulWidget {
  const MachineMasterPage({super.key});

  @override
  State<MachineMasterPage> createState() => _MachineMasterPageState();
}

class _MachineMasterPageState extends State<MachineMasterPage> {
  List<Map<String, dynamic>> machines = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    final data = await ErpDatabase.instance.getMachines();

    if (!mounted) return;

    setState(() {
      machines = data;
      loading = false;
    });
  }

  void _info() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Machines can be added or edited only from Master Control',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Machine Master (Read Only)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock),
            tooltip: 'Read only',
            onPressed: _info,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : machines.isEmpty
              ? const Center(child: Text('No machines added'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: machines.length,
                  itemBuilder: (_, i) {
                    final m = machines[i];

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.precision_manufacturing),
                        title: Text(
                          m['code'] ?? '',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Name: ${m['name'] ?? ''}',
                        ),
                        trailing: const Icon(
                          Icons.lock,
                          color: Colors.grey,
                          size: 18,
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
