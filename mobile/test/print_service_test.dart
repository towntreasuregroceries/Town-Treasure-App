import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/print_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';
import 'package:town_treasure_groceries/ui/core/theme/app_theme.dart';
import 'package:town_treasure_groceries/ui/core/widgets/branded_pdf_viewer_screen.dart';
import 'package:town_treasure_groceries/ui/core/widgets/print_options_sheet.dart';
import 'package:town_treasure_groceries/ui/features/invoices/invoice_pdf_builder.dart';

import 'test_fakes.dart';

class _InMemoryKvStorage extends LocalStorageService {
  _InMemoryKvStorage() : super(secureStore: InMemorySecureKeyStore());

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

void main() {
  group('PrintService', () {
    test('parseHostAndPort parses bare IPs, host:port, and ipp:// URIs', () {
      expect(
        PrintService.parseHostAndPort('192.168.1.55', fallbackPort: 631),
        (host: '192.168.1.55', port: 631),
      );
      expect(
        PrintService.parseHostAndPort('192.168.1.55:9100', fallbackPort: 631),
        (host: '192.168.1.55', port: 9100),
      );
      expect(
        PrintService.parseHostAndPort(
          'ipp://printer.local:631/ipp/print',
          fallbackPort: 9100,
        ),
        (host: 'printer.local', port: 631),
      );
    });

    test('discoverLanPrinters scans local /24 subnet for IPP (631) and RAW (9100)',
        () async {
      final service = PrintService(
        localIpProvider: () async => ['192.168.1.15'],
        portProber: (host, port, _) async {
          return (host == '192.168.1.50' && port == 631) ||
              (host == '192.168.1.88' && port == 9100);
        },
      );

      final found = await service.discoverLanPrinters(
        probeTimeout: const Duration(milliseconds: 5),
        concurrency: 64,
      );

      expect(found.length, 2);
      expect(found[0].host, '192.168.1.50');
      expect(found[0].port, 631);
      expect(found[0].protocol, WifiPrintProtocol.ippPdf);
      expect(found[1].host, '192.168.1.88');
      expect(found[1].port, 9100);
      expect(found[1].protocol, WifiPrintProtocol.rawPdf9100);
    });

    test('sendDirectWifiPrint sends RFC8011 IPP Print-Job with PDF payload and handles endpoints',
        () async {
      final requestedUrls = <String>[];
      late Uint8List capturedIppBody;
      String? capturedContentType;

      final mockHttp = MockClient((req) async {
        requestedUrls.add(req.url.toString());
        capturedContentType = req.headers['content-type'] ?? req.headers['Content-Type'];
        if (req.url.path == '/ipp/print') {
          return http.Response('Not Found', 404);
        }
        capturedIppBody = req.bodyBytes;
        // IPP 2.0 successful-ok response (0x0000)
        return http.Response.bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03], 200);
      });

      final service = PrintService(httpClient: mockHttp);
      final fakePdf = Uint8List.fromList(utf8.encode('%PDF-1.4\n%%EOF'));

      final msg = await service.sendDirectWifiPrint(
        hostInput: '192.168.1.50',
        port: 631,
        protocol: WifiPrintProtocol.ippPdf,
        jobName: 'Invoice TTG-1001',
        pdfBytes: fakePdf,
        copies: 2,
      );

      expect(requestedUrls, [
        'http://192.168.1.50:631/ipp/print',
        'http://192.168.1.50:631/printers/default',
      ]);
      expect(capturedContentType, 'application/ipp');
      expect(capturedIppBody.sublist(0, 4), [0x02, 0x00, 0x00, 0x02]);
      expect(utf8.decode(capturedIppBody, allowMalformed: true), contains('%PDF-1.4'));
      expect(msg, contains('2 copies'));
      expect(msg, contains('192.168.1.50:631'));
    });

    test('sendDirectWifiPrint streams Raw PDF and ESC/POS thermal commands to TCP port 9100',
        () async {
      final sentPayloads = <({String host, int port, Uint8List bytes})>[];
      final service = PrintService(
        tcpSender: (host, port, bytes, _) async {
          sentPayloads.add((host: host, port: port, bytes: bytes));
        },
      );

      final fakePdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
      await service.sendDirectWifiPrint(
        hostInput: '192.168.1.99',
        port: 9100,
        protocol: WifiPrintProtocol.rawPdf9100,
        jobName: 'Test PDF',
        pdfBytes: fakePdf,
        copies: 2,
      );
      expect(sentPayloads.length, 2);
      expect(sentPayloads.first.port, 9100);

      sentPayloads.clear();
      const inv = Invoice(
        id: 'i1',
        number: 'TTG-9999',
        restaurantId: 'r1',
        restaurantName: 'Hilton Garden Inn',
        date: '2026-11-19',
        items: [
          InvoiceLineItem(
            desc: 'White Cabbage',
            qty: 30,
            unit: 'kgs',
            buyPrice: 35,
            sellPrice: 50,
            total: 1500,
          ),
        ],
        totalSell: 1500,
        status: 'pending',
      );
      final escPos = EscPosReceiptBuilder.buildInvoicesReceipt(
        invoices: const [inv],
        restaurants: const [Restaurant(id: 'r1', name: 'Hilton Garden Inn')],
        lineWidth: 48,
      );

      await service.sendDirectWifiPrint(
        hostInput: '192.168.1.88:9100',
        port: 9100,
        protocol: WifiPrintProtocol.escPos9100,
        jobName: 'Receipt TTG-9999',
        pdfBytes: Uint8List(0),
        escPosBytes: escPos,
      );

      expect(sentPayloads.length, 1);
      expect(sentPayloads.first.host, '192.168.1.88');
      expect(sentPayloads.first.bytes.sublist(0, 2), [0x1B, 0x40]); // ESC @
      final ascii = utf8.decode(sentPayloads.first.bytes, allowMalformed: true);
      expect(ascii, contains('TOWN TREASURE'));
      expect(ascii, contains('TTG-9999'));
      expect(ascii, contains('Hilton Garden Inn'));
      expect(ascii, contains('White Cabbage'));
      expect(ascii, contains('1,500.00'));
    });
  });

  group('PrintOptionsSheet widget & multi-invoice PDF', () {
    test('InvoicePdfBuilder builds multi-invoice A4 and 80mm thermal receipt PDFs',
        () async {
      final a4Bytes = await InvoicePdfBuilder.buildMultiInvoicePdfBytes(
        invoices: const [
          Invoice(
            id: 'i1',
            number: 'TTG-0001',
            restaurantId: 'r1',
            restaurantName: 'Kempinski',
            date: '2026-11-18',
            totalSell: 1000,
            status: 'pending',
          ),
          Invoice(
            id: 'i2',
            number: 'TTG-0002',
            restaurantId: 'r1',
            restaurantName: 'Kempinski',
            date: '2026-11-19',
            totalSell: 2500,
            status: 'paid',
          ),
        ],
        restaurants: const [Restaurant(id: 'r1', name: 'Kempinski')],
        logoBytesOverride: Uint8List(0),
        stampBytesOverride: Uint8List(0),
      );
      expect(a4Bytes.length, greaterThan(500));

      final thermalBytes = await InvoicePdfBuilder.buildMultiInvoicePdfBytes(
        invoices: const [
          Invoice(
            id: 'i1',
            number: 'TTG-0001',
            restaurantId: 'r1',
            restaurantName: 'Kempinski',
            date: '2026-11-18',
            items: [
              InvoiceLineItem(
                desc: 'Tomatoes',
                qty: 5,
                unit: 'kgs',
                buyPrice: 80,
                sellPrice: 120,
                total: 600,
              ),
            ],
            totalSell: 600,
            status: 'pending',
          ),
        ],
        restaurants: const [Restaurant(id: 'r1', name: 'Kempinski')],
        pageFormat: PdfPageFormat.roll80,
      );
      expect(thermalBytes.length, greaterThan(400));
    });

    testWidgets('PrintOptionsSheet scans Wi-Fi printers, sends thermal receipt, and persists printer config',
        (tester) async {
      final storage = _InMemoryKvStorage();
      final vault = VaultRepository(
        cryptoService: CryptoService(),
        localStorage: storage,
        supabase: FakeSupabaseGateway(),
      );
      addTearDown(vault.dispose);

      final sentHosts = <String>[];
      final fakePrint = PrintService(
        localIpProvider: () async => ['192.168.10.20'],
        portProber: (host, port, _) async =>
            host == '192.168.10.77' && port == 9100,
        tcpSender: (host, port, bytes, _) async {
          sentHosts.add('$host:$port:${bytes.length}');
        },
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<VaultRepository>.value(
          value: vault,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: PrintOptionsSheet(
                printService: fakePrint,
                vault: vault,
                document: PrintableDocument(
                  title: 'Invoice TTG-7777',
                  filename: 'Invoice_TTG-7777.pdf',
                  buildPdf: (_) async => Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
                  buildEscPos: (cols) =>
                      EscPosReceiptBuilder.buildSummaryReceipt(
                        title: 'Invoice TTG-7777',
                        lines: const ['Roma Tomatoes: KES 500.00'],
                        lineWidth: cols,
                      ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('80mm Roll'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_scan_wifi_printers')));
      await tester.pumpAndSettle();

      expect(find.textContaining('192.168.10.77:9100'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_send_wifi_print')));
      await tester.pumpAndSettle();

      expect(sentHosts.length, 1);
      expect(sentHosts.first, startsWith('192.168.10.77:9100:'));

      final saved = await vault.getSavedPrinterConfig();
      expect(saved['host'], '192.168.10.77');
      expect(saved['port'], 9100);
      expect(saved['paperFormat'], 'roll80');
    });

    testWidgets('BrandedPdfViewerScreen renders branded multi-page PDF without external apps, zooms, and switches paper format',
        (tester) async {
      // Valid 1x1 transparent PNG bytes for crisp in-memory page raster testing
      final samplePng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      final requestedFormats = <PdfPageFormat>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: BrandedPdfViewerScreen(
            title: 'Invoice TTG-9001',
            filename: 'Invoice_TTG-9001.pdf',
            buildPdf: (fmt) async {
              requestedFormats.add(fmt);
              return Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
            },
            rasterStreamProvider: (_, _) => Stream.fromIterable([
              RasterizedPdfPage(pngBytes: samplePng, width: 595, height: 842),
              RasterizedPdfPage(pngBytes: samplePng, width: 595, height: 842),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Town Treasure Document Viewer'), findsOneWidget);
      expect(find.text('Invoice TTG-9001'), findsOneWidget);
      expect(find.text('Page 1 of 2'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);

      // Jump to page 2 via next-page button
      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 2'), findsOneWidget);

      // Zoom in and verify percentage updates cleanly
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(find.text('150%'), findsOneWidget);

      // Switch paper format to 80mm Roll and verify re-layout triggers
      await tester.tap(find.byKey(const Key('btn_viewer_paper_format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('80mm Roll'));
      await tester.pumpAndSettle();
      expect(requestedFormats, [PdfPageFormat.a4, PdfPageFormat.roll80]);
    });

    testWidgets('BrandedPdfViewerScreen uses a single unified Print button and hides split Wi-Fi button',
        (tester) async {
      final samplePng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      PrintPaperFormat? forwardedFormat;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => BrandedPdfViewerScreen(
              title: 'Unified Print Check',
              filename: 'Unified.pdf',
              initialPaperFormat: PrintPaperFormat.roll80,
              buildPdf: (_) async => Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
              rasterStreamProvider: (_, _) => Stream.fromIterable([
                RasterizedPdfPage(pngBytes: samplePng, width: 226, height: 400),
              ]),
              onOpenPrintCenter: (fmt) {
                forwardedFormat = fmt;
                showPrintOptionsSheet(
                  context,
                  document: PrintableDocument(
                    title: 'Unified Print Check',
                    filename: 'Unified.pdf',
                    buildPdf: (_) async =>
                        Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
                  ),
                  initialPaperFormat: fmt,
                  fromPreview: true,
                  printService: PrintService(),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_viewer_print')), findsOneWidget);
      expect(find.byKey(const Key('btn_viewer_wifi_print')), findsNothing);
      expect(find.byKey(const Key('btn_viewer_share')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_viewer_print')));
      await tester.pumpAndSettle();

      expect(forwardedFormat, PrintPaperFormat.roll80);
      expect(find.text('Print & Dispatch Center'), findsOneWidget);
      expect(find.byKey(const Key('btn_print_preview')), findsNothing);
      expect(find.byKey(const Key('btn_system_print')), findsOneWidget);
    });
  });
}
