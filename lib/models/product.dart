class Product {
  final int? id;
  final String name;
  final String category;
  final String unit;
  final double minStock;
  final int? gstCategoryId; // ✅ NEW

  Product({
    this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.minStock,
    this.gstCategoryId,
  });

  // ---------- FROM DB ----------
  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'] as int?,
      name: map['name'] as String,
      category: map['category'] as String,
      unit: map['unit'] as String,
      minStock: (map['min_stock'] as num).toDouble(),
      gstCategoryId: map['gst_category_id'] as int?, // ✅ NEW
    );
  }

  // ---------- TO DB ----------
  Map<String, dynamic> toMap() {
    final data = <String, dynamic>{
      'name': name,
      'category': category,
      'unit': unit,
      'min_stock': minStock,
      'gst_category_id': gstCategoryId, // ✅ NEW
    };

    if (id != null) {
      data['id'] = id;
    }

    return data;
  }

  // ---------- COPY WITH ----------
  Product copyWith({
    int? id,
    String? name,
    String? category,
    String? unit,
    double? minStock,
    int? gstCategoryId,
  }) {
    return Product(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      unit: unit ?? this.unit,
      minStock: minStock ?? this.minStock,
      gstCategoryId: gstCategoryId ?? this.gstCategoryId,
    );
  }

  // ---------- TO STRING ----------
  @override
  String toString() {
    return 'Product(id: $id, name: $name, category: $category, unit: $unit, minStock: $minStock, gstCategoryId: $gstCategoryId)';
  }

  // ---------- EQUALITY ----------
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Product &&
        other.id == id &&
        other.name == name &&
        other.category == category &&
        other.unit == unit &&
        other.minStock == minStock &&
        other.gstCategoryId == gstCategoryId;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        name.hashCode ^
        category.hashCode ^
        unit.hashCode ^
        minStock.hashCode ^
        gstCategoryId.hashCode;
  }
}
