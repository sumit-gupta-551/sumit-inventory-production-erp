// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';
import '../models/stock_ledger.dart';

class IssueInventoryPage extends StatefulWidget {
  const IssueInventoryPage({super.key});

  @override
  State<IssueInventoryPage> createState() => _IssueInventoryPageState();
}

class _IssueInventoryPageState extends State<IssueInventoryPage> {
  // ---------- UI COLORS ----------
  static const bg = Color(0xFFF5F6FA);
  static const blue = Color(0xFF2F80ED);
  static const red = Color(0xFFE53935);
  static const border = Color(0xFFE0E0E0);

  // ---------- CONTROLLERS ----------
  final dateCtrl = TextEditingController();
  final issueCtrl = TextEditingController();
  final shadeCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();

  // ---------- DATA ----------
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

  // ---------- ADD SHADE ----------
  void _addShade() {
    if (shadeCtrl.text.isEmpty || qtyCtrl.text.isEmpty) return;

    final q = double.tryParse(qtyCtrl.text);
    if (q == null || q <= 0) return;

    setState(() {
      addedShades.add({
        'shade': shadeCtrl.text.trim(),
        'qty': q,
      });
      shadeCtrl.clear();
      qtyCtrl.clear();
    });
  }

  // ---------- SAVE ISSUE (OUT) ----------
  Future<void> saveIssue() async {
    if (selectedProduct == null ||
        selectedParty == null ||
        issueCtrl.text.isEmpty ||
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
          type: 'OUT', // 🔥 ISSUE = STOCK OUT
          qty: s['qty'],
          date: _dateMillis(),
          reference: issueCtrl.text.trim(),
          remarks: 'Party: ${selectedParty!.name} | Shade: ${s['shade']}',
        ),
      );
    }

    setState(() {
      selectedProduct = null;
      selectedParty = null;
      issueCtrl.clear();
      addedShades.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Stock Issued Successfully'),
        backgroundColor: red,
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('ISSUE INVENTORY'),
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
                      Expanded(
                        child: _field(issueCtrl, 'Issue / Voucher No'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 16),
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
                style: _btn(red),
                onPressed: saveIssue,
                child: const Text(
                  'SAVE ISSUE',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- HELPERS ----------
  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(14),
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

    return Container(
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          ...addedShades.asMap().entries.map((e) {
            final i = e.key;
            final s = e.value;
            return ListTile(
              title: Text('Shade: ${s['shade']}'),
              subtitle: Text('Qty: ${s['qty']}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => setState(() => addedShades.removeAt(i)),
              ),
            );
          }),
        ],
      ),
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
