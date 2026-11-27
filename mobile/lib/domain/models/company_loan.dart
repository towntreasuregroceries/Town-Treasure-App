import 'dart:math' as math;

import 'app_helpers.dart';

/// Interest calculation method for a company credit facility / bank loan.
enum CompanyLoanMode {
  reducingBalance('reducing', 'Reducing Balance (% p.a.)'),
  flatRate('flat', 'Flat Interest Rate (% p.a.)'),
  fixedInstallment('fixed_installment', 'Known Monthly Installment');

  const CompanyLoanMode(this.code, this.label);
  final String code;
  final String label;

  static CompanyLoanMode fromCode(String? raw) {
    final clean = (raw ?? '').trim().toLowerCase();
    for (final mode in CompanyLoanMode.values) {
      if (mode.code == clean) return mode;
    }
    return CompanyLoanMode.reducingBalance;
  }
}

/// Single recorded monthly or lump-sum repayment against a [CompanyLoan],
/// bifurcated into balance-sheet Principal reduction and P&L Interest expense.
class CompanyLoanPayment {
  const CompanyLoanPayment({
    required this.id,
    required this.date,
    required this.totalAmount,
    required this.principalComponent,
    required this.interestComponent,
    this.notes = '',
    this.createdAt,
  });

  final String id;
  final String date;
  final double totalAmount;
  final double principalComponent;
  final double interestComponent;
  final String notes;
  final String? createdAt;

  factory CompanyLoanPayment.fromJson(Map<String, dynamic> json) {
    final total = AppHelpers.parseDouble(json['totalAmount']);
    final principal = AppHelpers.parseDouble(json['principalComponent']);
    final interest = AppHelpers.parseDouble(json['interestComponent']);
    return CompanyLoanPayment(
      id: (json['id'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      totalAmount: total > 0 ? total : (principal + interest),
      principalComponent: principal,
      interestComponent: interest,
      notes: (json['notes'] ?? '').toString(),
      createdAt: json['createdAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'totalAmount': totalAmount,
        'principalComponent': principalComponent,
        'interestComponent': interestComponent,
        if (notes.isNotEmpty) 'notes': notes,
        if (createdAt != null) 'createdAt': createdAt,
      };
}

/// Projected amortization row for month [periodIndex] (1..tenureMonths).
class AmortizationScheduleRow {
  const AmortizationScheduleRow({
    required this.periodIndex,
    required this.dueDateIso,
    required this.openingBalance,
    required this.installment,
    required this.principal,
    required this.interest,
    required this.closingBalance,
  });

  final int periodIndex;
  final String dueDateIso;
  final double openingBalance;
  final double installment;
  final double principal;
  final double interest;
  final double closingBalance;
}

/// Debt-financed Capital Injection facility (e.g., Equity SME Working Capital Loan)
/// with PMT / Flat / Newton-Raphson EIR math and Principal-vs-Interest bifurcation.
class CompanyLoan {
  const CompanyLoan({
    required this.id,
    required this.lenderName,
    this.facilityName = 'Working Capital Facility',
    required this.disbursementDate,
    required this.principal,
    this.upfrontFees = 0,
    this.mode = CompanyLoanMode.reducingBalance,
    this.annualRatePct = 0,
    required this.tenureMonths,
    required this.monthlyInstallment,
    this.debitDayOfMonth = 5,
    this.accountLabel = 'Company Bank Account',
    this.capitalExpenseId,
    this.upfrontFeeExpenseId,
    this.payments = const [],
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String lenderName;
  final String facilityName;
  final String disbursementDate;
  final double principal;
  final double upfrontFees;
  final CompanyLoanMode mode;
  final double annualRatePct;
  final int tenureMonths;
  final double monthlyInstallment;
  final int debitDayOfMonth;
  final String accountLabel;
  final String? capitalExpenseId;
  final String? upfrontFeeExpenseId;
  final List<CompanyLoanPayment> payments;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;

  bool get isDeleted => deletedAt != null && deletedAt!.trim().isNotEmpty;

  double get totalPrincipalPaid =>
      payments.fold<double>(0, (s, p) => s + p.principalComponent);

  double get totalInterestPaid =>
      payments.fold<double>(0, (s, p) => s + p.interestComponent);

  double get totalCashRepaid =>
      payments.fold<double>(0, (s, p) => s + p.totalAmount);

  double get remainingPrincipal =>
      math.max(0.0, principal - totalPrincipalPaid);

  bool get isFullySettled => remainingPrincipal <= 0.01;

  double get payoffProgress =>
      principal > 0 ? (totalPrincipalPaid / principal).clamp(0.0, 1.0) : 1.0;

  /// Computes standard monthly installment for [principal], [annualRatePct],
  /// [tenureMonths], and [mode].
  static double computeMonthlyInstallment({
    required double principal,
    required double annualRatePct,
    required int tenureMonths,
    required CompanyLoanMode mode,
  }) {
    if (principal <= 0 || tenureMonths <= 0) return 0;
    if (annualRatePct <= 0) return principal / tenureMonths;

    final monthlyRate = (annualRatePct / 100.0) / 12.0;
    if (mode == CompanyLoanMode.flatRate) {
      return (principal / tenureMonths) + (principal * monthlyRate);
    }
    // Standard PMT formula on reducing balance
    final factor = math.pow(1.0 + monthlyRate, tenureMonths).toDouble();
    if ((factor - 1.0).abs() < 1e-12) return principal / tenureMonths;
    return principal * (monthlyRate * factor) / (factor - 1.0);
  }

  /// Solves for the true monthly internal rate of return $i$ satisfying:
  /// $\sum_{t=1}^{n} M (1 + i)^{-t} = \max(1, P_0 - F_0)$
  /// using safeguarded Newton-Raphson iteration, returning nominal annual % (`12 * i * 100`).
  static double solveEffectiveAnnualRatePct({
    required double principal,
    required double monthlyInstallment,
    required int tenureMonths,
    double upfrontFees = 0,
  }) {
    final netProceeds = principal - math.max(0.0, upfrontFees);
    if (netProceeds <= 0 || tenureMonths <= 0 || monthlyInstallment <= 0) {
      return 0;
    }
    final totalOutflow = monthlyInstallment * tenureMonths;
    if (totalOutflow <= netProceeds + 1e-6) {
      return 0;
    }

    double npvAt(double r) {
      if (r.abs() < 1e-10) {
        return monthlyInstallment * tenureMonths - netProceeds;
      }
      final discount = 1.0 - math.pow(1.0 + r, -tenureMonths).toDouble();
      return monthlyInstallment * (discount / r) - netProceeds;
    }

    double derivAt(double r) {
      var sum = 0.0;
      for (var t = 1; t <= tenureMonths; t++) {
        sum -= t * monthlyInstallment * math.pow(1.0 + r, -(t + 1)).toDouble();
      }
      return sum;
    }

    var low = 0.0;
    var high = 5.0; // up to 6000% p.a. upper bracket
    var guess = ((totalOutflow / netProceeds) - 1.0) / tenureMonths;
    guess = guess.clamp(1e-5, 1.0);

    for (var iter = 0; iter < 40; iter++) {
      final f = npvAt(guess);
      if (f.abs() < 1e-8) break;
      if (f > 0) {
        low = guess;
      } else {
        high = guess;
      }
      final df = derivAt(guess);
      double next;
      if (df.abs() > 1e-12) {
        next = guess - (f / df);
        if (next <= low || next >= high || !next.isFinite) {
          next = 0.5 * (low + high);
        }
      } else {
        next = 0.5 * (low + high);
      }
      if ((next - guess).abs() < 1e-10) {
        guess = next;
        break;
      }
      guess = next;
    }
    return guess * 12.0 * 100.0;
  }

  /// True Effective Annual Interest Rate (EIR / APR %) including upfront bank fees.
  double get effectiveAnnualRatePct => solveEffectiveAnnualRatePct(
        principal: principal,
        monthlyInstallment: monthlyInstallment,
        tenureMonths: tenureMonths,
        upfrontFees: upfrontFees,
      );

  /// Implied periodic monthly interest rate used to split each installment into
  /// balance-sheet Principal vs. P&L Finance Expense.
  double get periodicMonthlyRate {
    if (mode == CompanyLoanMode.reducingBalance && annualRatePct > 0) {
      return (annualRatePct / 100.0) / 12.0;
    }
    if (mode == CompanyLoanMode.fixedInstallment) {
      // Exclude upfrontFees when splitting principal vs interest of principal=P0
      final nominal = solveEffectiveAnnualRatePct(
        principal: principal,
        monthlyInstallment: monthlyInstallment,
        tenureMonths: tenureMonths,
        upfrontFees: 0,
      );
      return (nominal / 100.0) / 12.0;
    }
    return (annualRatePct / 100.0) / 12.0;
  }

  /// Splits any payment [amount] against the current [remainingPrincipal] into
  /// `(principalComponent, interestComponent)`.
  ({double principal, double interest}) splitPaymentAmount(double amount) {
    if (amount <= 0) return (principal: 0.0, interest: 0.0);
    final rem = remainingPrincipal;
    if (rem <= 0) {
      return (principal: 0.0, interest: amount);
    }

    double rawInterest;
    if (mode == CompanyLoanMode.flatRate) {
      rawInterest = principal * ((annualRatePct / 100.0) / 12.0);
    } else {
      rawInterest = rem * periodicMonthlyRate;
    }
    rawInterest = rawInterest.isFinite ? math.max(0.0, rawInterest) : 0.0;
    final interestSlice = math.min(amount, rawInterest);
    final remainingCash = amount - interestSlice;
    final principalSlice = math.min(rem, remainingCash);
    final excessInterest = math.max(0.0, remainingCash - principalSlice);

    return (
      principal: double.parse(principalSlice.toStringAsFixed(2)),
      interest: double.parse((interestSlice + excessInterest).toStringAsFixed(2)),
    );
  }

  /// Generates the original full contractual amortization schedule (`1..tenureMonths`).
  List<AmortizationScheduleRow> buildSchedule() {
    if (principal <= 0 || tenureMonths <= 0) return const [];
    final rows = <AmortizationScheduleRow>[];
    final start = AppHelpers.parseAppDate(disbursementDate) ?? DateTime.now();
    final safeDay = debitDayOfMonth.clamp(1, 28);
    var balance = principal;
    final mRate = periodicMonthlyRate;

    for (var k = 1; k <= tenureMonths; k++) {
      final dueDate = DateTime(start.year, start.month + k, safeDay);
      final dueIso = AppHelpers.normalizeAppDate(dueDate);
      final opening = balance;

      double interest;
      if (mode == CompanyLoanMode.flatRate) {
        interest = principal * ((annualRatePct / 100.0) / 12.0);
      } else {
        interest = opening * mRate;
      }

      double principalPart;
      double inst;
      if (k == tenureMonths) {
        principalPart = opening;
        inst = principalPart + interest;
      } else {
        inst = monthlyInstallment > 0
            ? monthlyInstallment
            : computeMonthlyInstallment(
                principal: principal,
                annualRatePct: annualRatePct,
                tenureMonths: tenureMonths,
                mode: mode,
              );
        principalPart = math.max(0.0, math.min(opening, inst - interest));
      }
      balance = math.max(0.0, opening - principalPart);
      rows.add(
        AmortizationScheduleRow(
          periodIndex: k,
          dueDateIso: dueIso,
          openingBalance: opening,
          installment: inst,
          principal: principalPart,
          interest: interest,
          closingBalance: balance,
        ),
      );
    }
    return rows;
  }

  /// Estimates total remaining interest if paid on schedule from current [remainingPrincipal],
  /// vs contractual total interest — revealing exact KES saved by early principal top-ups.
  double get estimatedInterestSavedByPrepayment {
    if (mode == CompanyLoanMode.flatRate || principal <= 0) return 0.0;
    final originalTotalInterest =
        buildSchedule().fold<double>(0, (s, r) => s + r.interest);

    var simBal = remainingPrincipal;
    var futureInterest = 0.0;
    final mRate = periodicMonthlyRate;
    final inst = monthlyInstallment;
    if (inst <= 0 || mRate <= 0) return 0.0;

    var guard = 0;
    while (simBal > 0.01 && guard < tenureMonths * 2 + 12) {
      final intr = simBal * mRate;
      if (inst <= intr) return 0.0;
      futureInterest += intr;
      simBal = math.max(0.0, simBal - (inst - intr));
      guard++;
    }
    final projectedTotalInterest = totalInterestPaid + futureInterest;
    return math.max(0.0, originalTotalInterest - projectedTotalInterest);
  }

  /// Checks whether an installment has already been recorded in `yyyy-MM` [monthYm].
  bool isPaidForMonth(String monthYm) {
    return payments.any((p) => p.date.startsWith(monthYm));
  }

  /// Next upcoming due date for an active (unsettled) loan relative to [now].
  DateTime? nextDueDate(DateTime now) {
    if (isFullySettled) return null;
    final ym = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
    final safeDay = debitDayOfMonth.clamp(1, 28);
    if (!isPaidForMonth(ym)) {
      return DateTime(now.year, now.month, safeDay);
    }
    return DateTime(now.year, now.month + 1, safeDay);
  }

  factory CompanyLoan.fromJson(Map<String, dynamic> json) {
    final rawPayments = json['payments'];
    final payments = rawPayments is List
        ? rawPayments
            .whereType<Map>()
            .map((e) => CompanyLoanPayment.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <CompanyLoanPayment>[];

    final principal = AppHelpers.parseDouble(json['principal']);
    final tenure = math.max(1, AppHelpers.parseInt(json['tenureMonths'], 12));
    final mode = CompanyLoanMode.fromCode(json['mode']?.toString());
    final rate = AppHelpers.parseDouble(json['annualRatePct']);
    final savedInst = AppHelpers.parseDouble(json['monthlyInstallment']);

    return CompanyLoan(
      id: (json['id'] ?? '').toString(),
      lenderName: (json['lenderName'] ?? 'Bank').toString(),
      facilityName: (json['facilityName'] ?? 'Working Capital Facility').toString(),
      disbursementDate: (json['disbursementDate'] ?? '').toString(),
      principal: principal,
      upfrontFees: AppHelpers.parseDouble(json['upfrontFees']),
      mode: mode,
      annualRatePct: rate,
      tenureMonths: tenure,
      monthlyInstallment: savedInst > 0
          ? savedInst
          : computeMonthlyInstallment(
              principal: principal,
              annualRatePct: rate,
              tenureMonths: tenure,
              mode: mode,
            ),
      debitDayOfMonth: AppHelpers.parseInt(json['debitDayOfMonth'], 5).clamp(1, 28),
      accountLabel: (json['accountLabel'] ?? 'Company Bank Account').toString(),
      capitalExpenseId: json['capitalExpenseId']?.toString(),
      upfrontFeeExpenseId: json['upfrontFeeExpenseId']?.toString(),
      payments: payments,
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
      deletedAt: json['deletedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lenderName': lenderName,
        'facilityName': facilityName,
        'disbursementDate': disbursementDate,
        'principal': principal,
        if (upfrontFees > 0) 'upfrontFees': upfrontFees,
        'mode': mode.code,
        'annualRatePct': annualRatePct,
        'tenureMonths': tenureMonths,
        'monthlyInstallment': monthlyInstallment,
        'debitDayOfMonth': debitDayOfMonth,
        'accountLabel': accountLabel,
        if (capitalExpenseId != null) 'capitalExpenseId': capitalExpenseId,
        if (upfrontFeeExpenseId != null) 'upfrontFeeExpenseId': upfrontFeeExpenseId,
        'payments': payments.map((p) => p.toJson()).toList(),
        if (createdAt != null) 'createdAt': createdAt,
        if (updatedAt != null) 'updatedAt': updatedAt,
        if (deletedAt != null) 'deletedAt': deletedAt,
      };

  CompanyLoan copyWith({
    String? id,
    String? lenderName,
    String? facilityName,
    String? disbursementDate,
    double? principal,
    double? upfrontFees,
    CompanyLoanMode? mode,
    double? annualRatePct,
    int? tenureMonths,
    double? monthlyInstallment,
    int? debitDayOfMonth,
    String? accountLabel,
    String? capitalExpenseId,
    String? upfrontFeeExpenseId,
    List<CompanyLoanPayment>? payments,
    String? createdAt,
    String? updatedAt,
    String? deletedAt,
  }) {
    return CompanyLoan(
      id: id ?? this.id,
      lenderName: lenderName ?? this.lenderName,
      facilityName: facilityName ?? this.facilityName,
      disbursementDate: disbursementDate ?? this.disbursementDate,
      principal: principal ?? this.principal,
      upfrontFees: upfrontFees ?? this.upfrontFees,
      mode: mode ?? this.mode,
      annualRatePct: annualRatePct ?? this.annualRatePct,
      tenureMonths: tenureMonths ?? this.tenureMonths,
      monthlyInstallment: monthlyInstallment ?? this.monthlyInstallment,
      debitDayOfMonth: debitDayOfMonth ?? this.debitDayOfMonth,
      accountLabel: accountLabel ?? this.accountLabel,
      capitalExpenseId: capitalExpenseId ?? this.capitalExpenseId,
      upfrontFeeExpenseId: upfrontFeeExpenseId ?? this.upfrontFeeExpenseId,
      payments: payments ?? this.payments,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }
}
