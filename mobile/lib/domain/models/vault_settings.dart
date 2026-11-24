import 'branded_document.dart';
import 'kra_tax.dart';
import 'personal_document.dart';
import 'restaurant.dart';

/// Encrypted vault settings matching `settings` in `data.js` and `signature.js`.
class VaultSettings {
  const VaultSettings({
    this.signature,
    this.updatedAt,
    this.extra = const {},
  });

  static const String keyKraProfile = 'kraProfile';
  static const String keyMonthlyEtims = 'kraMonthlyEtims';
  static const String keyTaxableKeywords = 'kraTaxableKeywords';
  static const String keyPersonalDocs = 'personalDocs';
  static const String keyPersonalDocsWorkerUrl = 'personalDocsWorkerUrl';
  static const String keyBrandedDocs = 'brandedDocs';

  final String? signature;
  final String? updatedAt;
  final Map<String, dynamic> extra;

  KraCompanyProfile get kraProfile {
    final raw = extra[keyKraProfile];
    if (raw is Map) {
      return KraCompanyProfile.fromJson(Map<String, dynamic>.from(raw));
    }
    return const KraCompanyProfile();
  }

  String get personalDocsWorkerUrl =>
      (extra[keyPersonalDocsWorkerUrl] ?? '').toString().trim();

  /// Self-learned keywords for items that carry 16% VAT.
  List<String> get kraTaxableKeywords {
    final raw = extra[keyTaxableKeywords];
    if (raw is! List) return const [];
    return raw
        .map((e) => (e ?? '').toString().trim().toLowerCase())
        .where((e) => e.length >= 3)
        .toSet()
        .toList();
  }

  /// Returns all saved consolidated monthly client eTIMS records.
  List<MonthlyClientEtims> get monthlyEtimsRecords {
    final raw = extra[keyMonthlyEtims];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => MonthlyClientEtims.fromJson(Map<String, dynamic>.from(e)))
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  /// Looks up a consolidated monthly eTIMS record by `monthYm` and client.
  MonthlyClientEtims? findMonthlyEtims(
    String monthYm,
    Restaurant? restaurant, {
    String? fallbackName,
  }) {
    final targetId = MonthlyClientEtims.buildId(monthYm, restaurant, fallbackName);
    for (final rec in monthlyEtimsRecords) {
      if (rec.id == targetId) return rec;
      if (rec.month == monthYm &&
          restaurant != null &&
          restaurant.id.isNotEmpty &&
          rec.restaurantId == restaurant.id) {
        return rec;
      }
      final nameToMatch = (restaurant?.name ?? fallbackName ?? '').trim().toLowerCase();
      if (rec.month == monthYm &&
          nameToMatch.isNotEmpty &&
          rec.restaurantName.trim().toLowerCase() == nameToMatch) {
        return rec;
      }
    }
    return null;
  }

  /// Returns all stored personal document metadata (including soft-deleted tombstones for sync).
  List<PersonalDocument> get allPersonalDocumentsRaw {
    final raw = extra[keyPersonalDocs];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => PersonalDocument.fromJson(Map<String, dynamic>.from(e)))
        .where((d) => d.id.isNotEmpty)
        .toList();
  }

  /// Returns active (non-deleted) personal document metadata sorted newest first.
  List<PersonalDocument> get personalDocuments {
    final list =
        allPersonalDocumentsRaw.where((d) => !d.isDeleted).toList();
    list.sort((a, b) {
      final expA = a.parsedExpiryDate;
      final expB = b.parsedExpiryDate;
      if (expA != null && expB != null) return expA.compareTo(expB);
      if (expA != null) return -1;
      if (expB != null) return 1;
      return (b.updatedAt ?? b.createdAt ?? '').compareTo(
        a.updatedAt ?? a.createdAt ?? '',
      );
    });
    return list;
  }

  /// Returns all stored branded documents (including soft-deleted tombstones for sync).
  List<BrandedDocument> get allBrandedDocumentsRaw {
    final raw = extra[keyBrandedDocs];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => BrandedDocument.fromJson(Map<String, dynamic>.from(e)))
        .where((d) => d.id.isNotEmpty)
        .toList();
  }

  /// Returns active (non-deleted) branded documents sorted newest first.
  List<BrandedDocument> get brandedDocuments {
    final list = allBrandedDocumentsRaw.where((d) => !d.isDeleted).toList();
    list.sort(
      (a, b) => (b.updatedAt ?? b.createdAt ?? '').compareTo(
        a.updatedAt ?? a.createdAt ?? '',
      ),
    );
    return list;
  }

  factory VaultSettings.fromJson(Map<String, dynamic> json) {
    final extra = Map<String, dynamic>.from(json)
      ..remove('signature')
      ..remove('updatedAt');
    return VaultSettings(
      signature: json['signature']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      ...extra,
      if (signature != null) 'signature': signature,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  VaultSettings copyWith({
    String? signature,
    bool clearSignature = false,
    String? updatedAt,
    Map<String, dynamic>? extra,
  }) {
    return VaultSettings(
      signature: clearSignature ? null : (signature ?? this.signature),
      updatedAt: updatedAt ?? this.updatedAt,
      extra: extra ?? this.extra,
    );
  }

  VaultSettings withKraProfile(KraCompanyProfile profile) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    nextExtra[keyKraProfile] = profile.copyWith(updatedAt: nowIso).toJson();
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }

  VaultSettings withMonthlyEtims(List<MonthlyClientEtims> records) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    nextExtra[keyMonthlyEtims] = records.map((r) => r.toJson()).toList();
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }

  VaultSettings withKraTaxableKeywords(List<String> keywords) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    nextExtra[keyTaxableKeywords] = keywords
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.length >= 3)
        .toSet()
        .take(200)
        .toList();
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }

  VaultSettings withPersonalDocuments(List<PersonalDocument> docs) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    nextExtra[keyPersonalDocs] = docs.map((d) => d.toJson()).toList();
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }

  VaultSettings withPersonalDocsWorkerUrl(String url) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) {
      nextExtra.remove(keyPersonalDocsWorkerUrl);
    } else {
      nextExtra[keyPersonalDocsWorkerUrl] = trimmed;
    }
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }

  VaultSettings withBrandedDocuments(List<BrandedDocument> docs) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextExtra = Map<String, dynamic>.from(extra);
    nextExtra[keyBrandedDocs] = docs.map((d) => d.toJson()).toList();
    return copyWith(updatedAt: nowIso, extra: nextExtra);
  }
}
