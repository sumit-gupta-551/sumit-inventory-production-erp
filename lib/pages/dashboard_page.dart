// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/erp_database.dart';
import '../data/firebase_sync_service.dart';
import '../data/app_updater.dart';
import 'login_page.dart';
import 'add_inventory_page.dart';
import 'party_master_page.dart';
import 'product_master_page.dart';
import 'machine_master_page.dart';
import 'program_master_page.dart';
import 'thread_shade_master_page.dart';
import 'fabric_shade_master_page.dart';
import 'delay_reason_master_page.dart';
import 'stock_summary_page.dart';
import 'stock_ledger_page.dart';
import 'stock_adjustment_page.dart';
import 'issue_inventory_page.dart';
import 'machine_allotment_page.dart';
import 'operator_live_page.dart';
import 'firm_list_page.dart';
import 'issue_report_page.dart';
import 'requirement_fabrics_page.dart';
import 'firm_inventory_history_page.dart';
import 'issue_inventory_history_page.dart';
import 'issue_challan_page.dart';
import 'shade_movement_report_page.dart';
import 'daily_consumption_report_page.dart';
import 'employee_master_page.dart';
import 'production_entry_page.dart';
import 'attendance_page.dart';
import 'salary_payroll_page.dart';
import 'employee_advance_page.dart';
import 'pay_salary_page.dart';
import 'production_report_page.dart';
import 'advance_report_page.dart';
import 'attendance_report_page.dart';
import 'unit_master_page.dart';
import 'user_management_page.dart';
import '../data/permission_service.dart';
import '../data/firebase_backup_service.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int requirementCount = 0;
  bool isOnline = false;
  final _perm = PermissionService.instance;
  List<Map<String, dynamic>> _stockItems = [];
  late ScrollController _tickerScroll;
  bool _tickerRunning = false;
  Timer? _connectivityTimer;

  bool get _hasAnyReport =>
      _perm.isAdmin ||
      PermissionService.allPermissions.keys
          .where((k) => k.startsWith('report_'))
          .any((k) => _perm.hasPermission(k));

  bool get _hasAnyPayroll =>
      _perm.isAdmin ||
      PermissionService.allPermissions.keys
          .where((k) => k.startsWith('payroll_'))
          .any((k) => _perm.hasPermission(k));

  @override
  void initState() {
    super.initState();
    _tickerScroll = ScrollController();
    _loadRequirementCount();
    _loadStockTicker();
    _checkConnectivity();
    _connectivityTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkConnectivity(),
    );
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    _connectivityTimer?.cancel();
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    _tickerScroll.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) {
      _loadRequirementCount();
      _loadStockTicker();
    }
  }

  Future<void> _checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      setState(() =>
          isOnline = result.isNotEmpty && result[0].rawAddress.isNotEmpty);
    } catch (_) {
      if (!mounted) return;
      setState(() => isOnline = false);
    }
  }

  // ================= DATA =================

  Future<void> _loadRequirementCount() async {
    final rows = await ErpDatabase.instance.getNegativeFabricRequirements();
    if (!mounted) return;
    setState(() => requirementCount = rows.length);
  }

  Future<void> _loadStockTicker() async {
    final rows = await ErpDatabase.instance.getAllStockBalances();
    if (!mounted) return;
    setState(() => _stockItems = rows);
    _startTicker();
  }

  void _startTicker() {
    if (_tickerRunning || _stockItems.isEmpty) return;
    _tickerRunning = true;
    Future.delayed(const Duration(milliseconds: 500), () => _animateTicker());
  }

  Future<void> _animateTicker() async {
    while (mounted && _tickerRunning && _tickerScroll.hasClients) {
      final maxScroll = _tickerScroll.position.maxScrollExtent;
      if (maxScroll <= 0) break;
      await _tickerScroll.animateTo(
        maxScroll,
        duration: Duration(milliseconds: (maxScroll * 30).toInt()),
        curve: Curves.linear,
      );
      if (!mounted || !_tickerScroll.hasClients) break;
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || !_tickerScroll.hasClients) break;
      _tickerScroll.jumpTo(0);
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _syncData() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await FirebaseSyncService.instance.fullSync();
      FirebaseSyncService.instance.startListening();
      await _loadRequirementCount();
      await _checkConnectivity();
    } catch (e) {
      debugPrint('Sync error: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Data updated from server'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static const _clearPasscode = '0056';

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

    if (passOk != true || passCtrl.text.trim() != _clearPasscode) {
      if (passOk == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid passcode')),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _checkAppUpdateWithPasscode() async {
    if (!await _verifyPasscode()) return;
    _checkAppUpdate();
  }

  Future<void> _checkAppUpdate() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final update = await AppUpdater.checkForUpdate();

    if (!mounted) return;
    Navigator.of(context).pop();

    if (update == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App is up to date!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final version = update['version'] as String;
    final notes = update['releaseNotes'] as String;
    final url = update['downloadUrl'] as String;

    final shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update Available — v$version'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current: v${AppUpdater.currentVersion}'),
            Text('Latest:  v$version'),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('What\'s new:',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(notes, maxLines: 10, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update Now'),
          ),
        ],
      ),
    );

    if (shouldUpdate == true && mounted) {
      await AppUpdater.downloadAndInstall(context, url, version);
    }
  }

  Future<void> _runCloudBackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFFFFFFF),
        title: const Text('Backup to Cloud',
            style: TextStyle(color: Color(0xFF1565C0))),
        content: const Text(
          'This will backup all data tables to the secondary Firebase database.\n\nNo user or permission data will be included.',
          style: TextStyle(color: Color(0xFF212121)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0)),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.cloud_upload_rounded,
                color: Color(0xFFF5F5F5)),
            label: const Text('Start Backup',
                style: TextStyle(color: Color(0xFFF5F5F5))),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Show progress dialog
    String status = 'Starting backup...';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          // Kick off backup
          Future.microtask(() async {
            final result = await FirebaseBackupService.instance.runBackup(
              onProgress: (msg) {
                if (ctx.mounted) setDlg(() => status = msg);
              },
            );

            if (!ctx.mounted) return;
            Navigator.pop(ctx);

            if (result.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Backup failed: ${result.error}'),
                  backgroundColor: Colors.red,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Backup complete! ${result.tables} tables, ${result.rows} rows'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          });

          return AlertDialog(
            backgroundColor: const Color(0xFFFFFFFF),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Color(0xFF1565C0)),
                const SizedBox(height: 16),
                Text(status, style: const TextStyle(color: Color(0xFF212121))),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _clearFirebaseData() async {
    // Step 1: Ask for passcode
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

    if (passOk != true || passCtrl.text.trim() != _clearPasscode) {
      if (passOk == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid passcode')),
        );
      }
      return;
    }

    // Step 2: Choose what to delete
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Firebase Data'),
        content: const Text('What do you want to delete?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'issue'),
            child: const Text('Issue Data'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'purchase'),
            child: const Text('Purchase Data'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, 'all'),
            child:
                const Text('All Data', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (choice == null) return;

    // Step 3: Confirm
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you sure?'),
        content: Text(
          choice == 'all'
              ? 'This will permanently delete ALL data from Firebase. All devices will be affected.'
              : 'This will permanently delete ${choice.toUpperCase()} data from Firebase. All devices will be affected.',
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

    if (confirm != true || !mounted) return;

    // Step 4: Execute delete
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final ref = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app',
      ).ref();

      final db = await ErpDatabase.instance.database;

      if (choice == 'all') {
        await ref.child('sync').remove();
        await ref.child('issues').remove();
        await ref.child('inventory').remove();
        await ref.child('purchases').remove();
        // Clear local DB tables
        for (final table in [
          'stock_ledger',
          'purchase_master',
          'purchase_items',
          'challan_requirements',
        ]) {
          await db.delete(table);
        }
      } else if (choice == 'issue') {
        await ref.child('sync/stock_ledger').remove();
        await ref.child('sync/challan_requirements').remove();
        await ref.child('sync/_counters/stock_ledger').remove();
        await ref.child('sync/_counters/challan_requirements').remove();
        await ref.child('issues').remove();
        // Clear local
        await db.delete('stock_ledger');
        await db.delete('challan_requirements');
      } else if (choice == 'purchase') {
        await ref.child('sync/purchase_master').remove();
        await ref.child('sync/purchase_items').remove();
        await ref.child('sync/_counters/purchase_master').remove();
        await ref.child('sync/_counters/purchase_items').remove();
        await ref.child('purchases').remove();
        await ref.child('inventory').remove();
        // Clear local
        await db.delete('purchase_master');
        await db.delete('purchase_items');
      }

      ErpDatabase.instance.dataVersion.value++;
    } catch (e) {
      debugPrint('Clear Firebase error: $e');
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${choice.toUpperCase()} data cleared'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ================= NAVIGATION =================

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_logged_in', false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  Future<void> _openPage(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    await _loadRequirementCount();
  }

  void _openPayrollList() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFFFFFF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        final items = <_ReportItem>[
          _ReportItem(
              'Employee Master',
              Icons.people_rounded,
              const Color(0xFF7C3AED),
              const EmployeeMasterPage(),
              'payroll_employee_master'),
          _ReportItem(
              'Production Entry',
              Icons.factory_rounded,
              const Color(0xFFE11D48),
              const ProductionEntryPage(),
              'payroll_production_entry'),
          _ReportItem(
              'Attendance',
              Icons.calendar_month_rounded,
              const Color(0xFF0EA5E9),
              const AttendancePage(),
              'payroll_attendance'),
          _ReportItem(
              'Salary / Payroll',
              Icons.account_balance_wallet_rounded,
              const Color(0xFF22C55E),
              const SalaryPayrollPage(),
              'payroll_salary'),
          _ReportItem(
              'Employee Advance',
              Icons.money_off_rounded,
              const Color(0xFFF59E0B),
              const EmployeeAdvancePage(),
              'payroll_advance'),
          _ReportItem(
              'Pay Salary',
              Icons.payments_rounded,
              const Color(0xFF6366F1),
              const PaySalaryPage(),
              'payroll_pay_salary'),
          _ReportItem(
              'Production Report',
              Icons.assessment_rounded,
              const Color(0xFF0EA5E9),
              const ProductionReportPage(),
              'payroll_production_report'),
          _ReportItem(
              'Advance Report',
              Icons.summarize_rounded,
              const Color(0xFFE11D48),
              const AdvanceReportPage(),
              'payroll_advance_report'),
          _ReportItem(
              'Attendance Report',
              Icons.fact_check_rounded,
              const Color(0xFF1565C0),
              const AttendanceReportPage(),
              'payroll_attendance'),
        ].where((r) => _perm.hasPermission(r.permKey)).toList();

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.85,
          builder: (_, scrollController) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ListView(
              controller: scrollController,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade700,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Center(
                  child: Text(
                    'Payroll Management',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1565C0),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ...items.map((r) => ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: r.color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(r.icon, color: r.color, size: 22),
                      ),
                      title: Text(r.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Color(0xFF212121),
                          )),
                      trailing: Icon(Icons.chevron_right_rounded,
                          color: Colors.grey.shade600),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      onTap: () {
                        Navigator.pop(context);
                        _openPage(r.page);
                      },
                    )),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openReportsList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFFFFFFFF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        final reports = <_ReportItem>[
          _ReportItem('Stock Report', Icons.list_alt_rounded,
              const Color(0xFF14B8A6), const StockLedgerPage(), 'report_stock'),
          _ReportItem(
              'Purchase Report',
              Icons.bar_chart_rounded,
              const Color(0xFFDAA520),
              const StockSummaryPage(),
              'report_purchase'),
          _ReportItem('Issue Report', Icons.assessment_rounded,
              const Color(0xFF8B5CF6), const IssueReportPage(), 'report_issue'),
          _ReportItem(
              'Issue Challan',
              Icons.receipt_long_rounded,
              const Color(0xFFB8860B),
              const IssueChallanPage(),
              'report_challan'),
          _ReportItem(
              'Shade Movement',
              Icons.swap_vert_rounded,
              const Color(0xFF0EA5E9),
              const ShadeMovementReportPage(),
              'report_shade_movement'),
          _ReportItem(
              'Daily Consumption',
              Icons.trending_down_rounded,
              const Color(0xFFE11D48),
              const DailyConsumptionReportPage(),
              'report_daily_consumption'),
        ].where((r) => _perm.hasPermission(r.permKey)).toList();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade700,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                'Reports',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1565C0),
                ),
              ),
              const SizedBox(height: 12),
              ...reports.map((r) => ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: r.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(r.icon, color: r.color, size: 22),
                    ),
                    title: Text(r.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Color(0xFF212121),
                        )),
                    trailing: Icon(Icons.chevron_right_rounded,
                        color: Colors.grey.shade600),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    onTap: () {
                      Navigator.pop(context);
                      _openPage(r.page);
                    },
                  )),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openQuickPurchase(BuildContext context) async {
    final firm = await _selectFirm();
    if (firm == null) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddInventoryPage(firmId: firm['id']),
      ),
    );

    await _loadRequirementCount();
  }

  Future<void> _openInventoryHistory() async {
    final mode = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Select History'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'ISSUE'),
              child: const Text('Issue')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'PURCHASE'),
              child: const Text('Purchase')),
        ],
      ),
    );

    if (mode == 'ISSUE') {
      _openPage(const IssueInventoryHistoryPage());
    } else if (mode == 'PURCHASE') {
      final firm = await _selectFirm();
      if (firm != null) {
        _openPage(FirmInventoryHistoryPage(
          firmId: firm['id'],
          firmName: firm['firm_name'],
        ));
      }
    }
  }

  Future<Map<String, dynamic>?> _selectFirm() async {
    final firms = await ErpDatabase.instance.getFirms();

    if (firms.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No firms found")),
      );
      return null;
    }

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Select Firm"),
        content: SizedBox(
          width: 300,
          child: ListView(
            shrinkWrap: true,
            children: firms
                .map((f) => ListTile(
                      title: Text(f['firm_name']),
                      onTap: () => Navigator.pop(context, f),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  // ================= UI =================

  // Premium dark palette
  static const _bgDark = Color(0xFFF5F5F5);
  static const _bgCard = Color(0xFFFFFFFF);
  static const _accent = Color(0xFF1565C0);
  static const _accentLight = Color(0xFF00BAF2);
  static const _textLight = Color(0xFF212121);
  static const _textMuted = Color(0xFF757575);

  String get _greeting => 'Welcome Back';

  String get _todayDate {
    final now = DateTime.now();
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month]} ${now.year}';
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final userName = _perm.currentName.isNotEmpty
        ? _perm.currentName.split(' ').first
        : 'User';

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F5F5), Color(0xFFE3F2FD), Color(0xFFF5F5F5)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Decorative glow orbs
            Positioned(
              top: -100,
              right: -60,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF1565C0).withValues(alpha: 0.15),
                      const Color(0xFF1565C0).withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -140,
              left: -80,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFE91E63).withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 300,
              left: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF673AB7).withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Main content
            RefreshIndicator(
              color: _accent,
              backgroundColor: _bgCard,
              onRefresh: _loadRequirementCount,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  // -------- PREMIUM APP BAR --------
                  SliverToBoxAdapter(
                    child: Container(
                      padding: EdgeInsets.fromLTRB(24, topPad + 20, 20, 28),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF1A1A2E),
                            Color(0xFF16213E),
                            Color(0xFF1A1A2E),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(36),
                          bottomRight: Radius.circular(36),
                        ),
                        border: Border(
                          bottom: BorderSide(
                            color:
                                const Color(0xFF00E5FF).withValues(alpha: 0.6),
                            width: 1.5,
                          ),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF00E5FF).withValues(alpha: 0.35),
                            blurRadius: 30,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color:
                                const Color(0xFFFF00E5).withValues(alpha: 0.15),
                            blurRadius: 40,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Top row: branding + actions
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Logo & Title
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ShaderMask(
                                      shaderCallback: (bounds) =>
                                          const LinearGradient(
                                        colors: [
                                          Color(0xFF42A5F5),
                                          Color(0xFFFF4081),
                                          Color(0xFFB388FF),
                                        ],
                                      ).createShader(bounds),
                                      child: const Text(
                                        '✩ Mayur Synthetics ✩',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w900,
                                          fontStyle: FontStyle.italic,
                                          letterSpacing: 1.0,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'ERP System  •  v${AppUpdater.currentVersion}',
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.35),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w400,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Action buttons
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_perm.hasPermission('sync_data'))
                                    _appBarIconBtn(
                                      Icons.cloud_sync_rounded,
                                      'Sync',
                                      _syncData,
                                    ),
                                  _buildPopupMenu(),
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),

                          // Greeting + Date
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$_greeting, $userName ✨',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _todayDate,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.40),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                              // Online indicator
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: (isOnline
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFFEF4444))
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: (isOnline
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFEF4444))
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isOnline
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFEF4444),
                                        boxShadow: [
                                          BoxShadow(
                                            color: (isOnline
                                                    ? const Color(0xFF10B981)
                                                    : const Color(0xFFEF4444))
                                                .withValues(alpha: 0.5),
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isOnline ? 'Online' : 'Offline',
                                      style: TextStyle(
                                        color: isOnline
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFEF4444),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // ---------- STOCK TICKER ----------
                          if (_stockItems.isNotEmpty)
                            Container(
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _accent.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          _accent.withValues(alpha: 0.15),
                                          _accent.withValues(alpha: 0.05),
                                        ],
                                      ),
                                      borderRadius: const BorderRadius.only(
                                        topLeft: Radius.circular(10),
                                        bottomLeft: Radius.circular(10),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.trending_up_rounded,
                                            color: _accent, size: 14),
                                        const SizedBox(width: 4),
                                        Text('STOCK',
                                            style: TextStyle(
                                              color: _accent,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1,
                                            )),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: ListView.builder(
                                      controller: _tickerScroll,
                                      scrollDirection: Axis.horizontal,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      itemCount: _stockItems.length,
                                      itemBuilder: (_, i) {
                                        final s = _stockItems[i];
                                        final bal =
                                            (s['balance'] as num).toDouble();
                                        final isNeg = bal < 0;
                                        final unit = s['product_unit'] ?? 'Mtr';
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12),
                                          child: Center(
                                            child: RichText(
                                              text: TextSpan(
                                                style: const TextStyle(
                                                    fontSize: 11),
                                                children: [
                                                  TextSpan(
                                                    text: '${s['shade_no']}',
                                                    style: TextStyle(
                                                      color: _accent,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  TextSpan(
                                                    text:
                                                        ' ${bal.toStringAsFixed(1)} $unit',
                                                    style: TextStyle(
                                                      color: isNeg
                                                          ? const Color(
                                                              0xFFEF4444)
                                                          : const Color(
                                                              0xFF10B981),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  TextSpan(
                                                    text:
                                                        '  (${s['product_name']})',
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.30),
                                                      fontWeight:
                                                          FontWeight.w400,
                                                    ),
                                                  ),
                                                  TextSpan(
                                                    text: '   •',
                                                    style: TextStyle(
                                                      color: _accent.withValues(
                                                          alpha: 0.3),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // -------- BODY --------
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 16),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        const _SectionTitle('Modules'),
                        const SizedBox(height: 14),
                        GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.88,
                          children: [
                            if (_perm.hasPermission('purchase_entry'))
                              _moduleCard(
                                  'Purchase\nEntry',
                                  Icons.shopping_cart_rounded,
                                  const Color(0xFFDAA520),
                                  () => _openQuickPurchase(context)),
                            if (_perm.hasPermission('issue_entry'))
                              _moduleCard(
                                  'Issue\nEntry',
                                  Icons.outbox_rounded,
                                  const Color(0xFF6366F1),
                                  () => _openPage(const IssueInventoryPage())),
                            if (_perm.hasPermission('requirement'))
                              _moduleCard(
                                  'Requirement',
                                  Icons.warning_amber_rounded,
                                  const Color(0xFFF59E0B),
                                  () =>
                                      _openPage(const RequirementFabricsPage()),
                                  badge: requirementCount),
                            if (_perm.hasPermission('stock_adjustment'))
                              _moduleCard(
                                  'Adjust',
                                  Icons.tune_rounded,
                                  const Color(0xFFEC4899),
                                  () => _openPage(const StockAdjustmentPage())),
                            if (_perm.hasPermission('history'))
                              _moduleCard(
                                  'History',
                                  Icons.history_rounded,
                                  const Color(0xFF64748B),
                                  _openInventoryHistory),
                            if (_perm.hasPermission('firms'))
                              _moduleCard(
                                  'Add Firm',
                                  Icons.domain_add_rounded,
                                  const Color(0xFFB8860B),
                                  () => _openPage(const FirmListPage())),
                            if (_hasAnyReport)
                              _moduleCard('Reports', Icons.bar_chart_rounded,
                                  const Color(0xFF14B8A6), _openReportsList),
                            if (_perm.hasPermission('machine_allotment'))
                              _moduleCard(
                                  'Machine',
                                  Icons.precision_manufacturing_rounded,
                                  const Color(0xFFEF4444),
                                  () =>
                                      _openPage(const MachineAllotmentPage())),
                            if (_perm.hasPermission('operator_live'))
                              _moduleCard(
                                  'Operator',
                                  Icons.play_circle_fill_rounded,
                                  const Color(0xFF22C55E),
                                  () => _openPage(const OperatorLivePage())),
                            if (_hasAnyPayroll)
                              _moduleCard('Payroll', Icons.payments_rounded,
                                  const Color(0xFF7C3AED), _openPayrollList),
                          ],
                        ),
                        const SizedBox(height: 28),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- APP BAR HELPERS ----------

  Widget _appBarIconBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: Colors.white70, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _buildPopupMenu() {
    return PopupMenuButton<String>(
      icon: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.menu_rounded, color: Colors.white70, size: 22),
      ),
      tooltip: 'Master',
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      color: const Color(0xFFFFFFFF),
      offset: const Offset(0, 48),
      onSelected: (value) {
        switch (value) {
          case 'firms':
            _openPage(const FirmListPage());
          case 'parties':
            _openPage(const PartyMasterPage());
          case 'products':
            _openPage(const ProductMasterPage());
          case 'machines':
            _openPage(const MachineMasterPage());
          case 'units':
            _openPage(const UnitMasterPage());
          case 'programs':
            _openPage(const ProgramMasterPage());
          case 'thread':
            _openPage(const ThreadShadeMasterPage());
          case 'fabric':
            _openPage(const FabricShadeMasterPage());
          case 'delay':
            _openPage(const DelayReasonMasterPage());
          case 'user_management':
            _openPage(const UserManagementPage());
          case 'update_app':
            _checkAppUpdateWithPasscode();
          case 'cloud_backup':
            _runCloudBackup();
          case 'clear_firebase':
            _clearFirebaseData();
          case 'logout':
            _logout();
        }
      },
      itemBuilder: (_) => [
        if (_perm.hasPermission('firms'))
          const PopupMenuItem(
              value: 'firms', child: _MenuRow(Icons.business, 'Firms')),
        if (_perm.hasPermission('master_parties'))
          const PopupMenuItem(
              value: 'parties', child: _MenuRow(Icons.people, 'Parties')),
        if (_perm.hasPermission('master_products'))
          const PopupMenuItem(
              value: 'products',
              child: _MenuRow(Icons.inventory_2, 'Products / Items')),
        if (_perm.hasPermission('master_machines'))
          const PopupMenuItem(
              value: 'machines',
              child: _MenuRow(Icons.precision_manufacturing, 'Machines')),
        if (_perm.hasPermission('master_units'))
          const PopupMenuItem(
              value: 'units', child: _MenuRow(Icons.factory, 'Units')),
        if (_perm.hasPermission('master_programs'))
          const PopupMenuItem(
              value: 'programs', child: _MenuRow(Icons.list_alt, 'Programs')),
        if (_perm.hasPermission('master_thread_shade'))
          const PopupMenuItem(
              value: 'thread', child: _MenuRow(Icons.palette, 'Thread Shade')),
        if (_perm.hasPermission('master_fabric_shade'))
          const PopupMenuItem(
              value: 'fabric',
              child: _MenuRow(Icons.color_lens, 'Fabric Shade')),
        if (_perm.hasPermission('master_delay_reasons'))
          const PopupMenuItem(
              value: 'delay',
              child: _MenuRow(Icons.timer_off, 'Delay Reasons')),
        const PopupMenuDivider(),
        if (_perm.isSuper)
          const PopupMenuItem(
              value: 'user_management',
              child: _MenuRow(
                  Icons.admin_panel_settings_rounded, 'User Management')),
        if (_perm.isSuper)
          const PopupMenuItem(
              value: 'cloud_backup',
              child: _MenuRow(Icons.cloud_upload_rounded, 'Backup to Cloud')),
        if (_perm.hasPermission('update_app'))
          const PopupMenuItem(
              value: 'update_app',
              child: _MenuRow(Icons.system_update_rounded, 'Update App')),
        if (_perm.hasPermission('clear_firebase'))
          const PopupMenuItem(
              value: 'clear_firebase',
              child: _MenuRow(
                  Icons.delete_forever_rounded, 'Clear Firebase Data')),
        const PopupMenuDivider(),
        const PopupMenuItem(
            value: 'logout', child: _MenuRow(Icons.logout_rounded, 'Logout')),
      ],
    );
  }

  // ================= WIDGETS =================

  Widget _premiumStatCard(
      String label, String value, IconData icon, Color color, Color bgTint) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              bgTint.withValues(alpha: 0.25),
              bgTint.withValues(alpha: 0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.15)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.2),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    )),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.50),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _moduleCard(
      String title, IconData icon, Color color, VoidCallback onTap,
      {int badge = 0}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFFFFFFF),
              const Color(0xFFFFFFFF),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: color.withValues(alpha: 0.12),
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.06),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Accent glow
            Positioned(
              top: -15,
              right: -15,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      color.withValues(alpha: 0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Bottom accent line
            Positioned(
              bottom: 0,
              left: 16,
              right: 16,
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      color.withValues(alpha: 0.3),
                      Colors.transparent,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color.withValues(alpha: 0.18),
                            color.withValues(alpha: 0.06),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: color.withValues(alpha: 0.10)),
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: 0.12),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Icon(icon, color: color, size: 26),
                    ),
                    const SizedBox(height: 10),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 11.5,
                          color: _textLight,
                          height: 1.3,
                        )),
                  ],
                ),
              ),
            ),
            if (badge > 0)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Text('$badge',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      )),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReportItem {
  final String title;
  final IconData icon;
  final Color color;
  final Widget page;
  final String permKey;
  const _ReportItem(this.title, this.icon, this.color, this.page, this.permKey);
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 22,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF673AB7)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          text,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF212121),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1565C0).withValues(alpha: 0.2),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF1565C0)),
        const SizedBox(width: 12),
        Text(label,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: Color(0xFF212121),
            )),
      ],
    );
  }
}
