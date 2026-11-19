import 'app_helpers.dart';
import 'invoice_line_item.dart';

/// Clerk staging docket matching `staged_invoices` schema in `staging.js` & SQL.
class StagingDocket {
  const StagingDocket({
    required this.id,
    this.ownerUserId,
    this.submittedByInviteId,
    this.submissionKey,
    this.clerkName = 'Clerk',
    this.restaurantName = 'General Wholesale',
    required this.invoiceDate,
    this.itemsJson = const [],
    this.deliveryCost = 0,
    this.otherCost = 0,
    this.totalSell = 0,
    this.totalBuy = 0,
    this.receiptPhoto,
    this.receiptPhotos = const [],
    this.notes = '',
    this.status = 'pending',
    this.rejectionReason = '',
    this.targetUserId,
    this.targetUserEmail,
    this.targetUserName,
    this.approvedAt,
    this.generatedInvoiceNumber,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? ownerUserId;
  final String? submittedByInviteId;
  final String? submissionKey;
  final String clerkName;
  final String restaurantName;
  final String invoiceDate;
  final List<InvoiceLineItem> itemsJson;
  final double deliveryCost;
  final double otherCost;
  final double totalSell;
  final double totalBuy;
  final String? receiptPhoto;
  final List<String> receiptPhotos;
  final String notes;
  final String status;
  final String rejectionReason;
  final String? targetUserId;
  final String? targetUserEmail;
  final String? targetUserName;
  final String? approvedAt;
  final String? generatedInvoiceNumber;
  final String? createdAt;
  final String? updatedAt;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  factory StagingDocket.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items_json'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((e) => InvoiceLineItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <InvoiceLineItem>[];

    final rawPhotos = json['receipt_photos'];
    final photos = rawPhotos is List
        ? rawPhotos
            .map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];
    final singlePhoto = AppHelpers.nullableString(json['receipt_photo']);
    final effectivePhotos = photos.isNotEmpty
        ? photos
        : (singlePhoto != null ? [singlePhoto] : <String>[]);

    return StagingDocket(
      id: (json['id'] ?? '').toString(),
      ownerUserId: AppHelpers.nullableString(json['owner_user_id']),
      submittedByInviteId:
          AppHelpers.nullableString(json['submitted_by_invite_id']),
      submissionKey: AppHelpers.nullableString(json['submission_key']),
      clerkName: (json['clerk_name'] ?? 'Clerk').toString(),
      restaurantName: (json['restaurant_name'] ?? 'General Wholesale').toString(),
      invoiceDate: (json['invoice_date'] ?? '').toString(),
      itemsJson: items,
      deliveryCost: AppHelpers.parseDouble(json['delivery_cost']),
      otherCost: AppHelpers.parseDouble(json['other_cost']),
      totalSell: AppHelpers.parseDouble(json['total_sell']),
      totalBuy: AppHelpers.parseDouble(json['total_buy']),
      receiptPhoto:
          singlePhoto ?? (effectivePhotos.isNotEmpty ? effectivePhotos.first : null),
      receiptPhotos: effectivePhotos,
      notes: (json['notes'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      rejectionReason: (json['rejection_reason'] ?? '').toString(),
      targetUserId: AppHelpers.nullableString(json['target_user_id']),
      targetUserEmail: AppHelpers.nullableString(json['target_user_email']),
      targetUserName: AppHelpers.nullableString(json['target_user_name']),
      approvedAt: AppHelpers.nullableString(json['approved_at']),
      generatedInvoiceNumber:
          AppHelpers.nullableString(json['generated_invoice_number']),
      createdAt: AppHelpers.nullableString(json['created_at']),
      updatedAt: AppHelpers.nullableString(json['updated_at']),
    );
  }

  Map<String, dynamic> toJson({bool includePhotos = true}) {
    return {
      'id': id,
      if (ownerUserId != null) 'owner_user_id': ownerUserId,
      if (submittedByInviteId != null)
        'submitted_by_invite_id': submittedByInviteId,
      if (submissionKey != null) 'submission_key': submissionKey,
      'clerk_name': clerkName,
      'restaurant_name': restaurantName,
      'invoice_date': invoiceDate,
      'items_json': itemsJson.map((e) => e.toJson()).toList(),
      'delivery_cost': deliveryCost,
      'other_cost': otherCost,
      'total_sell': totalSell,
      'total_buy': totalBuy,
      if (includePhotos) 'receipt_photo': receiptPhoto,
      if (includePhotos) 'receipt_photos': receiptPhotos,
      'notes': notes,
      'status': status,
      'rejection_reason': rejectionReason,
      'target_user_id': targetUserId,
      'target_user_email': targetUserEmail,
      'target_user_name': targetUserName,
      if (approvedAt != null) 'approved_at': approvedAt,
      if (generatedInvoiceNumber != null)
        'generated_invoice_number': generatedInvoiceNumber,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    };
  }

  StagingDocket copyWith({
    String? id,
    String? ownerUserId,
    String? submittedByInviteId,
    String? submissionKey,
    String? clerkName,
    String? restaurantName,
    String? invoiceDate,
    List<InvoiceLineItem>? itemsJson,
    double? deliveryCost,
    double? otherCost,
    double? totalSell,
    double? totalBuy,
    String? receiptPhoto,
    List<String>? receiptPhotos,
    String? notes,
    String? status,
    String? rejectionReason,
    String? targetUserId,
    String? targetUserEmail,
    String? targetUserName,
    String? approvedAt,
    String? generatedInvoiceNumber,
    String? createdAt,
    String? updatedAt,
  }) {
    return StagingDocket(
      id: id ?? this.id,
      ownerUserId: ownerUserId ?? this.ownerUserId,
      submittedByInviteId: submittedByInviteId ?? this.submittedByInviteId,
      submissionKey: submissionKey ?? this.submissionKey,
      clerkName: clerkName ?? this.clerkName,
      restaurantName: restaurantName ?? this.restaurantName,
      invoiceDate: invoiceDate ?? this.invoiceDate,
      itemsJson: itemsJson ?? this.itemsJson,
      deliveryCost: deliveryCost ?? this.deliveryCost,
      otherCost: otherCost ?? this.otherCost,
      totalSell: totalSell ?? this.totalSell,
      totalBuy: totalBuy ?? this.totalBuy,
      receiptPhoto: receiptPhoto ?? this.receiptPhoto,
      receiptPhotos: receiptPhotos ?? this.receiptPhotos,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      targetUserId: targetUserId ?? this.targetUserId,
      targetUserEmail: targetUserEmail ?? this.targetUserEmail,
      targetUserName: targetUserName ?? this.targetUserName,
      approvedAt: approvedAt ?? this.approvedAt,
      generatedInvoiceNumber:
          generatedInvoiceNumber ?? this.generatedInvoiceNumber,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
