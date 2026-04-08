import 'package:flutter/material.dart';

import '../data/erp_database.dart';
import '../models/product.dart';

class ProductMasterPage extends StatefulWidget {
  const ProductMasterPage({super.key});

  @override
  State<ProductMasterPage> createState() => _ProductMasterPageState();
}

class _ProductMasterPageState extends State<ProductMasterPage> {
  // CONTROLLERS
  final nameCtrl = TextEditingController();
  final categoryCtrl = TextEditingController();
  String? selectedUnit;
  static const _unitOptions = ['Pcs', 'Kg', 'Mtr'];
  final minStockCtrl = TextEditingController();

  // DATA
  List<Product> products = [];
  int? editId;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final p = await ErpDatabase.instance.getProducts();

      if (!mounted) return;

      setState(() {
        products = p;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading products: $e')),
      );
    }
  }

  Future<void> _save() async {
    if (nameCtrl.text.trim().isEmpty || selectedUnit == null) {
      _msg('Product name & unit required');
      return;
    }

    final product = Product(
      id: editId,
      name: nameCtrl.text.trim(),
      category: categoryCtrl.text.trim(),
      unit: selectedUnit!,
      minStock: double.tryParse(minStockCtrl.text) ?? 0,
    );

    if (editId == null) {
      await ErpDatabase.instance.insertProduct(product);
    } else {
      await ErpDatabase.instance.updateProduct(product);
    }

    if (!mounted) return;

    _clear();
    _loadAll();
  }

  void _edit(Product p) {
    setState(() {
      editId = p.id;
      nameCtrl.text = p.name;
      categoryCtrl.text = p.category;
      selectedUnit = _unitOptions.contains(p.unit) ? p.unit : null;
      minStockCtrl.text = p.minStock.toString();
    });
  }

  Future<void> _delete(Product p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Product'),
        content: Text('Delete "${p.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await ErpDatabase.instance.deleteProduct(p.id!);
    if (!mounted) return;
    _loadAll();
  }

  void _clear() {
    editId = null;
    nameCtrl.clear();
    categoryCtrl.clear();
    selectedUnit = null;
    minStockCtrl.clear();
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Product Master')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                /// ================= FORM =================
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextField(
                              controller: nameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Product Name',
                              ),
                            ),
                            TextField(
                              controller: categoryCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Category',
                              ),
                            ),
                            DropdownButtonFormField<String>(
                              value: selectedUnit,
                              decoration: const InputDecoration(
                                labelText: 'Unit',
                                border: OutlineInputBorder(),
                              ),
                              items: _unitOptions
                                  .map((u) => DropdownMenuItem(
                                        value: u,
                                        child: Text(u),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => selectedUnit = v),
                            ),
                            TextField(
                              controller: minStockCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Minimum Stock',
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton(
                                onPressed: _save,
                                child: Text(
                                  editId == null
                                      ? 'ADD PRODUCT'
                                      : 'UPDATE PRODUCT',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                /// ================= LIST =================
                Expanded(
                  flex: 6,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: products.length,
                    itemBuilder: (_, i) {
                      final p = products[i];

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          title: Text(
                            p.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'Unit: ${p.unit}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _edit(p),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => _delete(p),
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
    );
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    categoryCtrl.dispose();
    minStockCtrl.dispose();
    super.dispose();
  }
}
