import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../models/product.dart';

class StockInPage extends StatefulWidget {
  const StockInPage({super.key});

  @override
  State<StockInPage> createState() => _StockInPageState();
}

class _StockInPageState extends State<StockInPage> {
  final qtyCtrl = TextEditingController();
  final refCtrl = TextEditingController(text: 'GRN');
  final remarksCtrl = TextEditingController();

  List<Product> products = [];
  Product? selectedProduct;

  bool saving = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted) return;
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    products = await ErpDatabase.instance.getProducts();
    if (!mounted) return;
    setState(() {});
  }

  // ---------------- SAVE STOCK IN ----------------
  Future<void> _saveStockIn() async {
    if (saving) return;

    if (selectedProduct == null) {
      _msg('Please select product');
      return;
    }

    final qty = double.tryParse(qtyCtrl.text);
    if (qty == null || qty <= 0) {
      _msg('Enter valid quantity');
      return;
    }

    setState(() => saving = true);

    await ErpDatabase.instance.insertLedger({
      'product_id': selectedProduct!.id,
      'fabric_shade_id': null, // NO SHADE IN DIRECT STOCK IN
      'qty': qty,
      'type': 'IN',
      'date': DateTime.now().millisecondsSinceEpoch,
      'reference': refCtrl.text.trim(),
      'remarks': remarksCtrl.text.trim(),
    });

    qtyCtrl.clear();
    remarksCtrl.clear();

    setState(() {
      selectedProduct = null;
      saving = false;
    });

    _msg('Stock IN saved successfully', success: true);
  }

  void _msg(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success ? Colors.green : null,
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stock IN (Purchase / GRN)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<Product>(
              initialValue: selectedProduct,
              decoration: const InputDecoration(labelText: 'Select Product'),
              items: products
                  .map(
                    (p) => DropdownMenuItem<Product>(
                      value: p,
                      child: Text(p.name),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => selectedProduct = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: refCtrl,
              decoration: const InputDecoration(labelText: 'Reference (GRN)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: remarksCtrl,
              decoration: const InputDecoration(labelText: 'Remarks'),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: saving ? null : _saveStockIn,
                child: Text(saving ? 'SAVING...' : 'SAVE STOCK IN'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    qtyCtrl.dispose();
    refCtrl.dispose();
    remarksCtrl.dispose();
    super.dispose();
  }
}
