import 'package:flutter/material.dart';

import 'product_master_page.dart';
import 'stock_in_page.dart';

class ErpHomePage extends StatelessWidget {
  const ErpHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ERP Inventory'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: [
            _tile(
              context,
              title: 'Product Master',
              icon: Icons.inventory_2,
              page: const ProductMasterPage(),
            ),
            _tile(
              context,
              title: 'ADD INVENTORY', // ✅ RENAMED
              icon: Icons.add_box_outlined,
              page: const StockInPage(),
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
            Icon(icon, size: 42),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
