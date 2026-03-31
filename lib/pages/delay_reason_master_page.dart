import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class DelayReasonMasterPage extends StatefulWidget {
  const DelayReasonMasterPage({super.key});

  @override
  State<DelayReasonMasterPage> createState() => _DelayReasonMasterPageState();
}

class _DelayReasonMasterPageState extends State<DelayReasonMasterPage> {
  final _formKey = GlobalKey<FormState>();
  final ctrl = TextEditingController();
  final focusNode = FocusNode();

  List<Map<String, dynamic>> reasons = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    reasons = await ErpDatabase.instance.getDelayReasons();
    setState(() {});
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      await ErpDatabase.instance.insertDelayReason(ctrl.text.trim());
      ctrl.clear();
      focusNode.requestFocus();
      await _load();
    } catch (e) {
      _msg('Error saving reason');
    }
  }

  Future<void> _delete(int id) async {
    try {
      await ErpDatabase.instance.deleteDelayReason(id);
      await _load();
    } catch (e) {
      _msg('Error deleting reason');
    }
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delay Reason Master')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Form(
              key: _formKey,
              child: TextFormField(
                controller: ctrl,
                focusNode: focusNode,
                decoration: const InputDecoration(
                  labelText: 'Delay Reason',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 45,
              child: ElevatedButton(
                onPressed: _save,
                child: const Text('ADD REASON'),
              ),
            ),
            const Divider(height: 30),
            Expanded(
              child: reasons.isEmpty
                  ? const Center(child: Text('No delay reasons added yet.'))
                  : ListView.builder(
                      itemCount: reasons.length,
                      itemBuilder: (_, i) {
                        final r = reasons[i];
                        return Card(
                          child: ListTile(
                            title: Text(r['reason']),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _delete(r['id']),
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

  @override
  void dispose() {
    ctrl.dispose();
    focusNode.dispose();
    super.dispose();
  }
}
