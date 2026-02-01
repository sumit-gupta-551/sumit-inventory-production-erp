import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class DelayReasonMasterPage extends StatefulWidget {
  const DelayReasonMasterPage({super.key});

  @override
  State<DelayReasonMasterPage> createState() => _DelayReasonMasterPageState();
}

class _DelayReasonMasterPageState extends State<DelayReasonMasterPage> {
  final ctrl = TextEditingController();
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
    if (ctrl.text.trim().isEmpty) return;
    await ErpDatabase.instance.insertDelayReason(ctrl.text.trim());
    ctrl.clear();
    _load();
  }

  Future<void> _delete(int id) async {
    await ErpDatabase.instance.deleteDelayReason(id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delay Reason Master')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Delay Reason',
                border: OutlineInputBorder(),
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
              child: ListView.builder(
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
}
