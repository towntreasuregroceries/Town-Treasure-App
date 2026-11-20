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
    this.taxRate,
  });

  final String desc;
  final double qty;
  final String unit;
  final double buyPrice;
  final double sellPrice;
  final double total;
  /// Optional Kenyan VAT code (`'exempt'`, `'zero_rated'`, `'standard_16'`).
  final String? taxRate;

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
    final rawTax = json['taxRate']?.toString().trim();

    return InvoiceLineItem(
      desc: (json['desc'] ?? json['name'] ?? '').toString().trim(),
      qty: qty,
      unit: (json['unit'] ?? 'kgs').toString().trim().isEmpty
          ? 'kgs'
          : (json['unit'] ?? 'kgs').toString(),
      buyPrice: buy,
      sellPrice: sell,
      total: total,
      taxRate: (rawTax != null && rawTax.isNotEmpty) ? rawTax : null,
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
      if (taxRate != null && taxRate!.isNotEmpty) 'taxRate': taxRate,
    };
  }

  InvoiceLineItem copyWith({
    String? desc,
    double? qty,
    String? unit,
    double? buyPrice,
    double? sellPrice,
    double? total,
    String? taxRate,
    bool clearTaxRate = false,
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
      taxRate: clearTaxRate ? null : (taxRate ?? this.taxRate),
    );
  }
}
