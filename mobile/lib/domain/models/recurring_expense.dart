import 'app_helpers.dart';

/// Monthly recurring expense entity matching `recurringExpenses` in `data.js` and `payroll.js`.
class RecurringExpense {
  const RecurringExpense({
    required this.id,
    required this.desc,
    this.category = 'rent',
    required this.amount,
    this.dueDay = '1',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String desc;
  final String category;
  final double amount;
  final String dueDay;
  final String? createdAt;
  final String? updatedAt;

  factory RecurringExpense.fromJson(Map<String, dynamic> json) {
    return RecurringExpense(
      id: (json['id'] ?? '').toString(),
      desc: (json['desc'] ?? '').toString(),
      category: (json['category'] ?? 'other').toString(),
      amount: AppHelpers.parseDouble(json['amount']),
      dueDay: (json['dueDay'] ?? '1').toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'desc': desc,
      'category': category,
      'amount': amount,
      'dueDay': dueDay,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  RecurringExpense copyWith({
    String? id,
    String? desc,
    String? category,
    double? amount,
    String? dueDay,
    String? createdAt,
    String? updatedAt,
  }) {
    return RecurringExpense(
      id: id ?? this.id,
      desc: desc ?? this.desc,
      category: category ?? this.category,
      amount: amount ?? this.amount,
      dueDay: dueDay ?? this.dueDay,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
