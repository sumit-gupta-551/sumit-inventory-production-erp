// ignore_for_file: unused_element

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/stock_ledger.dart';

class AddInventoryPage extends StatefulWidget {
  const AddInventoryPage({super.key});

  @override
  State<AddInventoryPage> createState() => _AddInventoryPageState();
}

class _AddInventoryPageState extends State<AddInventoryPage> {
  // ---------------- COLORS ----------------
  static const bg = Color(0xFFF5F6FA);
  static const border = Color(0xFFE0E0E0);
  static const blue = Color(0xFF2F80ED);
  static const green = Color(0xFF27AE60);

  // ---------------- CONTROLLERS ----------------
  final dateCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final partyCtrl = TextEditingController();
  final shadeCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();

  // ---------------- DATA ----------------
  List<Product> products = [];
  Product? selectedProduct;

  String? selectedCategory;
  String? selectedUnit;

  final List<Map<String, dynamic>> addedShades = [];

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    products = await ErpDatabase.instance.getProducts();
    setState(() {});
  }

  int _dateMillis() =>
      DateFormat('dd-MM-yyyy').parse(dateCtrl.text).millisecondsSinceEpoch;

  // ---------------- ADD SHADE ----------------
  void _addShade() {
    if (shadeCtrl.text.isEmpty || qtyCtrl.text.isEmpty) return;

    final qty = double.tryParse(qtyCtrl.text);
    if (qty == null || qty <= 0) return;

    setState(() {
      addedShades.add({
        'shade': shadeCtrl.text.trim(),
        'qty': qty,
      });
      shadeCtrl.clear();
      qtyCtrl.clear();
    });
  }

  // ---------------- SAVE INVENTORY ----------------
  Future<void> saveInventory() async {
    if (selectedProduct == null ||
        invoiceCtrl.text.isEmpty ||
        partyCtrl.text.isEmpty ||
        addedShades.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all required fields')),
      );
      return;
    }

    for (final s in addedShades) {
      await ErpDatabase.instance.insertLedger(
        StockLedger(
          productId: selectedProduct!.id!,
          type: 'IN',
          qty: s['qty'],
          date: _dateMillis(),
          reference: invoiceCtrl.text.trim(),
          remarks: 'Party: ${partyCtrl.text} | Category: $selectedCategory | '
              'Unit: $selectedUnit | Shade: ${s['shade']}',
        ),
      );
    }

    setState(() {
      selectedProduct = null;
      selectedCategory = null;
      selectedUnit = null;
      invoiceCtrl.clear();
      partyCtrl.clear();
      addedShades.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Inventory Saved Successfully'),
        backgroundColor: green,
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('ADD INVENTORY'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _card(
              Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _dateField()),
                      const SizedBox(width: 12),
                      Expanded(child: _field(invoiceCtrl, 'Invoice / GRN No')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _field(partyCtrl, 'Party Name'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<Product>(
                    value: selectedProduct,
                    decoration: _decor('Product'),
                    items: products
                        .map(
                          (p) => DropdownMenuItem(
                            value: p,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      setState(() {
                        selectedProduct = v;
                        selectedCategory = v?.category;
                        selectedUnit = v?.unit;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _card(
              Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _field(shadeCtrl, 'Shade No')),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _field(
                          qtyCtrl,
                          'Quantity',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: _btn(blue),
                      onPressed: _addShade,
                      child: const Text('ADD SHADE'),
                    ),
                  ),
                ],
              ),
            ),
            _addedShadesList(),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: _btn(green),
                onPressed: saveInventory,
                child: const Text(
                  'SAVE INVENTORY',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- UI HELPERS ----------------

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      decoration: _decor(label),
    );
  }

  Widget _addedShadesList() {
    if (addedShades.isEmpty) return const SizedBox();

    return Container(
      margin: const EdgeInsets.only(top: 16),
      child: Column(
        children: addedShades.map((e) {
          return ListTile(
            title: Text('Shade: ${e['shade']}'),
            trailing: Text('Qty: ${e['qty']}'),
          );
        }).toList(),
      ),
    );
  }

  Widget _dateField() {
    return TextField(
      controller: dateCtrl,
      readOnly: true,
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
          initialDate: DateTime.now(),
        );
        if (d != null) {
          dateCtrl.text = DateFormat('dd-MM-yyyy').format(d);
        }
      },
      decoration: _decor('Date'),
    );
  }

  InputDecoration _decor(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: blue),
      ),
    );
  }

  ButtonStyle _btn(Color c) {
    return ElevatedButton.styleFrom(
      backgroundColor: c,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}
