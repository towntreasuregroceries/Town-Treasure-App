import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../domain/models/models.dart';
import '../../core/stamp_signature_helper.dart';
import 'pricelists_view_model.dart';

/// Builds watermarked A4 PDFs for Price Lists matching `downloadPriceListPDF` in `pricelist.js`.
class PriceListPdfBuilder {
  PriceListPdfBuilder._();

  static const PdfColor _leafGreen = PdfColor.fromInt(0xFF61B146);
  static const PdfColor _forestGreen = PdfColor.fromInt(0xFF2E7D32);
  static const PdfColor _slateDark = PdfColor.fromInt(0xFF313A43);
  static const PdfColor _textDark = PdfColor.fromInt(0xFF333333);
  static const PdfColor _textMuted = PdfColor.fromInt(0xFF6B7280);
  static const PdfColor _borderGrey = PdfColor.fromInt(0xFFD1D5DB);

  static Future<Uint8List> buildPdfBytes(
    PriceList priceList, {
    VaultSettings settings = const VaultSettings(),
    DateTime? generatedDate,
  }) async {
    final logoBytes = await _loadAsset('assets/logo.png');
    final stampRaw = await _loadAsset('assets/stamp.png');
    final stampBytes = StampSignatureHelper.prepareStampPng(stampRaw);
    final signatureBytes =
        StampSignatureHelper.prepareSignaturePng(settings.signature);
    final dateText = PriceListsViewModel.formatDate(
      (generatedDate ?? DateTime.now()).toIso8601String().substring(0, 10),
    );
    final subtitle = priceList.subtitle.trim().isNotEmpty
        ? priceList.subtitle.trim()
        : 'Food Supplies (Veg and Fruits)';
    final sections = PriceListsViewModel.groupSections(priceList);

    final doc = pw.Document(
      title: priceList.name,
      author: 'Town Treasure Limited',
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(48, 28, 48, 56),
          buildBackground: (context) => _buildPageBackground(),
        ),
        footer: (context) => _buildFooter(),
        build: (context) {
          final widgets = <pw.Widget>[
            _buildHeader(logoBytes, subtitle),
            pw.SizedBox(height: 16),
            for (final section in sections) ...[
              if (section.header != null && section.header!.trim().isNotEmpty)
                _buildCategoryBanner(section.header!.trim()),
              if (section.items.isNotEmpty)
                _buildItemsTable(section.items, hasBanner: section.header != null),
              pw.SizedBox(height: 14),
            ],
            pw.SizedBox(height: 18),
            _buildOfficialStampRow(
              stampBytes: stampBytes,
              signatureBytes: signatureBytes,
              dateText: dateText,
            ),
          ];
          return widgets;
        },
      ),
    );

    return doc.save();
  }

  static Future<File> writeTempPdfFile(
    PriceList priceList, {
    VaultSettings settings = const VaultSettings(),
  }) async {
    final bytes = await buildPdfBytes(priceList, settings: settings);
    final safeName =
        priceList.name.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$safeName.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static pw.Widget _buildPageBackground() {
    return pw.FullPage(
      ignoreMargins: true,
      child: pw.Stack(
        children: [
          pw.Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: pw.Column(
              children: [
                pw.Container(height: 8, color: _leafGreen),
                pw.Container(height: 3, color: _slateDark),
              ],
            ),
          ),
          pw.Center(
            child: pw.Transform.rotate(
              angle: -0.52,
              child: pw.Opacity(
                opacity: 0.06,
                child: pw.Text(
                  'Town Treasure Limited',
                  style: pw.TextStyle(
                    fontSize: 44,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.grey600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildHeader(Uint8List? logoBytes, String subtitle) {
    return pw.Column(
      children: [
        pw.SizedBox(height: 8),
        if (logoBytes != null)
          pw.Image(
            pw.MemoryImage(logoBytes),
            height: 76,
            fit: pw.BoxFit.contain,
          )
        else
          pw.Text(
            'TOWN TREASURE GROCERIES',
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
              color: _forestGreen,
            ),
          ),
        pw.SizedBox(height: 12),
        pw.Text(
          subtitle,
          style: pw.TextStyle(
            fontSize: 14,
            fontWeight: pw.FontWeight.bold,
            color: _slateDark,
          ),
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Email: thetowntreasure25@gmail.com | TEL: 0708567696',
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: _slateDark,
          ),
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 12),
        pw.Divider(color: PdfColor.fromInt(0xFFE0E0E0), thickness: 1),
        pw.SizedBox(height: 12),
        pw.Text(
          'Price List',
          style: pw.TextStyle(
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
            color: _leafGreen,
          ),
          textAlign: pw.TextAlign.center,
        ),
      ],
    );
  }

  static pw.Widget _buildCategoryBanner(String title) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const pw.BoxDecoration(
        color: _leafGreen,
        borderRadius: pw.BorderRadius.only(
          topLeft: pw.Radius.circular(3),
          topRight: pw.Radius.circular(3),
        ),
      ),
      child: pw.Text(
        title.toUpperCase(),
        style: pw.TextStyle(
          color: PdfColors.white,
          fontSize: 11,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  static pw.Widget _buildItemsTable(
    List<PriceListItem> items, {
    required bool hasBanner,
  }) {
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _leafGreen),
        children: [
          _cellHeader('Commodity Description', align: pw.TextAlign.left),
          _cellHeader('Measurement', align: pw.TextAlign.left),
          _cellHeader('Price (KES)', align: pw.TextAlign.right),
        ],
      ),
      for (final item in items)
        pw.TableRow(
          children: [
            _cellBody(item.name, align: pw.TextAlign.left, color: _textDark),
            _cellBody(
              PriceListsViewModel.formatMeasurement(item.unit),
              align: pw.TextAlign.left,
              color: _textMuted,
            ),
            _cellBody(
              PriceListsViewModel.formatMoney(item.price),
              align: pw.TextAlign.right,
              color: _forestGreen,
              bold: true,
            ),
          ],
        ),
    ];

    return pw.Table(
      border: pw.TableBorder.all(color: _borderGrey, width: 0.5),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.3),
      },
      children: rows,
    );
  }

  static pw.Widget _cellHeader(String text, {required pw.TextAlign align}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          color: PdfColors.white,
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  static pw.Widget _cellBody(
    String text, {
    required pw.TextAlign align,
    required PdfColor color,
    bool bold = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6.5),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static pw.Widget _buildOfficialStampRow({
    required Uint8List? stampBytes,
    required Uint8List? signatureBytes,
    required String dateText,
  }) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Town Treasure Limited',
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: _slateDark,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'Orders: 0708567696 | thetowntreasure25@gmail.com',
              style: const pw.TextStyle(fontSize: 8.5, color: _textMuted),
            ),
            pw.Text(
              'Prices subject to market changes.',
              style: const pw.TextStyle(fontSize: 8.5, color: _textMuted),
            ),
          ],
        ),
        pw.Container(
          width: 195,
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _slateDark, width: 2),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              if (stampBytes != null)
                pw.Image(
                  pw.MemoryImage(stampBytes),
                  height: 44,
                  width: 152,
                  fit: pw.BoxFit.contain,
                )
              else
                pw.Text(
                  'TOWN TREASURE GROCERIES',
                  style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              pw.SizedBox(height: 5),
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                decoration: const pw.BoxDecoration(
                  border: pw.Border.symmetric(
                    horizontal: pw.BorderSide(color: _slateDark, width: 0.7),
                  ),
                ),
                child: pw.Text(
                  'APPROVED PRICING',
                  style: pw.TextStyle(
                    fontSize: 10.5,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.black,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                'DATE: $dateText',
                style: pw.TextStyle(
                  font: pw.Font.courierBold(),
                  fontSize: 8,
                  color: const PdfColor.fromInt(0xFFDC2626),
                ),
              ),
              pw.SizedBox(height: 6),
              if (signatureBytes != null) ...[
                pw.Image(
                  pw.MemoryImage(signatureBytes),
                  height: 42,
                  width: 155,
                  fit: pw.BoxFit.contain,
                ),
                pw.SizedBox(height: 2),
              ] else
                pw.SizedBox(height: 22),
              pw.Container(
                width: 140,
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    bottom: pw.BorderSide(
                      color: PdfColor.fromInt(0xFF475569),
                      width: 0.7,
                    ),
                  ),
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                'AUTHORIZED SIGNATORY',
                style: pw.TextStyle(
                  fontSize: 6.5,
                  fontWeight: pw.FontWeight.bold,
                  color: _textMuted,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildFooter() {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(vertical: 10),
      decoration: const pw.BoxDecoration(color: _slateDark),
      child: pw.Center(
        child: pw.Text(
          'Town Treasure Groceries - Fresh & Affordable',
          style: pw.TextStyle(
            color: PdfColors.white,
            fontSize: 9,
            fontStyle: pw.FontStyle.italic,
          ),
        ),
      ),
    );
  }

  static Future<Uint8List?> _loadAsset(String path) async {
    try {
      final data = await rootBundle.load(path);
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
