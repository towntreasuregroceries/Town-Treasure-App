import 'app_helpers.dart';

/// Staff member entity matching `staff` and `deletedStaff` in `data.js` and `payroll.js`.
class Staff {
  const Staff({
    required this.id,
    required this.name,
    this.role = '',
    required this.salary,
    this.phone = '',
    this.payDay = '5',
    this.status = 'active',
    this.deletedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String role;
  final double salary;
  final String phone;
  final String payDay;
  final String status;
  final String? deletedAt;
  final String? createdAt;
  final String? updatedAt;

  bool get isActive => status == 'active';

  factory Staff.fromJson(Map<String, dynamic> json) {
    return Staff(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      salary: AppHelpers.parseDouble(json['salary']),
      phone: (json['phone'] ?? '').toString(),
      payDay: (json['payDay'] ?? '5').toString(),
      status: (json['status'] ?? 'active').toString(),
      deletedAt: json['deletedAt']?.toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'role': role,
      'salary': salary,
      'phone': phone,
      'payDay': payDay,
      'status': status,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  Staff copyWith({
    String? id,
    String? name,
    String? role,
    double? salary,
    String? phone,
    String? payDay,
    String? status,
    String? deletedAt,
    bool clearDeletedAt = false,
    String? createdAt,
    String? updatedAt,
  }) {
    return Staff(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      salary: salary ?? this.salary,
      phone: phone ?? this.phone,
      payDay: payDay ?? this.payDay,
      status: status ?? this.status,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
