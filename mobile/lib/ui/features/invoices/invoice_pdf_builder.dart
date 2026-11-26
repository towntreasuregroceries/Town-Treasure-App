import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import 'invoice_formatters.dart';

/// Builds crisp A4 PDFs matching `generateInvoicePDF` in `views.js` and handles
/// print/share and WhatsApp dispatch summaries.
class InvoicePdfBuilder {
  InvoicePdfBuilder._();

  static const PdfColor _leafGreen = PdfColor.fromInt(0xFF61B146);
  static const PdfColor _slateDark = PdfColor.fromInt(0xFF313A43);
  static const PdfColor _textDark = PdfColor.fromInt(0xFF424242);
  static const PdfColor _textMuted = PdfColor.fromInt(0xFF616161);
  static const PdfColor _altRowBg = PdfColor.fromInt(0xFFF8FAFC);
  static const PdfColor _watermarkColor = PdfColor.fromInt(0xFFEBEBEB);
  static const PdfColor _stampRed = PdfColor.fromInt(0xFFDC2626);

  /// Generates A4 (or Letter/Thermal Roll) PDF bytes with header banner, KRA PIN
  /// under BILLED TO, line items table, totals, QR link, official stamp
  /// (`assets/stamp.png`), and saved signature from [settings].
  static Future<Uint8List> buildPdfBytes({
    required Invoice invoice,
    Restaurant? restaurant,
    VaultSettings settings = const VaultSettings(),
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    bool showKraPin = true,
    Uint8List? logoBytesOverride,
    Uint8List? stampBytesOverride,
  }) async {
    return buildMultiInvoicePdfBytes(
      invoices: [invoice],
      restaurants: restaurant != null ? [restaurant] : const [],
      settings: settings,
      pageFormat: pageFormat,
      showKraPin: showKraPin,
      logoBytesOverride: logoBytesOverride,
      stampBytesOverride: stampBytesOverride,
    );
  }

  /// Generates a combined PDF (A4/Letter multi-invoice pages or 80mm/58mm thermal receipts).
  static Future<Uint8List> buildMultiInvoicePdfBytes({
    required List<Invoice> invoices,
    required List<Restaurant> restaurants,
    VaultSettings settings = const VaultSettings(),
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    bool showKraPin = true,
    Uint8List? logoBytesOverride,
    Uint8List? stampBytesOverride,
  }) async {
    if (invoices.isEmpty) {
      throw ArgumentError('At least one invoice is required to build a PDF.');
    }
    if (pageFormat == PdfPageFormat.roll80 || pageFormat == PdfPageFormat.roll57) {
      return buildReceiptPdfBytes(
        invoices: invoices,
        restaurants: restaurants,
        settings: settings,
        pageFormat: pageFormat,
        showKraPin: showKraPin,
      );
    }

    final logoBytes = logoBytesOverride ?? await _loadAssetBytes('assets/logo.png');
    final stampRaw = stampBytesOverride ?? await _loadAssetBytes('assets/stamp.png');
    final stampGrayscale =
        (stampRaw != null && stampRaw.isNotEmpty) ? _toGrayscalePng(stampRaw) : null;
    final signatureBytes = decodeSignatureDataUrl(settings.signature);

    final logoImage =
        (logoBytes != null && logoBytes.isNotEmpty) ? pw.MemoryImage(logoBytes) : null;
    final stampImage = (stampGrayscale != null && stampGrayscale.isNotEmpty)
        ? pw.MemoryImage(stampGrayscale)
        : null;
    final sigImage = (signatureBytes != null && signatureBytes.isNotEmpty)
        ? pw.MemoryImage(signatureBytes)
        : null;

    final doc = pw.Document(
      title: invoices.length == 1
          ? 'Invoice ${invoices.first.number}'
          : 'Town Treasure Invoices (${invoices.length})',
      author: 'Town Treasure Limited',
    );

    for (final invoice in invoices) {
      final restaurant = Restaurant.resolveInvoiceRestaurant(
        invoice,
        restaurants,
      ).restaurant;
      final clientName =
          restaurant?.name.trim().isNotEmpty == true
              ? restaurant!.name
              : (invoice.restaurantName.trim().isNotEmpty
                  ? invoice.restaurantName
                  : 'Unknown');
      final kraPin = showKraPin ? Restaurant.normalizeKraPin(restaurant?.kraPin) : '';
      final clientAddress = restaurant?.address.trim() ?? '';
      final clientPhone = restaurant?.phone.trim() ?? '';

      final taxSummary = KraTaxCalculator.computeInvoiceTaxSummary(
        invoice,
        profile: settings.kraProfile,
      );
      final sellerPin =
          showKraPin ? settings.kraProfile.normalizedSellerPin : '';
      final cuSerial = settings.kraProfile.cuSerialNumber.trim();
      final isTaxInvoice =
          settings.kraProfile.vatRegistered &&
          (taxSummary.hasTaxableVatLines || invoice.isFiscalized);
      final showEtimsHeading = isTaxInvoice || invoice.isFiscalized;
      final docHeadingTitle = isTaxInvoice
          ? 'TAX INVOICE'
          : (invoice.isFiscalized ? 'eTIMS INVOICE' : 'INVOICE');

      final pageTheme = pw.PageTheme(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(36, 24, 36, 60),
        buildBackground: (context) => _buildPageBackground(
          context: context,
          logoImage: logoImage,
          clientName: clientName,
        ),
      );

      doc.addPage(
        pw.MultiPage(
          pageTheme: pageTheme,
          header: (context) => _buildPageHeader(
            context: context,
            invoice: invoice,
            clientName: clientName,
          ),
          build: (context) => [
            _buildTitleAndMeta(
              invoice,
              isTaxInvoice: showEtimsHeading,
              headingLabel: docHeadingTitle,
            ),
            pw.SizedBox(height: 20),
            _buildFromAndBilledTo(
              clientName: clientName,
              kraPin: kraPin,
              clientAddress: clientAddress,
              clientPhone: clientPhone,
              sellerKraPin: sellerPin,
              cuSerial: cuSerial,
            ),
            pw.SizedBox(height: 20),
            _buildItemsTable(
              invoice.items,
              showTaxCode: showEtimsHeading,
              defaultTaxRate: settings.kraProfile.vatRegistered
                  ? settings.kraProfile.defaultTaxRate
                  : KraTaxRate.exempt,
            ),
            pw.SizedBox(height: 20),
            _buildTotalsBlock(
              invoice.totalSell,
              taxSummary: taxSummary,
              isTaxInvoice: isTaxInvoice,
            ),
            pw.SizedBox(height: 28),
            _buildBottomQrAndStamp(
              invoice: invoice,
              stampImage: stampImage,
              sigImage: sigImage,
            ),
          ],
        ),
      );
    }

    return doc.save();
  }

  /// Generates compact 80mm / 58mm thermal roll PDF receipts for Android print plugins
  /// (Mopria, RawBT, USB thermal drivers, and Wi-Fi roll printers).
  static Future<Uint8List> buildReceiptPdfBytes({
    required List<Invoice> invoices,
    required List<Restaurant> restaurants,
    VaultSettings settings = const VaultSettings(),
    PdfPageFormat pageFormat = PdfPageFormat.roll80,
    bool showKraPin = true,
  }) async {
    final is58mm = pageFormat.width <= PdfPageFormat.roll57.width + 1;
    final baseFont = is58mm ? 7.5 : 9.0;
    final titleFont = is58mm ? 11.0 : 13.0;
    final doc = pw.Document(
      title: invoices.length == 1
          ? 'Receipt ${invoices.first.number}'
          : 'Receipts (${invoices.length})',
      author: 'Town Treasure Limited',
    );

    for (final invoice in invoices) {
      final clientName = Restaurant.invoiceDisplayName(invoice, restaurants);
      final rest = Restaurant.resolveInvoiceRestaurant(
        invoice,
        restaurants,
      ).restaurant;
      final kraPin = showKraPin ? Restaurant.normalizeKraPin(rest?.kraPin) : '';
      final sellerPin =
          showKraPin ? settings.kraProfile.normalizedSellerPin : '';
      final taxSummary = KraTaxCalculator.computeInvoiceTaxSummary(
        invoice,
        profile: settings.kraProfile,
      );

      doc.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Center(
                child: pw.Text(
                  'TOWN TREASURE LIMITED',
                  style: pw.TextStyle(
                    fontSize: titleFont,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Center(
                child: pw.Text(
                  'Tel: 0708567696 | Nairobi',
                  style: pw.TextStyle(fontSize: baseFont),
                ),
              ),
              if (sellerPin.isNotEmpty)
                pw.Center(
                  child: pw.Text(
                    'PIN: $sellerPin',
                    style: pw.TextStyle(fontSize: baseFont - 0.5),
                  ),
                ),
              pw.Divider(thickness: 0.7),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'INV: ${invoice.number}',
                    style: pw.TextStyle(
                      fontSize: baseFont,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    invoice.status.toUpperCase(),
                    style: pw.TextStyle(
                      fontSize: baseFont,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
              pw.Text('Client: $clientName', style: pw.TextStyle(fontSize: baseFont)),
              if (kraPin.isNotEmpty)
                pw.Text('PIN: $kraPin', style: pw.TextStyle(fontSize: baseFont - 1)),
              if (invoice.cuInvoiceNumber?.isNotEmpty == true)
                pw.Text(
                  'CU Inv: ${invoice.cuInvoiceNumber}',
                  style: pw.TextStyle(fontSize: baseFont - 1),
                ),
              pw.Text(
                'Date: ${InvoiceFormatters.formatDisplayDate(invoice.date)}',
                style: pw.TextStyle(fontSize: baseFont),
              ),
              pw.Divider(thickness: 0.7),
              ...invoice.items.map(
                (it) => pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 3),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        it.desc,
                        style: pw.TextStyle(
                          fontSize: baseFont,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text(
                            '${it.qty == it.qty.roundToDouble() ? it.qty.toInt() : it.qty} ${it.unit} x ${InvoiceFormatters.formatMoney(it.sellPrice)}',
                            style: pw.TextStyle(fontSize: baseFont - 0.5),
                          ),
                          pw.Text(
                            InvoiceFormatters.formatMoney(it.total),
                            style: pw.TextStyle(fontSize: baseFont),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              pw.Divider(thickness: 0.9),
              if (taxSummary.outputVatTotal > 0) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Exempt:', style: pw.TextStyle(fontSize: baseFont - 0.5)),
                    pw.Text(
                      InvoiceFormatters.formatMoney(taxSummary.exemptTotal),
                      style: pw.TextStyle(fontSize: baseFont - 0.5),
                    ),
                  ],
                ),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('VAT (16%):', style: pw.TextStyle(fontSize: baseFont - 0.5)),
                    pw.Text(
                      InvoiceFormatters.formatMoney(taxSummary.outputVatTotal),
                      style: pw.TextStyle(fontSize: baseFont - 0.5),
                    ),
                  ],
                ),
              ],
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'TOTAL (KES)',
                    style: pw.TextStyle(
                      fontSize: baseFont + 1,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    InvoiceFormatters.formatMoney(
                      taxSummary.outputVatTotal > 0
                          ? taxSummary.grandTotalWithVat
                          : invoice.totalSell,
                    ),
                    style: pw.TextStyle(
                      fontSize: baseFont + 1,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              if (invoice.etimsQrData?.trim().isNotEmpty == true) ...[
                pw.Divider(thickness: 0.7),
                pw.Center(
                  child: pw.Column(
                    children: [
                      pw.Text(
                        'KRA eTIMS Verification',
                        style: pw.TextStyle(
                          fontSize: baseFont - 0.5,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: invoice.etimsQrData!.trim(),
                        width: is58mm ? 74 : 88,
                        height: is58mm ? 74 : 88,
                      ),
                      pw.SizedBox(height: 3),
                      if (invoice.etimsSdcDateTime?.trim().isNotEmpty == true)
                        pw.Text(
                          'SDC: ${invoice.etimsSdcDateTime!.trim()}',
                          style: pw.TextStyle(fontSize: baseFont - 1.2),
                        ),
                      pw.Text(
                        'Scan to verify on KRA eTIMS',
                        style: pw.TextStyle(fontSize: baseFont - 1),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 6),
              ],
              pw.Center(
                child: pw.Text(
                  'Thank you for choosing Town Treasure!',
                  style: pw.TextStyle(fontSize: baseFont - 0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return doc.save();
  }

  static pw.Widget _buildPageBackground({
    required pw.Context context,
    required pw.MemoryImage? logoImage,
    required String clientName,
  }) {
    final pageW = context.page.pageFormat.width;
    final pageH = context.page.pageFormat.height;

    return pw.FullPage(
      ignoreMargins: true,
      child: pw.Stack(
        children: [
          // Diagonal subtle watermark
          pw.Positioned(
            left: 85,
            top: pageH * 0.48,
            child: pw.Transform.rotate(
              angle: 0.48,
              child: pw.Text(
                'Town Treasure Limited',
                style: pw.TextStyle(
                  fontSize: 40,
                  fontWeight: pw.FontWeight.bold,
                  color: _watermarkColor,
                ),
              ),
            ),
          ),
          // Top letterhead banner on page 1, slim brand bar on continuation pages
          if (context.pageNumber == 1)
            pw.Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: pw.SizedBox(
                width: pageW,
                height: 106,
                child: pw.Stack(
                  children: [
                    pw.CustomPaint(
                      size: PdfPoint(pageW, 106),
                      painter: (canvas, size) {
                        canvas
                          ..setFillColor(_leafGreen)
                          ..drawRect(0, 0, size.x, size.y)
                          ..fillPath();

                        canvas
                          ..setFillColor(_slateDark)
                          ..moveTo(size.x * 0.30, size.y)
                          ..lineTo(size.x, size.y)
                          ..lineTo(size.x, 22)
                          ..curveTo(
                            size.x * 0.72,
                            -12,
                            size.x * 0.45,
                            14,
                            size.x * 0.30,
                            size.y,
                          )
                          ..closePath()
                          ..fillPath();
                      },
                    ),
                    if (logoImage != null)
                      pw.Positioned(
                        left: 36,
                        top: 22,
                        child: pw.Image(
                          logoImage,
                          height: 56,
                          fit: pw.BoxFit.contain,
                        ),
                      )
                    else
                      pw.Positioned(
                        left: 36,
                        top: 38,
                        child: pw.Text(
                          'Town Treasure Groceries',
                          style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 18,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            pw.Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: pw.Column(
                children: [
                  pw.Container(height: 8, color: _leafGreen),
                  pw.Container(height: 4, color: _slateDark),
                ],
              ),
            ),
          // Dark slate footer bar across every page
          pw.Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: pw.Container(
              height: 42,
              color: _slateDark,
              padding: const pw.EdgeInsets.symmetric(horizontal: 36),
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                'Thank you, $clientName, for Shopping with us',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 9,
                  fontStyle: pw.FontStyle.italic,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildPageHeader({
    required pw.Context context,
    required Invoice invoice,
    required String clientName,
  }) {
    if (context.pageNumber == 1) {
      // Reserve clean vertical clearance below the 106pt page-1 curved banner
      return pw.SizedBox(height: 100);
    }
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      margin: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFE2E8F0), width: 0.8),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'INVOICE ${invoice.number} - $clientName',
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: _slateDark,
            ),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8.5, color: _textMuted),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildTitleAndMeta(
    Invoice invoice, {
    bool isTaxInvoice = false,
    String headingLabel = 'TAX INVOICE',
  }) {
    final cuNo = invoice.cuInvoiceNumber?.trim() ?? '';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          isTaxInvoice ? headingLabel : 'INVOICE',
          style: pw.TextStyle(
            fontSize: isTaxInvoice ? 21 : 24,
            fontWeight: pw.FontWeight.bold,
            color: _leafGreen,
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  'Receipt No:  ',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: _textDark,
                  ),
                ),
                pw.Text(
                  invoice.number,
                  style: const pw.TextStyle(fontSize: 10, color: _textMuted),
                ),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  'Order Date:  ',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: _textDark,
                  ),
                ),
                pw.Text(
                  InvoiceFormatters.formatDisplayDate(invoice.date),
                  style: const pw.TextStyle(fontSize: 10, color: _textMuted),
                ),
              ],
            ),
            if (cuNo.isNotEmpty) ...[
              pw.SizedBox(height: 4),
              pw.Row(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text(
                    'CU Inv No:  ',
                    style: pw.TextStyle(
                      fontSize: 9.5,
                      fontWeight: pw.FontWeight.bold,
                      color: _slateDark,
                    ),
                  ),
                  pw.Text(
                    cuNo,
                    style: const pw.TextStyle(fontSize: 9.5, color: _textMuted),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildFromAndBilledTo({
    required String clientName,
    required String kraPin,
    required String clientAddress,
    required String clientPhone,
    String sellerKraPin = '',
    String cuSerial = '',
  }) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'FROM:',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _textDark,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'Town Treasure Limited',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _leafGreen,
                ),
              ),
              if (sellerKraPin.isNotEmpty) ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  'KRA PIN: $sellerKraPin',
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                    color: _slateDark,
                  ),
                ),
              ],
              if (cuSerial.isNotEmpty) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  'eTIMS CU: $cuSerial',
                  style: const pw.TextStyle(fontSize: 8.5, color: _textMuted),
                ),
              ],
              pw.SizedBox(height: 4),
              pw.Text(
                'Tel: 0708567696',
                style: const pw.TextStyle(fontSize: 9, color: _textMuted),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Email: thetowntreasure25@gmail.com',
                style: const pw.TextStyle(fontSize: 9, color: _textMuted),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Web: towntreasuregroceries.com',
                style: const pw.TextStyle(fontSize: 9, color: _textMuted),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'BILLED TO:',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _textDark,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                clientName,
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _textDark,
                ),
              ),
              if (kraPin.isNotEmpty) ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  'KRA PIN: $kraPin',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                    color: _slateDark,
                  ),
                ),
              ],
              if (clientAddress.isNotEmpty) ...[
                pw.SizedBox(height: 3),
                pw.Text(
                  clientAddress,
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(fontSize: 9, color: _textMuted),
                ),
              ],
              if (clientPhone.isNotEmpty) ...[
                pw.SizedBox(height: 3),
                pw.Text(
                  clientPhone,
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(fontSize: 9, color: _textMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildItemsTable(
    List<InvoiceLineItem> items, {
    bool showTaxCode = false,
    KraTaxRate defaultTaxRate = KraTaxRate.exempt,
  }) {
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _slateDark),
        children: [
          _headerCell('SL\nNO.', align: pw.TextAlign.center),
          _headerCell('ITEM DESCRIPTION'),
          _headerCell('UNIT PRICE', align: pw.TextAlign.right),
          _headerCell('QUANTITY', align: pw.TextAlign.center),
          if (showTaxCode) _headerCell('TAX', align: pw.TextAlign.center),
          _headerCell('TOTAL', align: pw.TextAlign.right),
        ],
      ),
    ];

    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      final rowColor = i.isOdd ? _altRowBg : PdfColors.white;
      final lineTotal = it.total > 0 ? it.total : (it.qty * it.sellPrice);
      final rate = KraTaxRate.fromCode(it.taxRate, fallback: defaultTaxRate);
      final taxLetter = KraTaxCalculator.oscuTaxCode(rate);
      rows.add(
        pw.TableRow(
          decoration: pw.BoxDecoration(color: rowColor),
          children: [
            _bodyCell(
              (i + 1).toString().padLeft(2, '0'),
              align: pw.TextAlign.center,
            ),
            _bodyCell(it.desc),
            _bodyCell(
              'KSh ${InvoiceFormatters.formatMoney(it.sellPrice)}',
              align: pw.TextAlign.right,
            ),
            _bodyCell(
              '${_fmtQty(it.qty)} ${it.unit.isNotEmpty ? it.unit : 'kgs'}',
              align: pw.TextAlign.center,
            ),
            if (showTaxCode) _bodyCell(taxLetter, align: pw.TextAlign.center),
            _bodyCell(
              'KSh ${InvoiceFormatters.formatMoney(lineTotal)}',
              align: pw.TextAlign.right,
            ),
          ],
        ),
      );
    }

    return pw.Table(
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(
          color: PdfColor.fromInt(0xFFE2E8F0),
          width: 0.6,
        ),
        bottom: const pw.BorderSide(color: _slateDark, width: 1.0),
      ),
      columnWidths: showTaxCode
          ? {
              0: const pw.FixedColumnWidth(38),
              1: const pw.FlexColumnWidth(2.6),
              2: const pw.FlexColumnWidth(1.4),
              3: const pw.FlexColumnWidth(1.3),
              4: const pw.FixedColumnWidth(34),
              5: const pw.FlexColumnWidth(1.5),
            }
          : {
              0: const pw.FixedColumnWidth(44),
              1: const pw.FlexColumnWidth(2.8),
              2: const pw.FlexColumnWidth(1.5),
              3: const pw.FlexColumnWidth(1.4),
              4: const pw.FlexColumnWidth(1.6),
            },
      children: rows,
    );
  }

  static pw.Widget _headerCell(
    String text, {
    pw.TextAlign align = pw.TextAlign.left,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          color: PdfColors.white,
          fontSize: 8.5,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  static pw.Widget _bodyCell(
    String text, {
    pw.TextAlign align = pw.TextAlign.left,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: pw.Text(
        text,
        textAlign: align,
        style: const pw.TextStyle(
          color: _textDark,
          fontSize: 9.2,
          lineSpacing: 2,
        ),
      ),
    );
  }

  static pw.Widget _totalLineRow(String label, double amount) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: 9.2,
              fontWeight: pw.FontWeight.bold,
              color: _textDark,
            ),
          ),
          pw.Text(
            'KSh ${InvoiceFormatters.formatMoney(amount)}',
            style: pw.TextStyle(
              fontSize: 9.2,
              fontWeight: pw.FontWeight.bold,
              color: _textDark,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildTotalsBlock(
    double totalSell, {
    KraInvoiceTaxSummary? taxSummary,
    bool isTaxInvoice = false,
  }) {
    final showVatSplit = isTaxInvoice &&
        taxSummary != null &&
        taxSummary.hasTaxableVatLines;
    final grandDisplay = showVatSplit ? taxSummary.grandTotalWithVat : totalSell;

    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.SizedBox(
        width: 235,
        child: pw.Column(
          children: [
            if (showVatSplit) ...[
              if (taxSummary.exemptTotal > 0)
                _totalLineRow('VAT Exempt:', taxSummary.exemptTotal),
              if (taxSummary.zeroRatedTotal > 0)
                _totalLineRow('Zero-Rated (0%):', taxSummary.zeroRatedTotal),
              if (taxSummary.taxableNetTotal > 0)
                _totalLineRow('Taxable Net:', taxSummary.taxableNetTotal),
              _totalLineRow('Output VAT (16%):', taxSummary.outputVatTotal),
            ] else
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'Sub Total:',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: _textDark,
                      ),
                    ),
                    pw.Text(
                      'KSh ${InvoiceFormatters.formatMoney(totalSell)}',
                      style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: _textDark,
                      ),
                    ),
                  ],
                ),
              ),
            pw.Container(
              color: _leafGreen,
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Grand Total:',
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                    ),
                  ),
                  pw.Text(
                    'KSh ${InvoiceFormatters.formatMoney(grandDisplay)}',
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _buildBottomQrAndStamp({
    required Invoice invoice,
    required pw.MemoryImage? stampImage,
    required pw.MemoryImage? sigImage,
  }) {
    final stampDate = InvoiceFormatters.formatDisplayDate(
      InvoiceFormatters.todayIso(),
    );
    final etimsQr = invoice.etimsQrData?.trim() ?? '';
    final hasEtimsQr = etimsQr.isNotEmpty;

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  hasEtimsQr ? 'KRA eTIMS Verification:' : 'Visit Us Online:',
                  style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                    color: _textDark,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: hasEtimsQr
                      ? etimsQr
                      : 'https://towntreasuregroceries.com',
                  width: 66,
                  height: 66,
                  color: _slateDark,
                ),
              ],
            ),
            pw.SizedBox(width: 10),
            pw.SizedBox(
              width: 150,
              child: pw.Text(
                hasEtimsQr
                    ? [
                        'Scan QR to verify invoice\non KRA eTIMS portal.',
                        if (invoice.cuInvoiceNumber?.isNotEmpty == true)
                          'CU: ${invoice.cuInvoiceNumber}',
                        if (invoice.etimsSdcDateTime?.isNotEmpty == true)
                          'SDC: ${invoice.etimsSdcDateTime}',
                        if (invoice.etimsIntrData?.isNotEmpty == true)
                          'ID: ${invoice.etimsIntrData}',
                      ].join('\n')
                    : 'Scan to visit our website\nand explore our fresh\ngrocery catalog online.',
                style: const pw.TextStyle(fontSize: 8.0, color: _textMuted),
              ),
            ),
          ],
        ),
        pw.Container(
          width: 185,
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _slateDark, width: 2.2),
            borderRadius: pw.BorderRadius.circular(10),
          ),
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              if (stampImage != null)
                pw.Image(
                  stampImage,
                  height: 34,
                  width: 135,
                  fit: pw.BoxFit.contain,
                )
              else
                pw.Text(
                  'TOWN TREASURE GROCERIES',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.black,
                  ),
                ),
              pw.SizedBox(height: 4),
              pw.Text(
                invoice.isPaid ? 'PAID & PROCESSED' : 'AUTHORIZED',
                style: pw.TextStyle(
                  fontSize: 11.5,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.black,
                  letterSpacing: 0.8,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'DATE: $stampDate',
                style: pw.TextStyle(
                  font: pw.Font.courier(),
                  fontSize: 7.5,
                  color: _stampRed,
                ),
              ),
              pw.SizedBox(height: 4),
              if (sigImage != null)
                pw.Image(
                  sigImage,
                  height: 40,
                  width: 150,
                  fit: pw.BoxFit.contain,
                )
              else ...[
                pw.SizedBox(height: 18),
                pw.Container(
                  width: 110,
                  decoration: const pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(color: PdfColors.black, width: 0.6),
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Sign Here',
                  style: const pw.TextStyle(
                    fontSize: 6.5,
                    color: PdfColors.black,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Previews / prints the A4 PDF using `printing`.
  static Future<void> previewAndPrint({
    required Invoice invoice,
    Restaurant? restaurant,
    VaultSettings settings = const VaultSettings(),
  }) async {
    final filename = pdfFilename(invoice, restaurant);
    await AppLockGuard.runWithoutRelock(
      () => Printing.layoutPdf(
        name: filename,
        onLayout: (_) => buildPdfBytes(
          invoice: invoice,
          restaurant: restaurant,
          settings: settings,
        ),
      ),
    );
  }

  /// Generates PDF into a temporary file and opens native OS share sheet via `share_plus`.
  static Future<void> sharePdfFile({
    required Invoice invoice,
    Restaurant? restaurant,
    VaultSettings settings = const VaultSettings(),
    bool showKraPin = true,
    String? summaryText,
  }) async {
    final bytes = await buildPdfBytes(
      invoice: invoice,
      restaurant: restaurant,
      settings: settings,
      showKraPin: showKraPin,
    );
    final dir = await getTemporaryDirectory();
    final filename = pdfFilename(invoice, restaurant);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf', name: filename)],
        text: summaryText,
        subject: 'Invoice ${invoice.number}',
      ),
    );
  }

  /// Exact WhatsApp text summary matching `shareWhatsApp` in `views.js`.
  static String buildWhatsAppSummaryText({
    required Invoice invoice,
    Restaurant? restaurant,
  }) {
    final clientName =
        restaurant?.name.trim().isNotEmpty == true
            ? restaurant!.name
            : (invoice.restaurantName.trim().isNotEmpty
                ? invoice.restaurantName
                : 'Client');
    final greetingName = restaurant?.contact.trim().isNotEmpty == true
        ? restaurant!.contact.trim()
        : clientName;
    final dateStr = InvoiceFormatters.formatDisplayDate(invoice.date);
    final amountStr = InvoiceFormatters.formatMoney(invoice.totalSell);

    return 'Hello $greetingName,\n\n'
        'Thank you for choosing Town Treasure Groceries! Please find attached your invoice for the recent order.\n\n'
        '*Invoice No:* ${invoice.number}\n'
        '*Date:* $dateStr\n'
        '*Total Amount:* KES $amountStr\n\n'
        'Feel free to reach out for any queries. We appreciate your business!';
  }

  /// Normalizes local Kenyan phone numbers (`07...` -> `2547...`) matching `views.js`.
  static String normalizeKenyaPhone(String? rawPhone) {
    if (rawPhone == null) return '';
    var phone = rawPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (phone.startsWith('+')) phone = phone.substring(1);
    if (phone.startsWith('0')) phone = '254${phone.substring(1)}';
    return phone;
  }

  static Uri buildWhatsAppUri({
    required Invoice invoice,
    Restaurant? restaurant,
  }) {
    final phone = normalizeKenyaPhone(restaurant?.phone);
    final text = buildWhatsAppSummaryText(
      invoice: invoice,
      restaurant: restaurant,
    );
    return Uri.https(
      'wa.me',
      phone.isNotEmpty ? '/$phone' : '/',
      {'text': text},
    );
  }

  /// Shares the attached invoice PDF alongside the WhatsApp summary message.
  static Future<void> shareViaWhatsApp({
    required Invoice invoice,
    Restaurant? restaurant,
    VaultSettings settings = const VaultSettings(),
    bool showKraPin = true,
  }) async {
    final summary = buildWhatsAppSummaryText(
      invoice: invoice,
      restaurant: restaurant,
    );
    await sharePdfFile(
      invoice: invoice,
      restaurant: restaurant,
      settings: settings,
      showKraPin: showKraPin,
      summaryText: summary,
    );
  }

  static String pdfFilename(Invoice invoice, Restaurant? restaurant) {
    final rawName = restaurant?.name.trim().isNotEmpty == true
        ? restaurant!.name
        : invoice.restaurantName;
    final safeClient =
        (rawName.isNotEmpty ? rawName : 'Client').replaceAll(RegExp(r'\s+'), '_');
    return 'Invoice_${invoice.number}_$safeClient.pdf';
  }

  static Uint8List? decodeSignatureDataUrl(String? signature) {
    if (signature == null || signature.trim().isEmpty) return null;
    final trimmed = signature.trim();
    final match = RegExp(
      r'^data:image\/(?:png|jpe?g|webp|gif);base64,([A-Za-z0-9+/=]+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) return null;
    try {
      return base64Decode(match.group(1)!);
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _loadAssetBytes(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _toGrayscalePng(Uint8List rawBytes) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return rawBytes;
      final gray = img.grayscale(decoded);
      return Uint8List.fromList(img.encodePng(gray));
    } catch (_) {
      return rawBytes;
    }
  }

  static String _fmtQty(double qty) {
    if (qty == qty.roundToDouble()) return qty.toInt().toString();
    return qty.toStringAsFixed(2);
  }
}
