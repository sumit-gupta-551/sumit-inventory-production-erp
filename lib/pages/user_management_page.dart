// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../data/permission_service.dart';

class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});

  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
  final _perm = PermissionService.instance;
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    if (_users.isEmpty) setState(() => _loading = true);
    final users = await _perm.getAllUsers();
    if (!mounted) return;
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  // ─── Helpers ───
  Color _roleColor(String role) {
    switch (role) {
      case 'super':
        return Colors.red;
      case 'admin':
        return Colors.green;
      default:
        return Colors.orange;
    }
  }

  IconData _roleIcon(String role) {
    switch (role) {
      case 'super':
        return Icons.shield_rounded;
      case 'admin':
        return Icons.admin_panel_settings_rounded;
      default:
        return Icons.person_rounded;
    }
  }

  // ─── Actions ───
  Future<void> _changeRole(Map<String, dynamic> user) async {
    final phone = user['phone'] as String;
    if (phone == PermissionService.superPhone) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot change Super User role')),
      );
      return;
    }

    final currentRole = (user['role'] as String?) ?? 'custom';
    final newRole = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Change Role — ${user['name'] ?? phone}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _roleOption(ctx, 'admin', 'Admin', 'Full access to all pages',
                currentRole == 'admin'),
            const SizedBox(height: 8),
            _roleOption(ctx, 'custom', 'Custom', 'Custom page permissions',
                currentRole == 'custom'),
          ],
        ),
      ),
    );

    if (newRole != null && newRole != currentRole) {
      await _perm.setUserRole(phone, newRole);
      _load();
    }
  }

  Widget _roleOption(BuildContext ctx, String value, String title,
      String subtitle, bool selected) {
    return ListTile(
      leading: Icon(_roleIcon(value), color: _roleColor(value)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing:
          selected ? const Icon(Icons.check_circle, color: Colors.green) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? Colors.green : Colors.grey.shade300,
        ),
      ),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  Future<void> _editPermissions(Map<String, dynamic> user) async {
    final phone = user['phone'] as String;
    if (phone == PermissionService.superPhone) return;

    if ((user['role'] as String?) == 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Admin has full access. Change role to Custom first.')),
      );
      return;
    }

    final existing = <String, bool>{};
    if (user['permissions'] != null) {
      final p = user['permissions'] as Map;
      for (final e in p.entries) {
        existing[e.key.toString()] = e.value == true;
      }
    }

    final result = await Navigator.push<Map<String, bool>>(
      context,
      MaterialPageRoute(
        builder: (_) => _PermissionEditorPage(
          userName: (user['name'] as String?) ?? phone,
          permissions: Map<String, bool>.from(existing),
        ),
      ),
    );

    if (result != null) {
      await _perm.setUserPermissions(phone, result);
      _load();
    }
  }

  // ─── Delete User ───
  Future<void> _deleteUser(Map<String, dynamic> user) async {
    final phone = user['phone'] as String;
    final name = (user['name'] as String?) ?? phone;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete User'),
        content: Text(
          'Are you sure you want to delete "$name" ($phone)?\n\nThis action cannot be undone.',
        ),
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

    if (confirmed != true) return;

    final error = await _perm.deleteUser(phone);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('User $name deleted'),
          backgroundColor: Colors.red,
        ),
      );
      _load();
    }
  }

  // ─── Add User ───
  Future<void> _addUser() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool obscure = true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add New User'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  prefixIcon: Icon(Icons.person_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: 'Mobile Number',
                  prefixIcon: Icon(Icons.phone_rounded),
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(obscure
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded),
                    onPressed: () => setDlg(() => obscure = !obscure),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Create'),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final name = nameCtrl.text.trim();
    final phone = phoneCtrl.text.trim();
    final pass = passCtrl.text.trim();

    if (name.isEmpty || phone.length < 10 || pass.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Enter valid name, 10-digit phone and password (min 4 chars)')),
      );
      return;
    }

    final error = await _perm.createUser(phone, name, pass);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('User $name ($phone) created successfully'),
          backgroundColor: Colors.green,
        ),
      );
      _load();
    }
  }

  // ─── UI ───
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUser,
        icon: const Icon(Icons.person_add_rounded),
        label: const Text('Add User'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
              ? const Center(child: Text('No users found'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _users.length,
                  itemBuilder: (_, i) {
                    final user = _users[i];
                    final phone = user['phone'] as String;
                    final name = (user['name'] as String?) ?? '';
                    final role = (user['role'] as String?) ?? 'custom';
                    final isSuper = phone == PermissionService.superPhone;

                    int permCount = 0;
                    if (user['permissions'] != null) {
                      final p = user['permissions'] as Map;
                      permCount = p.values.where((v) => v == true).length;
                    }

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        leading: CircleAvatar(
                          backgroundColor:
                              _roleColor(role).withValues(alpha: 0.15),
                          child: Icon(_roleIcon(role),
                              color: _roleColor(role), size: 22),
                        ),
                        title: Text(
                          name.isNotEmpty ? name : phone,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(phone,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _roleColor(role)
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    role.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: _roleColor(role),
                                    ),
                                  ),
                                ),
                                if (role == 'custom') ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '$permCount / ${PermissionService.allPermissions.length} permissions',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                        trailing: isSuper
                            ? null
                            : PopupMenuButton<String>(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                onSelected: (value) {
                                  if (value == 'role') _changeRole(user);
                                  if (value == 'permissions') {
                                    _editPermissions(user);
                                  }
                                  if (value == 'delete') {
                                    _deleteUser(user);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'role',
                                    child: Row(
                                      children: [
                                        Icon(Icons.swap_horiz_rounded,
                                            size: 18),
                                        SizedBox(width: 8),
                                        Text('Change Role'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'permissions',
                                    child: Row(
                                      children: [
                                        Icon(Icons.lock_open_rounded, size: 18),
                                        SizedBox(width: 8),
                                        Text('Edit Permissions'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_rounded,
                                            size: 18, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete User',
                                            style:
                                                TextStyle(color: Colors.red)),
                                      ],
                                    ),
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

// ═══════════════════════════════════════════════════════════════
// Sub-page: toggle individual permissions for a "custom" user
// ═══════════════════════════════════════════════════════════════
class _PermissionEditorPage extends StatefulWidget {
  final String userName;
  final Map<String, bool> permissions;

  const _PermissionEditorPage({
    required this.userName,
    required this.permissions,
  });

  @override
  State<_PermissionEditorPage> createState() => _PermissionEditorPageState();
}

class _PermissionEditorPageState extends State<_PermissionEditorPage> {
  late Map<String, bool> _perms;

  static const _categories = <String, List<String>>{
    'Modules': [
      'purchase_entry',
      'issue_entry',
      'requirement',
      'stock_adjustment',
      'history',
      'firms',
      'machine_allotment',
      'operator_live',
    ],
    'Masters': [
      'master_parties',
      'master_products',
      'master_machines',
      'master_units',
      'master_programs',
      'master_thread_shade',
      'master_fabric_shade',
      'master_delay_reasons',
    ],
    'Reports': [
      'report_stock',
      'report_purchase',
      'report_issue',
      'report_challan',
      'report_shade_movement',
      'report_daily_consumption',
    ],
    'Payroll': [
      'payroll_employee_master',
      'payroll_production_entry',
      'payroll_attendance',
      'payroll_salary',
      'payroll_advance',
      'payroll_pay_salary',
      'payroll_production_report',
      'payroll_advance_report',
    ],
    'Admin': [
      'activity_log',
      'stock_ticker',
      'sync_data',
      'update_app',
      'clear_firebase',
    ],
  };

  @override
  void initState() {
    super.initState();
    _perms = Map<String, bool>.from(widget.permissions);
  }

  void _toggleAll(bool value) {
    setState(() {
      for (final key in PermissionService.allPermissions.keys) {
        _perms[key] = value;
      }
    });
  }

  void _toggleCategory(String category, bool value) {
    setState(() {
      for (final key in _categories[category]!) {
        _perms[key] = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabledCount = _perms.values.where((v) => v).length;
    final totalCount = PermissionService.allPermissions.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('Permissions — ${widget.userName}'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _perms),
            icon: const Icon(Icons.save_rounded, color: Colors.white),
            label: const Text('Save',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Toggle bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.indigo.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$enabledCount / $totalCount enabled',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => _toggleAll(true),
                      child: const Text('Enable All',
                          style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => _toggleAll(false),
                      child: const Text('Disable All',
                          style: TextStyle(fontSize: 12, color: Colors.red)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: _categories.entries.map((cat) {
                final catKeys = cat.value;
                final catEnabled =
                    catKeys.where((k) => _perms[k] == true).length;
                final allEnabled = catEnabled == catKeys.length;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: ExpansionTile(
                    initiallyExpanded: true,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Row(
                      children: [
                        Text(cat.key,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(width: 8),
                        Text('$catEnabled/${catKeys.length}',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                    trailing: TextButton(
                      onPressed: () => _toggleCategory(cat.key, !allEnabled),
                      child: Text(allEnabled ? 'Off All' : 'On All',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    children: catKeys.map((key) {
                      final label =
                          PermissionService.allPermissions[key] ?? key;
                      return SwitchListTile(
                        dense: true,
                        title:
                            Text(label, style: const TextStyle(fontSize: 13)),
                        value: _perms[key] ?? false,
                        onChanged: (v) {
                          setState(() => _perms[key] = v);
                        },
                      );
                    }).toList(),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
