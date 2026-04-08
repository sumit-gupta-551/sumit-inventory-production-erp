import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/erp_database.dart';
import '../models/product.dart';
import '../models/party.dart';
import '../widgets/inventory_form_card.dart';

class IssueInventoryPage extends StatefulWidget {
  const IssueInventoryPage({super.key});

  @override
  State<IssueInventoryPage> createState() => _IssueInventoryPageState();
}

class _IssueInventoryPageState extends State<IssueInventoryPage> {
  // ---------- CONTROLLERS ----------
  final dateCtrl = TextEditingController();
  final chNoCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final FocusNode shadeFocusNode = FocusNode();
  final FocusNode qtyFocusNode = FocusNode();

  // ---------- DATA ----------
  List<Product> products = [];
  List<Party> parties = [];
  List<Map<String, dynamic>> shades = [];
  final Map<int, Set<int>> productShadeIds = {};

  Product? selectedProduct;
  Party? selectedParty;
  int? selectedShadeId;
  final Set<int> selectedShadeIds = <int>{};
  final Map<int, double> selectedShadeQtyById = <int, double>{};
  int? editingIndex;
  bool mergeSameShade = true;
  bool loading = true;

  final List<Map<String, dynamic>> addedShades = [];

  // ---------- REQUIREMENT GRID ----------
  final reqQtyCtrl = TextEditingController();
  final FocusNode reqShadeFocusNode = FocusNode();
  final FocusNode reqQtyFocusNode = FocusNode();
  int? reqSelectedShadeId;
  final Set<int> reqSelectedShadeIds = <int>{};
  final Map<int, double> reqSelectedShadeQtyById = <int, double>{};
  int? reqEditingIndex;
  final List<Map<String, dynamic>> addedReqShades = [];
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    dateCtrl.text = DateFormat('dd-MM-yyyy').format(DateTime.now());
    _loadMasters();
  }

  @override
  void dispose() {
    dateCtrl.dispose();
    chNoCtrl.dispose();
    qtyCtrl.dispose();
    reqQtyCtrl.dispose();
    shadeFocusNode.dispose();
    qtyFocusNode.dispose();
    reqShadeFocusNode.dispose();
    reqQtyFocusNode.dispose();
    super.dispose();
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
          .where((p) => p.partyType == 'Sales')
          .toList();
      final s = results[2] as List<Map<String, dynamic>>;
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
        shades = s;
        productShadeIds
          ..clear()
          ..addAll(map);
        loading = false;
      });
    } catch (e) {
      debugPrint('Error loading masters: $e');
      if (!mounted) return;
      setState(() {
        loading = false;
      });
      _msg('Error loading masters');
    }
  }

  String _shadeNo(int? shadeId) {
    if (shadeId == null) return '-';
    final s = shades.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e?['id'] == shadeId,
          orElse: () => null,
        );
    return (s?['shade_no'] ?? '-').toString();
  }

  List<Map<String, dynamic>> _filteredShadesForProduct() {
    if (selectedProduct == null) return [];

    final byProductName = shades.where((s) {
      final n = (s['shade_name'] ?? '').toString().trim().toLowerCase();
      return n == selectedProduct!.name.trim().toLowerCase();
    });

    final linkedIds = selectedProduct!.id == null
        ? <int>{}
        : (productShadeIds[selectedProduct!.id!] ?? <int>{});

    final byHistory = shades.where((s) {
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

  String _selectedShadeText() {
    if (editingIndex != null) {
      if (selectedShadeId == null) return 'Select Shade';
      return _shadeNo(selectedShadeId);
    }
    if (selectedShadeIds.isEmpty) return 'Select Shade(s)';
    if (selectedShadeIds.length == 1) return _shadeNo(selectedShadeIds.first);
    return '${selectedShadeIds.length} shades selected';
  }

  Future<void> _openShadePicker() async {
    if (selectedProduct == null) {
      _msg('Select product first');
      return;
    }

    final source = _filteredShadesForProduct();
    if (source.isEmpty) {
      _msg('No shades found for selected product');
      return;
    }

    final temp = editingIndex != null
        ? <int>{if (selectedShadeId != null) selectedShadeId!}
        : Set<int>.from(selectedShadeIds);
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
                editingIndex == null ? 'Select Shade(s)' : 'Select Shade',
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
                                        if (editingIndex != null) {
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
                                if (editingIndex == null)
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
                      selectedShadeIds
                        ..clear()
                        ..addAll(temp);
                      selectedShadeQtyById
                        ..clear()
                        ..addAll(tempQtyById);
                      selectedShadeId = temp.isEmpty ? null : temp.first;

                      if (selectedShadeIds.length == 1) {
                        final onlyId = selectedShadeIds.first;
                        final q = selectedShadeQtyById[onlyId];
                        if (q != null && q > 0) {
                          qtyCtrl.text = q.toString();
                        }
                      }
                    });
                    Navigator.pop(ctx);
                    _focusQtyField();
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

  int _dateMillis() {
    try {
      return DateFormat('dd-MM-yyyy')
          .parse(dateCtrl.text)
          .millisecondsSinceEpoch;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  int _findShadeIndex(int shadeId, {int? exceptIndex}) {
    for (var i = 0; i < addedShades.length; i++) {
      if (exceptIndex != null && i == exceptIndex) continue;
      if (addedShades[i]['shade_id'] == shadeId) return i;
    }
    return -1;
  }

  void _focusQtyField({bool selectAll = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      qtyFocusNode.requestFocus();
      if (selectAll && qtyCtrl.text.isNotEmpty) {
        qtyCtrl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: qtyCtrl.text.length,
        );
      }
    });
  }

  void _focusShadeField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(shadeFocusNode);
    });
  }

  double get _totalIssueQty {
    return addedShades.fold<double>(
      0,
      (sum, row) => sum + ((row['qty'] as num?)?.toDouble() ?? 0),
    );
  }

  // ---------- ADD SHADE ----------
  Future<void> _addShade() async {
    if (editingIndex == null && selectedShadeIds.isEmpty) {
      _msg('Select shade');
      return;
    }

    if (editingIndex != null && selectedShadeId == null) {
      _msg('Select shade');
      return;
    }

    final qty = double.tryParse(qtyCtrl.text.trim()) ?? 0;

    // --- Editing existing row (no stock check) ---
    if (editingIndex != null) {
      if (qty <= 0) {
        _msg('Enter valid qty');
        return;
      }
      setState(() {
        final idx = editingIndex!;
        final mergeIdx = mergeSameShade
            ? _findShadeIndex(selectedShadeId!, exceptIndex: idx)
            : -1;

        if (mergeIdx >= 0) {
          final mergedQty =
              (addedShades[mergeIdx]['qty'] as num).toDouble() + qty;
          addedShades[mergeIdx] = {
            'shade_id': selectedShadeId,
            'shade_no': _shadeNo(selectedShadeId),
            'qty': mergedQty,
          };
          addedShades.removeAt(idx);
        } else {
          addedShades[idx] = {
            'shade_id': selectedShadeId,
            'shade_no': _shadeNo(selectedShadeId),
            'qty': qty,
          };
        }
        editingIndex = null;
        selectedShadeId = null;
        selectedShadeIds.clear();
        selectedShadeQtyById.clear();
        qtyCtrl.clear();
      });
      _focusShadeField();
      return;
    }

    // --- Adding new rows: check stock for each shade ---
    if (selectedShadeIds.length > 1) {
      final invalid = selectedShadeIds.any(
        (id) => (selectedShadeQtyById[id] ?? 0) <= 0,
      );
      if (invalid) {
        _msg('Enter qty for each selected shade');
        return;
      }
    }

    if (selectedProduct == null) {
      _msg('Select product first');
      return;
    }

    final toStock = <Map<String, dynamic>>[];
    final toReq = <Map<String, dynamic>>[];

    for (final shadeId in selectedShadeIds) {
      final rowQty = selectedShadeIds.length > 1
          ? (selectedShadeQtyById[shadeId] ?? 0)
          : ((selectedShadeQtyById[shadeId] ?? 0) > 0
              ? (selectedShadeQtyById[shadeId] ?? 0)
              : qty);

      if (rowQty <= 0) {
        _msg('Enter valid qty');
        return;
      }

      final balance = await ErpDatabase.instance.getCurrentStockBalance(
        productId: selectedProduct!.id!,
        fabricShadeId: shadeId,
      );

      if (balance >= rowQty) {
        // Enough stock
        toStock.add({
          'shade_id': shadeId,
          'shade_no': _shadeNo(shadeId),
          'qty': rowQty,
        });
      } else if (balance > 0 && balance < rowQty) {
        // Insufficient stock - send full qty to requirement, stock untouched
        if (!mounted) return;
        final send = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Insufficient Stock'),
            content: Text(
              '${_shadeNo(shadeId)}: Stock is ${balance.toStringAsFixed(2)}, '
              'but need ${rowQty.toStringAsFixed(2)}.\n\n'
              'Full qty will go to Requirement (stock untouched).',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Yes, Send to Requirement'),
              ),
            ],
          ),
        );
        if (send != true) return;
        toReq.add({
          'shade_id': shadeId,
          'shade_no': _shadeNo(shadeId),
          'qty': rowQty,
        });
      } else {
        // No stock at all
        if (!mounted) return;
        final send = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('No Stock'),
            content: Text(
              '${_shadeNo(shadeId)}: No stock available '
              '(balance: ${balance.toStringAsFixed(2)}).\n\n'
              'Send to Requirement?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Yes, Send to Requirement'),
              ),
            ],
          ),
        );
        if (send != true) return;
        toReq.add({
          'shade_id': shadeId,
          'shade_no': _shadeNo(shadeId),
          'qty': rowQty,
        });
      }
    }

    setState(() {
      for (final item in toStock) {
        final sid = item['shade_id'] as int;
        final mergeIdx = mergeSameShade ? _findShadeIndex(sid) : -1;
        if (mergeIdx >= 0) {
          addedShades[mergeIdx]['qty'] =
              (addedShades[mergeIdx]['qty'] as num).toDouble() +
                  (item['qty'] as num).toDouble();
        } else {
          addedShades.add(item);
        }
      }
      for (final item in toReq) {
        final sid = item['shade_id'] as int;
        final mergeIdx = mergeSameShade ? _findReqShadeIndex(sid) : -1;
        if (mergeIdx >= 0) {
          addedReqShades[mergeIdx]['qty'] =
              (addedReqShades[mergeIdx]['qty'] as num).toDouble() +
                  (item['qty'] as num).toDouble();
        } else {
          addedReqShades.add(item);
        }
      }

      selectedShadeId = null;
      selectedShadeIds.clear();
      selectedShadeQtyById.clear();
      qtyCtrl.clear();
    });

    _focusShadeField();
  }

  void _startEditShade(int index) {
    final item = addedShades[index];
    setState(() {
      editingIndex = index;
      selectedShadeId = item['shade_id'] as int?;
      selectedShadeIds
        ..clear()
        ..add((item['shade_id'] as int?) ?? -1)
        ..remove(-1);
      selectedShadeQtyById
        ..clear()
        ..addAll({
          if (item['shade_id'] is int)
            item['shade_id'] as int: (item['qty'] as num).toDouble(),
        });
      qtyCtrl.text = ((item['qty'] as num).toDouble()).toString();
    });
    _focusQtyField(selectAll: true);
  }

  void _cancelEditShade() {
    setState(() {
      editingIndex = null;
      selectedShadeId = null;
      selectedShadeIds.clear();
      selectedShadeQtyById.clear();
      qtyCtrl.clear();
    });
    _focusShadeField();
  }

  // ---------- REQUIREMENT GRID METHODS ----------
  String _reqSelectedShadeText() {
    if (reqEditingIndex != null) {
      if (reqSelectedShadeId == null) return 'Select Shade';
      return _shadeNo(reqSelectedShadeId);
    }
    if (reqSelectedShadeIds.isEmpty) return 'Select Shade(s)';
    if (reqSelectedShadeIds.length == 1) {
      return _shadeNo(reqSelectedShadeIds.first);
    }
    return '${reqSelectedShadeIds.length} shades selected';
  }

  Future<void> _openReqShadePicker() async {
    if (selectedProduct == null) {
      _msg('Select product first');
      return;
    }

    final source = _filteredShadesForProduct();
    if (source.isEmpty) {
      _msg('No shades found for selected product');
      return;
    }

    final temp = reqEditingIndex != null
        ? <int>{if (reqSelectedShadeId != null) reqSelectedShadeId!}
        : Set<int>.from(reqSelectedShadeIds);
    final tempQtyById = Map<int, double>.from(reqSelectedShadeQtyById);

    var reqShadeSearch = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final filtered = reqShadeSearch.isEmpty
                ? source
                : source.where((s) {
                    final no = (s['shade_no'] ?? '').toString().toLowerCase();
                    return no.contains(reqShadeSearch.toLowerCase());
                  }).toList();

            return AlertDialog(
              title: Text(
                reqEditingIndex == null
                    ? 'Select Requirement Shade(s)'
                    : 'Select Shade',
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
                      onChanged: (v) =>
                          setDialogState(() => reqShadeSearch = v),
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
                                        if (reqEditingIndex != null) {
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
                                if (reqEditingIndex == null)
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
                      reqSelectedShadeIds
                        ..clear()
                        ..addAll(temp);
                      reqSelectedShadeQtyById
                        ..clear()
                        ..addAll(tempQtyById);
                      reqSelectedShadeId = temp.isEmpty ? null : temp.first;

                      if (reqSelectedShadeIds.length == 1) {
                        final onlyId = reqSelectedShadeIds.first;
                        final q = reqSelectedShadeQtyById[onlyId];
                        if (q != null && q > 0) {
                          reqQtyCtrl.text = q.toString();
                        }
                      }
                    });
                    Navigator.pop(ctx);
                    _focusReqQtyField();
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

  void _focusReqQtyField({bool selectAll = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      reqQtyFocusNode.requestFocus();
      if (selectAll && reqQtyCtrl.text.isNotEmpty) {
        reqQtyCtrl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: reqQtyCtrl.text.length,
        );
      }
    });
  }

  void _focusReqShadeField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(reqShadeFocusNode);
    });
  }

  int _findReqShadeIndex(int shadeId, {int? exceptIndex}) {
    for (var i = 0; i < addedReqShades.length; i++) {
      if (exceptIndex != null && i == exceptIndex) continue;
      if (addedReqShades[i]['shade_id'] == shadeId) return i;
    }
    return -1;
  }

  void _addReqShade() {
    if (reqEditingIndex == null && reqSelectedShadeIds.isEmpty) {
      _msg('Select shade');
      return;
    }
    if (reqEditingIndex != null && reqSelectedShadeId == null) {
      _msg('Select shade');
      return;
    }

    final qty = double.tryParse(reqQtyCtrl.text.trim()) ?? 0;

    setState(() {
      if (reqEditingIndex != null) {
        if (qty <= 0) {
          _msg('Enter valid qty');
          return;
        }
        final idx = reqEditingIndex!;
        final mergeIdx = mergeSameShade
            ? _findReqShadeIndex(reqSelectedShadeId!, exceptIndex: idx)
            : -1;
        if (mergeIdx >= 0) {
          final mergedQty =
              (addedReqShades[mergeIdx]['qty'] as num).toDouble() + qty;
          addedReqShades[mergeIdx] = {
            'shade_id': reqSelectedShadeId,
            'shade_no': _shadeNo(reqSelectedShadeId),
            'qty': mergedQty,
          };
          addedReqShades.removeAt(idx);
        } else {
          addedReqShades[idx] = {
            'shade_id': reqSelectedShadeId,
            'shade_no': _shadeNo(reqSelectedShadeId),
            'qty': qty,
          };
        }
      } else {
        if (reqSelectedShadeIds.length > 1) {
          final invalid = reqSelectedShadeIds.any(
            (id) => (reqSelectedShadeQtyById[id] ?? 0) <= 0,
          );
          if (invalid) {
            _msg('Enter qty for each selected shade');
            return;
          }
        }
        for (final shadeId in reqSelectedShadeIds) {
          final rowQty = reqSelectedShadeIds.length > 1
              ? (reqSelectedShadeQtyById[shadeId] ?? 0)
              : ((reqSelectedShadeQtyById[shadeId] ?? 0) > 0
                  ? (reqSelectedShadeQtyById[shadeId] ?? 0)
                  : qty);
          if (rowQty <= 0) {
            _msg('Enter valid qty');
            return;
          }
          final mergeIdx = mergeSameShade ? _findReqShadeIndex(shadeId) : -1;
          if (mergeIdx >= 0) {
            addedReqShades[mergeIdx]['qty'] =
                (addedReqShades[mergeIdx]['qty'] as num).toDouble() + rowQty;
          } else {
            addedReqShades.add({
              'shade_id': shadeId,
              'shade_no': _shadeNo(shadeId),
              'qty': rowQty,
            });
          }
        }
      }

      reqEditingIndex = null;
      reqSelectedShadeId = null;
      reqSelectedShadeIds.clear();
      reqSelectedShadeQtyById.clear();
      reqQtyCtrl.clear();
    });
    _focusReqShadeField();
  }

  void _startEditReqShade(int index) {
    final item = addedReqShades[index];
    setState(() {
      reqEditingIndex = index;
      reqSelectedShadeId = item['shade_id'] as int?;
      reqSelectedShadeIds
        ..clear()
        ..add((item['shade_id'] as int?) ?? -1)
        ..remove(-1);
      reqSelectedShadeQtyById
        ..clear()
        ..addAll({
          if (item['shade_id'] is int)
            item['shade_id'] as int: (item['qty'] as num).toDouble(),
        });
      reqQtyCtrl.text = ((item['qty'] as num).toDouble()).toString();
    });
    _focusReqQtyField(selectAll: true);
  }

  void _cancelEditReqShade() {
    setState(() {
      reqEditingIndex = null;
      reqSelectedShadeId = null;
      reqSelectedShadeIds.clear();
      reqSelectedShadeQtyById.clear();
      reqQtyCtrl.clear();
    });
    _focusReqShadeField();
  }

  double get _totalReqQty {
    return addedReqShades.fold<double>(
      0,
      (sum, row) => sum + ((row['qty'] as num?)?.toDouble() ?? 0),
    );
  }

  // ---------- SAVE ISSUE (OUT) ----------
  Future<void> saveIssue() async {
    if (selectedProduct == null ||
        selectedParty == null ||
        (addedShades.isEmpty && addedReqShades.isEmpty)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill all required fields')),
      );
      return;
    }

    try {
      setState(() => _syncing = true);
      final issueRef = DateTime.now().millisecondsSinceEpoch.toString();
      final warningLines = <String>[];

      final outByShadeId = <int, double>{};
      for (final s in addedShades) {
        final sid = s['shade_id'] as int?;
        final qty = (s['qty'] as num?)?.toDouble() ?? 0;
        if (sid == null || qty <= 0) continue;
        outByShadeId[sid] = (outByShadeId[sid] ?? 0) + qty;
      }

      for (final e in outByShadeId.entries) {
        final current = await ErpDatabase.instance.getCurrentStockBalance(
          productId: selectedProduct!.id!,
          fabricShadeId: e.key,
        );
        final projected = current - e.value;
        if (projected < 0) {
          warningLines.add(
            '${_shadeNo(e.key)} -> ${projected.toStringAsFixed(2)}',
          );
        }
      }

      if (warningLines.isNotEmpty) {
        if (!mounted) {
          setState(() => _syncing = false);
          return;
        }
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Negative Balance Warning'),
            content: Text(
              'These shades will go negative:\n${warningLines.join('\n')}\n\nProceed anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Proceed'),
              ),
            ],
          ),
        );
        if (proceed != true) {
          setState(() => _syncing = false);
          return;
        }
      }

      for (final s in addedShades) {
        await ErpDatabase.instance.insertLedger(
          {
            'product_id': selectedProduct!.id,
            'fabric_shade_id': s['shade_id'],
            'type': 'OUT',
            'qty': s['qty'],
            'date': _dateMillis(),
            'reference': issueRef,
            'remarks':
                'Party: ${selectedParty!.name} | ChNo: ${chNoCtrl.text.trim()}',
          },
        );
      }

      // Save requirement items
      for (final r in addedReqShades) {
        await ErpDatabase.instance.insertChallanRequirement({
          'challan_no': chNoCtrl.text.trim(),
          'party_id': selectedParty!.id,
          'party_name': selectedParty!.name,
          'product_id': selectedProduct!.id,
          'fabric_shade_id': r['shade_id'],
          'qty': r['qty'],
          'date': _dateMillis(),
          'status': 'pending',
        });
      }

      // --- Firebase Realtime Database Sync ---
      try {
        final dbRef = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL:
              'https://mayur-synthetics-default-rtdb.asia-southeast1.firebasedatabase.app',
        ).ref('issues');

        final issueData = {
          'reference': issueRef,
          'product_id': selectedProduct!.id,
          'product_name': selectedProduct!.name,
          'party_id': selectedParty!.id,
          'party_name': selectedParty!.name,
          'challan_no': chNoCtrl.text.trim(),
          'date': _dateMillis(),
          'date_str': dateCtrl.text.trim(),
          'stock_items': [
            for (final s in addedShades)
              {
                'shade_id': s['shade_id'],
                'shade_no': s['shade_no'],
                'qty': s['qty'],
              },
          ],
          'requirement_items': [
            for (final r in addedReqShades)
              {
                'shade_id': r['shade_id'],
                'shade_no': r['shade_no'],
                'qty': r['qty'],
              },
          ],
          'total_stock_qty': _totalIssueQty,
          'total_req_qty': _totalReqQty,
        };
        await dbRef.push().set(issueData);
      } catch (e) {
        debugPrint('Firebase issue sync error: $e');
      }

      if (!mounted) return;

      setState(() {
        _syncing = false;
        selectedShadeId = null;
        selectedShadeIds.clear();
        selectedShadeQtyById.clear();
        editingIndex = null;
        qtyCtrl.clear();
        addedShades.clear();
        // Clear requirement state
        reqSelectedShadeId = null;
        reqSelectedShadeIds.clear();
        reqSelectedShadeQtyById.clear();
        reqEditingIndex = null;
        reqQtyCtrl.clear();
        addedReqShades.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Issued Successfully'),
        ),
      );

      if (warningLines.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            content: Text(
              'Warning: Negative balance moved to Fabric Requirement\n${warningLines.join(', ')}',
            ),
          ),
        );
      }

      _focusShadeField();
    } catch (e) {
      if (mounted) setState(() => _syncing = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving issue: $e')),
      );
    }
  }

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  // ---------- UI ----------
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
            Icon(Icons.local_shipping_outlined, color: Colors.white),
            SizedBox(width: 10),
            Text(
              'Issue Entry',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
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
                          InventoryFormCard(
                            title: 'ISSUE HEADER',
                            backgroundColor: const Color(0xFFE8EAF6),
                            borderColor: const Color(0xFF9FA8DA),
                            padding: const EdgeInsets.all(10),
                            children: [
                              Row(
                                children: [
                                  Expanded(child: _dateField()),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: _field(
                                      chNoCtrl,
                                      'Challan No',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<Party>(
                                value: selectedParty,
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: 'Party Code',
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                                items: parties
                                    .map(
                                      (p) => DropdownMenuItem<Party>(
                                        value: p,
                                        child: Text(p.name),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) =>
                                    setState(() => selectedParty = v),
                              ),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<Product>(
                                value: selectedProduct,
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: 'Product',
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                                items: products
                                    .map(
                                      (p) => DropdownMenuItem<Product>(
                                        value: p,
                                        child: Text(p.name),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() {
                                    selectedProduct = v;
                                    selectedShadeId = null;
                                    selectedShadeIds.clear();
                                    selectedShadeQtyById.clear();
                                    if (editingIndex != null) {
                                      editingIndex = null;
                                      qtyCtrl.clear();
                                    }
                                  });
                                },
                              ),
                            ],
                          ),
                          InventoryFormCard(
                            title: 'STOCK ITEMS',
                            backgroundColor: const Color(0xFFE8F5E9),
                            borderColor: const Color(0xFF81C784),
                            padding: const EdgeInsets.all(10),
                            children: [
                              SwitchListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Merge same shade'),
                                value: mergeSameShade,
                                onChanged: (v) =>
                                    setState(() => mergeSameShade = v),
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
                                  onPressed: _openShadePicker,
                                  icon: const Icon(Icons.color_lens_outlined,
                                      size: 18),
                                  label: Text(
                                    _selectedShadeText(),
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
                                        onSubmitted: (_) => _addShade(),
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        decoration: InputDecoration(
                                          labelText: 'Qty',
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
                                      onPressed: _addShade,
                                      icon: Icon(
                                        editingIndex == null
                                            ? Icons.add
                                            : Icons.check,
                                        size: 18,
                                      ),
                                      label: Text(
                                        editingIndex == null ? 'ADD' : 'UPDATE',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (editingIndex != null) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _cancelEditShade,
                                    child: const Text('Cancel edit'),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              if (addedShades.isEmpty)
                                const Text('No shade items added',
                                    style: TextStyle(fontSize: 12))
                              else
                                ...addedShades.asMap().entries.map((entry) {
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
                                            onPressed: () => _startEditShade(i),
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
                                                if (editingIndex == i) {
                                                  editingIndex = null;
                                                  selectedShadeId = null;
                                                  qtyCtrl.clear();
                                                } else if (editingIndex !=
                                                        null &&
                                                    editingIndex! > i) {
                                                  editingIndex =
                                                      editingIndex! - 1;
                                                }
                                                addedShades.removeAt(i);
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
                          // ---------- REQUIREMENT ITEMS GRID ----------
                          InventoryFormCard(
                            title: 'REQUIREMENT ITEMS',
                            backgroundColor: const Color(0xFFFFF3E0),
                            borderColor: const Color(0xFFFFCC80),
                            padding: const EdgeInsets.all(10),
                            children: [
                              Text(
                                'Items not in stock â€” tracked as requirement',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange.shade800,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                width: double.infinity,
                                height: 40,
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFFE91E63),
                                    side: const BorderSide(
                                      color: Color(0xFFFFB74D),
                                      width: 1.5,
                                    ),
                                    backgroundColor: const Color(0xFFFFFFFF),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  focusNode: reqShadeFocusNode,
                                  onPressed: _openReqShadePicker,
                                  icon: const Icon(Icons.color_lens_outlined,
                                      size: 18),
                                  label: Text(
                                    _reqSelectedShadeText(),
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
                                        controller: reqQtyCtrl,
                                        focusNode: reqQtyFocusNode,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(
                                          decimal: true,
                                        ),
                                        onSubmitted: (_) => _addReqShade(),
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
                                            const Color(0xFFE91E63),
                                        foregroundColor: Colors.white,
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
                                      onPressed: _addReqShade,
                                      icon: Icon(
                                        reqEditingIndex == null
                                            ? Icons.add
                                            : Icons.check,
                                        size: 18,
                                      ),
                                      label: Text(
                                        reqEditingIndex == null
                                            ? 'ADD'
                                            : 'UPDATE',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (reqEditingIndex != null) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _cancelEditReqShade,
                                    child: const Text('Cancel edit'),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              if (addedReqShades.isEmpty)
                                const Text('No requirement items added',
                                    style: TextStyle(fontSize: 12))
                              else
                                ...addedReqShades.asMap().entries.map((entry) {
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
                                        'Req ${selectedProduct?.unit ?? 'Qty'}: ${qty.toStringAsFixed(2)}',
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
                                            onPressed: () =>
                                                _startEditReqShade(i),
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
                                                if (reqEditingIndex == i) {
                                                  reqEditingIndex = null;
                                                  reqSelectedShadeId = null;
                                                  reqQtyCtrl.clear();
                                                } else if (reqEditingIndex !=
                                                        null &&
                                                    reqEditingIndex! > i) {
                                                  reqEditingIndex =
                                                      reqEditingIndex! - 1;
                                                }
                                                addedReqShades.removeAt(i);
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
                                      'Stock: ${addedShades.length} shades',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${selectedProduct?.unit ?? 'Qty'}: ${_totalIssueQty.toStringAsFixed(2)}',
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (addedReqShades.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Req: ${addedReqShades.length} shades',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: Colors.deepOrange,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '${selectedProduct?.unit ?? 'Qty'}: ${_totalReqQty.toStringAsFixed(2)}',
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                          color: Colors.deepOrange,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
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
                    color: Colors.black.withOpacity(0.3),
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
                    onPressed: _syncing ? null : saveIssue,
                    icon: _syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined, size: 20),
                    label: Text(_syncing ? 'SAVING...' : 'SAVE ISSUE'),
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
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: 'Date',
        prefixIcon: const Icon(Icons.calendar_today, size: 16),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
      ),
    );
  }

  String _shadeLabel(int? shadeId) {
    if (shadeId == null) return '';
    final shade = shades.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s?['id'] == shadeId,
          orElse: () => null,
        );
    if (shade == null) return '';

    final shadeNo = shade['shade_no']?.toString() ?? '';
    final shadeName = shade['shade_name']?.toString() ?? '';
    if (shadeName.isEmpty) return shadeNo;
    return '$shadeNo - $shadeName';
  }
}
