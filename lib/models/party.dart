class Party {
  final int? id;
  final String name;
  final String address;
  final String mobile;
  final String partyType; // 'Sales' or 'Purchase'

  Party({
    this.id,
    required this.name,
    required this.address,
    required this.mobile,
    this.partyType = 'Sales',
  });

  factory Party.fromMap(Map<String, dynamic> map) {
    return Party(
      id: map['id'] as int?,
      name: map['name'] as String,
      address: map['address'] as String,
      mobile: map['mobile'] as String,
      partyType: (map['party_type'] as String?) ?? 'Sales',
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'address': address,
      'mobile': mobile,
      'party_type': partyType,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  Party copyWith({
    int? id,
    String? name,
    String? address,
    String? mobile,
    String? partyType,
  }) {
    return Party(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      mobile: mobile ?? this.mobile,
      partyType: partyType ?? this.partyType,
    );
  }

  @override
  String toString() =>
      'Party(id: $id, name: $name, address: $address, mobile: $mobile, partyType: $partyType)';
}
