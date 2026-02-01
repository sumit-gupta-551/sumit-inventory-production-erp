import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/stock_ledger.dart';

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
  }

  Future<void> _loadProducts() async {
    final list = await ErpDatabase.instance.getProducts();
    setState(() => products = list);
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

    final ledger = StockLedger(
      productId: selectedProduct!.id!,
      type: 'IN',
      qty: qty,
      date: DateTime.now().millisecondsSinceEpoch,
      reference: refCtrl.text.trim().isEmpty ? 'GRN' : refCtrl.text.trim(),
      remarks: remarksCtrl.text.trim(),
    );

    await ErpDatabase.instance.insertLedger(ledger);

    qtyCtrl.clear();
    remarksCtrl.clear();

    setState(() {
      selectedProduct = null;
      saving = false;
    });

    _msg('Stock IN saved successfully');
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stock IN (Purchase / GRN)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<Product>(
              value: selectedProduct,
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
            const SizedBox(height: 20),
            if (selectedProduct != null)
              FutureBuilder<double>(
                future: ErpDatabase.instance
                    .getProductBalance(selectedProduct!.id!),
                builder: (_, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SizedBox();
                  }
                  if (!snap.hasData) {
                    return const Text('Current Stock: 0');
                  }
                  return Text(
                    'Current Stock: ${snap.data}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
