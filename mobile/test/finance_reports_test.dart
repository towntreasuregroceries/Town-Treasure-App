import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/expenses/expenses_hub_screen.dart';
import 'package:town_treasure_groceries/ui/features/expenses/expenses_view_model.dart';
import 'package:town_treasure_groceries/ui/features/pricelists/pricelist_editor_screen.dart';
import 'package:town_treasure_groceries/ui/features/pricelists/pricelist_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/pricelists/pricelists_screen.dart';
import 'package:town_treasure_groceries/ui/features/pricelists/pricelists_view_model.dart';
import 'package:town_treasure_groceries/ui/features/reports/reports_screen.dart';
import 'package:town_treasure_groceries/ui/features/reports/reports_view_model.dart';
import 'package:town_treasure_groceries/ui/features/reports/statement_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/reports/statements_screen.dart';

import 'test_fakes.dart';

class _InMemoryLocalStorage extends LocalStorageService {
  _InMemoryLocalStorage() : super(secureStore: InMemorySecureKeyStore());

  final Map<String, String> _kv = {};

  @override
  Future<void> init() async {}

  @override
  Future<String?> getRaw(String key) async => _kv[key];

  @override
  Future<void> setRaw(String key, String value) async {
    _kv[key] = value;
  }

  @override
  Future<void> deleteKey(String key) async {
    _kv.remove(key);
  }

  @override
  Future<void> clearVaultData() async {
    for (final key in LocalStorageService.allVaultDataKeys) {
      _kv.remove(key);
    }
  }

  @override
  Future<void> clearAllOnSignOut() async {
    for (final key in [
      ...LocalStorageService.allVaultDataKeys,
      ...LocalStorageService.allStagingKeys,
    ]) {
      _kv.remove(key);
    }
    await clearAuthMetadata();
  }

  @override
  Future<void> close() async {}
}

Future<VaultRepository> _createTestVault() async {
  final storage = _InMemoryLocalStorage();
  final crypto = CryptoService();
  final supabase = FakeSupabaseGateway()
    ..user = const AuthUserInfo(id: 'owner-1', email: 'veronica@ttg.test');
  await storage.setUserId('owner-1');
  final vault = VaultRepository(
    cryptoService: crypto,
    localStorage: storage,
    supabase: supabase,
    syncDebounceDuration: const Duration(milliseconds: 20),
  );
  addTearDown(vault.dispose);
  return vault;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PriceListsViewModel & PDF parity', () {
    test('guessCategory, canonicalProduce, and auditDuplicates match pricelist.js',
        () {
      expect(PriceListsViewModel.guessCategory('Roma Tomatoes'), 'vegetables');
      expect(PriceListsViewModel.guessCategory('Sweet Mango'), 'fruits');
      expect(PriceListsViewModel.guessCategory('Basmati Rice'), 'cereals');
      expect(PriceListsViewModel.guessCategory('Fresh Milk'), 'dairy');
      expect(PriceListsViewModel.guessCategory('Chicken Breast'), 'meat');
      expect(PriceListsViewModel.guessCategory('Tilapia Fillet'), 'fish');
      expect(PriceListsViewModel.guessCategory('Crushed Garlic'), 'spices');
      expect(PriceListsViewModel.guessCategory('Packaging Foil'), 'other');

      final dups = PriceListsViewModel.auditDuplicates(const [
        PriceListItem(id: 'h1', name: 'Vegetables', isHeader: true),
        PriceListItem(id: 'i1', name: 'Roma Tomatoes', price: 120),
        PriceListItem(id: 'i2', name: 'Fresh Tomatoes', price: 130),
        PriceListItem(id: 'i3', name: 'Dhania', price: 40),
      ]);
      expect(dups.length, 1);
      expect(dups.first.normKey, 'tomatoes');
      expect(dups.first.count, 2);
      expect(dups.first.itemIds, containsAll(['i1', 'i2']));
    });

    test('smartImportFromInvoices takes latest invoice prices and skips existing',
        () async {
      final vault = await _createTestVault();
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-1001',
          restaurantId: 'r1',
          restaurantName: 'Alpha',
          date: '2026-11-01',
          status: 'paid',
          items: [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 10,
              unit: 'kgs',
              buyPrice: 70,
              sellPrice: 100,
              total: 1000,
            ),
            InvoiceLineItem(
              desc: 'Carrots',
              qty: 5,
              unit: 'kgs',
              buyPrice: 50,
              sellPrice: 80,
              total: 400,
            ),
          ],
        ),
        const Invoice(
          id: 'inv2',
          number: 'TTG-1002',
          restaurantId: 'r1',
          restaurantName: 'Alpha',
          date: '2026-11-10',
          status: 'pending',
          items: [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 10,
              unit: 'kgs',
              buyPrice: 90,
              sellPrice: 145,
              total: 1450,
            ),
          ],
        ),
        const Invoice(
          id: 'inv3',
          number: 'DRAFT',
          restaurantId: 'r1',
          restaurantName: 'Alpha',
          date: '2026-11-12',
          status: 'draft',
          items: [
            InvoiceLineItem(
              desc: 'Avocados',
              qty: 20,
              unit: 'pieces',
              buyPrice: 20,
              sellPrice: 30,
              total: 600,
            ),
          ],
        ),
      ], sync: false);

      final vm = PriceListsViewModel(vault: vault);
      addTearDown(vm.dispose);

      final result = vm.smartImportFromInvoices(const [
        PriceListItem(id: 'e1', name: 'Carrots', unit: 'kgs', price: 75),
      ]);

      expect(result.skippedCount, 1);
      expect(result.newItems.length, 1);
      expect(result.newItems.first.name, 'Tomatoes');
      expect(result.newItems.first.price, 145);
      expect(result.newItems.first.category, 'vegetables');
    });

    test('publishPriceList detects cross-list collisions, duplicates, soft-deletes, and restores',
        () async {
      final vault = await _createTestVault();
      await vault.setPriceLists([
        const PriceList(
          id: 'pl-existing',
          name: 'November Wholesale',
          status: 'active',
          items: [
            PriceListItem(id: '1', name: 'Tomatoes', price: 120),
            PriceListItem(id: '2', name: 'Potatoes', price: 90),
            PriceListItem(id: '3', name: 'Red Onions', price: 110),
          ],
        ),
      ], sync: false);

      final vm = PriceListsViewModel(vault: vault);
      addTearDown(vm.dispose);

      final created = await vm.createOrResumeTodayDraft();
      final colliding = created.priceList.copyWith(
        name: 'November Wholesale',
        status: 'active',
        items: const [
          PriceListItem(id: 'a1', name: 'Roma Tomatoes', price: 125),
          PriceListItem(id: 'a2', name: 'Shangi Potatoes', price: 95),
          PriceListItem(id: 'a3', name: 'Bombay Onions', price: 115),
        ],
      );

      final blocked = await vm.publishPriceList(colliding);
      expect(blocked.isSaved, isFalse);
      expect(blocked.collision, isNotNull);
      expect(blocked.collision!.confidence, greaterThanOrEqualTo(0.95));

      final bypassed =
          await vm.publishPriceList(colliding, bypassDuplicateCheck: true);
      expect(bypassed.isSaved, isTrue);
      expect(vault.priceLists.length, 2);

      final dupCopy = await vm.duplicatePriceList(bypassed.saved!.id);
      expect(dupCopy, isNotNull);
      expect(dupCopy!.name, 'November Wholesale (Copy)');
      expect(dupCopy.status, 'draft');

      await vm.softDeletePriceList(dupCopy.id);
      expect(vault.priceLists.any((p) => p.id == dupCopy.id), isFalse);
      expect(vault.deletedPriceLists.any((p) => p.id == dupCopy.id), isTrue);
      expect(
        VaultRepository.isRecordDeleted(
          vault.recordActions,
          'priceLists',
          dupCopy.id,
        ),
        isTrue,
      );

      await vm.restorePriceList(dupCopy.id);
      expect(vault.priceLists.any((p) => p.id == dupCopy.id), isTrue);
      expect(vault.deletedPriceLists.any((p) => p.id == dupCopy.id), isFalse);
    });

    test('PriceListPdfBuilder produces valid PDF bytes', () async {
      const pl = PriceList(
        id: 'pl1',
        name: 'Weekly Market Rates',
        subtitle: 'Food Supplies (Veg and Fruits)',
        status: 'active',
        items: [
          PriceListItem(id: 'h1', name: 'Vegetables', isHeader: true),
          PriceListItem(id: 'i1', name: 'Tomatoes', unit: 'kgs', price: 120),
          PriceListItem(id: 'i2', name: 'Spinach', unit: 'bunch', price: 45),
        ],
      );

      final Uint8List pdfBytes = await PriceListPdfBuilder.buildPdfBytes(pl);
      expect(pdfBytes.length, greaterThan(500));
      expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');
    });
  });

  group('ExpensesViewModel parity (Capital, Salaries, Recurring, Borrowings)',
      () {
    test('hubSummary, salary pay/undo, recurring pay, and borrowings linked expenses',
        () async {
      final vault = await _createTestVault();
      await vault.setInvoices([
        const Invoice(
          id: 'inv-paid',
          number: 'TTG-2001',
          restaurantId: 'r1',
          restaurantName: 'Safari Hotel',
          date: '2026-11-10',
          totalSell: 10000,
          totalBuy: 7000,
          profit: 3000,
          status: 'paid',
        ),
      ], sync: false);

      final vm = ExpensesViewModel(
        vault: vault,
        now: DateTime(2026, 11, 18),
      );
      addTearDown(vm.dispose);

      await vm.addExpenseEntry(
        type: 'capital',
        date: '2026-11-01',
        desc: 'Owner Injection',
        category: 'capital',
        amount: 20000,
      );
      await vm.addExpenseEntry(
        type: 'expense',
        date: '2026-11-02',
        desc: 'Fuel',
        category: 'transport',
        amount: 2500,
      );

      expect(vm.hubSummary.totalCapital, 20000);
      expect(vm.hubSummary.totalExpenses, 2500);
      expect(vm.hubSummary.paidRevenue, 10000);
      expect(vm.hubSummary.netBalance, 27500);

      // Payroll pay & undo creates and deletes linked salary expense
      await vm.saveStaff(
        name: 'James Mwangi',
        role: 'Driver',
        salary: 15000,
        phone: '0712345678',
        payDay: '5',
      );
      final staff = vm.activeStaff.first;
      expect(vm.isSalaryOverdue(staff, '2026-11', DateTime(2026, 11, 18)), isTrue);

      await vm.markSalaryPaid(staff.id, now: DateTime(2026, 11, 18));
      expect(vm.isSalaryPaid(staff.id), isTrue);
      expect(
        vault.expenses.any(
          (e) =>
              e.category == 'salaries' &&
              e.desc.contains('James Mwangi') &&
              e.amount == 15000,
        ),
        isTrue,
      );

      await vm.undoSalaryPayment(staff.id);
      expect(vm.isSalaryPaid(staff.id), isFalse);
      expect(
        vault.expenses.any((e) => e.category == 'salaries'),
        isFalse,
      );

      // Recurring bill
      await vm.saveRecurring(
        desc: 'Shop Rent',
        category: 'rent',
        amount: 12000,
        dueDay: '1',
      );
      final rec = vm.recurringExpenses.first;
      expect(vm.isRecurringPaid(rec), isFalse);
      await vm.payRecurring(rec.id, now: DateTime(2026, 11, 18));
      expect(vm.isRecurringPaid(rec), isTrue);

      // Borrowings & linked expenses
      await vm.saveBorrowing(
        date: '2026-11-05',
        desc: 'Emergency Float',
        amount: 8000,
      );
      final loan = vm.loans.first;
      expect(
        vault.expenses.any(
          (e) =>
              e.refId == loan.id &&
              e.refType == 'boss_loan' &&
              e.amount == 8000,
        ),
        isTrue,
      );

      await vm.saveRepayment(
        loanId: loan.id,
        date: '2026-11-12',
        amount: 3000,
        desc: 'M-Pesa partial',
      );
      expect(vm.borrowingsSummary.totalBorrowed, 8000);
      expect(vm.borrowingsSummary.totalRepaid, 3000);
      expect(vm.borrowingsSummary.outstandingBalance, 5000);
      expect(
        vault.expenses.any((e) => e.refType == 'boss_repay' && e.amount == 3000),
        isTrue,
      );

      await vm.deleteBorrowing(loan.id);
      expect(vm.loans, isEmpty);
      expect(
        vault.expenses.any(
          (e) => e.refType == 'boss_loan' || e.refType == 'boss_repay',
        ),
        isFalse,
      );
    });
  });

  group('ReportsViewModel, Insights, P&L, Exports & Statements parity', () {
    test('generateInsights, buildMonthlyPnL, generateReport, PDF & Excel exports',
        () async {
      final vault = await _createTestVault();
      final now = DateTime(2026, 11, 18);
      final thisMonth = DateFormat('yyyy-MM').format(now);
      final lastMonth = DateFormat('yyyy-MM').format(DateTime(2026, 10, 1));

      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Golden Crest Hotel',
          aliases: ['Golden Crest Suites'],
          phone: '0711223344',
        ),
      ], sync: false);

      await vault.setInvoices([
        Invoice(
          id: 'inv-old-unpaid',
          number: 'TTG-0901',
          restaurantId: 'legacy-r1',
          restaurantName: 'Golden Crest Suites',
          date: '2026-09-15',
          items: const [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 10,
              unit: 'kgs',
              buyPrice: 80,
              sellPrice: 120,
              total: 1200,
            ),
          ],
          totalSell: 1200,
          totalBuy: 800,
          profit: 400,
          status: 'pending',
        ),
        Invoice(
          id: 'inv-last',
          number: 'TTG-0950',
          restaurantId: 'r1',
          restaurantName: 'Golden Crest Hotel',
          date: '$lastMonth-10',
          items: const [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 20,
              unit: 'kgs',
              buyPrice: 70,
              sellPrice: 100,
              total: 2000,
            ),
          ],
          totalSell: 2000,
          totalBuy: 1400,
          profit: 600,
          status: 'paid',
        ),
        Invoice(
          id: 'inv-this',
          number: 'TTG-1001',
          restaurantId: 'r1',
          restaurantName: 'Golden Crest Hotel',
          date: '$thisMonth-12',
          items: const [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 30,
              unit: 'kgs',
              buyPrice: 90,
              sellPrice: 150,
              total: 4500,
            ),
          ],
          totalSell: 4500,
          totalBuy: 2700,
          profit: 1800,
          status: 'pending',
        ),
      ], sync: false);

      await vault.setExpenses([
        Expense(
          id: 'e1',
          type: 'expense',
          date: '$lastMonth-05',
          desc: 'Fuel',
          category: 'transport',
          amount: 1000,
        ),
        Expense(
          id: 'e2',
          type: 'expense',
          date: '$thisMonth-06',
          desc: 'Fuel spike',
          category: 'transport',
          amount: 2000,
        ),
        Expense(
          id: 'c1',
          type: 'capital',
          date: '$thisMonth-01',
          desc: 'Topup',
          category: 'capital',
          amount: 5000,
        ),
      ], sync: false);

      await vault.setStaff([
        const Staff(id: 's1', name: 'Peter', salary: 10000, payDay: '5'),
      ], sync: false);

      await vault.setBorrowings([
        const Borrowing(id: 'b1', date: '2026-11-01', desc: 'Float', amount: 4000),
      ], sync: false);

      final vm = ReportsViewModel(vault: vault);
      addTearDown(vm.dispose);

      final insights = vm.generateInsights(clockNow: now);
      expect(insights.urgent.any((m) => m.contains('overdue')), isTrue);
      expect(insights.urgent.any((m) => m.contains('Unpaid salaries: Peter')),
          isTrue);
      expect(
        insights.attention.any((m) => m.contains('Golden Crest Hotel owes')),
        isTrue,
      );
      expect(
        insights.attention.any((m) => m.contains("Boss's Account")),
        isTrue,
      );
      expect(
        insights.attention.any((m) => m.contains('Transport expenses up 100%')),
        isTrue,
      );
      expect(insights.good.any((m) => m.contains('Revenue up')), isTrue);
      expect(
        insights.good.any((m) => m.contains('Top customer: Golden Crest Hotel')),
        isTrue,
      );

      final pnl = vm.buildMonthlyPnL(thisMonth);
      expect(pnl.revenue, 4500);
      expect(pnl.cogs, 2700);
      expect(pnl.grossProfit, 1800);
      expect(pnl.totalExpenses, 2000);
      expect(pnl.netProfit, -200);
      expect(pnl.capitalAdded, 5000);

      // General & Product Reports + PDF/Excel exports
      final generalReport = vm.generateReport(type: 'general', dateType: 'all');
      expect(generalReport.totalSell, 7700);
      expect(generalReport.totalExpenses, 3000);

      final productReport = vm.generateReport(
        type: 'product',
        dateType: 'all',
        productQuery: 'tomatoes',
      );
      expect(productReport.productTransactions.length, 3);
      expect(productReport.totalSell, 7700);

      final reportPdf = await vm.buildReportPdfBytes(generalReport);
      expect(String.fromCharCodes(reportPdf.take(5)), '%PDF-');

      final xlsx = vm.buildReportExcelBytes(productReport);
      expect(xlsx.length, greaterThan(100));
      expect(xlsx.take(2).toList(), [0x50, 0x4B]); // ZIP PK header for .xlsx

      // Monthly Client Statement + PDF
      final rest = vault.restaurants.first;
      final stmt = vm.buildStatement(rest, '2026-11', clockNow: now);
      expect(stmt.openingBalance, 1200); // inv-old-unpaid (legacy alias match!)
      expect(stmt.monthInvoicedTotal, 4500);
      expect(stmt.monthPaidTotal, 0);
      expect(stmt.closingBalance, 5700);
      expect(stmt.ageAnalysis.current, 4500);
      expect(stmt.ageAnalysis.days60, 1200);

      final stmtPdf = await StatementPdfBuilder.buildPdfBytes(stmt);
      expect(String.fromCharCodes(stmtPdf.take(5)), '%PDF-');
    });
  });

  group('Widget tests for PriceLists, ExpensesHub, Reports & Statements', () {
    testWidgets('PriceListsScreen triggers optional onOpenScanner and Editor shows duplicate banner',
        (tester) async {
      final vault = await _createTestVault();
      var scannerCalled = false;

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: PriceListsScreen(
              onOpenScanner: (_) async {
                scannerCalled = true;
                return const [
                  PriceListItem(
                    id: 'scan1',
                    name: 'Tomatoes',
                    category: 'vegetables',
                    unit: 'kgs',
                    price: 110,
                  ),
                ];
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      expect(scannerCalled, isTrue);
      expect(vault.priceLists.length, 1);
    });

    testWidgets('PriceListEditorScreen shows live duplicate commodities banner',
        (tester) async {
      final vault = await _createTestVault();
      await vault.setPriceLists([
        const PriceList(
          id: 'pl-dup',
          name: 'Test List',
          items: [
            PriceListItem(id: '1', name: 'Roma Tomatoes', price: 120),
            PriceListItem(id: '2', name: 'Fresh Tomatoes', price: 130),
          ],
        ),
      ], sync: false);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const PriceListEditorScreen(priceListId: 'pl-dup'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Duplicate Produce Commodities Detected'),
        findsOneWidget,
      );
    });

    testWidgets('ExpensesHubScreen, ReportsScreen, and StatementsScreen render cleanly',
        (tester) async {
      final vault = await _createTestVault();
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Savanna Bistro'),
      ], sync: false);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ExpensesHubScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Capital & Finance Hub'), findsOneWidget);
      expect(find.text('Total Capital'), findsOneWidget);
      expect(find.text("Boss's Account"), findsOneWidget);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ReportsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reports & Insights'), findsOneWidget);
      expect(find.text('Revenue vs Gross Profit (6 Months)'), findsOneWidget);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const StatementsScreen(
              initialRestaurantId: 'r1',
              initialMonth: '2026-11',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Monthly Statements'), findsOneWidget);
      expect(find.text('Savanna Bistro'), findsWidgets);
    });
  });
}
