import 'app_helpers.dart';

/// Partial repayment entry on a `Borrowing` loan matching `payroll.js`.
class Repayment {
  const Repayment({
    required this.id,
    required this.date,
    required this.amount,
    this.desc = '',
  });

  final String id;
  final String date;
  final double amount;
  final String desc;

  factory Repayment.fromJson(Map<String, dynamic> json) {
    return Repayment(
      id: (json['id'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      amount: AppHelpers.parseDouble(json['amount']),
      desc: (json['desc'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date,
      'amount': amount,
      'desc': desc,
    };
  }

  Repayment copyWith({
    String? id,
    String? date,
    double? amount,
    String? desc,
  }) {
    return Repayment(
      id: id ?? this.id,
      date: date ?? this.date,
      amount: amount ?? this.amount,
      desc: desc ?? this.desc,
    );
  }
}
