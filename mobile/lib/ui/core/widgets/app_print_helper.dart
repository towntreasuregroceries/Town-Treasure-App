import 'package:flutter/material.dart';

import '../../../data/services/print_service.dart';
import 'branded_pdf_viewer_screen.dart';
import 'print_options_sheet.dart';

/// Unified preview-and-print launcher used across Invoices, KRA Tax Center,
/// Monthly Statements, Reports, Price Lists, and Personal Documents so every
/// screen exposes consistent A4/thermal paper selection, zoom, and print options.
class AppPrintHelper {
  AppPrintHelper._();

  static Future<void> openPreview(
    BuildContext context, {
    required PrintableDocument document,
    PrintPaperFormat initialPaperFormat = PrintPaperFormat.a4,
    PrintService? printService,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (viewerCtx) => BrandedPdfViewerScreen(
          title: document.title,
          filename: document.filename,
          initialPaperFormat: initialPaperFormat,
          supportsThermalRoll: document.supportsThermalRoll,
          buildPdf: document.buildPdf,
          printService: printService,
          onOpenPrintCenter: (fmt) => showPrintOptionsSheet(
            viewerCtx,
            document: document,
            initialPaperFormat: fmt,
            fromPreview: true,
            printService: printService,
          ),
        ),
      ),
    );
  }

  static Future<void> openPrintCenter(
    BuildContext context, {
    required PrintableDocument document,
    PrintService? printService,
  }) {
    return showPrintOptionsSheet(
      context,
      document: document,
      printService: printService,
    );
  }
}
