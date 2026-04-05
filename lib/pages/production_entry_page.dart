// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../widgets/inventory_form_card.dart';

class ProductionEntryPage extends StatefulWidget {
  const ProductionEntryPage({super.key});

  @override
  State<ProductionEntryPage> createState() => _ProductionEntryPageState();
}

class _ProductionEntryPageState extends State<ProductionEntryPage> {
  DateTime _selectedDate = DateTime.now();
  List<Map<String, dynamic>> machines = [];
  List<Map<String, dynamic>> employees = [];
  List<Map<String, dynamic>> units = [];
  List<Map<String, dynamic>> savedEntries = [];
  String? _selectedUnit;
  bool loading = true;
  bool _saving = false;

  // Current entry fields
  int? _selMachineId;
  int? _selEmployeeId;
  final _stitchCtrl = TextEditingController();
  final _bonusCtrl = TextEditingController();
  final _incentiveCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  final _machineFocusNode = FocusNode();

  // Pending items list (not yet saved)
  final List<Map<String, dynamic>> _items = [];
  int? _editingIndex;
  int? _editingSavedId; // non-null when editing a saved DB entry
  final Set<String> _expandedSavedUnits = {};

  @override
  void initState() {
    super.initState();
    _loadMasters();
  }

  @override
  void dispose() {
    _machineFocusNode.dispose();
    _stitchCtrl.dispose();
    _bonusCtrl.dispose();
    _incentiveCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMasters() async {
    try {
      final m = await ErpDatabase.instance.getMachines();
      final e = await ErpDatabase.instance.getEmployees(status: 'active');
      final u = await ErpDatabase.instance.getUnits();
      if (!mounted) return;
      setState(() {
        machines = m;
        employees = e;
        units = u;
        loading = false;
      });
      _loadSavedEntries();
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error loading data: $e');
    }
  }

  Future<void> _loadSavedEntries() async {
    try {
      final dayStart =
          DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final rows = await ErpDatabase.instance.getProductionEntries(
        fromMs: dayStart.millisecondsSinceEpoch,
        toMs: dayEnd.millisecondsSinceEpoch,
      );
      if (!mounted) return;
      setState(() => savedEntries = rows);
    } catch (e) {
      _msg('Error loading entries: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  int get _dateMs =>
      DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day)
          .millisecondsSinceEpoch;

  List<Map<String, dynamic>> get _filteredMachines {
    if (_selectedUnit == null) return machines;
    return machines
        .where((m) => (m['unit_name'] ?? '').toString() == _selectedUnit)
        .toList();
  }

  void _addItem() {
    if (_selEmployeeId == null) {
      _msg('Select an employee');
      return;
    }
    final stitch = int.tryParse(_stitchCtrl.text.trim()) ?? 0;
    final bonus = double.tryParse(_bonusCtrl.text.trim()) ?? 0;
    final incentive = double.tryParse(_incentiveCtrl.text.trim()) ?? 0;
    final item = {
      'machine_id': _selMachineId,
      'employee_id': _selEmployeeId,
      'stitch': stitch,
      'bonus': bonus,
      'incentive': incentive,
      'total_bonus': bonus + incentive,
      'remarks': _remarksCtrl.text.trim(),
    };
    setState(() {
      if (_editingIndex != null) {
        _items[_editingIndex!] = item;
        _editingIndex = null;
      } else {
        _items.add(item);
      }
    });
    _selEmployeeId = null;
    _selMachineId = null;
    _stitchCtrl.clear();
    _bonusCtrl.clear();
    _incentiveCtrl.clear();
    _remarksCtrl.clear();
    setState(() {});
    _machineFocusNode.requestFocus();
  }

  Future<void> _updateSavedItem() async {
    if (_editingSavedId == null) return;
    if (_selEmployeeId == null) {
      _msg('Select an employee');
      return;
    }
    final stitch = int.tryParse(_stitchCtrl.text.trim()) ?? 0;
    final bonus = double.tryParse(_bonusCtrl.text.trim()) ?? 0;
    final incentive = double.tryParse(_incentiveCtrl.text.trim()) ?? 0;
    final data = {
      'date': _dateMs,
      'unit_name': _selectedUnit ?? '',
      'machine_id': _selMachineId,
      'employee_id': _selEmployeeId,
      'stitch': stitch,
      'bonus': bonus,
      'incentive_bonus': incentive,
      'total_bonus': bonus + incentive,
      'remarks': _remarksCtrl.text.trim(),
    };
    try {
      await ErpDatabase.instance.updateProductionEntry(data, _editingSavedId!);
      _msg('Entry updated');
      _cancelEdit();
      _loadSavedEntries();
    } catch (e) {
      _msg('Update error: $e');
    }
  }

  void _editSaved(Map<String, dynamic> entry) {
    setState(() {
      _editingSavedId = entry['id'] as int;
      _editingIndex = null;
      _selMachineId = entry['machine_id'] as int?;
      _selEmployeeId = entry['employee_id'] as int?;
      _selectedUnit = (entry['unit_name'] ?? '').toString().isEmpty
          ? null
          : entry['unit_name'].toString();
      _stitchCtrl.text = (entry['stitch'] as num?)?.toInt() != 0
          ? entry['stitch'].toString()
          : '';
      _bonusCtrl.text = (entry['bonus'] as num?)?.toDouble() != 0
          ? entry['bonus'].toString()
          : '';
      _incentiveCtrl.text = (entry['incentive_bonus'] as num?)?.toDouble() != 0
          ? entry['incentive_bonus'].toString()
          : '';
      _remarksCtrl.text = (entry['remarks'] ?? '').toString();
    });
  }

  void _startEdit(int index) {
    final item = _items[index];
    setState(() {
      _editingIndex = index;
      _selMachineId = item['machine_id'] as int?;
      _selEmployeeId = item['employee_id'] as int?;
      _stitchCtrl.text =
          (item['stitch'] as int?) != 0 ? item['stitch'].toString() : '';
      _bonusCtrl.text = (item['bonus'] as num?)?.toDouble() != 0
          ? item['bonus'].toString()
          : '';
      _incentiveCtrl.text = (item['incentive'] as num?)?.toDouble() != 0
          ? item['incentive'].toString()
          : '';
      _remarksCtrl.text = (item['remarks'] ?? '').toString();
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingIndex = null;
      _editingSavedId = null;
      _selMachineId = null;
      _selEmployeeId = null;
      _stitchCtrl.clear();
      _bonusCtrl.clear();
      _incentiveCtrl.clear();
      _remarksCtrl.clear();
    });
  }

  void _removeItem(int index) {
    setState(() {
      if (_editingIndex == index) {
        _cancelEdit();
      } else if (_editingIndex != null && _editingIndex! > index) {
        _editingIndex = _editingIndex! - 1;
      }
      _items.removeAt(index);
    });
  }

  Future<void> _saveAll() async {
    if (_items.isEmpty) {
      _msg('Add at least one entry');
      return;
    }
    setState(() => _saving = true);
    try {
      final count = _items.length;
      for (final item in _items) {
        final data = {
          'date': _dateMs,
          'unit_name': _selectedUnit ?? '',
          'machine_id': item['machine_id'],
          'employee_id': item['employee_id'],
          'stitch': item['stitch'],
          'bonus': item['bonus'],
          'incentive_bonus': item['incentive'],
          'total_bonus': item['total_bonus'],
          'remarks': item['remarks'],
        };
        await ErpDatabase.instance.insertProductionEntry(data);
      }
      setState(() {
        _items.clear();
        _saving = false;
      });
      _msg('$count entries saved');
      _loadSavedEntries();
    } catch (e) {
      setState(() => _saving = false);
      _msg('Save error: $e');
    }
  }

  Future<void> _deleteSaved(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Entry?'),
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
    await ErpDatabase.instance.deleteProductionEntry(id);
    _msg('Deleted');
    _loadSavedEntries();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _selectedDate = d);
      _loadSavedEntries();
    }
  }

  void _prevDay() {
    setState(
        () => _selectedDate = _selectedDate.subtract(const Duration(days: 1)));
    _loadSavedEntries();
  }

  void _nextDay() {
    setState(() => _selectedDate = _selectedDate.add(const Duration(days: 1)));
    _loadSavedEntries();
  }

  String _machineName(int? id) {
    if (id == null) return '-';
    final m = machines.where((m) => m['id'] == id).firstOrNull;
    if (m == null) return '-';
    return '${m['code'] ?? ''} ${m['name'] ?? ''}'.trim();
  }

  String _empName(int? id) {
    if (id == null) return '-';
    final e = employees.where((e) => e['id'] == id).firstOrNull;
    if (e == null) return '-';
    return (e['name'] ?? '-').toString();
  }

  int get _totalStitch =>
      _items.fold(0, (s, e) => s + ((e['stitch'] as int?) ?? 0));
  double get _totalBonus => _items.fold(
      0.0, (s, e) => s + ((e['total_bonus'] as num?)?.toDouble() ?? 0));

  List<Widget> _buildGroupedSaved() {
    // Group saved entries by unit_name
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final e in savedEntries) {
      final unit = (e['unit_name'] ?? '').toString();
      final key = unit.isEmpty ? 'No Unit' : unit;
      grouped.putIfAbsent(key, () => []).add(e);
    }

    final widgets = <Widget>[];
    for (final entry in grouped.entries) {
      final unitName = entry.key;
      final items = entry.value;
      final isExpanded = _expandedSavedUnits.contains(unitName);
      final unitStitch = items.fold<int>(
          0, (s, e) => s + ((e['stitch'] as num?)?.toInt() ?? 0));
      final unitBonus = items.fold<double>(
          0, (s, e) => s + ((e['total_bonus'] as num?)?.toDouble() ?? 0));

      widgets.add(
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedSavedUnits.remove(unitName);
              } else {
                _expandedSavedUnits.add(unitName);
              }
            });
          },
          borderRadius: BorderRadius.circular(6),
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: isExpanded
                  ? const Color(0xFF2A1A0A)
                  : const Color(0xFF1F150A),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isExpanded
                    ? Colors.orange.shade800
                    : Colors.orange.shade900,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    unitName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${items.length} entries',
                  style: TextStyle(fontSize: 11, color: Color(0xFF757575)),
                ),
                const SizedBox(width: 8),
                Text(
                  'St: $unitStitch',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  'B: ${unitBonus.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.green),
                ),
              ],
            ),
          ),
        ),
      );

      if (isExpanded) {
        for (final e in items) {
          final totalB = (e['total_bonus'] as num?)?.toDouble() ?? 0;
          widgets.add(
            Card(
              color: const Color(0xFF2A1A0A),
              margin: const EdgeInsets.only(bottom: 4, left: 8),
              child: ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                title: Text(
                  '${_empName(e['employee_id'] as int?)}  |  ${_machineName(e['machine_id'] as int?)}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'St: ${e['stitch']}  |  Bonus: ${totalB.toStringAsFixed(0)}'
                  '${(e['remarks'] ?? '').toString().isNotEmpty ? '  |  ${e['remarks']}' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      iconSize: 18,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.edit_outlined, color: Colors.blue),
                      onPressed: () => _editSaved(e),
                    ),
                    IconButton(
                      iconSize: 18,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _deleteSaved(e['id'] as int),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Production Entry')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final fMachines = _filteredMachines;
    final savedCount = savedEntries.length;
    final savedTotalBonus = savedEntries.fold<double>(
        0, (s, e) => s + ((e['total_bonus'] as num?)?.toDouble() ?? 0));
    final savedTotalStitch = savedEntries.fold<int>(
        0, (s, e) => s + ((e['stitch'] as num?)?.toInt() ?? 0));

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1976D2), Color(0xFFFFFFFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Row(
          children: [
            Icon(Icons.precision_manufacturing, color: Colors.white, size: 22),
            SizedBox(width: 6),
            Text('Production Entry',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16)),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(0.85)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            children: [
              // HEADER
              InventoryFormCard(
                title: 'PRODUCTION HEADER',
                backgroundColor: const Color(0xFF0A1828),
                borderColor: const Color(0xFF1565C0),
                padding: const EdgeInsets.all(10),
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, size: 22),
                        onPressed: _prevDay,
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: _pickDate,
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 8, horizontal: 8),
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: const Color(0xFF1976D2)
                                      .withValues(alpha: 0.3)),
                              borderRadius: BorderRadius.circular(6),
                              color: const Color(0xFFFFFFFF),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.calendar_today,
                                    size: 16, color: Colors.grey),
                                const SizedBox(width: 6),
                                Text(
                                  DateFormat('dd MMM yyyy (EEEE)')
                                      .format(_selectedDate),
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, size: 22),
                        onPressed: _nextDay,
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _selectedUnit,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<String>(
                          value: null, child: Text('All Units')),
                      ...units.map((u) => DropdownMenuItem<String>(
                            value: u['name'] as String,
                            child: Text(u['name'] as String),
                          )),
                    ],
                    onChanged: (v) => setState(() {
                      _selectedUnit = v;
                      _selMachineId = null;
                    }),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    focusNode: _machineFocusNode,
                    value: _selMachineId,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Machine',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    isExpanded: true,
                    items: fMachines
                        .map((m) => DropdownMenuItem<int>(
                              value: m['id'] as int,
                              child: Text(
                                  '${m['code'] ?? ''} ${m['name'] ?? ''}'
                                      .trim()),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selMachineId = v),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    value: _selEmployeeId,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Employee *',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    isExpanded: true,
                    items: employees
                        .map((e) => DropdownMenuItem<int>(
                              value: e['id'] as int,
                              child: Text((e['name'] ?? '').toString()),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selEmployeeId = v),
                  ),
                ],
              ),

              // ENTRY DETAILS
              InventoryFormCard(
                title: 'ENTRY DETAILS',
                backgroundColor: const Color(0xFF0A2818),
                borderColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.all(10),
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _stitchCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                            decoration: InputDecoration(
                              labelText: 'Stitch',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: const Color(0xFFF5F5F5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _bonusCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                            decoration: InputDecoration(
                              labelText: 'Bonus',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: const Color(0xFFF5F5F5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _incentiveCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                            decoration: InputDecoration(
                              labelText: 'Incentive',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: const Color(0xFFF5F5F5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _remarksCtrl,
                            textCapitalization: TextCapitalization.sentences,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Remarks',
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: const Color(0xFFF5F5F5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 40,
                        width: 100,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1976D2),
                            foregroundColor: const Color(0xFFF5F5F5),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            textStyle: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          onPressed: _editingSavedId != null
                              ? _updateSavedItem
                              : _addItem,
                          icon: Icon(
                            (_editingIndex != null || _editingSavedId != null)
                                ? Icons.check
                                : Icons.add,
                            size: 18,
                          ),
                          label: Text(
                              (_editingIndex != null || _editingSavedId != null)
                                  ? 'UPDATE'
                                  : 'ADD'),
                        ),
                      ),
                    ],
                  ),
                  if (_editingIndex != null || _editingSavedId != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _cancelEdit,
                        child: const Text('Cancel edit'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  if (_items.isEmpty)
                    const Text('No items added',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF757575)))
                  else
                    ..._items.asMap().entries.map((entry) {
                      final i = entry.key;
                      final item = entry.value;
                      final stitch = (item['stitch'] as int?) ?? 0;
                      final bonus = (item['bonus'] as num?)?.toDouble() ?? 0;
                      final incentive =
                          (item['incentive'] as num?)?.toDouble() ?? 0;
                      final total = bonus + incentive;
                      return Card(
                        color: const Color(0xFF0A2818),
                        margin: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(vertical: -3),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          title: Text(
                            '${_empName(item['employee_id'] as int?)}  |  ${_machineName(item['machine_id'] as int?)}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            'St: $stitch  |  B: ${bonus.toStringAsFixed(0)}  |  I: ${incentive.toStringAsFixed(0)}  |  T: ${total.toStringAsFixed(0)}'
                            '${(item['remarks'] ?? '').toString().isNotEmpty ? '  |  ${item['remarks']}' : ''}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                iconSize: 20,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _startEdit(i),
                              ),
                              IconButton(
                                iconSize: 20,
                                constraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red),
                                onPressed: () => _removeItem(i),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),

              // SUMMARY
              InventoryFormCard(
                title: 'SUMMARY',
                backgroundColor: const Color(0xFF1A0A2A),
                borderColor: const Color(0xFF673AB7),
                padding: const EdgeInsets.all(10),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Items: ${_items.length}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Stitch: $_totalStitch',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Bonus: ${_totalBonus.toStringAsFixed(0)}',
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // SAVED ENTRIES
              if (savedCount > 0)
                InventoryFormCard(
                  title:
                      'SAVED  ${DateFormat('dd MMM').format(_selectedDate)} ($savedCount)',
                  backgroundColor: const Color(0xFF2A1A0A),
                  borderColor: const Color(0xFFFFB74D),
                  padding: const EdgeInsets.all(10),
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A1A0A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Stitch: $savedTotalStitch  |  Bonus: ${savedTotalBonus.toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                    ),
                    ..._buildGroupedSaved(),
                  ],
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: loading
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: const Color(0xFFF5F5F5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1),
                    ),
                    onPressed: _saving || _items.isEmpty ? null : _saveAll,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save),
                    label: Text(
                        _saving ? 'SAVING...' : 'SAVE ALL (${_items.length})'),
                  ),
                ),
              ),
            ),
    );
  }
}
