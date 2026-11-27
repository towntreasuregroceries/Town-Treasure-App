import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/scoped_text_controllers.dart';
import 'expenses_view_model.dart';

/// Capital & Finance Hub matching `page-expenses` in `index.html`, `views.js`, and `payroll.js`.
class ExpensesHubScreen extends StatefulWidget {
  const ExpensesHubScreen({
    super.key,
    this.viewModel,
    this.initialTabIndex = 0,
  });

  final ExpensesViewModel? viewModel;
  final int initialTabIndex;

  @override
  State<ExpensesHubScreen> createState() => _ExpensesHubScreenState();
}

class _ExpensesHubScreenState extends State<ExpensesHubScreen>
    with SingleTickerProviderStateMixin {
  ExpensesViewModel? _ownedVm;
  late TabController _tabController;

  ExpensesViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 6,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 5),
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = ExpensesViewModel(vault: context.read<VaultRepository>());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ownedVm?.dispose();
    super.dispose();
  }

  Future<void> _pickMonth() async {
    final parts = _vm.selectedMonth.split('-');
    final initial = DateTime(
      int.tryParse(parts.firstOrNull ?? '') ?? DateTime.now().year,
      int.tryParse(parts.elementAtOrNull(1) ?? '') ?? DateTime.now().month,
      1,
    );
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: 'Select Payroll / Billing Month',
    );
    if (picked != null) {
      _vm.setSelectedMonth(DateFormat('yyyy-MM').format(picked));
    }
  }

  Future<bool> _confirmDelete(String title, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  void _showAddActionForActiveTab() {
    switch (_tabController.index) {
      case 0:
        _openExpenseModal(defaultType: 'expense');
      case 1:
        _openCapitalInjectionModal();
      case 2:
        _openStaffModal();
      case 3:
        _openRecurringModal();
      case 4:
        _openPersonalExpenseModal();
      case 5:
        _openBorrowingModal();
    }
  }

  String _fabLabelForActiveTab() {
    switch (_tabController.index) {
      case 0:
        return 'Add Expense';
      case 1:
        return 'Add Capital';
      case 2:
        return 'Add Staff';
      case 3:
        return 'Add Recurring';
      case 4:
        return 'Add Company Expense';
      case 5:
        return 'Record Loan';
      default:
        return 'Add Entry';
    }
  }

  Future<void> _openExpenseModal({required String defaultType}) async {
    var type = defaultType;
    var category = defaultType == 'capital' ? 'capital' : 'transport';
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [todayIso, '', ''],
        builder: (ctx, ctrls) {
          final dateCtrl = ctrls[0];
          final descCtrl = ctrls[1];
          final amountCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setModalState) => Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                math.max(
                      MediaQuery.viewInsetsOf(ctx).bottom,
                      math.max(
                        MediaQuery.viewPaddingOf(ctx).bottom,
                        MediaQuery.paddingOf(ctx).bottom,
                      ),
                    ) +
                    24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      type == 'capital'
                          ? 'Record Capital Input'
                          : 'Record Expense',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: type,
                            decoration:
                                const InputDecoration(labelText: 'Type'),
                            items: const [
                              DropdownMenuItem(
                                value: 'expense',
                                child: Text('Expense'),
                              ),
                              DropdownMenuItem(
                                value: 'capital',
                                child: Text('Capital Input'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setModalState(() {
                                type = v;
                                if (v == 'capital') category = 'capital';
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: dateCtrl,
                            readOnly: true,
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              suffixIcon: Icon(Icons.calendar_today, size: 18),
                            ),
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2035),
                              );
                              if (picked != null) {
                                dateCtrl.text =
                                    DateFormat('yyyy-MM-dd').format(picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'e.g. Fuel, Rent, Supplier payment',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: category,
                            decoration:
                                const InputDecoration(labelText: 'Category'),
                            items: ExpensesViewModel.expenseCategories
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(
                                      ExpensesViewModel.getCategoryLabel(c),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setModalState(() => category = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: amountCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Amount (KES)',
                              hintText: '0.00',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: () async {
                        final desc = descCtrl.text.trim();
                        final amount =
                            double.tryParse(amountCtrl.text.trim()) ?? 0;
                        if (desc.isEmpty || amount <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('Please enter a description and amount'),
                            ),
                          );
                          return;
                        }
                        await _vm.addExpenseEntry(
                          type: type,
                          date: dateCtrl.text,
                          desc: desc,
                          category: category,
                          amount: amount,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: const Text('Save Entry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openStaffModal({Staff? existing}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          existing?.name ?? '',
          existing?.role ?? '',
          existing != null && existing.salary > 0
              ? existing.salary.toString()
              : '',
          existing?.phone ?? '',
          existing?.payDay ?? '5',
        ],
        builder: (ctx, ctrls) {
          final nameCtrl = ctrls[0];
          final roleCtrl = ctrls[1];
          final salaryCtrl = ctrls[2];
          final phoneCtrl = ctrls[3];
          final payDayCtrl = ctrls[4];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              math.max(
                    MediaQuery.viewInsetsOf(ctx).bottom,
                    math.max(
                      MediaQuery.viewPaddingOf(ctx).bottom,
                      MediaQuery.paddingOf(ctx).bottom,
                    ),
                  ) +
                  24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing == null ? 'Add Staff' : 'Edit Staff',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Full Name',
                            hintText: 'e.g. James Mwangi',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: roleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Role / Position',
                            hintText: 'e.g. Driver, Loader',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: salaryCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Monthly Salary (KES)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: 'Phone',
                            hintText: '0712345678',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: payDayCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Pay Day (1-31)',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () async {
                      final name = nameCtrl.text.trim();
                      final salary =
                          double.tryParse(salaryCtrl.text.trim()) ?? 0;
                      if (name.isEmpty || salary <= 0) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content:
                                Text('Staff name and salary are required'),
                          ),
                        );
                        return;
                      }
                      await _vm.saveStaff(
                        id: existing?.id,
                        name: name,
                        role: roleCtrl.text,
                        salary: salary,
                        phone: phoneCtrl.text,
                        payDay: payDayCtrl.text.trim().isEmpty
                            ? '5'
                            : payDayCtrl.text.trim(),
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Save Staff'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRecurringModal({RecurringExpense? existing}) async {
    var category = existing?.category ?? 'rent';
    if (!ExpensesViewModel.recurringCategories.contains(category)) {
      category = 'other';
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          existing?.desc ?? '',
          existing != null && existing.amount > 0
              ? existing.amount.toString()
              : '',
          existing?.dueDay ?? '1',
        ],
        builder: (ctx, ctrls) {
          final descCtrl = ctrls[0];
          final amountCtrl = ctrls[1];
          final dueDayCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setModalState) => Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                math.max(
                      MediaQuery.viewInsetsOf(ctx).bottom,
                      math.max(
                        MediaQuery.viewPaddingOf(ctx).bottom,
                        MediaQuery.paddingOf(ctx).bottom,
                      ),
                    ) +
                    24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      existing == null
                          ? 'Add Recurring Expense'
                          : 'Edit Recurring Expense',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'e.g. Shop Rent',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: category,
                            decoration:
                                const InputDecoration(labelText: 'Category'),
                            items: ExpensesViewModel.recurringCategories
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(
                                      ExpensesViewModel.getCategoryLabel(c),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setModalState(() => category = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: amountCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Amount (KES)',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: dueDayCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Due Day (1-31)',
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: () async {
                        final desc = descCtrl.text.trim();
                        final amount =
                            double.tryParse(amountCtrl.text.trim()) ?? 0;
                        if (desc.isEmpty || amount <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('Description and amount are required'),
                            ),
                          );
                          return;
                        }
                        await _vm.saveRecurring(
                          id: existing?.id,
                          desc: desc,
                          category: category,
                          amount: amount,
                          dueDay: dueDayCtrl.text.trim().isEmpty
                              ? '1'
                              : dueDayCtrl.text.trim(),
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: const Text('Save Recurring Expense'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openPersonalExpenseModal() async {
    var category = 'airtime';
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    const personalPickerCats = [
      'airtime',
      'food_personal',
      'personal_transport',
      'family',
      'medical',
      'clothing',
      'entertainment',
      'savings',
      'other_personal',
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: ['', '', todayIso],
        builder: (ctx, ctrls) {
          final descCtrl = ctrls[0];
          final amountCtrl = ctrls[1];
          final dateCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setModalState) => Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                math.max(
                      MediaQuery.viewInsetsOf(ctx).bottom,
                      math.max(
                        MediaQuery.viewPaddingOf(ctx).bottom,
                        MediaQuery.paddingOf(ctx).bottom,
                      ),
                    ) +
                    24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Add Company Expense',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'e.g. Office Airtime, Staff Meals, Errand Fare',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: category,
                            decoration:
                                const InputDecoration(labelText: 'Category'),
                            items: personalPickerCats
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: c,
                                    child: Text(
                                      ExpensesViewModel
                                          .getPersonalCategoryLabel(c),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setModalState(() => category = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: amountCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Amount (KES)',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: dateCtrl,
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: 'Date',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2035),
                        );
                        if (picked != null) {
                          dateCtrl.text =
                              DateFormat('yyyy-MM-dd').format(picked);
                        }
                      },
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: () async {
                        final desc = descCtrl.text.trim();
                        final amount =
                            double.tryParse(amountCtrl.text.trim()) ?? 0;
                        if (desc.isEmpty || amount <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('Description and amount are required'),
                            ),
                          );
                          return;
                        }
                        await _vm.addPersonalExpense(
                          desc: desc,
                          category: category,
                          amount: amount,
                          date: dateCtrl.text,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: const Text('Save Company Expense'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCapitalInjectionModal() async {
    var isBankFacility = false;
    var loanMode = CompanyLoanMode.reducingBalance;
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          todayIso,
          '',
          '',
          'Equity Bank',
          'Working Capital Facility',
          '18',
          '12',
          '',
          '0',
          '5',
        ],
        builder: (ctx, ctrls) {
          final dateCtrl = ctrls[0];
          final descCtrl = ctrls[1];
          final amountCtrl = ctrls[2];
          final lenderCtrl = ctrls[3];
          final facilityCtrl = ctrls[4];
          final rateCtrl = ctrls[5];
          final tenureCtrl = ctrls[6];
          final monthlyOverrideCtrl = ctrls[7];
          final feeCtrl = ctrls[8];
          final debitDayCtrl = ctrls[9];

          return StatefulBuilder(
            builder: (ctx, setModalState) {
              final principal = double.tryParse(amountCtrl.text.trim()) ?? 0;
              final rate = double.tryParse(rateCtrl.text.trim()) ?? 0;
              final tenure = int.tryParse(tenureCtrl.text.trim()) ?? 12;
              final upfrontFee = double.tryParse(feeCtrl.text.trim()) ?? 0;
              final manualInst =
                  double.tryParse(monthlyOverrideCtrl.text.trim()) ?? 0;

              final previewInstallment = loanMode ==
                      CompanyLoanMode.fixedInstallment
                  ? manualInst
                  : CompanyLoan.computeMonthlyInstallment(
                      principal: principal,
                      annualRatePct: rate,
                      tenureMonths: tenure > 0 ? tenure : 1,
                      mode: loanMode,
                    );
              final previewEir = CompanyLoan.solveEffectiveAnnualRatePct(
                principal: principal,
                monthlyInstallment: previewInstallment,
                tenureMonths: tenure > 0 ? tenure : 1,
                upfrontFees: upfrontFee,
              );
              final previewTotalInterest = math.max(
                0.0,
                (previewInstallment * (tenure > 0 ? tenure : 1)) -
                    principal +
                    upfrontFee,
              );

              return Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  18,
                  20,
                  math.max(
                        MediaQuery.viewInsetsOf(ctx).bottom,
                        MediaQuery.viewPaddingOf(ctx).bottom,
                      ) +
                      24,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Record Capital Injection',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<bool>(
                        key: const Key('seg_capital_source_type'),
                        segments: const [
                          ButtonSegment<bool>(
                            value: false,
                            icon: Icon(Icons.savings_outlined, size: 17),
                            label: Text('Owner Equity'),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            icon: Icon(Icons.account_balance_outlined, size: 17),
                            label: Text('Bank / Credit Loan'),
                          ),
                        ],
                        selected: {isBankFacility},
                        onSelectionChanged: (sel) {
                          if (sel.isNotEmpty) {
                            setModalState(() => isBankFacility = sel.first);
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: dateCtrl,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'Date Disbursed',
                                suffixIcon:
                                    Icon(Icons.calendar_today, size: 18),
                              ),
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: ctx,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (picked != null) {
                                  dateCtrl.text = DateFormat('yyyy-MM-dd')
                                      .format(picked);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              key: const Key('input_capital_principal'),
                              controller: amountCtrl,
                              onChanged: (_) => setModalState(() {}),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: InputDecoration(
                                labelText: isBankFacility
                                    ? 'Loan Principal (KES)'
                                    : 'Capital Amount (KES)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (!isBankFacility) ...[
                        TextField(
                          key: const Key('input_capital_equity_desc'),
                          controller: descCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Source / Description',
                            hintText: 'e.g. Director working capital injection',
                          ),
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('input_loan_lender_name'),
                                controller: lenderCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Bank / Lender',
                                  hintText: 'e.g. Equity Bank',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: facilityCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Facility Type',
                                  hintText: 'e.g. SME Working Capital',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<CompanyLoanMode>(
                          key: const Key('dropdown_loan_mode'),
                          initialValue: loanMode,
                          decoration: const InputDecoration(
                            labelText: 'Repayment Structure',
                          ),
                          items: CompanyLoanMode.values
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setModalState(() => loanMode = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('input_loan_tenure_months'),
                                controller: tenureCtrl,
                                onChanged: (_) => setModalState(() {}),
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Tenure (Months)',
                                  hintText: '12',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: loanMode ==
                                      CompanyLoanMode.fixedInstallment
                                  ? TextField(
                                      key: const Key('input_loan_fixed_monthly'),
                                      controller: monthlyOverrideCtrl,
                                      onChanged: (_) => setModalState(() {}),
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      decoration: const InputDecoration(
                                        labelText: 'Monthly Payback (KES)',
                                      ),
                                    )
                                  : TextField(
                                      key: const Key('input_loan_annual_rate'),
                                      controller: rateCtrl,
                                      onChanged: (_) => setModalState(() {}),
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      decoration: const InputDecoration(
                                        labelText: 'Interest Rate (% p.a.)',
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('input_loan_upfront_fee'),
                                controller: feeCtrl,
                                onChanged: (_) => setModalState(() {}),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Upfront Bank/Excise Fee (KES)',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: debitDayCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Monthly Debit Day (1-28)',
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (principal > 0 && previewInstallment > 0) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.sageTint,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.leafGreen),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Monthly Installment: KES ${ExpensesViewModel.formatMoney(previewInstallment)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.forestGreenDeep,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'True Effective Rate (EIR): ${previewEir.toStringAsFixed(2)}% p.a.  •  Total Finance Cost: KES ${ExpensesViewModel.formatMoney(previewTotalInterest)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.slateInk,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'Principal repayments reduce debt & cash without distorting Monthly P&L Net Profit; only interest is expensed.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        key: const Key('btn_save_capital_injection'),
                        onPressed: () async {
                          if (principal <= 0) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('Enter a valid amount > 0'),
                              ),
                            );
                            return;
                          }
                          if (!isBankFacility) {
                            final d = descCtrl.text.trim().isEmpty
                                ? 'Owner Capital Injection'
                                : descCtrl.text.trim();
                            await _vm.addExpenseEntry(
                              type: 'capital',
                              date: dateCtrl.text,
                              desc: d,
                              category: 'capital',
                              amount: principal,
                            );
                          } else {
                            if (loanMode == CompanyLoanMode.fixedInstallment &&
                                manualInst <= 0) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content:
                                      Text('Enter the monthly payback amount'),
                                ),
                              );
                              return;
                            }
                            await _vm.addBankCapitalFacility(
                              lenderName: lenderCtrl.text,
                              facilityName: facilityCtrl.text,
                              disbursementDate: dateCtrl.text,
                              principal: principal,
                              upfrontFees: upfrontFee,
                              mode: loanMode,
                              annualRatePct: rate,
                              tenureMonths: tenure > 0 ? tenure : 12,
                              monthlyInstallmentOverride: manualInst > 0
                                  ? manualInst
                                  : null,
                              debitDayOfMonth:
                                  int.tryParse(debitDayCtrl.text.trim()) ?? 5,
                            );
                          }
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                        child: Text(
                          isBankFacility
                              ? 'Disburse Bank Facility & Build Schedule'
                              : 'Save Capital Injection',
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openCompanyLoanInstallmentModal(CompanyLoan loan) async {
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final defaultAmt = math
        .min(
          loan.monthlyInstallment,
          loan.remainingPrincipal +
              loan.splitPaymentAmount(loan.monthlyInstallment).interest,
        )
        .toStringAsFixed(2);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [todayIso, defaultAmt, ''],
        builder: (ctx, ctrls) {
          final dateCtrl = ctrls[0];
          final amtCtrl = ctrls[1];
          final notesCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setModalState) {
              final amt = double.tryParse(amtCtrl.text.trim()) ?? 0;
              final split = loan.splitPaymentAmount(amt);
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  20,
                  20,
                  math.max(
                        MediaQuery.viewInsetsOf(ctx).bottom,
                        MediaQuery.viewPaddingOf(ctx).bottom,
                      ) +
                      24,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Record Installment — ${loan.lenderName}',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Remaining Principal: KES ${ExpensesViewModel.formatMoney(loan.remainingPrincipal)}',
                        style: const TextStyle(color: AppTheme.slateMuted),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: dateCtrl,
                              readOnly: true,
                              decoration: const InputDecoration(
                                labelText: 'Payment Date',
                                suffixIcon:
                                    Icon(Icons.calendar_today, size: 18),
                              ),
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: ctx,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2035),
                                );
                                if (picked != null) {
                                  dateCtrl.text = DateFormat('yyyy-MM-dd')
                                      .format(picked);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              key: const Key('input_loan_installment_amount'),
                              controller: amtCtrl,
                              onChanged: (_) => setModalState(() {}),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Total Paid (KES)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (amt > 0) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSage,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderSubtle),
                          ),
                          child: Text(
                            'Auto-Split: Principal Reduction KES ${ExpensesViewModel.formatMoney(split.principal)}  +  Finance Interest Expense KES ${ExpensesViewModel.formatMoney(split.interest)}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.slateInk,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: notesCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Bank Ref / Notes (Optional)',
                          hintText: 'e.g. Standing order debit',
                        ),
                      ),
                      const SizedBox(height: 18),
                      FilledButton(
                        key: const Key('btn_confirm_loan_installment'),
                        onPressed: () async {
                          if (amt <= 0) return;
                          await _vm.recordCompanyLoanInstallment(
                            loanId: loan.id,
                            amount: amt,
                            date: dateCtrl.text,
                            notes: notesCtrl.text,
                          );
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                        child: const Text('Save Bifurcated Installment'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openCompanyLoanScheduleSheet(CompanyLoan loan) async {
    final schedule = loan.buildSchedule();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.82,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${loan.lenderName} — Amortization & Payments',
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              Text(
                '${loan.facilityName} • Effective Rate ${loan.effectiveAnnualRatePct.toStringAsFixed(2)}% p.a.',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppTheme.slateMuted,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    if (loan.payments.isNotEmpty) ...[
                      const Text(
                        'Recorded Repayments',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.forestGreenDeep,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final p in loan.payments.reversed)
                        Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            dense: true,
                            title: Text(
                              'KES ${ExpensesViewModel.formatMoney(p.totalAmount)} (${ExpensesViewModel.formatDate(p.date)})',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(
                              'Principal: KES ${ExpensesViewModel.formatMoney(p.principalComponent)} • Interest: KES ${ExpensesViewModel.formatMoney(p.interestComponent)}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.danger,
                                size: 19,
                              ),
                              onPressed: () async {
                                final ok = await _confirmDelete(
                                  'Delete Installment',
                                  'Reverse this installment and its Principal/Interest ledger entries?',
                                );
                                if (ok) {
                                  await _vm.deleteCompanyLoanPayment(
                                    loan.id,
                                    p.id,
                                  );
                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                }
                              },
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                    ],
                    const Text(
                      'Contractual Amortization Schedule',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final row in schedule)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '#${row.periodIndex} • ${ExpensesViewModel.formatDate(row.dueDateIso)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'P: ${ExpensesViewModel.formatMoney(row.principal)} | I: ${ExpensesViewModel.formatMoney(row.interest)} | Bal: ${ExpensesViewModel.formatMoney(row.closingBalance)}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBorrowingModal({Borrowing? existing}) async {
    final initialDate =
        existing?.date ?? DateFormat('yyyy-MM-dd').format(DateTime.now());
    final initialAmt = existing != null && existing.amount > 0
        ? existing.amount.toString()
        : '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [initialDate, initialAmt, existing?.desc ?? ''],
        builder: (ctx, ctrls) {
          final dateCtrl = ctrls[0];
          final amountCtrl = ctrls[1];
          final descCtrl = ctrls[2];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              math.max(
                    MediaQuery.viewInsetsOf(ctx).bottom,
                    math.max(
                      MediaQuery.viewPaddingOf(ctx).bottom,
                      MediaQuery.paddingOf(ctx).bottom,
                    ),
                  ) +
                  24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    existing == null ? 'Record New Loan' : 'Edit Loan',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: dateCtrl,
                          readOnly: true,
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2035),
                            );
                            if (picked != null) {
                              dateCtrl.text =
                                  DateFormat('yyyy-MM-dd').format(picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Amount (KES)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description / Reason',
                      hintText: 'e.g. Cash advance',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () async {
                      final amount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      if (amount <= 0) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Amount is required')),
                        );
                        return;
                      }
                      await _vm.saveBorrowing(
                        id: existing?.id,
                        date: dateCtrl.text,
                        desc: descCtrl.text,
                        amount: amount,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Save Loan'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRepayModal(Borrowing loan) async {
    final todayIso = DateFormat('yyyy-MM-dd').format(DateTime.now());

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [todayIso, '', ''],
        builder: (ctx, ctrls) {
          final dateCtrl = ctrls[0];
          final amountCtrl = ctrls[1];
          final descCtrl = ctrls[2];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              math.max(
                    MediaQuery.viewInsetsOf(ctx).bottom,
                    math.max(
                      MediaQuery.viewPaddingOf(ctx).bottom,
                      MediaQuery.paddingOf(ctx).bottom,
                    ),
                  ) +
                  24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Record Repayment',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Outstanding: KES ${ExpensesViewModel.formatMoney(loan.outstandingBalance)}',
                    style: const TextStyle(color: AppTheme.slateMuted),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: dateCtrl,
                          readOnly: true,
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2035),
                            );
                            if (picked != null) {
                              dateCtrl.text =
                                  DateFormat('yyyy-MM-dd').format(picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Repayment (KES)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'e.g. Paid via M-Pesa',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () async {
                      final amount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      if (amount <= 0) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('Amount is required')),
                        );
                        return;
                      }
                      await _vm.saveRepayment(
                        loanId: loan.id,
                        date: dateCtrl.text,
                        amount: amount,
                        desc: descCtrl.text,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    child: const Text('Save Repayment'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRepaymentsHistory(Borrowing loan) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListenableBuilder(
        listenable: _vm,
        builder: (ctx, _) {
          final currentLoan = _vm.loans
              .where((l) => l.id == loan.id)
              .firstOrNull;
          final repayments = currentLoan?.repayments ?? const <Repayment>[];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 +
                  math.max(
                    MediaQuery.viewPaddingOf(ctx).bottom,
                    MediaQuery.paddingOf(ctx).bottom,
                  ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Repayment History',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                if (repayments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No repayments recorded yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.slateMuted),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: repayments.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final r = repayments[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'KES ${ExpensesViewModel.formatMoney(r.amount)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.forestGreen,
                            ),
                          ),
                          subtitle: Text(
                            '${ExpensesViewModel.formatDate(r.date)}'
                            '${r.desc.isNotEmpty ? ' - ${r.desc}' : ''}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: AppTheme.danger,
                            ),
                            onPressed: () async {
                              final ok = await _confirmDelete(
                                'Delete Repayment',
                                'Delete this repayment and its linked expense?',
                              );
                              if (ok) {
                                await _vm.deleteRepayment(loan.id, r.id);
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final summary = _vm.hubSummary;
        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Capital & Finance Hub'),
            actions: [
              TextButton.icon(
                onPressed: _pickMonth,
                icon: const Icon(
                  Icons.calendar_month_outlined,
                  color: Colors.white,
                  size: 18,
                ),
                label: Text(
                  _vm.selectedMonth,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: AppTheme.leafGreen,
              tabs: const [
                Tab(icon: Icon(Icons.receipt_outlined), text: 'Expenses'),
                Tab(icon: Icon(Icons.savings_outlined), text: 'Capital Input'),
                Tab(icon: Icon(Icons.groups_outlined), text: 'Monthly Salaries'),
                Tab(icon: Icon(Icons.autorenew), text: 'Recurring'),
                Tab(
                  icon: Icon(Icons.business_center_outlined),
                  text: 'Company Expense',
                ),
                Tab(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  text: "Boss's Account",
                ),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _showAddActionForActiveTab,
            backgroundColor: AppTheme.forestGreen,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: Text(_fabLabelForActiveTab()),
          ),
          body: Column(
            children: [
              _HubKpiHeader(summary: summary),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildExpenseListTab(_vm.businessExpenses, isCapital: false),
                    _buildCapitalInputTab(),
                    _buildSalariesTab(),
                    _buildRecurringTab(),
                    _buildPersonalTab(),
                    _buildBorrowingsTab(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCapitalInputTab() {
    final facilities = _vm.companyLoans;
    final capItems = _vm.capitalEntries;
    final dscr = _vm.debtServiceCoverageRatio;

    if (facilities.isEmpty && capItems.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No capital entries yet. Tap "+ Add Capital" to record Owner Equity or a Bank / Credit Facility.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.slateMuted),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        if (facilities.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Bank & Credit Facilities',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.slateInk,
                ),
              ),
              if (dscr != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: dscr >= 1.35
                        ? AppTheme.successSurface
                        : AppTheme.warningSurface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'DSCR ${dscr.toStringAsFixed(2)}x ${dscr >= 1.35 ? 'Healthy' : 'Tight'}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: dscr >= 1.35
                          ? AppTheme.forestGreenDeep
                          : AppTheme.warning,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final loan in facilities) ...[
            Builder(
              builder: (context) {
                final savedInterest = loan.estimatedInterestSavedByPrepayment;
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${loan.lenderName} — ${loan.facilityName}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  Text(
                                    'Disbursed ${ExpensesViewModel.formatDate(loan.disbursementDate)} • Debit Day ${loan.debitDayOfMonth}th • EIR ${loan.effectiveAnnualRatePct.toStringAsFixed(1)}%',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: loan.isFullySettled
                                    ? AppTheme.successSurface
                                    : AppTheme.infoSurface,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                loan.isFullySettled ? 'Settled' : 'Active',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: loan.isFullySettled
                                      ? AppTheme.forestGreen
                                      : AppTheme.info,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: loan.payoffProgress,
                            minHeight: 7,
                            backgroundColor: AppTheme.surfaceSage,
                            color: AppTheme.leafGreen,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              'Principal: KES ${ExpensesViewModel.formatMoney(loan.principal)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Remaining: KES ${ExpensesViewModel.formatMoney(loan.remainingPrincipal)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.danger,
                              ),
                            ),
                            Text(
                              'Monthly: KES ${ExpensesViewModel.formatMoney(loan.monthlyInstallment)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.forestGreenDeep,
                              ),
                            ),
                          ],
                        ),
                        if (savedInterest > 10) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Early Principal Top-Up Savings: KES ${ExpensesViewModel.formatMoney(savedInterest)} interest saved!',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.forestGreen,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (!loan.isFullySettled)
                              FilledButton.icon(
                                key: Key('btn_repay_company_loan_${loan.id}'),
                                onPressed: () =>
                                    _openCompanyLoanInstallmentModal(loan),
                                icon: const Icon(Icons.payments_outlined, size: 17),
                                label: const Text('Record Installment'),
                              ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  _openCompanyLoanScheduleSheet(loan),
                              icon: const Icon(Icons.table_chart_outlined, size: 17),
                              label: const Text('Schedule'),
                            ),
                            IconButton(
                              tooltip: 'Delete Facility',
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.danger,
                              ),
                              onPressed: () async {
                                final ok = await _confirmDelete(
                                  'Delete Bank Facility',
                                  'Delete "${loan.lenderName}" and all linked disbursement/installment ledger entries?',
                                );
                                if (ok) await _vm.deleteCompanyLoan(loan.id);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Capital Input Ledger',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppTheme.slateInk,
            ),
          ),
          const SizedBox(height: 6),
        ],
        for (final e in capItems)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppTheme.successSurface,
                child: Icon(
                  Icons.arrow_downward,
                  color: AppTheme.forestGreen,
                  size: 20,
                ),
              ),
              title: Text(
                e.desc,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.slateInk,
                ),
              ),
              subtitle: Text(
                '${ExpensesViewModel.formatDate(e.date)} | '
                '${ExpensesViewModel.getCategoryLabel(e.category)}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'KES ${ExpensesViewModel.formatMoney(e.amount)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.forestGreen,
                    ),
                  ),
                  if (e.refType != 'company_loan_disbursement')
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: AppTheme.danger,
                        size: 20,
                      ),
                      onPressed: () async {
                        final ok = await _confirmDelete(
                          'Delete Entry',
                          'Are you sure you want to delete "${e.desc}"?',
                        );
                        if (ok) await _vm.deleteExpense(e.id);
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildExpenseListTab(
    List<Expense> items, {
    required bool isCapital,
  }) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          isCapital ? 'No capital entries yet' : 'No expense entries yet',
          style: const TextStyle(color: AppTheme.slateMuted),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final e = items[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  isCapital ? AppTheme.successSurface : AppTheme.warningSurface,
              child: Icon(
                isCapital ? Icons.arrow_downward : Icons.arrow_upward,
                color: isCapital ? AppTheme.forestGreen : AppTheme.warning,
                size: 20,
              ),
            ),
            title: Text(
              e.desc,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.slateInk,
              ),
            ),
            subtitle: Text(
              '${ExpensesViewModel.formatDate(e.date)} | '
              '${ExpensesViewModel.getCategoryLabel(e.category)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'KES ${ExpensesViewModel.formatMoney(e.amount)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: isCapital ? AppTheme.forestGreen : AppTheme.danger,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppTheme.danger,
                    size: 20,
                  ),
                  onPressed: () async {
                    final ok = await _confirmDelete(
                      'Delete Entry',
                      'Are you sure you want to delete "${e.desc}"?',
                    );
                    if (ok) await _vm.deleteExpense(e.id);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSalariesTab() {
    final payroll = _vm.getPayrollSummary();
    final staffList = _vm.activeStaff;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MiniStatChip(
              label: 'Staff',
              value: '${payroll.totalStaff}',
              color: AppTheme.info,
            ),
            _MiniStatChip(
              label: 'Payroll',
              value: 'KES ${ExpensesViewModel.formatMoney(payroll.monthlyPayroll)}',
              color: AppTheme.slateDark,
            ),
            _MiniStatChip(
              label: 'Paid',
              value: '${payroll.paidCount}/${payroll.totalStaff}',
              color: AppTheme.forestGreen,
            ),
            _MiniStatChip(
              label: 'Outstanding',
              value: 'KES ${ExpensesViewModel.formatMoney(payroll.outstanding)}',
              color: payroll.outstanding > 0
                  ? AppTheme.danger
                  : AppTheme.forestGreen,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (staffList.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'No staff members yet. Add your first staff member to start tracking salaries.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.slateMuted),
              ),
            ),
          )
        else
          for (final s in staffList) ...[
            Builder(
              builder: (context) {
                final paid = _vm.isSalaryPaid(s.id);
                final payment = _vm.getSalaryPayment(s.id);
                final overdue = _vm.isSalaryOverdue(s);
                final statusColor = paid
                    ? AppTheme.forestGreen
                    : (overdue ? AppTheme.danger : AppTheme.warning);
                final statusBg = paid
                    ? AppTheme.successSurface
                    : (overdue
                        ? AppTheme.dangerSurface
                        : AppTheme.warningSurface);
                final statusLabel = paid
                    ? 'Paid (${ExpensesViewModel.formatDate(payment?.datePaid)})'
                    : (overdue ? 'Overdue' : 'Due');

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    '${s.role.isEmpty ? 'Staff' : s.role} | Pay day ${s.payDay}th',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: statusBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Text(
                              'KES ${ExpensesViewModel.formatMoney(s.salary)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: AppTheme.slateInk,
                              ),
                            ),
                            const Spacer(),
                            if (paid)
                              OutlinedButton(
                                onPressed: () async {
                                  final ok = await _confirmDelete(
                                    'Undo Salary Payment',
                                    'Undo salary payment for ${s.name}? This will also remove the linked expense.',
                                  );
                                  if (ok) await _vm.undoSalaryPayment(s.id);
                                },
                                child: const Text('Undo'),
                              )
                            else
                              FilledButton(
                                onPressed: () => _vm.markSalaryPaid(s.id),
                                child: Text(overdue ? 'Pay Now' : 'Pay'),
                              ),
                            IconButton(
                              tooltip: 'Edit Staff',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _openStaffModal(existing: s),
                            ),
                            IconButton(
                              tooltip: 'Remove Staff',
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.danger,
                              ),
                              onPressed: () async {
                                final ok = await _confirmDelete(
                                  'Remove Staff',
                                  '${s.name} will be moved to the Recycle Bin.',
                                );
                                if (ok) await _vm.deleteStaff(s.id);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
      ],
    );
  }

  Widget _buildRecurringTab() {
    final items = _vm.recurringExpenses;
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No recurring expenses. Add monthly costs like rent, utilities, or subscriptions.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.slateMuted),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final r = items[index];
        final paid = _vm.isRecurringPaid(r);
        final overdue = _vm.isRecurringOverdue(r);
        final statusColor = paid
            ? AppTheme.forestGreen
            : (overdue ? AppTheme.danger : AppTheme.warning);
        final statusBg = paid
            ? AppTheme.successSurface
            : (overdue ? AppTheme.dangerSurface : AppTheme.warningSurface);
        final statusText =
            paid ? 'Paid' : (overdue ? 'Overdue' : 'Due ${r.dueDay}th');

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.desc,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${ExpensesViewModel.getCategoryLabel(r.category)} | Due ${r.dueDay}th',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            'KES ${ExpensesViewModel.formatMoney(r.amount)}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: statusBg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: statusColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!paid)
                  FilledButton(
                    onPressed: () => _vm.payRecurring(r.id),
                    child: Text(overdue ? 'Pay Now' : 'Pay'),
                  ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _openRecurringModal(existing: r),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
                  onPressed: () async {
                    final ok = await _confirmDelete(
                      'Delete Recurring Expense',
                      'Delete "${r.desc}"?',
                    );
                    if (ok) await _vm.deleteRecurring(r.id);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPersonalTab() {
    final items = _vm.monthlyPersonalExpenses;
    final total = _vm.monthlyPersonalTotal;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Card(
          color: AppTheme.sageTint,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Company Expenses (${_vm.selectedMonth})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
                Text(
                  'KES ${ExpensesViewModel.formatMoney(total)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'No company expenses recorded this month.',
                style: TextStyle(color: AppTheme.slateMuted),
              ),
            ),
          )
        else
          for (final e in items)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  e.desc,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${ExpensesViewModel.formatDate(e.date)} | '
                  '${ExpensesViewModel.getPersonalCategoryLabel(e.category)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'KES ${ExpensesViewModel.formatMoney(e.amount)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.danger,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: AppTheme.danger,
                      ),
                      onPressed: () async {
                        final ok = await _confirmDelete(
                          'Delete Entry',
                          'Delete "${e.desc}"?',
                        );
                        if (ok) await _vm.deleteExpense(e.id);
                      },
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Widget _buildBorrowingsTab() {
    final stats = _vm.borrowingsSummary;
    final loans = _vm.loans;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MiniStatChip(
              label: 'Total Loans',
              value: 'KES ${ExpensesViewModel.formatMoney(stats.totalBorrowed)}',
              color: AppTheme.danger,
            ),
            _MiniStatChip(
              label: 'Total Repaid',
              value: 'KES ${ExpensesViewModel.formatMoney(stats.totalRepaid)}',
              color: AppTheme.forestGreen,
            ),
            _MiniStatChip(
              label: 'Outstanding',
              value:
                  'KES ${ExpensesViewModel.formatMoney(stats.outstandingBalance)}',
              color: stats.outstandingBalance > 0
                  ? AppTheme.warning
                  : AppTheme.info,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (loans.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'No loans recorded yet.',
                style: TextStyle(color: AppTheme.slateMuted),
              ),
            ),
          )
        else
          for (final loan in loans) ...[
            Builder(
              builder: (context) {
                final repaid = loan.totalRepaid;
                final bal = loan.outstandingBalance;
                final statusLabel =
                    bal <= 0 ? 'Paid' : (repaid > 0 ? 'Partial' : 'Unpaid');
                final statusColor = bal <= 0
                    ? AppTheme.forestGreen
                    : (repaid > 0 ? AppTheme.warning : AppTheme.danger);
                final statusBg = bal <= 0
                    ? AppTheme.successSurface
                    : (repaid > 0
                        ? AppTheme.warningSurface
                        : AppTheme.dangerSurface);

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loan.desc.isEmpty ? 'Boss Loan' : loan.desc,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  Text(
                                    ExpensesViewModel.formatDate(loan.date),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: statusBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Borrowed: KES ${ExpensesViewModel.formatMoney(loan.amount)}',
                              style: const TextStyle(
                                color: AppTheme.danger,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              'Repaid: KES ${ExpensesViewModel.formatMoney(repaid)}',
                              style: const TextStyle(
                                color: AppTheme.forestGreen,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                            Text(
                              'Bal: KES ${ExpensesViewModel.formatMoney(bal)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            FilledButton(
                              onPressed: bal <= 0
                                  ? null
                                  : () => _openRepayModal(loan),
                              child: const Text('Repay'),
                            ),
                            OutlinedButton(
                              onPressed: repaid <= 0
                                  ? null
                                  : () => _openRepaymentsHistory(loan),
                              child: const Text('History'),
                            ),
                            IconButton(
                              tooltip: 'Edit Loan',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  _openBorrowingModal(existing: loan),
                            ),
                            IconButton(
                              tooltip: 'Delete Loan',
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.danger,
                              ),
                              onPressed: () async {
                                final ok = await _confirmDelete(
                                  'Delete Loan',
                                  'Delete this loan, all repayments, and linked expenses?',
                                );
                                if (ok) await _vm.deleteBorrowing(loan.id);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
      ],
    );
  }
}

class _HubKpiHeader extends StatelessWidget {
  const _HubKpiHeader({required this.summary});

  final FinanceHubSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surfaceCard,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _KpiCard(
              title: 'Total Capital',
              amount: summary.totalCapital,
              color: AppTheme.forestGreen,
              icon: Icons.savings_outlined,
            ),
            const SizedBox(width: 8),
            _KpiCard(
              title: 'Total Expenses',
              amount: summary.totalExpenses,
              color: AppTheme.danger,
              icon: Icons.trending_down,
            ),
            const SizedBox(width: 8),
            _KpiCard(
              title: 'Paid Revenue',
              amount: summary.paidRevenue,
              color: AppTheme.info,
              icon: Icons.payments_outlined,
            ),
            const SizedBox(width: 8),
            _KpiCard(
              title: 'Net Balance',
              amount: summary.netBalance,
              color: summary.netBalance >= 0
                  ? AppTheme.forestGreen
                  : AppTheme.danger,
              icon: Icons.account_balance_outlined,
            ),
            if (summary.activeBankDebt > 0) ...[
              const SizedBox(width: 8),
              _KpiCard(
                title: 'Active Bank Debt',
                amount: summary.activeBankDebt,
                color: AppTheme.warning,
                icon: Icons.credit_score_outlined,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.title,
    required this.amount,
    required this.color,
    required this.icon,
  });

  final String title;
  final double amount;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 158,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSage,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'KES ${ExpensesViewModel.formatMoney(amount)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStatChip extends StatelessWidget {
  const _MiniStatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.slateMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
