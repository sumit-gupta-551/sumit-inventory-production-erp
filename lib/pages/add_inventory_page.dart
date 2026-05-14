import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telephony/telephony.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';
import '../widgets/inventory_form_card.dart';
import 'firm_inventory_history_page.dart';

class AddInventoryPage extends StatefulWidget {
  final int firmId;

  const AddInventoryPage({
    super.key,
    required this.firmId,
  });

  @override
  State<AddInventoryPage> createState() => _AddInventoryPageState();
}

enum SyncState { idle, syncing, synced, error }

class _AddInventoryPageState extends State<AddInventoryPage> {
  SyncState _syncState = SyncState.idle;
  static const String _defaultReportMobile = '919999999999';
  static const String _reportMobilePrefKey = 'auto_report_mobile';
  static const String _smsSettingsPasscode = '0056';
  final Telephony _telephony = Telephony.instance;
  String _autoReportMobile = _defaultReportMobile;

  // ---------------- CONTROLLERS ----------------
  final dateCtrl = TextEditingController();
  final invoiceCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();

  final shadeFocusNode = FocusNode();
  final qtyFocusNode = FocusNode();

  // ---------------- MASTER DATA ----------------
  List<Product> products = [];
  Product? selectedProduct;

  List<Party> parties = [];
  Party? selectedParty;

  List<Map<String, dynamic>> fabricShades = [];
  final Map<int, Set<int>> productShadeIds = {};
  int? selectedFabricShadeId;
  final Set<int> selectedFabricShadeIds = <int>{};
  final Map<int, double> selectedShadeQtyById = <int, double>{};
  int? editingItemIndex;
  bool mergeSameShadeLines = false;

  final List<Map<String, dynamic>> items = [];

  bool loading = true;

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadAutoReportMobile();
    _loadMasters();
    ErpDatabase.instance.dataVersion.addListener(_onDataChanged);
  }

  void _onDataChanged() {
    if (!mounted) return;
    _loadMasters();
  }

  Future<void> _loadAutoReportMobile() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_reportMobilePrefKey)?.trim() ?? '';
    if (!mounted) return;
    setState(() {
      _autoReportMobile =
          saved.isEmpty ? _defaultReportMobile : saved.replaceAll(' ', '');
    });
  }

  Future<void> _openAutoSmsSettings() async {
    final passCtrl = TextEditingController();
    final passOk = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Enter Passcode'),
          content: TextField(
            controller: passCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Passcode',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verify'),
            ),
          ],
        );
      },
    );

    if (passOk != true) return;
    if (passCtrl.text.trim() != _smsSettingsPasscode) {
      _msg('Invalid passcode');
      return;
    }

    if (!mounted) return;

    final ctrl = TextEditingController(text: _autoReportMobile);

    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Auto SMS Number'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Number with country code',
              hintText: 'e.g. 919876543210',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Clear'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (saved == null) return;

    final prefs = await SharedPreferences.getInstance();
    final next = saved.replaceAll(' ', '');

    if (next.isEmpty) {
      await prefs.remove(_reportMobilePrefKey);
      if (!mounted) return;
      setState(() => _autoReportMobile = _defaultReportMobile);
      _msg('Auto SMS number reset to default');
      return;
    }

    await prefs.setString(_reportMobilePrefKey, next);
    if (!mounted) return;
    setState(() => _autoReportMobile = next);
    _msg('Auto SMS number updated');
  }

  Future<void> _loadMasters() async {
    try {
      final db = await ErpDatabase.instance.database;
      final results = await Future.wait([
        ErpDatabase.instance.getProducts(),
        ErpDatabase.instance.getParties(),
        ErpDatabase.instance.getFabricShades(),
        db.rawQuery('''
          SELECT DISTINCT product_id, shade_id
          FROM purchase_items
          WHERE product_id IS NOT NULL AND shade_id IS NOT NULL
        '''),
      ]);
      final p = results[0] as List<Product>;
      final pa = (results[1] as List<Party>)
          .where((p) => p.partyType == 'Purchase')
          .toList();
      final fs = results[2] as List<Map<String, dynamic>>;
      final links = results[3] as List<Map<String, dynamic>>;

      final map = <int, Set<int>>{};
      for (final r in links) {
        final pid = r['product_id'] as int?;
        final sid = r['shade_id'] as int?;
        if (pid == null || sid == null) continue;
        map.putIfAbsent(pid, () => <int>{}).add(sid);
      }

      if (!mounted) return;

      setState(() {
        products = p;
        parties = pa;
        fabricShades = fs;
        productShadeIds
          ..clear()
          ..addAll(map);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
      });
      _msg('Error loading masters: $e');
    }
  }

  int _dateMillis() {
    try {
      return DateFormat('dd-MM-yyyy')
          .parse(dateCtrl.text)
          .millisecondsSinceEpoch;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  Future<void> _pickPurchaseDate() async {
    final initial = () {
      try {
        return DateFormat('dd-MM-yyyy').parse(dateCtrl.text);
      } catch (_) {
        return DateTime.now();
      }
    }();

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (picked == null || !mounted) return;

    setState(() {
      dateCtrl.text = DateFormat('dd-MM-yyyy').format(picked);
    });
  }

  // ---------------- ADD ITEM ----------------
  void _addItem() {
    if (selectedProduct == null) {
      _msg('Select product first');
      return;
    }

    if (editingItemIndex == null && selectedFabricShadeIds.isEmpty) {
      _msg('Select shade');
      return;
    }

    if (editingItemIndex != null && selectedFabricShadeId == null) {
      _msg('Select shade');
      return;
    }

    final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;

    setState(() {
      if (editingItemIndex != null) {
        if (qty <= 0) {
          _msg('Enter valid ${selectedProduct?.unit ?? 'qty'}');
          return;
        }
        final shadeId = selectedFabricShadeId!;
        items[editingItemIndex!] = {
          'shade_id': shadeId,
          'shade_no': _shadeLabel(shadeId),
          'qty': qty,
        };
      } else {
        if (selectedFabricShadeIds.length > 1) {
          final invalid = selectedFabricShadeIds.any(
            (id) => (selectedShadeQtyById[id] ?? 0) <= 0,
          );
          if (invalid) {
            _msg(
                'Enter ${selectedProduct?.unit ?? 'qty'} for each selected shade');
            return;
          }
        }

        for (final shadeId in selectedFabricShadeIds) {
          final rowQty = selectedFabricShadeIds.length > 1
              ? (selectedShadeQtyById[shadeId] ?? 0)
              : ((selectedShadeQtyById[shadeId] ?? 0) > 0
                  ? (selectedShadeQtyById[shadeId] ?? 0)
                  : qty);

          if (rowQty <= 0) {
            _msg('Enter valid ${selectedProduct?.unit ?? 'qty'}');
            return;
          }

          final row = {
            'shade_id': shadeId,
            'shade_no': _shadeLabel(shadeId),
            'qty': rowQty,
          };

          if (mergeSameShadeLines) {
            final existingIndex = items.indexWhere(
              (e) => e['shade_id'] == shadeId,
            );

            if (existingIndex >= 0) {
              final existingQty =
                  (items[existingIndex]['qty'] as num).toDouble();
              final mergedQty = existingQty + rowQty;

              items[existingIndex] = {
                'shade_id': shadeId,
                'shade_no': _shadeLabel(shadeId),
                'qty': mergedQty,
              };
            } else {
              items.add(row);
            }
          } else {
            items.add(row);
          }
        }
      }

      editingItemIndex = null;
      selectedFabricShadeId = null;
      selectedFabricShadeIds.clear();
      selectedShadeQtyById.clear();
      qtyCtrl.clear();
    });

    FocusScope.of(context).requestFocus(shadeFocusNode);
  }

  void _startEditItem(int index) {
    final item = items[index];
    setState(() {
      editingItemIndex = index;
      selectedFabricShadeId = item['shade_id'] as int?;
      selectedFabricShadeIds
        ..clear()
        ..add((item['shade_id'] as int?) ?? -1)
        ..remove(-1);
      selectedShadeQtyById
        ..clear()
        ..addAll({
          if (item['shade_id'] is int)
            item['shade_id'] as int: (item['qty'] as num).toDouble(),
        });
      qtyCtrl.text = (item['qty'] as num).toString();
    });

    FocusScope.of(context).requestFocus(qtyFocusNode);
  }

  void _cancelEditItem() {
    setState(() {
      editingItemIndex = null;
      selectedFabricShadeId = null;
      selectedFabricShadeIds.clear();
      selectedShadeQtyById.clear();
      qtyCtrl.clear();
    });

    FocusScope.of(context).requestFocus(shadeFocusNode);
  }

  // ---------------- TOTAL MTR ----------------
  double get _totalMtr {
    return items.fold<double>(
      0,
      (sum, item) => sum + ((item['qty'] as num?)?.toDouble() ?? 0),
    );
  }

  String _shadeLabel(int? shadeId) {
    if (shadeId == null) return '';
    final shade = fabricShades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == shadeId,
          orElse: () => null,
        );
    if (shade == null) return '';

    return shade['shade_no']?.toString() ?? '';
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

  List<Map<String, dynamic>> _filteredShadesForProduct() {
    if (selectedProduct == null) return [];

    final byProductName = fabricShades.where((s) {
      final n = (s['shade_name'] ?? '').toString().trim().toLowerCase();
      return n == selectedProduct!.name.trim().toLowerCase();
    });

    final linkedIds = selectedProduct!.id == null
        ? <int>{}
        : (productShadeIds[selectedProduct!.id!] ?? <int>{});

    final byHistory = fabricShades.where((s) {
      final id = s['id'] as int?;
      return id != null && linkedIds.contains(id);
    });

    final merged = <int, Map<String, dynamic>>{};
    for (final s in byProductName) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }
    for (final s in byHistory) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }

    final list = merged.values.toList();
    list.sort((a, b) {
      final aNo = (a['shade_no'] ?? '').toString();
      final bNo = (b['shade_no'] ?? '').toString();
      final aNum = num.tryParse(aNo);
      final bNum = num.tryParse(bNo);
      if (aNum != null && bNum != null) return aNum.compareTo(bNum);
      return aNo.compareTo(bNo);
    });
    return list;
  }

  List<Map<String, dynamic>> _shadesForProduct(Product product) {
    final byProductName = fabricShades.where((s) {
      final n = (s['shade_name'] ?? '').toString().trim().toLowerCase();
      return n == product.name.trim().toLowerCase();
    });

    final linkedIds = product.id == null
        ? <int>{}
        : (productShadeIds[product.id!] ?? <int>{});

    final byHistory = fabricShades.where((s) {
      final id = s['id'] as int?;
      return id != null && linkedIds.contains(id);
    });

    final merged = <int, Map<String, dynamic>>{};
    for (final s in byProductName) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }
    for (final s in byHistory) {
      final id = s['id'] as int?;
      if (id != null) merged[id] = s;
    }

    final list = merged.values.toList();
    list.sort((a, b) {
      final aNo = (a['shade_no'] ?? '').toString();
      final bNo = (b['shade_no'] ?? '').toString();
      final aNum = num.tryParse(aNo);
      final bNum = num.tryParse(bNo);
      if (aNum != null && bNum != null) return aNum.compareTo(bNum);
      return aNo.compareTo(bNo);
    });
    return list;
  }

  // ---------------- SCAN / OCR HELPERS ----------------
  String _scanValue(Map<String, String> data, List<String> keys) {
    for (final key in keys) {
      final v = data[key.toLowerCase()];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  String _compact(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _normalizedKey(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  double _diceSimilarity(String a, String b) {
    final x = _normalizedKey(a);
    final y = _normalizedKey(b);
    if (x.isEmpty || y.isEmpty) return 0;
    if (x == y) return 1;

    Set<String> bigrams(String s) {
      if (s.length < 2) return {s};
      final out = <String>{};
      for (var i = 0; i < s.length - 1; i++) {
        out.add(s.substring(i, i + 2));
      }
      return out;
    }

    final bx = bigrams(x);
    final by = bigrams(y);
    var inter = 0;
    for (final g in bx) {
      if (by.contains(g)) inter++;
    }
    return (2 * inter) / (bx.length + by.length);
  }

  String _bestMasterMatch(
    String token,
    Iterable<String> source, {
    required double threshold,
    bool fallbackToInput = true,
  }) {
    final clean = _compact(token);
    if (clean.isEmpty) return '';

    final cleanNorm = _normalizedKey(clean);
    if (cleanNorm.isEmpty) return clean;

    String best = clean;
    var bestScore = 0.0;

    for (final raw in source) {
      final name = _compact(raw);
      if (name.isEmpty) continue;

      final nameNorm = _normalizedKey(name);
      if (nameNorm.isEmpty) continue;

      if (nameNorm == cleanNorm) {
        return name;
      }

      var score = _diceSimilarity(cleanNorm, nameNorm);
      if (nameNorm.contains(cleanNorm) || cleanNorm.contains(nameNorm)) {
        final shorter = cleanNorm.length < nameNorm.length
            ? cleanNorm.length
            : nameNorm.length;
        final longer = cleanNorm.length > nameNorm.length
            ? cleanNorm.length
            : nameNorm.length;
        final containScore = longer == 0 ? 0.0 : shorter / longer;
        if (containScore > score) score = containScore;
      }

      if (score > bestScore) {
        bestScore = score;
        best = name;
      }
    }

    if (bestScore >= threshold) return best;
    return fallbackToInput ? clean : '';
  }

  String _cleanInvoiceText(String value) {
    var v = _compact(value)
        .replaceAll(' ', '')
        .replaceFirst(RegExp(r'^[#:\-/._]+'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9\-/._]'), '');
    if (v.isEmpty) return '';

    final lower = v.toLowerCase();
    if ({'lr', 'bill', 'invoice', 'challan', 'inv', 'no'}.contains(lower)) {
      return '';
    }

    final hasDigit = RegExp(r'\d').hasMatch(v);
    if (!hasDigit && v.length < 5) return '';
    return v;
  }

  String _cleanPartyText(String value) {
    var v = _compact(value);
    if (v.isEmpty) return '';

    v = v.replaceFirst(
      RegExp(
        r'^(?:party|vendor|supplier|seller|from|consignor|bill\s*from|buyer|bill\s*to|sold\s*to|customer)\s*[:\-]?\s*',
        caseSensitive: false,
      ),
      '',
    );

    v = v.replaceFirst(
      RegExp(r'^(?:m\s*/?\s*s\.?\s*)', caseSensitive: false),
      'M/s ',
    );

    final breakAt = RegExp(
      r'\b(?:gstin|gst|state\s*code|mobile|mob|phone|tel|address|addr|invoice|date)\b',
      caseSensitive: false,
    ).firstMatch(v);
    if (breakAt != null && breakAt.start > 0) {
      v = v.substring(0, breakAt.start).trim();
    }

    v = v.replaceAll(RegExp(r'[,;:\-]+$'), '').trim();
    return v;
  }

  String _cleanShadeText(String value) {
    var v = _compact(value);
    if (v.isEmpty) return '';

    v = v
        .replaceFirst(
          RegExp(
            r'^(?:shade\s*(?:no|number|#)?|colour|color)\s*[:\-]?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'^[\s\-/.,:]+'), '')
        .replaceAll(RegExp(r'[\s\-/.,:]+$'), '')
        .trim();

    if (v.isEmpty) return '';
    if (RegExp(r'^(?:no|n/?a|na|nil|none)$', caseSensitive: false)
        .hasMatch(v)) {
      return '';
    }
    if (v.length < 2 && !RegExp(r'\d').hasMatch(v)) return '';
    return v;
  }

  String _extractFirstNumber(String value) {
    final m = RegExp(r'\d+(?:\.\d+)?').firstMatch(value);
    return m?.group(0) ?? '';
  }

  String _valueFromLineForTarget(String target, String line) {
    switch (target) {
      case 'invoice':
        return _cleanInvoiceText(line);
      case 'date':
        final m = RegExp(
          r'((?:\d{1,2}[\/\.\-]\d{1,2}[\/\.\-]\d{2,4})|(?:\d{4}[\/\.\-]\d{1,2}[\/\.\-]\d{1,2}))',
        ).firstMatch(line);
        return _normalizeDateForField(m?.group(1) ?? line);
      case 'party':
        return _bestMasterMatch(
          _cleanPartyText(line),
          parties.map((e) => e.name),
          threshold: 0.84,
          fallbackToInput: true,
        );
      case 'product':
        return _bestMasterMatch(
          _compact(line),
          products.map((e) => e.name),
          threshold: 0.80,
          fallbackToInput: true,
        );
      case 'shade':
        return _cleanShadeText(line);
      case 'qty':
        return _extractFirstNumber(line);
      default:
        return _compact(line);
    }
  }

  Map<String, String> _extractLineItemFromText(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((e) => _compact(e))
        .where((e) => e.isNotEmpty)
        .toList();

    for (final line in lines) {
      if (!RegExp(r'^\d+\s+').hasMatch(line)) continue;

      final tokens = line.split(RegExp(r'\s+'));
      if (tokens.length < 4) continue;

      final numeric = <int>[];
      for (var i = 0; i < tokens.length; i++) {
        if (RegExp(r'^\d+(?:\.\d+)?$').hasMatch(tokens[i])) {
          numeric.add(i);
        }
      }

      if (numeric.length < 2) continue;

      final result = <String, String>{};

      final qty = tokens[numeric.last];
      final shade = tokens[numeric[0]];

      const itemStart = 1;
      final itemEnd = numeric[0];
      if (itemEnd > itemStart) {
        final item = tokens.sublist(itemStart, itemEnd).join(' ').trim();
        if (item.isNotEmpty) {
          result['product'] = item;
        }
      }

      if (shade.isNotEmpty) result['shade'] = shade;
      if (qty.isNotEmpty) result['qty'] = qty;

      if (result.isNotEmpty) {
        return result;
      }
    }

    return <String, String>{};
  }

  Map<String, String> _parseScanPayload(String raw) {
    final text = raw.trim();
    final out = <String, String>{};

    try {
      if (text.startsWith('{') && text.endsWith('}')) {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString().trim().toLowerCase();
            final val = entry.value?.toString().trim() ?? '';
            if (key.isNotEmpty && val.isNotEmpty) {
              out[key] = val;
            }
          }
          return out;
        }
      }
    } catch (_) {}

    final parts = text.split(RegExp(r'[\n|;,]+'));
    for (final p in parts) {
      final seg = p.trim();
      if (seg.isEmpty) continue;

      final sep = seg.contains(':') ? ':' : (seg.contains('=') ? '=' : '');
      if (sep.isEmpty) continue;

      final i = seg.indexOf(sep);
      if (i <= 0) continue;
      final key = seg.substring(0, i).trim().toLowerCase();
      final val = seg.substring(i + 1).trim();
      if (key.isNotEmpty && val.isNotEmpty) {
        out[key] = val;
      }
    }

    return out;
  }

  // ignore: unused_element
  Map<String, String> _scanDataFromRaw(String raw) {
    final parsed = _parseScanPayload(raw);
    if (parsed.isNotEmpty) return parsed;
    return _extractFieldsFromInvoiceText(raw);
  }

  Party? _findPartyByToken(String token) {
    final t = token.trim().toLowerCase();
    if (t.isEmpty) return null;

    for (final p in parties) {
      if (p.name.trim().toLowerCase() == t) return p;
    }
    for (final p in parties) {
      if (p.name.trim().toLowerCase().contains(t)) return p;
    }
    return null;
  }

  Future<bool> _confirmAddMaster({
    required String title,
    required String message,
  }) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, Add'),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<Party?> _ensurePartyFromScan(String token) async {
    final clean = token.trim();
    if (clean.isEmpty) return null;

    final existing = _findPartyByToken(clean);
    if (existing != null) return existing;

    final shouldAdd = await _confirmAddMaster(
      title: 'New Party Found',
      message: 'Party "$clean" not found. Add it now?',
    );
    if (!shouldAdd) return null;

    await ErpDatabase.instance.insertParty(
      Party(name: clean, address: '', mobile: ''),
    );
    await _loadMasters();
    return _findPartyByToken(clean);
  }

  Product? _findProductByToken(String token) {
    final t = token.trim().toLowerCase();
    if (t.isEmpty) return null;

    for (final p in products) {
      if (p.name.trim().toLowerCase() == t) return p;
    }
    for (final p in products) {
      if (p.name.trim().toLowerCase().contains(t)) return p;
    }
    return null;
  }

  Future<Product?> _ensureProductFromScan(String token) async {
    final clean = token.trim();
    if (clean.isEmpty) return null;

    final existing = _findProductByToken(clean);
    if (existing != null) return existing;

    final shouldAdd = await _confirmAddMaster(
      title: 'New Product Found',
      message: 'Product "$clean" not found. Add it now?',
    );
    if (!shouldAdd) return null;

    await ErpDatabase.instance.insertProductRaw({
      'name': clean,
      'category': 'Fabric',
      'unit': 'Mtr',
      'min_stock': 0,
    });
    await _loadMasters();
    return _findProductByToken(clean);
  }

  int? _findShadeIdForProduct(Product product, String token) {
    final t = token.trim().toLowerCase();
    if (t.isEmpty) return null;

    final shades = _shadesForProduct(product);
    for (final s in shades) {
      if ((s['shade_no'] ?? '').toString().trim().toLowerCase() == t) {
        return s['id'] as int?;
      }
    }
    for (final s in shades) {
      if ((s['shade_no'] ?? '').toString().trim().toLowerCase().contains(t)) {
        return s['id'] as int?;
      }
    }
    return null;
  }

  Future<int?> _ensureShadeForProductFromScan(
    Product product,
    String token,
  ) async {
    final clean = token.trim();
    if (clean.isEmpty) return null;

    final existing = _findShadeIdForProduct(product, clean);
    if (existing != null) return existing;

    final shouldAdd = await _confirmAddMaster(
      title: 'New Shade Found',
      message:
          'Shade "$clean" not found for product "${product.name}". Add it now?',
    );
    if (!shouldAdd) return null;

    final shadeId = await ErpDatabase.instance.insertFabricShadeReturningId(
      shadeNo: clean,
      shadeName: product.name,
      imagePath: null,
    );
    await _loadMasters();
    return shadeId;
  }

  String _normalizeDateForField(String token) {
    final raw = token.trim();
    if (raw.isEmpty) return '';

    final cleaned = raw.replaceAll('.', '-').replaceAll('/', '-');

    DateTime? parsed;
    final ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(cleaned);
    if (ymd != null) {
      final y = int.tryParse(ymd.group(1)!);
      final m = int.tryParse(ymd.group(2)!);
      final d = int.tryParse(ymd.group(3)!);
      if (y != null && m != null && d != null) {
        parsed = DateTime(y, m, d);
      }
    }

    if (parsed == null) {
      final dmy =
          RegExp(r'^(\d{1,2})-(\d{1,2})-(\d{2,4})$').firstMatch(cleaned);
      if (dmy != null) {
        final d = int.tryParse(dmy.group(1)!);
        final m = int.tryParse(dmy.group(2)!);
        var y = int.tryParse(dmy.group(3)!);
        if (y != null && y < 100) {
          y += 2000;
        }
        if (y != null && m != null && d != null) {
          parsed = DateTime(y, m, d);
        }
      }
    }

    if (parsed == null) return '';
    return DateFormat('dd-MM-yyyy').format(parsed);
  }

  Map<String, String> _extractFieldsFromInvoiceText(String text) {
    final out = <String, String>{};
    final normalized = text.trim();
    if (normalized.isEmpty) return out;
    final lower = normalized.toLowerCase();

    final invoiceMatch = RegExp(
      r'(?:invoice\s*no|inv\s*no|bill\s*no|challan\s*no|bill|challan)\s*[:\-#.]?\s*([A-Za-z0-9\/_\-.]+)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (invoiceMatch != null) {
      final v = _cleanInvoiceText(invoiceMatch.group(1) ?? '');
      if (v.isNotEmpty) out['invoice'] = v;
    }

    final dateMatch = RegExp(
      r'(?:invoice\s*date|bill\s*date|date|lr\s*date)\s*[:\-]?\s*((?:\d{1,2}[\/.\-]\d{1,2}[\/.\-]\d{2,4})|(?:\d{4}[\/.\-]\d{1,2}[\/.\-]\d{1,2}))',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (dateMatch != null) {
      final dateText = (dateMatch.group(1) ?? '').trim();
      final dateVal = _normalizeDateForField(dateText);
      if (dateVal.isNotEmpty) out['date'] = dateVal;
    }

    final supplierPartyMatch = RegExp(
      r'(?:supplier|vendor|seller|consignor|from|bill\s*from|party\s*name|party)\s*[:\-]?\s*([^\n\r|]{2,})',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (supplierPartyMatch != null) {
      final party = _bestMasterMatch(
        _cleanPartyText(supplierPartyMatch.group(1) ?? ''),
        parties.map((e) => e.name),
        threshold: 0.84,
        fallbackToInput: false,
      );
      if (party.isNotEmpty) out['party'] = party;
    }

    if (!out.containsKey('party')) {
      final genericPartyMatch = RegExp(
        r'(?:buyer|bill\s*to|sold\s*to|customer)\s*[:\-]?\s*([^\n\r|]{2,})',
        caseSensitive: false,
      ).firstMatch(normalized);
      if (genericPartyMatch != null) {
        final party = _bestMasterMatch(
          _cleanPartyText(genericPartyMatch.group(1) ?? ''),
          parties.map((e) => e.name),
          threshold: 0.90,
          fallbackToInput: false,
        );
        if (party.isNotEmpty) out['party'] = party;
      }
    }

    if (!out.containsKey('party')) {
      final lines = normalized
          .split(RegExp(r'[\r\n]+'))
          .map((e) => _compact(e))
          .where((e) => e.isNotEmpty)
          .toList();

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];

        final tagged = RegExp(
          r'^(?:supplier|vendor|seller|consignor|from|bill\s*from|party\s*name|party)\b\s*[:\-]?\s*(.*)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (tagged != null) {
          var candidate = tagged.group(1)?.trim() ?? '';
          if (candidate.isEmpty && i + 1 < lines.length) {
            candidate = lines[i + 1];
          }
          final party = _cleanPartyText(candidate);
          if (party.isNotEmpty) {
            out['party'] = _bestMasterMatch(
              party,
              parties.map((e) => e.name),
              threshold: 0.84,
              fallbackToInput: false,
            );
            break;
          }
        }

        if (RegExp(r'^(?:m\s*/?\s*s\.?)\s+.+', caseSensitive: false)
            .hasMatch(line)) {
          final party = _cleanPartyText(line);
          if (party.isNotEmpty) {
            out['party'] = _bestMasterMatch(
              party,
              parties.map((e) => e.name),
              threshold: 0.84,
              fallbackToInput: false,
            );
            break;
          }
        }
      }
    }

    if (!out.containsKey('invoice')) {
      final lines = normalized.split(RegExp(r'[\r\n]+'));
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final lower = line.toLowerCase();
        if (!lower.contains('invoice') &&
            !lower.contains('inv') &&
            !lower.contains('bill')) {
          continue;
        }

        final tokenMatch = RegExp(r'([A-Za-z0-9][A-Za-z0-9\/_\-.]{2,})')
            .allMatches(line)
            .toList();
        if (tokenMatch.isNotEmpty) {
          final last = tokenMatch.last.group(1)?.trim() ?? '';
          final cleanedInvoice = _cleanInvoiceText(last);
          if (cleanedInvoice.isNotEmpty) {
            out['invoice'] = cleanedInvoice;
            break;
          }
        }
      }
    }

    final productMatch = RegExp(
      r'(?:product|item|fabric|quality)\s*[:\-]\s*([^\n\r|]{2,})',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (productMatch != null) {
      final product = _bestMasterMatch(
        _compact(productMatch.group(1) ?? ''),
        products.map((e) => e.name),
        threshold: 0.80,
        fallbackToInput: false,
      );
      if (product.isNotEmpty) out['product'] = product;
    }

    final shadeMatch = RegExp(
      r'(?:shade\s*(?:no|number|#)?|colour|color)\s*[:\-]?\s*([A-Za-z0-9\/_\-.]+)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (shadeMatch != null) {
      final shade = _cleanShadeText(shadeMatch.group(1) ?? '');
      if (shade.isNotEmpty) out['shade'] = shade;
    }

    final qtyMatch = RegExp(
      r'(?:qty|quantity|mtr|meter|metre)\s*[:\-]?\s*([0-9]+(?:\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (qtyMatch != null) {
      final qty = (qtyMatch.group(1) ?? '').trim();
      if (qty.isNotEmpty) out['qty'] = qty;
    }

    if (!out.containsKey('party')) {
      for (final p in parties) {
        final name = p.name.trim();
        if (name.isEmpty) continue;
        if (lower.contains(name.toLowerCase())) {
          out['party'] = name;
          break;
        }
      }
    }

    if (!out.containsKey('product')) {
      for (final p in products) {
        final name = p.name.trim();
        if (name.isEmpty) continue;
        if (lower.contains(name.toLowerCase())) {
          out['product'] = name;
          break;
        }
      }
    }

    final itemRow = _extractLineItemFromText(normalized);
    if (itemRow.containsKey('product') && !out.containsKey('product')) {
      out['product'] = itemRow['product']!;
    }
    if (itemRow.containsKey('shade') && !out.containsKey('shade')) {
      final shade = _cleanShadeText(itemRow['shade']!);
      if (shade.isNotEmpty) out['shade'] = shade;
    }
    if (itemRow.containsKey('qty') && !out.containsKey('qty')) {
      out['qty'] = itemRow['qty']!;
    }

    return out;
  }

  // ignore: unused_element
  Future<Map<String, String>?> _reviewScanData(
    Map<String, String> data, {
    String fullText = '',
  }) async {
    final invoiceCtrl = TextEditingController(
      text: _scanValue(data, ['invoice', 'invoice_no', 'inv', 'bill_no']),
    );
    final dateCtrlLocal = TextEditingController(
      text: _scanValue(data, ['date', 'invoice_date', 'bill_date', 'dt']),
    );
    final partyCtrl = TextEditingController(
      text: _scanValue(data, [
        'party',
        'party_name',
        'vendor',
        'supplier',
        'seller',
        'consignor',
        'from',
      ]),
    );
    final productCtrl = TextEditingController(
      text: _scanValue(data, ['product', 'product_name', 'item', 'fabric']),
    );
    final shadeCtrl = TextEditingController(
      text: _scanValue(data, ['shade', 'shade_no', 'shadeno']),
    );
    final qtyCtrlLocal = TextEditingController(
      text: _scanValue(data, ['qty', 'quantity', 'mtr']),
    );

    final lines = fullText
        .split(RegExp(r'[\r\n]+'))
        .map((e) => _compact(e))
        .where((e) => e.isNotEmpty)
        .toList();

    TextEditingController controllerFor(String key) {
      switch (key) {
        case 'invoice':
          return invoiceCtrl;
        case 'date':
          return dateCtrlLocal;
        case 'party':
          return partyCtrl;
        case 'product':
          return productCtrl;
        case 'shade':
          return shadeCtrl;
        case 'qty':
          return qtyCtrlLocal;
        default:
          return partyCtrl;
      }
    }

    final reviewed = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        var targetField = 'party';
        return StatefulBuilder(
          builder: (ctx, setLocalState) {
            return AlertDialog(
              title: const Text('Review Scanned Data'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: invoiceCtrl,
                        decoration: InputDecoration(
                          labelText: 'Bill No',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'invoice';
                                    });
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: dateCtrlLocal,
                        decoration: InputDecoration(
                          labelText: 'Date',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'date';
                                    });
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: partyCtrl,
                        decoration: InputDecoration(
                          labelText: 'Party',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'party';
                                    });
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: productCtrl,
                        decoration: InputDecoration(
                          labelText: 'Product',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'product';
                                    });
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: shadeCtrl,
                        decoration: InputDecoration(
                          labelText: 'Shade',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'shade';
                                    });
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: qtyCtrlLocal,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: selectedProduct?.unit ?? 'Qty',
                          suffixIcon: lines.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Pick from text',
                                  icon: const Icon(Icons.touch_app_outlined),
                                  onPressed: () {
                                    setLocalState(() {
                                      targetField = 'qty';
                                    });
                                  },
                                ),
                        ),
                      ),
                      if (lines.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Full Page Text',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Tap field pick icon or chip, then tap a line to use it.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            ('invoice', 'Bill No'),
                            ('date', 'Date'),
                            ('party', 'Party'),
                            ('product', 'Product'),
                            ('shade', 'Shade'),
                            ('qty', selectedProduct?.unit ?? 'Qty'),
                          ].map((e) {
                            final key = e.$1;
                            return ChoiceChip(
                              label: Text(e.$2),
                              selected: targetField == key,
                              onSelected: (_) {
                                setLocalState(() {
                                  targetField = key;
                                });
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 180,
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: const Color.fromARGB(31, 225, 228, 223)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListView.separated(
                            itemCount: lines.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final line = lines[i];
                              return ListTile(
                                dense: true,
                                visualDensity: const VisualDensity(
                                  vertical: -2,
                                ),
                                title: Text(
                                  line,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  final selected = _valueFromLineForTarget(
                                      targetField, line);
                                  if (selected.isEmpty) return;
                                  controllerFor(targetField).text = selected;
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx, {
                      'invoice': invoiceCtrl.text.trim(),
                      'date': dateCtrlLocal.text.trim(),
                      'party': partyCtrl.text.trim(),
                      'product': productCtrl.text.trim(),
                      'shade': shadeCtrl.text.trim(),
                      'qty': qtyCtrlLocal.text.trim(),
                    });
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );

    return reviewed;
  }

  // ignore: unused_element
  Future<void> _applyReviewedEntry(
    Map<String, String> reviewed, {
    required String sourceLabel,
  }) async {
    final data = <String, String>{};
    reviewed.forEach((k, v) {
      final value = v.trim();
      if (value.isNotEmpty) data[k.toLowerCase()] = value;
    });

    final invoice = _cleanInvoiceText(_scanValue(data, [
      'invoice',
      'invoice_no',
      'inv',
      'bill',
      'bill_no',
    ]));
    final partyToken = _bestMasterMatch(
      _cleanPartyText(_scanValue(data, [
        'party',
        'party_name',
        'vendor',
        'supplier',
        'seller',
        'consignor',
        'from',
      ])),
      parties.map((e) => e.name),
      threshold: 0.84,
      fallbackToInput: true,
    );
    final dateToken =
        _scanValue(data, ['date', 'invoice_date', 'bill_date', 'dt']);
    final productToken = _bestMasterMatch(
      _compact(_scanValue(data, ['product', 'product_name', 'item', 'fabric'])),
      products.map((e) => e.name),
      threshold: 0.80,
      fallbackToInput: true,
    );
    final shadeToken = _cleanShadeText(
      _scanValue(data, ['shade', 'shade_no', 'shade number', 'shadeno']),
    );
    final qtyToken = _scanValue(data, ['qty', 'quantity', 'mtr']);

    Party? nextParty;
    if (partyToken.isNotEmpty) {
      nextParty = await _ensurePartyFromScan(partyToken);
    }

    Product? nextProduct;
    if (productToken.isNotEmpty) {
      nextProduct = await _ensureProductFromScan(productToken);
    }

    int? nextShadeId;
    if (nextProduct != null && shadeToken.isNotEmpty) {
      nextShadeId = await _ensureShadeForProductFromScan(
        nextProduct,
        shadeToken,
      );
    }

    final parsedQty = double.tryParse(qtyToken.trim());
    final parsedDate = _normalizeDateForField(dateToken);

    setState(() {
      editingItemIndex = null;

      if (invoice.isNotEmpty) {
        invoiceCtrl.text = invoice;
      }
      if (parsedDate.isNotEmpty) {
        dateCtrl.text = parsedDate;
      }
      if (nextParty != null) {
        selectedParty = nextParty;
      }
      if (nextProduct != null) {
        selectedProduct = nextProduct;
        selectedFabricShadeId = null;
        selectedFabricShadeIds.clear();
        selectedShadeQtyById.clear();
      }
      if (nextShadeId != null) {
        selectedFabricShadeId = nextShadeId;
        selectedFabricShadeIds
          ..clear()
          ..add(nextShadeId);
      }
      if (parsedQty != null && parsedQty > 0) {
        qtyCtrl.text = parsedQty.toString();
        if (nextShadeId != null) {
          selectedShadeQtyById[nextShadeId] = parsedQty;
        }
      }
    });

    final readyForAutoAdd = nextProduct != null &&
        nextShadeId != null &&
        parsedQty != null &&
        parsedQty > 0;

    if (readyForAutoAdd) {
      _addItem();
    }

    final notices = <String>[];
    if (partyToken.isNotEmpty && nextParty == null) {
      notices.add('party not found');
    }
    if (productToken.isNotEmpty && nextProduct == null) {
      notices.add('product not found');
    }
    if (shadeToken.isNotEmpty && nextProduct != null && nextShadeId == null) {
      notices.add('shade not found for selected product');
    }

    if (notices.isEmpty) {
      _msg(readyForAutoAdd
          ? '$sourceLabel applied and item added.'
          : '$sourceLabel applied. Review and tap Add.');
    } else {
      _msg('$sourceLabel applied with notes: ${notices.join(', ')}');
    }
  }

  String _selectedShadesText() {
    if (editingItemIndex != null) {
      return selectedFabricShadeId == null
          ? 'Select Shade'
          : _shadeLabel(selectedFabricShadeId);
    }
    if (selectedFabricShadeIds.isEmpty) return 'Select Shade(s)';
    if (selectedFabricShadeIds.length == 1) {
      return _shadeLabel(selectedFabricShadeIds.first);
    }
    return '${selectedFabricShadeIds.length} shades selected';
  }

  Future<void> _openShadeMultiSelect() async {
    if (selectedProduct == null) {
      _msg('Select product first');
      return;
    }

    final source = _filteredShadesForProduct();
    if (source.isEmpty) {
      _msg('No shades found for selected product');
      return;
    }

    final temp = editingItemIndex != null
        ? <int>{if (selectedFabricShadeId != null) selectedFabricShadeId!}
        : Set<int>.from(selectedFabricShadeIds);
    final tempQtyById = Map<int, double>.from(selectedShadeQtyById);

    var shadeSearch = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final filtered = shadeSearch.isEmpty
                ? source
                : source.where((s) {
                    final no = (s['shade_no'] ?? '').toString().toLowerCase();
                    return no.contains(shadeSearch.toLowerCase());
                  }).toList();

            return AlertDialog(
              title: Text(
                editingItemIndex == null ? 'Select Shade(s)' : 'Select Shade',
              ),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search shade...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 10, horizontal: 12),
                      ),
                      onChanged: (v) => setDialogState(() => shadeSearch = v),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: filtered.map((s) {
                            final id = s['id'] as int;
                            final selected = temp.contains(id);
                            return Row(
                              children: [
                                Expanded(
                                  child: CheckboxListTile(
                                    value: selected,
                                    title:
                                        Text((s['shade_no'] ?? '').toString()),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    onChanged: (v) {
                                      setDialogState(() {
                                        if (editingItemIndex != null) {
                                          temp
                                            ..clear()
                                            ..add(id);
                                        } else {
                                          if (v == true) {
                                            temp.add(id);
                                          } else {
                                            temp.remove(id);
                                            tempQtyById.remove(id);
                                          }
                                        }
                                      });
                                    },
                                  ),
                                ),
                                if (editingItemIndex == null)
                                  SizedBox(
                                    width: 90,
                                    child: TextFormField(
                                      enabled: selected,
                                      initialValue: selected
                                          ? ((tempQtyById[id] ?? 0) == 0
                                              ? ''
                                              : (tempQtyById[id] ?? 0)
                                                  .toString())
                                          : '',
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      decoration: InputDecoration(
                                          labelText:
                                              selectedProduct?.unit ?? 'Qty'),
                                      onChanged: (v) {
                                        final q =
                                            double.tryParse(v.trim()) ?? 0;
                                        if (q > 0) {
                                          tempQtyById[id] = q;
                                        } else {
                                          tempQtyById.remove(id);
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      selectedFabricShadeIds
                        ..clear()
                        ..addAll(temp);
                      selectedShadeQtyById
                        ..clear()
                        ..addAll(tempQtyById);
                      selectedFabricShadeId = temp.isEmpty ? null : temp.first;
                    });
                    Navigator.pop(ctx);
                    FocusScope.of(context).requestFocus(qtyFocusNode);
                  },
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------- SAVE ----------------
  void _prepareNextEntry() {
    setState(() {
      invoiceCtrl.clear();
      items.clear();
      selectedFabricShadeId = null;
      selectedFabricShadeIds.clear();
      selectedShadeQtyById.clear();
      editingItemIndex = null;
      qtyCtrl.clear();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(shadeFocusNode);
    });
  }

  Future<void> _save() async {
    if (selectedParty == null || selectedProduct == null || items.isEmpty) {
      _msg('Fill all required fields');
      return;
    }

    try {
      setState(() => _syncState = SyncState.syncing);
      final purchaseNo = DateTime.now().millisecondsSinceEpoch;
      final db = ErpDatabase.instance;
      final savedInvoice = invoiceCtrl.text.trim();

      await db.insertPurchaseMaster({
        'purchase_no': purchaseNo,
        'firm_id': widget.firmId,
        'party_id': selectedParty!.id,
        'purchase_date': _dateMillis(),
        'invoice_no': savedInvoice,
        'gross_amount': 0,
        'discount_amount': 0,
        'cgst': 0,
        'sgst': 0,
        'igst': 0,
        'total_amount': 0,
      });

      for (final i in items) {
        await db.insertPurchaseItem({
          'purchase_no': purchaseNo,
          'product_id': selectedProduct!.id,
          'shade_id': i['shade_id'],
          'qty': i['qty'],
          'rate': 0,
          'amount': 0,
        });

        await db.insertLedger({
          'product_id': selectedProduct!.id,
          'fabric_shade_id': i['shade_id'],
          'qty': i['qty'],
          'type': 'IN',
          'date': _dateMillis(),
          'reference': savedInvoice,
          'remarks': 'Purchase',
        });
      }

      if (!mounted) return;

      // Capture data BEFORE clearing form for SMS & Firebase sync
      final savedDate = dateCtrl.text.trim().isEmpty
          ? DateFormat('dd-MM-yyyy').format(DateTime.now())
          : dateCtrl.text.trim();
      final savedPartyName = selectedParty?.name ?? '';
      final savedProductName = selectedProduct?.name ?? '';
      final savedUnit = selectedProduct?.unit ?? 'Qty';
      final savedTotalMtr = _totalMtr;
      final savedShadeLines = _buildShadeQtySummaryText();
      final savedItems = items
          .map((i) => {
                'shade_no': i['shade_no'] ?? _shadeLabel(i['shade_id'] as int?),
                'mtr': i['qty'],
              })
          .toList();

      _prepareNextEntry();
      _msg('Inventory saved. Ready for next entry.');

      // --- Firebase Realtime Database Sync ---
      try {
        final dbRef = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL:
              'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app',
        ).ref('inventory');

        final inventoryData = {
          'date': savedDate,
          'party_name': savedPartyName,
          'bill_no': savedInvoice,
          'product': savedProductName,
          'items': savedItems,
          'total_mtr': savedTotalMtr,
          'timestamp': ServerValue.timestamp,
        };
        await dbRef.push().set(inventoryData);
        if (mounted) setState(() => _syncState = SyncState.synced);
      } catch (e) {
        debugPrint('Firebase sync error: $e');
        if (mounted) setState(() => _syncState = SyncState.error);
      }

      await _autoSendInventoryMessage(
        invoiceNo: savedInvoice,
        date: savedDate,
        partyName: savedPartyName,
        productName: savedProductName,
        unit: savedUnit,
        shadeLines: savedShadeLines,
        totalMtr: savedTotalMtr,
      );
    } catch (e) {
      if (mounted) setState(() => _syncState = SyncState.error);
      _msg('Error saving inventory: $e');
    }
  }

  Future<void> _autoSendInventoryMessage({
    required String invoiceNo,
    required String date,
    required String partyName,
    required String productName,
    required String unit,
    required String shadeLines,
    required double totalMtr,
  }) async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS) {
      return;
    }

    try {
      final to = _autoReportMobile.trim();
      if (to.isEmpty) return;

      final body = 'Date: $date\n'
          'Party: ${partyName.isEmpty ? '-' : partyName}\n'
          'Bill No: ${invoiceNo.isEmpty ? '-' : invoiceNo}\n'
          'Product: ${productName.isEmpty ? '-' : productName}\n'
          'Shades: ${shadeLines.isNotEmpty ? shadeLines : '-'}\n'
          'Total $unit: ${totalMtr.toStringAsFixed(2)}';

      final granted = await _telephony.requestPhoneAndSmsPermissions;
      if (granted != true) {
        if (mounted) {
          _msg('Inventory saved, but SMS permission denied.');
        }
        return;
      }

      await _telephony.sendSms(to: to, message: body);
    } catch (e) {
      debugPrint('Auto SMS failed: $e');
      if (mounted) {
        _msg('Inventory saved, but auto SMS failed.');
      }
    }
  }

  String _buildShadeQtySummaryText() {
    if (items.isEmpty) return '';

    final shadeNameById = <int, String>{
      for (final s in fabricShades)
        if (s['id'] is int) s['id'] as int: (s['shade_no'] ?? '-').toString(),
    };

    final qtyByShade = <String, double>{};
    for (final i in items) {
      final sid = i['shade_id'] as int?;
      if (sid == null) continue;
      final shade = shadeNameById[sid] ?? 'Shade#$sid';
      final qty = (i['qty'] as num?)?.toDouble() ?? 0;
      qtyByShade[shade] = (qtyByShade[shade] ?? 0) + qty;
    }

    final parts = qtyByShade.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return parts
        .map((e) => '${e.key}:${e.value.toStringAsFixed(2)}')
        .join(', ');
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _openHistory() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FirmInventoryHistoryPage(
          firmId: widget.firmId,
          firmName: 'Firm ${widget.firmId}',
        ),
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        title: const Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: Colors.white),
            SizedBox(width: 2),
            Text(
              'Purchase Entry',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_syncState == SyncState.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.sync, color: Colors.orangeAccent, size: 22),
            )
          else if (_syncState == SyncState.synced)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.check_circle,
                  color: Colors.lightGreenAccent, size: 22),
            )
          else if (_syncState == SyncState.error)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.error, color: Colors.redAccent, size: 22),
            ),
          IconButton(
            tooltip: 'Auto SMS Number',
            onPressed: _openAutoSmsSettings,
            icon: const Icon(Icons.settings_phone, color: Colors.white),
            iconSize: 20,
          ),
          IconButton(
            tooltip: 'History',
            onPressed: _openHistory,
            icon: const Icon(Icons.history, color: Colors.white),
            iconSize: 20,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFF5F5F5),
                    Color(0xFFE3F2FD),
                    Color(0xFFF5F5F5)
                  ],
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
                  MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: const TextScaler.linear(0.85),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                      child: Column(
                        children: [
                          // ---------- HEADER ----------
                          InventoryFormCard(
                            title: 'INVENTORY HEADER',
                            backgroundColor: const Color(0xFFE8F5E9),
                            borderColor: const Color(0xFF81C784),
                            padding: const EdgeInsets.all(10),
                            children: [
                              Row(
                                children: [
                                  Expanded(child: _dateField()),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _field(invoiceCtrl, 'Bill No'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Auto SMS to: $_autoReportMobile',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF757575),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<int>(
                                initialValue: _selectedPartyId,
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: 'Party Name',
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                                items: parties
                                    .where((p) => p.id != null)
                                    .map(
                                      (p) => DropdownMenuItem<int>(
                                        value: p.id!,
                                        child: Text(p.name),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) =>
                                    setState(() => selectedParty = _partyById(v)),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<int>(
                                initialValue: _selectedProductId,
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: 'Product',
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                                items: products
                                    .where((p) => p.id != null)
                                    .map(
                                      (p) => DropdownMenuItem<int>(
                                        value: p.id!,
                                        child: Text(p.name),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() {
                                    selectedProduct = _productById(v);
                                    selectedFabricShadeId = null;
                                    selectedFabricShadeIds.clear();
                                    selectedShadeQtyById.clear();
                                    if (editingItemIndex != null) {
                                      editingItemIndex = null;
                                      qtyCtrl.clear();
                                    }
                                  });
                                },
                              ),
                            ],
                          ),

                          // ---------- SHADE ITEMS ----------
                          InventoryFormCard(
                            title: 'SHADE-WISE ITEMS',
                            backgroundColor: const Color(0xFFE3F2FD),
                            borderColor: const Color(0xFF90CAF9),
                            padding: const EdgeInsets.all(10),
                            children: [
                              SwitchListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Merge same shade'),
                                value: mergeSameShadeLines,
                                onChanged: (v) =>
                                    setState(() => mergeSameShadeLines = v),
                              ),
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF1565C0),
                                    side: const BorderSide(
                                      color: Color(0xFF1565C0),
                                      width: 1.5,
                                    ),
                                    backgroundColor: const Color(0xFFFFFFFF),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  focusNode: shadeFocusNode,
                                  onPressed: _openShadeMultiSelect,
                                  icon: const Icon(Icons.color_lens_outlined,
                                      size: 18),
                                  label: Text(
                                    _selectedShadesText(),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 40,
                                      child: TextField(
                                        controller: qtyCtrl,
                                        focusNode: qtyFocusNode,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(
                                          decimal: true,
                                        ),
                                        onSubmitted: (_) => _addItem(),
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        decoration: InputDecoration(
                                          labelText:
                                              selectedProduct?.unit ?? 'Qty',
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 10, vertical: 8),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          filled: true,
                                          fillColor: const Color(0xFFF5F5F5),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 40,
                                    width: 100,
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF1565C0),
                                        foregroundColor:
                                            const Color(0xFFF5F5F5),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        textStyle: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      onPressed: _addItem,
                                      icon: Icon(
                                        editingItemIndex == null
                                            ? Icons.add
                                            : Icons.check,
                                        size: 18,
                                      ),
                                      label: Text(
                                        editingItemIndex == null
                                            ? 'ADD'
                                            : 'UPDATE',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (editingItemIndex != null) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _cancelEditItem,
                                    child: const Text('Cancel edit'),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              if (items.isEmpty)
                                const Text('No shade items added',
                                    style: TextStyle(fontSize: 12))
                              else
                                ...items.asMap().entries.map((entry) {
                                  final i = entry.key;
                                  final item = entry.value;
                                  final qty = (item['qty'] as num).toDouble();

                                  return Card(
                                    color: const Color(0xFFFFFFFF),
                                    margin: const EdgeInsets.only(bottom: 4),
                                    child: ListTile(
                                      dense: true,
                                      visualDensity:
                                          const VisualDensity(vertical: -3),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 10),
                                      title: Text(
                                        _shadeLabel(item['shade_id'] as int?),
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                      subtitle: Text(
                                        '${selectedProduct?.unit ?? 'Qty'}: ${qty.toStringAsFixed(2)}',
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            iconSize: 20,
                                            constraints: const BoxConstraints(
                                                minWidth: 32, minHeight: 32),
                                            padding: EdgeInsets.zero,
                                            icon:
                                                const Icon(Icons.edit_outlined),
                                            onPressed: () => _startEditItem(i),
                                          ),
                                          IconButton(
                                            iconSize: 20,
                                            constraints: const BoxConstraints(
                                                minWidth: 32, minHeight: 32),
                                            padding: EdgeInsets.zero,
                                            icon: const Icon(
                                                Icons.delete_outline),
                                            onPressed: () {
                                              setState(() {
                                                if (editingItemIndex == i) {
                                                  editingItemIndex = null;
                                                  selectedFabricShadeId = null;
                                                  qtyCtrl.clear();
                                                } else if (editingItemIndex !=
                                                        null &&
                                                    editingItemIndex! > i) {
                                                  editingItemIndex =
                                                      editingItemIndex! - 1;
                                                }
                                                items.removeAt(i);
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                            ],
                          ),

                          // ---------- SUMMARY ----------
                          InventoryFormCard(
                            title: 'SUMMARY',
                            backgroundColor: const Color(0xFFF3E5F5),
                            borderColor: const Color(0xFFCE93D8),
                            padding: const EdgeInsets.all(10),
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Items: ${items.length} shades',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      'Total ${selectedProduct?.unit ?? 'Qty'}: ${_totalMtr.toStringAsFixed(2)}',
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      bottomNavigationBar: loading
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: const Color(0xFFF5F5F5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    onPressed: _syncState == SyncState.syncing ? null : _save,
                    icon: _syncState == SyncState.syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined, size: 20),
                    label: Text(
                      _syncState == SyncState.syncing
                          ? 'SAVING...'
                          : 'SAVE INVENTORY',
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  // ---------- HELPERS ----------
  Widget _field(
    TextEditingController c,
    String label, {
    TextInputType keyboardType = TextInputType.text,
    FocusNode? focusNode,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      focusNode: focusNode,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
      ),
    );
  }

  Widget _dateField() {
    return TextField(
      controller: dateCtrl,
      readOnly: true,
      onTap: _pickPurchaseDate,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: 'Date',
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
      ),
    );
  }

  @override
  void dispose() {
    ErpDatabase.instance.dataVersion.removeListener(_onDataChanged);
    dateCtrl.dispose();
    invoiceCtrl.dispose();
    qtyCtrl.dispose();
    shadeFocusNode.dispose();
    qtyFocusNode.dispose();
    super.dispose();
  }
}


