import 'package:flutter/material.dart';
import '../data/erp_database.dart';

class MachineMasterPage extends StatefulWidget {
  const MachineMasterPage({super.key});

  @override
  State<MachineMasterPage> createState() => _MachineMasterPageState();
}

class _MachineMasterPageState extends State<MachineMasterPage> {
  List<Map<String, dynamic>> machines = [];
  List<Map<String, dynamic>> units = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadMachines();
  }

  Future<void> _loadMachines() async {
    try {
      final data = await ErpDatabase.instance.getMachines();
      final u = await ErpDatabase.instance.getUnits();
      if (!mounted) return;
      setState(() {
        machines = data;
        units = u;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _MachineFormPage(
          existing: existing,
          units: units,
        ),
      ),
    );
    if (result == true) _loadMachines();
  }

  Future<void> _delete(int id, String code) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Machine?'),
        content: Text('Remove "$code"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ErpDatabase.instance.deleteMachine(id);
    _msg('Deleted');
    _loadMachines();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Machine Master'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
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
                          '${m['code'] ?? ''} ${m['name'] ?? ''}'.trim(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          'Unit: ${m['unit_name'] ?? '-'}  •  Status: ${m['status'] ?? 'active'}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _openForm(existing: m),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 20, color: Colors.red),
                              onPressed: () => _delete(
                                  m['id'] as int, (m['code'] ?? '').toString()),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Machine Add/Edit — full page (fixes keyboard issues)
// ═══════════════════════════════════════════════════════════════════

class _MachineFormPage extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> units;

  const _MachineFormPage({this.existing, required this.units});

  @override
  State<_MachineFormPage> createState() => _MachineFormPageState();
}

class _MachineFormPageState extends State<_MachineFormPage> {
  late TextEditingController _codeCtrl;
  late TextEditingController _nameCtrl;
  String? _selectedUnit;
  String _status = 'active';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _codeCtrl = TextEditingController(
        text: (widget.existing?['code'] ?? '').toString());
    _nameCtrl = TextEditingController(
        text: (widget.existing?['name'] ?? '').toString());
    _selectedUnit = (widget.existing?['unit_name'] ?? '').toString();
    if (_selectedUnit!.isEmpty) _selectedUnit = null;
    _status = (widget.existing?['status'] ?? 'active').toString();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Machine code required')));
      return;
    }

    setState(() => _saving = true);
    try {
      final data = {
        'code': code,
        'name': _nameCtrl.text.trim(),
        'unit_name': _selectedUnit ?? '',
        'status': _status,
      };

      if (widget.existing == null) {
        await ErpDatabase.instance.insertMachine(data);
      } else {
        await ErpDatabase.instance
            .updateMachine(data, widget.existing!['id'] as int);
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add Machine' : 'Edit Machine'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(
                labelText: 'Machine Code *',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Machine Name',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _selectedUnit,
              decoration: const InputDecoration(
                labelText: 'Unit Name',
                border: OutlineInputBorder(),
              ),
              isExpanded: true,
              items: widget.units
                  .map((u) => DropdownMenuItem<String>(
                        value: u['name'] as String,
                        child: Text(u['name'] as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedUnit = v),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _status = v);
                },
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save),
                label: Text(
                  _saving ? 'Saving...' : 'Save Machine',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
