import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:town_treasure_groceries/data/repositories/staging_repository.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/duplicate_detector_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/ocr_consensus_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/clerk/clerk_submissions_screen.dart';
import 'package:town_treasure_groceries/ui/features/clerk/clerk_view_model.dart';
import 'package:town_treasure_groceries/ui/features/scanner/docket_scanner_sheet.dart';

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

class _FakeTextRecognizer implements OcrTextRecognizerGateway {
  _FakeTextRecognizer(this.responses);
  final List<String> responses;
  int _idx = 0;

  @override
  Future<String> recognizeTextFromFile(String filePath) async {
    if (responses.isEmpty) return '';
    final out = responses[_idx % responses.length];
    _idx++;
    return out;
  }

  @override
  Future<void> close() async {}
}

class _FakeImagePicker implements ImagePickerGateway {
  _FakeImagePicker({this.cameraFile, this.galleryFiles = const []});
  final XFile? cameraFile;
  final List<XFile> galleryFiles;

  @override
  Future<XFile?> pickCameraImage({int imageQuality = 85}) async => cameraFile;

  @override
  Future<List<XFile>> pickGalleryImages({int imageQuality = 85}) async =>
      galleryFiles;
}

class _ClerkFakeSupabaseGateway extends FakeSupabaseGateway {
  String activeInviteToken = 'tok_abcdefghijklmnopqrstuvwxyz0123456789ABCDEF';
  String ownerName = 'Veronica';
  String ownerEmail = 'veronica@towntreasure.test';
  final List<Map<String, dynamic>> clerkApiCalls = [];

  @override
  Future<Map<String, dynamic>> invokeClerkApi(Map<String, dynamic> body) async {
    clerkApiCalls.add(body);
    final action = body['action']?.toString();
    if (action == 'create_invite') {
      return {
        'token': activeInviteToken,
        'invite': {
          'id': 'inv_1',
          'owner_user_id': user?.id ?? 'user-1',
          'owner_email': ownerEmail,
          'owner_name': ownerName,
          'expires_at': '2026-12-31T00:00:00Z',
        },
      };
    }

    if (body['invite_token'] != activeInviteToken) {
      throw const VaultSyncException('Invalid invite token.');
    }

    if (action == 'list') {
      final subId = body['submission_id']?.toString();
      final filtered = subId != null
          ? stagedInvoices.where((r) => r['id'] == subId).toList()
          : List<Map<String, dynamic>>.from(stagedInvoices);
      return {
        'owner': {'name': ownerName, 'email': ownerEmail},
        'submissions': filtered,
      };
    }

    if (action == 'submit') {
      final docket = Map<String, dynamic>.from(body['docket'] as Map);
      final reqId = docket['id']?.toString();
      final saved = {
        ...docket,
        'id': (reqId != null && reqId.isNotEmpty)
            ? reqId
            : 'stg_${stagedInvoices.length + 1}',
        'owner_user_id': user?.id ?? 'user-1',
        'status': 'pending',
        'rejection_reason': '',
        'created_at':
            docket['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      };
      final idx = stagedInvoices.indexWhere((e) => e['id'] == saved['id']);
      if (idx >= 0) {
        stagedInvoices[idx] = saved;
      } else {
        stagedInvoices.insert(0, saved);
      }
      return {'submission': saved, 'replayed': false};
    }

    if (action == 'delete') {
      final id = body['id']?.toString();
      final idx = stagedInvoices.indexWhere(
        (e) => e['id'] == id && e['status'] != 'approved',
      );
      if (idx < 0) return {'deleted': false};
      stagedInvoices.removeAt(idx);
      return {'deleted': true};
    }

    return {};
  }
}

void main() {
  group('OcrConsensusService', () {
    test('itemsToCsv and csvToItems round-trip quoted descriptions and totals',
        () {
      const items = [
        InvoiceLineItem(
          desc: 'Tomatoes, "Roma" Grade A',
          qty: 3,
          unit: 'crates',
          buyPrice: 2400,
          sellPrice: 3200,
          total: 9600,
        ),
        InvoiceLineItem(
          desc: 'Red Onions',
          qty: 50,
          unit: 'kgs',
          buyPrice: 110,
          sellPrice: 155,
          total: 7750,
        ),
      ];

      final csv = OcrConsensusService.itemsToCsv(items);
      expect(
        csv,
        contains('"Tomatoes, ""Roma"" Grade A",3,crates,3200,9600'),
      );

      final parsed = OcrConsensusService.csvToItems(csv);
      expect(parsed.length, 2);
      expect(parsed[0].desc, 'Tomatoes, "Roma" Grade A');
      expect(parsed[0].qty, 3);
      expect(parsed[0].unit, 'crates');
      expect(parsed[0].sellPrice, 3200);
      expect(parsed[0].total, 9600);
      expect(parsed[1].desc, 'Red Onions');
      expect(parsed[1].qty, 50);
    });

    test('reconcileWithMath arbitrates unit price from qty and line total', () {
      final res = OcrConsensusService.reconcileWithMath(
        geminiData: {
          'restaurant_name': 'The Golden Crest Hotel',
          'invoice_number': 'DKT-8821',
          'invoice_date': '2026-11-18',
          'subtotal': 10800,
          'delivery_cost': 500,
          'other_cost': 0,
          'items': [
            {
              'desc': 'Roma Tomatoes',
              'qty': 3,
              'unit': 'crates',
              'price': 300, // OCR misread 3200 as 300; total 9600 is ground truth
              'total': 9600,
            },
            {
              'desc': 'Dhania',
              'qty': 30,
              'unit': 'bunch',
              'price': 40,
              'total': 0, // Missing total computed from qty * price = 1200
            },
          ],
        },
      );

      expect(res.items.length, 2);
      expect(res.items[0].sellPrice, 3200);
      expect(res.items[0].total, 9600);
      expect(res.items[1].unit, 'bunches');
      expect(res.items[1].total, 1200);
      expect(res.subtotal, 10800);
      expect(res.grandTotal, 11300);
      expect(res.confidence, 99);
    });

    test('processDocket works offline with Google ML Kit text recognizer',
        () async {
      final ocr = OcrConsensusService(
        textRecognizer: _FakeTextRecognizer([
          'Client: Sankara Suites\n'
              'Date: 2026-11-18\n'
              'Red Onions 50 kgs 155 7750\n'
              'Baby Spinach 20 bundles 50 1000\n'
              'Delivery Fee: KES 450\n',
        ]),
      );

      final result = await ocr.processDocket([
        const OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,AAAA',
          filePath: '/tmp/page1.jpg',
        ),
      ]);

      expect(result.restaurantName, 'Sankara Suites');
      expect(result.date, '2026-11-18');
      expect(result.items.length, 2);
      expect(result.items[0].desc, 'Red Onions');
      expect(result.items[0].total, 7750);
      expect(result.deliveryCost, 450);
      expect(result.subtotal, 8750);
      expect(result.grandTotal, 9200);
      expect(result.confidence, 85);
      expect(result.enginesUsed, contains('Google ML Kit On-Device'));
      expect(result.enginesUsed, contains('Math Invariant Arbiter'));
    });

    test('processDocket reconciles Gemini Vision REST + ML Kit when key is set',
        () async {
      final mockClient = MockClient((request) async {
        expect(request.url.host, 'generativelanguage.googleapis.com');
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({
                        'restaurant_name': 'Villa Rosa Kempinski',
                        'invoice_number': 'DKT-9901',
                        'invoice_date': '2026-11-18',
                        'items': [
                          {
                            'desc': 'Button Mushrooms',
                            'qty': 8,
                            'unit': 'kgs',
                            'price': 520,
                            'total': 4160,
                          },
                        ],
                        'subtotal': 4160,
                        'delivery_cost': 300,
                      }),
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final ocr = OcrConsensusService(
        httpClient: mockClient,
        geminiApiKey: 'test-gemini-key',
        textRecognizer: _FakeTextRecognizer(['Villa Rosa Kempinski']),
      );

      final result = await ocr.processDocket([
        const OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,AAAA',
          filePath: '/tmp/p1.jpg',
        ),
      ]);

      expect(result.confidence, 99);
      expect(result.restaurantName, 'Villa Rosa Kempinski');
      expect(result.items.single.desc, 'Button Mushrooms');
      expect(result.grandTotal, 4460);
      expect(result.enginesUsed, contains('Town Treasure Optical Engine'));
      expect(result.enginesUsed, contains('Google ML Kit On-Device'));
    });

    test('processPriceList normalizes headers, categories, and Kenyan units',
        () async {
      final ocr = OcrConsensusService(
        textRecognizer: _FakeTextRecognizer([
          'VEGETABLES\n'
              'Roma Tomatoes 3200 crate\n'
              'FRUITS\n'
              'Ripe Mangoes 180 kgs\n',
        ]),
      );

      final res = await ocr.processPriceList([
        const OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,AAAA',
          filePath: '/tmp/pl1.jpg',
        ),
      ]);

      expect(res.items.length, 4);
      expect(res.items[0].isHeader, isTrue);
      expect(res.items[0].name, 'VEGETABLES');
      expect(res.items[1].category, 'vegetables');
      expect(res.items[1].unit, 'crates');
      expect(res.items[2].isHeader, isTrue);
      expect(res.items[3].category, 'fruits');
    });
  });

  group('DuplicateDetectorService', () {
    test('normalizeHotel and canonicalProduce match Kenyan aliases', () {
      expect(
        DuplicateDetectorService.normalizeHotel('The Golden Crest Hotel Ltd'),
        'goldencrest',
      );
      expect(
        DuplicateDetectorService.canonicalProduce('Roma Tomatoes (Grade A)'),
        'tomatoes',
      );
      expect(
        DuplicateDetectorService.canonicalProduce('Sweet Capsicum (Hoho)'),
        'capsicum',
      );
      expect(
        DuplicateDetectorService.canonicalProduce('Dhania (Coriander)'),
        'coriander',
      );
      expect(
        DuplicateDetectorService.canonicalProduce('Potatoes (Shangi)'),
        'potatoes',
      );
      expect(
        DuplicateDetectorService.canonicalProduce('Warus'),
        'potatoes',
      );
    });

    test('compareItemLists resolves aliases across two produce lists', () {
      final cmp = DuplicateDetectorService.compareItemLists(
        const [
          InvoiceLineItem(
            desc: 'Roma Tomatoes',
            qty: 3,
            unit: 'crates',
            buyPrice: 0,
            sellPrice: 3200,
            total: 9600,
          ),
          InvoiceLineItem(
            desc: 'Sweet Capsicum (Hoho)',
            qty: 12,
            unit: 'kgs',
            buyPrice: 0,
            sellPrice: 180,
            total: 2160,
          ),
        ],
        const [
          InvoiceLineItem(
            desc: 'Cooking Tomatoes',
            qty: 3,
            unit: 'crates',
            buyPrice: 0,
            sellPrice: 3200,
            total: 9600,
          ),
          InvoiceLineItem(
            desc: 'Green Bell Pepper',
            qty: 12,
            unit: 'kgs',
            buyPrice: 0,
            sellPrice: 180,
            total: 2160,
          ),
        ],
      );

      expect(cmp.matchingCount, 2);
      expect(cmp.score, closeTo(1.0, 0.01));
    });

    test('auditSubmission detects high-confidence duplicate and skips drafts',
        () async {
      final detector = DuplicateDetectorService();
      const items = [
        InvoiceLineItem(
          desc: 'Roma Tomatoes',
          qty: 3,
          unit: 'crates',
          buyPrice: 2400,
          sellPrice: 3200,
          total: 9600,
        ),
        InvoiceLineItem(
          desc: 'Red Onions',
          qty: 50,
          unit: 'kgs',
          buyPrice: 110,
          sellPrice: 155,
          total: 7750,
        ),
      ];

      const candidate = AuditRecord(
        id: 'cand_1',
        restaurantName: 'The Golden Crest Hotel',
        date: '2026-11-18',
        items: items,
        totalSell: 17350,
      );

      const draftSame = AuditRecord(
        id: 'draft_1',
        number: 'DRAFT',
        restaurantName: 'The Golden Crest Hotel',
        date: '2026-11-18',
        items: items,
        totalSell: 17350,
        status: 'draft',
      );

      final draftResult = await detector.auditSubmission(
        candidate,
        const [draftSame],
        useDeepAudit: false,
      );
      expect(draftResult.isDuplicate, isFalse);
      expect(draftResult.recommendedAction, 'ALLOW');

      const existingSame = AuditRecord(
        id: 'inv_1001',
        number: 'TTG-1001',
        restaurantName: 'Golden Crest Restaurant',
        date: '2026-11-18',
        items: [
          InvoiceLineItem(
            desc: 'Cooking Tomatoes',
            qty: 3,
            unit: 'crates',
            buyPrice: 2400,
            sellPrice: 3200,
            total: 9600,
          ),
          InvoiceLineItem(
            desc: 'Bombay Onions',
            qty: 50,
            unit: 'kgs',
            buyPrice: 110,
            sellPrice: 155,
            total: 7750,
          ),
        ],
        totalSell: 17350,
        status: 'pending',
      );

      final dupResult = await detector.auditSubmission(
        candidate,
        const [existingSame],
        useDeepAudit: false,
      );
      expect(dupResult.isDuplicate, isTrue);
      expect(dupResult.determination, 'EXACT_DUPLICATE');
      expect(dupResult.recommendedAction, 'BLOCK_SUBMISSION');
      expect(dupResult.matchedRecord?.id, 'inv_1001');
    });
  });

  group('ClerkViewModel integration', () {
    late LocalStorageService storage;
    late _ClerkFakeSupabaseGateway supabase;
    late CryptoService crypto;
    late VaultRepository vault;
    late StagingRepository staging;
    late ClerkViewModel vm;

    setUp(() async {
      storage = await createTestLocalStorage();
      supabase = _ClerkFakeSupabaseGateway();
      supabase.user = const AuthUserInfo(
        id: 'owner-1',
        email: 'veronica@towntreasure.test',
      );
      await storage.setUserId('owner-1');
      await storage.setUserEmail('veronica@towntreasure.test');

      crypto = CryptoService();
      final key = await crypto.deriveKey('master-pass', 'owner-1');
      await storage.setE2eKey(key);

      vault = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
        syncDebounceDuration: const Duration(milliseconds: 10),
      );
      await vault.setRestaurants(
        const [
          Restaurant(id: 'rest_gc', name: 'The Golden Crest Hotel'),
        ],
        sync: false,
      );
      await vault.syncNow();

      staging = StagingRepository(
        supabase: supabase,
        localStorage: storage,
        vaultRepository: vault,
      );

      vm = ClerkViewModel(
        stagingRepository: staging,
        vaultRepository: vault,
        supabase: supabase,
        localStorage: storage,
        ocrService: OcrConsensusService(),
        duplicateDetector: DuplicateDetectorService(),
      );
    });

    tearDown(() async {
      await storage.close();
      vault.dispose();
    });

    test('parseInviteTokenInput extracts invite token from full URL or token',
        () {
      expect(
        ClerkViewModel.parseInviteTokenInput(
          'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk.html#invite=abc_123_XYZ',
        ),
        'abc_123_XYZ',
      );
      expect(
        ClerkViewModel.parseInviteTokenInput('raw_token_value_123'),
        'raw_token_value_123',
      );
    });

    test(
        'owner review runs Ledger Integrity Guard, detects duplicate, and approves when confirmed',
        () async {
      const items = [
        InvoiceLineItem(
          desc: 'Roma Tomatoes',
          qty: 3,
          unit: 'crates',
          buyPrice: 2400,
          sellPrice: 3200,
          total: 9600,
        ),
      ];
      await vault.setInvoices(
        const [
          Invoice(
            id: 'inv_existing',
            number: 'TTG-8801',
            restaurantId: 'rest_gc',
            restaurantName: 'The Golden Crest Hotel',
            date: '2026-11-18',
            items: items,
            totalSell: 9600,
            totalBuy: 7200,
            profit: 2400,
          ),
        ],
        sync: false,
      );
      await vault.syncNow();

      final docket = StagingDocket(
        id: 'stg_1',
        ownerUserId: 'owner-1',
        clerkName: 'Daniel',
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        itemsJson: items,
        totalSell: 9600,
        status: 'pending',
      );
      supabase.stagedInvoices.add(docket.toJson());

      await vm.openReview(docket);
      expect(vm.reviewAuditState, ReviewAuditState.duplicate);
      expect(vm.canApproveActiveReview, isFalse);

      // Blocked until supplementary dispatch override is checked
      final blocked = await vm.approveActiveReview(
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        items: items,
        deliveryCost: 0,
        otherCost: 0,
      );
      expect(blocked, isA<ApprovalBlocked>());

      vm.setSupplementaryConfirmed(true);
      expect(vm.canApproveActiveReview, isTrue);

      final outcome = await vm.approveActiveReview(
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        items: const [
          InvoiceLineItem(
            desc: 'Roma Tomatoes',
            qty: 3,
            unit: 'crates',
            buyPrice: 2400,
            sellPrice: 3200,
            total: 9600,
          ),
        ],
        deliveryCost: 500,
        otherCost: 0,
      );

      expect(outcome, isA<ApprovalSuccess>());
      final approvedInv = (outcome as ApprovalSuccess).invoice;
      expect(approvedInv.sourceSubmissionId, 'stg_1');
      expect(approvedInv.profit, 1900); // 9600 - 7200 - 500
    });

    test('native Clerk Intake Mode pairs token, enforces duplicate gate, and submits',
        () async {
      await vm.pairWithInviteToken(
        'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk.html#invite=${supabase.activeInviteToken}',
      );
      expect(vm.hasClerkInvite, isTrue);
      expect(vm.inviteOwnerName, 'Veronica');

      const items = [
        InvoiceLineItem(
          desc: 'Red Onions',
          qty: 50,
          unit: 'kgs',
          buyPrice: 0,
          sellPrice: 155,
          total: 7750,
        ),
      ];

      final first = await vm.submitClerkDocket(
        clerkName: 'Faith Muthoni',
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        items: items,
        deliveryCost: 300,
        otherCost: 0,
        notes: 'Morning drop',
        receiptPhotos: const [],
      );
      expect(first.isSuccess, isTrue);
      expect(vm.clerkHistory.length, 1);

      // Submitting an identical docket triggers duplicate gate
      final dup = await vm.submitClerkDocket(
        clerkName: 'Faith Muthoni',
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        items: items,
        deliveryCost: 300,
        otherCost: 0,
        notes: 'Accidental double tap',
        receiptPhotos: const [],
      );
      expect(dup.isDuplicate, isTrue);

      // Bypassing as supplementary dispatch succeeds
      final second = await vm.submitClerkDocket(
        clerkName: 'Faith Muthoni',
        restaurantName: 'The Golden Crest Hotel',
        invoiceDate: '2026-11-18',
        items: items,
        deliveryCost: 300,
        otherCost: 0,
        notes: '[Supplementary Dispatch #2]',
        receiptPhotos: const [],
        bypassDuplicateCheck: true,
      );
      expect(second.isSuccess, isTrue);
      expect(vm.clerkHistory.length, 2);
    });
  });

  group('Scanner & Clerk Widget tests', () {
    testWidgets('DocketScannerSheet parses CSV and invokes callback',
        (tester) async {
      List<InvoiceLineItem> applied = [];
      final ocr = OcrConsensusService(
        imagePicker: _FakeImagePicker(
          cameraFile: XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'c.jpg'),
          galleryFiles: [
            XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'd.jpg'),
          ],
        ),
      );
      expect(await ocr.pickCameraPage(), isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DocketScannerSheet(
              ocrService: ocr,
              mode: ScannerTargetMode.csvImport,
              onApplyCsvItems: (items) => applied = items,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Load Sample'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('Parsed 3 Line Item(s)'), findsOneWidget);

      await tester.tap(find.text('Apply Items'));
      await tester.pumpAndSettle();

      expect(applied.length, 3);
      expect(applied.first.desc, 'Red Onions (Medium)');
    });

    testWidgets(
        'ClerkSubmissionsScreen displays tabs and ClerkPortalScreen pairs and quick-adds',
        (tester) async {
      final storage = _InMemoryLocalStorageService();
      final supabase = _ClerkFakeSupabaseGateway()
        ..user = const AuthUserInfo(
          id: 'owner-1',
          email: 'veronica@towntreasure.test',
        );
      await storage.setUserId('owner-1');
      final crypto = CryptoService();
      final vault = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
      );
      final staging = StagingRepository(
        supabase: supabase,
        localStorage: storage,
        vaultRepository: vault,
      );

      supabase.stagedInvoices.add({
        'id': 'stg_pending_1',
        'owner_user_id': 'owner-1',
        'clerk_name': 'Daniel Ochieng',
        'restaurant_name': 'Sankara Suites',
        'invoice_date': '2026-11-18',
        'items_json': [
          {
            'desc': 'Baby Spinach',
            'qty': 20,
            'unit': 'bundles',
            'buyPrice': 30,
            'sellPrice': 50,
            'total': 1000,
          },
        ],
        'total_sell': 1000,
        'status': 'pending',
      });

      final vm = ClerkViewModel(
        stagingRepository: staging,
        vaultRepository: vault,
        supabase: supabase,
        localStorage: storage,
        ocrService: OcrConsensusService(),
        duplicateDetector: DuplicateDetectorService(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: ClerkSubmissionsScreen(viewModel: vm),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clerk Docket Submissions'), findsOneWidget);
      expect(find.text('Sankara Suites'), findsOneWidget);
      expect(find.text('Pending (1)'), findsOneWidget);

      await tester.tap(find.text('Open Clerk Portal'));
      await tester.pumpAndSettle();

      expect(find.text('Clerk Intake Portal'), findsOneWidget);
      expect(find.text('Generate & Pair My Invite'), findsOneWidget);

      await tester.tap(find.text('Generate & Pair My Invite'));
      await tester.pumpAndSettle();

      expect(find.text('Submitting directly to: Veronica'), findsOneWidget);

      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).last),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Red Onions'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Red Onions'));
      await tester.pumpAndSettle();

      expect(find.text('Red Onions'), findsWidgets);

      await storage.close();
      vault.dispose();
    });
  });
}
