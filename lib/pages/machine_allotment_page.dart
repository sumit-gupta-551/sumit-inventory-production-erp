// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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
  }

  Future<void> _load() async {
    programs = await ErpDatabase.instance.getPlannedPrograms();
    machines = await ErpDatabase.instance.getMachines();
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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Program Allotted Successfully'),
        backgroundColor: Colors.green,
      ),
    );

    selectedProgramNo = null;
    selectedMachineId = null;
    await _load();
  }

  String _date(int ms) =>
      DateFormat('dd-MM-yyyy').format(DateTime.fromMillisecondsSinceEpoch(ms));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Machine Allotment')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ---------------- PROGRAM LIST ----------------
            DropdownButtonFormField<int>(
              value: selectedProgramNo,
              decoration: const InputDecoration(
                labelText: 'Select Program',
                border: OutlineInputBorder(),
              ),
              items: programs.map<DropdownMenuItem<int>>((p) {
                return DropdownMenuItem<int>(
                  value: p['program_no'] as int,
                  child: Text(
                    'P${p['program_no']} | ${p['party_name']} | ${p['fabric_shade']}',
                  ),
                );
              }).toList(),
              onChanged: (v) => setState(() => selectedProgramNo = v),
            ),

            const SizedBox(height: 12),

            // ---------------- MACHINE LIST ----------------
            DropdownButtonFormField<int>(
              value: selectedMachineId,
              decoration: const InputDecoration(
                labelText: 'Select Machine',
                border: OutlineInputBorder(),
              ),
              items: machines
                  .where((m) => m['status'] == 'IDLE')
                  .map<DropdownMenuItem<int>>((m) {
                return DropdownMenuItem<int>(
                  value: m['id'] as int,
                  child: Text(
                    '${m['machine_code']} (${m['machine_type']})',
                  ),
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

            // ---------------- PREVIEW ----------------
            Expanded(
              child: programs.isEmpty
                  ? const Center(child: Text('No planned programs'))
                  : ListView.builder(
                      itemCount: programs.length,
                      itemBuilder: (_, i) {
                        final p = programs[i];
                        return Card(
                          child: ListTile(
                            title: Text(
                              'Program ${p['program_no']}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              'Party: ${p['party_name']}\n'
                              'Fabric: ${p['fabric_shade']}\n'
                              'Qty: ${p['planned_qty']} | Date: ${_date(p['program_date'])}',
                            ),
                            trailing: Chip(
                              label: Text(p['status']),
                              backgroundColor: Colors.orange.shade100,
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
