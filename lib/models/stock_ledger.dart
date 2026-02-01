class StockLedger {
  final int? id;
  final int productId;
  final String type; // IN / OUT
  final double qty;
  final int date;
  final String? reference;
  final String? remarks;

  StockLedger({
    this.id,
    required this.productId,
    required this.type,
    required this.qty,
    required this.date,
    this.reference,
    this.remarks,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_id': productId,
      'type': type,
      'qty': qty,
      'date': date,
      'reference': reference,
      'remarks': remarks,
    };
  }
}
