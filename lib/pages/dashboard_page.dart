import 'package:flutter/material.dart';

import 'product_master_page.dart';
import 'party_master_page.dart';
import 'machine_master_page.dart';
import 'program_master_page.dart';
import 'add_inventory_page.dart';
import 'operator_live_page.dart';
import 'thread_shade_master_page.dart';
import 'machine_allotment_page.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ERP Dashboard'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: [
            _tile(
              context,
              title: 'Product Master',
              icon: Icons.inventory_2,
              page: const ProductMasterPage(),
            ),
            _tile(
              context,
              title: 'Party Master',
              icon: Icons.people,
              page: const PartyMasterPage(),
            ),
            _tile(
              context,
              title: 'Machine Master',
              icon: Icons.precision_manufacturing,
              page: const MachineMasterPage(),
            ),
            _tile(
              context,
              title: 'Machine Allotment',
              icon: Icons.link,
              page: const MachineAllotmentPage(),
            ),
            _tile(
              context,
              title: 'Thread Shade Master',
              icon: Icons.color_lens,
              page: const ThreadShadeMasterPage(),
            ),
            _tile(
              context,
              title: 'Program Master',
              icon: Icons.assignment,
              page: const ProgramMasterPage(),
            ),
            _tile(
              context,
              title: 'Add Inventory',
              icon: Icons.add_box,
              page: const AddInventoryPage(),
            ),
            _tile(
              context,
              title: 'Operator Live',
              icon: Icons.play_circle_fill,
              page: const OperatorLivePage(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Widget page,
  }) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => page),
        );
      },
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 42, color: Colors.blue),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
