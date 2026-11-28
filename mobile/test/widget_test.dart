import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:town_treasure_groceries/data/repositories/auth_repository.dart';
import 'package:town_treasure_groceries/data/repositories/staging_repository.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/duplicate_detector_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/ocr_consensus_service.dart';
import 'package:town_treasure_groceries/data/services/remote_update_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/main.dart';
import 'package:town_treasure_groceries/ui/core/app_lock_guard.dart';
import 'package:town_treasure_groceries/ui/core/app_shell.dart';
import 'package:town_treasure_groceries/ui/core/user_friendly_error.dart';
import 'package:town_treasure_groceries/ui/features/auth/auth_screen.dart';
import 'package:town_treasure_groceries/ui/features/clerk/clerk_submissions_screen.dart';
import 'package:town_treasure_groceries/ui/features/clerk/clerk_view_model.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/dashboard_screen.dart';
import 'package:town_treasure_groceries/ui/features/expenses/expenses_hub_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_editor_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoices_list_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/recycle_bin_screen.dart';
import 'package:town_treasure_groceries/ui/features/pricelists/pricelists_screen.dart';
import 'package:town_treasure_groceries/ui/features/reports/reports_screen.dart';
import 'package:town_treasure_groceries/ui/features/reports/statements_screen.dart';
import 'package:town_treasure_groceries/ui/features/restaurants/restaurants_screen.dart';
import 'package:town_treasure_groceries/ui/features/scanner/docket_scanner_sheet.dart';

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

class _FakeBiometricGateway implements BiometricGateway {
  bool authResult = true;
  int authenticateCalls = 0;

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    authenticateCalls++;
    return authResult;
  }

  @override
  Future<bool> canCheckBiometrics() async => true;

  @override
  Future<bool> isDeviceSupported() async => true;
}

class _FakeTextRecognizer implements OcrTextRecognizerGateway {
  @override
  Future<String> recognizeTextFromFile(String filePath) async => '';

  @override
  Future<void> close() async {}
}

class _FakeImagePicker implements ImagePickerGateway {
  @override
  Future<XFile?> pickCameraImage({int imageQuality = 85}) async => null;

  @override
  Future<List<XFile>> pickGalleryImages({int imageQuality = 85}) async =>
      const [];
}

class _IntegrationHarness {
  _IntegrationHarness({
    AuthUserInfo? initialUser,
    bool biometricEnabled = false,
  })  : storage = _InMemoryLocalStorage(),
        crypto = CryptoService(),
        supabase = FakeSupabaseGateway()..user = initialUser,
        biometrics = _FakeBiometricGateway(),
        ocr = OcrConsensusService(
          textRecognizer: _FakeTextRecognizer(),
          imagePicker: _FakeImagePicker(),
        ),
        duplicateDetector = DuplicateDetectorService(),
        updateService = RemoteUpdateService(
          versionProvider: () async => (version: '1.0.0', buildNumber: 1),
        ),
        initialBiometricEnabled = biometricEnabled {
    vault = VaultRepository(
      cryptoService: crypto,
      localStorage: storage,
      supabase: supabase,
    );
    auth = AuthRepository(
      supabase: supabase,
      localStorage: storage,
      cryptoService: crypto,
      vaultRepository: vault,
      biometrics: biometrics,
    );
    staging = StagingRepository(
      supabase: supabase,
      localStorage: storage,
      vaultRepository: vault,
    );
  }

  final _InMemoryLocalStorage storage;
  final CryptoService crypto;
  final FakeSupabaseGateway supabase;
  final _FakeBiometricGateway biometrics;
  final OcrConsensusService ocr;
  final DuplicateDetectorService duplicateDetector;
  final RemoteUpdateService updateService;
  final bool initialBiometricEnabled;

  late final VaultRepository vault;
  late final AuthRepository auth;
  late final StagingRepository staging;

  Future<void> seedApp({
    bool withRestaurant = true,
    bool withPendingDocket = true,
  }) async {
    await storage.init();
    if (initialBiometricEnabled) {
      await storage.setBiometricEnabled(true);
    }
    if (withRestaurant) {
      await vault.setRestaurants(
        const [
          Restaurant(
            id: 'rest-1',
            name: 'Serena Hotel',
            kraPin: 'P051234567A',
            contact: 'Chef Kamau',
            phone: '0712345678',
          ),
        ],
        sync: false,
      );
    }
    if (withPendingDocket) {
      supabase.stagedInvoices.add({
        'id': 'stg-1',
        'owner_user_id': 'user-1',
        'target_user_id': 'user-1',
        'target_user_email': 'owner@towntreasure.test',
        'clerk_name': 'Grace',
        'restaurant_name': 'Serena Hotel',
        'invoice_date': '2026-11-18',
        'items_json': [
          {
            'desc': 'Tomatoes',
            'qty': 5,
            'unit': 'crates',
            'buyPrice': 0,
            'sellPrice': 3200,
            'total': 16000,
          },
        ],
        'total_sell': 16000,
        'status': 'pending',
      });
    }
  }

  Widget buildApp({int initialTabIndex = 0}) {
    return TownTreasureApp(
      cryptoService: crypto,
      localStorageService: storage,
      supabaseService: supabase,
      vaultRepository: vault,
      authRepository: auth,
      stagingRepository: staging,
      remoteUpdateService: updateService,
      ocrService: ocr,
      duplicateDetectorService: duplicateDetector,
      initialTabIndex: initialTabIndex,
    );
  }
}

Future<void> _scrollMoreAndTap(
  WidgetTester tester,
  Finder finder, {
  double delta = 150,
}) async {
  final moreScrollable = find.descendant(
    of: find.byKey(const Key('more_hub_list')),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: moreScrollable,
  );
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'AuthGate routes unauthenticated users to AuthScreen, ClerkPortal, sign-in -> AppShell, and sign-out -> AuthScreen',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness();
      await harness.seedApp();

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      // Starts on AuthScreen sign-in view without Field Clerk Mode card.
      expect(find.byKey(const Key('btn_sign_in')), findsOneWidget);
      expect(find.byKey(const Key('btn_open_clerk_portal')), findsNothing);
      expect(find.text('Field Clerk Mode'), findsNothing);

      // Sign in transitions AuthGate to AppShell.
      await tester.enterText(
        find.byKey(const Key('input_login_email')),
        'owner@towntreasure.test',
      );
      await tester.enterText(
        find.byKey(const Key('input_login_password')),
        'secret123',
      );
      await tester.tap(find.byKey(const Key('btn_sign_in')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('app_navigation_bar')), findsOneWidget);
      expect(find.byType(DashboardScreen), findsOneWidget);

      // Switch to More tab and Sign Out back to AuthScreen.
      await tester.tap(find.byKey(const Key('nav_more')));
      await tester.pumpAndSettle();
      expect(find.text('More & Tools'), findsOneWidget);

      await _scrollMoreAndTap(tester, find.byKey(const Key('more_sign_out')));

      await tester.tap(find.widgetWithText(FilledButton, 'Sign Out'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_sign_in')), findsOneWidget);
    },
  );

  testWidgets(
    'AuthGate shows biometric quick-unlock when session exists with screen lock enabled and unlocks into AppShell',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-1',
          email: 'owner@towntreasure.test',
        ),
        biometricEnabled: true,
      );
      await harness.seedApp();

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_quick_unlock')), findsOneWidget);
      expect(find.byKey(const Key('app_navigation_bar')), findsNothing);

      await tester.tap(find.byKey(const Key('btn_quick_unlock')));
      await tester.pumpAndSettle();

      expect(harness.biometrics.authenticateCalls, 1);
      expect(find.byKey(const Key('app_navigation_bar')), findsOneWidget);
      expect(find.byType(DashboardScreen), findsOneWidget);
    },
  );

  testWidgets(
    'AppShell NavigationBar switches tabs, shows live pending badge, opens New/Scan sheet, and PopScope returns to Dashboard',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-1',
          email: 'owner@towntreasure.test',
        ),
      );
      await harness.seedApp(withPendingDocket: true);

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      // Live pendingCount badge from StagingRepository is rendered on Clerks destination.
      expect(harness.staging.pendingCount, 1);
      expect(
        find.descendant(
          of: find.byKey(const Key('nav_clerks')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // Navigate to Invoices tab.
      await tester.tap(find.byKey(const Key('nav_invoices')));
      await tester.pumpAndSettle();
      expect(find.byType(InvoicesListScreen), findsOneWidget);

      // Navigate to Clerks tab.
      await tester.tap(find.byKey(const Key('nav_clerks')));
      await tester.pumpAndSettle();
      expect(find.byType(ClerkSubmissionsScreen), findsOneWidget);
      expect(find.text('Serena Hotel'), findsAtLeastNWidgets(1));

      // PopScope back from Clerks tab returns to Dashboard instead of popping app.
      final NavigatorState navState = tester.state(find.byType(Navigator));
      await navState.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);

      // Tapping New / Scan opens the quick create & scan action sheet.
      await tester.tap(find.byKey(const Key('nav_new_scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new_scan_action_sheet')), findsOneWidget);
      expect(find.byKey(const Key('action_new_invoice')), findsOneWidget);
      expect(find.byKey(const Key('action_scan_docket')), findsOneWidget);
      expect(find.byKey(const Key('action_scan_pricelist')), findsOneWidget);

      // Action sheet -> New Invoice opens InvoiceEditorScreen with DocketScannerSheet callback wired.
      await tester.tap(find.byKey(const Key('action_new_invoice')));
      await tester.pumpAndSettle();
      expect(find.byType(InvoiceEditorScreen), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Scan Docket'));
      await tester.pumpAndSettle();
      expect(find.byType(DocketScannerSheet), findsOneWidget);
    },
  );

  testWidgets(
    'AppShell More hub exposes all tools and wires Restaurants -> Statements and PriceLists -> OCR Scanner',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-1',
          email: 'owner@towntreasure.test',
        ),
      );
      await harness.seedApp();

      await tester.pumpWidget(harness.buildApp(initialTabIndex: 3));
      await tester.pumpAndSettle();

      // Verify all More hub items are accessible.
      expect(find.byKey(const Key('more_restaurants')), findsOneWidget);
      expect(find.byKey(const Key('more_pricelists')), findsOneWidget);
      expect(find.byKey(const Key('more_recycle_bin')), findsOneWidget);
      expect(find.byKey(const Key('more_capital_finance')), findsOneWidget);
      expect(find.byKey(const Key('more_reports_insights')), findsOneWidget);
      expect(find.byKey(const Key('more_monthly_statements')), findsOneWidget);

      final moreScrollable = find.descendant(
        of: find.byKey(const Key('more_hub_list')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('more_sign_out')),
        150,
        scrollable: moreScrollable,
      );
      expect(find.byKey(const Key('more_signature')), findsOneWidget);
      expect(find.byKey(const Key('more_excel_export')), findsOneWidget);
      expect(find.byKey(const Key('more_check_updates')), findsOneWidget);
      expect(find.byKey(const Key('more_sign_out')), findsOneWidget);

      // Scroll back up and test Restaurants -> Statements pre-selected client wiring.
      await _scrollMoreAndTap(
        tester,
        find.byKey(const Key('more_restaurants')),
        delta: -150,
      );
      expect(find.byType(RestaurantsScreen), findsOneWidget);

      await tester.tap(find.text('Statement'));
      await tester.pumpAndSettle();
      expect(find.byType(StatementsScreen), findsOneWidget);
      final stmtWidget = tester.widget<StatementsScreen>(
        find.byType(StatementsScreen),
      );
      expect(stmtWidget.initialRestaurantId, 'rest-1');

      // Pop back to More hub and test PriceLists -> OCR scanner wiring.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollMoreAndTap(tester, find.byKey(const Key('more_pricelists')));
      expect(find.byType(PriceListsScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Scan Price List'));
      await tester.pumpAndSettle();
      expect(find.byType(DocketScannerSheet), findsOneWidget);
      final scannerWidget = tester.widget<DocketScannerSheet>(
        find.byType(DocketScannerSheet),
      );
      expect(scannerWidget.mode, ScannerTargetMode.priceList);
    },
  );

  testWidgets(
    'AppShell More hub routes cleanly to Capital & Finance, Reports & Insights, and Recycle Bin',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-1',
          email: 'owner@towntreasure.test',
        ),
      );
      await harness.seedApp();

      await tester.pumpWidget(harness.buildApp(initialTabIndex: 3));
      await tester.pumpAndSettle();

      await _scrollMoreAndTap(
        tester,
        find.byKey(const Key('more_capital_finance')),
      );
      expect(find.byType(ExpensesHubScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollMoreAndTap(
        tester,
        find.byKey(const Key('more_reports_insights')),
      );
      expect(find.byType(ReportsScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await _scrollMoreAndTap(
        tester,
        find.byKey(const Key('more_recycle_bin')),
        delta: -150,
      );
      expect(find.byType(RecycleBinScreen), findsOneWidget);
    },
  );

  testWidgets(
    'Dashboard pending clerk banner switches to Clerks tab and New Invoice FAB opens InvoiceEditorScreen',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-1',
          email: 'owner@towntreasure.test',
        ),
      );
      await harness.seedApp(withPendingDocket: true);

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      // Pending clerk banner on Dashboard opens Clerks tab.
      expect(find.byType(DashboardScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_open_clerk_inbox')));
      await tester.pumpAndSettle();
      expect(find.byType(ClerkSubmissionsScreen), findsOneWidget);

      // Return to Dashboard and tap New Invoice FAB -> opens InvoiceEditorScreen.
      await tester.tap(find.byKey(const Key('nav_dashboard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fab_create_invoice')));
      await tester.pumpAndSettle();
      expect(find.byType(InvoiceEditorScreen), findsOneWidget);
    },
  );

  testWidgets(
    'AuthGate immediately locks on background/exit when screen lock is enabled',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-lock',
          email: 'owner@towntreasure.test',
        ),
        biometricEnabled: true,
      );
      await harness.seedApp();

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btn_quick_unlock')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_quick_unlock')));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);

      // Intentional external share/camera flow stays unlocked while suppressed.
      await AppLockGuard.runWithoutRelock(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);

      // Genuine background / Back exit locks while paused, and resuming
      // returns directly to the Welcome Back screen-lock gate before Dashboard.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byKey(const Key('btn_quick_unlock')), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);

      // Tapping Unlock with Fingerprint / Screen Lock re-enters the app.
      await tester.tap(find.byKey(const Key('btn_quick_unlock')));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);
    },
  );

  test('Live endpoint defaults and plain-language error formatting', () {
    expect(
      ClerkViewModel.defaultClerkWebBaseUrl,
      'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk.html',
    );
    expect(
      AppShell.defaultUpdateManifestUrl,
      'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json',
    );
    expect(
      UserFriendlyError.format(
        Exception('Manifest request failed with status 444.'),
      ),
      contains('update file could not be found'),
    );
    expect(
      UserFriendlyError.format(
        Exception(
          'PlatformException(error, Attempt to invoke virtual method \'java.lang.Class java.lang.Object.getClass()\' on a null object reference)',
        ),
      ),
      contains('well-lit photo'),
    );
  });

  testWidgets(
    'AuthGate shields open sheets/forms behind lock curtain on background lock, resumes seamlessly on unlock, and clears all overlays on sign-out',
    (WidgetTester tester) async {
      final harness = _IntegrationHarness(
        initialUser: const AuthUserInfo(
          id: 'user-overlay-lock',
          email: 'owner@towntreasure.test',
        ),
        biometricEnabled: true,
      );
      await harness.seedApp();
      await harness.storage.setUserId('user-overlay-lock');
      await harness.storage.setE2eKey(
        CryptoService.bytesToJwk(List<int>.filled(32, 7)),
      );

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_quick_unlock')));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardScreen), findsOneWidget);

      // Open InvoiceEditorScreen and begin filling an invoice, then background-lock
      // (simulating answering a phone call mid-invoice).
      await tester.tap(find.byKey(const Key('fab_create_invoice')));
      await tester.pumpAndSettle();
      expect(find.byType(InvoiceEditorScreen), findsOneWidget);

      // Camera/ML Kit return handoff via AppLockGuard must NOT trigger lockout
      // even if a trailing paused event arrives right after runWithoutRelock ends.
      await AppLockGuard.runWithoutRelock(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(InvoiceEditorScreen), findsOneWidget);
      expect(find.byKey(const Key('btn_quick_unlock')), findsNothing);

      // Genuine background (e.g. answering a phone call mid-invoice) locks behind
      // the root Lock Curtain without destroying InvoiceEditorScreen state.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // While locked: Lock Curtain hides InvoiceEditorScreen completely.
      expect(find.byKey(const Key('btn_quick_unlock')), findsOneWidget);
      expect(find.byType(InvoiceEditorScreen), findsNothing);

      // Unlocking lifts the curtain and resumes directly inside InvoiceEditorScreen!
      await tester.tap(find.byKey(const Key('btn_quick_unlock')));
      await tester.pumpAndSettle();
      expect(find.byType(InvoiceEditorScreen), findsOneWidget);

      // Signing out while a sub-route / dialog is open still clears everything.
      final editorCtx = tester.element(find.byType(InvoiceEditorScreen));
      showDialog<void>(
        context: editorCtx,
        builder: (ctx) => const AlertDialog(
          title: Text('Confirm Sign Out Test'),
          content: Text('Should vanish immediately on sign-out.'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Confirm Sign Out Test'), findsOneWidget);

      final signedOut = await tester.runAsync(() => harness.auth.signOut());
      expect(signedOut, isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_sign_in')), findsOneWidget);
      expect(find.text('Confirm Sign Out Test'), findsNothing);
      expect(find.byType(InvoiceEditorScreen), findsNothing);
    },
  );
}
