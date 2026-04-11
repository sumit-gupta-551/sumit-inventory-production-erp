// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import 'add_shade_page.dart';

const _shadePasscode = '0056';

class FabricShadeMasterPage extends StatefulWidget {
  const FabricShadeMasterPage({super.key});

  @override
  State<FabricShadeMasterPage> createState() => _FabricShadeMasterPageState();
}

class _FabricShadeMasterPageState extends State<FabricShadeMasterPage> {
  List<Map<String, dynamic>> fabricShades = [];
  List<Map<String, dynamic>> filteredShades = [];
  bool loading = true;
  String searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadFabricShades();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _loadFabricShades();
  }

  Future<void> _loadFabricShades() async {
    final data = await ErpDatabase.instance.getFabricShades();
    if (!mounted) return;
    setState(() {
      fabricShades = data;
      _applyFilter();
      loading = false;
    });
  }

  void _applyFilter() {
    if (searchQuery.isEmpty) {
      filteredShades = List.from(fabricShades);
    } else {
      final q = searchQuery.toLowerCase();
      filteredShades = fabricShades.where((s) {
        final shadeNo = (s['shade_no'] ?? '').toString().toLowerCase();
        final shadeName = (s['shade_name'] ?? '').toString().toLowerCase();
        return shadeNo.contains(q) || shadeName.contains(q);
      }).toList();
    }
  }

  Future<void> _openAddShade() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddShadePage()),
    );
    if (!mounted) return;
    await _loadFabricShades();
  }

  Future<bool> _verifyPasscode() async {
    final passCtrl = TextEditingController();
    final passOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Passcode'),
        content: TextField(
          controller: passCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Passcode',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );

    if (passOk != true || passCtrl.text.trim() != _shadePasscode) {
      if (passOk == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid passcode')),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _editShade(Map<String, dynamic> shade) async {
    if (!await _verifyPasscode()) return;

    final id = shade['id'] as int;
    final shadeNoCtrl =
        TextEditingController(text: shade['shade_no']?.toString() ?? '');
    final shadeNameCtrl =
        TextEditingController(text: shade['shade_name']?.toString() ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Fabric Shade'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: shadeNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Shade No',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: shadeNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Product Name',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true) return;

    final newShadeNo = shadeNoCtrl.text.trim();
    final newShadeName = shadeNameCtrl.text.trim();

    if (newShadeNo.isEmpty || newShadeName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Shade No and Product Name are required')),
      );
      return;
    }

    try {
      await ErpDatabase.instance.updateFabricShade(
        id,
        shadeNo: newShadeNo,
        shadeName: newShadeName,
        imagePath: shade['image_path']?.toString(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shade updated'),
          backgroundColor: Colors.green,
        ),
      );
      await _loadFabricShades();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  Future<void> _deleteShade(Map<String, dynamic> shade) async {
    if (!await _verifyPasscode()) return;

    final id = shade['id'] as int;
    final shadeNo = shade['shade_no'] ?? '';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Shade'),
        content: Text('Delete shade "$shadeNo"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ErpDatabase.instance.deleteFabricShade(id);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Shade deleted'),
          backgroundColor: Colors.green,
        ),
      );
      await _loadFabricShades();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fabric Shade Master'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Shade',
            onPressed: _openAddShade,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search by shade no or product name...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                    ),
                    onChanged: (v) {
                      setState(() {
                        searchQuery = v;
                        _applyFilter();
                      });
                    },
                  ),
                ),
                Expanded(
                  child: filteredShades.isEmpty
                      ? const Center(child: Text('No fabric shades found'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: filteredShades.length,
                          itemBuilder: (_, i) {
                            final s = filteredShades[i];
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: ListTile(
                                leading: const Icon(Icons.color_lens),
                                title: Text(
                                  s['shade_no']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  s['shade_name']?.toString() ?? '-',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          color: Colors.blue),
                                      tooltip: 'Edit',
                                      onPressed: () => _editShade(s),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.red),
                                      tooltip: 'Delete',
                                      onPressed: () => _deleteShade(s),
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
    );
  }
}
