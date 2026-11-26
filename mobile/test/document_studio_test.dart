import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/ocr_consensus_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/stamp_signature_helper.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/documents/branded_document_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/documents/document_ocr_converter.dart';
import 'package:town_treasure_groceries/ui/features/documents/document_studio_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_detail_screen.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/reports/reports_view_model.dart';
import 'package:town_treasure_groceries/ui/features/reports/statement_pdf_builder.dart';

import 'test_fakes.dart';

class _MemStorage extends LocalStorageService {
  _MemStorage() : super(secureStore: InMemorySecureKeyStore());

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
    _kv.clear();
  }

  @override
  Future<void> clearAllOnSignOut() async {
    _kv.clear();
    await clearAuthMetadata();
  }

  @override
  Future<void> close() async {}
}

String _extractPdfTextStreams(Uint8List pdfBytes) {
  final rawLatin = latin1.decode(pdfBytes);
  final buf = StringBuffer(rawLatin);
  final streamRegex = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
  final tjArrayRegex = RegExp(r'\[((?:\([^\)]*\)|-?\d+(?:\.\d+)?|\s)+)\]\s*TJ');
  final literalParenRegex = RegExp(r'\(([^\)]*)\)');
  for (final m in streamRegex.allMatches(rawLatin)) {
    final chunk = latin1.encode(m.group(1)!);
    try {
      final inflated = zlib.decode(chunk);
      final decoded = latin1.decode(inflated, allowInvalid: true);
      buf.write('\n');
      buf.write(decoded);
      for (final tj in tjArrayRegex.allMatches(decoded)) {
        final joined = literalParenRegex
            .allMatches(tj.group(1)!)
            .map((p) => p.group(1)!)
            .join();
        buf.write('\n$joined');
      }
    } catch (_) {}
  }
  return buf.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BrandedDocument model, inline parser, Vault merge & PDF Builder', () {
    test('BrandedInlineParser parses and toggles bold, italic, and underline spans',
        () {
      final spans = BrandedInlineParser.parse(
        'Supply of **Fresh Tomatoes**, *Baby Spinach*, and __Sweet Capsicum__.',
      );
      expect(spans.any((s) => s.text == 'Fresh Tomatoes' && s.bold), isTrue);
      expect(spans.any((s) => s.text == 'Baby Spinach' && s.italic), isTrue);
      expect(
        spans.any((s) => s.text == 'Sweet Capsicum' && s.underline),
        isTrue,
      );

      const initial = TextEditingValue(
        text: 'Total KES 15,000',
        selection: TextSelection(baseOffset: 6, extentOffset: 16),
      );
      final bolded = BrandedInlineParser.toggleSelectionMarker(initial, '**');
      expect(bolded.text, 'Total **KES 15,000**');
      expect(
        bolded.text.substring(bolded.selection.start, bolded.selection.end),
        'KES 15,000',
      );

      final unbolded = BrandedInlineParser.toggleSelectionMarker(bolded, '**');
      expect(unbolded.text, 'Total KES 15,000');

      // Runs of 3+ underscores must stay verbatim and never underline adjacent labels
      final fillInSpans = BrandedInlineParser.parse(
        '**Dispatched By:** ________________________    **Received By (Name & Stamp):** ________________________\n**Receiver Signature:** ________________________    **Arrival Time:** _______________',
      );
      expect(
        fillInSpans.any((s) => s.text == '________________________' && !s.underline),
        isTrue,
      );
      expect(
        fillInSpans
            .where((s) => s.text.contains('Received By') || s.text.contains('Arrival Time'))
            .every((s) => !s.underline),
        isTrue,
      );
    });

    test(
        'Delivery Note signatory grid upgrades legacy underscore paragraphs and StampSignatureHelper tight-crops stamp & signature',
        () async {
      // 1. Legacy saved Delivery Note paragraph auto-upgrades to signatory grid in PDF
      final legacyDn = BrandedDocument(
        id: 'dn_legacy_weston',
        title: 'Delivery Note - Weston Hotel',
        documentType: 'DELIVERY NOTE',
        referenceNumber: 'DN-TTG-C0XI',
        date: '2026-10-30',
        stampCaption: 'DISPATCHED',
        blocks: const [
          BrandedDocBlock(
            id: 'b_legacy_sig',
            kind: 'paragraph',
            text:
                '**Dispatched By:** ________________________    **Received By (Name & Stamp):** ________________________\n**Receiver Signature:** ________________________    **Arrival Time:** _______________',
          ),
        ],
      );
      expect(legacyDn.blocks.single.isLegacySignatoryParagraph, isTrue);
      expect(legacyDn.blocks.single.isSignatory, isTrue);

      final pdfBytes = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: legacyDn,
      );
      final pdfText = _extractPdfTextStreams(pdfBytes);
      expect(pdfText, contains('DISPATCH'));
      expect(pdfText, contains('RECEIVING'));
      expect(pdfText, contains('SIGNATORY'));
      expect(pdfText, contains('Dispatcher'));
      expect(pdfText, contains('Receiver'));
      expect(pdfText, contains('Arrival'));
      expect(pdfText, contains('Official'));
      expect(pdfText, contains('AUTHORIZED'));

      // 2. Padded 200x200 stamp PNG trims down tightly around central emblem
      final rawStamp = img.Image(width: 200, height: 200, numChannels: 4);
      for (var y = 70; y <= 130; y++) {
        for (var x = 40; x <= 160; x++) {
          rawStamp.setPixelRgba(x, y, 25, 75, 45, 255);
        }
      }
      final trimmedStampBytes = StampSignatureHelper.prepareStampPng(
        Uint8List.fromList(img.encodePng(rawStamp)),
      )!;
      final trimmedStamp = img.decodePng(trimmedStampBytes)!;
      expect(trimmedStamp.width, lessThan(145));
      expect(trimmedStamp.height, lessThan(85));

      // 3. Signature with wide empty canvas + isolated corner noise speck crops tightly around ink
      final rawSig = img.Image(width: 300, height: 220, numChannels: 4);
      rawSig.setPixelRgba(5, 5, 10, 20, 120, 255); // isolated dust speck
      for (var y = 100; y <= 118; y++) {
        for (var x = 110; x <= 190; x++) {
          rawSig.setPixelRgba(x, y, 10, 20, 120, 255);
        }
      }
      final rawSigUri =
          'data:image/png;base64,${base64Encode(img.encodePng(rawSig))}';
      final enhancedSigBytes =
          StampSignatureHelper.prepareSignaturePng(rawSigUri)!;
      final enhancedSig = img.decodePng(enhancedSigBytes)!;
      expect(enhancedSig.width, lessThan(115));
      expect(enhancedSig.height, lessThan(50));
    });

    test(
        'scrubs internal clerk metadata & own supplier phone across schemas and keeps 32-item Delivery Note closing pack unbroken',
        () async {
      // 1. Restaurant.fromJson & WhatsApp helpers scrub internal clerk provenance & own phone
      final restFromVault = Restaurant.fromJson({
        'id': 'r_elysian',
        'name': 'Elysian Resort',
        'contact': 'Added from clerk approval',
        'phone': '0708567696',
        'address': 'PX62+Q44, Eastern Bypass',
      });
      expect(restFromVault.contact, isEmpty);

      const sampleInv = Invoice(
        id: 'inv_6182',
        number: 'TTG-6182',
        restaurantId: 'r_elysian',
        restaurantName: 'Elysian Resort',
        date: '2026-11-07',
        totalSell: 45000,
        notes:
            '[Supplementary Dispatch #2] Gate B kitchen [Submitted by Clerk: Peter]',
      );
      expect(
        Invoice.sanitizeExternalNotes(sampleInv.notes),
        'Gate B kitchen',
      );

      final waSummary = InvoicePdfBuilder.buildWhatsAppSummaryText(
        invoice: sampleInv,
        restaurant: restFromVault,
      );
      expect(waSummary, startsWith('Hello Elysian Resort,'));
      expect(waSummary, isNot(contains('clerk')));
      expect(InvoicePdfBuilder.normalizeKenyaPhone('0708567696'), isEmpty);
      expect(
        ReportsViewModel.normalizeKenyanWhatsAppPhone('+254 708 567 696'),
        isEmpty,
      );
      expect(
        ReportsViewModel.buildStatementWhatsAppText(
          restFromVault,
          'November 2026',
        ),
        startsWith('Hello Elysian Resort,'),
      );

      // 2. Existing saved BrandedDocument with leaked contact + 32 items renders 3 clean pages
      final items32 = List<SelectableDocItem>.generate(
        32,
        (i) => SelectableDocItem(
          id: 'item_$i',
          desc: 'Fresh Produce Item ${i + 1}',
          orderedQty: 10,
          dispatchedQty: 10,
          unit: 'Kgs',
          sellPrice: 0,
        ),
      );
      final blocks32 = DocumentOcrConverter.buildBlocksForItems(
        mode: DocSmartConversionMode.deliveryNote,
        activeItems: items32,
        sourceReference: 'TTG-6182',
      );
      final savedDocJson = {
        'id': 'dn_elysian',
        'title': 'Delivery Note - Elysian Resort',
        'documentType': 'DELIVERY NOTE',
        'referenceNumber': 'DN-TTG-6182',
        'date': '2026-11-07',
        'recipientName': 'Elysian Resort',
        'recipientContact': 'Added from clerk approval',
        'recipientAddress': 'PX62+Q44, Eastern Bypass',
        'recipientPhone': '0708567696',
        'subject': 'GOODS DISPATCHED (ORDER / REF: TTG-6182)',
        'showKraPin': false,
        'stampCaption': 'DISPATCHED',
        'blocks': blocks32.map((b) => b.toJson()).toList(),
      };

      final reloadedDoc = BrandedDocument.fromJson(savedDocJson);
      expect(reloadedDoc.recipientContact, isEmpty);
      expect(reloadedDoc.recipientPhone, isEmpty);

      final pdf32Bytes = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: reloadedDoc.copyWith(
          footerNote: 'Town Treasure Limited | Hospitality Supply | Nairobi',
        ),
      );
      final pdf32Text = _extractPdfTextStreams(pdf32Bytes);
      expect(pdf32Text, isNot(contains('clerk')));
      expect(pdf32Text, isNot(contains('0708567696')));
      expect(pdf32Text, contains('/Count 3'));
      expect(pdf32Text, contains('DISPATCHED'));
      expect(pdf32Text, contains('Official'));
    });

    test('saves, deletes, and merges BrandedDocuments in VaultRepository',
        () async {
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: _MemStorage(),
        supabase: FakeSupabaseGateway(),
        syncDebounceDuration: const Duration(milliseconds: 20),
      );
      addTearDown(vault.dispose);

      final quote = BrandedDocument.fromTemplate(
        BrandedDocTemplate.quotation,
        refNumber: 'TTG-DOC-TEST-01',
        dateIso: '2026-11-24',
      );
      await vault.saveBrandedDocument(quote, sync: false);
      expect(vault.brandedDocuments.length, 1);
      expect(vault.brandedDocuments.first.referenceNumber, 'TTG-DOC-TEST-01');

      // Timestamp conflict resolution across devices
      final olderRemote = const VaultSettings().withBrandedDocuments([
        quote.copyWith(
          title: 'Older Remote Title',
          updatedAt: '2026-11-20T10:00:00Z',
        ),
      ]);
      final newerLocal = const VaultSettings().withBrandedDocuments([
        quote.copyWith(
          title: 'Newer Local Title',
          updatedAt: '2026-11-24T12:00:00Z',
        ),
      ]);
      final merged =
          VaultRepository.mergeSettingsByTimestamp(newerLocal, olderRemote);
      expect(merged.brandedDocuments.single.title, 'Newer Local Title');

      await vault.deleteBrandedDocument(quote.id, sync: false);
      expect(vault.brandedDocuments, isEmpty);
    });

    test('BrandedDocumentPdfBuilder generates valid A4 & Letter PDFs with tables and signature',
        () async {
      const tinyPngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      final doc = BrandedDocument.fromTemplate(
        BrandedDocTemplate.quotation,
        refNumber: 'TTG-DOC-PDF-01',
        dateIso: '2026-11-24',
      ).copyWith(
        recipientName: 'Fairmont The Norfolk',
        recipientContact: 'Executive Chef',
        recipientKraPin: 'P051234567X',
      );

      final a4Bytes = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: doc,
        settings: const VaultSettings(
          signature: 'data:image/png;base64,$tinyPngBase64',
        ),
      );
      expect(a4Bytes.length, greaterThan(1000));
      expect(utf8.decode(a4Bytes.take(5).toList()), '%PDF-');

      final letterBytes = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: doc.copyWith(pageSize: 'letter', defaultFontFamily: 'serif'),
        pageFormatOverride: PdfPageFormat.letter,
      );
      expect(letterBytes.length, greaterThan(1000));
      expect(utf8.decode(letterBytes.take(5).toList()), '%PDF-');
    });

    testWidgets(
        'DocumentStudioScreen creates Business Letter from template and applies MS Word ribbon operations',
        (tester) async {
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: _MemStorage(),
        supabase: FakeSupabaseGateway(),
        syncDebounceDuration: const Duration(milliseconds: 20),
      );
      addTearDown(vault.dispose);
      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Hemingways Nairobi',
          contact: 'Chef Jean',
          kraPin: 'P051999888Z',
        ),
      ], sync: false);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: DocumentStudioScreen(vault: vault),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Branded Document Studio'), findsOneWidget);

      // Tap Business Letter template -> opens BrandedDocumentEditorScreen
      await tester.tap(find.byKey(const Key('tpl_business_letter')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('branded_doc_a4_canvas')), findsOneWidget);
      expect(find.byKey(const Key('ribbon_tab_home')), findsOneWidget);
      expect(find.byKey(const Key('ribbon_tab_insert')), findsOneWidget);
      expect(find.byKey(const Key('ribbon_tab_layout')), findsOneWidget);
      expect(find.byKey(const Key('ribbon_tab_brand')), findsOneWidget);

      // Edit document title & toggle Italic + Center alignment on active block
      await tester.enterText(
        find.byKey(const Key('field_doc_title')),
        'Annual Produce Supply Agreement',
      );
      await tester.tap(find.byKey(const Key('btn_ribbon_italic')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_ribbon_align_center')));
      await tester.pump();

      // Switch to Insert tab and insert a Table
      await tester.tap(find.byKey(const Key('ribbon_tab_insert')));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('btn_insert_table'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_insert_table')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_insert_table')));
      await tester.pumpAndSettle();

      // Save explicitly and verify persisted blocks & formatting
      await tester.tap(find.byKey(const Key('btn_doc_save')));
      await tester.pumpAndSettle();

      expect(vault.brandedDocuments.length, 1);
      final saved = vault.brandedDocuments.first;
      expect(saved.title, 'Annual Produce Supply Agreement');
      expect(saved.blocks.first.italic, isTrue);
      expect(saved.blocks.first.align, 'center');
      expect(saved.blocks.any((b) => b.isTable), isTrue);
    });
  });

  group('v1.2.7 Smart OCR Delivery Note Filter, LPO Price Hydration & KRA PIN Toggles',
      () {
    test(
        'DocumentOcrConverter strips leaked prices and excludes non-goods fee rows on Delivery Notes while hydrating LPO prices on Quotations',
        () async {
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: _MemStorage(),
        supabase: FakeSupabaseGateway(),
        syncDebounceDuration: const Duration(milliseconds: 20),
      );
      addTearDown(vault.dispose);

      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Serena Hotel',
          kraPin: 'P051234567X',
        ),
      ], sync: false);
      await vault.setPriceLists([
        const PriceList(
          id: 'pl1',
          name: 'Hospitality Catalog',
          items: [
            PriceListItem(
              id: 'p1',
              name: 'Roma Tomatoes',
              unit: 'kgs',
              price: 135,
            ),
            PriceListItem(
              id: 'p2',
              name: 'English Cucumbers',
              unit: 'kgs',
              price: 95,
            ),
          ],
        ),
      ], sync: false);

      const scannedInvoiceLines = [
        InvoiceLineItem(
          desc: '01. Fresh Tomato @ KSh 120/kg',
          qty: 25,
          unit: 'kgs',
          buyPrice: 80,
          sellPrice: 120,
          total: 3000,
        ),
        InvoiceLineItem(
          desc: '2) English Cucumber - KES 95.00',
          qty: 10,
          unit: 'kgs',
          buyPrice: 60,
          sellPrice: 95,
          total: 950,
        ),
        InvoiceLineItem(
          desc: 'Delivery Fee',
          qty: 1,
          unit: 'pcs',
          buyPrice: 0,
          sellPrice: 350,
          total: 350,
        ),
        InvoiceLineItem(
          desc: 'Transport Charge',
          qty: 1,
          unit: 'pcs',
          buyPrice: 0,
          sellPrice: 200,
          total: 200,
        ),
      ];

      final dnStaged = DocumentOcrConverter.prepareSelectableItems(
        sourceItems: scannedInvoiceLines,
        mode: DocSmartConversionMode.deliveryNote,
        vault: vault,
        matchedRestaurant: vault.restaurants.first,
      );

      // Physical goods selected & cleaned of price tokens; fee rows automatically unchecked!
      expect(dnStaged.length, 4);
      expect(dnStaged[0].selected, isTrue);
      expect(dnStaged[0].desc, 'Fresh Tomato');
      expect(dnStaged[0].sellPrice, 0);
      expect(dnStaged[1].selected, isTrue);
      expect(dnStaged[1].desc, 'English Cucumber');
      expect(dnStaged[2].selected, isFalse);
      expect(dnStaged[3].selected, isFalse);

      final dnDoc = DocumentOcrConverter.buildDocumentFromItems(
        mode: DocSmartConversionMode.deliveryNote,
        items: dnStaged,
        vault: vault,
        matchedRestaurant: vault.restaurants.first,
        sourceReference: 'TTG-8842',
      );
      expect(dnDoc.documentType, 'DELIVERY NOTE');
      expect(dnDoc.showKraPin, isFalse); // Default off for Delivery Notes
      final tableBlock = dnDoc.blocks.firstWhere((b) => b.isTable);
      expect(tableBlock.tableRows.length, 3); // Header + 2 physical items ONLY
      final flatTableText =
          tableBlock.tableRows.expand((r) => r).join(' ').toLowerCase();
      expect(flatTableText, isNot(contains('delivery fee')));
      expect(flatTableText, isNot(contains('transport')));
      expect(flatTableText, isNot(contains('3,000')));
      expect(flatTableText, isNot(contains('120')));

      // Unpriced LPO scanned into Quotation -> auto-hydrates prices from Vault PriceList!
      const unpricedLpoLines = [
        InvoiceLineItem(
          desc: 'Tomato',
          qty: 20,
          unit: 'kgs',
          buyPrice: 0,
          sellPrice: 0,
          total: 0,
        ),
        InvoiceLineItem(
          desc: 'Cucumber',
          qty: 15,
          unit: 'kgs',
          buyPrice: 0,
          sellPrice: 0,
          total: 0,
        ),
      ];
      final quoteStaged = DocumentOcrConverter.prepareSelectableItems(
        sourceItems: unpricedLpoLines,
        mode: DocSmartConversionMode.quotation,
        vault: vault,
      );
      expect(quoteStaged[0].sellPrice, 135);
      expect(quoteStaged[0].priceAutoFilledFromVault, isTrue);
      expect(quoteStaged[1].sellPrice, 95);
      expect(quoteStaged[1].priceAutoFilledFromVault, isTrue);
    });

    test('OcrConsensusService.parseRawTextToBrandedDoc reconstructs headings, subject, bullets & tables offline',
        () {
      const rawText = '''
SUPPLY ADVISORY NOTICE
Date: 26/11/2026
Ref: TTG-ADV-99
To: Villa Rosa Kempinski
RE: MORNING COLD-CHAIN DISPATCH SCHEDULE

Please note our updated holiday kitchen dispatch windows:
- First dispatch leaves at 5:30 AM daily
- Emergency top-up orders accepted until 11:00 AM

Window | Cutoff Time | Route
Morning | 20:00 HRS | Westlands & CBD
Midday | 11:00 HRS | Karen & Kilimani
''';

      final parsed = OcrConsensusService.parseRawTextToBrandedDoc(rawText);
      expect(parsed['documentType'], 'NOTICE');
      expect(parsed['date'], '2026-11-26');
      expect(parsed['referenceNumber'], 'TTG-ADV-99');
      expect(parsed['recipientName'], 'Villa Rosa Kempinski');
      expect(parsed['subject'], 'MORNING COLD-CHAIN DISPATCH SCHEDULE');

      final blocks = (parsed['blocks'] as List).cast<Map<String, dynamic>>();
      expect(blocks.any((b) => b['kind'] == 'bullet'), isTrue);
      expect(blocks.any((b) => b['kind'] == 'table'), isTrue);
    });

    test('showKraPin toggle cleanly includes or omits Seller & Client KRA PINs across Branded Docs, Invoices, and Statements PDFs',
        () async {
      final settingsWithPin = const VaultSettings().withKraProfile(
        const KraCompanyProfile(
          sellerKraPin: 'P051112223A',
          vatRegistered: false,
        ),
      );
      const client = Restaurant(
        id: 'r1',
        name: 'Sarova Panafric',
        kraPin: 'P059998887Z',
      );
      const inv = Invoice(
        id: 'inv1',
        number: 'TTG-7701',
        restaurantId: 'r1',
        restaurantName: 'Sarova Panafric',
        date: '2026-11-26',
        items: [
          InvoiceLineItem(
            desc: 'Carrots',
            qty: 10,
            unit: 'kgs',
            buyPrice: 50,
            sellPrice: 90,
            total: 900,
          ),
        ],
        totalSell: 900,
      );

      final invWithPin = await InvoicePdfBuilder.buildPdfBytes(
        invoice: inv,
        restaurant: client,
        settings: settingsWithPin,
        showKraPin: true,
      );
      final invNoPin = await InvoicePdfBuilder.buildPdfBytes(
        invoice: inv,
        restaurant: client,
        settings: settingsWithPin,
        showKraPin: false,
      );
      expect(_extractPdfTextStreams(invWithPin), contains('P059998887Z'));
      expect(_extractPdfTextStreams(invWithPin), contains('P051112223A'));
      expect(
        _extractPdfTextStreams(invNoPin),
        isNot(contains('P059998887Z')),
      );
      expect(
        _extractPdfTextStreams(invNoPin),
        isNot(contains('P051112223A')),
      );

      final brandedDoc = BrandedDocument.fromTemplate(
        BrandedDocTemplate.quotation,
        refNumber: 'TTG-Q-01',
        dateIso: '2026-11-26',
      ).copyWith(recipientName: client.name, recipientKraPin: client.kraPin);

      final docWithPin = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: brandedDoc.copyWith(showKraPin: true),
        settings: settingsWithPin,
      );
      final docNoPin = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: brandedDoc.copyWith(showKraPin: false),
        settings: settingsWithPin,
      );
      expect(_extractPdfTextStreams(docWithPin), contains('P059998887Z'));
      expect(_extractPdfTextStreams(docWithPin), contains('P051112223A'));
      expect(
        _extractPdfTextStreams(docNoPin),
        isNot(contains('P059998887Z')),
      );
      expect(
        _extractPdfTextStreams(docNoPin),
        isNot(contains('P051112223A')),
      );

      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: _MemStorage(),
        supabase: FakeSupabaseGateway(),
      );
      addTearDown(vault.dispose);
      await vault.setRestaurants([client], sync: false);
      await vault.setInvoices([inv], sync: false);
      final repVm = ReportsViewModel(vault: vault);
      addTearDown(repVm.dispose);
      final stmt = repVm.buildStatement(client, '2026-11');

      final stmtWithPin = await StatementPdfBuilder.buildPdfBytes(
        stmt,
        settings: settingsWithPin,
        showKraPin: true,
      );
      final stmtNoPin = await StatementPdfBuilder.buildPdfBytes(
        stmt,
        settings: settingsWithPin,
        showKraPin: false,
      );
      expect(_extractPdfTextStreams(stmtWithPin), contains('P059998887Z'));
      expect(_extractPdfTextStreams(stmtWithPin), contains('P051112223A'));
      expect(
        _extractPdfTextStreams(stmtNoPin),
        isNot(contains('P059998887Z')),
      );
      expect(
        _extractPdfTextStreams(stmtNoPin),
        isNot(contains('P051112223A')),
      );
    });

    testWidgets(
        'InvoiceDetailScreen toggles KRA PIN visibility and converts Invoice into clean Branded Delivery Note in 1 tap',
        (tester) async {
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: _MemStorage(),
        supabase: FakeSupabaseGateway(),
        syncDebounceDuration: const Duration(milliseconds: 20),
      );
      addTearDown(vault.dispose);

      await vault.setRestaurants([
        const Restaurant(
          id: 'r1',
          name: 'Fairmont Norfolk',
          kraPin: 'P051234567X',
        ),
      ], sync: false);
      await vault.setInvoices([
        const Invoice(
          id: 'inv1',
          number: 'TTG-9021',
          restaurantId: 'r1',
          restaurantName: 'Fairmont Norfolk',
          date: '2026-11-26',
          items: [
            InvoiceLineItem(
              desc: 'Roma Tomatoes',
              qty: 15,
              unit: 'kgs',
              buyPrice: 80,
              sellPrice: 120,
              total: 1800,
            ),
            InvoiceLineItem(
              desc: 'Delivery Charge',
              qty: 1,
              unit: 'pcs',
              buyPrice: 0,
              sellPrice: 300,
              total: 300,
            ),
          ],
          totalSell: 2100,
        ),
      ], sync: false);

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const InvoiceDetailScreen(invoiceId: 'inv1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // KRA PIN shown initially -> toggle Include KRA PIN off hides it immediately
      expect(find.text('KRA PIN: P051234567X'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chip_invoice_show_kra_pin')));
      await tester.pumpAndSettle();
      expect(find.text('KRA PIN: P051234567X'), findsNothing);

      // Tap Delivery Note -> opens DocumentOcrImportSheet with non-goods fee excluded & KRA PIN off by default
      await tester.tap(
        find.byKey(const Key('btn_invoice_generate_delivery_note')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delivery Note Items (1 deliverable)'), findsOneWidget);
      expect(
        find.textContaining('1 non-goods fee line(s) automatically excluded'),
        findsOneWidget,
      );

      // Confirm -> saves & opens BrandedDocumentEditorScreen with Delivery Note
      await tester.tap(
        find.byKey(const Key('btn_create_converted_branded_doc')),
      );
      await tester.pumpAndSettle();

      expect(vault.brandedDocuments.length, 1);
      final createdDn = vault.brandedDocuments.first;
      expect(createdDn.documentType, 'DELIVERY NOTE');
      expect(createdDn.showKraPin, isFalse);
      final dnTable = createdDn.blocks.firstWhere((b) => b.isTable);
      expect(dnTable.tableRows.length, 2); // Header + Roma Tomatoes ONLY
      expect(dnTable.tableRows[1][1], 'Roma Tomatoes');
    });
  });
}
