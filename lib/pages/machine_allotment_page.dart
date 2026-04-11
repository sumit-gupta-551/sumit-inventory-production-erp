import 'package:flutter/material.dart';

import '../data/erp_database.dart';

class MachineAllotmentPage extends StatefulWidget {
  const MachineAllotmentPage({super.key});

  @override
  State<MachineAllotmentPage> createState() => _MachineAllotmentPageState();
}

class _MachineAllotmentPageState extends State<MachineAllotmentPage> {
  List<Map<String, dynamic>> programs = [];
  List<Map<String, dynamic>> machines = [];

  int? selectedProgramNo;
  int? selectedMachineId;

  @override
  void initState() {
    super.initState();
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    programs = await ErpDatabase.instance.getPlannedPrograms();
    machines = await ErpDatabase.instance.getMachines();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _allot() async {
    if (selectedProgramNo == null || selectedMachineId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select Program & Machine')),
      );
      return;
    }

    await ErpDatabase.instance.allotMachine(
      programNo: selectedProgramNo!,
      machineId: selectedMachineId!,
    );

    // ignore: use_build_context_synchronously
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Machine Allotted Successfully'),
        backgroundColor: Colors.green,
      ),
    );

    selectedProgramNo = null;
    selectedMachineId = null;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Machine Allotment')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // -------- PROGRAM ----------
            DropdownButtonFormField<int>(
              value: selectedProgramNo,
              decoration: const InputDecoration(
                labelText: 'Select Program',
                border: OutlineInputBorder(),
              ),
              items: programs.map((p) {
                return DropdownMenuItem<int>(
                  value: p['program_no'],
                  child: Text('Program ${p['program_no']}'),
                );
              }).toList(),
              onChanged: (v) => setState(() => selectedProgramNo = v),
            ),

            const SizedBox(height: 12),

            // -------- MACHINE ----------
            DropdownButtonFormField<int>(
              value: selectedMachineId,
              decoration: const InputDecoration(
                labelText: 'Select Machine',
                border: OutlineInputBorder(),
              ),
              items: machines.map((m) {
                return DropdownMenuItem<int>(
                  value: m['id'],
                  child: Text('${m['code']} - ${m['name']}'),
                );
              }).toList(),
              onChanged: (v) => setState(() => selectedMachineId = v),
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.link),
                label: const Text(
                  'ALLOT MACHINE',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: _allot,
              ),
            ),

            const Divider(height: 30),

            // -------- ALLOTMENTS ----------
            Expanded(
              child: programs.isEmpty
                  ? const Center(child: Text('No planned programs'))
                  : ListView.builder(
                      itemCount: programs.length,
                      itemBuilder: (_, i) {
                        final p = programs[i];
                        return Card(
                          child: ListTile(
                            title: Text('Program ${p['program_no']}'),
                            subtitle:
                                Text('Status: ${p['status'] ?? 'PLANNED'}'),
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
