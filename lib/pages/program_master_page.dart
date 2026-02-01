import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/party.dart';

class ProgramMasterPage extends StatefulWidget {
  const ProgramMasterPage({super.key});

  @override
  State<ProgramMasterPage> createState() => _ProgramMasterPageState();
}

class _ProgramMasterPageState extends State<ProgramMasterPage> {
  final dateCtrl = TextEditingController();
  final cardCtrl = TextEditingController();
  final designCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final designerCtrl = TextEditingController();

  List<Party> parties = [];
  List<Map<String, dynamic>> threadShades = [];

  Party? selectedParty;
  String fabricShade = '';
  final Set<String> selectedThreadShades = {};

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _load();
  }

  Future<void> _load() async {
    parties = await ErpDatabase.instance.getParties();
    threadShades = await ErpDatabase.instance.getThreadShades();
    setState(() {});
  }

  int _dateMillis() =>
      DateFormat('dd-MM-yyyy').parse(dateCtrl.text).millisecondsSinceEpoch;

  Future<void> _saveProgram() async {
    if (selectedParty == null ||
        cardCtrl.text.isEmpty ||
        designCtrl.text.isEmpty ||
        designerCtrl.text.isEmpty ||
        qtyCtrl.text.isEmpty ||
        fabricShade.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all fields')),
      );
      return;
    }

    final programNo = await ErpDatabase.instance.getNextProgramNo();

    await ErpDatabase.instance.insertProgram({
      'program_no': programNo,
      'program_date': _dateMillis(),
      'party_id': selectedParty!.id,
      'card_no': cardCtrl.text,
      'design_no': designCtrl.text,
      'designer': designerCtrl.text,
      'fabric_shade': fabricShade,
      'planned_qty': double.parse(qtyCtrl.text),
      'status': 'PLANNED',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    for (final s in selectedThreadShades) {
      await ErpDatabase.instance.insertProgramThreadShade(
        programNo,
        s,
      );
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Program Saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Program Master')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: dateCtrl,
              readOnly: true,
              decoration: const InputDecoration(labelText: 'Program Date'),
            ),
            DropdownButtonFormField<Party>(
              value: selectedParty,
              decoration: const InputDecoration(labelText: 'Party'),
              items: parties
                  .map((p) => DropdownMenuItem(
                        value: p,
                        child: Text(p.name),
                      ))
                  .toList(),
              onChanged: (v) => selectedParty = v,
            ),
            TextField(
              controller: cardCtrl,
              decoration: const InputDecoration(labelText: 'Card No'),
            ),
            TextField(
              controller: designCtrl,
              decoration: const InputDecoration(labelText: 'Design No'),
            ),
            TextField(
              controller: designerCtrl,
              decoration: const InputDecoration(labelText: 'Designer'),
            ),
            TextField(
              onChanged: (v) => fabricShade = v,
              decoration: const InputDecoration(labelText: 'Fabric Shade'),
            ),
            TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Planned Qty'),
            ),
            const SizedBox(height: 20),
            const Text('Thread Shades'),
            ...threadShades.map((s) => CheckboxListTile(
                  title: Text(s['shade_name']),
                  value: selectedThreadShades.contains(s['shade_name']),
                  onChanged: (v) {
                    setState(() {
                      v == true
                          ? selectedThreadShades.add(s['shade_name'])
                          : selectedThreadShades.remove(s['shade_name']);
                    });
                  },
                )),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveProgram,
              child: const Text('SAVE PROGRAM'),
            ),
          ],
        ),
      ),
    );
  }
}
