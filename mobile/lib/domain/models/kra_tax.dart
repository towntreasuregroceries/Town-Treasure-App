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

/// Company KRA tax configuration stored inside `VaultSettings` (`kraProfile`).
class KraCompanyProfile {
  const KraCompanyProfile({
    this.sellerKraPin = '',
    this.vatNumber = '',
    this.vatRegistered = true,
    this.defaultTaxRate = KraTaxRate.exempt,
    this.defaultVatMode = KraVatMode.inclusive,
    this.cuSerialNumber = '',
    this.etimsBranchId = '00',
    this.updatedAt,
  });

  final String sellerKraPin;
  final String vatNumber;
  final bool vatRegistered;
  final KraTaxRate defaultTaxRate;
  final KraVatMode defaultVatMode;
  final String cuSerialNumber;
  final String etimsBranchId;
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
      defaultVatMode: KraVatMode.fromCode(json['defaultVatMode']?.toString()),
      cuSerialNumber: (json['cuSerialNumber'] ?? '').toString(),
      etimsBranchId: (json['etimsBranchId'] ?? '00').toString(),
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
}
