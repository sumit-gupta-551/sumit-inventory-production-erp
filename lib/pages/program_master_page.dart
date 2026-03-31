import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/party.dart';
import 'program_preview_page.dart';

class ProgramMasterPage extends StatefulWidget {
  final int? editProgramNo;

  const ProgramMasterPage({super.key, this.editProgramNo});

  @override
  State<ProgramMasterPage> createState() => _ProgramMasterPageState();
}

class _ProgramMasterPageState extends State<ProgramMasterPage> {
  // ---------------- CONTROLLERS ----------------
  final programNoCtrl = TextEditingController();
  final dateCtrl = TextEditingController();
  final cardCtrl = TextEditingController();
  final designCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final designerCtrl = TextEditingController();
  final fabricQtyCtrl = TextEditingController();

  // ---------------- MASTER DATA ----------------
  List<Party> parties = [];
  int? selectedPartyId;

  List<Map<String, dynamic>> fabricShades = [];
  List<Map<String, dynamic>> threadShades = [];

  // ---------------- SELECTED DATA ----------------
  List<Map<String, dynamic>> selectedFabrics = [];
  List<Map<String, dynamic>> selectedThreads = [];

  int? fabricPickId;
  int? threadPickId;

  bool isEdit = false;

  @override
  void initState() {
    super.initState();
    isEdit = widget.editProgramNo != null;
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _init();
  }

  Future<void> _init() async {
    final db = ErpDatabase.instance;

    parties = await db.getParties();
    fabricShades = await db.getFabricShades();
    threadShades = await db.getThreadShades();

    if (isEdit) {
      await _loadForEdit(widget.editProgramNo!);
    } else {
      programNoCtrl.text = (await db.getNextProgramNo()).toString();
    }

    if (mounted) setState(() {});
  }

  // ---------------- LOAD EDIT DATA ----------------
  Future<void> _loadForEdit(int programNo) async {
    final db = ErpDatabase.instance;

    final p = await db.getProgramByNo(programNo);
    final f = await db.getProgramFabrics(programNo);
    final t = await db.getProgramThreads(programNo);

    programNoCtrl.text = p['program_no'].toString();
    dateCtrl.text = DateFormat('dd-MM-yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(p['program_date']));

    cardCtrl.text = p['card_no'] ?? '';
    designCtrl.text = p['design_no'] ?? '';
    designerCtrl.text = p['designer'] ?? '';

    final party = parties.cast<Party?>().firstWhere(
          (e) => e?.id == p['party_id'],
          orElse: () => null,
        );
    selectedPartyId = party?.id;

    // FABRICS (same reference objects)
    selectedFabrics = f.map((e) {
      final shade =
          fabricShades.firstWhere((s) => s['id'] == e['fabric_shade_id']);
      return {
        'shade': shade,
        'qty': e['qty'],
      };
    }).toList();

    // THREADS (same reference objects)
    selectedThreads = t.map((e) {
      return threadShades.firstWhere((s) => s['id'] == e['thread_shade_id']);
    }).toList();
  }

  int _dateMillis() =>
      DateFormat('dd-MM-yyyy').parse(dateCtrl.text).millisecondsSinceEpoch;

  // ---------------- SAVE / UPDATE ----------------
  Future<void> _saveProgram() async {
    if (selectedPartyId == null || selectedFabrics.isEmpty) {
      _msg('Party & Fabric required');
      return;
    }

    final db = ErpDatabase.instance;
    final programNo = int.parse(programNoCtrl.text);

    if (isEdit) {
      await db.deleteProgram(programNo);
    }

    await db.insertProgram({
      'program_no': programNo,
      'party_id': selectedPartyId,
      'program_date': _dateMillis(),
      'card_no': cardCtrl.text,
      'design_no': designCtrl.text,
      'designer': designerCtrl.text,
      'fabric_shade': fabricShades,
      'planned_qty': double.parse(qtyCtrl.text),
      'status': 'PLANNED',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    for (final f in selectedFabrics) {
      await db.insertProgramFabric(
        programNo,
        f['shade']['id'],
        f['qty'],
      );
    }

    for (final t in selectedThreads) {
      await db.insertProgramThreadShade(programNo, t['id']);
    }

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ProgramPreviewPage(
          programNo: programNo,
          showSavedMsg: true,
        ),
      ),
    );
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit Program' : 'Add Program')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _section('Program Details', [
              Row(
                children: [
                  Expanded(
                    child: _text(programNoCtrl, 'Program No', readOnly: true),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: _pickDate,
                      child: AbsorbPointer(child: _text(dateCtrl, 'Date')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: selectedPartyId,
                hint: const Text('Party'),
                items: parties
                    .map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => selectedPartyId = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _text(cardCtrl, 'Card No')),
                  const SizedBox(width: 8),
                  Expanded(child: _text(designCtrl, 'Design No')),
                ],
              ),
              const SizedBox(height: 8),
              _text(designerCtrl, 'Designer'),
            ]),

            // ---------------- FABRICS ----------------
            _section('Fabric Planning', [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _pickerDropdown(
                      hint: 'Fabric Shade',
                      items: fabricShades,
                      onPickId: (v) => fabricPickId = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: fabricQtyCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'Qty'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle),
                    onPressed: () {
                      if (fabricPickId != null &&
                          fabricQtyCtrl.text.isNotEmpty) {
                        final shade = fabricShades.firstWhere(
                          (s) => s['id'] == fabricPickId,
                        );
                        setState(() {
                          selectedFabrics.add({
                            'shade': shade,
                            'qty': double.parse(fabricQtyCtrl.text),
                          });
                          fabricPickId = null;
                          fabricQtyCtrl.clear();
                        });
                      }
                    },
                  ),
                ],
              ),
              ...selectedFabrics.map(
                (f) => ListTile(
                  title: Text(f['shade']['shade_no']),
                  subtitle: Text('Qty: ${f['qty']}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => selectedFabrics.remove(f)),
                  ),
                ),
              ),
            ]),

            // ---------------- THREADS ----------------
            _section('Thread Shades', [
              Row(
                children: [
                  Expanded(
                    child: _pickerDropdown(
                      hint: 'Thread Shade',
                      items: threadShades
                          .where((t) =>
                              !selectedThreads.any((s) => s['id'] == t['id']))
                          .toList(),
                      onPickId: (v) => threadPickId = v,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle),
                    onPressed: () {
                      if (threadPickId != null) {
                        final shade = threadShades.firstWhere(
                          (s) => s['id'] == threadPickId,
                        );
                        setState(() {
                          selectedThreads.add(shade);
                          threadPickId = null;
                        });
                      }
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: selectedThreads
                    .map(
                      (t) => Chip(
                        label: Text(t['shade_no']),
                        onDeleted: () =>
                            setState(() => selectedThreads.remove(t)),
                      ),
                    )
                    .toList(),
              ),
            ]),

            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 45,
              child: ElevatedButton(
                onPressed: _saveProgram,
                child: Text(isEdit ? 'UPDATE PROGRAM' : 'SAVE PROGRAM'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- HELPERS ----------------
  Widget _section(String t, List<Widget> c) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).cardColor,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ...c,
          ],
        ),
      );

  Widget _text(TextEditingController c, String h, {bool readOnly = false}) =>
      TextField(
        controller: c,
        readOnly: readOnly,
        decoration: InputDecoration(hintText: h),
      );

  // 🔒 PICKER-ONLY DROPDOWN (NO RED BOX EVER)
  Widget _pickerDropdown({
    required String hint,
    required List<Map<String, dynamic>> items,
    required void Function(int) onPickId,
  }) {
    return DropdownButtonFormField<int>(
      value: null,
      hint: Text(hint),
      items: items
          .map(
            (e) => DropdownMenuItem<int>(
              value: e['id'] as int,
              child: Text(e['shade_no'].toString()),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) onPickId(v);
      },
    );
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      dateCtrl.text = DateFormat('dd-MM-yyyy').format(d);
      setState(() {});
    }
  }

  @override
  void dispose() {
    programNoCtrl.dispose();
    dateCtrl.dispose();
    cardCtrl.dispose();
    designCtrl.dispose();
    designerCtrl.dispose();
    fabricQtyCtrl.dispose();
    super.dispose();
  }
}
