// ignore_for_file: use_build_context_synchronously

import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/erp_database.dart';

enum ShadeType { thread, fabric }

class AddShadePage extends StatefulWidget {
  const AddShadePage({super.key});

  @override
  State<AddShadePage> createState() => _AddShadePageState();
}

class _AddShadePageState extends State<AddShadePage> {
  final _formKey = GlobalKey<FormState>();

  ShadeType selectedType = ShadeType.fabric;

  final shadeNoCtrl = TextEditingController();
  final companyCtrl = TextEditingController(); // For thread shade
  final openingStockCtrl = TextEditingController();
  List<Map<String, dynamic>> products = [];
  int? selectedProductId;

  bool saving = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final db = await ErpDatabase.instance.database;
      final rows = await db.query(
        'products',
        columns: ['id', 'name'],
        where: "name IS NOT NULL AND TRIM(name) <> ''",
        orderBy: 'name',
      );
      if (!mounted) return;
      setState(() {
        products = rows;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        products = [];
      });
      _msg('Unable to load product names');
    }
  }

  String _selectedProductName() {
    final p = products.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == selectedProductId,
          orElse: () => null,
        );
    return (p?['name'] ?? '').toString().trim();
  }

  Future<void> _insertOpeningStock({
    required int productId,
    required int shadeId,
    required double qty,
  }) async {
    if (qty <= 0) return;
    await ErpDatabase.instance.insertLedger(
      {
        'product_id': productId,
        'fabric_shade_id': shadeId,
        'type': 'IN',
        'qty': qty,
        'date': DateTime.now().millisecondsSinceEpoch,
        'reference': 'OPENING',
        'remarks': 'Opening Stock',
      },
    );
  }

  Future<bool> _fabricShadeExists({
    required String shadeNo,
    required String shadeName,
  }) async {
    final db = await ErpDatabase.instance.database;
    final rows = await db.query(
      'fabric_shades',
      columns: ['id'],
      where: 'LOWER(TRIM(shade_no)) = ? AND LOWER(TRIM(shade_name)) = ?',
      whereArgs: [shadeNo.toLowerCase(), shadeName.toLowerCase()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> _threadShadeExists({
    required String shadeNo,
    required String companyName,
  }) async {
    final db = await ErpDatabase.instance.database;
    final rows = await db.query(
      'thread_shades',
      columns: ['id'],
      where: 'LOWER(TRIM(shade_no)) = ? AND LOWER(TRIM(company_name)) = ?',
      whereArgs: [shadeNo.toLowerCase(), companyName.toLowerCase()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _exportToExcel() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      if (selectedType == ShadeType.fabric && selectedProductId == null) {
        _msg('Select product name to export');
        return;
      }

      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];

      if (selectedType == ShadeType.fabric) {
        sheet.appendRow([
          TextCellValue('Shade No'),
        ]);

        final allShades = await ErpDatabase.instance.getFabricShades();
        final productName = _selectedProductName();
        final productShades =
            allShades.where((s) => s['shade_name'] == productName).toList();

        // Deduplicate shade numbers
        final seen = <String>{};
        for (final shade in productShades) {
          final shadeNo = shade['shade_no']?.toString() ?? '';
          if (seen.add(shadeNo)) {
            sheet.appendRow([TextCellValue(shadeNo)]);
          }
        }
      } else {
        sheet.appendRow([
          TextCellValue('Shade No'),
        ]);

        final allThreads = await ErpDatabase.instance.getThreadShades();
        final seen = <String>{};
        for (final shade in allThreads) {
          final shadeNo = shade['shade_no']?.toString() ?? '';
          if (seen.add(shadeNo)) {
            sheet.appendRow([TextCellValue(shadeNo)]);
          }
        }
      }

      final bytes = excel.save();
      if (bytes == null) {
        _msg('Failed to generate Excel');
        return;
      }

      final fileName = selectedType == ShadeType.fabric
          ? 'Fabric_${_selectedProductName()}_Shades.xlsx'
          : 'Thread_Shades.xlsx';

      // Open native save dialog — user picks where to save
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Shades Export',
        fileName: fileName,
        type: FileType.any,
        bytes: Uint8List.fromList(bytes),
      );

      if (path != null && mounted) {
        _msg('Exported successfully', success: true);
      }
    } catch (e) {
      _msg('Export failed: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _importFromExcel() async {
    if (saving) return;

    if (selectedType == ShadeType.fabric && selectedProductId == null) {
      _msg('Select product first for fabric shade import');
      return;
    }

    final productName = _selectedProductName();
    if (selectedType == ShadeType.fabric && productName.isEmpty) {
      _msg('Select valid product');
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final bytes = picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());

    if (bytes == null || bytes.isEmpty) {
      _msg('Unable to read selected file');
      return;
    }

    setState(() => saving = true);

    try {
      final excel = Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) {
        _msg('Excel sheet is empty');
        return;
      }

      final sheet = excel.tables[excel.tables.keys.first];
      if (sheet == null || sheet.rows.isEmpty) {
        _msg('Excel sheet has no rows');
        return;
      }

      var inserted = 0;
      var skipped = 0;

      for (var i = 0; i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        if (row.isEmpty) {
          skipped++;
          continue;
        }

        final shadeNo = (row[0]?.value?.toString() ?? '').trim();
        if (shadeNo.isEmpty) {
          skipped++;
          continue;
        }

        if (i == 0) {
          final maybeHeader = shadeNo.toLowerCase();
          if (maybeHeader.contains('shade')) {
            continue;
          }
        }

        if (selectedType == ShadeType.thread) {
          final company = companyCtrl.text.trim();
          if (company.isEmpty) {
            _msg('Enter company name before thread shade import');
            break;
          }

          final exists = await _threadShadeExists(
            shadeNo: shadeNo,
            companyName: company,
          );
          if (exists) {
            skipped++;
            continue;
          }

          await ErpDatabase.instance.insertThreadShade(
            shadeNo: shadeNo,
            companyName: company,
          );
          inserted++;
        } else {
          final openingQty = double.tryParse(
                  (row.length > 1 ? row[1]?.value?.toString() : '') ?? '') ??
              0;

          final exists = await _fabricShadeExists(
            shadeNo: shadeNo,
            shadeName: productName,
          );
          if (exists) {
            // Shade already exists — add stock to existing shade
            if (openingQty > 0) {
              final db = await ErpDatabase.instance.database;
              final existing = await db.query(
                'fabric_shades',
                columns: ['id'],
                where:
                    'LOWER(TRIM(shade_no)) = ? AND LOWER(TRIM(shade_name)) = ?',
                whereArgs: [shadeNo.toLowerCase(), productName.toLowerCase()],
                limit: 1,
              );
              if (existing.isNotEmpty) {
                await _insertOpeningStock(
                  productId: selectedProductId!,
                  shadeId: existing.first['id'] as int,
                  qty: openingQty,
                );
              }
            }
            skipped++;
            continue;
          }

          final shadeId =
              await ErpDatabase.instance.insertFabricShadeReturningId(
            shadeNo: shadeNo,
            shadeName: productName,
            imagePath: null,
          );

          await _insertOpeningStock(
            productId: selectedProductId!,
            shadeId: shadeId,
            qty: openingQty,
          );

          inserted++;
        }
      }

      _msg(
        'Import completed. Added: $inserted, Skipped: $skipped',
        success: true,
      );
    } catch (e) {
      _msg('Import failed: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  // ---------------- SAVE SHADE ----------------
  Future<void> _saveShade() async {
    if (saving) return;
    if (!_formKey.currentState!.validate()) return;

    if (selectedType == ShadeType.fabric && selectedProductId == null) {
      _msg('Select product name');
      return;
    }

    setState(() => saving = true);

    try {
      if (selectedType == ShadeType.thread) {
        await ErpDatabase.instance.insertThreadShade(
          shadeNo: shadeNoCtrl.text.trim(),
          companyName: companyCtrl.text.trim(),
        );
      } else {
        final productName = _selectedProductName();
        if (productName.isEmpty) {
          _msg('Select valid product name');
          setState(() => saving = false);
          return;
        }
        final shadeId = await ErpDatabase.instance.insertFabricShadeReturningId(
          shadeNo: shadeNoCtrl.text.trim(),
          shadeName: productName,
          imagePath: null,
        );

        final openingQty = double.tryParse(openingStockCtrl.text.trim()) ?? 0;
        await _insertOpeningStock(
          productId: selectedProductId!,
          shadeId: shadeId,
          qty: openingQty,
        );
      }

      _msg('Shade saved successfully', success: true);

      // Clear form
      shadeNoCtrl.clear();
      companyCtrl.clear();
      openingStockCtrl.clear();
      selectedProductId = null;

      setState(() {});
    } catch (e, s) {
      debugPrint('SHADE SAVE ERROR: $e');
      debugPrint(s.toString());
      _msg('Failed to save shade');
    } finally {
      if (mounted) setState(() => saving = false);
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

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shade Master'),
        actions: [
          IconButton(
            tooltip: 'Export Excel',
            onPressed: saving ? null : _exportToExcel,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Import Excel',
            onPressed: saving ? null : _importFromExcel,
            icon: const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // SHADE TYPE SELECTOR
                Row(
                  children: ShadeType.values.map((t) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(t == ShadeType.thread
                            ? 'Thread Shade'
                            : 'Fabric Shade'),
                        selected: selectedType == t,
                        onSelected: (_) {
                          setState(() {
                            selectedType = t;
                            selectedProductId = null;
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.shade100),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Excel Import',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Column A: Shade No, Column B: Opening Stock Qty (for Fabric)',
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: saving ? null : _importFromExcel,
                          icon: const Icon(Icons.upload_file),
                          label: const Text('IMPORT SHADES FROM EXCEL'),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // THREAD SHADE FIELDS
                if (selectedType == ShadeType.thread) ...[
                  TextFormField(
                    controller: shadeNoCtrl,
                    decoration: const InputDecoration(labelText: 'Shade No'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: companyCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Company Name'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Opening stock is available in Fabric Shade section.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],

                // FABRIC SHADE FIELDS
                if (selectedType == ShadeType.fabric) ...[
                  DropdownButtonFormField<int>(
                    value: selectedProductId,
                    decoration:
                        const InputDecoration(labelText: 'Product Name'),
                    items: products
                        .map(
                          (p) => DropdownMenuItem<int>(
                            value: p['id'] as int,
                            child: Text((p['name'] ?? '').toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => selectedProductId = v),
                    validator: (v) =>
                        selectedType == ShadeType.fabric && v == null
                            ? 'Required'
                            : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: shadeNoCtrl,
                    decoration: const InputDecoration(labelText: 'Shade No'),
                    validator: (v) => selectedType == ShadeType.fabric &&
                            (v == null || v.isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: openingStockCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Opening Stock Qty (optional)',
                      helperText:
                          'Used when saving shade; for Excel import, use column B',
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // SAVE BUTTON
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: saving ? null : _saveShade,
                    child: Text(saving ? 'SAVING...' : 'SAVE SHADE'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    shadeNoCtrl.dispose();
    companyCtrl.dispose();
    openingStockCtrl.dispose();
    super.dispose();
  }
}
