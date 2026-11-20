import 'app_helpers.dart';

/// Categories for encrypted personal & business compliance documents in the Vault.
enum PersonalDocCategory {
  kraTax('kra_tax', 'KRA & Tax'),
  companyReg('company_reg', 'Company & Reg'),
  permits('permits', 'Permits & Licenses'),
  personalId('personal_id', 'Personal IDs'),
  contracts('contracts', 'Contracts'),
  banking('banking', 'Banking'),
  other('other', 'Other');

  const PersonalDocCategory(this.code, this.label);
  final String code;
  final String label;

  static PersonalDocCategory fromCode(String? raw) {
    final norm = (raw ?? '').trim().toLowerCase();
    for (final value in PersonalDocCategory.values) {
      if (value.code == norm) return value;
    }
    return PersonalDocCategory.other;
  }
}

/// Encrypted metadata record stored in `VaultSettings` while raw encrypted
/// bytes live in Cloudflare R2 (`users/<uid>/docs/<id>.enc`) + local `.enc` cache.
class PersonalDocument {
  const PersonalDocument({
    required this.id,
    required this.title,
    this.category = PersonalDocCategory.kraTax,
    this.docNumber = '',
    this.issuer = '',
    this.issueDate = '',
    this.expiryDate = '',
    this.alertDaysBefore = 30,
    this.mimeType = 'application/pdf',
    this.originalFileName = '',
    this.plainBytes = 0,
    this.sha256 = '',
    this.notes = '',
    this.r2Synced = false,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String title;
  final PersonalDocCategory category;
  final String docNumber;
  final String issuer;
  final String issueDate;
  final String expiryDate;
  final int alertDaysBefore;
  final String mimeType;
  final String originalFileName;
  final int plainBytes;
  final String sha256;
  final String notes;
  final bool r2Synced;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;

  bool get isDeleted => deletedAt != null && deletedAt!.isNotEmpty;
  bool get isPdf => mimeType.toLowerCase().contains('pdf');

  DateTime? get parsedExpiryDate {
    final clean = expiryDate.trim();
    if (clean.isEmpty) return null;
    return DateTime.tryParse(clean);
  }

  /// Whole-day delta from [now] (`< 0` = already expired, `0` = today, `> 0` = days left).
  int? daysUntilExpiry([DateTime? now]) {
    final exp = parsedExpiryDate;
    if (exp == null) return null;
    final ref = now ?? DateTime.now();
    final refDate = DateTime(ref.year, ref.month, ref.day);
    final expDate = DateTime(exp.year, exp.month, exp.day);
    return expDate.difference(refDate).inDays;
  }

  bool isExpired([DateTime? now]) {
    final days = daysUntilExpiry(now);
    return days != null && days < 0;
  }

  bool isExpiringSoon([DateTime? now]) {
    final days = daysUntilExpiry(now);
    return days != null && days <= alertDaysBefore;
  }

  factory PersonalDocument.fromJson(Map<String, dynamic> json) {
    return PersonalDocument(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      category: PersonalDocCategory.fromCode(json['category']?.toString()),
      docNumber: (json['docNumber'] ?? '').toString(),
      issuer: (json['issuer'] ?? '').toString(),
      issueDate: (json['issueDate'] ?? '').toString(),
      expiryDate: (json['expiryDate'] ?? '').toString(),
      alertDaysBefore: AppHelpers.parseInt(json['alertDaysBefore'], 30),
      mimeType: (json['mimeType'] ?? 'application/pdf').toString(),
      originalFileName: (json['originalFileName'] ?? '').toString(),
      plainBytes: AppHelpers.parseInt(json['plainBytes']),
      sha256: (json['sha256'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
      r2Synced: json['r2Synced'] == true,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      deletedAt: json['deletedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'category': category.code,
      'docNumber': docNumber,
      'issuer': issuer,
      'issueDate': issueDate,
      'expiryDate': expiryDate,
      'alertDaysBefore': alertDaysBefore,
      'mimeType': mimeType,
      'originalFileName': originalFileName,
      'plainBytes': plainBytes,
      'sha256': sha256,
      'notes': notes,
      'r2Synced': r2Synced,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
      if (deletedAt != null) 'deletedAt': deletedAt,
    };
  }

  PersonalDocument copyWith({
    String? id,
    String? title,
    PersonalDocCategory? category,
    String? docNumber,
    String? issuer,
    String? issueDate,
    String? expiryDate,
    int? alertDaysBefore,
    String? mimeType,
    String? originalFileName,
    int? plainBytes,
    String? sha256,
    String? notes,
    bool? r2Synced,
    String? createdAt,
    String? updatedAt,
    String? deletedAt,
    bool clearDeletedAt = false,
  }) {
    return PersonalDocument(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      docNumber: docNumber ?? this.docNumber,
      issuer: issuer ?? this.issuer,
      issueDate: issueDate ?? this.issueDate,
      expiryDate: expiryDate ?? this.expiryDate,
      alertDaysBefore: alertDaysBefore ?? this.alertDaysBefore,
      mimeType: mimeType ?? this.mimeType,
      originalFileName: originalFileName ?? this.originalFileName,
      plainBytes: plainBytes ?? this.plainBytes,
      sha256: sha256 ?? this.sha256,
      notes: notes ?? this.notes,
      r2Synced: r2Synced ?? this.r2Synced,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
    );
  }
}
