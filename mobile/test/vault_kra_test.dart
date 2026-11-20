import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/kra_oscu_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/personal_vault_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/kra/kra_tax_center_screen.dart';
import 'package:town_treasure_groceries/ui/features/reports/reports_view_model.dart';
import 'package:town_treasure_groceries/ui/features/reports/statement_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/vault/personal_vault_screen.dart';

import 'test_fakes.dart';

class _InMemoryLocalStorageService extends LocalStorageService {
  _InMemoryLocalStorageService() : super(secureStore: InMemorySecureKeyStore());

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
  Future<void> close() async {}
}

class _FakeAuthGateway implements VaultAuthGateway {
  _FakeAuthGateway({required this.allow});
  bool allow;
  int calls = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    return allow;
  }
}

void main() {
  group('Personal Documents Vault + Cloudflare R2 E2EE', () {
    test(
        'CryptoService encryptBytes/decryptBytes and PersonalVaultService upload ciphertext to R2 & lazy-download on another device',
        () async {
      final tempRoot =
          await Directory.systemTemp.createTemp('ttg_vault_service_test_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final deviceADir = Directory('${tempRoot.path}/deviceA')..createSync();
      final deviceBDir = Directory('${tempRoot.path}/deviceB')..createSync();

      final r2Objects = <String, Uint8List>{};
      final r2AuthHeaders = <String>[];
      final fakeClient = MockClient((req) async {
        r2AuthHeaders.add(req.headers['Authorization'] ?? '');
        final docPath = req.url.path;
        if (req.method == 'PUT') {
          r2Objects[docPath] = Uint8List.fromList(req.bodyBytes);
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        if (req.method == 'GET') {
          final found = r2Objects[docPath];
          if (found == null) return http.Response('Not found', 404);
          return http.Response.bytes(found, 200);
        }
        if (req.method == 'DELETE') {
          r2Objects.remove(docPath);
          return http.Response(jsonEncode({'deleted': true}), 200);
        }
        return http.Response('Method error', 405);
      });

      final crypto = CryptoService();
      final jwk = await crypto.deriveKey('TestPass#2026', 'owner-1');
      final storage = _InMemoryLocalStorageService();
      await storage.setE2eKey(jwk);
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'owner-1', email: 'owner@ttg.test')
        ..accessToken = 'supabase-jwt-123';

      final sampleImg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 24, height: 24)),
      );
      final pdfBytes = await PersonalVaultService.packImagesToPdf(
        [sampleImg],
        title: 'KRA TCC 2026',
      );
      expect(utf8.decode(pdfBytes.sublist(0, 5)), '%PDF-');

      final serviceA = PersonalVaultService(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        httpClient: fakeClient,
        vaultDirProvider: () async => deviceADir,
      );

      final savedMeta = await serviceA.encryptStoreAndUpload(
        meta: const PersonalDocument(
          id: 'doc_tcc_2026',
          title: 'KRA TCC 2026',
          category: PersonalDocCategory.kraTax,
          expiryDate: '2027-06-30',
        ),
        plainBytes: pdfBytes,
        workerUrl: 'https://ttg-vault-docs.example.workers.dev/',
      );

      expect(savedMeta.r2Synced, isTrue);
      expect(savedMeta.plainBytes, pdfBytes.length);
      expect(savedMeta.sha256.length, 64);
      expect(r2AuthHeaders.first, 'Bearer supabase-jwt-123');

      final uploadedCipher = r2Objects['/docs/doc_tcc_2026']!;
      expect(uploadedCipher, isNot(equals(pdfBytes)));
      expect(uploadedCipher.length, pdfBytes.length + 28);

      // Device B starts empty, downloads ciphertext lazily from R2, verifies SHA-256 & decrypts
      final serviceB = PersonalVaultService(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        httpClient: fakeClient,
        vaultDirProvider: () async => deviceBDir,
      );
      expect(await serviceB.hasLocalEncryptedCopy('doc_tcc_2026'), isFalse);

      final decryptedOnB = await serviceB.loadAndDecryptDocument(
        savedMeta,
        workerUrl: 'https://ttg-vault-docs.example.workers.dev',
      );
      expect(decryptedOnB, equals(pdfBytes));
      expect(await serviceB.hasLocalEncryptedCopy('doc_tcc_2026'), isTrue);

      // Delete cleans R2 & local encrypted file
      await serviceB.deleteEncryptedBlob(
        'doc_tcc_2026',
        workerUrl: 'https://ttg-vault-docs.example.workers.dev',
      );
      expect(r2Objects, isEmpty);
      expect(await serviceB.hasLocalEncryptedCopy('doc_tcc_2026'), isFalse);
    });

    test('VaultRepository merges PersonalDocument lists across devices without overwrite', () {
      const localDoc = PersonalDocument(
        id: 'doc_local_1',
        title: 'Nairobi Business Permit',
        expiryDate: '2026-12-31',
        updatedAt: '2026-11-20T10:00:00Z',
      );
      const remoteDoc = PersonalDocument(
        id: 'doc_remote_2',
        title: 'KRA PIN Certificate',
        updatedAt: '2026-11-20T09:00:00Z',
      );

      final localSettings = const VaultSettings()
          .withPersonalDocuments([localDoc]);
      final remoteSettings = const VaultSettings()
          .withPersonalDocuments([remoteDoc])
          .withKraProfile(
            const KraCompanyProfile(
              sellerKraPin: 'P051234567X',
              updatedAt: '2026-11-20T11:00:00Z',
            ),
          );

      final merged = VaultRepository.mergeSettingsByTimestamp(
        localSettings,
        remoteSettings,
      );
      expect(merged.personalDocuments.map((d) => d.id).toSet(), {
        'doc_local_1',
        'doc_remote_2',
      });
      expect(merged.kraProfile.normalizedSellerPin, 'P051234567X');
    });

    testWidgets(
        'PersonalVaultScreen gates access behind biometrics and encrypts added document',
        (tester) async {
      final tempDir =
          Directory.systemTemp.createTempSync('ttg_vault_widget_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final storage = _InMemoryLocalStorageService();
      final crypto = CryptoService();
      final jwk = await tester.runAsync(
        () => crypto.deriveKey('VaultKey#1', 'owner-1'),
      );
      await storage.setE2eKey(jwk!);
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'owner-1', email: 'vero@ttg.test');

      final vault = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        syncDebounceDuration: const Duration(milliseconds: 10),
      );
      addTearDown(vault.dispose);

      final service = PersonalVaultService(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        httpClient: MockClient((req) async {
          if (req.method == 'PUT') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('Not found', 404);
        }),
        vaultDirProvider: () async => tempDir,
      );

      final auth = _FakeAuthGateway(allow: false);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: PersonalVaultScreen(
            vault: vault,
            vaultService: service,
            authGateway: auth,
            documentPicker: () async => StagedVaultFile(
              bytes: Uint8List.fromList(utf8.encode('%PDF-1.4\nSampleKRA')),
              mimeType: 'application/pdf',
              fileName: 'tcc.pdf',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially locked because biometric auth returned false
      expect(find.text('Personal Vault Locked'), findsOneWidget);
      expect(find.byKey(const Key('fab_add_vault_doc')), findsNothing);

      // Unlock succeeds
      auth.allow = true;
      await tester.tap(find.byKey(const Key('btn_unlock_personal_vault')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fab_add_vault_doc')), findsOneWidget);

      // Add a document through the bottom sheet
      await tester.tap(find.byKey(const Key('fab_add_vault_doc')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_vault_pick_file')));
      await tester.pumpAndSettle();

      // Vault should not force expiry clutter onto owner
      expect(find.byKey(const Key('field_vault_expiry')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('field_vault_title')),
        'KRA TCC 2026',
      );
      await tester.ensureVisible(find.byKey(const Key('btn_vault_save_doc')));
      await tester.tap(find.byKey(const Key('btn_vault_save_doc')));
      for (var i = 0; i < 40 && vault.personalDocuments.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();

      expect(vault.personalDocuments.length, 1);
      expect(vault.personalDocuments.first.title, 'KRA TCC 2026');
      expect(find.text('KRA TCC 2026'), findsOneWidget);
    });
  });

  group('KRA VAT3 Compliance & Tax Center', () {
    test('KraTaxCalculator computes mixed Exempt + 16% Inclusive/Exclusive VAT and PDF generation succeeds', () async {
      const mixedInv = Invoice(
        id: 'inv_mix_1',
        number: 'TTG-9001',
        restaurantId: 'rest_1',
        restaurantName: 'The Golden Crest Hotel',
        date: '2026-11-15',
        vatMode: 'exclusive',
        cuInvoiceNumber: 'KRAMW001/0099',
        etimsQrData: 'https://etims.kra.go.ke/verify/KRAMW001-0099',
        items: [
          InvoiceLineItem(
            desc: 'Fresh Tomatoes',
            qty: 100,
            unit: 'kgs',
            buyPrice: 60,
            sellPrice: 100,
            total: 10000,
            taxRate: 'exempt',
          ),
          InvoiceLineItem(
            desc: 'Processed Olive Oil',
            qty: 10,
            unit: 'bottles',
            buyPrice: 800,
            sellPrice: 1000,
            total: 10000,
            taxRate: 'standard_16',
          ),
        ],
        totalSell: 20000,
      );

      final summary = KraTaxCalculator.computeInvoiceTaxSummary(mixedInv);
      expect(summary.exemptTotal, 10000.0);
      expect(summary.taxableNetTotal, 10000.0);
      expect(summary.outputVatTotal, 1600.0);
      expect(summary.grandTotalWithVat, 21600.0);
      expect(summary.hasTaxableVatLines, isTrue);

      final monthly = KraTaxCalculator.computeMonthlySummary(
        monthYm: '2026-11',
        invoices: [mixedInv],
        expenses: [
          const Expense(
            id: 'exp_1',
            date: '2026-11-10',
            desc: 'Packaging Boxes',
            amount: 5800,
            inputVatAmount: 800,
            supplierKraPin: 'P051112223A',
          ),
        ],
        restaurants: const [
          Restaurant(
            id: 'rest_1',
            name: 'The Golden Crest Hotel',
            kraPin: 'P059998887B',
          ),
        ],
      );

      expect(monthly.outputVatTotal, 1600.0);
      expect(monthly.inputVatTotal, 800.0);
      expect(monthly.netVatPayable, 800.0);
      expect(monthly.filingDeadline, DateTime(2026, 12, 20));
      expect(monthly.invoicesMissingClientPin, isEmpty);

      final settings = const VaultSettings().withKraProfile(
        const KraCompanyProfile(
          sellerKraPin: 'P051234567X',
          vatRegistered: true,
          cuSerialNumber: 'KRAMW001',
        ),
      );

      final pdfBytes = await InvoicePdfBuilder.buildPdfBytes(
        invoice: mixedInv,
        restaurant: const Restaurant(
          id: 'rest_1',
          name: 'The Golden Crest Hotel',
          kraPin: 'P059998887B',
        ),
        settings: settings,
        logoBytesOverride: Uint8List(0),
        stampBytesOverride: Uint8List(0),
      );
      expect(utf8.decode(pdfBytes.sublist(0, 5)), '%PDF-');
    });

    testWidgets(
        'KraTaxCenterScreen opens Help guide, configures KRA/OSCU setup, and issues eTIMS QR invoice',
        (tester) async {
      final storage = _InMemoryLocalStorageService();
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'owner-1', email: 'vero@ttg.test');
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: storage,
        supabase: supabase,
        syncDebounceDuration: const Duration(milliseconds: 10),
      );
      addTearDown(vault.dispose);

      await vault.setRestaurants(
        const [
          Restaurant(
            id: 'r1',
            name: 'Sankara Suites',
            kraPin: 'P051111111Z',
          ),
        ],
        sync: false,
      );
      await vault.setInvoices(
        [
          Invoice(
            id: 'inv_1',
            number: 'TTG-2026',
            restaurantId: 'r1',
            restaurantName: 'Sankara Suites',
            date: DateTime.now().toIso8601String().substring(0, 10),
            items: const [
              InvoiceLineItem(
                desc: 'Cooking Oil',
                qty: 1,
                buyPrice: 900,
                sellPrice: 1160,
                total: 1160,
              ),
            ],
            totalSell: 1160,
          ),
        ],
        sync: false,
      );

      final fakeOscu = KraOscuService(
        supabase: supabase,
        httpClient: MockClient((req) async {
          expect(req.url.path, '/oscu/sales');
          return http.Response(
            jsonEncode({
              'ok': true,
              'cuInvoiceNumber': 'KRA-OSCU-2026',
              'qrCodeUrl':
                  'https://etims.kra.go.ke/common/link/etims/receipt/indexEtimsInvoiceData?Data=P051234567X00SIG9988',
              'data': {
                'rcptNo': 2026,
                'rcptSign': 'SIG9988',
                'intrData': 'INTR12',
              },
            }),
            200,
          );
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: KraTaxCenterScreen(vault: vault, oscuService: fakeOscu),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Help button opens plain-language operational guide
      await tester.tap(find.byKey(const Key('btn_kra_help')));
      await tester.pumpAndSettle();
      expect(find.text('How KRA & eTIMS Tax Center Works'), findsOneWidget);
      await tester.ensureVisible(find.text('Got It'));
      await tester.tap(find.text('Got It'));
      await tester.pumpAndSettle();

      // 2. Uncluttered Setup bottom sheet saves Seller KRA PIN
      await tester.tap(find.byKey(const Key('btn_edit_kra_profile')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('field_kra_seller_pin')),
        'P051234567X',
      );
      await tester.ensureVisible(find.byKey(const Key('btn_save_kra_profile')));
      await tester.tap(find.byKey(const Key('btn_save_kra_profile')));
      await tester.pumpAndSettle();
      expect(vault.kraProfile.normalizedSellerPin, 'P051234567X');

      ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // 3. Tag invoice to 16% VAT & issue eTIMS QR via OSCU
      await tester.ensureVisible(find.byKey(const Key('kra_inv_inv_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('kra_inv_inv_1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chip_mark_all_vat16')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('btn_issue_oscu')));
      await tester.tap(find.byKey(const Key('btn_issue_oscu')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('btn_save_invoice_tax')));
      await tester.tap(find.byKey(const Key('btn_save_invoice_tax')));
      await tester.pumpAndSettle();

      // Inclusive 1,160 KES @ 16% => Net 1,000 + Output VAT 160 + QR Ready
      expect(vault.invoices.first.cuInvoiceNumber, 'KRA-OSCU-2026');
      expect(
        vault.invoices.first.etimsQrData,
        'https://etims.kra.go.ke/common/link/etims/receipt/indexEtimsInvoiceData?Data=P051234567X00SIG9988',
      );
      expect(find.textContaining('eTIMS QR Ready'), findsWidgets);
      expect(find.textContaining('KES 160.00'), findsWidgets);

      ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // 4. Switch to Monthly By Hotel cadence & issue consolidated Monthly Statement eTIMS QR
      await tester.ensureVisible(find.byKey(const Key('segmented_etims_cadence')));
      await tester.tap(find.textContaining('Monthly Hotel'));
      await tester.pumpAndSettle();

      final monthKey = DateTime.now().toIso8601String().substring(0, 7);
      final monthlyTileKey = Key('kra_monthly_${monthKey}_r1');
      await tester.ensureVisible(find.byKey(monthlyTileKey));
      await tester.tap(find.byKey(monthlyTileKey));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('btn_issue_oscu')));
      await tester.tap(find.byKey(const Key('btn_issue_oscu')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('btn_save_invoice_tax')));
      await tester.tap(find.byKey(const Key('btn_save_invoice_tax')));
      await tester.pumpAndSettle();

      final savedMonthly = vault.settings.findMonthlyEtims(
        monthKey,
        const Restaurant(id: 'r1', name: 'Sankara Suites'),
      );
      expect(savedMonthly, isNotNull);
      expect(savedMonthly!.cuInvoiceNumber, 'KRA-OSCU-2026');
      expect(savedMonthly.hasQr, isTrue);
      expect(find.textContaining('Monthly QR Ready'), findsOneWidget);

      // 5. Consolidated Monthly Statement PDF renders cleanly with eTIMS QR attached
      final stmt = ReportsViewModel(vault: vault).buildStatement(
        const Restaurant(id: 'r1', name: 'Sankara Suites', kraPin: 'P051111111Z'),
        monthKey,
      );
      final stmtPdfBytes = await StatementPdfBuilder.buildPdfBytes(
        stmt,
        settings: vault.settings,
      );
      expect(stmtPdfBytes.length, greaterThan(1500));
      expect(utf8.decode(stmtPdfBytes.take(5).toList()), '%PDF-');
    });
  });
}
