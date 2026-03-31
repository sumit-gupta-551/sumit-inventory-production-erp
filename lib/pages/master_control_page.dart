import 'package:flutter/material.dart';

import 'firm_list_page.dart';
import 'party_master_page.dart';
import 'product_master_page.dart';
import 'machine_master_page.dart';
import 'program_master_page.dart';
import 'thread_shade_master_page.dart';
import 'delay_reason_master_page.dart';

class MasterControlPage extends StatelessWidget {
  const MasterControlPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FB),
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          'Master Control',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 1.1,
          children: const [
            _MasterTile(
              title: 'Firms',
              icon: Icons.business,
              color: Colors.blue,
              page: FirmListPage(),
            ),
            _MasterTile(
              title: 'Parties',
              icon: Icons.people,
              color: Colors.green,
              page: PartyMasterPage(),
            ),
            _MasterTile(
              title: 'Products / Items',
              icon: Icons.inventory_2,
              color: Colors.orange,
              page: ProductMasterPage(),
            ),
            _MasterTile(
              title: 'Machines',
              icon: Icons.precision_manufacturing,
              color: Colors.teal,
              page: MachineMasterPage(),
            ),
            _MasterTile(
              title: 'Programs',
              icon: Icons.list_alt,
              color: Colors.indigo,
              page: ProgramMasterPage(),
            ),
            _MasterTile(
              title: 'Thread / Shade',
              icon: Icons.palette,
              color: Colors.purple,
              page: ThreadShadeMasterPage(),
            ),
            _MasterTile(
              title: 'Delay Reasons',
              icon: Icons.timer_off,
              color: Colors.redAccent,
              page: DelayReasonMasterPage(),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// MASTER TILE WIDGET
/// =======================
class _MasterTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final Widget page;

  const _MasterTile({
    required this.title,
    required this.icon,
    required this.color,
    required this.page,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => page),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.15),
              blurRadius: 12,
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
                shape: BoxShape.circle,
                color: color.withOpacity(0.12),
              ),
              child: Icon(icon, size: 32, color: color),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
