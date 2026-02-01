import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class MachineMasterPage extends StatefulWidget {
  const MachineMasterPage({super.key});

  @override
  State<MachineMasterPage> createState() => _MachineMasterPageState();
}

class _MachineMasterPageState extends State<MachineMasterPage> {
  final machineCodeCtrl = TextEditingController();
  final machineTypeCtrl = TextEditingController();

  List<Map<String, dynamic>> machines = [];

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    machines = await ErpDatabase.instance.getMachines();
    setState(() {});
  }

  Future<void> _saveMachine() async {
    if (machineCodeCtrl.text.trim().isEmpty ||
        machineTypeCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Machine code & type required')),
      );
      return;
    }

    await ErpDatabase.instance.insertMachine(
      machineCodeCtrl.text.trim(),
      machineTypeCtrl.text.trim(),
    );

    machineCodeCtrl.clear();
    machineTypeCtrl.clear();
    await _loadMachines();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Machine added successfully')),
    );
  }

  Future<void> _deleteMachine(int id) async {
    await ErpDatabase.instance.deleteMachine(id);
    await _loadMachines();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Machine Master')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: machineCodeCtrl,
              decoration: const InputDecoration(
                labelText: 'Machine Code',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: machineTypeCtrl,
              decoration: const InputDecoration(
                labelText: 'Machine Type (Embroidery / Cutting)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 45,
              child: ElevatedButton(
                onPressed: _saveMachine,
                child: const Text('ADD MACHINE'),
              ),
            ),
            const Divider(height: 30),
            Expanded(
              child: machines.isEmpty
                  ? const Center(child: Text('No machines added'))
                  : ListView.builder(
                      itemCount: machines.length,
                      itemBuilder: (_, i) {
                        final m = machines[i];
                        return Card(
                          child: ListTile(
                            title: Text(m['machine_code']),
                            subtitle: Text(
                              'Type: ${m['machine_type']} | Status: ${m['status']}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteMachine(m['id']),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
