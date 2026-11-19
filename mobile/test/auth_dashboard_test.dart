import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/auth_repository.dart';
import 'package:town_treasure_groceries/data/repositories/staging_repository.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/remote_update_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/auth/auth_screen.dart';
import 'package:town_treasure_groceries/ui/features/auth/auth_view_model.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/change_password_dialog.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/dashboard_screen.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/dashboard_view_model.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/excel_exporter.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/notification_center_sheet.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/overdue_notification_service.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/signature_scanner_sheet.dart';
import 'package:town_treasure_groceries/ui/features/dashboard/update_checker_sheet.dart';

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

class FakeBiometricGateway implements BiometricGateway {
  FakeBiometricGateway({
    this.supported = true,
    this.canCheck = true,
    this.authResult = true,
  });

  bool supported;
  bool canCheck;
  bool authResult;
  int authenticateCalls = 0;

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    authenticateCalls++;
    return authResult;
  }

  @override
  Future<bool> canCheckBiometrics() async => canCheck;

  @override
  Future<bool> isDeviceSupported() async => supported;
}

class FakeOverdueNotificationGateway
    implements OverdueNotificationGateway, SmartNotificationGateway {
  bool permissionGranted = true;
  int initCalls = 0;
  int showCalls = 0;
  int cancelCalls = 0;
  int? lastOverdueCount;
  int? lastPendingCount;
  final List<({NotificationCategory category, String title, String body})>
      categoryCalls = [];

  @override
  Future<bool> initializeAndRequestPermission() async {
    initCalls++;
    return permissionGranted;
  }

  @override
  Future<void> showOverdueSummary({
    required int overdueCount,
    required int pendingCount,
  }) async {
    showCalls++;
    lastOverdueCount = overdueCount;
    lastPendingCount = pendingCount;
  }

  @override
  Future<void> showCategoryNotification({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    categoryCalls.add((category: category, title: title, body: body));
  }

  @override
  Future<void> cancelAll() async {
    cancelCalls++;
  }
}

class FakeRemoteUpdateService extends RemoteUpdateService {
  FakeRemoteUpdateService({
    required this.result,
    this.throwError,
  });

  final UpdateCheckResult result;
  final Object? throwError;
  int checkCalls = 0;
  int installCalls = 0;
  String? lastManifestUrl;
  AppUpdateManifest? lastInstalledManifest;

  @override
  Future<UpdateCheckResult> checkForUpdate(String manifestUrl) async {
    checkCalls++;
    lastManifestUrl = manifestUrl;
    if (throwError != null) {
      throw throwError!;
    }
    return result;
  }

  @override
  Future<bool> downloadVerifyAndInstall(
    AppUpdateManifest manifest, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    installCalls++;
    lastInstalledManifest = manifest;
    onProgress?.call(50, 100);
    onProgress?.call(100, 100);
    return true;
  }
}

class TrackingFakeSupabaseGateway extends FakeSupabaseGateway {
  int verifyOtpCalls = 0;
  int updatePasswordCalls = 0;
  String? lastVerifiedOtp;
  String? lastUpdatedPassword;

  @override
  Future<AuthUserInfo> verifySignupOtp(String email, String token) async {
    verifyOtpCalls++;
    lastVerifiedOtp = token;
    return super.verifySignupOtp(email, token);
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    updatePasswordCalls++;
    lastUpdatedPassword = newPassword;
  }
}

Future<({
  LocalStorageService storage,
  TrackingFakeSupabaseGateway supabase,
  FakeBiometricGateway biometrics,
  VaultRepository vault,
  AuthRepository auth,
  StagingRepository staging,
})> _createFixture({bool fastCryptoForWidgetTest = true}) async {
  final storage = _InMemoryLocalStorage();
  final supabase = TrackingFakeSupabaseGateway();
  final crypto = fastCryptoForWidgetTest
      ? CryptoService(
          pbkdf2: Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: 50,
            bits: 256,
          ),
        )
      : CryptoService();
  final biometrics = FakeBiometricGateway();
  final vault = VaultRepository(
    cryptoService: crypto,
    localStorage: storage,
    supabase: supabase,
    syncDebounceDuration: const Duration(milliseconds: 20),
  );
  final auth = AuthRepository(
    supabase: supabase,
    localStorage: storage,
    cryptoService: crypto,
    vaultRepository: vault,
    biometrics: biometrics,
  );
  final staging = StagingRepository(
    supabase: supabase,
    localStorage: storage,
    vaultRepository: vault,
  );
  return (
    storage: storage,
    supabase: supabase,
    biometrics: biometrics,
    vault: vault,
    auth: auth,
    staging: staging,
  );
}

Uint8List _createSampleSignatureImageBytes() {
  final canvas = img.Image(width: 120, height: 80, numChannels: 3);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  // Draw a dark ink stroke near the center (x: 40..79, y: 30..45)
  for (var y = 30; y <= 45; y++) {
    for (var x = 40; x <= 79; x++) {
      canvas.setPixelRgb(x, y, 20, 20, 25);
    }
  }
  return Uint8List.fromList(img.encodePng(canvas));
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

void main() {
  group('AuthViewModel and AuthScreen', () {
    test('signIn authenticates invite user and derives E2EE key', () async {
      final f = await _createFixture(fastCryptoForWidgetTest: false);
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      final vm = AuthViewModel(authRepository: f.auth);
      final initialUser = await vm.initialize();
      expect(initialUser, isNull);
      expect(vm.mode, AuthMode.signIn);

      expect(f.auth.signUp, throwsUnsupportedError);

      final user = await vm.signIn(
        email: 'veronicah@ttg.test',
        password: 'secret-password',
      );
      expect(user, isNotNull);
      expect(user!.email, 'veronicah@ttg.test');
      expect(vm.mode, AuthMode.authenticated);
      expect(await f.storage.getE2eKey(), isNotNull);
      vm.dispose();
    });

    testWidgets('AuthScreen sign-in and optional Clerk Portal button work',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      AuthUserInfo? authenticated;

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthRepository>.value(
          value: f.auth,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: AuthScreen(
              onAuthenticated: (user) => authenticated = user,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('btn_open_clerk_portal')), findsNothing);
      expect(find.text('Field Clerk Mode'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('input_login_email')),
        'owner@ttg.test',
      );
      await tester.enterText(
        find.byKey(const Key('input_login_password')),
        'vault-pass-123',
      );
      await _tapKey(tester, const Key('btn_sign_in'));
      await tester.pumpAndSettle();

      expect(authenticated, isNotNull);
      expect(authenticated!.email, 'owner@ttg.test');
    });

    testWidgets(
        'Onboarding wizard verifies invite OTP and enables screen lock',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      AuthUserInfo? authenticated;

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthRepository>.value(
          value: f.auth,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: AuthScreen(
              onAuthenticated: (user) => authenticated = user,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _tapKey(tester, const Key('btn_start_wizard'));
      await tester.pumpAndSettle();
      await _tapKey(tester, const Key('btn_wiz_get_started'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_wiz_email')),
        'invited@ttg.test',
      );
      await _tapKey(tester, const Key('btn_wiz_email_next'));
      await tester.pumpAndSettle();

      await _tapKey(tester, const Key('btn_wiz_security_next'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_wiz_password')),
        'strongpass',
      );
      await tester.enterText(
        find.byKey(const Key('input_wiz_confirm_password')),
        'strongpass',
      );
      await _tapKey(tester, const Key('btn_wiz_password_next'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_wiz_otp')),
        '12345678',
      );
      await _tapKey(tester, const Key('btn_wiz_verify_otp'));
      await tester.pumpAndSettle();

      expect(f.supabase.verifyOtpCalls, 1);
      expect(f.supabase.lastVerifiedOtp, '12345678');

      await _tapKey(tester, const Key('btn_setup_biometrics'));
      await tester.pumpAndSettle();

      expect(f.biometrics.authenticateCalls, 1);
      expect(await f.auth.isBiometricEnabled(), isTrue);
      expect(authenticated?.email, 'invited@ttg.test');
    });

    testWidgets(
        'Onboarding blocks uninvited emails immediately at Step 1 before password or OTP',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);
      f.supabase.invitedEmails = {'invited@ttg.test'};

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthRepository>.value(
          value: f.auth,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: AuthScreen(
              onAuthenticated: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _tapKey(tester, const Key('btn_start_wizard'));
      await tester.pumpAndSettle();
      await _tapKey(tester, const Key('btn_wiz_get_started'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_wiz_email')),
        'uninvited@gmail.com',
      );
      await _tapKey(tester, const Key('btn_wiz_email_next'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_wiz_security_next')), findsNothing);
      expect(
        find.textContaining('has not been invited yet'),
        findsOneWidget,
      );
    });

    testWidgets('Quick biometric unlock screen unlocks returning session',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      f.supabase.user =
          const AuthUserInfo(id: 'user-bio', email: 'bio@ttg.test');
      await f.auth.setBiometricEnabled(true);

      AuthUserInfo? authenticated;

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthRepository>.value(
          value: f.auth,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: AuthScreen(
              onAuthenticated: (user) => authenticated = user,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_quick_unlock')), findsOneWidget);

      await _tapKey(tester, const Key('btn_quick_unlock'));
      await tester.pumpAndSettle();

      expect(f.biometrics.authenticateCalls, 1);
      expect(authenticated?.id, 'user-bio');
    });
  });

  group('DashboardViewModel, Utilities, and DashboardScreen', () {
    test('computes Revenue, Net Profit, Pending Bills, Paid Count, and Recent Invoices with dashboard.js parity',
        () async {
      final f = await _createFixture(fastCryptoForWidgetTest: false);
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      await f.vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Savanna Bistro'),
      ], sync: false);

      await f.vault.setInvoices([
        const Invoice(
          id: 'inv-1',
          number: 'TTG-1001',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-11-10',
          totalSell: 10000,
          totalBuy: 7000,
          profit: 3000,
          status: 'paid',
          createdAt: '2026-11-10T10:00:00Z',
        ),
        const Invoice(
          id: 'inv-2',
          number: 'TTG-1002',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-11-15',
          totalSell: 5000,
          totalBuy: 3500,
          profit: 1500,
          status: 'overdue',
          createdAt: '2026-11-15T10:00:00Z',
        ),
        const Invoice(
          id: 'inv-draft',
          number: 'DRAFT',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-11-16',
          totalSell: 99999,
          profit: 99999,
          status: 'draft',
        ),
        const Invoice(
          id: 'inv-old',
          number: 'TTG-0999',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-10-28',
          totalSell: 4000,
          profit: 1000,
          status: 'pending',
        ),
      ], sync: false);

      await f.vault.setExpenses([
        const Expense(
          id: 'exp-1',
          type: 'expense',
          date: '2026-11-12',
          desc: 'Fuel',
          amount: 500,
        ),
        const Expense(
          id: 'cap-1',
          type: 'capital',
          date: '2026-11-12',
          desc: 'Capital injection',
          amount: 20000,
        ),
      ], sync: false);

      final notifications = FakeOverdueNotificationGateway();
      final vm = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        notificationGateway: notifications,
        clock: () => DateTime(2026, 11, 18),
      );
      addTearDown(vm.dispose);

      final m = vm.metrics;
      expect(m.thisMonthRevenue, 15000);
      expect(m.thisMonthProfit, 4000);
      expect(m.thisMonthInvoiceCount, 2);
      expect(m.thisMonthPaidCount, 1);
      expect(m.pendingBillsCount, 2);
      expect(m.overdueBillsCount, 1);
      expect(m.pendingBillsAmount, 9000);
      expect(m.recentInvoices.map((e) => e.id).toList(), ['inv-2', 'inv-1']);

      final enabled = await vm.toggleOverdueNotifications(true);
      expect(enabled, isTrue);
      expect(vm.overdueNotificationsEnabled, isTrue);
      expect(notifications.initCalls, 1);
      expect(notifications.showCalls, 1);
      expect(notifications.lastOverdueCount, 1);
      expect(notifications.lastPendingCount, 2);

      await vm.toggleOverdueNotifications(false);
      expect(vm.overdueNotificationsEnabled, isFalse);
      expect(notifications.cancelCalls, 1);
    });

    test('suppresses automatic pending bill notifications for 24 hours across refreshes',
        () async {
      final f = await _createFixture(fastCryptoForWidgetTest: false);
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      await f.vault.setRestaurants([
        const Restaurant(id: 'r1', name: 'Savanna Bistro'),
      ], sync: false);
      await f.vault.setInvoices([
        const Invoice(
          id: 'inv-2',
          number: 'TTG-1002',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-11-15',
          totalSell: 5000,
          profit: 1500,
          status: 'overdue',
        ),
      ], sync: false);

      var now = DateTime.utc(2026, 11, 18, 9, 0);
      final notifications = FakeOverdueNotificationGateway();
      final vm = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        notificationGateway: notifications,
        clock: () => now,
      );
      addTearDown(vm.dispose);

      await vm.toggleOverdueNotifications(true);
      expect(notifications.showCalls, 1);

      // Refreshing 10 minutes later or 12 hours later must NOT spam again
      now = now.add(const Duration(minutes: 10));
      await vm.refresh();
      expect(notifications.showCalls, 1);

      now = now.add(const Duration(hours: 12));
      await vm.refresh();
      expect(notifications.showCalls, 1);

      // Once 24 hours have passed, one automatic reminder is allowed
      now = now.add(const Duration(hours: 12));
      await vm.refresh();
      expect(notifications.showCalls, 2);

      // Immediately refreshing again stays muted for the next 24h window
      now = now.add(const Duration(minutes: 5));
      await vm.refresh();
      expect(notifications.showCalls, 2);
    });

    test('SignatureProcessor thresholds ink to deep biro blue with transparent background and crops',
        () {
      final rawBytes = _createSampleSignatureImageBytes();
      final result = SignatureProcessor.processSignatureBytes(rawBytes);

      expect(result.dataUri.startsWith('data:image/png;base64,'), isTrue);
      expect(result.width, 80);
      expect(result.height, 56);

      final decoded = img.decodePng(result.pngBytes)!;
      final corner = decoded.getPixel(0, 0);
      expect(corner.a, 0);

      final center = decoded.getPixel(40, 28);
      expect(center.r, SignatureProcessor.inkRed);
      expect(center.g, SignatureProcessor.inkGreen);
      expect(center.b, SignatureProcessor.inkBlue);
      expect(center.a, 255);
    });

    test('ExcelExporter builds valid multi-sheet .xlsx workbook and shares it',
        () async {
      final f = await _createFixture(fastCryptoForWidgetTest: false);
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      await f.vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Highland Grill',
          kraPin: 'P051234567Z',
        ),
      ], sync: false);
      await f.vault.setInvoices([
        const Invoice(
          id: 'i1',
          number: 'TTG-2001',
          restaurantId: 'r1',
          restaurantName: 'Highland Grill',
          date: '2026-11-18',
          totalSell: 12000,
          totalBuy: 8500,
          profit: 3500,
          status: 'paid',
        ),
      ], sync: false);
      await f.vault.setExpenses([
        const Expense(
          id: 'e1',
          date: '2026-11-18',
          desc: 'Market Porter',
          category: 'labor',
          amount: 600,
        ),
      ], sync: false);
      await f.vault.setStaff([
        const Staff(id: 's1', name: 'Grace Wanjiku', role: 'Driver', salary: 25000),
      ], sync: false);

      final tempDir = await Directory.systemTemp.createTemp('ttg_excel_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      String? sharedPath;
      final exporter = ExcelExporter(
        tempDirLookup: () async => tempDir,
        shareFiles: (files, {subject, text}) async {
          sharedPath = files.first.path;
        },
      );

      final exportedFile = await exporter.exportAndShare(f.vault);
      expect(await exportedFile.exists(), isTrue);
      expect(sharedPath, exportedFile.path);

      final decoded = xls.Excel.decodeBytes(await exportedFile.readAsBytes());
      expect(
        decoded.tables.keys,
        containsAll(['Invoices', 'Expenses', 'Staff', 'Restaurants']),
      );
      final invoiceRow = decoded.tables['Invoices']!.rows[1];
      expect(
        (invoiceRow[0]!.value as xls.TextCellValue).value.text,
        'TTG-2001',
      );
      expect(
        (invoiceRow[1]!.value as xls.TextCellValue).value.text,
        'Highland Grill',
      );
    });

    testWidgets('DashboardScreen displays pending clerk banner, KPIs, recent invoices, and callbacks',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      f.supabase.user =
          const AuthUserInfo(id: 'owner-1', email: 'veronicah@ttg.test');
      await f.storage.setUserId('owner-1');
      await f.storage.setUserEmail('veronicah@ttg.test');

      f.supabase.stagedInvoices.add({
        'id': 'stg_1',
        'owner_user_id': 'owner-1',
        'clerk_name': 'John Clerk',
        'restaurant_name': 'Savanna Bistro',
        'invoice_date': '2026-11-18',
        'status': 'pending',
        'notes': '',
        'items_json': [],
      });

      await f.vault.setInvoices([
        const Invoice(
          id: 'inv-101',
          number: 'TTG-1010',
          restaurantId: 'r1',
          restaurantName: 'Savanna Bistro',
          date: '2026-11-18',
          totalSell: 8500,
          totalBuy: 6000,
          profit: 2500,
          status: 'paid',
        ),
      ], sync: false);

      final notifications = FakeOverdueNotificationGateway();
      final vm = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        notificationGateway: notifications,
        clock: () => DateTime(2026, 11, 18),
      );
      addTearDown(vm.dispose);

      var clerkInboxOpened = false;
      Invoice? openedInvoice;
      var createInvoiceTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DashboardScreen(
            viewModel: vm,
            onOpenClerkInbox: () => clerkInboxOpened = true,
            onOpenInvoice: (inv) => openedInvoice = inv,
            onCreateInvoice: () => createInvoiceTapped = true,
            autoInitialize: false,
          ),
        ),
      );
      await vm.initialize(syncRemote: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('banner_pending_clerk_dockets')), findsOneWidget);
      expect(find.byKey(const Key('kpi_revenue')), findsOneWidget);
      expect(find.byKey(const Key('kpi_profit')), findsOneWidget);
      expect(find.byKey(const Key('kpi_pending_bills')), findsOneWidget);
      expect(find.byKey(const Key('kpi_paid_count')), findsOneWidget);
      expect(find.textContaining('8,500.00'), findsWidgets);

      await _tapKey(tester, const Key('btn_open_clerk_inbox'));
      await tester.pump();
      expect(clerkInboxOpened, isTrue);

      await _tapKey(tester, const Key('recent_invoice_inv-101'));
      await tester.pump();
      expect(openedInvoice?.id, 'inv-101');

      await _tapKey(tester, const Key('fab_create_invoice'));
      await tester.pump();
      expect(createInvoiceTapped, isTrue);
    });

    testWidgets('ChangePasswordDialog migrates E2EE key and updates Supabase password',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      await f.auth.signIn('owner@ttg.test', 'old-pass');
      final oldKey = await f.storage.getE2eKey();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => ChangePasswordDialog(
                      onChangePassword: ({
                        required currentPassword,
                        required newPassword,
                      }) =>
                          f.auth.updatePassword(
                        currentPassword: currentPassword,
                        newPassword: newPassword,
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_cp_current')),
        'old-pass',
      );
      await tester.enterText(
        find.byKey(const Key('input_cp_new')),
        'new-strong-pass',
      );
      await tester.enterText(
        find.byKey(const Key('input_cp_confirm')),
        'new-strong-pass',
      );
      await _tapKey(tester, const Key('chk_cp_understand'));
      await _tapKey(tester, const Key('btn_cp_submit'));
      await tester.pumpAndSettle();

      expect(f.supabase.updatePasswordCalls, 1);
      expect(f.supabase.lastUpdatedPassword, 'new-strong-pass');
      expect(f.supabase.signOutOthersCalls, 1);
      final newKey = await f.storage.getE2eKey();
      expect(newKey, isNotNull);
      expect(newKey!['k'], isNot(oldKey!['k']));
    });

    testWidgets('SignatureScannerSheet processes image and saves signature to VaultSettings',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      final sampleBytes = _createSampleSignatureImageBytes();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SignatureScannerSheet(
              initialSignatureUri: null,
              imagePicker: (_) async => sampleBytes,
              onSaveSignature: (uri) async {
                await f.vault.setSettings(
                  f.vault.settings.copyWith(signature: uri),
                  sync: false,
                );
              },
            ),
          ),
        ),
      );

      await _tapKey(tester, const Key('btn_sig_gallery'));
      await tester.pumpAndSettle();

      await _tapKey(tester, const Key('btn_sig_save'));
      await tester.pumpAndSettle();

      expect(
        f.vault.settings.signature,
        startsWith('data:image/png;base64,'),
      );
    });

    testWidgets('UpdateCheckerSheet checks manifest and triggers verified APK install',
        (tester) async {
      const manifest = AppUpdateManifest(
        version: '2.0.0',
        buildNumber: 12,
        apkUrl: 'https://updates.example.com/ttg-2.0.0.apk',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        releaseNotes: 'Faster invoice scanning and offline sync.',
      );
      final updateService = FakeRemoteUpdateService(
        result: const UpdateCheckResult(
          updateAvailable: true,
          currentVersion: '1.0.0',
          currentBuildNumber: 1,
          manifest: manifest,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: UpdateCheckerSheet(
              updateService: updateService,
              manifestUrl: 'https://updates.example.com/app-update.json',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(updateService.checkCalls, 1);
      expect(
        updateService.lastManifestUrl,
        'https://updates.example.com/app-update.json',
      );
      expect(find.textContaining('v2.0.0'), findsOneWidget);
      expect(
        find.textContaining('Faster invoice scanning and offline sync.'),
        findsOneWidget,
      );

      await _tapKey(tester, const Key('btn_install_update'));
      await tester.pumpAndSettle();

      expect(updateService.installCalls, 1);
      expect(updateService.lastInstalledManifest?.buildNumber, 12);
      expect(
        find.textContaining('Installer opened after safety verification.'),
        findsOneWidget,
      );
    });

    test(
        'DashboardViewModel silent auto-update check notifies once per build and handles offline cleanly',
        () async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      const manifest = AppUpdateManifest(
        version: '1.1.0',
        buildNumber: 4,
        apkUrl: 'https://updates.example.com/ttg-1.1.0.apk',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        releaseNotes: 'Hybrid PP-OCRv5 offline scanning and smart alerts.',
      );
      final notifications = FakeOverdueNotificationGateway();
      final updateService = FakeRemoteUpdateService(
        result: const UpdateCheckResult(
          updateAvailable: true,
          currentVersion: '1.0.2',
          currentBuildNumber: 3,
          manifest: manifest,
        ),
      );

      var now = DateTime(2026, 11, 19, 9, 0);
      final vm = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        notificationGateway: notifications,
        smartNotificationGateway: notifications,
        updateService: updateService,
        updateManifestUrl: 'https://updates.example.com/app-update.json',
        clock: () => now,
      );
      addTearDown(vm.dispose);

      await vm.initialize(syncRemote: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(updateService.checkCalls, 1);
      expect(vm.hasUpdateAvailable, isTrue);
      expect(vm.availableUpdate?.manifest?.version, '1.1.0');
      expect(
        notifications.categoryCalls
            .where((c) => c.category == NotificationCategory.appUpdates)
            .length,
        1,
      );

      // Re-checking within 12h interval skips network call unless forced.
      now = now.add(const Duration(hours: 2));
      await vm.runSilentUpdateCheck();
      expect(updateService.checkCalls, 1);

      // Forced re-check on the same buildNumber does not duplicate OS alert.
      await vm.runSilentUpdateCheck(force: true);
      expect(updateService.checkCalls, 2);
      expect(
        notifications.categoryCalls
            .where((c) => c.category == NotificationCategory.appUpdates)
            .length,
        1,
      );

      // Offline failure during silent update check is gracefully suppressed.
      final offlineUpdate = FakeRemoteUpdateService(
        result: const UpdateCheckResult(
          updateAvailable: false,
          currentVersion: '1.0.2',
          currentBuildNumber: 3,
        ),
        throwError: const SocketException('Network unreachable'),
      );
      final vmOffline = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        updateService: offlineUpdate,
        clock: () => now.add(const Duration(days: 1)),
      );
      addTearDown(vmOffline.dispose);
      await vmOffline.runSilentUpdateCheck(force: true);
      expect(vmOffline.errorMessage, isNull);
    });

    testWidgets(
        'DashboardScreen shows Update banner and NotificationCenterSheet toggles smart alerts',
        (tester) async {
      final f = await _createFixture();
      addTearDown(f.storage.close);
      addTearDown(f.vault.dispose);

      await f.vault.setStaff([
        const Staff(
          id: 'st-1',
          name: 'Grace Wanjiku',
          role: 'Packer',
          salary: 18000,
          payDay: '1',
          status: 'active',
        ),
      ], sync: false);
      await f.vault.setInvoices([
        const Invoice(
          id: 'inv-old',
          number: 'TTG-900',
          restaurantId: 'r1',
          restaurantName: 'Kempinski Hotel',
          date: '2026-09-01',
          dueDate: '2026-09-15',
          totalSell: 12000,
          totalBuy: 9000,
          profit: 3000,
          status: 'pending',
        ),
      ], sync: false);

      const manifest = AppUpdateManifest(
        version: '1.1.0',
        buildNumber: 4,
        apkUrl: 'https://updates.example.com/ttg-1.1.0.apk',
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        releaseNotes: 'Hybrid local OCR and Smart Notification Center.',
      );
      final notifications = FakeOverdueNotificationGateway();
      final updateService = FakeRemoteUpdateService(
        result: const UpdateCheckResult(
          updateAvailable: true,
          currentVersion: '1.0.2',
          currentBuildNumber: 3,
          manifest: manifest,
        ),
      );

      final vm = DashboardViewModel(
        vaultRepository: f.vault,
        authRepository: f.auth,
        stagingRepository: f.staging,
        localStorage: f.storage,
        notificationGateway: notifications,
        smartNotificationGateway: notifications,
        updateService: updateService,
        clock: () => DateTime(2026, 11, 2),
      );
      addTearDown(vm.dispose);

      var invoicesOpened = false;
      var statementsOpened = false;
      int? openedExpenseTab;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DashboardScreen(
            viewModel: vm,
            updateService: updateService,
            onOpenInvoicesTab: () => invoicesOpened = true,
            onOpenExpensesHub: (tab) => openedExpenseTab = tab,
            onOpenStatements: () => statementsOpened = true,
            autoInitialize: false,
          ),
        ),
      );
      await vm.initialize(syncRemote: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('banner_update_available')), findsOneWidget);
      expect(find.textContaining('Update Available (v1.1.0)'), findsOneWidget);

      await _tapKey(tester, const Key('btn_dashboard_notify_toggle'));
      await tester.pumpAndSettle();

      expect(find.byType(NotificationCenterSheet), findsOneWidget);
      expect(find.text('Smart Notification Center'), findsOneWidget);
      expect(find.textContaining('Staff Salary Due'), findsOneWidget);
      expect(find.textContaining('Monthly Client Statements Ready'), findsOneWidget);

      final appUpdatesToggle = find.byKey(const Key('pref_app_updates'));
      await tester.scrollUntilVisible(
        appUpdatesToggle,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(appUpdatesToggle);
      await tester.pumpAndSettle();
      expect(vm.notificationPrefs.appUpdatesEnabled, isFalse);

      // Scroll back to top of alert feed and tap Statements action to verify deep link.
      final statementsAction = find.widgetWithText(FilledButton, 'Statements');
      await tester.scrollUntilVisible(
        statementsAction,
        -250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(statementsAction);
      await tester.pumpAndSettle();

      expect(statementsOpened, isTrue);
      expect(invoicesOpened, isFalse);
      expect(openedExpenseTab, isNull);
    });
  });
}
