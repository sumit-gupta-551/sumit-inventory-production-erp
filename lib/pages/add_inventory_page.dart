// ignore_for_file: unused_element

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';
import '../models/stock_ledger.dart';

class AddInventoryPage extends StatefulWidget {
  const AddInventoryPage({super.key});

  @override
  State<AddInventoryPage> createState() => _AddInventoryPageState();
}

class _AddInventoryPageState extends State<AddInventoryPage> {
  // ---------------- CONTROLLERS ----------------
  final dateCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final shadeCtrl = TextEditingController();

  // ---------------- MASTER DATA ----------------
  List<Product> products = [];
  Product? selectedProduct;

  List<Party> parties = [];
  Party? selectedParty;

  String? selectedCategory;
  String? selectedUnit;

  List<String> fabricShades = [];
  String? selectedFabricShade;

  final List<Map<String, dynamic>> addedShades = [];

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    products = await ErpDatabase.instance.getProducts();
    parties = await ErpDatabase.instance.getParties();
    setState(() {});
  }

  int _dateMillis() =>
      DateFormat('dd-MM-yyyy').parse(dateCtrl.text).millisecondsSinceEpoch;

  // ---------------- DATE PICKER ----------------
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: DateTime.now(),
    );
    if (picked != null) {
      dateCtrl.text = DateFormat('dd-MM-yyyy').format(picked);
    }
  }

  // ---------------- ADD SHADE ----------------
  void _addShade() {
    if (shadeCtrl.text.isEmpty || qtyCtrl.text.isEmpty) {
      _msg('Select shade and enter quantity');
      return;
    }

    final qty = double.tryParse(qtyCtrl.text);
    if (qty == null || qty <= 0) {
      _msg('Invalid quantity');
      return;
    }

    setState(() {
      addedShades.add({
        'shade': shadeCtrl.text.trim(),
        'qty': qty,
      });
      shadeCtrl.clear();
      qtyCtrl.clear();
      selectedFabricShade = null;
    });
  }

  void _openFabricShadePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        List<String> filtered = List.from(fabricShades);
        final searchCtrl = TextEditingController();

        return StatefulBuilder(
          builder: (ctx, setModal) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: searchCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Search fabric shade',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (v) {
                        setModal(() {
                          filtered = fabricShades
                              .where((s) =>
                                  s.toLowerCase().contains(v.toLowerCase()))
                              .toList();
                        });
                      },
                    ),
                  ),
                  SizedBox(
                    height: 300,
                    child: filtered.isEmpty
                        ? const Center(child: Text('No shades found'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              return ListTile(
                                title: Text(filtered[i]),
                                onTap: () {
                                  setState(() {
                                    selectedFabricShade = filtered[i];
                                    shadeCtrl.text = filtered[i];
                                  });
                                  Navigator.pop(context);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------------- SAVE INVENTORY ----------------
  Future<void> _saveInventory() async {
    if (selectedProduct == null ||
        selectedParty == null ||
        addedShades.isEmpty) {
      _msg('Please fill all required fields');
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
          remarks: 'Party: ${selectedParty!.name} | '
              'Category: $selectedCategory | '
              'Unit: $selectedUnit | '
              'Shade: ${s['shade']}',
        ),
      );
    }

    setState(() {
      selectedProduct = null;
      selectedParty = null;
      selectedCategory = null;
      selectedUnit = null;
      fabricShades.clear();
      addedShades.clear();
      invoiceCtrl.clear();
    });

    _msg('Inventory saved successfully');
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ADD INVENTORY')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // DATE + INVOICE ROW
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: dateCtrl,
                    readOnly: true,
                    onTap: _pickDate,
                    decoration: const InputDecoration(labelText: 'Date'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: invoiceCtrl,
                    decoration: const InputDecoration(labelText: 'Invoice No'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // PARTY
            DropdownButtonFormField<Party>(
              value: selectedParty,
              decoration: const InputDecoration(labelText: 'Party'),
              items: parties
                  .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                  .toList(),
              onChanged: (v) => setState(() => selectedParty = v),
            ),
            const SizedBox(height: 12),

            // PRODUCT
            DropdownButtonFormField<Product>(
              value: selectedProduct,
              decoration: const InputDecoration(labelText: 'Product'),
              items: products
                  .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                  .toList(),
              onChanged: (p) async {
                setState(() {
                  selectedProduct = p;
                  selectedCategory = p?.category;
                  selectedUnit = p?.unit;
                  fabricShades.clear();
                  shadeCtrl.clear();
                });

                if (p != null) {
                  fabricShades =
                      await ErpDatabase.instance.getFabricShades(p.id!);
                  setState(() {});
                }
              },
            ),
            const SizedBox(height: 12),

            // CATEGORY & UNIT
            Row(
              children: [
                Expanded(
                  child: TextField(
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Category'),
                    controller:
                        TextEditingController(text: selectedCategory ?? ''),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    readOnly: true,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    controller: TextEditingController(text: selectedUnit ?? ''),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

// FABRIC SHADE (SEARCH + DROPDOWN BEHAVIOR)
            Autocomplete<String>(
              optionsBuilder: (TextEditingValue text) {
                if (fabricShades.isEmpty) {
                  return const Iterable<String>.empty();
                }

                // Show ALL shades when field is empty
                if (text.text.isEmpty) {
                  return fabricShades;
                }

                // Filter when typing
                return fabricShades.where(
                  (s) => s.toLowerCase().contains(text.text.toLowerCase()),
                );
              },
              onSelected: (value) {
                selectedFabricShade = value;
                shadeCtrl.text = value;
              },
              fieldViewBuilder: (context, controller, focusNode, _) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Fabric Shade',
                    hintText: 'Tap or type to search shade',
                  ),
                  onTap: () {
                    // Force dropdown to open on tap
                    if (!focusNode.hasFocus) {
                      focusNode.requestFocus();
                    }
                  },
                );
              },
            )
            // QTY
            ,
            TextField(
              controller: shadeCtrl,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Fabric Shade',
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              onTap: () {
                if (fabricShades.isEmpty) {
                  _msg('No fabric shades available for this product');
                  return;
                }
                _openFabricShadePicker();
              },
            ),

            TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
            const SizedBox(height: 12),

            ElevatedButton(
              onPressed: _addShade,
              child: const Text('ADD SHADE'),
            ),

            const SizedBox(height: 12),
            ...addedShades.map((e) => ListTile(
                  title: Text(e['shade']),
                  trailing: Text(e['qty'].toString()),
                )),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _saveInventory,
              child: const Text('SAVE INVENTORY'),
            ),
          ],
        ),
      ),
    );
  }
}
