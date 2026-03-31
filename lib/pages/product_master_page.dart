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
  final unitCtrl = TextEditingController();
  final minStockCtrl = TextEditingController();

  // GST
  List<Map<String, dynamic>> gstCategories = [];
  int? selectedGstCategoryId;

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
      final g = await ErpDatabase.instance.getGstCategories();
      final p = await ErpDatabase.instance.getProducts();

      if (!mounted) return;

      setState(() {
        gstCategories = g;
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
    if (nameCtrl.text.trim().isEmpty ||
        unitCtrl.text.trim().isEmpty ||
        selectedGstCategoryId == null) {
      _msg('Product name, unit & GST required');
      return;
    }

    final product = Product(
      id: editId,
      name: nameCtrl.text.trim(),
      category: categoryCtrl.text.trim(),
      unit: unitCtrl.text.trim(),
      minStock: double.tryParse(minStockCtrl.text) ?? 0,
      gstCategoryId: selectedGstCategoryId,
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
      unitCtrl.text = p.unit;
      minStockCtrl.text = p.minStock.toString();
      selectedGstCategoryId = p.gstCategoryId;
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
    BuildContext;
    if (!mounted) return;
    _loadAll();
  }

  void _clear() {
    editId = null;
    nameCtrl.clear();
    categoryCtrl.clear();
    unitCtrl.clear();
    minStockCtrl.clear();
    selectedGstCategoryId = null;
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _gstLabel(int? id) {
    final g = gstCategories.firstWhere(
      (e) => e['id'] == id,
      orElse: () => {},
    );
    BuildContext;
    return g.isEmpty ? '-' : '${g['gst_percent']}%';
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
                            TextField(
                              controller: unitCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Unit',
                              ),
                            ),
                            TextField(
                              controller: minStockCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Minimum Stock',
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int>(
                              value: selectedGstCategoryId,
                              decoration: const InputDecoration(
                                labelText: 'GST Category',
                                border: OutlineInputBorder(),
                              ),
                              items: gstCategories
                                  .map(
                                    (g) => DropdownMenuItem<int>(
                                      value: g['id'],
                                      child: Text(
                                        '${g['name']} (${g['gst_percent']}%)',
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) => setState(
                                () => selectedGstCategoryId = v,
                              ),
                            ),
                            const SizedBox(height: 16),
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
                            'Unit: ${p.unit}\nGST: ${_gstLabel(p.gstCategoryId)}',
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
    unitCtrl.dispose();
    minStockCtrl.dispose();
    super.dispose();
  }
}
