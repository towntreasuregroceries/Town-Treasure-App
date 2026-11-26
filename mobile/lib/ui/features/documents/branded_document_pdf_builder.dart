import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/stamp_signature_helper.dart';
import '../invoices/invoice_formatters.dart';

/// Builds official Town Treasure Limited A4 / Letter PDFs for custom
/// [BrandedDocument] records, sharing the exact corporate letterhead curve,
/// watermark, table palette, stamp, and signature styling as [InvoicePdfBuilder].
class BrandedDocumentPdfBuilder {
  BrandedDocumentPdfBuilder._();

  static const PdfColor _leafGreen = PdfColor.fromInt(0xFF61B146);
  static const PdfColor _forestGreen = PdfColor.fromInt(0xFF1B5E20);
  static const PdfColor _slateDark = PdfColor.fromInt(0xFF313A43);
  static const PdfColor _textDark = PdfColor.fromInt(0xFF1E293B);
  static const PdfColor _textMuted = PdfColor.fromInt(0xFF64748B);
  static const PdfColor _altRowBg = PdfColor.fromInt(0xFFF8FAFC);
  static const PdfColor _calloutBg = PdfColor.fromInt(0xFFF0FDF4);
  static const PdfColor _watermarkColor = PdfColor.fromInt(0xFFEBEBEB);
  static const PdfColor _stampRed = PdfColor.fromInt(0xFFDC2626);

  static String pdfFilename(BrandedDocument doc) {
    final rawTitle = doc.title.trim().isNotEmpty ? doc.title.trim() : 'Document';
    final clean = rawTitle
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final prefix = doc.referenceNumber.trim().isNotEmpty
        ? '${doc.referenceNumber.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')}_'
        : 'TTG_';
    return '$prefix${clean.isEmpty ? 'Branded_Document' : clean}.pdf';
  }

  static Future<Uint8List> buildPdfBytes({
    required BrandedDocument document,
    VaultSettings settings = const VaultSettings(),
    PdfPageFormat? pageFormatOverride,
    Uint8List? logoBytesOverride,
    Uint8List? stampBytesOverride,
  }) async {
    final format = pageFormatOverride ??
        (document.pageSize.toLowerCase() == 'letter'
            ? PdfPageFormat.letter
            : PdfPageFormat.a4);

    final horizontalMargin = switch (document.marginPreset) {
      'narrow' => 26.0,
      'wide' => 50.0,
      _ => 36.0,
    };

    final logoBytes =
        logoBytesOverride ?? await _loadAssetBytes('assets/logo.png');
    final stampRaw =
        stampBytesOverride ?? await _loadAssetBytes('assets/stamp.png');
    final stampPrepared = StampSignatureHelper.prepareStampPng(stampRaw);
    final sigBytes = StampSignatureHelper.prepareSignaturePng(settings.signature);

    final logoImage = (logoBytes != null && logoBytes.isNotEmpty)
        ? pw.MemoryImage(logoBytes)
        : null;
    final stampImage = (stampPrepared != null && stampPrepared.isNotEmpty)
        ? pw.MemoryImage(stampPrepared)
        : null;
    final sigImage =
        (sigBytes != null && sigBytes.isNotEmpty) ? pw.MemoryImage(sigBytes) : null;

    final sellerPin =
        document.showKraPin ? settings.kraProfile.normalizedSellerPin : '';
    final displayDate = document.date.trim().isNotEmpty
        ? InvoiceFormatters.formatDisplayDate(document.date)
        : InvoiceFormatters.formatDisplayDate(InvoiceFormatters.todayIso());

    final pdf = pw.Document(
      title: document.title.trim().isNotEmpty
          ? document.title.trim()
          : 'Town Treasure Branded Document',
      author: 'Town Treasure Limited',
    );

    final pageTheme = pw.PageTheme(
      pageFormat: format,
      margin: pw.EdgeInsets.fromLTRB(
        horizontalMargin,
        24,
        horizontalMargin,
        56,
      ),
      buildBackground: (context) => _buildPageBackground(
        context: context,
        document: document,
        logoImage: logoImage,
      ),
    );

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (context) => _buildContinuationHeader(context, document),
        build: (context) => [
          if (document.showLetterheadBanner) pw.SizedBox(height: 88),
          _buildTopTitleAndMeta(
            document: document,
            displayDate: displayDate,
          ),
          pw.SizedBox(height: 16),
          _buildSenderAndRecipientRow(
            document: document,
            sellerPin: sellerPin,
          ),
          if (document.subject.trim().isNotEmpty) ...[
            pw.SizedBox(height: 14),
            _buildSubjectBar(document),
          ],
          pw.SizedBox(height: 16),
          ..._buildContentBlocks(document),
          if (document.showQrCode ||
              document.showStamp ||
              document.showSignature) ...[
            pw.SizedBox(height: 24),
            _buildAuthorizationFooter(
              document: document,
              displayDate: displayDate,
              stampImage: stampImage,
              sigImage: sigImage,
            ),
          ],
        ],
      ),
    );

    return pdf.save();
  }

  static Future<void> sharePdfFile({
    required BrandedDocument document,
    VaultSettings settings = const VaultSettings(),
  }) async {
    final bytes = await buildPdfBytes(document: document, settings: settings);
    final dir = await getTemporaryDirectory();
    final filename = pdfFilename(document);
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf', name: filename)],
        subject: document.title.trim().isNotEmpty
            ? document.title.trim()
            : 'Town Treasure Document',
      ),
    );
  }

  static pw.Widget _buildPageBackground({
    required pw.Context context,
    required BrandedDocument document,
    required pw.MemoryImage? logoImage,
  }) {
    final pageW = context.page.pageFormat.width;
    final pageH = context.page.pageFormat.height;

    return pw.FullPage(
      ignoreMargins: true,
      child: pw.Stack(
        children: [
          if (document.showWatermark)
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
          if (document.showLetterheadBanner && context.pageNumber == 1)
            pw.Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: pw.SizedBox(
                width: pageW,
                height: 102,
                child: pw.Stack(
                  children: [
                    pw.CustomPaint(
                      size: PdfPoint(pageW, 102),
                      painter: (canvas, size) {
                        canvas
                          ..setFillColor(_leafGreen)
                          ..drawRect(0, 0, size.x, size.y)
                          ..fillPath();

                        canvas
                          ..setFillColor(_slateDark)
                          ..moveTo(size.x * 0.30, size.y)
                          ..lineTo(size.x, size.y)
                          ..lineTo(size.x, 20)
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
                        top: 20,
                        child: pw.Image(
                          logoImage,
                          height: 54,
                          fit: pw.BoxFit.contain,
                        ),
                      )
                    else
                      pw.Positioned(
                        left: 36,
                        top: 36,
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
          else if (document.showLetterheadBanner)
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
          pw.Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: pw.Container(
              height: 40,
              color: _slateDark,
              padding: const pw.EdgeInsets.symmetric(horizontal: 36),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      _sanitizeType1Text(
                        document.footerNote.trim().isNotEmpty
                            ? document.footerNote.trim()
                            : 'Town Treasure Limited | Tel: 0708567696 | Nairobi',
                      ),
                      maxLines: 1,
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 8.5,
                        fontStyle: pw.FontStyle.italic,
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 12),
                  pw.Text(
                    'Page ${context.pageNumber} of ${context.pagesCount}',
                    style: const pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 8.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildContinuationHeader(
    pw.Context context,
    BrandedDocument doc,
  ) {
    if (context.pageNumber == 1) return pw.SizedBox.shrink();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 12),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            doc.title.trim().isNotEmpty ? doc.title.trim() : doc.documentType,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: _textMuted,
            ),
          ),
          if (doc.referenceNumber.trim().isNotEmpty)
            pw.Text(
              'Ref: ${doc.referenceNumber.trim()}',
              style: const pw.TextStyle(fontSize: 8.5, color: _textMuted),
            ),
        ],
      ),
    );
  }

  static pw.Widget _buildTopTitleAndMeta({
    required BrandedDocument document,
    required String displayDate,
  }) {
    final badgeLabel = document.documentType.trim().isNotEmpty
        ? document.documentType.trim().toUpperCase()
        : 'OFFICIAL DOCUMENT';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: pw.BoxDecoration(
                  color: _leafGreen,
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Text(
                  badgeLabel,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (document.title.trim().isNotEmpty) ...[
                pw.SizedBox(height: 8),
                pw.Text(
                  document.title.trim(),
                  style: pw.TextStyle(
                    fontSize: 17,
                    fontWeight: pw.FontWeight.bold,
                    color: _slateDark,
                  ),
                ),
              ],
            ],
          ),
        ),
        pw.SizedBox(width: 16),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            if (document.referenceNumber.trim().isNotEmpty)
              pw.Text(
                'Ref: ${document.referenceNumber.trim()}',
                style: pw.TextStyle(
                  fontSize: 9.5,
                  fontWeight: pw.FontWeight.bold,
                  color: _textDark,
                ),
              ),
            pw.SizedBox(height: 3),
            pw.Text(
              'Date: $displayDate',
              style: const pw.TextStyle(fontSize: 9.2, color: _textMuted),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildSenderAndRecipientRow({
    required BrandedDocument document,
    required String sellerPin,
  }) {
    final hasRecipient = document.showRecipientCard &&
        (document.recipientName.trim().isNotEmpty ||
            document.recipientContact.trim().isNotEmpty ||
            document.recipientAddress.trim().isNotEmpty ||
            document.recipientPhone.trim().isNotEmpty ||
            document.recipientKraPin.trim().isNotEmpty);

    final fromCol = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'FROM',
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: _leafGreen,
            letterSpacing: 0.8,
          ),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          'Town Treasure Limited',
          style: pw.TextStyle(
            fontSize: 10.5,
            fontWeight: pw.FontWeight.bold,
            color: _slateDark,
          ),
        ),
        pw.Text(
          'Fresh Grocery & Hospitality Supply | Nairobi',
          style: const pw.TextStyle(fontSize: 8.8, color: _textMuted),
        ),
        pw.Text(
          'Tel: 0708 567 696',
          style: const pw.TextStyle(fontSize: 8.8, color: _textMuted),
        ),
        if (sellerPin.isNotEmpty)
          pw.Text(
            'KRA PIN: $sellerPin',
            style: pw.TextStyle(
              fontSize: 8.5,
              fontWeight: pw.FontWeight.bold,
              color: _textDark,
            ),
          ),
      ],
    );

    if (!hasRecipient) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: _altRowBg,
          borderRadius: pw.BorderRadius.circular(6),
          border: pw.Border.all(color: const PdfColor.fromInt(0xFFE2E8F0)),
        ),
        child: fromCol,
      );
    }

    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: _altRowBg,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFE2E8F0)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: fromCol),
          pw.SizedBox(width: 18),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'TO / RECIPIENT',
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                    color: _leafGreen,
                    letterSpacing: 0.8,
                  ),
                ),
                pw.SizedBox(height: 3),
                if (document.recipientName.trim().isNotEmpty)
                  pw.Text(
                    document.recipientName.trim(),
                    style: pw.TextStyle(
                      fontSize: 10.5,
                      fontWeight: pw.FontWeight.bold,
                      color: _slateDark,
                    ),
                  ),
                if (document.recipientContact.trim().isNotEmpty)
                  pw.Text(
                    'Attn: ${document.recipientContact.trim()}',
                    style: const pw.TextStyle(fontSize: 8.8, color: _textMuted),
                  ),
                if (document.recipientAddress.trim().isNotEmpty)
                  pw.Text(
                    document.recipientAddress.trim(),
                    style: const pw.TextStyle(fontSize: 8.8, color: _textMuted),
                  ),
                if (document.recipientPhone.trim().isNotEmpty)
                  pw.Text(
                    'Tel: ${document.recipientPhone.trim()}',
                    style: const pw.TextStyle(fontSize: 8.8, color: _textMuted),
                  ),
                if (document.showKraPin &&
                    document.recipientKraPin.trim().isNotEmpty)
                  pw.Text(
                    'KRA PIN: ${document.recipientKraPin.trim().toUpperCase()}',
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold,
                      color: _textDark,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildSubjectBar(BrandedDocument document) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const pw.BoxDecoration(
        color: _calloutBg,
        border: pw.Border(
          left: pw.BorderSide(color: _leafGreen, width: 3.5),
        ),
      ),
      child: pw.Text(
        'RE: ${document.subject.trim()}',
        style: pw.TextStyle(
          fontSize: 10.5,
          fontWeight: pw.FontWeight.bold,
          color: _forestGreen,
        ),
      ),
    );
  }

  static List<pw.Widget> _buildContentBlocks(BrandedDocument document) {
    final widgets = <pw.Widget>[];
    var numberedCounter = 0;

    for (final block in document.blocks) {
      if (block.kind == 'numbered') {
        numberedCounter++;
      } else {
        numberedCounter = 0;
      }

      if (block.isDivider) {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: pw.Divider(
              color: const PdfColor.fromInt(0xFFCBD5E1),
              thickness: 0.9,
            ),
          ),
        );
        continue;
      }

      if (block.isTable) {
        if (block.tableRows.isNotEmpty) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 8),
              child: _buildStyledTable(block, document.defaultFontFamily),
            ),
          );
        }
        continue;
      }

      if (block.isSignatory) {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: _buildSignatoryGrid(block),
          ),
        );
        continue;
      }

      final leftIndent = block.indent.clamp(0, 4) * 18.0;
      final textAlign = _resolveTextAlign(block.align);
      final rich = _buildRichText(
        block,
        fallbackFontFamily: document.defaultFontFamily,
        textAlign: textAlign,
      );

      if (block.kind == 'callout') {
        widgets.add(
          pw.Padding(
            padding: pw.EdgeInsets.fromLTRB(leftIndent, 6, 0, 8),
            child: pw.Container(
              width: double.infinity,
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const pw.BoxDecoration(
                color: _calloutBg,
                border: pw.Border(
                  left: pw.BorderSide(color: _leafGreen, width: 3.5),
                ),
              ),
              child: rich,
            ),
          ),
        );
        continue;
      }

      if (block.kind == 'bullet' || block.kind == 'numbered') {
        widgets.add(
          pw.Padding(
            padding: pw.EdgeInsets.fromLTRB(leftIndent + 8, 2, 0, 5),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 18,
                  child: block.kind == 'bullet'
                      ? pw.Padding(
                          padding: pw.EdgeInsets.only(
                            top: (block.fontSize * 0.42).clamp(3.0, 8.0),
                          ),
                          child: pw.Align(
                            alignment: pw.Alignment.centerLeft,
                            child: pw.Container(
                              width: 5,
                              height: 5,
                              decoration: const pw.BoxDecoration(
                                color: _leafGreen,
                                shape: pw.BoxShape.circle,
                              ),
                            ),
                          ),
                        )
                      : pw.Text(
                          '$numberedCounter.',
                          style: pw.TextStyle(
                            fontSize: block.fontSize,
                            fontWeight: pw.FontWeight.bold,
                            color: _leafGreen,
                          ),
                        ),
                ),
                pw.Expanded(child: rich),
              ],
            ),
          ),
        );
        continue;
      }

      final topSpacing = block.kind == 'heading1'
          ? 10.0
          : (block.kind == 'heading2' || block.kind == 'heading3' ? 7.0 : 2.0);
      final bottomSpacing = block.isHeading ? 5.0 : 7.0;

      widgets.add(
        pw.Padding(
          padding:
              pw.EdgeInsets.fromLTRB(leftIndent, topSpacing, 0, bottomSpacing),
          child: rich,
        ),
      );
    }

    return widgets;
  }

  static pw.Widget _buildStyledTable(
    BrandedDocBlock block,
    String fallbackFamily,
  ) {
    final rows = block.tableRows;
    final colCount = rows.fold<int>(
      1,
      (maxC, r) => r.length > maxC ? r.length : maxC,
    );
    final family =
        block.fontFamily.isNotEmpty ? block.fontFamily : fallbackFamily;
    final cellSize = block.fontSize.clamp(8.5, 14.0);

    final pdfRows = <pw.TableRow>[];
    for (var rIdx = 0; rIdx < rows.length; rIdx++) {
      final isHeader = rIdx == 0;
      final rowCells = List<String>.generate(
        colCount,
        (cIdx) => cIdx < rows[rIdx].length ? rows[rIdx][cIdx] : '',
      );

      pdfRows.add(
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: isHeader
                ? _leafGreen
                : (rIdx.isEven ? _altRowBg : PdfColors.white),
          ),
          children: [
            for (final cellText in rowCells)
              pw.Padding(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: _buildCellRichText(
                  cellText,
                  isHeader: isHeader,
                  fontFamily: family,
                  fontSize: isHeader ? cellSize - 0.5 : cellSize,
                ),
              ),
          ],
        ),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(
        color: const PdfColor.fromInt(0xFFE2E8F0),
        width: 0.6,
      ),
      children: pdfRows,
    );
  }

  static pw.Widget _buildCellRichText(
    String text, {
    required bool isHeader,
    required String fontFamily,
    required double fontSize,
  }) {
    final parsed =
        BrandedInlineParser.parse(_sanitizeType1Text(text), baseBold: isHeader);
    return pw.RichText(
      text: pw.TextSpan(
        children: parsed
            .map(
              (s) => pw.TextSpan(
                text: s.text,
                style: _buildPdfTextStyle(
                  family: fontFamily,
                  fontSize: fontSize,
                  bold: s.bold,
                  italic: s.italic,
                  underline: s.underline,
                  color: isHeader ? PdfColors.white : _textDark,
                  lineSpacing: 1.5,
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  static pw.Widget _buildRichText(
    BrandedDocBlock block, {
    required String fallbackFontFamily,
    required pw.TextAlign textAlign,
  }) {
    final effectiveBold = block.bold || block.isHeading;
    final effectiveSize = switch (block.kind) {
      'heading1' => block.fontSize < 15 ? 17.0 : block.fontSize,
      'heading2' => block.fontSize < 13 ? 14.0 : block.fontSize,
      'heading3' => block.fontSize < 11.5 ? 12.5 : block.fontSize,
      _ => block.fontSize,
    };
    final family = block.fontFamily.isNotEmpty
        ? block.fontFamily
        : fallbackFontFamily;
    final color = _parseHexColor(block.colorHex);
    final lineGap = ((block.lineSpacing - 1.0) * effectiveSize).clamp(1.0, 14.0);

    final spans = BrandedInlineParser.parse(
      _sanitizeType1Text(block.text),
      baseBold: effectiveBold,
      baseItalic: block.italic,
      baseUnderline: block.underline,
    );

    return pw.RichText(
      textAlign: textAlign,
      text: pw.TextSpan(
        children: spans
            .map(
              (s) => pw.TextSpan(
                text: s.text,
                style: _buildPdfTextStyle(
                  family: family,
                  fontSize: effectiveSize,
                  bold: s.bold,
                  italic: s.italic,
                  underline: s.underline,
                  color: color,
                  lineSpacing: lineGap,
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  static pw.TextStyle _buildPdfTextStyle({
    required String family,
    required double fontSize,
    required bool bold,
    required bool italic,
    required bool underline,
    required PdfColor color,
    required double lineSpacing,
  }) {
    final norm = family.toLowerCase();
    pw.Font baseFont;
    if (norm == 'serif') {
      baseFont = bold && italic
          ? pw.Font.timesBoldItalic()
          : (bold
              ? pw.Font.timesBold()
              : (italic ? pw.Font.timesItalic() : pw.Font.times()));
    } else if (norm == 'mono') {
      baseFont = bold && italic
          ? pw.Font.courierBoldOblique()
          : (bold
              ? pw.Font.courierBold()
              : (italic ? pw.Font.courierOblique() : pw.Font.courier()));
    } else {
      baseFont = bold && italic
          ? pw.Font.helveticaBoldOblique()
          : (bold
              ? pw.Font.helveticaBold()
              : (italic ? pw.Font.helveticaOblique() : pw.Font.helvetica()));
    }

    return pw.TextStyle(
      font: baseFont,
      fontSize: fontSize,
      color: color,
      lineSpacing: lineSpacing,
      decoration:
          underline ? pw.TextDecoration.underline : pw.TextDecoration.none,
    );
  }

  static pw.Widget _buildSignatoryGrid(BrandedDocBlock block) {
    final dispatchHint =
        block.isLegacySignatoryParagraph ? '' : block.text.trim();
    const borderCol = PdfColor.fromInt(0xFF94A3B8);
    const dividerCol = PdfColor.fromInt(0xFFCBD5E1);
    const lineCol = PdfColor.fromInt(0xFF334155);
    const headerBg = PdfColor.fromInt(0xFFF1F5F9);
    const labelCol = PdfColor.fromInt(0xFF475569);

    pw.Widget buildWritingField({
      required String label,
      required double writingHeight,
      String prefill = '',
    }) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: 7.8,
              fontWeight: pw.FontWeight.bold,
              color: labelCol,
            ),
          ),
          pw.Container(
            width: double.infinity,
            height: writingHeight,
            alignment: pw.Alignment.bottomLeft,
            padding: const pw.EdgeInsets.only(bottom: 3),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: lineCol, width: 0.8),
              ),
            ),
            child: prefill.isNotEmpty
                ? pw.Text(
                    _sanitizeType1Text(prefill),
                    maxLines: 1,
                    style: pw.TextStyle(
                      fontSize: 9.0,
                      fontWeight: pw.FontWeight.bold,
                      color: _textDark,
                    ),
                  )
                : null,
          ),
        ],
      );
    }

    return pw.Container(
      width: double.infinity,
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: borderCol, width: 0.9),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const pw.BoxDecoration(
              color: headerBg,
              borderRadius: pw.BorderRadius.vertical(
                top: pw.Radius.circular(5.2),
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'DISPATCH & RECEIVING SIGNATORY',
                  style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                    color: _slateDark,
                    letterSpacing: 0.6,
                  ),
                ),
                pw.Text(
                  'Complete in ink upon physical verification',
                  style: pw.TextStyle(
                    fontSize: 7.4,
                    fontStyle: pw.FontStyle.italic,
                    color: _textMuted,
                  ),
                ),
              ],
            ),
          ),
          pw.Container(height: 0.8, color: dividerCol),
          pw.Padding(
            padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  flex: 38,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        '1. DISPATCHED BY (SUPPLIER)',
                        style: pw.TextStyle(
                          fontSize: 7.8,
                          fontWeight: pw.FontWeight.bold,
                          color: _forestGreen,
                          letterSpacing: 0.4,
                        ),
                      ),
                      pw.SizedBox(height: 7),
                      buildWritingField(
                        label: 'Full Name:',
                        writingHeight: 24,
                      ),
                      pw.SizedBox(height: 9),
                      buildWritingField(
                        label: 'Dispatcher Signature:',
                        writingHeight: 28,
                      ),
                      pw.SizedBox(height: 9),
                      buildWritingField(
                        label: 'Dispatch Time / Vehicle:',
                        writingHeight: 20,
                        prefill: dispatchHint,
                      ),
                    ],
                  ),
                ),
                pw.Container(
                  width: 0.8,
                  height: 128,
                  margin: const pw.EdgeInsets.symmetric(horizontal: 10),
                  color: dividerCol,
                ),
                pw.Expanded(
                  flex: 38,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        '2. RECEIVED BY (CLIENT)',
                        style: pw.TextStyle(
                          fontSize: 7.8,
                          fontWeight: pw.FontWeight.bold,
                          color: _forestGreen,
                          letterSpacing: 0.4,
                        ),
                      ),
                      pw.SizedBox(height: 7),
                      buildWritingField(
                        label: 'Full Name & Designation:',
                        writingHeight: 24,
                      ),
                      pw.SizedBox(height: 9),
                      buildWritingField(
                        label: 'Receiver Signature:',
                        writingHeight: 28,
                      ),
                      pw.SizedBox(height: 9),
                      buildWritingField(
                        label: 'Arrival Date & Time:',
                        writingHeight: 20,
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(width: 10),
                pw.Expanded(
                  flex: 26,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        '3. CLIENT STAMP',
                        style: pw.TextStyle(
                          fontSize: 7.8,
                          fontWeight: pw.FontWeight.bold,
                          color: _forestGreen,
                          letterSpacing: 0.4,
                        ),
                      ),
                      pw.SizedBox(height: 7),
                      pw.Container(
                        width: double.infinity,
                        height: 118,
                        padding: const pw.EdgeInsets.all(6),
                        alignment: pw.Alignment.bottomCenter,
                        decoration: pw.BoxDecoration(
                          color: const PdfColor.fromInt(0xFFFAFAFA),
                          borderRadius: pw.BorderRadius.circular(5),
                          border: pw.Border.all(
                            color: borderCol,
                            width: 0.8,
                            style: pw.BorderStyle.dashed,
                          ),
                        ),
                        child: pw.Text(
                          'Official Receiving\nStamp & Date',
                          textAlign: pw.TextAlign.center,
                          style: const pw.TextStyle(
                            fontSize: 6.8,
                            color: PdfColor.fromInt(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildAuthorizationFooter({
    required BrandedDocument document,
    required String displayDate,
    required pw.MemoryImage? stampImage,
    required pw.MemoryImage? sigImage,
  }) {
    final showRightBox = document.showStamp || document.showSignature;
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        if (document.showQrCode)
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Official Verification:',
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: _textDark,
                    ),
                  ),
                  pw.SizedBox(height: 5),
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: 'https://towntreasuregroceries.com',
                    width: 60,
                    height: 60,
                    color: _slateDark,
                  ),
                ],
              ),
              pw.SizedBox(width: 10),
              pw.SizedBox(
                width: 145,
                child: pw.Text(
                  'Issued by Town Treasure Limited.\nScan QR to visit our official\nportal & verify contact details.',
                  style: const pw.TextStyle(fontSize: 7.8, color: _textMuted),
                ),
              ),
            ],
          )
        else
          pw.SizedBox.shrink(),
        if (showRightBox)
          pw.Container(
            width: 200,
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _slateDark, width: 2.0),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                if (document.showStamp) ...[
                  if (stampImage != null)
                    pw.Image(
                      stampImage,
                      height: 46,
                      width: 156,
                      fit: pw.BoxFit.contain,
                    )
                  else
                    pw.Text(
                      'TOWN TREASURE LIMITED',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontSize: 8.5,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.black,
                      ),
                    ),
                  pw.SizedBox(height: 5),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border.symmetric(
                        horizontal:
                            pw.BorderSide(color: _slateDark, width: 0.7),
                      ),
                    ),
                    child: pw.Text(
                      document.stampCaption.trim().isNotEmpty
                          ? document.stampCaption.trim().toUpperCase()
                          : 'AUTHORIZED',
                      style: pw.TextStyle(
                        fontSize: 10.8,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.black,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'DATE: $displayDate',
                    style: pw.TextStyle(
                      font: pw.Font.courierBold(),
                      fontSize: 8.2,
                      color: _stampRed,
                    ),
                  ),
                ],
                if (document.showSignature) ...[
                  pw.SizedBox(height: 6),
                  if (sigImage != null) ...[
                    pw.Image(
                      sigImage,
                      height: 44,
                      width: 160,
                      fit: pw.BoxFit.contain,
                    ),
                    pw.SizedBox(height: 2),
                  ] else
                    pw.SizedBox(height: 24),
                  pw.Container(
                    width: 145,
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
              ],
            ),
          ),
      ],
    );
  }

  static pw.TextAlign _resolveTextAlign(String align) {
    return switch (align.toLowerCase()) {
      'center' => pw.TextAlign.center,
      'right' => pw.TextAlign.right,
      'justify' => pw.TextAlign.justify,
      _ => pw.TextAlign.left,
    };
  }

  static PdfColor _parseHexColor(String hex) {
    final cleaned = hex.trim().replaceAll('#', '');
    if (cleaned.length == 6) {
      final val = int.tryParse('FF$cleaned', radix: 16);
      if (val != null) return PdfColor.fromInt(val);
    }
    return _textDark;
  }

  static String _sanitizeType1Text(String input) {
    return input
        .replaceAll('·', '|')
        .replaceAll('•', '-')
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"');
  }

  static Future<Uint8List?> _loadAssetBytes(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
