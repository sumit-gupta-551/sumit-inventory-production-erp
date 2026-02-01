class Product {
  final int? id;
  final String name;
  final String category;
  final String unit;
  final double minStock;

  Product({
    this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.minStock,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'unit': unit,
      'min_stock': minStock,
    };
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'],
      name: map['name'],
      category: map['category'],
      unit: map['unit'],
      minStock: (map['min_stock'] as num).toDouble(),
    );
  }
}
