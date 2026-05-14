import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';
import '../widgets/inventory_form_card.dart';

class GoodsReturnPage extends StatefulWidget {
  const GoodsReturnPage({super.key});

  @override
  State<GoodsReturnPage> createState() => _GoodsReturnPageState();
}

class _GoodsReturnPageState extends State<GoodsReturnPage> {
  final dateCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();

  List<Product> products = [];
  List<Party> parties = [];
  List<Map<String, dynamic>> fabricShades = [];

  Product? selectedProduct;
  Party? selectedParty;
  Map<String, dynamic>? selectedShade;

  final List<Map<String, dynamic>> addedShades = [];

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadMasters();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted) return;
    _loadMasters();
  }

  Future<void> _loadMasters() async {
    final results = await Future.wait([
      ErpDatabase.instance.getProducts(),
      ErpDatabase.instance.getParties(),
      ErpDatabase.instance.getFabricShades(),
    ]);
    products = results[0] as List<Product>;
    parties = results[1] as List<Party>;
    fabricShades = results[2] as List<Map<String, dynamic>>;
    setState(() {});
  }

  int? get _selectedPartyId {
    final id = selectedParty?.id;
    if (id == null) return null;
    return parties.any((p) => p.id == id) ? id : null;
  }

  Party? _partyById(int? id) {
    if (id == null) return null;
    return parties.cast<Party?>().firstWhere(
          (p) => p?.id == id,
          orElse: () => null,
        );
  }

  int? get _selectedProductId {
    final id = selectedProduct?.id;
    if (id == null) return null;
    return products.any((p) => p.id == id) ? id : null;
  }

  Product? _productById(int? id) {
    if (id == null) return null;
    return products.cast<Product?>().firstWhere(
          (p) => p?.id == id,
          orElse: () => null,
        );
  }

  int _dateMillis() =>
      DateFormat('dd-MM-yyyy').parse(dateCtrl.text).millisecondsSinceEpoch;

  void _addShade() {
    if (selectedShade == null || qtyCtrl.text.isEmpty) {
      _msg('Select fabric shade and quantity');
      return;
    }

    final qty = double.tryParse(qtyCtrl.text);
    if (qty == null || qty <= 0) {
      _msg('Invalid quantity');
      return;
    }

    setState(() {
      addedShades.add({
        'fabric_shade_id': selectedShade!['id'],
        'shade_no': selectedShade!['shade_no'],
        'qty': qty,
      });
      selectedShade = null;
      qtyCtrl.clear();
    });
  }

  Future<void> _saveReturn() async {
    if (selectedProduct == null ||
        selectedParty == null ||
        invoiceCtrl.text.isEmpty ||
        addedShades.isEmpty) {
      _msg('Please fill all required fields');
      return;
    }

    try {
      for (final s in addedShades) {
        await ErpDatabase.instance.insertLedger({
          'product_id': selectedProduct!.id,
          'fabric_shade_id': s['fabric_shade_id'],
          'qty': s['qty'],
          'type': 'IN',
          'date': _dateMillis(),
          'reference': invoiceCtrl.text.trim(),
          'remarks':
              'Return | Party: ${selectedParty!.name} | Shade: ${s['shade_no']}',
        });
      }

      setState(() {
        selectedProduct = null;
        selectedParty = null;
        selectedShade = null;
        invoiceCtrl.clear();
        qtyCtrl.clear();
        addedShades.clear();
      });

      _msg('Goods Return Saved Successfully', success: true);
    } catch (e) {
      _msg('Error saving return');
    }
  }

  void _msg(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success ? Colors.green : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Goods Return')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F5F5), Color(0xFFE3F2FD), Color(0xFFF5F5F5)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -100,
              right: -60,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFF1565C0).withValues(alpha: 0.15),
                    const Color(0xFF1565C0).withValues(alpha: 0.04),
                    Colors.transparent,
                  ], stops: const [
                    0.0,
                    0.4,
                    1.0
                  ]),
                ),
              ),
            ),
            Positioned(
              bottom: -140,
              left: -80,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFFE91E63).withValues(alpha: 0.12),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
            Positioned(
              top: 300,
              left: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFF673AB7).withValues(alpha: 0.10),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  InventoryFormCard(
                    title: 'Return Details',
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
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
                                  dateCtrl.text =
                                      DateFormat('dd-MM-yyyy').format(d);
                                }
                              },
                              decoration:
                                  const InputDecoration(labelText: 'Date'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: invoiceCtrl,
                              decoration: const InputDecoration(
                                  labelText: 'Return / Bill No'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _selectedPartyId,
                        decoration: const InputDecoration(labelText: 'Party'),
                        items: parties
                            .where((p) => p.id != null)
                            .map((p) => DropdownMenuItem<int>(
                                  value: p.id!,
                                  child: Text(p.name),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => selectedParty = _partyById(v)),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: _selectedProductId,
                        decoration: const InputDecoration(labelText: 'Product'),
                        items: products
                            .where((p) => p.id != null)
                            .map((p) => DropdownMenuItem<int>(
                                  value: p.id!,
                                  child: Text(p.name),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => selectedProduct = _productById(v)),
                      ),
                    ],
                  ),
                  InventoryFormCard(
                    title: 'Add Fabric Shade',
                    // ignore: sort_child_properties_last
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child:
                                DropdownButtonFormField<Map<String, dynamic>>(
                              initialValue: selectedShade,
                              decoration: const InputDecoration(
                                  labelText: 'Fabric Shade'),
                              items: fabricShades
                                  .map((s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(s['shade_no']),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => selectedShade = v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: qtyCtrl,
                              keyboardType: TextInputType.number,
                              decoration:
                                  const InputDecoration(labelText: 'Quantity'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    footer: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _addShade,
                        child: const Text('ADD SHADE'),
                      ),
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
          ],
        ),
      ),
    );
  }

  Widget _addedShadesList() {
    if (addedShades.isEmpty) return const SizedBox();

    return Column(
      children: addedShades.asMap().entries.map((e) {
        final i = e.key;
        final s = e.value;
        return ListTile(
          title: Text(s['shade_no']),
          subtitle: Text('Qty: ${s['qty']}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () => setState(() => addedShades.removeAt(i)),
          ),
        );
      }).toList(),
    );
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    dateCtrl.dispose();
    invoiceCtrl.dispose();
    qtyCtrl.dispose();
    super.dispose();
  }
}
