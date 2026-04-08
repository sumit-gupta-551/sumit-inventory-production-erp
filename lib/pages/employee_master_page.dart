// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';

class EmployeeMasterPage extends StatefulWidget {
  const EmployeeMasterPage({super.key});

  @override
  State<EmployeeMasterPage> createState() => _EmployeeMasterPageState();
}

class _EmployeeMasterPageState extends State<EmployeeMasterPage> {
  List<Map<String, dynamic>> employees = [];
  List<Map<String, dynamic>> units = [];
  List<String> designations = [];
  bool loading = true;
  String filterStatus = 'active';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ErpDatabase.instance
          .getEmployees(status: filterStatus == 'all' ? null : filterStatus);
      final u = await ErpDatabase.instance.getUnits();
      if (!mounted) return;
      // Collect distinct designations from employees
      final allEmps = await ErpDatabase.instance.getEmployees();
      if (!mounted) return;
      final desigSet = <String>{};
      for (final e in allEmps) {
        final d = (e['designation'] ?? '').toString().trim();
        if (d.isNotEmpty) desigSet.add(d);
      }
      setState(() {
        employees = rows;
        units = u;
        designations = desigSet.toList()..sort();
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      _msg('Error loading employees: $e');
    }
  }

  void _msg(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final nameCtrl =
        TextEditingController(text: (existing?['name'] ?? '').toString());
    final mobileCtrl =
        TextEditingController(text: (existing?['mobile'] ?? '').toString());
    final designationCtrl = TextEditingController(
        text: (existing?['designation'] ?? '').toString());
    String? selectedUnit = (existing?['unit_name'] ?? '').toString();
    if (selectedUnit.isEmpty) selectedUnit = null;
    final basePayCtrl = TextEditingController(
        text: (existing?['base_pay'] as num?)?.toString() ?? '');
    final baseDaysCtrl = TextEditingController(
        text: ((existing?['salary_base_days'] as num?)?.toInt() ?? 30)
            .toString());

    String salaryType = (existing?['salary_type'] ?? 'monthly').toString();
    String status = (existing?['status'] ?? 'active').toString();
    DateTime? joinDate;
    final jd = existing?['join_date'] as int?;
    if (jd != null) joinDate = DateTime.fromMillisecondsSinceEpoch(jd);
    DateTime effectiveSalaryDate = DateTime.now();

    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDState) {
            return AlertDialog(
              title: Text(existing == null ? 'Add Employee' : 'Edit Employee'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name *',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: mobileCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Mobile',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Autocomplete<String>(
                      initialValue: designationCtrl.value,
                      optionsBuilder: (textEditingValue) {
                        if (textEditingValue.text.isEmpty) {
                          return designations;
                        }
                        return designations.where((d) => d
                            .toLowerCase()
                            .contains(textEditingValue.text.toLowerCase()));
                      },
                      onSelected: (val) {
                        designationCtrl.text = val;
                      },
                      fieldViewBuilder:
                          (context, controller, focusNode, onFieldSubmitted) {
                        // Sync with our controller
                        controller.text = designationCtrl.text;
                        controller.addListener(() {
                          designationCtrl.text = controller.text;
                        });
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: const InputDecoration(
                            labelText: 'Designation',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.arrow_drop_down, size: 20),
                          ),
                          textCapitalization: TextCapitalization.words,
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedUnit,
                      decoration: const InputDecoration(
                        labelText: 'Unit Name',
                        border: OutlineInputBorder(),
                      ),
                      isExpanded: true,
                      items: units
                          .map((u) => DropdownMenuItem<String>(
                                value: u['name'] as String,
                                child: Text(u['name'] as String),
                              ))
                          .toList(),
                      onChanged: (v) => setDState(() => selectedUnit = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: salaryType,
                      decoration: const InputDecoration(
                        labelText: 'Salary Type',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'monthly', child: Text('Monthly')),
                        DropdownMenuItem(
                            value: 'daily', child: Text('Daily Wage')),
                      ],
                      onChanged: (v) {
                        if (v != null) setDState(() => salaryType = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: basePayCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: salaryType == 'monthly'
                            ? 'Monthly Salary (₹)'
                            : 'Daily Rate (₹)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (salaryType == 'monthly') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: baseDaysCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Base Days (e.g. 26, 30)',
                          border: OutlineInputBorder(),
                          hintText: '30',
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: ctx,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                          initialDate: effectiveSalaryDate,
                        );
                        if (d != null) setDState(() => effectiveSalaryDate = d);
                      },
                      icon: const Icon(Icons.event_rounded),
                      label: Text(
                          'Effective Salary: ${DateFormat('dd-MM-yyyy').format(effectiveSalaryDate)}'),
                    ),
                    if (existing == null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: ctx,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                            initialDate: joinDate ?? DateTime.now(),
                          );
                          if (d != null) setDState(() => joinDate = d);
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: Text(joinDate == null
                            ? 'Join Date (optional)'
                            : 'Joined: ${DateFormat('dd-MM-yyyy').format(joinDate!)}'),
                      ),
                    ],
                    if (existing != null) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: status,
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'active', child: Text('Active')),
                          DropdownMenuItem(
                              value: 'inactive', child: Text('Inactive')),
                        ],
                        onChanged: (v) {
                          if (v != null) setDState(() => status = v);
                        },
                      ),
                    ],
                  ],
                ),
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
            );
          },
        );
      },
    );

    if (saved != true) return;

    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      _msg('Name is required');
      return;
    }

    final data = {
      'name': name,
      'mobile': mobileCtrl.text.trim(),
      'designation': designationCtrl.text.trim(),
      'unit_name': selectedUnit ?? '',
      'salary_type': salaryType,
      'base_pay': double.tryParse(basePayCtrl.text.trim()) ?? 0,
      'salary_base_days': int.tryParse(baseDaysCtrl.text.trim()) ?? 30,
      'join_date': joinDate?.millisecondsSinceEpoch,
      'status': status,
    };

    if (existing == null) {
      try {
        final empId = await ErpDatabase.instance.insertEmployee(data);
        // Create initial salary history record
        await ErpDatabase.instance.insertSalaryHistory({
          'employee_id': empId,
          'base_pay': data['base_pay'],
          'salary_type': data['salary_type'],
          'salary_base_days': data['salary_base_days'],
          'effective_from': effectiveSalaryDate.millisecondsSinceEpoch,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
        _msg('Employee added (id: $empId)');
      } catch (e, st) {
        debugPrint('Employee save error: $e\n$st');
        _msg('Error: $e');
        return;
      }
    } else {
      try {
        await ErpDatabase.instance.updateEmployee(
          data,
          existing['id'] as int,
          effectiveFrom: effectiveSalaryDate,
        );
        _msg('Employee updated');
      } catch (e) {
        _msg('Error updating employee: $e');
        return;
      }
    }

    _load();
  }

  Future<void> _openSalaryUpdate(Map<String, dynamic> emp) async {
    final empId = emp['id'] as int;
    final empName = (emp['name'] ?? '').toString();
    final currentPay = (emp['base_pay'] as num?)?.toDouble() ?? 0;
    final currentType = (emp['salary_type'] ?? 'monthly').toString();
    final currentBaseDays = (emp['salary_base_days'] as num?)?.toInt() ?? 30;

    final newPayCtrl =
        TextEditingController(text: currentPay.toStringAsFixed(0));
    final newBaseDaysCtrl =
        TextEditingController(text: currentBaseDays.toString());
    String newSalaryType = currentType;
    DateTime effectiveFrom = DateTime.now();

    // Load existing salary history
    List<Map<String, dynamic>> history =
        await ErpDatabase.instance.getEmployeeSalaryHistory(empId);

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDState) {
            return AlertDialog(
              title: Text('Salary Update - $empName'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline,
                                size: 16, color: Colors.blue),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Current: ₹${currentPay.toStringAsFixed(0)} / $currentType ($currentBaseDays days)',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('New Salary',
                          style: TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: newSalaryType,
                        decoration: const InputDecoration(
                          labelText: 'Salary Type',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'monthly', child: Text('Monthly')),
                          DropdownMenuItem(
                              value: 'daily', child: Text('Daily Wage')),
                        ],
                        onChanged: (v) {
                          if (v != null) setDState(() => newSalaryType = v);
                        },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: newPayCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: newSalaryType == 'monthly'
                              ? 'Monthly Salary (₹)'
                              : 'Daily Rate (₹)',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      if (newSalaryType == 'monthly') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: newBaseDaysCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Base Days',
                            border: OutlineInputBorder(),
                            isDense: true,
                            hintText: '30',
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: ctx,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                            initialDate: effectiveFrom,
                          );
                          if (d != null) setDState(() => effectiveFrom = d);
                        },
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                          'Effective From: ${DateFormat('dd-MM-yyyy').format(effectiveFrom)}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async {
                            final newPay =
                                double.tryParse(newPayCtrl.text.trim()) ?? 0;
                            final newDays =
                                int.tryParse(newBaseDaysCtrl.text.trim()) ?? 30;
                            final effMs = DateTime(
                              effectiveFrom.year,
                              effectiveFrom.month,
                              effectiveFrom.day,
                            ).millisecondsSinceEpoch;

                            // Insert history record
                            await ErpDatabase.instance.insertSalaryHistory({
                              'employee_id': empId,
                              'base_pay': newPay,
                              'salary_type': newSalaryType,
                              'salary_base_days': newDays,
                              'effective_from': effMs,
                              'created_at':
                                  DateTime.now().millisecondsSinceEpoch,
                            });

                            // Update current employee record
                            // Skip auto-history since we just inserted it above
                            await ErpDatabase.instance.updateEmployeeRaw({
                              'base_pay': newPay,
                              'salary_type': newSalaryType,
                              'salary_base_days': newDays,
                            }, empId);

                            // Reload history
                            history = await ErpDatabase.instance
                                .getEmployeeSalaryHistory(empId);
                            setDState(() {});

                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('Salary updated')),
                              );
                            }
                          },
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('UPDATE SALARY'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (history.isNotEmpty) ...[
                        const Divider(),
                        const Text('Salary History',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13)),
                        const SizedBox(height: 4),
                        ...history.map((h) {
                          final pay = (h['base_pay'] as num?)?.toDouble() ?? 0;
                          final type =
                              (h['salary_type'] ?? 'monthly').toString();
                          final days =
                              (h['salary_base_days'] as num?)?.toInt() ?? 30;
                          final effMs = (h['effective_from'] as int?) ?? 0;
                          final effDate =
                              DateTime.fromMillisecondsSinceEpoch(effMs);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '₹${pay.toStringAsFixed(0)} / $type${type == 'monthly' ? ' ($days days)' : ''}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                Text(
                                  DateFormat('dd-MM-yyyy').format(effDate),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600),
                                ),
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: () async {
                                    await ErpDatabase.instance
                                        .deleteSalaryHistory(h['id'] as int);
                                    history = await ErpDatabase.instance
                                        .getEmployeeSalaryHistory(empId);
                                    setDState(() {});
                                  },
                                  child: const Icon(Icons.close,
                                      size: 16, color: Colors.red),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
    _load();
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Employee?'),
        content: Text('Remove "$name"?'),
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
    await ErpDatabase.instance.deleteEmployee(id);
    _msg('Deleted');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Employee Master'),
        actions: [
          PopupMenuButton<String>(
            initialValue: filterStatus,
            onSelected: (v) {
              setState(() => filterStatus = v);
              _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'active', child: Text('Active')),
              PopupMenuItem(value: 'inactive', child: Text('Inactive')),
              PopupMenuItem(value: 'all', child: Text('All')),
            ],
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter Status',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : employees.isEmpty
              ? const Center(child: Text('No employees found'))
              : ListView.builder(
                  itemCount: employees.length,
                  itemBuilder: (context, i) {
                    final e = employees[i];
                    final salaryType =
                        (e['salary_type'] ?? 'monthly').toString();
                    final basePay = (e['base_pay'] as num?)?.toDouble() ?? 0;
                    final baseDays =
                        (e['salary_base_days'] as num?)?.toInt() ?? 30;
                    final payLabel = salaryType == 'monthly'
                        ? '₹${basePay.toStringAsFixed(0)}/month ($baseDays days)'
                        : '₹${basePay.toStringAsFixed(0)}/day';

                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: e['status'] == 'active'
                              ? Colors.green.shade100
                              : Colors.grey.shade200,
                          child: Text(
                            (e['name'] ?? '?')
                                .toString()
                                .substring(0, 1)
                                .toUpperCase(),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: e['status'] == 'active'
                                  ? Colors.green.shade800
                                  : Colors.grey,
                            ),
                          ),
                        ),
                        title: Text((e['name'] ?? '').toString(),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          '${(e['designation'] ?? '-')}  •  ${(e['unit_name'] ?? '-')}  •  $payLabel',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.currency_rupee,
                                  size: 20, color: Colors.green),
                              tooltip: 'Salary Update',
                              onPressed: () => _openSalaryUpdate(e),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              onPressed: () => _openForm(existing: e),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  size: 20, color: Colors.red),
                              onPressed: () => _delete(
                                  e['id'] as int, (e['name'] ?? '').toString()),
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
