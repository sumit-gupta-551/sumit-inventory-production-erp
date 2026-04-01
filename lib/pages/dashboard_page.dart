// ignore_for_file: use_build_context_synchronously

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

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int requirementCount = 0;
  bool isOnline = false;

  @override
  void initState() {
    super.initState();
    _loadRequirementCount();
    _checkConnectivity();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) _loadRequirementCount();
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
              const Text('What\'s new:', style: TextStyle(fontWeight: FontWeight.w700)),
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
        content: Text('${choice!.toUpperCase()} data cleared'),
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

  // Gold/cream palette matching login page
  static const _gold = Color(0xFFDAA520);
  static const _goldDark = Color(0xFFB8860B);
  static const _textDark = Color(0xFF1E293B);
  static const _textMuted = Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFFFEFC), Color(0xFFFFF8EE), Color(0xFFFFF1DB)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // Decorative circles (matching login)
            Positioned(
              top: -80,
              right: -60,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFFFD700).withValues(alpha: 0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -80,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFFDAA520).withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Main content
            RefreshIndicator(
              color: _goldDark,
              onRefresh: _loadRequirementCount,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  // -------- APP BAR --------
                  SliverToBoxAdapter(
                    child: Container(
                      padding: EdgeInsets.fromLTRB(20, topPad + 18, 20, 28),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFB8860B), Color(0xFFDAA520)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(32),
                          bottomRight: Radius.circular(32),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'SJ ⟡ ERP',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2,
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: _syncData,
                                    icon: const Icon(
                                        Icons.cloud_download_rounded,
                                        color: Colors.white70,
                                        size: 26),
                                    tooltip: 'Sync Data',
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.menu_rounded,
                                        color: Colors.white70, size: 26),
                                    tooltip: 'Master',
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    color: const Color(0xFFFFFBF0),
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
                                        case 'programs':
                                          _openPage(
                                              const ProgramMasterPage());
                                        case 'thread':
                                          _openPage(
                                              const ThreadShadeMasterPage());
                                        case 'fabric':
                                          _openPage(
                                              const FabricShadeMasterPage());
                                        case 'delay':
                                          _openPage(
                                              const DelayReasonMasterPage());
                                        case 'update_app':
                                          _checkAppUpdateWithPasscode();
                                        case 'clear_firebase':
                                          _clearFirebaseData();
                                        case 'logout':
                                          _logout();
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                          value: 'firms',
                                          child: _MenuRow(
                                              Icons.business, 'Firms')),
                                      PopupMenuItem(
                                          value: 'parties',
                                          child: _MenuRow(
                                              Icons.people, 'Parties')),
                                      PopupMenuItem(
                                          value: 'products',
                                          child: _MenuRow(Icons.inventory_2,
                                              'Products / Items')),
                                      PopupMenuItem(
                                          value: 'machines',
                                          child: _MenuRow(
                                              Icons.precision_manufacturing,
                                              'Machines')),
                                      PopupMenuItem(
                                          value: 'programs',
                                          child: _MenuRow(
                                              Icons.list_alt, 'Programs')),
                                      PopupMenuItem(
                                          value: 'thread',
                                          child: _MenuRow(
                                              Icons.palette, 'Thread Shade')),
                                      PopupMenuItem(
                                          value: 'fabric',
                                          child: _MenuRow(Icons.color_lens,
                                              'Fabric Shade')),
                                      PopupMenuItem(
                                          value: 'delay',
                                          child: _MenuRow(Icons.timer_off,
                                              'Delay Reasons')),
                                      PopupMenuDivider(),
                                      PopupMenuItem(
                                          value: 'update_app',
                                          child: _MenuRow(
                                              Icons.system_update_rounded,
                                              'Update App')),
                                      PopupMenuItem(
                                          value: 'clear_firebase',
                                          child: _MenuRow(
                                              Icons.delete_forever_rounded,
                                              'Clear Firebase Data')),
                                      PopupMenuDivider(),
                                      PopupMenuItem(
                                          value: 'logout',
                                          child: _MenuRow(
                                              Icons.logout_rounded, 'Logout')),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          // ---------- STATS ROW ----------
                          Row(
                            children: [
                              _statChip(
                                'Low Stock',
                                requirementCount.toString(),
                                Icons.warning_amber_rounded,
                                const Color(0xFFFBBF24),
                              ),
                              const SizedBox(width: 12),
                              _statChip(
                                'Status',
                                isOnline ? 'Online' : 'Offline',
                                isOnline
                                    ? Icons.cloud_done_rounded
                                    : Icons.cloud_off_rounded,
                                isOnline
                                    ? const Color(0xFF34D399)
                                    : const Color(0xFFEF4444),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // -------- BODY --------
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        // QUICK ACTIONS LABEL
                        const _SectionTitle('Quick Actions'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _actionChip('Purchase',
                                Icons.shopping_cart_rounded,
                                () => _openQuickPurchase(context)),
                            _actionChip('Issue', Icons.outbox_rounded,
                                () => _openPage(const IssueInventoryPage())),
                            _actionChip(
                              'Requirement',
                              Icons.warning_amber_rounded,
                              () =>
                                  _openPage(const RequirementFabricsPage()),
                              badge: requirementCount,
                            ),
                            _actionChip('History', Icons.history_rounded,
                                _openInventoryHistory),
                          ],
                        ),

                        const SizedBox(height: 28),

                        // MODULES LABEL
                        const _SectionTitle('Modules'),
                        const SizedBox(height: 12),

                        GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.92,
                          children: [
                            _moduleCard(
                                'Add Firm',
                                Icons.domain_add_rounded,
                                const Color(0xFFB8860B),
                                () => _openPage(const FirmListPage())),
                            _moduleCard(
                                'Stock\nReport',
                                Icons.list_alt_rounded,
                                const Color(0xFF14B8A6),
                                () => _openPage(const StockLedgerPage())),
                            _moduleCard(
                                'Purchase\nReport',
                                Icons.bar_chart_rounded,
                                const Color(0xFFDAA520),
                                () => _openPage(const StockSummaryPage())),
                            _moduleCard(
                                'Adjust',
                                Icons.tune_rounded,
                                const Color(0xFFEC4899),
                                () =>
                                    _openPage(const StockAdjustmentPage())),
                            _moduleCard(
                                'Issue\nReport',
                                Icons.assessment_rounded,
                                const Color(0xFF8B5CF6),
                                () => _openPage(const IssueReportPage())),
                            _moduleCard(
                                'Issue\nChallan',
                                Icons.receipt_long_rounded,
                                const Color(0xFFB8860B),
                                () => _openPage(const IssueChallanPage())),
                            _moduleCard(
                                'Machine',
                                Icons.precision_manufacturing_rounded,
                                const Color(0xFFEF4444),
                                () =>
                                    _openPage(const MachineAllotmentPage())),
                            _moduleCard(
                                'Operator',
                                Icons.play_circle_fill_rounded,
                                const Color(0xFF22C55E),
                                () => _openPage(const OperatorLivePage())),
                          ],
                        ),

                        const SizedBox(height: 24),
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

  // ================= WIDGETS =================

  Widget _statChip(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
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
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    )),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 12,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(String title, IconData icon, VoidCallback onTap,
      {int badge = 0}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(50),
          border: Border.all(color: _gold.withValues(alpha: 0.15)),
          boxShadow: [
            BoxShadow(
              color: _gold.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _goldDark, size: 18),
            const SizedBox(width: 6),
            Text(title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: _textDark,
                )),
            if (badge > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$badge',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _moduleCard(
      String title, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: color.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: _textDark,
                )),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1E293B),
        letterSpacing: -0.3,
      ),
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
        Icon(icon, size: 20, color: const Color(0xFFB8860B)),
        const SizedBox(width: 12),
        Text(label,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
              color: Color(0xFF1E293B),
            )),
      ],
    );
  }
}
