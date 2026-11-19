import 'app_helpers.dart';

/// Produce item or category header row inside a `PriceList`.
class PriceListItem {
  const PriceListItem({
    required this.id,
    required this.name,
    this.isHeader = false,
    this.category = 'vegetables',
    this.unit = 'kgs',
    this.price = 0,
    this.notes = '',
  });

  final String id;
  final String name;
  final bool isHeader;
  final String category;
  final String unit;
  final double price;
  final String notes;

  factory PriceListItem.fromJson(Map<String, dynamic> json) {
    final isHeader = json['isHeader'] == true;
    return PriceListItem(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      isHeader: isHeader,
      category: (json['category'] ?? 'vegetables').toString(),
      unit: (json['unit'] ?? 'kgs').toString(),
      price: AppHelpers.parseDouble(json['price']),
      notes: (json['notes'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    if (isHeader) {
      return {
        'id': id,
        'name': name,
        'isHeader': true,
      };
    }
    return {
      'id': id,
      'name': name,
      'category': category,
      'unit': unit,
      'price': price,
      'notes': notes,
    };
  }

  PriceListItem copyWith({
    String? id,
    String? name,
    bool? isHeader,
    String? category,
    String? unit,
    double? price,
    String? notes,
  }) {
    return PriceListItem(
      id: id ?? this.id,
      name: name ?? this.name,
      isHeader: isHeader ?? this.isHeader,
      category: category ?? this.category,
      unit: unit ?? this.unit,
      price: price ?? this.price,
      notes: notes ?? this.notes,
    );
  }
}

/// Wholesale price list entity matching `priceLists` & `deletedPriceLists` in `pricelist.js`.
class PriceList {
  const PriceList({
    required this.id,
    required this.name,
    this.subtitle = 'Food Supplies (Veg and Fruits)',
    this.status = 'draft',
    this.shareId,
    this.items = const [],
    this.deletedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String subtitle;
  final String status;
  final String? shareId;
  final List<PriceListItem> items;
  final String? deletedAt;
  final String? createdAt;
  final String? updatedAt;

  factory PriceList.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((e) => PriceListItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <PriceListItem>[];

    return PriceList(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      subtitle:
          (json['subtitle'] ?? 'Food Supplies (Veg and Fruits)').toString(),
      status: (json['status'] ?? 'draft').toString(),
      shareId: json['shareId']?.toString(),
      items: items,
      deletedAt: json['deletedAt']?.toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'status': status,
      if (shareId != null) 'shareId': shareId,
      'items': items.map((e) => e.toJson()).toList(),
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  PriceList copyWith({
    String? id,
    String? name,
    String? subtitle,
    String? status,
    String? shareId,
    List<PriceListItem>? items,
    String? deletedAt,
    bool clearDeletedAt = false,
    String? createdAt,
    String? updatedAt,
  }) {
    return PriceList(
      id: id ?? this.id,
      name: name ?? this.name,
      subtitle: subtitle ?? this.subtitle,
      status: status ?? this.status,
      shareId: shareId ?? this.shareId,
      items: items ?? this.items,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
