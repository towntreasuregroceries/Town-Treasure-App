import 'app_helpers.dart';

/// Expense and capital injection entity matching `expenses` in `data.js`, `views.js`, and `payroll.js`.
class Expense {
  const Expense({
    required this.id,
    this.invId,
    this.refId,
    this.refType,
    this.type = 'expense',
    required this.date,
    required this.desc,
    this.category = 'other',
    required this.amount,
    this.inputVatAmount,
    this.supplierKraPin,
    this.supplierName,
    this.supplierCuInvoiceNumber,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? invId;
  final String? refId;
  final String? refType;
  final String type;
  final String date;
  final String desc;
  final String category;
  final double amount;
  final double? inputVatAmount;
  final String? supplierKraPin;
  final String? supplierName;
  final String? supplierCuInvoiceNumber;
  final String? createdAt;
  final String? updatedAt;

  bool get isCapital => type == 'capital';

  factory Expense.fromJson(Map<String, dynamic> json) {
    final rawVat = json['inputVatAmount'];
    final rawPin = json['supplierKraPin']?.toString().trim();
    final rawSupName = json['supplierName']?.toString().trim();
    final rawSupCu = json['supplierCuInvoiceNumber']?.toString().trim();
    return Expense(
      id: (json['id'] ?? '').toString(),
      invId: json['invId']?.toString(),
      refId: json['refId']?.toString(),
      refType: json['refType']?.toString(),
      type: (json['type'] ?? 'expense').toString(),
      date: (json['date'] ?? '').toString(),
      desc: (json['desc'] ?? '').toString(),
      category: (json['category'] ?? 'other').toString(),
      amount: AppHelpers.parseDouble(json['amount']),
      inputVatAmount:
          rawVat != null ? AppHelpers.parseDouble(rawVat) : null,
      supplierKraPin:
          (rawPin != null && rawPin.isNotEmpty) ? rawPin : null,
      supplierName:
          (rawSupName != null && rawSupName.isNotEmpty) ? rawSupName : null,
      supplierCuInvoiceNumber:
          (rawSupCu != null && rawSupCu.isNotEmpty) ? rawSupCu : null,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (invId != null) 'invId': invId,
      if (refId != null) 'refId': refId,
      if (refType != null) 'refType': refType,
      'type': type,
      'date': date,
      'desc': desc,
      'category': category,
      'amount': amount,
      if (inputVatAmount != null && inputVatAmount! > 0)
        'inputVatAmount': inputVatAmount,
      if (supplierKraPin != null && supplierKraPin!.isNotEmpty)
        'supplierKraPin': supplierKraPin,
      if (supplierName != null && supplierName!.isNotEmpty)
        'supplierName': supplierName,
      if (supplierCuInvoiceNumber != null &&
          supplierCuInvoiceNumber!.isNotEmpty)
        'supplierCuInvoiceNumber': supplierCuInvoiceNumber,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  Expense copyWith({
    String? id,
    String? invId,
    String? refId,
    String? refType,
    String? type,
    String? date,
    String? desc,
    String? category,
    double? amount,
    double? inputVatAmount,
    String? supplierKraPin,
    String? supplierName,
    String? supplierCuInvoiceNumber,
    String? createdAt,
    String? updatedAt,
  }) {
    return Expense(
      id: id ?? this.id,
      invId: invId ?? this.invId,
      refId: refId ?? this.refId,
      refType: refType ?? this.refType,
      type: type ?? this.type,
      date: date ?? this.date,
      desc: desc ?? this.desc,
      category: category ?? this.category,
      amount: amount ?? this.amount,
      inputVatAmount: inputVatAmount ?? this.inputVatAmount,
      supplierKraPin: supplierKraPin ?? this.supplierKraPin,
      supplierName: supplierName ?? this.supplierName,
      supplierCuInvoiceNumber:
          supplierCuInvoiceNumber ?? this.supplierCuInvoiceNumber,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
