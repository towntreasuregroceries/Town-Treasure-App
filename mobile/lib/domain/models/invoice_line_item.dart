import 'app_helpers.dart';

/// Single produce line item inside an `Invoice` or `StagingDocket`.
class InvoiceLineItem {
  const InvoiceLineItem({
    required this.desc,
    required this.qty,
    this.unit = 'kgs',
    required this.buyPrice,
    required this.sellPrice,
    required this.total,
  });

  final String desc;
  final double qty;
  final String unit;
  final double buyPrice;
  final double sellPrice;
  final double total;

  factory InvoiceLineItem.fromJson(Map<String, dynamic> json) {
    final qty = AppHelpers.parseDouble(json['qty'], 1);
    final buy = AppHelpers.parseDouble(json['buyPrice'] ?? json['buy'], 0);
    final sell = AppHelpers.parseDouble(
      json['sellPrice'] ?? json['sell'] ?? json['price'],
      0,
    );
    final total = json['total'] != null
        ? AppHelpers.parseDouble(json['total'], qty * sell)
        : qty * sell;

    return InvoiceLineItem(
      desc: (json['desc'] ?? json['name'] ?? '').toString().trim(),
      qty: qty,
      unit: (json['unit'] ?? 'kgs').toString().trim().isEmpty
          ? 'kgs'
          : (json['unit'] ?? 'kgs').toString(),
      buyPrice: buy,
      sellPrice: sell,
      total: total,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'desc': desc,
      'qty': qty,
      'unit': unit,
      'buyPrice': buyPrice,
      'sellPrice': sellPrice,
      'total': total,
    };
  }

  InvoiceLineItem copyWith({
    String? desc,
    double? qty,
    String? unit,
    double? buyPrice,
    double? sellPrice,
    double? total,
  }) {
    final nextQty = qty ?? this.qty;
    final nextSell = sellPrice ?? this.sellPrice;
    return InvoiceLineItem(
      desc: desc ?? this.desc,
      qty: nextQty,
      unit: unit ?? this.unit,
      buyPrice: buyPrice ?? this.buyPrice,
      sellPrice: nextSell,
      total: total ?? (nextQty * nextSell),
    );
  }
}
