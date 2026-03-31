class StockLedger {
  final int? id;
  final int productId;
  final String type; // IN / OUT
  final double qty;
  final int date; // Unix timestamp
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

  // ---------- FROM DB ----------
  factory StockLedger.fromMap(Map<String, dynamic> map) {
    return StockLedger(
      id: map['id'] as int?,
      productId: map['product_id'] as int,
      type: map['type'] as String,
      qty: (map['qty'] as num).toDouble(),
      date: map['date'] as int,
      reference: map['reference'] as String?,
      remarks: map['remarks'] as String?,
    );
  }

  // ---------- TO DB ----------
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

  // ---------- COPY WITH ----------
  StockLedger copyWith({
    int? id,
    int? productId,
    String? type,
    double? qty,
    int? date,
    String? reference,
    String? remarks,
  }) {
    return StockLedger(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      type: type ?? this.type,
      qty: qty ?? this.qty,
      date: date ?? this.date,
      reference: reference ?? this.reference,
      remarks: remarks ?? this.remarks,
    );
  }

  // ---------- TO STRING ----------
  @override
  String toString() {
    return 'StockLedger(id: $id, productId: $productId, type: $type, qty: $qty, date: $date, reference: $reference, remarks: $remarks)';
  }

  // ---------- EQUALITY ----------
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StockLedger &&
        other.id == id &&
        other.productId == productId &&
        other.type == type &&
        other.qty == qty &&
        other.date == date &&
        other.reference == reference &&
        other.remarks == remarks;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        productId.hashCode ^
        type.hashCode ^
        qty.hashCode ^
        date.hashCode ^
        reference.hashCode ^
        remarks.hashCode;
  }
}
