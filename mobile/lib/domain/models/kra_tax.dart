import 'expense.dart';
import 'invoice.dart';
import 'invoice_line_item.dart';
import 'restaurant.dart';

/// Kenyan VAT tax classifications per invoice line item.
enum KraTaxRate {
  exempt('exempt', 'VAT Exempt', 0.0),
  zeroRated('zero_rated', 'Zero-Rated (0%)', 0.0),
  standard16('standard_16', 'Standard VAT (16%)', 0.16);

  const KraTaxRate(this.code, this.label, this.rate);
  final String code;
  final String label;
  final double rate;

  static KraTaxRate fromCode(String? raw, {KraTaxRate fallback = KraTaxRate.exempt}) {
    final norm = (raw ?? '').trim().toLowerCase();
    for (final value in KraTaxRate.values) {
      if (value.code == norm) return value;
    }
    return fallback;
  }
}

/// Controls whether line prices entered already include 16% VAT or add 16% VAT on top.
enum KraVatMode {
  inclusive('inclusive', 'VAT Inclusive'),
  exclusive('exclusive', 'VAT Exclusive');

  const KraVatMode(this.code, this.label);
  final String code;
  final String label;

  static KraVatMode fromCode(String? raw) {
    return (raw ?? '').trim().toLowerCase() == 'exclusive'
        ? KraVatMode.exclusive
        : KraVatMode.inclusive;
  }
}

/// Company KRA tax & eTIMS OSCU configuration stored inside `VaultSettings` (`kraProfile`).
class KraCompanyProfile {
  const KraCompanyProfile({
    this.sellerKraPin = '',
    this.vatNumber = '',
    this.vatRegistered = true,
    this.defaultTaxRate = KraTaxRate.exempt,
    this.defaultVatMode = KraVatMode.inclusive,
    this.cuSerialNumber = '',
    this.etimsBranchId = '00',
    this.oscuSandbox = true,
    this.oscuRelayUrl = '',
    this.updatedAt,
  });

  final String sellerKraPin;
  final String vatNumber;
  final bool vatRegistered;
  final KraTaxRate defaultTaxRate;
  final KraVatMode defaultVatMode;
  final String cuSerialNumber;
  final String etimsBranchId;
  final bool oscuSandbox;
  final String oscuRelayUrl;
  final String? updatedAt;

  String get normalizedSellerPin => Restaurant.normalizeKraPin(sellerKraPin);
  bool get hasValidSellerPin =>
      normalizedSellerPin.isNotEmpty &&
      Restaurant.isValidKraPin(normalizedSellerPin);

  factory KraCompanyProfile.fromJson(Map<String, dynamic> json) {
    return KraCompanyProfile(
      sellerKraPin: (json['sellerKraPin'] ?? '').toString(),
      vatNumber: (json['vatNumber'] ?? '').toString(),
      vatRegistered: json['vatRegistered'] != false,
      defaultTaxRate: KraTaxRate.fromCode(json['defaultTaxRate']?.toString()),
      defaultVatMode: KraTaxRate.values.isNotEmpty
          ? KraVatMode.fromCode(json['defaultVatMode']?.toString())
          : KraVatMode.inclusive,
      cuSerialNumber: (json['cuSerialNumber'] ?? '').toString(),
      etimsBranchId: (json['etimsBranchId'] ?? '00').toString(),
      oscuSandbox: json['oscuSandbox'] != false,
      oscuRelayUrl: (json['oscuRelayUrl'] ?? '').toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sellerKraPin': normalizedSellerPin,
      'vatNumber': vatNumber.trim().toUpperCase(),
      'vatRegistered': vatRegistered,
      'defaultTaxRate': defaultTaxRate.code,
      'defaultVatMode': defaultVatMode.code,
      'cuSerialNumber': cuSerialNumber.trim().toUpperCase(),
      'etimsBranchId': etimsBranchId.trim().isEmpty ? '00' : etimsBranchId.trim(),
      'oscuSandbox': oscuSandbox,
      if (oscuRelayUrl.trim().isNotEmpty)
        'oscuRelayUrl': oscuRelayUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  KraCompanyProfile copyWith({
    String? sellerKraPin,
    String? vatNumber,
    bool? vatRegistered,
    KraTaxRate? defaultTaxRate,
    KraVatMode? defaultVatMode,
    String? cuSerialNumber,
    String? etimsBranchId,
    bool? oscuSandbox,
    String? oscuRelayUrl,
    String? updatedAt,
  }) {
    return KraCompanyProfile(
      sellerKraPin: sellerKraPin ?? this.sellerKraPin,
      vatNumber: vatNumber ?? this.vatNumber,
      vatRegistered: vatRegistered ?? this.vatRegistered,
      defaultTaxRate: defaultTaxRate ?? this.defaultTaxRate,
      defaultVatMode: defaultVatMode ?? this.defaultVatMode,
      cuSerialNumber: cuSerialNumber ?? this.cuSerialNumber,
      etimsBranchId: etimsBranchId ?? this.etimsBranchId,
      oscuSandbox: oscuSandbox ?? this.oscuSandbox,
      oscuRelayUrl: oscuRelayUrl ?? this.oscuRelayUrl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class KraLineTaxBreakdown {
  const KraLineTaxBreakdown({
    required this.rate,
    required this.netAmount,
    required this.vatAmount,
    required this.grossAmount,
  });

  final KraTaxRate rate;
  final double netAmount;
  final double vatAmount;
  final double grossAmount;
}

class KraInvoiceTaxSummary {
  const KraInvoiceTaxSummary({
    required this.exemptTotal,
    required this.zeroRatedTotal,
    required this.taxableNetTotal,
    required this.outputVatTotal,
    required this.subtotalNet,
    required this.grandTotalWithVat,
    required this.hasTaxableVatLines,
  });

  final double exemptTotal;
  final double zeroRatedTotal;
  final double taxableNetTotal;
  final double outputVatTotal;
  final double subtotalNet;
  final double grandTotalWithVat;
  final bool hasTaxableVatLines;
}

class KraMonthlyVat3Summary {
  const KraMonthlyVat3Summary({
    required this.month,
    required this.invoiceCount,
    required this.vatInvoiceCount,
    required this.exemptSalesTotal,
    required this.zeroRatedSalesTotal,
    required this.taxableNetSalesTotal,
    required this.outputVatTotal,
    required this.inputVatTotal,
    required this.netVatPayable,
    required this.filingDeadline,
    required this.invoicesMissingClientPin,
  });

  final String month;
  final int invoiceCount;
  final int vatInvoiceCount;
  final double exemptSalesTotal;
  final double zeroRatedSalesTotal;
  final double taxableNetSalesTotal;
  final double outputVatTotal;
  final double inputVatTotal;
  final double netVatPayable;
  final DateTime filingDeadline;
  final List<Invoice> invoicesMissingClientPin;
}

/// Pure Kenyan VAT3 & line-item tax calculation helpers.
class KraTaxCalculator {
  KraTaxCalculator._();

  static double _round2(double value) => (value * 100).roundToDouble() / 100;

  static KraLineTaxBreakdown computeLineBreakdown(
    InvoiceLineItem item, {
    required KraVatMode vatMode,
  }) {
    final rate = KraTaxRate.fromCode(item.taxRate);
    final rawTotal = item.total;
    if (rate != KraTaxRate.standard16) {
      return KraLineTaxBreakdown(
        rate: rate,
        netAmount: _round2(rawTotal),
        vatAmount: 0.0,
        grossAmount: _round2(rawTotal),
      );
    }

    if (vatMode == KraVatMode.exclusive) {
      final net = _round2(rawTotal);
      final vat = _round2(rawTotal * 0.16);
      return KraLineTaxBreakdown(
        rate: rate,
        netAmount: net,
        vatAmount: vat,
        grossAmount: _round2(net + vat),
      );
    }

    // VAT Inclusive (16 / 116)
    final gross = _round2(rawTotal);
    final net = _round2(rawTotal / 1.16);
    final vat = _round2(gross - net);
    return KraLineTaxBreakdown(
      rate: rate,
      netAmount: net,
      vatAmount: vat,
      grossAmount: gross,
    );
  }

  /// Splits an invoice cleanly into VAT-Exempt, 0% Zero-Rated, 16% Net, and Output VAT.
  /// Delivery/other charges are treated as VAT-exempt unless taxable lines exist or
  /// kept separate as exempt ancillary fees so historical totals never drift.
  static KraInvoiceTaxSummary computeInvoiceTaxSummary(
    Invoice invoice, {
    KraCompanyProfile profile = const KraCompanyProfile(),
  }) {
    final vatMode = KraVatMode.fromCode(
      invoice.vatMode ?? profile.defaultVatMode.code,
    );

    var exempt = 0.0;
    var zeroRated = 0.0;
    var taxableNet = 0.0;
    var outputVat = 0.0;
    var hasTaxable = false;

    for (final item in invoice.items) {
      final line = computeLineBreakdown(item, vatMode: vatMode);
      switch (line.rate) {
        case KraTaxRate.exempt:
          exempt += line.netAmount;
        case KraTaxRate.zeroRated:
          zeroRated += line.netAmount;
        case KraTaxRate.standard16:
          hasTaxable = true;
          taxableNet += line.netAmount;
          outputVat += line.vatAmount;
      }
    }

    final extraFees = _round2(invoice.deliveryCost + invoice.otherCost);
    exempt += extraFees;

    final subtotalNet = _round2(exempt + zeroRated + taxableNet);
    final cleanOutputVat = _round2(outputVat);

    return KraInvoiceTaxSummary(
      exemptTotal: _round2(exempt),
      zeroRatedTotal: _round2(zeroRated),
      taxableNetTotal: _round2(taxableNet),
      outputVatTotal: cleanOutputVat,
      subtotalNet: subtotalNet,
      grandTotalWithVat: _round2(subtotalNet + cleanOutputVat),
      hasTaxableVatLines: hasTaxable,
    );
  }

  /// Returns Kenyan VAT3 filing deadline: 20th of the month following [monthYm].
  static DateTime filingDeadlineForMonth(String monthYm) {
    final parts = monthYm.split('-');
    if (parts.length == 2) {
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (y != null && m != null && m >= 1 && m <= 12) {
        final nextMonth = m == 12 ? 1 : m + 1;
        final nextYear = m == 12 ? y + 1 : y;
        return DateTime(nextYear, nextMonth, 20);
      }
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, 20);
  }

  /// Aggregates monthly Output VAT, Exempt Produce Sales, Input VAT, and missing B2B KRA PINs.
  static KraMonthlyVat3Summary computeMonthlySummary({
    required String monthYm,
    required List<Invoice> invoices,
    required List<Expense> expenses,
    required List<Restaurant> restaurants,
    KraCompanyProfile profile = const KraCompanyProfile(),
  }) {
    final monthInvoices = invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(monthYm))
        .toList();

    var exempt = 0.0;
    var zeroRated = 0.0;
    var taxableNet = 0.0;
    var outputVat = 0.0;
    var vatInvCount = 0;
    final missingPins = <Invoice>[];

    for (final inv in monthInvoices) {
      final summary = computeInvoiceTaxSummary(inv, profile: profile);
      exempt += summary.exemptTotal;
      zeroRated += summary.zeroRatedTotal;
      taxableNet += summary.taxableNetTotal;
      outputVat += summary.outputVatTotal;
      if (summary.hasTaxableVatLines) {
        vatInvCount++;
      }
      final rest = Restaurant.resolveInvoiceRestaurant(inv, restaurants).restaurant;
      final pin = Restaurant.normalizeKraPin(rest?.kraPin);
      if (pin.isEmpty || !Restaurant.isValidKraPin(pin)) {
        missingPins.add(inv);
      }
    }

    var inputVat = 0.0;
    for (final exp in expenses) {
      if (!exp.isCapital && exp.date.startsWith(monthYm)) {
        inputVat += exp.inputVatAmount ?? 0.0;
      }
    }

    final cleanOutput = _round2(outputVat);
    final cleanInput = _round2(inputVat);

    return KraMonthlyVat3Summary(
      month: monthYm,
      invoiceCount: monthInvoices.length,
      vatInvoiceCount: vatInvCount,
      exemptSalesTotal: _round2(exempt),
      zeroRatedSalesTotal: _round2(zeroRated),
      taxableNetSalesTotal: _round2(taxableNet),
      outputVatTotal: cleanOutput,
      inputVatTotal: cleanInput,
      netVatPayable: _round2(cleanOutput - cleanInput),
      filingDeadline: filingDeadlineForMonth(monthYm),
      invoicesMissingClientPin: missingPins,
    );
  }

  /// Builds the official KRA eTIMS verification QR URL from Seller PIN, Branch ID (`00`),
  /// and the KRA Receipt Signature (`rcptSign`).
  static String buildEtimsQrUrl({
    required String sellerKraPin,
    required String branchId,
    required String receiptSignature,
    bool sandbox = false,
  }) {
    final raw = receiptSignature.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw;
    }
    final cleanPin = Restaurant.normalizeKraPin(sellerKraPin);
    if (cleanPin.isEmpty) return '';
    final cleanBranch = branchId.trim().isEmpty ? '00' : branchId.trim();
    final host = sandbox
        ? 'https://etims-sbx.kra.go.ke'
        : 'https://etims.kra.go.ke';
    return '$host/common/link/etims/receipt/indexEtimsInvoiceData?Data=$cleanPin$cleanBranch$raw';
  }

  /// Maps internal tax rate to KRA eTIMS OSCU `taxTyCd` (`A` Exempt, `B` 16% VAT, `C` Zero-Rated).
  static String oscuTaxCode(KraTaxRate rate) {
    return switch (rate) {
      KraTaxRate.exempt => 'A',
      KraTaxRate.standard16 => 'B',
      KraTaxRate.zeroRated => 'C',
    };
  }

  /// Builds an official KRA eTIMS OSCU `saveTrnsSalesReq` JSON payload for an invoice.
  static Map<String, dynamic> buildOscuSalesPayload({
    required Invoice invoice,
    required KraCompanyProfile profile,
    Restaurant? buyer,
    DateTime? timestamp,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    String fmtDate(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    String fmtDateTime(DateTime d) =>
        '${fmtDate(d)}${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}${d.second.toString().padLeft(2, '0')}';

    final vatMode = KraVatMode.fromCode(
      invoice.vatMode ?? profile.defaultVatMode.code,
    );
    final summary = computeInvoiceTaxSummary(invoice, profile: profile);
    final numericDigits = invoice.number.replaceAll(RegExp(r'[^0-9]'), '');
    final invcNo = int.tryParse(numericDigits) ?? 1;
    final cleanDate = invoice.date.replaceAll('-', '');
    final salesDt = cleanDate.length == 8 ? cleanDate : fmtDate(now);
    final buyerPin = Restaurant.normalizeKraPin(buyer?.kraPin);

    final itemList = <Map<String, dynamic>>[];
    for (var i = 0; i < invoice.items.length; i++) {
      final item = invoice.items[i];
      final lineTax = computeLineBreakdown(item, vatMode: vatMode);
      final code = oscuTaxCode(lineTax.rate);
      itemList.add({
        'itemSeq': i + 1,
        'itemCd': 'KE2NT${(i + 1).toString().padLeft(4, '0')}',
        'itemClsCd': '50400000', // Fresh produce / food supplies UNSPSC base
        'itemNm': item.desc,
        'pkgUnitCd': 'NT',
        'pkg': item.qty,
        'qtyUnitCd': 'KGM',
        'qty': item.qty,
        'prc': item.sellPrice,
        'splyAmt': lineTax.netAmount,
        'dcRt': 0,
        'dcAmt': 0,
        'taxTyCd': code,
        'taxblAmt': lineTax.netAmount,
        'taxAmt': lineTax.vatAmount,
        'totAmt': lineTax.grossAmount,
      });
    }

    return {
      'tin': profile.normalizedSellerPin,
      'bhfId': profile.etimsBranchId.trim().isEmpty
          ? '00'
          : profile.etimsBranchId.trim(),
      'invcNo': invcNo,
      'orgInvcNo': 0,
      if (buyerPin.isNotEmpty) 'custTin': buyerPin,
      'custNm': buyer?.name ?? invoice.restaurantName,
      'salesTyCd': 'N',
      'rcptTyCd': 'S',
      'pmtTyCd': invoice.isPaid ? '01' : '02',
      'salesSttsCd': '02',
      'cfmDt': fmtDateTime(now),
      'salesDt': salesDt,
      'totItemCnt': itemList.length,
      'taxblAmtA': summary.exemptTotal,
      'taxblAmtB': summary.taxableNetTotal,
      'taxblAmtC': summary.zeroRatedTotal,
      'taxRtA': 0,
      'taxRtB': 16,
      'taxRtC': 0,
      'taxAmtA': 0,
      'taxAmtB': summary.outputVatTotal,
      'taxAmtC': 0,
      'totTaxblAmt': summary.subtotalNet,
      'totTaxAmt': summary.outputVatTotal,
      'totAmt': summary.grandTotalWithVat,
      'prchrAcptcYn': 'N',
      'regrId': 'TownTreasureApp',
      'regrNm': 'Town Treasure',
      'modrId': 'TownTreasureApp',
      'modrNm': 'Town Treasure',
      'itemList': itemList,
    };
  }
}

/// Consolidated monthly eTIMS invoice / QR record for a hotel or corporate client
/// billed on a monthly statement rather than per-delivery daily eTIMS.
class MonthlyClientEtims {
  const MonthlyClientEtims({
    required this.id,
    required this.month,
    required this.restaurantId,
    required this.restaurantName,
    this.cuInvoiceNumber = '',
    this.rcptSign = '',
    this.qrCodeUrl = '',
    this.vatMode = 'inclusive',
    this.totalAmount = 0,
    this.exemptAmount = 0,
    this.taxableNetAmount = 0,
    this.outputVatAmount = 0,
    this.invoiceIds = const [],
    this.updatedAt,
  });

  final String id;
  final String month;
  final String restaurantId;
  final String restaurantName;
  final String cuInvoiceNumber;
  final String rcptSign;
  final String qrCodeUrl;
  final String vatMode;
  final double totalAmount;
  final double exemptAmount;
  final double taxableNetAmount;
  final double outputVatAmount;
  final List<String> invoiceIds;
  final String? updatedAt;

  bool get hasQr => qrCodeUrl.trim().isNotEmpty;

  static String buildId(String monthYm, Restaurant? restaurant, [String? fallbackName]) {
    final restKey = (restaurant != null && restaurant.id.trim().isNotEmpty)
        ? restaurant.id.trim()
        : (fallbackName ?? restaurant?.name ?? 'client')
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return '${monthYm.trim()}_$restKey';
  }

  factory MonthlyClientEtims.fromJson(Map<String, dynamic> json) {
    return MonthlyClientEtims(
      id: (json['id'] ?? '').toString(),
      month: (json['month'] ?? '').toString(),
      restaurantId: (json['restaurantId'] ?? '').toString(),
      restaurantName: (json['restaurantName'] ?? '').toString(),
      cuInvoiceNumber: (json['cuInvoiceNumber'] ?? '').toString(),
      rcptSign: (json['rcptSign'] ?? '').toString(),
      qrCodeUrl: (json['qrCodeUrl'] ?? '').toString(),
      vatMode: (json['vatMode'] ?? 'inclusive').toString(),
      totalAmount: (json['totalAmount'] as num?)?.toDouble() ?? 0,
      exemptAmount: (json['exemptAmount'] as num?)?.toDouble() ?? 0,
      taxableNetAmount: (json['taxableNetAmount'] as num?)?.toDouble() ?? 0,
      outputVatAmount: (json['outputVatAmount'] as num?)?.toDouble() ?? 0,
      invoiceIds: (json['invoiceIds'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [],
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'month': month,
      'restaurantId': restaurantId,
      'restaurantName': restaurantName,
      'cuInvoiceNumber': cuInvoiceNumber,
      'rcptSign': rcptSign,
      'qrCodeUrl': qrCodeUrl,
      'vatMode': vatMode,
      'totalAmount': totalAmount,
      'exemptAmount': exemptAmount,
      'taxableNetAmount': taxableNetAmount,
      'outputVatAmount': outputVatAmount,
      'invoiceIds': invoiceIds,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  MonthlyClientEtims copyWith({
    String? id,
    String? month,
    String? restaurantId,
    String? restaurantName,
    String? cuInvoiceNumber,
    String? rcptSign,
    String? qrCodeUrl,
    String? vatMode,
    double? totalAmount,
    double? exemptAmount,
    double? taxableNetAmount,
    double? outputVatAmount,
    List<String>? invoiceIds,
    String? updatedAt,
  }) {
    return MonthlyClientEtims(
      id: id ?? this.id,
      month: month ?? this.month,
      restaurantId: restaurantId ?? this.restaurantId,
      restaurantName: restaurantName ?? this.restaurantName,
      cuInvoiceNumber: cuInvoiceNumber ?? this.cuInvoiceNumber,
      rcptSign: rcptSign ?? this.rcptSign,
      qrCodeUrl: qrCodeUrl ?? this.qrCodeUrl,
      vatMode: vatMode ?? this.vatMode,
      totalAmount: totalAmount ?? this.totalAmount,
      exemptAmount: exemptAmount ?? this.exemptAmount,
      taxableNetAmount: taxableNetAmount ?? this.taxableNetAmount,
      outputVatAmount: outputVatAmount ?? this.outputVatAmount,
      invoiceIds: invoiceIds ?? this.invoiceIds,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
