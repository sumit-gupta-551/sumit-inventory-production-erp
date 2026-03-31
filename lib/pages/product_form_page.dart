import 'package:flutter/material.dart';
import '../data/erp_database.dart';
import '../models/product.dart';

class ProductMasterPage extends StatefulWidget {
  const ProductMasterPage({super.key});

  @override
  State<ProductMasterPage> createState() => _ProductMasterPageState();
}

class _ProductMasterPageState extends State<ProductMasterPage> {
  // Controllers
  final nameCtrl = TextEditingController();
  final categoryCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final minStockCtrl = TextEditingController();

  // GST
  List<Map<String, dynamic>> gstCategories = [];
  int? selectedGstId;

  // Data
  List<Product> products = [];
  int? editId;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      loading = false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _save() async {
    if (nameCtrl.text.isEmpty ||
        unitCtrl.text.isEmpty ||
        selectedGstId == null) {
      _msg('Name, Unit & GST required');
      return;
    }

    final p = Product(
      id: editId,
      name: nameCtrl.text.trim(),
      category: categoryCtrl.text.trim(),
      unit: unitCtrl.text.trim(),
      minStock: double.tryParse(minStockCtrl.text) ?? 0,
      gstCategoryId: selectedGstId,
    );

    if (editId == null) {
      await ErpDatabase.instance.insertProduct(p);
    } else {
      await ErpDatabase.instance.updateProduct(p);
    }

    if (!mounted) return;
    _clear();
    _load();
  }

  void _edit(Product p) {
    setState(() {
      editId = p.id;
      nameCtrl.text = p.name;
      categoryCtrl.text = p.category;
      unitCtrl.text = p.unit;
      minStockCtrl.text = p.minStock.toString();
      selectedGstId = p.gstCategoryId;
    });
  }

  Future<void> _delete(Product p) async {
    await ErpDatabase.instance.deleteProduct(p.id!);
    _load();
  }

  void _clear() {
    editId = null;
    nameCtrl.clear();
    categoryCtrl.clear();
    unitCtrl.clear();
    minStockCtrl.clear();
    selectedGstId = null;
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
                /// ---------- FORM ----------
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
                              decoration:
                                  const InputDecoration(labelText: 'Name'),
                            ),
                            TextField(
                              controller: categoryCtrl,
                              decoration:
                                  const InputDecoration(labelText: 'Category'),
                            ),
                            TextField(
                              controller: unitCtrl,
                              decoration:
                                  const InputDecoration(labelText: 'Unit'),
                            ),
                            TextField(
                              controller: minStockCtrl,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: 'Min Stock'),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int>(
                              value: selectedGstId,
                              decoration: const InputDecoration(
                                labelText: 'GST',
                                border: OutlineInputBorder(),
                              ),
                              items: gstCategories
                                  .map(
                                    (g) => DropdownMenuItem<int>(
                                      value: g['id'],
                                      child: Text(
                                          '${g['name']} (${g['gst_percent']}%)'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => selectedGstId = v),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: 46,
                              child: ElevatedButton(
                                onPressed: _save,
                                child: Text(
                                  editId == null ? 'ADD PRODUCT' : 'UPDATE',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                /// ---------- LIST ----------
                Expanded(
                  flex: 6,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: products.length,
                    itemBuilder: (_, i) {
                      final p = products[i];
                      return Card(
                        child: ListTile(
                          title: Text(p.name),
                          subtitle: Text('Unit: ${p.unit}'),
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
