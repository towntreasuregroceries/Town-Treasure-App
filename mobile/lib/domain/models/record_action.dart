import 'app_helpers.dart';

/// Tombstone/restore timestamp entry for a record inside `recordActions` (`data.js`).
class RecordAction {
  const RecordAction({
    this.deletedAt = 0,
    this.restoredAt = 0,
  });

  final int deletedAt;
  final int restoredAt;

  /// Matches `isRecordDeleted` in `data.js`:
  /// deleted when `deletedAt > 0 && deletedAt >= restoredAt`.
  bool get isDeleted => deletedAt > 0 && deletedAt >= restoredAt;

  factory RecordAction.fromJson(Map<String, dynamic> json) {
    return RecordAction(
      deletedAt: AppHelpers.parseInt(json['deletedAt']),
      restoredAt: AppHelpers.parseInt(json['restoredAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deletedAt': deletedAt,
      'restoredAt': restoredAt,
    };
  }

  RecordAction copyWith({int? deletedAt, int? restoredAt}) {
    return RecordAction(
      deletedAt: deletedAt ?? this.deletedAt,
      restoredAt: restoredAt ?? this.restoredAt,
    );
  }
}
