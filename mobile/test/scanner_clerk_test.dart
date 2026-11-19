import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

class _FakePaddleOcrGateway implements PaddleOcrGateway {
  _FakePaddleOcrGateway(this.boxes);
  final List<OcrTextBox> boxes;

  @override
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath) async => boxes;

  @override
  Future<void> close() async {}
}

class _FakeSpatialTextRecognizer
    implements OcrTextRecognizerGateway, OcrSpatialRecognizerGateway {
  _FakeSpatialTextRecognizer(this.boxes);
  final List<OcrTextBox> boxes;

  @override
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath) async => boxes;

  @override
  Future<String> recognizeTextFromFile(String filePath) async => '';

  @override
  Future<void> close() async {}
}

OcrTextBox _skewedBox(
  String text,
  double x,
  double y,
  double w,
  double h, {
  double angleDeg = -11.3,
  double confidence = 0.98,
}) {
  final rad = angleDeg * math.pi / 180.0;
  final dx = x - 450.0;
  final dy = y - 600.0;
  final cx = 450.0 + dx * math.cos(rad) - dy * math.sin(rad);
  final cy = 600.0 + dx * math.sin(rad) + dy * math.cos(rad);
  return OcrTextBox(
    text: text,
    confidence: confidence,
    centerX: cx,
    centerY: cy,
    width: w,
    height: h,
    angle: angleDeg,
    left: cx - w / 2,
    top: cy - h / 2,
    right: cx + w / 2,
    bottom: cy + h / 2,
  );
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

    test(
        'Offline PaddleOCR PP-OCRv5 + SpatialOcrParser reconstructs -11.3deg skewed handwritten docket and fails fast when offline',
        () async {
      var httpCalls = 0;
      final offlineHttp = MockClient((request) async {
        httpCalls++;
        throw const SocketException('Network unreachable');
      });

      // Simulated -11.3deg rotated boxes matching offline PP-OCRv5 ONNX detections
      // on test_samples/skewed_handwritten_docket.jpg (including border-digit '115' & 'baqs').
      final rotatedBoxes = <OcrTextBox>[
        _skewedBox('TOWN TRFASURE GROCERIES', 450, 120, 420, 34, confidence: 0.95),
        _skewedBox('DELIVERY DOCKET # TTG-409', 440, 180, 380, 30, confidence: 0.99),
        _skewedBox('Client: Kempinski Hotel', 260, 250, 310, 28, confidence: 0.99),
        _skewedBox('Date: 19/11/2026.', 690, 250, 220, 28, confidence: 0.95),
        _skewedBox('ITEM DESCRIPTION', 200, 340, 220, 24, confidence: 1.00),
        _skewedBox('QTY', 450, 340, 90, 24, confidence: 1.00),
        _skewedBox('UNIT PRICE', 600, 340, 140, 24, confidence: 0.99),
        _skewedBox('TOTAL', 760, 340, 110, 24, confidence: 1.00),
        _skewedBox('Roma Tomatoes', 200, 410, 210, 26, confidence: 0.97),
        _skewedBox('4 crates', 450, 410, 110, 26, confidence: 0.98),
        _skewedBox('3200', 600, 410, 90, 26, confidence: 1.00),
        _skewedBox('12800', 760, 410, 100, 26, confidence: 0.99),
        _skewedBox('Red Onions', 200, 480, 180, 26, confidence: 0.99),
        _skewedBox('3 baqs', 450, 480, 100, 26, confidence: 0.95),
        _skewedBox('4500', 600, 480, 90, 26, confidence: 1.00),
        _skewedBox('13500', 760, 480, 100, 26, confidence: 0.99),
        _skewedBox('Shangi Potatoes', 200, 550, 220, 26, confidence: 0.98),
        _skewedBox('2 bags', 450, 550, 100, 26, confidence: 0.87),
        _skewedBox('3800', 600, 550, 90, 26, confidence: 1.00),
        _skewedBox('7600', 760, 550, 95, 26, confidence: 1.00),
        _skewedBox('Dhania', 200, 620, 130, 26, confidence: 1.00),
        _skewedBox('115 bunches', 450, 620, 140, 26, confidence: 0.96),
        _skewedBox('40', 600, 620, 60, 26, confidence: 1.00),
        _skewedBox('600', 760, 620, 75, 26, confidence: 1.00),
        _skewedBox('Sweet Capsicum', 200, 690, 220, 26, confidence: 0.98),
        _skewedBox('10 kgs', 450, 690, 100, 26, confidence: 0.93),
        _skewedBox('180', 600, 690, 75, 26, confidence: 0.99),
        _skewedBox('1800', 760, 690, 95, 26, confidence: 0.97),
        _skewedBox('Delivery:', 600, 780, 120, 26, confidence: 1.00),
        _skewedBox('500', 760, 780, 75, 26, confidence: 0.98),
        _skewedBox('Grand Total: KES 36.800', 620, 850, 310, 30, confidence: 0.95),
      ];

      final service = OcrConsensusService(
        httpClient: offlineHttp,
        geminiApiKey: 'fake-key-offline-test',
        paddleOcr: _FakePaddleOcrGateway(rotatedBoxes),
        textRecognizer: _FakeTextRecognizer([]),
      );

      final result = await service.processDocket([
        OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,${base64Encode([1, 2, 3, 4])}',
          filePath: 'skewed_handwritten_docket.jpg',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        ),
      ]);

      // Fails fast after 1st SocketException instead of blocking through all models.
      expect(httpCalls, 1);
      expect(result.enginesUsed, contains('PaddleOCR PP-OCRv5 ONNX (Offline)'));
      expect(result.restaurantName, 'Kempinski Hotel');
      expect(result.invoiceNumber, 'TTG-409');
      expect(result.date, '2026-11-19');
      expect(result.items.length, 5);

      final roma = result.items[0];
      expect(roma.desc, 'Roma Tomatoes');
      expect(roma.qty, 4);
      expect(roma.unit, 'crates');
      expect(roma.sellPrice, 3200);
      expect(roma.total, 12800);

      final redOnions = result.items[1];
      expect(redOnions.desc, 'Red Onions');
      expect(redOnions.qty, 3);
      expect(redOnions.unit, 'bags');
      expect(redOnions.sellPrice, 4500);
      expect(redOnions.total, 13500);

      final potatoes = result.items[2];
      expect(potatoes.qty, 2);
      expect(potatoes.unit, 'bags');

      final dhania = result.items[3];
      expect(dhania.desc, 'Dhania');
      expect(dhania.qty, 15);
      expect(dhania.unit, 'bunches');
      expect(dhania.sellPrice, 40);
      expect(dhania.total, 600);

      final capsicum = result.items[4];
      expect(capsicum.qty, 10);
      expect(capsicum.unit, 'kgs');

      expect(result.deliveryCost, 500);
      expect(result.grandTotal, 36800);
      service.dispose();
    });

    test(
        'Tier 3 ML Kit 2D Spatial redundancy activates when PaddleOCR returns empty boxes',
        () async {
      final mlKitBoxes = <OcrTextBox>[
        _skewedBox('Client: Sankara Suites', 240, 180, 260, 26, angleDeg: 0),
        _skewedBox('Date: 18/10/2026', 640, 180, 200, 26, angleDeg: 0),
        _skewedBox('Baby Spinach', 180, 300, 180, 24, angleDeg: 0),
        _skewedBox('12 kgs', 420, 300, 90, 24, angleDeg: 0),
        _skewedBox('90', 580, 300, 60, 24, angleDeg: 0),
        _skewedBox('1080', 740, 300, 90, 24, angleDeg: 0),
      ];

      final service = OcrConsensusService(
        geminiApiKey: '',
        paddleOcr: _FakePaddleOcrGateway(const []),
        textRecognizer: _FakeSpatialTextRecognizer(mlKitBoxes),
      );

      final result = await service.processDocket([
        OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,${base64Encode([1, 2, 3])}',
          filePath: 'docket_sankara_suites.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]);

      expect(
        result.enginesUsed,
        contains('Google ML Kit On-Device'),
      );
      expect(result.restaurantName, 'Sankara Suites');
      expect(result.date, '2026-10-18');
      expect(result.items.length, 1);
      expect(result.items.first.desc, 'Baby Spinach');
      expect(result.items.first.qty, 12);
      expect(result.items.first.sellPrice, 90);
      expect(result.items.first.total, 1080);
      service.dispose();
    });

    test(
        'SpatialOcrParser and reconcileWithMath strip serial numbers and embedded KSh rates from descriptions',
        () async {
      // Mirrors the TTG-ZCNG Hilton Garden Inn regression where serial numbers (01..05)
      // and unit rates (KSh 15.00 .. KSh 50.00 / kgs) leaked into item descriptions.
      final tableBoxes = <OcrTextBox>[
        _skewedBox('Receipt No: TTG-ZCNG', 650, 120, 260, 26, angleDeg: 0),
        _skewedBox('Order Date: 19/11/2026', 650, 160, 250, 24, angleDeg: 0),
        _skewedBox('BILLED TO:', 640, 210, 130, 22, angleDeg: 0),
        _skewedBox('Hilton Garden Inn', 660, 245, 240, 26, angleDeg: 0),
        _skewedBox('#', 80, 310, 30, 22, angleDeg: 0),
        _skewedBox('ITEM', 220, 310, 100, 22, angleDeg: 0),
        _skewedBox('QTY', 500, 310, 80, 22, angleDeg: 0),
        _skewedBox('TOTAL', 720, 310, 100, 22, angleDeg: 0),
        // Separate Rate cell before Qty:
        _skewedBox('01', 80, 360, 36, 24, angleDeg: 0),
        _skewedBox('Dhania', 180, 360, 110, 24, angleDeg: 0),
        _skewedBox('KSh 15.00', 320, 360, 110, 24, angleDeg: 0),
        _skewedBox('50.0 kgs', 500, 360, 110, 24, angleDeg: 0),
        _skewedBox('KSh 750.00', 720, 360, 130, 24, angleDeg: 0),
        // Horizontally merged item + rate:
        _skewedBox('02', 80, 410, 36, 24, angleDeg: 0),
        _skewedBox('Parsley KSh 30.00', 220, 410, 210, 24, angleDeg: 0),
        _skewedBox('7.0 kgs', 500, 410, 100, 24, angleDeg: 0),
        _skewedBox('KSh 210.00', 720, 410, 130, 24, angleDeg: 0),
        // Merged serial + item + rate:
        _skewedBox('03 Cherry tomato KSh 100.00', 220, 460, 290, 24, angleDeg: 0),
        _skewedBox('2.0 kgs', 500, 460, 100, 24, angleDeg: 0),
        _skewedBox('KSh 200.00', 720, 460, 130, 24, angleDeg: 0),
        // Currency rate with slash unit subtitle:
        _skewedBox('04', 80, 510, 36, 24, angleDeg: 0),
        _skewedBox('Mushroom', 190, 510, 130, 24, angleDeg: 0),
        _skewedBox('KSh 350.00 / kgs', 340, 510, 150, 24, angleDeg: 0),
        _skewedBox('4.0 kgs', 500, 510, 100, 24, angleDeg: 0),
        _skewedBox('KSh 1,400.00', 720, 510, 140, 24, angleDeg: 0),
        // Double whitespace wrap case:
        _skewedBox('05', 80, 560, 36, 24, angleDeg: 0),
        _skewedBox('White Cabbage KSh 50.00', 230, 560, 260, 24, angleDeg: 0),
        _skewedBox('30.0 kgs', 500, 560, 110, 24, angleDeg: 0),
        _skewedBox('KSh 1,500.00', 720, 560, 140, 24, angleDeg: 0),
      ];

      final service = OcrConsensusService(
        geminiApiKey: '',
        paddleOcr: _FakePaddleOcrGateway(tableBoxes),
        textRecognizer: _FakeTextRecognizer([]),
      );

      final result = await service.processDocket([
        OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,${base64Encode([1, 2, 3])}',
          filePath: 'hilton_receipt.jpg',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]);

      expect(result.restaurantName, 'Hilton Garden Inn');
      expect(result.invoiceNumber, 'TTG-ZCNG');
      expect(result.date, '2026-11-19');
      expect(result.items.length, 5);
      expect(
        result.items.map((i) => i.desc).toList(),
        ['Dhania', 'Parsley', 'Cherry tomato', 'Mushroom', 'White Cabbage'],
      );
      expect(result.items[0].qty, 50);
      expect(result.items[0].sellPrice, 15);
      expect(result.items[0].total, 750);
      expect(result.items[3].sellPrice, 350);
      expect(result.items[3].total, 1400);

      // Also verify Gemini / Arbiter cleanup guard directly in reconcileWithMath:
      final arbitrated = OcrConsensusService.reconcileWithMath(
        geminiData: {
          'restaurant_name': 'Hilton Garden Inn',
          'invoice_number': 'TTG-ZCNG',
          'invoice_date': '2026-11-19',
          'items': [
            {
              'desc': '01 Dhania KSh 15.00',
              'qty': 50.0,
              'unit': 'kgs',
              'price': 0.0,
              'total': 750.0,
            },
            {
              'desc': '03 Cherry tomato KSh 100.00 / kgs',
              'qty': 2.0,
              'unit': 'kgs',
              'price': 100.0,
              'total': 200.0,
            },
          ],
        },
      );
      expect(arbitrated.items[0].desc, 'Dhania');
      expect(arbitrated.items[0].sellPrice, 15);
      expect(arbitrated.items[1].desc, 'Cherry tomato');

      service.dispose();
    });

    test(
        'Offline PP-OCRv5 boxes from Invoice_TTG-A8ESK6_The_Golden_Crest_Hotel.pdf parse exact items, split header, text date, and European/spaced decimals',
        () async {
      OcrTextBox pdfBox(
        String text,
        double cx,
        double cy,
        double w,
        double h,
      ) =>
          OcrTextBox(
            text: text,
            confidence: 0.96,
            centerX: cx,
            centerY: cy,
            width: w,
            height: h,
            angle: 0,
            left: cx - w / 2,
            top: cy - h / 2,
            right: cx + w / 2,
            bottom: cy + h / 2,
          );

      // Exact boxes extracted offline by PP-OCRv5 ONNX from the uploaded PDF
      final pdfOcrBoxes = <OcrTextBox>[
        pdfBox('INVOICE', 233.8, 373.9, 281.1, 33.2),
        pdfBox('Receipt No:', 1133.4, 364.0, 153.8, 15.0),
        pdfBox('TTG-A8ESK6', 1310.6, 364.0, 167.3, 14.8),
        pdfBox('Order Date:', 1133.4, 403.5, 149.3, 15.0),
        pdfBox('12 May 2026', 1316.1, 403.0, 158.2, 16.9),
        pdfBox('FROM:', 139.6, 501.6, 96.4, 21.1),
        pdfBox('BILLED TO:', 1317.3, 502.1, 149.3, 15.0),
        pdfBox('Town Treasure Limited', 248.2, 546.0, 310.9, 16.5),
        pdfBox('The Golden Crest Hotel', 1236.4, 546.0, 312.2, 14.0),
        pdfBox('SL.', 142.9, 786.1, 64.4, 58.2),
        pdfBox('ITEM DESCRIPTION', 336.8, 786.1, 233.5, 11.8),
        pdfBox('UNIT PRICE', 682.5, 785.0, 147.1, 15.1),
        pdfBox('QUANTITY', 936.2, 785.0, 131.3, 15.3),
        pdfBox('TOTAL', 1158.8, 785.0, 88.0, 16.3),
        pdfBox('01', 148.5, 877.1, 40.3, 26.6),
        pdfBox('Yellow beans', 294.7, 877.1, 151.6, 15.0),
        pdfBox('KSh 150.00', 766.7, 877.1, 138.1, 15.2),
        pdfBox('120 kgs', 973.8, 878.2, 99.1, 21.0),
        pdfBox('KSh 18.000,00', 1285.1, 877.1, 169.5, 14.8),
        pdfBox('02', 149.6, 954.9, 43.8, 30.0),
        pdfBox('Onions', 261.5, 954.9, 90.2, 19.5),
        pdfBox('KSh 135.00', 766.7, 953.8, 138.1, 15.2),
        pdfBox('70 kgs', 973.8, 955.5, 91.2, 24.2),
        pdfBox('KSh 9.450.00', 1291.8, 953.8, 156.1, 14.9),
        pdfBox('03', 148.5, 1031.7, 40.7, 30.2),
        pdfBox('Potatoes', 270.4, 1033.0, 107.9, 17.3),
        pdfBox('KSh 100.00', 765.5, 1030.6, 135.8, 15.2),
        pdfBox('120 kgs', 974.9, 1032.5, 101.5, 21.5),
        pdfBox('KSh 12.000 00', 1285.1, 1030.6, 169.5, 14.8),
        pdfBox('04', 149.6, 1108.4, 36.8, 23.2),
        pdfBox('Rice', 248.2, 1108.4, 61.1, 21.2),
        pdfBox('KSh 110.00', 765.6, 1108.1, 137.2, 16.4),
        pdfBox('134 kgs', 974.0, 1109.7, 100.0, 22.6),
        pdfBox('KSh 14 740 00', 1285.1, 1108.4, 166.6, 12.1),
        pdfBox('Town re', 448.5, 1217.7, 529.5, 60.5),
        pdfBox('Sub Total:', 991.6, 1235.6, 129.4, 18.3),
        pdfBox('KSh 54.190.00', 1282.9, 1234.5, 169.5, 14.8),
        pdfBox('Grand Total:', 979.4, 1304.7, 151.6, 15.0),
        pdfBox('KSh 54.190.00', 1284.0, 1302.5, 171.8, 14.8),
        pdfBox('DATE: 14 MaV 2026', 1212.0, 1777.2, 188.9, 12.0),
        pdfBox('Thank vou, The Golden Crest Hotel, for Shopping with us',
            387.8, 2058.4, 577.7, 13.1),
      ];

      final service = OcrConsensusService(
        geminiApiKey: '',
        paddleOcr: _FakePaddleOcrGateway(pdfOcrBoxes),
        textRecognizer: _FakeTextRecognizer([]),
      );

      final result = await service.processDocket([
        OcrImagePage(
          dataUrl: 'data:image/jpeg;base64,${base64Encode([1, 2, 3])}',
          filePath: 'Invoice_TTG-A8ESK6_The_Golden_Crest_Hotel.png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      ]);

      expect(result.restaurantName, 'The Golden Crest Hotel');
      expect(result.invoiceNumber, 'TTG-A8ESK6');
      expect(result.date, '2026-05-12');
      expect(result.items.length, 4);
      expect(
        result.items.map((i) => i.desc).toList(),
        ['Yellow beans', 'Onions', 'Potatoes', 'Rice'],
      );
      expect(result.items.map((i) => i.qty).toList(), [120, 70, 120, 134]);
      expect(result.items.map((i) => i.sellPrice).toList(), [150, 135, 100, 110]);
      expect(result.items.map((i) => i.total).toList(),
          [18000, 9450, 12000, 14740]);
      expect(result.subtotal, 54190);
      expect(result.grandTotal, 54190);
      service.dispose();
    });
  });
}
