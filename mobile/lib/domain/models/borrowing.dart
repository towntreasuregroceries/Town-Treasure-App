import 'app_helpers.dart';
import 'repayment.dart';

/// Boss loan / borrowing entity matching `borrowings` in `data.js` and `payroll.js`.
class Borrowing {
  const Borrowing({
    required this.id,
    required this.date,
    this.desc = '',
    required this.amount,
    this.type,
    this.repayments = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String date;
  final String desc;
  final double amount;
  final String? type;
  final List<Repayment> repayments;
  final String? createdAt;
  final String? updatedAt;

  double get totalRepaid =>
      repayments.fold<double>(0, (sum, r) => sum + r.amount);

  double get outstandingBalance => amount - totalRepaid;

  factory Borrowing.fromJson(Map<String, dynamic> json) {
    final rawRepayments = json['repayments'];
    final repayments = rawRepayments is List
        ? rawRepayments
            .whereType<Map>()
            .map((e) => Repayment.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <Repayment>[];

    return Borrowing(
      id: (json['id'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      desc: (json['desc'] ?? '').toString(),
      amount: AppHelpers.parseDouble(json['amount']),
      type: json['type']?.toString(),
      repayments: repayments,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date,
      'desc': desc,
      'amount': amount,
      if (type != null) 'type': type,
      'repayments': repayments.map((e) => e.toJson()).toList(),
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  Borrowing copyWith({
    String? id,
    String? date,
    String? desc,
    double? amount,
    String? type,
    List<Repayment>? repayments,
    String? createdAt,
    String? updatedAt,
  }) {
    return Borrowing(
      id: id ?? this.id,
      date: date ?? this.date,
      desc: desc ?? this.desc,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      repayments: repayments ?? this.repayments,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
