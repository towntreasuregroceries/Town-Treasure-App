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

/// Broad KRA UNSPSC category mapping so daily fresh produce items never need manual
/// individual product registration while keeping KRA `saveTrnsSalesOsdc` valid.
class KraOscuCategory {
  const KraOscuCategory({
    required this.itemCd,
    required this.itemClsCd,
    required this.label,
  });

  final String itemCd;
  final String itemClsCd;
  final String label;
}

/// Pure Kenyan VAT3, smart produce-vs-VAT exception heuristics, and KRA OSCU helpers.
class KraTaxCalculator {
  KraTaxCalculator._();

  static const List<String> defaultTaxableGroceryKeywords = [
    'cooking oil',
    'vegetable oil',
    'sunflower oil',
    'olive oil',
    'corn oil',
    'margarine',
    'butter',
    'cheese',
    'yoghurt',
    'yogurt',
    'sugar',
    'sauce',
    'ketchup',
    'mayonnaise',
    'vinegar',
    'foil',
    'cling film',
    'packaging',
    'serviette',
    'napkin',
    'tissue',
    'detergent',
    'soap',
    'bleach',
    'soda',
    'juice',
    'bottled water',
    'charcoal',
    'salt',
    'pasta',
    'spaghetti',
    'noodles',
    'jam',
    'honey',
    'coffee',
    'tea leaves',
    'cream',
    'royco',
    'baking',
    'mustard',
  ];

  static const List<KraOscuCategory> coreOscuCategories = [
    KraOscuCategory(itemCd: 'TTG-VEG-01', itemClsCd: '5040150000', label: 'Fresh Vegetables'),
    KraOscuCategory(itemCd: 'TTG-FRT-01', itemClsCd: '5030150000', label: 'Fresh Fruits'),
    KraOscuCategory(itemCd: 'TTG-HRB-01', itemClsCd: '5040560000', label: 'Fresh Herbs & Spices'),
    KraOscuCategory(itemCd: 'TTG-ROT-01', itemClsCd: '5040570000', label: 'Roots & Tubers'),
    KraOscuCategory(itemCd: 'TTG-TAX-16', itemClsCd: '5015150000', label: 'Taxable Groceries & Oils'),
    KraOscuCategory(itemCd: 'TTG-FEE-01', itemClsCd: '7810220000', label: 'Delivery & Handling'),
  ];

  static double _round2(double value) => (value * 100).roundToDouble() / 100;

  /// Suggests a KRA VAT rate using self-learning exception keywords plus company defaults.
  /// Unprocessed agricultural produce stays `exempt` unless matched by 16% keywords.
  static KraTaxRate suggestTaxRate(
    String desc, {
    KraCompanyProfile profile = const KraCompanyProfile(),
    List<String> learnedKeywords = const [],
  }) {
    if (!profile.vatRegistered) return KraTaxRate.exempt;
    final norm = desc.trim().toLowerCase();
    if (norm.isNotEmpty) {
      for (final kw in learnedKeywords) {
        final k = kw.trim().toLowerCase();
        if (k.length >= 3 && norm.contains(k)) return KraTaxRate.standard16;
      }
      for (final kw in defaultTaxableGroceryKeywords) {
        if (norm.contains(kw)) return KraTaxRate.standard16;
      }
    }
    return profile.defaultTaxRate;
  }

  /// Normalizes a product name into a clean lowercase keyword for self-learning 16% VAT rules.
  static String normalizeTaxableKeyword(String rawDesc) {
    final cleaned = rawDesc
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'^st[mt\d-]*\s*·\s*'), '')
        .replaceAll(RegExp(r'^ttg-\d+\s*·\s*'), '')
        .replaceAll(RegExp(r'\b\d+(?:\.\d+)?\s*(?:kgs?|g|l|ltrs?|pcs?|crates?)\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  static KraOscuCategory mapProduceCategory(String desc, KraTaxRate rate) {
    final d = desc.toLowerCase();
    if (rate == KraTaxRate.standard16) {
      return coreOscuCategories[4]; // TTG-TAX-16
    }
    if (RegExp(r'\b(potato|potatoes|waru|sweet potato|cassava|arrow|yam|carrot|beet|ginger|garlic|onion|shallot)\b')
        .hasMatch(d)) {
      return coreOscuCategories[3]; // TTG-ROT-01
    }
    if (RegExp(r'\b(apple|mango|orange|banana|pineapple|melon|watermelon|pawpaw|papaya|passion|lemon|lime|avocado|strawberry|grape|pear|plum|peach|kiwi|berry)\b')
        .hasMatch(d)) {
      return coreOscuCategories[1]; // TTG-FRT-01
    }
    if (RegExp(r'\b(dhania|coriander|parsley|rosemary|mint|basil|thyme|sage|chives|dill|oregano)\b')
        .hasMatch(d)) {
      return coreOscuCategories[2]; // TTG-HRB-01
    }
    return coreOscuCategories[0]; // TTG-VEG-01
  }

  static String mapUnitCode(String unit) {
    final u = unit.trim().toLowerCase();
    if (u.startsWith('l') || u.contains('ltr') || u.contains('litre')) return 'LTR';
    if (u.startsWith('crate') || u.startsWith('box') || u.startsWith('carton')) return 'CT';
    if (u.startsWith('bag') || u.startsWith('sack')) return 'BG';
    if (u.startsWith('pc') || u == 'each' || u.startsWith('bunch') || u.startsWith('tray')) {
      return 'U';
    }
    return 'KGM';
  }

  static KraLineTaxBreakdown computeLineBreakdown(
    InvoiceLineItem item, {
    required KraVatMode vatMode,
    KraTaxRate defaultRate = KraTaxRate.exempt,
  }) {
    final rate = KraTaxRate.fromCode(item.taxRate, fallback: defaultRate);
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
  /// Delivery/other charges are treated as VAT-exempt ancillary fees.
  static KraInvoiceTaxSummary computeInvoiceTaxSummary(
    Invoice invoice, {
    KraCompanyProfile profile = const KraCompanyProfile(),
  }) {
    final vatMode = KraVatMode.fromCode(
      invoice.vatMode ?? profile.defaultVatMode.code,
    );
    final fallbackRate =
        profile.vatRegistered ? profile.defaultTaxRate : KraTaxRate.exempt;

    var exempt = 0.0;
    var zeroRated = 0.0;
    var taxableNet = 0.0;
    var outputVat = 0.0;
    var hasTaxable = false;

    for (final item in invoice.items) {
      final line = computeLineBreakdown(
        item,
        vatMode: vatMode,
        defaultRate: fallbackRate,
      );
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

  /// Aggregates monthly Output VAT, Exempt Produce Sales, Input VAT, and unique hotels missing KRA PINs.
  /// Incorporates saved [monthlyEtimsRecords] without double counting underlying invoices.
  static KraMonthlyVat3Summary computeMonthlySummary({
    required String monthYm,
    required List<Invoice> invoices,
    required List<Expense> expenses,
    required List<Restaurant> restaurants,
    KraCompanyProfile profile = const KraCompanyProfile(),
    List<MonthlyClientEtims> monthlyEtimsRecords = const [],
  }) {
    final monthInvoices = invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(monthYm))
        .toList();

    final monthlyByInvoiceId = <String, MonthlyClientEtims>{};
    for (final rec in monthlyEtimsRecords) {
      if (rec.month == monthYm && (rec.hasQr || rec.cuInvoiceNumber.isNotEmpty)) {
        for (final id in rec.invoiceIds) {
          monthlyByInvoiceId[id] = rec;
        }
      }
    }

    var exempt = 0.0;
    var zeroRated = 0.0;
    var taxableNet = 0.0;
    var outputVat = 0.0;
    var vatInvCount = 0;
    final missingPins = <Invoice>[];
    final seenMissingClientKeys = <String>{};
    final appliedMonthlyIds = <String>{};

    for (final inv in monthInvoices) {
      final rest = Restaurant.resolveInvoiceRestaurant(inv, restaurants).restaurant;
      final pin = Restaurant.normalizeKraPin(rest?.kraPin);
      if (pin.isEmpty || !Restaurant.isValidKraPin(pin)) {
        final clientKey = (rest != null && rest.id.isNotEmpty)
            ? rest.id
            : Restaurant.normalizeRestaurantName(inv.restaurantName);
        if (seenMissingClientKeys.add(clientKey)) {
          missingPins.add(inv);
        }
      }

      final hasDailyExplicitTax = inv.isFiscalized ||
          inv.items.any((it) => KraTaxRate.fromCode(it.taxRate) == KraTaxRate.standard16);
      final monthlyRec = monthlyByInvoiceId[inv.id];

      // If this hotel is covered by a consolidated monthly eTIMS record and the invoice itself
      // wasn't individually fiscalized as daily eTIMS, aggregate the monthly record once instead.
      if (!hasDailyExplicitTax && monthlyRec != null) {
        if (appliedMonthlyIds.add(monthlyRec.id)) {
          exempt += monthlyRec.exemptAmount;
          taxableNet += monthlyRec.taxableNetAmount;
          outputVat += monthlyRec.outputVatAmount;
          if (monthlyRec.outputVatAmount > 0) {
            vatInvCount++;
          }
        }
        continue;
      }

      final summary = computeInvoiceTaxSummary(inv, profile: profile);
      exempt += summary.exemptTotal;
      zeroRated += summary.zeroRatedTotal;
      taxableNet += summary.taxableNetTotal;
      outputVat += summary.outputVatTotal;
      if (summary.hasTaxableVatLines) {
        vatInvCount++;
      }
    }

    var inputVat = 0.0;
    for (final exp in expenses) {
      if (!exp.isCapital && !exp.isLoanPrincipal && exp.date.startsWith(monthYm)) {
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

  /// Builds an official KRA eTIMS OSCU `/saveTrnsSalesOsdc` JSON payload for an invoice or Credit Note.
  static Map<String, dynamic> buildOscuSalesPayload({
    required Invoice invoice,
    required KraCompanyProfile profile,
    Restaurant? buyer,
    DateTime? timestamp,
    int sequentialInvcNo = 0,
    bool isCreditNote = false,
    int originalInvcNo = 0,
  }) {
    final eatNow = (timestamp ?? DateTime.now()).toUtc().add(const Duration(hours: 3));
    String fmtDate(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    String fmtDateTime(DateTime d) =>
        '${fmtDate(d)}${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}${d.second.toString().padLeft(2, '0')}';

    final vatMode = KraVatMode.fromCode(
      invoice.vatMode ?? profile.defaultVatMode.code,
    );
    final fallbackRate =
        profile.vatRegistered ? profile.defaultTaxRate : KraTaxRate.exempt;
    final summary = computeInvoiceTaxSummary(invoice, profile: profile);
    final cleanDate = invoice.date.replaceAll('-', '');
    final salesDt = cleanDate.length == 8 ? cleanDate : fmtDate(eatNow);
    final buyerPin = Restaurant.normalizeKraPin(buyer?.kraPin);

    final itemList = <Map<String, dynamic>>[];
    for (var i = 0; i < invoice.items.length; i++) {
      final item = invoice.items[i];
      final lineTax = computeLineBreakdown(
        item,
        vatMode: vatMode,
        defaultRate: fallbackRate,
      );
      final code = oscuTaxCode(lineTax.rate);
      final cat = mapProduceCategory(item.desc, lineTax.rate);
      final unitCode = mapUnitCode(item.unit);
      final safeQty = item.qty > 0 ? item.qty : 1.0;
      itemList.add({
        'itemSeq': itemList.length + 1,
        'itemCd': cat.itemCd,
        'itemClsCd': cat.itemClsCd,
        'itemNm': item.desc,
        'bcd': null,
        'pkgUnitCd': 'NT',
        'pkg': safeQty,
        'qtyUnitCd': unitCode,
        'qty': safeQty,
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

    void addFeeLine(String label, double feeAmount) {
      if (feeAmount <= 0) return;
      final cleanFee = _round2(feeAmount);
      final feeCat = coreOscuCategories[5]; // TTG-FEE-01
      itemList.add({
        'itemSeq': itemList.length + 1,
        'itemCd': feeCat.itemCd,
        'itemClsCd': feeCat.itemClsCd,
        'itemNm': label,
        'bcd': null,
        'pkgUnitCd': 'NT',
        'pkg': 1,
        'qtyUnitCd': 'U',
        'qty': 1,
        'prc': cleanFee,
        'splyAmt': cleanFee,
        'dcRt': 0,
        'dcAmt': 0,
        'taxTyCd': 'A',
        'taxblAmt': cleanFee,
        'taxAmt': 0,
        'totAmt': cleanFee,
      });
    }

    addFeeLine('Delivery Charge', invoice.deliveryCost);
    addFeeLine('Other Charge', invoice.otherCost);

    return {
      'tin': profile.normalizedSellerPin,
      'bhfId': profile.etimsBranchId.trim().isEmpty
          ? '00'
          : profile.etimsBranchId.trim(),
      'invcNo': sequentialInvcNo,
      'orgInvcNo': isCreditNote ? originalInvcNo : 0,
      'trdInvcNo': invoice.number,
      if (buyerPin.isNotEmpty) 'custTin': buyerPin,
      'custNm': buyer?.name ?? invoice.restaurantName,
      'salesTyCd': 'N',
      'rcptTyCd': isCreditNote ? 'R' : 'S',
      'pmtTyCd': invoice.isPaid ? '01' : '02',
      'salesSttsCd': isCreditNote ? '05' : '02',
      'cfmDt': fmtDateTime(eatNow),
      'salesDt': salesDt,
      'totItemCnt': itemList.length,
      'taxblAmtA': summary.exemptTotal,
      'taxblAmtB': summary.taxableNetTotal,
      'taxblAmtC': summary.zeroRatedTotal,
      'taxblAmtD': 0,
      'taxblAmtE': 0,
      'taxRtA': 0,
      'taxRtB': 16,
      'taxRtC': 0,
      'taxRtD': 0,
      'taxRtE': 8,
      'taxAmtA': 0,
      'taxAmtB': summary.outputVatTotal,
      'taxAmtC': 0,
      'taxAmtD': 0,
      'taxAmtE': 0,
      'totDcAmt': 0,
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
    this.invcNo,
    this.sdcDateTime = '',
    this.intrData = '',
    this.lineTaxRates = const {},
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
  final int? invcNo;
  final String sdcDateTime;
  final String intrData;
  final Map<String, String> lineTaxRates;
  final String? updatedAt;

  bool get hasQr => qrCodeUrl.trim().isNotEmpty;
  bool get isFiscalized =>
      qrCodeUrl.trim().isNotEmpty || cuInvoiceNumber.trim().isNotEmpty;

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
    final rawRates = json['lineTaxRates'];
    final parsedRates = <String, String>{};
    if (rawRates is Map) {
      rawRates.forEach((k, v) {
        if (k != null && v != null) {
          parsedRates[k.toString()] = v.toString();
        }
      });
    }
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
      invcNo: (json['invcNo'] as num?)?.toInt(),
      sdcDateTime: (json['sdcDateTime'] ?? '').toString(),
      intrData: (json['intrData'] ?? '').toString(),
      lineTaxRates: parsedRates,
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
      if (invcNo != null) 'invcNo': invcNo,
      if (sdcDateTime.isNotEmpty) 'sdcDateTime': sdcDateTime,
      if (intrData.isNotEmpty) 'intrData': intrData,
      if (lineTaxRates.isNotEmpty) 'lineTaxRates': lineTaxRates,
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
    int? invcNo,
    String? sdcDateTime,
    String? intrData,
    Map<String, String>? lineTaxRates,
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
      invcNo: invcNo ?? this.invcNo,
      sdcDateTime: sdcDateTime ?? this.sdcDateTime,
      intrData: intrData ?? this.intrData,
      lineTaxRates: lineTaxRates ?? this.lineTaxRates,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
