import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';

/// KPI summary for Capital & Finance Hub matching `renderExpenses()` in `views.js`.
class FinanceHubSummary {
  const FinanceHubSummary({
    required this.totalCapital,
    required this.totalExpenses,
    required this.paidRevenue,
    required this.netBalance,
  });

  final double totalCapital;
  final double totalExpenses;
  final double paidRevenue;
  final double netBalance;
}

/// Payroll KPI summary matching `updatePayrollSummary()` in `payroll.js`.
class PayrollSummary {
  const PayrollSummary({
    required this.totalStaff,
    required this.monthlyPayroll,
    required this.paidCount,
    required this.paidAmount,
    required this.outstanding,
  });

  final int totalStaff;
  final double monthlyPayroll;
  final int paidCount;
  final double paidAmount;
  final double outstanding;
}

/// Boss's Account (Borrowings) KPI summary matching `renderBorrowingsTab()`.
class BorrowingsSummary {
  const BorrowingsSummary({
    required this.totalBorrowed,
    required this.totalRepaid,
    required this.outstandingBalance,
  });

  final double totalBorrowed;
  final double totalRepaid;
  final double outstandingBalance;
}

/// MVVM ViewModel for Capital, Expenses, Payroll, Recurring Bills, Personal, and Borrowings.
class ExpensesViewModel extends ChangeNotifier {
  ExpensesViewModel({required this._vault, DateTime? now})
      : _selectedMonth =
            DateFormat('yyyy-MM').format(now ?? DateTime.now()) {
    _vault.addListener(_onVaultChanged);
  }

  final VaultRepository _vault;
  String _selectedMonth;

  static const List<String> expenseCategories = [
    'transport',
    'rent',
    'utilities',
    'supplies',
    'wages',
    'inventory',
    'capital',
    'other',
  ];

  static const List<String> recurringCategories = [
    'rent',
    'utilities',
    'software',
    'insurance',
    'other',
  ];

  static const Map<String, String> personalCategoryLabels = {
    'personal': 'Personal',
    'airtime': 'Airtime',
    'food_personal': 'Food & Meals',
    'personal_transport': 'Transport',
    'family': 'Family',
    'medical': 'Medical',
    'clothing': 'Clothing',
    'entertainment': 'Entertainment',
    'savings': 'Savings',
    'other_personal': 'Other',
  };

  static const Set<String> personalCategories = {
    'personal',
    'airtime',
    'food_personal',
    'medical',
    'family',
    'clothing',
    'entertainment',
    'savings',
    'personal_transport',
    'other_personal',
  };

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  void _onVaultChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _vault.removeListener(_onVaultChanged);
    super.dispose();
  }

  String get selectedMonth => _selectedMonth;

  void setSelectedMonth(String month) {
    if (_selectedMonth == month) return;
    _selectedMonth = month;
    notifyListeners();
  }

  static String formatMoney(double amount) => _moneyFormat.format(amount);

  static String formatDate(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    final parsed = AppHelpers.parseAppDate(value);
    if (parsed == null) return value;
    return DateFormat('dd/MM/yyyy').format(parsed);
  }

  static String getPersonalCategoryLabel(String cat) {
    return personalCategoryLabels[cat] ?? cat;
  }

  static String getCategoryLabel(String cat) {
    if (personalCategoryLabels.containsKey(cat)) {
      return personalCategoryLabels[cat]!;
    }
    const map = {
      'transport': 'Transport',
      'rent': 'Rent',
      'utilities': 'Utilities',
      'supplies': 'Supplies',
      'wages': 'Wages',
      'salaries': 'Salaries',
      'inventory': 'Inventory Purchase',
      'capital': 'Capital Injection',
      'software': 'Software/Subscriptions',
      'insurance': 'Insurance',
      'other': 'Other',
    };
    return map[cat] ?? (cat.isEmpty ? 'Other' : cat);
  }

  // --- Summary KPIs ---

  FinanceHubSummary get hubSummary {
    final totalCap = _vault.expenses
        .where((e) => e.type == 'capital')
        .fold<double>(0, (s, e) => s + e.amount);
    final totalExp = _vault.expenses
        .where((e) => e.type == 'expense')
        .fold<double>(0, (s, e) => s + e.amount);
    final totalRev = _vault.invoices
        .where((i) => i.status == 'paid')
        .fold<double>(0, (s, i) => s + i.totalSell);
    return FinanceHubSummary(
      totalCapital: totalCap,
      totalExpenses: totalExp,
      paidRevenue: totalRev,
      netBalance: totalCap + totalRev - totalExp,
    );
  }

  // --- Expenses & Capital ---

  List<Expense> get businessExpenses => _vault.expenses
      .where((e) => e.type == 'expense')
      .toList()
      .reversed
      .toList();

  List<Expense> get capitalEntries => _vault.expenses
      .where((e) => e.type == 'capital')
      .toList()
      .reversed
      .toList();

  Future<void> addExpenseEntry({
    required String type,
    required String date,
    required String desc,
    required String category,
    required double amount,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final entry = Expense(
      id: AppHelpers.genId(),
      type: type,
      date: date.isEmpty ? DateFormat('yyyy-MM-dd').format(DateTime.now()) : date,
      desc: desc.trim(),
      category: category,
      amount: amount,
      createdAt: nowIso,
      updatedAt: nowIso,
    );
    await _vault.setExpenses([..._vault.expenses, entry]);
  }

  Future<bool> deleteExpense(String id) async {
    await _vault.markRecordDeleted('expenses', id, sync: false);
    await _vault.setExpenses(
      _vault.expenses.where((e) => e.id != id).toList(),
      sync: false,
    );
    return _vault.syncNow();
  }

  // --- Monthly Salaries / Staff ---

  List<Staff> get activeStaff =>
      _vault.staff.where((s) => s.status == 'active').toList();

  bool isSalaryPaid(String staffId, [String? month]) {
    final m = month ?? _selectedMonth;
    return _vault.salaryPayments.any(
      (p) => p.staffId == staffId && p.month == m,
    );
  }

  SalaryPayment? getSalaryPayment(String staffId, [String? month]) {
    final m = month ?? _selectedMonth;
    for (final p in _vault.salaryPayments) {
      if (p.staffId == staffId && p.month == m) return p;
    }
    return null;
  }

  bool isSalaryOverdue(Staff staff, [String? month, DateTime? clockNow]) {
    final m = month ?? _selectedMonth;
    if (isSalaryPaid(staff.id, m)) return false;
    final parts = m.split('-');
    if (parts.length != 2) return false;
    final yr = int.tryParse(parts[0]) ?? DateTime.now().year;
    final mo = int.tryParse(parts[1]) ?? DateTime.now().month;
    final dueDay = int.tryParse(staff.payDay) ?? 5;
    final now = clockNow ?? DateTime.now();
    final payMonthDate = DateTime(yr, mo, 1);
    final dueDate = DateTime(yr, mo, dueDay);
    return now.isAfter(dueDate) &&
        now.month >= payMonthDate.month &&
        now.year >= payMonthDate.year;
  }

  PayrollSummary getPayrollSummary([String? month]) {
    final m = month ?? _selectedMonth;
    final staffList = activeStaff;
    final totalPayroll =
        staffList.fold<double>(0, (s, x) => s + x.salary);
    final paidStaff = staffList.where((s) => isSalaryPaid(s.id, m)).toList();
    final paidAmount = paidStaff.fold<double>(0, (s, x) => s + x.salary);
    return PayrollSummary(
      totalStaff: staffList.length,
      monthlyPayroll: totalPayroll,
      paidCount: paidStaff.length,
      paidAmount: paidAmount,
      outstanding: totalPayroll - paidAmount,
    );
  }

  Future<void> saveStaff({
    String? id,
    required String name,
    required String role,
    required double salary,
    required String phone,
    required String payDay,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final list = List<Staff>.from(_vault.staff);
    final idx = id == null || id.isEmpty
        ? -1
        : list.indexWhere((x) => x.id == id);

    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        name: name.trim(),
        role: role.trim(),
        salary: salary,
        phone: phone.trim(),
        payDay: payDay.isEmpty ? '5' : payDay,
        updatedAt: nowIso,
      );
    } else {
      list.add(
        Staff(
          id: AppHelpers.genId(),
          name: name.trim(),
          role: role.trim(),
          salary: salary,
          phone: phone.trim(),
          payDay: payDay.isEmpty ? '5' : payDay,
          status: 'active',
          createdAt: nowIso,
          updatedAt: nowIso,
        ),
      );
    }
    await _vault.setStaff(list);
  }

  Future<bool> deleteStaff(String id) async {
    final target = _vault.staff.where((x) => x.id == id).firstOrNull;
    if (target != null) {
      final deleted = target.copyWith(
        deletedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await _vault.setDeletedStaff(
        [..._vault.deletedStaff, deleted],
        sync: false,
      );
    }
    await _vault.setStaff(
      _vault.staff.where((x) => x.id != id).toList(),
      sync: false,
    );
    await _vault.markRecordDeleted('staff', id, sync: false);
    return _vault.syncNow();
  }

  Future<bool> markSalaryPaid(String staffId, {DateTime? now}) async {
    final month = _selectedMonth;
    final staff = _vault.staff.where((x) => x.id == staffId).firstOrNull;
    if (staff == null) return false;
    if (isSalaryPaid(staffId, month)) return false;

    final current = now ?? DateTime.now();
    final datePaid = DateFormat('yyyy-MM-dd').format(current);
    final createdAt = current.toUtc().toIso8601String();
    final payment = SalaryPayment(
      id: AppHelpers.genId(),
      staffId: staff.id,
      staffName: staff.name,
      month: month,
      amount: staff.salary,
      datePaid: datePaid,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await _vault.setSalaryPayments(
      [..._vault.salaryPayments, payment],
      sync: false,
    );

    final roleLabel = staff.role.trim().isEmpty ? 'Staff' : staff.role.trim();
    final linkedExpense = Expense(
      id: AppHelpers.genId(),
      type: 'expense',
      date: datePaid,
      desc: 'Salary — ${staff.name} ($roleLabel)',
      category: 'salaries',
      amount: staff.salary,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    await _vault.setExpenses([..._vault.expenses, linkedExpense]);
    return true;
  }

  Future<bool> undoSalaryPayment(String staffId) async {
    final month = _selectedMonth;
    final payment = getSalaryPayment(staffId, month);
    if (payment == null) return false;

    await _vault.markRecordDeleted('salaryPayments', payment.id, sync: false);
    await _vault.setSalaryPayments(
      _vault.salaryPayments.where((p) => p.id != payment.id).toList(),
      sync: false,
    );

    bool matchesLinked(Expense e) {
      return e.category == 'salaries' &&
          e.desc.contains(payment.staffName) &&
          e.date == payment.datePaid &&
          e.amount == payment.amount;
    }

    for (final exp in _vault.expenses.where(matchesLinked)) {
      await _vault.markRecordDeleted('expenses', exp.id, sync: false);
    }
    await _vault.setExpenses(
      _vault.expenses.where((e) => !matchesLinked(e)).toList(),
      sync: false,
    );
    return _vault.syncNow();
  }

  // --- Recurring Expenses ---

  List<RecurringExpense> get recurringExpenses => _vault.recurringExpenses;

  bool isRecurringPaid(RecurringExpense r, [String? month]) {
    final m = month ?? _selectedMonth;
    return _vault.expenses.any(
      (e) =>
          e.category == r.category &&
          e.desc == r.desc &&
          e.date.startsWith(m),
    );
  }

  bool isRecurringOverdue(
    RecurringExpense r, [
    String? month,
    DateTime? clockNow,
  ]) {
    final m = month ?? _selectedMonth;
    if (isRecurringPaid(r, m)) return false;
    final parts = m.split('-');
    if (parts.length != 2) return false;
    final yr = int.tryParse(parts[0]) ?? DateTime.now().year;
    final mo = int.tryParse(parts[1]) ?? DateTime.now().month;
    final dueDay = int.tryParse(r.dueDay) ?? 1;
    final now = clockNow ?? DateTime.now();
    final dueDate = DateTime(yr, mo, dueDay);
    return now.isAfter(dueDate);
  }

  Future<void> saveRecurring({
    String? id,
    required String desc,
    required String category,
    required double amount,
    required String dueDay,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final list = List<RecurringExpense>.from(_vault.recurringExpenses);
    final idx = id == null || id.isEmpty
        ? -1
        : list.indexWhere((x) => x.id == id);

    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        desc: desc.trim(),
        category: category,
        amount: amount,
        dueDay: dueDay.isEmpty ? '1' : dueDay,
        updatedAt: nowIso,
      );
    } else {
      list.add(
        RecurringExpense(
          id: AppHelpers.genId(),
          desc: desc.trim(),
          category: category,
          amount: amount,
          dueDay: dueDay.isEmpty ? '1' : dueDay,
          createdAt: nowIso,
          updatedAt: nowIso,
        ),
      );
    }
    await _vault.setRecurringExpenses(list);
  }

  Future<bool> deleteRecurring(String id) async {
    await _vault.markRecordDeleted('recurringExpenses', id, sync: false);
    await _vault.setRecurringExpenses(
      _vault.recurringExpenses.where((x) => x.id != id).toList(),
      sync: false,
    );
    return _vault.syncNow();
  }

  Future<bool> payRecurring(String recurringId, {DateTime? now}) async {
    final r = _vault.recurringExpenses
        .where((x) => x.id == recurringId)
        .firstOrNull;
    if (r == null) return false;
    if (isRecurringPaid(r, _selectedMonth)) return false;

    final current = now ?? DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(current);
    final nowIso = current.toUtc().toIso8601String();
    final expense = Expense(
      id: AppHelpers.genId(),
      type: 'expense',
      date: dateStr,
      desc: r.desc,
      category: r.category,
      amount: r.amount,
      createdAt: nowIso,
      updatedAt: nowIso,
    );
    await _vault.setExpenses([..._vault.expenses, expense]);
    return true;
  }

  // --- Personal Expenses ---

  List<Expense> get monthlyPersonalExpenses {
    return _vault.expenses
        .where(
          (e) =>
              personalCategories.contains(e.category) &&
              e.date.startsWith(_selectedMonth),
        )
        .toList()
        .reversed
        .toList();
  }

  double get monthlyPersonalTotal => monthlyPersonalExpenses.fold<double>(
        0,
        (s, e) => s + e.amount,
      );

  Future<void> addPersonalExpense({
    required String desc,
    required String category,
    required double amount,
    required String date,
  }) async {
    await addExpenseEntry(
      type: 'expense',
      date: date,
      desc: desc,
      category: category,
      amount: amount,
    );
  }

  // --- Boss's Account (Borrowings & Linked Expenses) ---

  List<Borrowing> get loans => _vault.borrowings
      .where((b) => b.type != 'repay')
      .toList()
      .reversed
      .toList();

  BorrowingsSummary get borrowingsSummary {
    var totalBorrowed = 0.0;
    var totalRepaid = 0.0;
    for (final loan in loans) {
      totalBorrowed += loan.amount;
      totalRepaid += loan.totalRepaid;
    }
    return BorrowingsSummary(
      totalBorrowed: totalBorrowed,
      totalRepaid: totalRepaid,
      outstandingBalance: totalBorrowed - totalRepaid,
    );
  }

  Future<void> saveBorrowing({
    String? id,
    required String date,
    required String desc,
    required double amount,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final resolvedDate =
        date.isEmpty ? DateFormat('yyyy-MM-dd').format(DateTime.now()) : date;
    final list = List<Borrowing>.from(_vault.borrowings);
    final idx = id == null || id.isEmpty
        ? -1
        : list.indexWhere((x) => x.id == id);

    var expenses = List<Expense>.from(_vault.expenses);
    if (idx >= 0) {
      final updated = list[idx].copyWith(
        date: resolvedDate,
        desc: desc.trim(),
        amount: amount,
        updatedAt: nowIso,
      );
      list[idx] = updated;
      expenses = _updateLinkedExpenseInList(
        expenses,
        refId: updated.id,
        refType: 'boss_loan',
        amount: amount,
        date: resolvedDate,
        desc: 'Boss Loan: ${desc.trim()}',
        updatedAt: nowIso,
      );
    } else {
      final item = Borrowing(
        id: AppHelpers.genId(),
        date: resolvedDate,
        desc: desc.trim(),
        amount: amount,
        repayments: const [],
        createdAt: nowIso,
        updatedAt: nowIso,
      );
      list.add(item);
      expenses.add(
        Expense(
          id: AppHelpers.genId(),
          refId: item.id,
          refType: 'boss_loan',
          type: 'expense',
          date: resolvedDate,
          desc: 'Boss Loan: ${desc.trim()}',
          category: 'personal',
          amount: amount,
          createdAt: nowIso,
          updatedAt: nowIso,
        ),
      );
    }

    await _vault.setBorrowings(list, sync: false);
    await _vault.setExpenses(expenses);
  }

  Future<bool> deleteBorrowing(String id) async {
    final loan = _vault.borrowings.where((x) => x.id == id).firstOrNull;
    var expenses = List<Expense>.from(_vault.expenses);
    if (loan != null) {
      expenses = await _deleteLinkedExpenseFromList(
        expenses,
        refId: loan.id,
        refType: 'boss_loan',
      );
      for (final repay in loan.repayments) {
        expenses = await _deleteLinkedExpenseFromList(
          expenses,
          refId: repay.id,
          refType: 'boss_repay',
        );
      }
    }
    await _vault.markRecordDeleted('borrowings', id, sync: false);
    await _vault.setBorrowings(
      _vault.borrowings.where((x) => x.id != id).toList(),
      sync: false,
    );
    await _vault.setExpenses(expenses, sync: false);
    return _vault.syncNow();
  }

  Future<void> saveRepayment({
    required String loanId,
    required String date,
    required double amount,
    required String desc,
  }) async {
    final list = List<Borrowing>.from(_vault.borrowings);
    final idx = list.indexWhere((x) => x.id == loanId);
    if (idx < 0) return;

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final resolvedDate =
        date.isEmpty ? DateFormat('yyyy-MM-dd').format(DateTime.now()) : date;
    final repayId = AppHelpers.genId();
    final repayment = Repayment(
      id: repayId,
      date: resolvedDate,
      amount: amount,
      desc: desc.trim(),
    );
    final loan = list[idx];
    list[idx] = loan.copyWith(
      repayments: [...loan.repayments, repayment],
      updatedAt: nowIso,
    );

    final linkedExpense = Expense(
      id: AppHelpers.genId(),
      refId: repayId,
      refType: 'boss_repay',
      type: 'capital',
      date: resolvedDate,
      desc: 'Boss Repayment',
      category: 'capital',
      amount: amount,
      createdAt: nowIso,
      updatedAt: nowIso,
    );

    await _vault.setBorrowings(list, sync: false);
    await _vault.setExpenses([..._vault.expenses, linkedExpense]);
  }

  Future<bool> deleteRepayment(String loanId, String repayId) async {
    final list = List<Borrowing>.from(_vault.borrowings);
    final idx = list.indexWhere((x) => x.id == loanId);
    if (idx < 0) return false;

    final loan = list[idx];
    list[idx] = loan.copyWith(
      repayments: loan.repayments.where((r) => r.id != repayId).toList(),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );

    final expenses = await _deleteLinkedExpenseFromList(
      List<Expense>.from(_vault.expenses),
      refId: repayId,
      refType: 'boss_repay',
    );

    await _vault.setBorrowings(list, sync: false);
    await _vault.setExpenses(expenses, sync: false);
    return _vault.syncNow();
  }

  List<Expense> _updateLinkedExpenseInList(
    List<Expense> list, {
    required String refId,
    required String refType,
    required double amount,
    required String date,
    required String desc,
    required String updatedAt,
  }) {
    final idx = list.indexWhere(
      (e) => e.refId == refId && e.refType == refType,
    );
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        amount: amount,
        date: date,
        desc: refType == 'boss_loan' ? desc : list[idx].desc,
        updatedAt: updatedAt,
      );
    }
    return list;
  }

  Future<List<Expense>> _deleteLinkedExpenseFromList(
    List<Expense> list, {
    required String refId,
    required String refType,
  }) async {
    final matching = list
        .where((e) => e.refId == refId && e.refType == refType)
        .toList();
    for (final exp in matching) {
      await _vault.markRecordDeleted('expenses', exp.id, sync: false);
    }
    return list
        .where((e) => !(e.refId == refId && e.refType == refType))
        .toList();
  }
}
