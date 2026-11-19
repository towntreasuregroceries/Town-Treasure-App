/// Encrypted vault settings matching `settings` in `data.js` and `signature.js`.
class VaultSettings {
  const VaultSettings({
    this.signature,
    this.updatedAt,
    this.extra = const {},
  });

  final String? signature;
  final String? updatedAt;
  final Map<String, dynamic> extra;

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
}
