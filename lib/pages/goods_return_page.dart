import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';

class GoodsReturnPage extends StatefulWidget {
  const GoodsReturnPage({super.key});

  @override
  State<GoodsReturnPage> createState() => _GoodsReturnPageState();
}

class _GoodsReturnPageState extends State<GoodsReturnPage> {
  // ---------------- CONTROLLERS ----------------
  final dateCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final shadeCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();

  // ---------------- DATA ----------------
  List<Product> products = [];
  List<Party> parties = [];

  Product? selectedProduct;
  Party? selectedParty;

  final List<Map<String, dynamic>> addedShades = [];

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadMasters();
  }

  Future<void> _loadMasters() async {
    products = await ErpDatabase.instance.getProducts();
    parties = await ErpDatabase.instance.getParties();
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

  // ---------------- SAVE GOODS RETURN ----------------
  Future<void> _saveReturn() async {
    if (selectedProduct == null ||
        selectedParty == null ||
        invoiceCtrl.text.isEmpty ||
        addedShades.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields')),
      );
      return;
    }

    for (final s in addedShades) {
      await ErpDatabase.instance.insertLedger({
        'product_id': selectedProduct!.id,
        'type': 'IN', // ✅ RETURN = STOCK IN
        'qty': s['qty'],
        'date': _dateMillis(),
        'reference': invoiceCtrl.text.trim(),
        'remarks':
            'Return | Party: ${selectedParty!.name} | Shade: ${s['shade']}',
      });
    }

    setState(() {
      selectedProduct = null;
      selectedParty = null;
      invoiceCtrl.clear();
      addedShades.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Goods Return Saved Successfully'),
        backgroundColor: Colors.green,
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Goods Return')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _dateField(),
            const SizedBox(height: 12),
            _field(invoiceCtrl, 'Return / Bill No'),
            const SizedBox(height: 12),

            // PARTY
            DropdownButtonFormField<Party>(
              value: selectedParty,
              decoration: _decor('Party'),
              items: parties
                  .map(
                    (p) => DropdownMenuItem(
                      value: p,
                      child: Text(p.name),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => selectedParty = v),
            ),
            const SizedBox(height: 12),

            // PRODUCT
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
              onChanged: (v) => setState(() => selectedProduct = v),
            ),
            const SizedBox(height: 20),

            // SHADE + QTY
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
              child: ElevatedButton(
                onPressed: _addShade,
                child: const Text('ADD SHADE'),
              ),
            ),

            _addedShadesList(),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _saveReturn,
                child: const Text(
                  'SAVE GOODS RETURN',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- HELPERS ----------------

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

  Widget _addedShadesList() {
    if (addedShades.isEmpty) return const SizedBox();

    return Column(
      children: addedShades.asMap().entries.map((e) {
        final i = e.key;
        final s = e.value;
        return ListTile(
          title: Text(s['shade']),
          subtitle: Text('Qty: ${s['qty']}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () {
              setState(() => addedShades.removeAt(i));
            },
          ),
        );
      }).toList(),
    );
  }

  InputDecoration _decor(String label) {
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    );
  }
}
