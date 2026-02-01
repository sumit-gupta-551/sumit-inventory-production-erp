class Party {
  final int? id;
  final String name;
  final String? address;
  final String? contact;

  Party({
    this.id,
    required this.name,
    this.address,
    this.contact,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'address': address,
        'contact': contact,
      };

  factory Party.fromMap(Map<String, dynamic> map) => Party(
        id: map['id'],
        name: map['name'],
        address: map['address'],
        contact: map['contact'],
      );
}
