import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../domain/models/models.dart';
import 'reports_view_model.dart';

/// Builds A4 Monthly Client Statement PDFs matching `downloadStatementPDF` in `statements.js`.
class StatementPdfBuilder {
  StatementPdfBuilder._();

  static const PdfColor _leafGreen = PdfColor.fromInt(0xFF61B146);
  static const PdfColor _forestGreen = PdfColor.fromInt(0xFF2E7D32);
  static const PdfColor _slateDark = PdfColor.fromInt(0xFF313A43);
  static const PdfColor _dangerRed = PdfColor.fromInt(0xFFDC2626);
  static const PdfColor _textDark = PdfColor.fromInt(0xFF424242);
  static const PdfColor _textMuted = PdfColor.fromInt(0xFF616161);

  static Future<Uint8List> buildPdfBytes(
    ClientStatementData statement, {
    VaultSettings settings = const VaultSettings(),
    DateTime? generatedDate,
  }) async {
    final logoBytes = await _loadAsset('assets/logo.png');
    final stampBytes = await _loadAsset('assets/stamp.png');
    final signatureBytes = _decodeDataUri(settings.signature);
    final dateText = ReportsViewModel.formatDate(
      (generatedDate ?? DateTime.now()).toIso8601String().substring(0, 10),
    );
    final firstMonthWord = statement.monthName.split(' ').first;

    final doc = pw.Document(
      title: 'Statement_${statement.restaurant.name}_${statement.monthName}',
      author: 'Town Treasure Limited',
    );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(38, 34, 38, 60),
          buildBackground: (_) => _buildBackground(),
        ),
        footer: (_) => _buildFooter(statement),
        build: (_) {
          return [
            _buildHeader(logoBytes, statement, dateText),
            pw.SizedBox(height: 20),
            _buildAddressRow(statement.restaurant),
            pw.SizedBox(height: 18),
            _buildOpeningBalanceBanner(statement, firstMonthWord),
            pw.SizedBox(height: 18),
            _buildTransactionsTable(statement),
            pw.SizedBox(height: 22),
            _buildTotalsAndAgeRow(statement),
            pw.SizedBox(height: 22),
            _buildOfficialStamp(
              stampBytes: stampBytes,
              signatureBytes: signatureBytes,
              dateText: dateText,
            ),
          ];
        },
      ),
    );

    return doc.save();
  }

  static Future<File> writeTempPdfFile(
    ClientStatementData statement, {
    VaultSettings settings = const VaultSettings(),
  }) async {
    final bytes = await buildPdfBytes(statement, settings: settings);
    final dir = await getTemporaryDirectory();
    final safeName =
        statement.restaurant.name.replaceAll(RegExp(r'\s+'), '_');
    final safeMonth = statement.monthName.replaceAll(RegExp(r'\s+'), '_');
    final file = File('${dir.path}/Statement_${safeName}_$safeMonth.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static pw.Widget _buildBackground() {
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
                pw.Container(height: 10, color: _leafGreen),
                pw.Container(height: 4, color: _slateDark),
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

  static pw.Widget _buildHeader(
    Uint8List? logoBytes,
    ClientStatementData statement,
    String dateText,
  ) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (logoBytes != null)
              pw.Image(
                pw.MemoryImage(logoBytes),
                height: 48,
                fit: pw.BoxFit.contain,
              ),
            pw.SizedBox(height: 10),
            pw.Text(
              'MONTHLY STATEMENT',
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
                color: _leafGreen,
              ),
            ),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.SizedBox(height: 16),
            pw.Text(
              'Period: ${statement.monthName}',
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: _textDark,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Generated: $dateText',
              style: const pw.TextStyle(fontSize: 9.5, color: _textMuted),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildAddressRow(Restaurant rest) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'FROM:',
              style: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
                color: _textDark,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Town Treasure Limited',
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: _leafGreen,
              ),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              'Tel: 0708567696',
              style: const pw.TextStyle(fontSize: 9, color: _textMuted),
            ),
            pw.Text(
              'Email: thetowntreasure25@gmail.com',
              style: const pw.TextStyle(fontSize: 9, color: _textMuted),
            ),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'TO:',
              style: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
                color: _textDark,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              rest.name,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: _textDark,
              ),
            ),
            if (rest.address.trim().isNotEmpty)
              pw.Text(
                rest.address,
                style: const pw.TextStyle(fontSize: 9, color: _textMuted),
              ),
            if (rest.phone.trim().isNotEmpty)
              pw.Text(
                rest.phone,
                style: const pw.TextStyle(fontSize: 9, color: _textMuted),
              ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildOpeningBalanceBanner(
    ClientStatementData statement,
    String monthWord,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF8FAFC),
        border: pw.Border.all(color: PdfColor.fromInt(0xFFE2E8F0)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Previous Unpaid Balance (Prior to 1 $monthWord):',
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: _textDark,
            ),
          ),
          pw.Text(
            'KES ${ReportsViewModel.formatMoney(statement.openingBalance)}',
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: statement.openingBalance > 0 ? _dangerRed : _forestGreen,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildTransactionsTable(ClientStatementData statement) {
    final rows = statement.transactions.isEmpty
        ? [
            ['', 'No transactions this month', '', '', '', ''],
          ]
        : statement.transactions
            .map(
              (tx) => [
                ReportsViewModel.formatDate(tx.date).replaceAll('—', '-'),
                tx.desc.replaceAll('—', '-'),
                tx.itemsLabel,
                tx.debit > 0
                    ? 'KES ${ReportsViewModel.formatMoney(tx.debit)}'
                    : '',
                tx.credit > 0
                    ? 'KES ${ReportsViewModel.formatMoney(tx.credit)}'
                    : '',
                'KES ${ReportsViewModel.formatMoney(tx.balance)}',
              ],
            )
            .toList();

    return pw.TableHelper.fromTextArray(
      headers: ['Date', 'Description', 'Details', 'Debit', 'Credit', 'Balance'],
      data: rows,
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(
          color: PdfColor.fromInt(0xFFE2E8F0),
          width: 0.6,
        ),
        top: const pw.BorderSide(color: _slateDark, width: 1),
        bottom: const pw.BorderSide(color: _slateDark, width: 1),
      ),
      headerPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      oddRowDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF8FAFC),
      ),
      columnWidths: {
        0: const pw.FixedColumnWidth(66),
        1: const pw.FlexColumnWidth(2.2),
        2: const pw.FlexColumnWidth(2.1),
        3: const pw.FixedColumnWidth(76),
        4: const pw.FixedColumnWidth(76),
        5: const pw.FixedColumnWidth(82),
      },
      headerStyle: pw.TextStyle(
        color: PdfColors.white,
        fontSize: 8.8,
        fontWeight: pw.FontWeight.bold,
      ),
      cellStyle: const pw.TextStyle(
        fontSize: 8.5,
        color: _textDark,
        lineSpacing: 1.5,
      ),
      headerDecoration: const pw.BoxDecoration(color: _slateDark),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
      },
    );
  }

  static pw.Widget _buildTotalsAndAgeRow(ClientStatementData statement) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        if (statement.closingBalance > 0)
          pw.Container(
            width: 280,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFFFF7ED),
              border: pw.Border.all(color: PdfColor.fromInt(0xFFFED7AA)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Debt Age Analysis',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFF92400E),
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    _ageCol('Current', statement.ageAnalysis.current, _forestGreen),
                    _ageCol(
                      '30 Days',
                      statement.ageAnalysis.days30,
                      PdfColor.fromInt(0xFFD97706),
                    ),
                    _ageCol(
                      '60 Days',
                      statement.ageAnalysis.days60,
                      PdfColor.fromInt(0xFFEA580C),
                    ),
                    _ageCol('90+ Days', statement.ageAnalysis.days90, _dangerRed),
                  ],
                ),
              ],
            ),
          )
        else
          pw.SizedBox(width: 280),
        pw.Container(
          width: 210,
          child: pw.Column(
            children: [
              _summaryLine(
                'Total Invoiced:',
                'KES ${ReportsViewModel.formatMoney(statement.monthInvoicedTotal)}',
                _dangerRed,
              ),
              pw.SizedBox(height: 4),
              _summaryLine(
                'Total Paid:',
                'KES ${ReportsViewModel.formatMoney(statement.monthPaidTotal)}',
                _forestGreen,
              ),
              pw.Divider(color: _leafGreen, thickness: 1.5),
              _summaryLine(
                'Total Amount Owed:',
                'KES ${ReportsViewModel.formatMoney(statement.closingBalance)}',
                statement.closingBalance > 0 ? _dangerRed : _forestGreen,
                bold: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _ageCol(String label, double value, PdfColor color) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 7.5, color: _textMuted)),
        pw.Text(
          'KES ${ReportsViewModel.formatMoney(value)}',
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  static pw.Widget _summaryLine(
    String label,
    String value,
    PdfColor valueColor, {
    bool bold = false,
  }) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: bold ? 10 : 9,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: _textDark,
          ),
        ),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: bold ? 10.5 : 9,
            fontWeight: pw.FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildOfficialStamp({
    required Uint8List? stampBytes,
    required Uint8List? signatureBytes,
    required String dateText,
  }) {
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Container(
        width: 175,
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _slateDark, width: 2),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          children: [
            if (stampBytes != null)
              pw.Image(
                pw.MemoryImage(stampBytes),
                height: 30,
                fit: pw.BoxFit.contain,
              )
            else
              pw.Text(
                'TOWN TREASURE GROCERIES',
                style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
              ),
            pw.SizedBox(height: 4),
            pw.Text(
              'ACCOUNT VERIFIED',
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.black,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              'DATE: $dateText',
              style: const pw.TextStyle(fontSize: 7, color: _dangerRed),
            ),
            pw.SizedBox(height: 4),
            if (signatureBytes != null)
              pw.Image(
                pw.MemoryImage(signatureBytes),
                height: 34,
                fit: pw.BoxFit.contain,
              )
            else ...[
              pw.SizedBox(height: 16),
              pw.Divider(color: PdfColors.black, thickness: 0.6),
              pw.Text('Authorized Signature', style: const pw.TextStyle(fontSize: 6.5)),
            ],
          ],
        ),
      ),
    );
  }

  static pw.Widget _buildFooter(ClientStatementData statement) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _slateDark,
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Thank you for your business, ${statement.restaurant.name}!',
            style: pw.TextStyle(
              color: PdfColors.white,
              fontSize: 8.5,
              fontStyle: pw.FontStyle.italic,
            ),
          ),
          pw.Text(
            'Account Statement - ${statement.monthName}',
            style: const pw.TextStyle(color: PdfColors.white, fontSize: 8),
          ),
        ],
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

  static Uint8List? _decodeDataUri(String? uri) {
    if (uri == null || uri.trim().isEmpty) return null;
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(uri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}
