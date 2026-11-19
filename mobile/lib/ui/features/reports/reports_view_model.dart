import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';

/// Smart business insights grouped by urgency matching `insights.js`.
class SmartInsightsResult {
  const SmartInsightsResult({
    this.urgent = const [],
    this.attention = const [],
    this.good = const [],
  });

  final List<String> urgent;
  final List<String> attention;
  final List<String> good;

  bool get isEmpty => urgent.isEmpty && attention.isEmpty && good.isEmpty;
}

/// Dynamic Monthly Profit & Loss breakdown matching `renderMonthlyPnL()` in `insights.js`.
class MonthlyPnLData {
  const MonthlyPnLData({
    required this.month,
    required this.monthName,
    required this.revenue,
    required this.prevRevenue,
    required this.revenueChangePct,
    required this.cogs,
    required this.grossProfit,
    required this.grossMarginPct,
    required this.expensesByCategory,
    required this.salaryTotal,
    required this.totalExpenses,
    required this.netProfit,
    required this.netMarginPct,
    required this.capitalAdded,
  });

  final String month;
  final String monthName;
  final double revenue;
  final double prevRevenue;
  final double? revenueChangePct;
  final double cogs;
  final double grossProfit;
  final double? grossMarginPct;
  final List<MapEntry<String, double>> expensesByCategory;
  final double salaryTotal;
  final double totalExpenses;
  final double netProfit;
  final double? netMarginPct;
  final double capitalAdded;
}

/// Monthly chart point for interactive `fl_chart` visualization.
class MonthlyTrendPoint {
  const MonthlyTrendPoint({
    required this.month,
    required this.label,
    required this.revenue,
    required this.cost,
    required this.profit,
    required this.expenses,
  });

  final String month;
  final String label;
  final double revenue;
  final double cost;
  final double profit;
  final double expenses;
}

/// Expense slice for category chart.
class ExpenseCategorySlice {
  const ExpenseCategorySlice({
    required this.category,
    required this.label,
    required this.amount,
  });

  final String category;
  final String label;
  final double amount;
}

/// Product catalog option for "By Product" report selector.
class ProductCatalogOption {
  const ProductCatalogOption({
    required this.key,
    required this.name,
    required this.qty,
    required this.unit,
    required this.count,
  });

  final String key;
  final String name;
  final double qty;
  final String unit;
  final int count;
}

/// Aggregated restaurant performance row.
class ReportRestaurantBreakdown {
  const ReportRestaurantBreakdown({
    required this.name,
    required this.count,
    required this.qty,
    required this.sell,
    required this.buy,
    required this.profit,
  });

  final String name;
  final int count;
  final double qty;
  final double sell;
  final double buy;
  final double profit;

  double get marginPct => sell > 0 ? (profit / sell) * 100 : 0;
}

/// Aggregated expense category row for reports.
class ReportExpenseCategoryRow {
  const ReportExpenseCategoryRow({
    required this.category,
    required this.count,
    required this.total,
  });

  final String category;
  final int count;
  final double total;
}

/// Single product transaction match for "By Product" report.
class ProductReportTransaction {
  const ProductReportTransaction({
    required this.invoiceNumber,
    required this.restaurantName,
    required this.date,
    required this.qty,
    required this.unit,
    required this.sellPrice,
    required this.buyPrice,
    required this.total,
    required this.cost,
    required this.profit,
  });

  final String invoiceNumber;
  final String restaurantName;
  final String date;
  final double qty;
  final String unit;
  final double sellPrice;
  final double buyPrice;
  final double total;
  final double cost;
  final double profit;
}

/// Generated report payload covering `general`, `restaurant`, and `product` modes.
class GeneratedReportData {
  const GeneratedReportData({
    required this.type,
    required this.dateRangeLabel,
    required this.fromDate,
    required this.toDate,
    required this.targetLabel,
    this.totalSell = 0,
    this.totalBuy = 0,
    this.totalProfit = 0,
    this.paidTotal = 0,
    this.pendingTotal = 0,
    this.totalExpenses = 0,
    this.totalCapital = 0,
    this.netPosition = 0,
    this.invoices = const [],
    this.expenseItems = const [],
    this.capitalItems = const [],
    this.byRestaurant = const [],
    this.expensesByCategory = const [],
    this.unitSummary = '',
    this.productTransactions = const [],
  });

  final String type;
  final String dateRangeLabel;
  final String fromDate;
  final String toDate;
  final String targetLabel;
  final double totalSell;
  final double totalBuy;
  final double totalProfit;
  final double paidTotal;
  final double pendingTotal;
  final double totalExpenses;
  final double totalCapital;
  final double netPosition;
  final List<Invoice> invoices;
  final List<Expense> expenseItems;
  final List<Expense> capitalItems;
  final List<ReportRestaurantBreakdown> byRestaurant;
  final List<ReportExpenseCategoryRow> expensesByCategory;
  final String unitSummary;
  final List<ProductReportTransaction> productTransactions;

  bool get isGeneral => type == 'general';
  bool get isProduct => type == 'product';
}

/// Ledger line item inside a monthly restaurant statement.
class StatementTransaction {
  const StatementTransaction({
    required this.date,
    required this.desc,
    required this.itemsLabel,
    required this.debit,
    required this.credit,
    required this.balance,
    required this.type,
  });

  final String date;
  final String desc;
  final String itemsLabel;
  final double debit;
  final double credit;
  final double balance;
  final String type;
}

/// Debt age buckets matching `statements.js`.
class DebtAgeAnalysis {
  const DebtAgeAnalysis({
    required this.current,
    required this.days30,
    required this.days60,
    required this.days90,
  });

  final double current;
  final double days30;
  final double days60;
  final double days90;
}

/// Complete monthly client statement model matching `buildStatementHTML` in `statements.js`.
class ClientStatementData {
  const ClientStatementData({
    required this.restaurant,
    required this.month,
    required this.monthName,
    required this.openingBalance,
    required this.monthInvoicedTotal,
    required this.monthPaidTotal,
    required this.closingBalance,
    required this.transactions,
    required this.ageAnalysis,
  });

  final Restaurant restaurant;
  final String month;
  final String monthName;
  final double openingBalance;
  final double monthInvoicedTotal;
  final double monthPaidTotal;
  final double closingBalance;
  final List<StatementTransaction> transactions;
  final DebtAgeAnalysis ageAnalysis;
}

/// MVVM ViewModel for Reports, Smart Insights, Monthly P&L, Exports, and Client Statements.
class ReportsViewModel extends ChangeNotifier {
  ReportsViewModel({required this._vault}) {
    _vault.addListener(_onVaultChanged);
  }

  final VaultRepository _vault;

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  void _onVaultChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _vault.removeListener(_onVaultChanged);
    super.dispose();
  }

  List<Restaurant> get restaurants => _vault.restaurants;
  List<Invoice> get invoices => _vault.invoices;
  List<Expense> get expenses => _vault.expenses;
  List<Staff> get staff => _vault.staff;
  VaultSettings get settings => _vault.settings;

  static String formatMoney(double amount) => _moneyFormat.format(amount);

  static String formatDate(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    final parsed = AppHelpers.parseAppDate(value);
    if (parsed == null) return value;
    return DateFormat('dd/MM/yyyy').format(parsed);
  }

  static String getExpenseCategoryLabel(String cat) {
    const labels = {
      'transport': 'Transport',
      'rent': 'Rent',
      'utilities': 'Utilities',
      'supplies': 'Supplies',
      'salaries': 'Salaries',
      'wages': 'Wages',
      'inventory': 'Inventory',
      'capital': 'Capital',
      'other': 'Other',
      'personal': 'Personal',
      'airtime': 'Airtime',
      'food_personal': 'Food & Meals',
      'medical': 'Medical',
      'family': 'Family',
      'clothing': 'Clothing',
      'entertainment': 'Entertainment',
      'savings': 'Savings',
      'personal_transport': 'Personal Transport',
      'other_personal': 'Other Personal',
    };
    return labels[cat] ?? cat;
  }

  /// Smart Insights engine matching `generateInsights()` in `insights.js`.
  SmartInsightsResult generateInsights({DateTime? clockNow}) {
    final now = clockNow ?? DateTime.now();
    final thisMonth = DateFormat('yyyy-MM').format(now);
    final lastMonthDate = DateTime(now.year, now.month - 1, 1);
    final lastMonth = DateFormat('yyyy-MM').format(lastMonthDate);

    final urgent = <String>[];
    final attention = <String>[];
    final good = <String>[];

    final activeInvoices = _vault.invoices.where((i) => !i.isDraft).toList();
    final thisMonthInvs =
        activeInvoices.where((i) => i.date.startsWith(thisMonth)).toList();
    final lastMonthInvs =
        activeInvoices.where((i) => i.date.startsWith(lastMonth)).toList();

    // URGENT: Overdue invoices
    final overdue = activeInvoices.where((i) {
      if (i.isPaid) return false;
      final due = AppHelpers.parseAppDate(i.dueDate);
      if (due != null && due.isBefore(now)) return true;
      final invDate = AppHelpers.parseAppDate(i.date);
      if (invDate == null) return false;
      return now.difference(invDate).inMilliseconds >
          30 * 24 * 60 * 60 * 1000;
    }).toList();
    if (overdue.isNotEmpty) {
      final total = overdue.fold<double>(0, (s, i) => s + i.totalSell);
      urgent.add(
        '${overdue.length} invoice${overdue.length > 1 ? 's' : ''} overdue — '
        'total KES ${formatMoney(total)} outstanding',
      );
    }

    // URGENT: Unpaid salaries
    final activeStaff = _vault.staff.where((s) => s.isActive).toList();
    final unpaidStaff = activeStaff.where((s) {
      final isPaid = _vault.salaryPayments.any(
        (p) => p.staffId == s.id && p.month == thisMonth,
      );
      if (isPaid) return false;
      final payDay = int.tryParse(s.payDay) ?? 5;
      return now.day >= payDay;
    }).toList();
    if (unpaidStaff.isNotEmpty) {
      final names = unpaidStaff.map((s) => s.name).join(', ');
      final total = unpaidStaff.fold<double>(0, (s, x) => s + x.salary);
      urgent.add('Unpaid salaries: $names — KES ${formatMoney(total)}');
    }

    // URGENT: Recurring expenses due/overdue
    final recurringDue = _vault.recurringExpenses.where((r) {
      final dueDay = int.tryParse(r.dueDay) ?? 1;
      final isPaid = _vault.expenses.any(
        (e) =>
            e.category == r.category &&
            e.desc == r.desc &&
            e.date.startsWith(thisMonth),
      );
      return !isPaid && now.day >= dueDay;
    }).toList();
    for (final r in recurringDue) {
      urgent.add(
        '${r.desc} (KES ${formatMoney(r.amount)}) is due — not yet paid this month',
      );
    }

    // ATTENTION: Restaurants with old unpaid invoices (> 30 days)
    final restDebts = <String, ({double total, int days})>{};
    for (final inv in activeInvoices.where((i) => !i.isPaid)) {
      final invDate = AppHelpers.parseAppDate(inv.date);
      if (invDate == null) continue;
      final days = now.difference(invDate).inDays;
      if (days > 30) {
        final name = Restaurant.invoiceDisplayName(inv, _vault.restaurants);
        final prev = restDebts[name];
        restDebts[name] = (
          total: (prev?.total ?? 0) + inv.totalSell,
          days: prev == null ? days : (days > prev.days ? days : prev.days),
        );
      }
    }
    restDebts.forEach((name, data) {
      attention.add(
        '$name owes KES ${formatMoney(data.total)} (oldest is ${data.days} days old)',
      );
    });

    // ATTENTION: Borrowed Loans (Boss's Account)
    if (_vault.borrowings.isNotEmpty) {
      var totalBorrowed = 0.0;
      var totalRepaid = 0.0;
      for (final loan in _vault.borrowings) {
        if (loan.type != 'repay') {
          totalBorrowed += loan.amount;
          totalRepaid += loan.totalRepaid;
        }
      }
      final outstanding = totalBorrowed - totalRepaid;
      if (outstanding > 0) {
        attention.add(
          "Boss's Account has an outstanding loan balance of KES ${formatMoney(outstanding)}. "
          'Consider making partial repayments to clear it.',
        );
      }
    }

    // ATTENTION: Expense category spikes vs last month (> 25%)
    final thisMonthExps = _vault.expenses
        .where((e) => e.type == 'expense' && e.date.startsWith(thisMonth));
    final lastMonthExps = _vault.expenses
        .where((e) => e.type == 'expense' && e.date.startsWith(lastMonth));
    final thisByCategory = <String, double>{};
    final lastByCategory = <String, double>{};
    for (final e in thisMonthExps) {
      thisByCategory[e.category] =
          (thisByCategory[e.category] ?? 0) + e.amount;
    }
    for (final e in lastMonthExps) {
      lastByCategory[e.category] =
          (lastByCategory[e.category] ?? 0) + e.amount;
    }
    thisByCategory.forEach((cat, amount) {
      final lastAmt = lastByCategory[cat] ?? 0;
      if (lastAmt > 0) {
        final pctChange = ((amount - lastAmt) / lastAmt) * 100;
        if (pctChange > 25) {
          attention.add(
            '${getExpenseCategoryLabel(cat)} expenses up ${pctChange.toStringAsFixed(0)}% '
            'vs last month (KES ${formatMoney(amount)} vs ${formatMoney(lastAmt)})',
          );
        }
      }
    });

    // GOOD NEWS / ATTENTION: Revenue comparison
    final thisRevenue =
        thisMonthInvs.fold<double>(0, (s, i) => s + i.totalSell);
    final lastRevenue =
        lastMonthInvs.fold<double>(0, (s, i) => s + i.totalSell);
    if (thisRevenue > 0 && lastRevenue > 0) {
      final pct = ((thisRevenue - lastRevenue) / lastRevenue) * 100;
      if (pct > 0) {
        good.add(
          'Revenue up ${pct.toStringAsFixed(0)}% this month — '
          'KES ${formatMoney(thisRevenue)} vs KES ${formatMoney(lastRevenue)} last month',
        );
      } else if (pct < -5) {
        attention.add(
          'Revenue down ${pct.abs().toStringAsFixed(0)}% vs last month',
        );
      }
    } else if (thisRevenue > 0) {
      good.add(
        "This month's revenue: KES ${formatMoney(thisRevenue)} from ${thisMonthInvs.length} invoices",
      );
    }

    // GOOD NEWS: Top customer this month
    if (thisMonthInvs.isNotEmpty) {
      final byRest = <String, double>{};
      for (final i in thisMonthInvs) {
        final name = Restaurant.invoiceDisplayName(i, _vault.restaurants);
        byRest[name] = (byRest[name] ?? 0) + i.totalSell;
      }
      final sorted = byRest.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (sorted.isNotEmpty) {
        final top = sorted.first;
        good.add(
          'Top customer: ${top.key} — KES ${formatMoney(top.value)} this month',
        );
      }
    }

    // GOOD NEWS: Profit margin
    final thisProfit = thisMonthInvs.fold<double>(0, (s, i) => s + i.profit);
    if (thisRevenue > 0) {
      final margin = (thisProfit / thisRevenue) * 100;
      good.add('Gross profit margin: ${margin.toStringAsFixed(1)}% this month');
    }

    // GOOD NEWS: All salaries paid
    if (activeStaff.isNotEmpty && unpaidStaff.isEmpty && now.day >= 5) {
      good.add('All ${activeStaff.length} staff salaries paid this month');
    }

    // GOOD NEWS: Milestones
    final totalInvoices = activeInvoices.length;
    const milestones = [10, 25, 50, 100, 250, 500, 1000];
    for (final m in milestones) {
      if (totalInvoices >= m && totalInvoices < m + 5) {
        good.add('Milestone: $m+ invoices created!');
      }
    }

    return SmartInsightsResult(
      urgent: urgent,
      attention: attention,
      good: good,
    );
  }

  /// Monthly P&L breakdown matching `renderMonthlyPnL()` in `insights.js`.
  MonthlyPnLData buildMonthlyPnL(String month) {
    final parts = month.split('-');
    final yr = int.tryParse(parts.firstOrNull ?? '') ?? DateTime.now().year;
    final mo = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? DateTime.now().month;
    final monthDate = DateTime(yr, mo, 1);
    final monthName = DateFormat('MMMM yyyy').format(monthDate);
    final prevDate = DateTime(yr, mo - 1, 1);
    final prevMonth = DateFormat('yyyy-MM').format(prevDate);

    final invs = _vault.invoices
        .where((i) => !i.isDraft && i.date.startsWith(month))
        .toList();
    final prevInvs = _vault.invoices
        .where((i) => !i.isDraft && i.date.startsWith(prevMonth))
        .toList();

    final revenue = invs.fold<double>(0, (s, i) => s + i.totalSell);
    final prevRevenue = prevInvs.fold<double>(0, (s, i) => s + i.totalSell);
    final cogs = invs.fold<double>(0, (s, i) => s + i.totalBuy);
    final grossProfit = revenue - cogs;

    final exps = _vault.expenses
        .where((e) => e.type == 'expense' && e.date.startsWith(month))
        .toList();
    final expByCat = <String, double>{};
    for (final e in exps) {
      final label = getExpenseCategoryLabel(e.category);
      expByCat[label] = (expByCat[label] ?? 0) + e.amount;
    }
    final sortedCats = expByCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final totalExpenses = exps.fold<double>(0, (s, e) => s + e.amount);
    final salaryTotal = _vault.salaryPayments
        .where((p) => p.month == month)
        .fold<double>(0, (s, p) => s + p.amount);
    final capital = _vault.expenses
        .where((e) => e.type == 'capital' && e.date.startsWith(month))
        .fold<double>(0, (s, e) => s + e.amount);

    final netProfit = grossProfit - totalExpenses;
    final revChangePct = prevRevenue > 0
        ? ((revenue - prevRevenue) / prevRevenue) * 100
        : null;

    return MonthlyPnLData(
      month: month,
      monthName: monthName,
      revenue: revenue,
      prevRevenue: prevRevenue,
      revenueChangePct: revChangePct,
      cogs: cogs,
      grossProfit: grossProfit,
      grossMarginPct: revenue > 0 ? (grossProfit / revenue) * 100 : null,
      expensesByCategory: sortedCats,
      salaryTotal: salaryTotal,
      totalExpenses: totalExpenses,
      netProfit: netProfit,
      netMarginPct: revenue > 0 ? (netProfit / revenue) * 100 : null,
      capitalAdded: capital,
    );
  }

  /// Builds trailing N-month revenue/cost/profit/expense trend points for charts.
  List<MonthlyTrendPoint> buildMonthlyTrend({
    int months = 6,
    DateTime? clockNow,
  }) {
    final now = clockNow ?? DateTime.now();
    final points = <MonthlyTrendPoint>[];
    for (var offset = months - 1; offset >= 0; offset--) {
      final d = DateTime(now.year, now.month - offset, 1);
      final ym = DateFormat('yyyy-MM').format(d);
      final label = DateFormat('MMM').format(d);
      final invs = _vault.invoices
          .where((i) => !i.isDraft && i.date.startsWith(ym))
          .toList();
      final rev = invs.fold<double>(0, (s, i) => s + i.totalSell);
      final cost = invs.fold<double>(0, (s, i) => s + i.totalBuy);
      final profit = invs.fold<double>(0, (s, i) => s + i.profit);
      final exp = _vault.expenses
          .where((e) => e.type == 'expense' && e.date.startsWith(ym))
          .fold<double>(0, (s, e) => s + e.amount);
      points.add(
        MonthlyTrendPoint(
          month: ym,
          label: label,
          revenue: rev,
          cost: cost,
          profit: profit,
          expenses: exp,
        ),
      );
    }
    return points;
  }

  /// Expense breakdown slices for PieChart in a given month (`yyyy-MM`).
  List<ExpenseCategorySlice> buildExpenseBreakdown(String month) {
    final byCat = <String, double>{};
    for (final e in _vault.expenses) {
      if (e.type == 'expense' && e.date.startsWith(month)) {
        byCat[e.category] = (byCat[e.category] ?? 0) + e.amount;
      }
    }
    final list = byCat.entries
        .map(
          (e) => ExpenseCategorySlice(
            category: e.key,
            label: getExpenseCategoryLabel(e.key),
            amount: e.value,
          ),
        )
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return list;
  }

  /// Product catalog list aggregated across invoices matching `toggleReportRestaurant()`.
  List<ProductCatalogOption> getProductCatalog() {
    final map = <String, ProductCatalogOption>{};
    for (final inv in _vault.invoices) {
      for (final item in inv.items) {
        final name = item.desc.trim();
        if (name.isEmpty) continue;
        final key = name.toLowerCase();
        final prev = map[key];
        map[key] = ProductCatalogOption(
          key: key,
          name: prev?.name ?? name,
          qty: (prev?.qty ?? 0) + item.qty,
          unit: prev?.unit ?? (item.unit.isEmpty ? 'kgs' : item.unit),
          count: (prev?.count ?? 0) + 1,
        );
      }
    }
    final list = map.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Generates general, by-restaurant, or by-product report matching `generateReport()` in `dashboard.js`.
  GeneratedReportData generateReport({
    required String type,
    required String dateType,
    String singleDate = '',
    String fromDate = '',
    String toDate = '',
    String? restaurantId,
    String? productQuery,
  }) {
    var from = '';
    var to = '';
    var dateRange = 'All Time';

    if (dateType == 'single') {
      from = singleDate;
      to = singleDate;
      dateRange = from.isNotEmpty ? formatDate(from) : 'All Time';
    } else if (dateType == 'range') {
      from = fromDate;
      to = toDate;
      final left = from.isNotEmpty ? formatDate(from) : 'Start';
      final right = to.isNotEmpty ? formatDate(to) : 'Present';
      dateRange = '$left — $right';
    }

    var invs = _vault.invoices.where((i) => !i.isDraft).toList();
    if (from.isNotEmpty) {
      final fKey = AppHelpers.appDateKey(from);
      invs = invs
          .where((i) => AppHelpers.appDateKey(i.date).compareTo(fKey) >= 0)
          .toList();
    }
    if (to.isNotEmpty) {
      final tKey = AppHelpers.appDateKey(to);
      invs = invs
          .where((i) => AppHelpers.appDateKey(i.date).compareTo(tKey) <= 0)
          .toList();
    }

    if (type == 'product') {
      final query = (productQuery ?? '').toLowerCase().trim();
      final matches = <ProductReportTransaction>[];
      var totalSell = 0.0;
      var totalBuy = 0.0;
      final byRest = <String, ({double qty, double sell, double buy, int count})>{};
      final byUnit = <String, double>{};

      if (query.isNotEmpty) {
        for (final inv in invs) {
          final restName =
              Restaurant.invoiceDisplayName(inv, _vault.restaurants);
          for (final item in inv.items) {
            if (item.desc.toLowerCase().trim().contains(query)) {
              final unit = item.unit.isEmpty ? 'kgs' : item.unit;
              final cost = item.qty * item.buyPrice;
              final profit = item.total - cost;
              matches.add(
                ProductReportTransaction(
                  invoiceNumber: inv.number,
                  restaurantName: restName,
                  date: inv.date,
                  qty: item.qty,
                  unit: unit,
                  sellPrice: item.sellPrice,
                  buyPrice: item.buyPrice,
                  total: item.total,
                  cost: cost,
                  profit: profit,
                ),
              );
              totalSell += item.total;
              totalBuy += cost;
              final prev = byRest[restName];
              byRest[restName] = (
                qty: (prev?.qty ?? 0) + item.qty,
                sell: (prev?.sell ?? 0) + item.total,
                buy: (prev?.buy ?? 0) + cost,
                count: (prev?.count ?? 0) + 1,
              );
              byUnit[unit] = (byUnit[unit] ?? 0) + item.qty;
            }
          }
        }
      }

      matches.sort(
        (a, b) => AppHelpers.appDateKey(a.date)
            .compareTo(AppHelpers.appDateKey(b.date)),
      );
      final restBreakdown = byRest.entries
          .map(
            (e) => ReportRestaurantBreakdown(
              name: e.key,
              count: e.value.count,
              qty: e.value.qty,
              sell: e.value.sell,
              buy: e.value.buy,
              profit: e.value.sell - e.value.buy,
            ),
          )
          .toList()
        ..sort((a, b) => b.sell.compareTo(a.sell));

      final unitSummary = byUnit.entries
          .map((e) => '${e.value} ${e.key}')
          .join(', ');

      return GeneratedReportData(
        type: 'product',
        dateRangeLabel: dateRange,
        fromDate: from,
        toDate: to,
        targetLabel: query.isEmpty ? 'No product selected' : query,
        totalSell: totalSell,
        totalBuy: totalBuy,
        totalProfit: totalSell - totalBuy,
        byRestaurant: restBreakdown,
        unitSummary: unitSummary.isEmpty ? '0' : unitSummary,
        productTransactions: matches,
      );
    }

    var targetLabel = 'All Restaurants';
    if (type == 'restaurant' && restaurantId != null && restaurantId.isNotEmpty) {
      final selected = _vault.restaurants
          .where((r) => r.id == restaurantId)
          .firstOrNull;
      targetLabel = selected?.name ?? 'Unknown';
      invs = selected == null
          ? <Invoice>[]
          : invs
              .where(
                (i) => Restaurant.invoiceBelongsToRestaurant(
                  i,
                  selected,
                  _vault.restaurants,
                ),
              )
              .toList();
    }

    invs.sort(
      (a, b) =>
          AppHelpers.appDateKey(a.date).compareTo(AppHelpers.appDateKey(b.date)),
    );

    final totalSell = invs.fold<double>(0, (s, i) => s + i.totalSell);
    final totalBuy = invs.fold<double>(0, (s, i) => s + i.totalBuy);
    final totalProfit = invs.fold<double>(0, (s, i) => s + i.profit);
    final paidTotal = invs
        .where((i) => i.isPaid)
        .fold<double>(0, (s, i) => s + i.totalSell);
    final pendingTotal = invs
        .where((i) => !i.isPaid)
        .fold<double>(0, (s, i) => s + i.totalSell);

    final isGeneral = type == 'general';
    var filteredExpenses = <Expense>[];
    if (isGeneral) {
      filteredExpenses = List<Expense>.from(_vault.expenses);
      if (from.isNotEmpty) {
        final fKey = AppHelpers.appDateKey(from);
        filteredExpenses = filteredExpenses
            .where((e) => AppHelpers.appDateKey(e.date).compareTo(fKey) >= 0)
            .toList();
      }
      if (to.isNotEmpty) {
        final tKey = AppHelpers.appDateKey(to);
        filteredExpenses = filteredExpenses
            .where((e) => AppHelpers.appDateKey(e.date).compareTo(tKey) <= 0)
            .toList();
      }
      filteredExpenses.sort(
        (a, b) => AppHelpers.appDateKey(a.date)
            .compareTo(AppHelpers.appDateKey(b.date)),
      );
    }

    final expenseItems =
        filteredExpenses.where((e) => e.type == 'expense').toList();
    final capitalItems =
        filteredExpenses.where((e) => e.type == 'capital').toList();
    final totalExpenses =
        expenseItems.fold<double>(0, (s, e) => s + e.amount);
    final totalCapital =
        capitalItems.fold<double>(0, (s, e) => s + e.amount);
    final netPosition = isGeneral
        ? (totalCapital + paidTotal - totalBuy - totalExpenses)
        : (paidTotal - totalBuy);

    final byRestMap = <String, ({double sell, double buy, double profit, int count})>{};
    for (final inv in invs) {
      final name = Restaurant.invoiceDisplayName(inv, _vault.restaurants);
      final prev = byRestMap[name];
      byRestMap[name] = (
        sell: (prev?.sell ?? 0) + inv.totalSell,
        buy: (prev?.buy ?? 0) + inv.totalBuy,
        profit: (prev?.profit ?? 0) + inv.profit,
        count: (prev?.count ?? 0) + 1,
      );
    }
    final byRest = byRestMap.entries
        .map(
          (e) => ReportRestaurantBreakdown(
            name: e.key,
            count: e.value.count,
            qty: 0,
            sell: e.value.sell,
            buy: e.value.buy,
            profit: e.value.profit,
          ),
        )
        .toList()
      ..sort((a, b) => b.sell.compareTo(a.sell));

    final catMap = <String, ({double total, int count})>{};
    for (final e in expenseItems) {
      final prev = catMap[e.category];
      catMap[e.category] = (
        total: (prev?.total ?? 0) + e.amount,
        count: (prev?.count ?? 0) + 1,
      );
    }
    final byCat = catMap.entries
        .map(
          (e) => ReportExpenseCategoryRow(
            category: e.key,
            count: e.value.count,
            total: e.value.total,
          ),
        )
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    return GeneratedReportData(
      type: type,
      dateRangeLabel: dateRange,
      fromDate: from,
      toDate: to,
      targetLabel: targetLabel,
      totalSell: totalSell,
      totalBuy: totalBuy,
      totalProfit: totalProfit,
      paidTotal: paidTotal,
      pendingTotal: pendingTotal,
      totalExpenses: totalExpenses,
      totalCapital: totalCapital,
      netPosition: netPosition,
      invoices: invs,
      expenseItems: expenseItems,
      capitalItems: capitalItems,
      byRestaurant: byRest,
      expensesByCategory: byCat,
    );
  }

  /// Generates A4 PDF bytes for a Financial / Product Report matching `downloadReportPDF()` in `dashboard.js`.
  Future<Uint8List> buildReportPdfBytes(GeneratedReportData data) async {
    final doc = pw.Document(
      title: data.isProduct ? 'Product Report' : 'Financial Report',
      author: 'Town Treasure Limited',
    );
    const leafGreen = PdfColor.fromInt(0xFF61B146);
    const slateDark = PdfColor.fromInt(0xFF313A43);
    const forestGreen = PdfColor.fromInt(0xFF2E7D32);
    const dangerRed = PdfColor.fromInt(0xFFDC2626);
    final generatedDate = formatDate(
      DateTime.now().toIso8601String().substring(0, 10),
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(40, 28, 40, 56),
          buildBackground: (_) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Stack(
              children: [
                pw.Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: pw.Column(
                    children: [
                      pw.Container(height: 10, color: leafGreen),
                      pw.Container(height: 4, color: slateDark),
                    ],
                  ),
                ),
                pw.Center(
                  child: pw.Transform.rotate(
                    angle: -0.52,
                    child: pw.Opacity(
                      opacity: 0.06,
                      child: pw.Text(
                        'Town Treasure Limited',
                        style: pw.TextStyle(
                          fontSize: 42,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.grey600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        footer: (_) => pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: slateDark,
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Generated on $generatedDate - Town Treasure Groceries',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 8.5,
                  fontStyle: pw.FontStyle.italic,
                ),
              ),
              pw.Text(
                data.isProduct ? 'Product Report' : 'Financial Report',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 8),
              ),
            ],
          ),
        ),
        build: (_) {
          final widgets = <pw.Widget>[
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      data.isProduct ? 'PRODUCT REPORT' : 'FINANCIAL REPORT',
                      style: pw.TextStyle(
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                        color: leafGreen,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      data.isProduct
                          ? 'Product: ${data.targetLabel}'
                          : 'For: ${data.targetLabel}',
                      style: const pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      'Period: ${data.dateRangeLabel.replaceAll('—', '-')}',
                      style: const pw.TextStyle(fontSize: 9.5),
                    ),
                    pw.Text(
                      'Generated: $generatedDate',
                      style: const pw.TextStyle(fontSize: 9.5),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 14),
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
              ),
              child: pw.Wrap(
                spacing: 18,
                runSpacing: 8,
                children: [
                  if (data.isProduct)
                    pw.Text(
                      'Total Sold: ${data.unitSummary}',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  pw.Text(
                    'Sales: KES ${formatMoney(data.totalSell)}',
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      fontWeight: pw.FontWeight.bold,
                      color: forestGreen,
                    ),
                  ),
                  pw.Text(
                    'Cost: KES ${formatMoney(data.totalBuy)}',
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      fontWeight: pw.FontWeight.bold,
                      color: dangerRed,
                    ),
                  ),
                  pw.Text(
                    'Profit: KES ${formatMoney(data.totalProfit)}',
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      fontWeight: pw.FontWeight.bold,
                      color: data.totalProfit >= 0 ? forestGreen : dangerRed,
                    ),
                  ),
                  if (data.isGeneral) ...[
                    pw.Text(
                      'Expenses: KES ${formatMoney(data.totalExpenses)}',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: dangerRed,
                      ),
                    ),
                    pw.Text(
                      'Capital In: KES ${formatMoney(data.totalCapital)}',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromInt(0xFF2563EB),
                      ),
                    ),
                    pw.Text(
                      'Net Position: KES ${formatMoney(data.netPosition)}',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: data.netPosition >= 0 ? forestGreen : dangerRed,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            pw.SizedBox(height: 16),
          ];

          if (data.byRestaurant.isNotEmpty) {
            widgets.add(
              pw.Text(
                'Sales by Restaurant',
                style: pw.TextStyle(
                  fontSize: 11.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: [
                  'Restaurant',
                  'Orders',
                  if (data.isProduct) 'Qty',
                  'Revenue',
                  'Cost',
                  'Profit',
                ],
                data: data.byRestaurant
                    .map(
                      (r) => [
                        r.name,
                        '${r.count}',
                        if (data.isProduct) '${r.qty}',
                        'KES ${formatMoney(r.sell)}',
                        'KES ${formatMoney(r.buy)}',
                        'KES ${formatMoney(r.profit)}',
                      ],
                    )
                    .toList(),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 8.5,
                ),
                cellStyle: const pw.TextStyle(fontSize: 8.5),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
              ),
            );
            widgets.add(pw.SizedBox(height: 14));
          }

          if (data.isProduct && data.productTransactions.isNotEmpty) {
            widgets.add(
              pw.Text(
                'Transaction History',
                style: pw.TextStyle(
                  fontSize: 11.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: [
                  'Invoice',
                  'Restaurant',
                  'Date',
                  'Qty',
                  'Unit',
                  'Price',
                  'Total',
                  'Profit',
                ],
                data: data.productTransactions
                    .map(
                      (m) => [
                        m.invoiceNumber,
                        m.restaurantName,
                        formatDate(m.date),
                        '${m.qty}',
                        m.unit,
                        'KES ${formatMoney(m.sellPrice)}',
                        'KES ${formatMoney(m.total)}',
                        'KES ${formatMoney(m.profit)}',
                      ],
                    )
                    .toList(),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                  fontSize: 8,
                ),
                cellStyle: const pw.TextStyle(fontSize: 8),
                headerDecoration: const pw.BoxDecoration(color: slateDark),
              ),
            );
          }

          if (!data.isProduct && data.invoices.isNotEmpty) {
            widgets.add(
              pw.Text(
                'All Invoices',
                style: pw.TextStyle(
                  fontSize: 11.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: ['#', 'Restaurant', 'Date', 'Amount', 'Profit', 'Status'],
                data: data.invoices
                    .map(
                      (i) => [
                        i.number,
                        Restaurant.invoiceDisplayName(i, _vault.restaurants),
                        formatDate(i.date),
                        'KES ${formatMoney(i.totalSell)}',
                        'KES ${formatMoney(i.profit)}',
                        i.status,
                      ],
                    )
                    .toList(),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 8.5,
                ),
                cellStyle: const pw.TextStyle(fontSize: 8.5),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
              ),
            );
            widgets.add(pw.SizedBox(height: 14));
          }

          if (data.isGeneral && data.expenseItems.isNotEmpty) {
            widgets.add(
              pw.Text(
                'All Expenses',
                style: pw.TextStyle(
                  fontSize: 11.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            );
            widgets.add(pw.SizedBox(height: 6));
            widgets.add(
              pw.TableHelper.fromTextArray(
                headers: ['Date', 'Description', 'Category', 'Amount'],
                data: data.expenseItems
                    .map(
                      (e) => [
                        formatDate(e.date),
                        e.desc,
                        getExpenseCategoryLabel(e.category),
                        'KES ${formatMoney(e.amount)}',
                      ],
                    )
                    .toList(),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 8.5,
                ),
                cellStyle: const pw.TextStyle(fontSize: 8.5),
                headerDecoration:
                    const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
              ),
            );
          }

          return widgets;
        },
      ),
    );

    return doc.save();
  }

  /// Generates an Excel `.xlsx` workbook for the active report or full financial export.
  Uint8List buildReportExcelBytes(GeneratedReportData data) {
    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet() ?? 'Sheet1';

    final invSheet = excel['Invoices'];
    invSheet.appendRow([
      TextCellValue('Invoice #'),
      TextCellValue('Restaurant'),
      TextCellValue('Date'),
      TextCellValue('Total Sell (KES)'),
      TextCellValue('Total Buy (KES)'),
      TextCellValue('Profit (KES)'),
      TextCellValue('Status'),
    ]);
    for (final inv in data.invoices) {
      invSheet.appendRow([
        TextCellValue(inv.number),
        TextCellValue(
          Restaurant.invoiceDisplayName(inv, _vault.restaurants),
        ),
        TextCellValue(formatDate(inv.date)),
        DoubleCellValue(inv.totalSell),
        DoubleCellValue(inv.totalBuy),
        DoubleCellValue(inv.profit),
        TextCellValue(inv.status),
      ]);
    }

    final expSheet = excel['Expenses'];
    expSheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Description'),
      TextCellValue('Category'),
      TextCellValue('Amount (KES)'),
      TextCellValue('Type'),
    ]);
    final expSource =
        data.isGeneral ? [...data.expenseItems, ...data.capitalItems] : _vault.expenses;
    for (final e in expSource) {
      expSheet.appendRow([
        TextCellValue(formatDate(e.date)),
        TextCellValue(e.desc),
        TextCellValue(e.category),
        DoubleCellValue(e.amount),
        TextCellValue(e.type),
      ]);
    }

    final staffSheet = excel['Staff'];
    staffSheet.appendRow([
      TextCellValue('Name'),
      TextCellValue('Role'),
      TextCellValue('Salary (KES)'),
      TextCellValue('Pay Day'),
      TextCellValue('Status'),
    ]);
    for (final s in _vault.staff) {
      staffSheet.appendRow([
        TextCellValue(s.name),
        TextCellValue(s.role),
        DoubleCellValue(s.salary),
        TextCellValue(s.payDay),
        TextCellValue(s.status),
      ]);
    }

    if (data.isProduct) {
      final prodSheet = excel['Product Report'];
      prodSheet.appendRow([
        TextCellValue('Invoice'),
        TextCellValue('Restaurant'),
        TextCellValue('Date'),
        TextCellValue('Qty'),
        TextCellValue('Unit'),
        TextCellValue('Sell Price'),
        TextCellValue('Total'),
        TextCellValue('Profit'),
      ]);
      for (final tx in data.productTransactions) {
        prodSheet.appendRow([
          TextCellValue(tx.invoiceNumber),
          TextCellValue(tx.restaurantName),
          TextCellValue(formatDate(tx.date)),
          DoubleCellValue(tx.qty),
          TextCellValue(tx.unit),
          DoubleCellValue(tx.sellPrice),
          DoubleCellValue(tx.total),
          DoubleCellValue(tx.profit),
        ]);
      }
    }

    if (excel.sheets.containsKey(defaultSheet) &&
        defaultSheet != 'Invoices') {
      excel.delete(defaultSheet);
    }

    final bytes = excel.encode();
    return Uint8List.fromList(bytes ?? const <int>[]);
  }

  Future<File> writeTempExcelFile(GeneratedReportData data) async {
    final bytes = buildReportExcelBytes(data);
    final dir = await getTemporaryDirectory();
    final safeRange =
        data.dateRangeLabel.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final file = File('${dir.path}/TTG_Report_${data.type}_$safeRange.xlsx');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<File> writeTempReportPdfFile(GeneratedReportData data) async {
    final bytes = await buildReportPdfBytes(data);
    final dir = await getTemporaryDirectory();
    final safeRange =
        data.dateRangeLabel.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final file = File('${dir.path}/Report_${data.type}_$safeRange.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  // --- Monthly Client Statements matching `statements.js` ---

  List<Invoice> getStatementInvoices(Restaurant restaurant) {
    return _vault.invoices
        .where(
          (inv) =>
              !inv.isDraft &&
              Restaurant.invoiceBelongsToRestaurant(
                inv,
                restaurant,
                _vault.restaurants,
              ),
        )
        .toList();
  }

  static String getStatementMonthEnd(String month, int year, int monthNumber) {
    final finalDay = DateTime(year, monthNumber + 1, 0).day;
    return '$month-${finalDay.toString().padLeft(2, '0')}';
  }

  ClientStatementData buildStatement(
    Restaurant rest,
    String month, {
    DateTime? clockNow,
  }) {
    final parts = month.split('-');
    final yr = int.tryParse(parts.firstOrNull ?? '') ?? DateTime.now().year;
    final mo = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? DateTime.now().month;
    final monthName = DateFormat('MMMM yyyy').format(DateTime(yr, mo, 1));
    final monthStart = '$month-01';
    final monthEnd = getStatementMonthEnd(month, yr, mo);

    final allInvoices = getStatementInvoices(rest);

    final priorInvoices = allInvoices
        .where(
          (i) =>
              AppHelpers.appDateKey(i.date)
                  .compareTo(AppHelpers.appDateKey(monthStart)) <
              0,
        )
        .toList();
    final priorPaidTotal = priorInvoices
        .where((i) => i.isPaid)
        .fold<double>(0, (s, i) => s + i.totalSell);
    final priorInvoicedTotal =
        priorInvoices.fold<double>(0, (s, i) => s + i.totalSell);
    final openingBalance = priorInvoicedTotal - priorPaidTotal;

    final startKey = AppHelpers.appDateKey(monthStart);
    final endKey = AppHelpers.appDateKey(monthEnd);
    final monthInvoices = allInvoices
        .where((i) {
          final k = AppHelpers.appDateKey(i.date);
          return k.compareTo(startKey) >= 0 && k.compareTo(endKey) <= 0;
        })
        .toList()
      ..sort(
        (a, b) => AppHelpers.appDateKey(a.date)
            .compareTo(AppHelpers.appDateKey(b.date)),
      );

    final monthInvoicedTotal =
        monthInvoices.fold<double>(0, (s, i) => s + i.totalSell);
    final monthPaidTotal = monthInvoices
        .where((i) => i.isPaid)
        .fold<double>(0, (s, i) => s + i.totalSell);

    var runningBalance = openingBalance;
    final transactions = <StatementTransaction>[];
    for (final inv in monthInvoices) {
      runningBalance += inv.totalSell;
      transactions.add(
        StatementTransaction(
          date: inv.date,
          desc: 'Invoice ${inv.number}',
          itemsLabel: '${inv.items.length} items',
          debit: inv.totalSell,
          credit: 0,
          balance: runningBalance,
          type: 'invoice',
        ),
      );
      if (inv.isPaid) {
        runningBalance -= inv.totalSell;
        transactions.add(
          StatementTransaction(
            date: inv.date,
            desc: 'Payment — ${inv.number}',
            itemsLabel: '',
            debit: 0,
            credit: inv.totalSell,
            balance: runningBalance,
            type: 'payment',
          ),
        );
      }
    }
    final closingBalance = runningBalance;

    final unpaidInvoices = allInvoices.where(
      (i) =>
          !i.isPaid &&
          AppHelpers.appDateKey(i.date).compareTo(endKey) <= 0,
    );
    final refNow = clockNow ?? DateTime.now();
    final now = DateTime(yr, mo, refNow.day);
    var current = 0.0;
    var days30 = 0.0;
    var days60 = 0.0;
    var days90 = 0.0;
    for (final inv in unpaidInvoices) {
      final invDate = AppHelpers.parseAppDate(inv.date);
      if (invDate == null) continue;
      final daysDiff = now.difference(invDate).inDays;
      if (daysDiff <= 30) {
        current += inv.totalSell;
      } else if (daysDiff <= 60) {
        days30 += inv.totalSell;
      } else if (daysDiff <= 90) {
        days60 += inv.totalSell;
      } else {
        days90 += inv.totalSell;
      }
    }

    return ClientStatementData(
      restaurant: rest,
      month: month,
      monthName: monthName,
      openingBalance: openingBalance,
      monthInvoicedTotal: monthInvoicedTotal,
      monthPaidTotal: monthPaidTotal,
      closingBalance: closingBalance,
      transactions: transactions,
      ageAnalysis: DebtAgeAnalysis(
        current: current,
        days30: days30,
        days60: days60,
        days90: days90,
      ),
    );
  }

  List<ClientStatementData> buildAllStatements(String month) {
    return _vault.restaurants
        .map((r) => buildStatement(r, month))
        .toList();
  }

  static String normalizeKenyanWhatsAppPhone(String rawPhone) {
    var phone = rawPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (phone.startsWith('0')) {
      phone = '254${phone.substring(1)}';
    }
    return phone;
  }

  static String buildStatementWhatsAppText(
    Restaurant rest,
    String monthName,
  ) {
    final addressee =
        rest.contact.trim().isNotEmpty ? rest.contact.trim() : rest.name;
    return 'Hello $addressee,\n\n'
        'Here is your account statement from Town Treasure Groceries for *$monthName*.\n\n'
        'Please find the attached PDF statement showing all invoices and payments for the period.\n\n'
        'For any queries, please call 0708567696.\n\n'
        'Thank you for your business!';
  }
}
