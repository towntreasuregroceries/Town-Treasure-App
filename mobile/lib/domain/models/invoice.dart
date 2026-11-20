import 'app_helpers.dart';
import 'invoice_line_item.dart';

/// Invoice entity matching `invoices` and `deletedInvoices` in `data.js` & `invoices.js`.
class Invoice {
  const Invoice({
    required this.id,
    this.sourceSubmissionId,
    required this.number,
    required this.restaurantId,
    required this.restaurantName,
    required this.date,
    this.dueDate = '',
    this.items = const [],
    this.totalSell = 0,
    this.totalBuy = 0,
    this.deliveryCost = 0,
    this.otherCost = 0,
    this.profit = 0,
    this.notes = '',
    this.status = 'pending',
    this.paidDate,
    this.deletedAt,
    this.originalStatus,
    this.createdAt,
    this.updatedAt,
    this.vatMode,
    this.cuInvoiceNumber,
    this.cuSerial,
    this.etimsQrData,
    this.etimsRcptSign,
    this.etimsIntrData,
    this.etimsSubmittedAt,
  });

  final String id;
  final String? sourceSubmissionId;
  final String number;
  final String restaurantId;
  final String restaurantName;
  final String date;
  final String dueDate;
  final List<InvoiceLineItem> items;
  final double totalSell;
  final double totalBuy;
  final double deliveryCost;
  final double otherCost;
  final double profit;
  final String notes;
  final String status;
  final String? paidDate;
  final String? deletedAt;
  final String? originalStatus;
  final String? createdAt;
  final String? updatedAt;
  final String? vatMode;
  final String? cuInvoiceNumber;
  final String? cuSerial;
  final String? etimsQrData;
  final String? etimsRcptSign;
  final String? etimsIntrData;
  final String? etimsSubmittedAt;

  bool get isDraft => status == 'draft';
  bool get isPaid => status == 'paid';

  factory Invoice.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((e) => InvoiceLineItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <InvoiceLineItem>[];

    final totalSell = AppHelpers.parseDouble(json['totalSell']);
    final totalBuy = AppHelpers.parseDouble(json['totalBuy']);
    final deliveryCost = AppHelpers.parseDouble(json['deliveryCost']);
    final otherCost = AppHelpers.parseDouble(json['otherCost']);
    final profit = json['profit'] != null
        ? AppHelpers.parseDouble(json['profit'])
        : (totalSell - totalBuy - deliveryCost - otherCost);

    return Invoice(
      id: (json['id'] ?? '').toString(),
      sourceSubmissionId: json['sourceSubmissionId']?.toString(),
      number: (json['number'] ?? '').toString(),
      restaurantId: (json['restaurantId'] ?? '').toString(),
      restaurantName: (json['restaurantName'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      dueDate: (json['dueDate'] ?? '').toString(),
      items: items,
      totalSell: totalSell,
      totalBuy: totalBuy,
      deliveryCost: deliveryCost,
      otherCost: otherCost,
      profit: profit,
      notes: (json['notes'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      paidDate: json['paidDate']?.toString(),
      deletedAt: json['deletedAt']?.toString(),
      originalStatus: json['originalStatus']?.toString(),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      vatMode: json['vatMode']?.toString(),
      cuInvoiceNumber: json['cuInvoiceNumber']?.toString(),
      cuSerial: json['cuSerial']?.toString(),
      etimsQrData: json['etimsQrData']?.toString(),
      etimsRcptSign: json['etimsRcptSign']?.toString(),
      etimsIntrData: json['etimsIntrData']?.toString(),
      etimsSubmittedAt: json['etimsSubmittedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (sourceSubmissionId != null) 'sourceSubmissionId': sourceSubmissionId,
      'number': number,
      'restaurantId': restaurantId,
      'restaurantName': restaurantName,
      'date': date,
      'dueDate': dueDate,
      'items': items.map((e) => e.toJson()).toList(),
      'totalSell': totalSell,
      'totalBuy': totalBuy,
      'deliveryCost': deliveryCost,
      'otherCost': otherCost,
      'profit': profit,
      'notes': notes,
      'status': status,
      if (paidDate != null) 'paidDate': paidDate,
      if (deletedAt != null) 'deletedAt': deletedAt,
      if (originalStatus != null) 'originalStatus': originalStatus,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
      if (vatMode != null && vatMode!.isNotEmpty) 'vatMode': vatMode,
      if (cuInvoiceNumber != null && cuInvoiceNumber!.isNotEmpty)
        'cuInvoiceNumber': cuInvoiceNumber,
      if (cuSerial != null && cuSerial!.isNotEmpty) 'cuSerial': cuSerial,
      if (etimsQrData != null && etimsQrData!.isNotEmpty)
        'etimsQrData': etimsQrData,
      if (etimsRcptSign != null && etimsRcptSign!.isNotEmpty)
        'etimsRcptSign': etimsRcptSign,
      if (etimsIntrData != null && etimsIntrData!.isNotEmpty)
        'etimsIntrData': etimsIntrData,
      if (etimsSubmittedAt != null && etimsSubmittedAt!.isNotEmpty)
        'etimsSubmittedAt': etimsSubmittedAt,
    };
  }

  Invoice copyWith({
    String? id,
    String? sourceSubmissionId,
    String? number,
    String? restaurantId,
    String? restaurantName,
    String? date,
    String? dueDate,
    List<InvoiceLineItem>? items,
    double? totalSell,
    double? totalBuy,
    double? deliveryCost,
    double? otherCost,
    double? profit,
    String? notes,
    String? status,
    String? paidDate,
    bool clearPaidDate = false,
    String? deletedAt,
    bool clearDeletedAt = false,
    String? originalStatus,
    bool clearOriginalStatus = false,
    String? createdAt,
    String? updatedAt,
    String? vatMode,
    String? cuInvoiceNumber,
    String? cuSerial,
    String? etimsQrData,
    String? etimsRcptSign,
    String? etimsIntrData,
    String? etimsSubmittedAt,
    bool clearEtims = false,
  }) {
    return Invoice(
      id: id ?? this.id,
      sourceSubmissionId: sourceSubmissionId ?? this.sourceSubmissionId,
      number: number ?? this.number,
      restaurantId: restaurantId ?? this.restaurantId,
      restaurantName: restaurantName ?? this.restaurantName,
      date: date ?? this.date,
      dueDate: dueDate ?? this.dueDate,
      items: items ?? this.items,
      totalSell: totalSell ?? this.totalSell,
      totalBuy: totalBuy ?? this.totalBuy,
      deliveryCost: deliveryCost ?? this.deliveryCost,
      otherCost: otherCost ?? this.otherCost,
      profit: profit ?? this.profit,
      notes: notes ?? this.notes,
      status: status ?? this.status,
      paidDate: clearPaidDate ? null : (paidDate ?? this.paidDate),
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      originalStatus:
          clearOriginalStatus ? null : (originalStatus ?? this.originalStatus),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      vatMode: vatMode ?? this.vatMode,
      cuInvoiceNumber:
          clearEtims ? null : (cuInvoiceNumber ?? this.cuInvoiceNumber),
      cuSerial: clearEtims ? null : (cuSerial ?? this.cuSerial),
      etimsQrData: clearEtims ? null : (etimsQrData ?? this.etimsQrData),
      etimsRcptSign:
          clearEtims ? null : (etimsRcptSign ?? this.etimsRcptSign),
      etimsIntrData:
          clearEtims ? null : (etimsIntrData ?? this.etimsIntrData),
      etimsSubmittedAt:
          clearEtims ? null : (etimsSubmittedAt ?? this.etimsSubmittedAt),
    );
  }
}
