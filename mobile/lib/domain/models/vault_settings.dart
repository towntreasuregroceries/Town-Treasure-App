import 'kra_tax.dart';
import 'personal_document.dart';

/// Encrypted vault settings matching `settings` in `data.js` and `signature.js`.
class VaultSettings {
  const VaultSettings({
    this.signature,
    this.updatedAt,
    this.extra = const {},
  });

  static const String keyKraProfile = 'kraProfile';
  static const String keyPersonalDocs = 'personalDocs';
  static const String keyPersonalDocsWorkerUrl = 'personalDocsWorkerUrl';

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
}
