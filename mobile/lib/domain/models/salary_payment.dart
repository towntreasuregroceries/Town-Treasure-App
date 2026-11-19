import 'app_helpers.dart';

/// Monthly salary disbursement entity matching `salaryPayments` in `data.js` and `payroll.js`.
class SalaryPayment {
  const SalaryPayment({
    required this.id,
    required this.staffId,
    required this.staffName,
    required this.month,
    required this.amount,
    required this.datePaid,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String staffId;
  final String staffName;
  final String month;
  final double amount;
  final String datePaid;
  final String? createdAt;
  final String? updatedAt;

  factory SalaryPayment.fromJson(Map<String, dynamic> json) {
    return SalaryPayment(
      id: (json['id'] ?? '').toString(),
      staffId: (json['staffId'] ?? '').toString(),
      staffName: (json['staffName'] ?? '').toString(),
      month: (json['month'] ?? '').toString(),
      amount: AppHelpers.parseDouble(json['amount']),
      datePaid: (json['datePaid'] ?? '').toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'staffId': staffId,
      'staffName': staffName,
      'month': month,
      'amount': amount,
      'datePaid': datePaid,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  SalaryPayment copyWith({
    String? id,
    String? staffId,
    String? staffName,
    String? month,
    double? amount,
    String? datePaid,
    String? createdAt,
    String? updatedAt,
  }) {
    return SalaryPayment(
      id: id ?? this.id,
      staffId: staffId ?? this.staffId,
      staffName: staffName ?? this.staffName,
      month: month ?? this.month,
      amount: amount ?? this.amount,
      datePaid: datePaid ?? this.datePaid,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
