import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_detail_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_editor_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_formatters.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoices_list_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoices_view_model.dart';
import 'package:town_treasure_groceries/ui/features/invoices/recycle_bin_screen.dart';
import 'package:town_treasure_groceries/ui/features/restaurants/restaurants_screen.dart';
import 'package:town_treasure_groceries/ui/features/restaurants/restaurants_view_model.dart';

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

class _DelayedSnapshotSupabaseGateway extends FakeSupabaseGateway {
  final Completer<int?> snapshotCompleter = Completer<int?>();

  @override
  Future<int?> readVaultRevision(String userId) {
    return snapshotCompleter.future;
  }
}

Future<({VaultRepository vault, FakeSupabaseGateway supabase, CryptoService crypto})>
    _createTestVault({bool withSyncCredentials = false}) async {
  final storage = _InMemoryLocalStorage();
  final supabase = FakeSupabaseGateway();
  final crypto = CryptoService();

  if (withSyncCredentials) {
    const user = AuthUserInfo(id: 'owner-1', email: 'owner@ttg.co.ke');
    supabase.user = user;
    await storage.setUserId(user.id);
    final key = await crypto.deriveKey('secret-pass', user.id);
    await storage.setE2eKey(key);
  }

  final vault = VaultRepository(
    cryptoService: crypto,
    localStorage: storage,
    supabase: supabase,
    syncDebounceDuration: const Duration(milliseconds: 20),
  );
  addTearDown(vault.dispose);
  return (vault: vault, supabase: supabase, crypto: crypto);
}

Widget _wrapWithProviders(VaultRepository vault, Widget child) {
  return ChangeNotifierProvider<VaultRepository>.value(
    value: vault,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: child,
    ),
  );
}

void main() {
  group('RestaurantsViewModel & RestaurantsScreen', () {
    test('validates KRA PIN, generic names, and duplicate creation', () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Savannah Bistro',
          kraPin: 'P051234567X',
          aliases: ['Savanna Kitchen'],
        ),
      ]);

      final vm = RestaurantsViewModel(vault: vault);

      // Invalid KRA PIN
      final badPin = vm.prepareSave(
        name: 'Kempinski',
        kraPinRaw: 'INVALID123',
      );
      expect(badPin.hasError, isTrue);
      expect(badPin.error, contains('11-character KRA PIN'));

      // Generic words only
      final generic = vm.prepareSave(name: 'The Hotel Resort');
      expect(generic.hasError, isTrue);
      expect(generic.error, contains('generic words alone'));

      // Exact/alias duplicate on new restaurant is blocked
      final dupNew = vm.prepareSave(name: 'Savanna Kitchen');
      expect(dupNew.hasError, isTrue);
      expect(dupNew.error, contains('already exists'));

      // Valid normalized KRA PIN
      final valid = vm.prepareSave(
        name: 'Artcaffe Westlands',
        kraPinRaw: ' p051 999 888z ',
        aliasesRaw: 'Artcaffe Westie, Artcaffe',
      );
      expect(valid.hasError, isFalse);
      expect(valid.candidate?.kraPin, 'P051999888Z');
      expect(valid.candidate?.aliases, ['Artcaffe Westie', 'Artcaffe']);

      vm.dispose();
    });

    test('detects fuzzy duplicate and merges exact duplicates with invoice reassignment',
        () async {
      final env = await _createTestVault(withSyncCredentials: true);
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Golden Crest Hotel',
          kraPin: '',
          aliases: ['Crest'],
        ),
        const Restaurant(
          id: 'r2',
          name: 'Golden Crest Westlands',
          kraPin: 'P051112223A',
          aliases: ['Crest'],
        ),
        const Restaurant(
          id: 'r3',
          name: 'Goldn Crest',
          aliases: [],
        ),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-1001',
          restaurantId: 'r2',
          restaurantName: 'Golden Crest Westlands',
          date: '2026-11-18',
          totalSell: 5000,
        ),
      ]);
      await vault.setDeletedInvoices([
        const Invoice(
          id: 'inv_del',
          number: 'TTG-1000',
          restaurantId: 'r2',
          restaurantName: 'Golden Crest Westlands',
          date: '2026-11-10',
          totalSell: 2000,
          deletedAt: '2026-11-11T00:00:00Z',
          originalStatus: 'pending',
        ),
      ]);

      final vm = RestaurantsViewModel(vault: vault);

      // Editing r1 keeps r2 as exact merge candidate (shared 'Crest' alias) and r3 as fuzzy candidate
      final check = vm.prepareSave(
        existingId: 'r1',
        name: 'Golden Crest Flagship',
        aliasesRaw: 'Crest',
      );
      expect(check.hasError, isFalse);
      expect(check.needsMergeConfirmation, isTrue);
      expect(check.duplicates.map((d) => d.id), contains('r2'));
      expect(check.needsFuzzyConfirmation, isTrue);
      expect(check.fuzzyCandidates.map((c) => c.id), contains('r3'));

      final res = await vm.commitSave(
        check.candidate!,
        isNew: check.isNew,
        duplicates: check.duplicates,
      );
      expect(res.ok, isTrue);
      expect(res.synced, isTrue);

      // r2 merged & deleted, its KRA PIN inherited, old name preserved as alias
      final updatedR1 = vault.restaurants.firstWhere((r) => r.id == 'r1');
      expect(updatedR1.kraPin, 'P051112223A');
      expect(updatedR1.aliases, contains('Golden Crest Hotel'));
      expect(updatedR1.aliases, contains('Golden Crest Westlands'));
      expect(vault.restaurants.any((r) => r.id == 'r2'), isFalse);
      expect(vault.deletedRestaurantIds, contains('r2'));

      // Active & deleted invoices reassigned to r1
      expect(vault.invoices.first.restaurantId, 'r1');
      expect(vault.invoices.first.restaurantName, 'Golden Crest Flagship');
      expect(vault.deletedInvoices.first.restaurantId, 'r1');

      vm.dispose();
    });

    test('blocks delete when linked invoices exist and deletes clean records',
        () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Linked Hotel'),
        const Restaurant(id: 'r2', name: 'Unused Cafe'),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-1001',
          restaurantId: 'r1',
          restaurantName: 'Linked Hotel',
          date: '2026-11-18',
          totalSell: 1500,
        ),
      ]);

      final vm = RestaurantsViewModel(vault: vault);

      final blocked = await vm.deleteRestaurant('r1');
      expect(blocked.ok, isFalse);
      expect(blocked.message, contains('active or recycled invoice(s)'));
      expect(vault.restaurants.any((r) => r.id == 'r1'), isTrue);

      final deleted = await vm.deleteRestaurant('r2');
      expect(deleted.ok, isTrue);
      expect(vault.restaurants.any((r) => r.id == 'r2'), isFalse);
      expect(vault.deletedRestaurantIds, contains('r2'));

      vm.dispose();
    });

    testWidgets('RestaurantsScreen shows KRA PIN pill, filters search, and triggers onQuickStatement',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Serena Hotel',
          kraPin: 'P051234567X',
          contact: 'Chef Ali',
          phone: '0712345678',
        ),
        const Restaurant(
          id: 'r2',
          name: 'Sarova Stanley',
          kraPin: 'P059876543Y',
        ),
      ]);

      Restaurant? statementTarget;
      await tester.pumpWidget(
        _wrapWithProviders(
          vault,
          RestaurantsScreen(
            onQuickStatement: (r) => statementTarget = r,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Serena Hotel'), findsOneWidget);
      expect(find.text('PIN: P051234567X'), findsOneWidget);
      expect(find.text('Sarova Stanley'), findsOneWidget);

      // Search filtering
      await tester.enterText(find.byType(TextField), 'Serena');
      await tester.pumpAndSettle();
      expect(find.text('Serena Hotel'), findsOneWidget);
      expect(find.text('Sarova Stanley'), findsNothing);

      // Quick statement callback
      await tester.tap(find.text('Statement'));
      await tester.pump();
      expect(statementTarget?.id, 'r1');
    });
  });

  group('InvoicesViewModel, Duplicate Guard, CSV, Drafts & Paid Toggle', () {
    test('generates unique invoice numbers avoiding active and deleted records',
        () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setInvoices([
        const Invoice(
          id: 'i1',
          number: 'TTG-AB12',
          restaurantId: 'r1',
          restaurantName: 'Client',
          date: '2026-11-18',
        ),
      ]);
      await vault.setDeletedInvoices([
        const Invoice(
          id: 'i2',
          number: 'TTG-CD34',
          restaurantId: 'r1',
          restaurantName: 'Client',
          date: '2026-11-17',
        ),
      ]);

      final vm = InvoicesViewModel(vault: vault);
      final generated = vm.generateSecureInvoiceNumber();
      expect(generated, matches(RegExp(r'^TTG-[A-Z0-9]{4}$')));
      expect(generated, isNot('TTG-AB12'));
      expect(generated, isNot('TTG-CD34'));
      vm.dispose();
    });

    test('computes live totals/margins, saves linked expenses, detects duplicates, and toggles paid',
        () async {
      final env = await _createTestVault(withSyncCredentials: true);
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Tribe Hotel',
          kraPin: 'P051234567X',
        ),
      ]);

      final vm = InvoicesViewModel(vault: vault);
      vm.setEditorRestaurantId('r1', triggerAutoSave: false);
      vm.setEditorDate('2026-11-18', triggerAutoSave: false);
      vm.updateLineItem(
        0,
        desc: 'Roma Tomatoes',
        qty: 10,
        unit: 'kgs',
        buyPrice: 80,
        sellPrice: 120,
        triggerAutoSave: false,
      );
      vm.setEditorDeliveryCost(150, triggerAutoSave: false);
      vm.setEditorOtherCost(50, triggerAutoSave: false);

      expect(vm.totalSell, 1200);
      expect(vm.totalBuy, 800);
      expect(vm.opsCost, 200);
      expect(vm.profit, 200);

      // Save first invoice (syncs to FakeSupabaseGateway)
      final firstSave = await vm.saveInvoice();
      expect(firstSave.outcome, SaveInvoiceOutcome.saved);
      expect(firstSave.synced, isTrue);
      final savedInv = firstSave.invoice!;
      expect(savedInv.totalSell, 1200);
      expect(savedInv.profit, 200);
      expect(vault.expenses.length, 2);
      expect(
        vault.expenses.map((e) => e.category).toSet(),
        {'transport', 'other'},
      );

      // Entering identical order on same day triggers duplicate collision guard
      vm.resetEditor();
      vm.setEditorRestaurantId('r1', triggerAutoSave: false);
      vm.setEditorDate('2026-11-18', triggerAutoSave: false);
      vm.updateLineItem(
        0,
        desc: 'Fresh Tomatoes', // alias canonicalizes to 'tomatoes'
        qty: 10,
        unit: 'kgs',
        buyPrice: 80,
        sellPrice: 120,
        triggerAutoSave: false,
      );
      final dupCheck = await vm.saveInvoice();
      expect(dupCheck.outcome, SaveInvoiceOutcome.duplicateDetected);
      expect(dupCheck.matchedDuplicate?.id, savedInv.id);

      // Override duplicate check succeeds
      final overrideSave = await vm.saveInvoice(bypassDuplicateCheck: true);
      expect(overrideSave.outcome, SaveInvoiceOutcome.saved);

      // Paid / Unpaid toggle
      await vm.markAsPaid(savedInv.id);
      expect(vm.findInvoiceById(savedInv.id)?.status, 'paid');
      expect(vm.findInvoiceById(savedInv.id)?.paidDate, isNotNull);

      await vm.markAsUnpaid(savedInv.id);
      expect(vm.findInvoiceById(savedInv.id)?.status, 'pending');
      expect(vm.findInvoiceById(savedInv.id)?.paidDate, isNull);

      vm.dispose();
    });

    test('auto-saves drafts without demoting saved invoices and supports CSV round-trip',
        () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Bistro 99'),
      ]);

      final vm = InvoicesViewModel(
        vault: vault,
        autoSaveDebounce: const Duration(milliseconds: 25),
      );

      vm.setEditorRestaurantId('r1');
      vm.updateLineItem(0, desc: 'Onions', qty: 5, sellPrice: 100);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(vm.drafts.length, 1);
      expect(vm.drafts.first.number, endsWith('-D'));

      // CSV round-trip
      final csv = InvoiceFormatters.itemsToCsv(const [
        InvoiceLineItem(
          desc: 'Capsicum, Red',
          qty: 4,
          unit: 'kgs',
          buyPrice: 0,
          sellPrice: 150,
          total: 600,
        ),
      ]);
      final importedCount = vm.importCsvText(csv);
      expect(importedCount, 1);
      expect(vm.items.first.desc, 'Capsicum, Red');
      expect(vm.items.first.total, 600);

      // Saved non-draft invoice must NEVER be demoted to draft by auto-save
      final savedRes = await vm.saveInvoice(bypassDuplicateCheck: true);
      final saved = savedRes.invoice!;
      vm.loadInvoiceForEdit(saved);
      vm.setEditorNotes('Updated delivery note');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(vm.findInvoiceById(saved.id)?.status, 'pending');

      vm.dispose();
    });

    testWidgets('InvoiceEditorScreen renders prefill items, live margin bar, and scanner callback',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Kempinski'),
      ]);

      await tester.pumpWidget(
        _wrapWithProviders(
          vault,
          InvoiceEditorScreen(
            prefillRestaurantId: 'r1',
            prefillItems: const [
              InvoiceLineItem(
                desc: 'Carrots',
                qty: 10,
                unit: 'kgs',
                buyPrice: 60,
                sellPrice: 100,
                total: 1000,
              ),
            ],
            onOpenScanner: (_) async => const [
              InvoiceLineItem(
                desc: 'Avocados',
                qty: 2,
                unit: 'crates',
                buyPrice: 500,
                sellPrice: 900,
                total: 1800,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Total: KES 1,000.00'), findsOneWidget);
      expect(find.textContaining('Profit: KES 400.00'), findsOneWidget);

      await tester.tap(find.text('Scan Docket'));
      await tester.pumpAndSettle();

      expect(find.text('Total: KES 1,800.00'), findsOneWidget);
      expect(find.textContaining('Profit: KES 800.00'), findsOneWidget);
    });

    testWidgets(
        'InvoiceEditorScreen Save button disables immediately with Saving indicator during slow network check',
        (tester) async {
      final storage = _InMemoryLocalStorage();
      final supabase = _DelayedSnapshotSupabaseGateway();
      final crypto = CryptoService();
      const user = AuthUserInfo(id: 'owner-1', email: 'owner@ttg.co.ke');
      supabase.user = user;
      await storage.setUserId(user.id);
      await storage.setE2eKey(CryptoService.bytesToJwk(List<int>.filled(32, 7)));
      final vault = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        syncDebounceDuration: const Duration(milliseconds: 20),
      );
      addTearDown(vault.dispose);
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Kempinski'),
      ], sync: false);

      await tester.pumpWidget(
        _wrapWithProviders(
          vault,
          const InvoiceEditorScreen(
            prefillRestaurantId: 'r1',
            prefillItems: [
              InvoiceLineItem(
                desc: 'Roma Tomatoes',
                qty: 5,
                unit: 'crates',
                buyPrice: 2000,
                sellPrice: 3000,
                total: 15000,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveBtnFinder = find.byKey(const Key('btn_save_invoice'));
      expect(saveBtnFinder, findsOneWidget);
      expect(find.text('Save Invoice'), findsOneWidget);

      await tester.tap(saveBtnFinder);
      await tester.pump();

      // Immediately locks button and updates label before slow remote call completes.
      expect(find.text('Saving...'), findsOneWidget);
      final btnWidget = tester.widget<FilledButton>(saveBtnFinder);
      expect(btnWidget.onPressed, isNull);

      await tester.runAsync(() async {
        supabase.snapshotCompleter.complete(null);
        for (var i = 0; i < 40 && vault.invoices.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(vault.invoices.length, 1);
    }, timeout: const Timeout(Duration(seconds: 20)));

    testWidgets('InvoiceDetailScreen shows KRA PIN and Paid/Unpaid toggle confirmation',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Fairmont Norfolk',
          kraPin: 'P051234567X',
        ),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-8899',
          restaurantId: 'r1',
          restaurantName: 'Fairmont Norfolk',
          date: '2026-11-18',
          items: [
            InvoiceLineItem(
              desc: 'Tomatoes',
              qty: 5,
              unit: 'kgs',
              buyPrice: 70,
              sellPrice: 120,
              total: 600,
            ),
          ],
          totalSell: 600,
          totalBuy: 350,
          profit: 250,
          status: 'pending',
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithProviders(
          vault,
          const InvoiceDetailScreen(invoiceId: 'inv1'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('KRA PIN: P051234567X'), findsOneWidget);
      expect(find.text('Mark as Paid'), findsOneWidget);

      await tester.tap(find.text('Mark as Paid'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as Unpaid'), findsOneWidget);
      expect(find.text('PAID & PROCESSED'), findsWidgets);

      // Tapping Mark as Unpaid asks confirmation
      await tester.tap(find.text('Mark as Unpaid'));
      await tester.pumpAndSettle();
      expect(find.text('Undo Paid Status'), findsOneWidget);
      await tester.tap(find.text('Yes, Mark Unpaid'));
      await tester.pumpAndSettle();
      expect(find.text('Mark as Paid'), findsOneWidget);
    });

    testWidgets('InvoicesListScreen filters by status and search',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Hemingways'),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'i1',
          number: 'TTG-1111',
          restaurantId: 'r1',
          restaurantName: 'Hemingways',
          date: '2026-11-18',
          totalSell: 1000,
          profit: 200,
          status: 'paid',
        ),
        const Invoice(
          id: 'i2',
          number: 'TTG-2222',
          restaurantId: 'r1',
          restaurantName: 'Hemingways',
          date: '2026-11-17',
          totalSell: 2000,
          profit: 400,
          status: 'pending',
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithProviders(vault, const InvoicesListScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('TTG-1111'), findsOneWidget);
      expect(find.text('TTG-2222'), findsOneWidget);

      await tester.tap(find.text('Paid'));
      await tester.pumpAndSettle();
      expect(find.text('TTG-1111'), findsOneWidget);
      expect(find.text('TTG-2222'), findsNothing);
    });

    test('InvoicesViewModel filters by month and markInvoicesAsPaid updates batch atomically',
        () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Hemingways'),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'i1',
          number: 'TTG-OCT1',
          restaurantId: 'r1',
          restaurantName: 'Hemingways',
          date: '2026-10-12',
          totalSell: 1500,
          status: 'pending',
        ),
        const Invoice(
          id: 'i2',
          number: 'TTG-NOV1',
          restaurantId: 'r1',
          restaurantName: 'Hemingways',
          date: '2026-11-05',
          totalSell: 2000,
          status: 'overdue',
        ),
        const Invoice(
          id: 'i3',
          number: 'TTG-NOV2',
          restaurantId: 'r1',
          restaurantName: 'Hemingways',
          date: '2026-11-18',
          totalSell: 3500,
          status: 'paid',
        ),
      ]);

      final vm = InvoicesViewModel(vault: vault);
      addTearDown(vm.dispose);

      expect(vm.availableMonths, ['2026-11', '2026-10']);

      vm.setFilterMonth('2026-11');
      expect(vm.filteredInvoices.map((e) => e.id).toList(), ['i3', 'i2']);

      vm.setFilterMonth('');
      vm.setSearchQuery('Oct 2026');
      expect(vm.filteredInvoices.map((e) => e.id).toList(), ['i1']);

      vm.setSearchQuery('');
      final res = await vm.markInvoicesAsPaid(['i1', 'i2', 'i3']);
      expect(res.ok, isTrue);
      expect(res.message, contains('2 invoices marked as paid'));
      expect(vm.findInvoiceById('i1')?.status, 'paid');
      expect(vm.findInvoiceById('i1')?.paidDate, isNotNull);
      expect(vm.findInvoiceById('i2')?.status, 'paid');
      expect(vm.findInvoiceById('i3')?.status, 'paid');
    });

    testWidgets('InvoicesListScreen filters by month, selects multiple unpaid, and marks paid in batch',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Kempinski'),
      ]);
      await vault.setInvoices([
        const Invoice(
          id: 'i1',
          number: 'TTG-101',
          restaurantId: 'r1',
          restaurantName: 'Kempinski',
          date: '2026-10-10',
          totalSell: 1200,
          profit: 200,
          status: 'pending',
        ),
        const Invoice(
          id: 'i2',
          number: 'TTG-201',
          restaurantId: 'r1',
          restaurantName: 'Kempinski',
          date: '2026-11-04',
          totalSell: 3000,
          profit: 600,
          status: 'pending',
        ),
        const Invoice(
          id: 'i3',
          number: 'TTG-202',
          restaurantId: 'r1',
          restaurantName: 'Kempinski',
          date: '2026-11-15',
          totalSell: 4500,
          profit: 900,
          status: 'overdue',
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithProviders(vault, const InvoicesListScreen()),
      );
      await tester.pumpAndSettle();

      // Filter by Nov 2026 using month dropdown
      await tester.tap(find.byKey(const Key('dropdown_filter_month')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nov 2026').last);
      await tester.pumpAndSettle();

      expect(find.text('TTG-101'), findsNothing);
      expect(find.text('TTG-201'), findsOneWidget);
      expect(find.text('TTG-202'), findsOneWidget);

      // Enter multi-select mode and select all unpaid for Nov 2026
      await tester.tap(find.byKey(const Key('btn_select_multiple_invoices')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chk_select_all_unpaid')));
      await tester.pumpAndSettle();

      expect(find.text('2 unpaid invoice(s) selected'), findsOneWidget);
      expect(find.text('Total: KES 7,500.00'), findsOneWidget);

      // Verify batch Print button opens PrintOptionsSheet cleanly
      await tester.tap(find.byKey(const Key('btn_batch_print_invoices')));
      await tester.pumpAndSettle();
      expect(find.text('Print & Dispatch Center'), findsOneWidget);
      expect(find.text('2 Selected Invoices'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // Mark selected batch as paid
      await tester.tap(find.byKey(const Key('btn_batch_mark_paid')));
      await tester.pumpAndSettle();
      expect(find.text('Mark Invoices Paid'), findsOneWidget);

      await tester.tap(find.text('Yes, Mark Paid'));
      await tester.pumpAndSettle();

      final nov1 = vault.invoices.firstWhere((e) => e.id == 'i2');
      final nov2 = vault.invoices.firstWhere((e) => e.id == 'i3');
      final oct1 = vault.invoices.firstWhere((e) => e.id == 'i1');
      expect(nov1.status, 'paid');
      expect(nov2.status, 'paid');
      expect(oct1.status, 'pending'); // Untouched because filtered out!
    });
  });

  group('InvoicePdfBuilder', () {
    test('builds valid A4 PDF bytes with KRA PIN and signature plus WhatsApp text',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();

      // 1x1 transparent PNG base64
      const tinyPngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      const invoice = Invoice(
        id: 'inv1',
        number: 'TTG-4567',
        restaurantId: 'r1',
        restaurantName: 'Radisson Blu',
        date: '2026-11-18',
        items: [
          InvoiceLineItem(
            desc: 'Spinach',
            qty: 10,
            unit: 'bundles',
            buyPrice: 30,
            sellPrice: 50,
            total: 500,
          ),
        ],
        totalSell: 500,
        status: 'paid',
      );
      const restaurant = Restaurant(
        id: 'r1',
        name: 'Radisson Blu',
        kraPin: 'P051234567X',
        contact: 'Chef Peter',
        phone: '0712345678',
        address: 'Upper Hill, Nairobi',
      );
      const settings = VaultSettings(
        signature: 'data:image/png;base64,$tinyPngBase64',
      );

      final bytes = await InvoicePdfBuilder.buildPdfBytes(
        invoice: invoice,
        restaurant: restaurant,
        settings: settings,
      );

      expect(bytes.length, greaterThan(500));
      expect(utf8.decode(bytes.take(5).toList()), '%PDF-');

      final waText = InvoicePdfBuilder.buildWhatsAppSummaryText(
        invoice: invoice,
        restaurant: restaurant,
      );
      expect(waText, contains('Hello Chef Peter,'));
      expect(waText, contains('*Invoice No:* TTG-4567'));
      expect(waText, contains('*Date:* 18/11/2026'));
      expect(waText, contains('*Total Amount:* KES 500.00'));

      expect(
        InvoicePdfBuilder.normalizeKenyaPhone('0712 345 678'),
        '254712345678',
      );
    });
  });

  group('Recycle Bin Recovery & RecycleBinScreen', () {
    test('soft deletes and batch restores Invoices (with expenses), Staff, and Price Lists',
        () async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-1010',
          restaurantId: 'r1',
          restaurantName: 'Client A',
          date: '2026-11-18',
          totalSell: 1500,
          deliveryCost: 200,
          otherCost: 50,
          status: 'paid',
        ),
        const Invoice(
          id: 'inv2',
          number: 'TTG-2020',
          restaurantId: 'r1',
          restaurantName: 'Client A',
          date: '2026-11-18',
          totalSell: 900,
          status: 'pending',
        ),
      ]);
      await vault.setExpenses([
        const Expense(
          id: 'e1',
          invId: 'inv1',
          date: '2026-11-18',
          desc: 'Delivery: TTG-1010',
          category: 'transport',
          amount: 200,
        ),
      ]);
      await vault.setDeletedStaff([
        const Staff(
          id: 'st1',
          name: 'Joseph',
          role: 'Driver',
          salary: 20000,
          deletedAt: '2026-11-18T10:00:00Z',
        ),
      ]);
      await vault.setDeletedPriceLists([
        const PriceList(
          id: 'pl1',
          name: 'Nov Wholesale',
          deletedAt: '2026-11-18T10:00:00Z',
        ),
      ]);

      final vm = InvoicesViewModel(vault: vault);

      // Soft delete both invoices
      await vm.softDeleteInvoice('inv1');
      await vm.softDeleteInvoice('inv2');
      expect(vault.invoices, isEmpty);
      expect(vault.deletedInvoices.length, 2);
      expect(vault.expenses, isEmpty);
      expect(
        VaultRepository.isRecordDeleted(vault.recordActions, 'invoices', 'inv1'),
        isTrue,
      );

      // Batch restore both invoices
      final invRestore = await vm.restoreInvoices(['inv1', 'inv2']);
      expect(invRestore.ok, isTrue);
      expect(vault.deletedInvoices, isEmpty);
      expect(vault.invoices.length, 2);
      expect(
        vault.invoices.firstWhere((i) => i.id == 'inv1').status,
        'paid',
      );
      expect(vault.expenses.length, 2); // Delivery + Ops recreated
      expect(
        VaultRepository.isRecordDeleted(vault.recordActions, 'invoices', 'inv1'),
        isFalse,
      );

      // Restore staff & price list
      await vm.restoreStaffMembers(['st1']);
      expect(vault.staff.length, 1);
      expect(vault.deletedStaff, isEmpty);

      await vm.restorePriceLists(['pl1']);
      expect(vault.priceLists.length, 1);
      expect(vault.deletedPriceLists, isEmpty);

      vm.dispose();
    });

    testWidgets('RecycleBinScreen supports tabs and multi-select batch restore',
        (tester) async {
      final env = await _createTestVault();
      final vault = env.vault;
      await vault.setDeletedInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-0001',
          restaurantId: 'r1',
          restaurantName: 'Alpha Hotel',
          date: '2026-11-18',
          totalSell: 1000,
          deletedAt: '2026-11-18T12:00:00Z',
          originalStatus: 'pending',
        ),
        const Invoice(
          id: 'inv2',
          number: 'TTG-0002',
          restaurantId: 'r1',
          restaurantName: 'Beta Cafe',
          date: '2026-11-17',
          totalSell: 2000,
          deletedAt: '2026-11-18T12:00:00Z',
          originalStatus: 'paid',
        ),
      ]);
      await vault.setDeletedStaff([
        const Staff(
          id: 'st1',
          name: 'Mary Wanjiku',
          role: 'Packer',
          salary: 18000,
          deletedAt: '2026-11-18T12:00:00Z',
        ),
      ]);
      await vault.setDeletedPriceLists([
        const PriceList(
          id: 'pl1',
          name: 'Weekly Market List',
          deletedAt: '2026-11-18T12:00:00Z',
        ),
      ]);

      await tester.pumpWidget(
        _wrapWithProviders(vault, const RecycleBinScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('TTG-0001'), findsOneWidget);
      expect(find.textContaining('TTG-0002'), findsOneWidget);

      // Select all & batch restore
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Restore Selected'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes, Restore'));
      await tester.pumpAndSettle();

      expect(vault.invoices.length, 2);
      expect(find.text('No deleted invoices'), findsOneWidget);

      // Switch to Staff tab and restore
      await tester.tap(find.text('Staff (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Mary Wanjiku'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(vault.staff.length, 1);

      // Switch to Price Lists tab and restore
      await tester.tap(find.text('Price Lists (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly Market List'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(vault.priceLists.length, 1);
    });
  });
}
