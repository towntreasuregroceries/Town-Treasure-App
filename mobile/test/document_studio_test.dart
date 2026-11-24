import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/features/documents/branded_document_pdf_builder.dart';
import 'package:town_treasure_groceries/ui/features/documents/document_studio_screen.dart';

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
}
