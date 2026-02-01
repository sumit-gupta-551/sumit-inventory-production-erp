import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../models/party.dart';

class PartyMasterPage extends StatefulWidget {
  const PartyMasterPage({super.key});

  @override
  State<PartyMasterPage> createState() => _PartyMasterPageState();
}

class _PartyMasterPageState extends State<PartyMasterPage> {
  final nameCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final contactCtrl = TextEditingController();

  List<Party> parties = [];
  int? editId;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _loadParties();
  }

  Future<void> _loadParties() async {
    final res = await ErpDatabase.instance.getParties();
    if (!mounted) return;
    setState(() => parties = res);
  }

  Future<void> _saveParty() async {
    if (saving) return;

    if (nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Party name is required')),
      );
      return;
    }

    setState(() => saving = true);

    final party = Party(
      id: editId,
      name: nameCtrl.text.trim(),
      address: addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),
      contact: contactCtrl.text.trim().isEmpty ? null : contactCtrl.text.trim(),
    );

    if (editId == null) {
      await ErpDatabase.instance.insertParty(party);
    } else {
      await ErpDatabase.instance.updateParty(party);
    }

    _clearForm();
    await _loadParties();

    if (!mounted) return;
    setState(() => saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(editId == null ? 'Party saved successfully' : 'Party updated'),
      ),
    );
  }

  void _editParty(Party p) {
    setState(() {
      editId = p.id;
      nameCtrl.text = p.name;
      addressCtrl.text = p.address ?? '';
      contactCtrl.text = p.contact ?? '';
    });
  }

  Future<void> _deleteParty(int id) async {
    await ErpDatabase.instance.deleteParty(id);
    await _loadParties();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Party deleted successfully')),
    );
  }

  void _clearForm() {
    editId = null;
    nameCtrl.clear();
    addressCtrl.clear();
    contactCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Party Master')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Party Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addressCtrl,
              decoration: const InputDecoration(labelText: 'Address'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: contactCtrl,
              decoration: const InputDecoration(labelText: 'Contact'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: saving ? null : _saveParty,
                child: Text(editId == null ? 'SAVE PARTY' : 'UPDATE PARTY'),
              ),
            ),
            const Divider(height: 32),
            Expanded(
              child: parties.isEmpty
                  ? const Center(child: Text('No parties added yet'))
                  : ListView.builder(
                      itemCount: parties.length,
                      itemBuilder: (_, i) {
                        final p = parties[i];
                        return Card(
                          child: ListTile(
                            title: Text(p.name),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (p.address != null)
                                  Text('Address: ${p.address}'),
                                if (p.contact != null)
                                  Text('Contact: ${p.contact}'),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  onPressed: () => _editParty(p),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete,
                                      color: Colors.red),
                                  onPressed: () => _deleteParty(p.id!),
                                ),
                              ],
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
