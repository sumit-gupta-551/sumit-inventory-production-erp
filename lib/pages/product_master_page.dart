import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../models/product.dart';

class ProductMasterPage extends StatefulWidget {
  const ProductMasterPage({super.key});

  @override
  State<ProductMasterPage> createState() => _ProductMasterPageState();
}

class _ProductMasterPageState extends State<ProductMasterPage> {
  final nameCtrl = TextEditingController();
  final categoryCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final minCtrl = TextEditingController();

  List<Product> products = [];
  int? editId;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    products = await ErpDatabase.instance.getProducts();
    setState(() {});
  }

  Future<void> _saveProduct() async {
    if (nameCtrl.text.isEmpty ||
        categoryCtrl.text.isEmpty ||
        unitCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all required fields')),
      );
      return;
    }

    final product = Product(
      id: editId,
      name: nameCtrl.text.trim(),
      category: categoryCtrl.text.trim(),
      unit: unitCtrl.text.trim(),
      minStock: double.tryParse(minCtrl.text) ?? 0,
    );

    if (editId == null) {
      await ErpDatabase.instance.insertProduct(product);
    } else {
      await ErpDatabase.instance.updateProduct(product);
    }

    _clearForm();
    _loadProducts();
  }

  void _editProduct(Product p) {
    setState(() {
      editId = p.id;
      nameCtrl.text = p.name;
      categoryCtrl.text = p.category;
      unitCtrl.text = p.unit;
      minCtrl.text = p.minStock.toString();
    });
  }

  Future<void> _deleteProduct(int id) async {
    await ErpDatabase.instance.deleteProduct(id);
    _loadProducts();
  }

  void _clearForm() {
    editId = null;
    nameCtrl.clear();
    categoryCtrl.clear();
    unitCtrl.clear();
    minCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Product Master'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Product Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: categoryCtrl,
              decoration: const InputDecoration(labelText: 'Category'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: unitCtrl,
              decoration: const InputDecoration(labelText: 'Unit (kg, pcs)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: minCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Minimum Stock'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveProduct,
                    child: Text(
                        editId == null ? 'SAVE PRODUCT' : 'UPDATE PRODUCT'),
                  ),
                ),
                if (editId != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _clearForm,
                      child: const Text('CANCEL'),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 30),
            Expanded(
              child: ListView.builder(
                itemCount: products.length,
                itemBuilder: (_, i) {
                  final p = products[i];
                  return Card(
                    child: ListTile(
                      title: Text(p.name),
                      subtitle: Text(
                        'Category: ${p.category} | Unit: ${p.unit} | Min: ${p.minStock}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () => _editProduct(p),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteProduct(p.id!),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
