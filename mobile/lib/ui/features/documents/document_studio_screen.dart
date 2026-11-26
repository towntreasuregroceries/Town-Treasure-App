import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/ocr_consensus_service.dart';
import '../../../data/services/personal_vault_service.dart';
import '../../../data/services/print_service.dart';
import '../../../domain/models/models.dart';
import '../../core/stamp_signature_helper.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/app_print_helper.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../../core/widgets/scoped_text_controllers.dart';
import 'branded_document_pdf_builder.dart';
import 'document_ocr_converter.dart';
import 'document_ocr_import_sheet.dart';

/// Custom [TextEditingController] that renders inline `**bold**`, `*italic*`,
/// and `__underline__` spans live inside the editor while keeping exact UTF-16
/// cursor & selection offsets.
class WordRichTextController extends TextEditingController {
  WordRichTextController({super.text});

  static final RegExp _inlineMarkers = RegExp(
    r'(_{3,}|\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|__(?!_)([^\n]+?)(?<!_)__(?!_)|\*(.+?)\*)',
    dotAll: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final raw = value.text;
    if (raw.isEmpty) {
      return TextSpan(style: style, text: '');
    }

    final markerStyle = (style ?? const TextStyle()).copyWith(
      color: AppTheme.slateMuted.withValues(alpha: 0.42),
      fontWeight: FontWeight.w400,
    );

    final children = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inlineMarkers.allMatches(raw)) {
      if (m.start > cursor) {
        children.add(
          TextSpan(style: style, text: raw.substring(cursor, m.start)),
        );
      }

      final full = m.group(0) ?? '';
      if (full.startsWith('___')) {
        children.add(TextSpan(style: style, text: full));
      } else if (m.group(2) != null) {
        final inner = m.group(2)!;
        children.add(TextSpan(style: markerStyle, text: '***'));
        children.add(
          TextSpan(
            style: (style ?? const TextStyle()).copyWith(
              fontWeight: FontWeight.w800,
              fontStyle: FontStyle.italic,
            ),
            text: inner,
          ),
        );
        children.add(TextSpan(style: markerStyle, text: '***'));
      } else if (m.group(3) != null) {
        final inner = m.group(3)!;
        children.add(TextSpan(style: markerStyle, text: '**'));
        children.add(
          TextSpan(
            style: (style ?? const TextStyle()).copyWith(
              fontWeight: FontWeight.w800,
            ),
            text: inner,
          ),
        );
        children.add(TextSpan(style: markerStyle, text: '**'));
      } else if (m.group(4) != null) {
        final inner = m.group(4)!;
        children.add(TextSpan(style: markerStyle, text: '__'));
        children.add(
          TextSpan(
            style: (style ?? const TextStyle()).copyWith(
              decoration: TextDecoration.underline,
            ),
            text: inner,
          ),
        );
        children.add(TextSpan(style: markerStyle, text: '__'));
      } else if (m.group(5) != null) {
        final inner = m.group(5)!;
        children.add(TextSpan(style: markerStyle, text: '*'));
        children.add(
          TextSpan(
            style: (style ?? const TextStyle()).copyWith(
              fontStyle: FontStyle.italic,
            ),
            text: inner,
          ),
        );
        children.add(TextSpan(style: markerStyle, text: '*'));
      }
      cursor = m.end;
    }

    if (cursor < raw.length) {
      children.add(TextSpan(style: style, text: raw.substring(cursor)));
    }

    return TextSpan(style: style, children: children);
  }
}

/// Branded Document Studio Hub: create new documents from Town Treasure
/// templates or manage existing encrypted branded documents.
class DocumentStudioScreen extends StatefulWidget {
  const DocumentStudioScreen({
    super.key,
    this.vault,
    this.personalVaultService,
    this.ocrService,
  });

  final VaultRepository? vault;
  final PersonalVaultService? personalVaultService;
  final OcrConsensusService? ocrService;

  @override
  State<DocumentStudioScreen> createState() => _DocumentStudioScreenState();
}

class _DocumentStudioScreenState extends State<DocumentStudioScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  VaultRepository get _vault => widget.vault ?? context.read<VaultRepository>();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _createFromTemplate(BrandedDocTemplate template) async {
    final nextRef = BrandedDocument.generateReferenceNumber(
      _vault.brandedDocuments.length + 1,
    );
    final created = BrandedDocument.fromTemplate(
      template,
      refNumber: nextRef,
    );
    await _vault.saveBrandedDocument(created);
    if (!mounted) return;
    await _openEditor(created);
  }

  Future<void> _openEditor(BrandedDocument doc) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BrandedDocumentEditorScreen(
          initialDocument: doc,
          vault: _vault,
          personalVaultService: widget.personalVaultService,
          ocrService: widget.ocrService,
        ),
      ),
    );
  }

  Future<void> _openSmartOcrConverter({
    DocSmartConversionMode initialMode = DocSmartConversionMode.deliveryNote,
    bool startOnSavedInvoicesTab = false,
  }) async {
    final output = await DocumentOcrImportSheet.show(
      context,
      vault: _vault,
      ocrService: widget.ocrService,
      initialMode: initialMode,
      startOnSavedInvoicesTab: startOnSavedInvoicesTab,
    );
    if (output == null || !mounted) return;
    await _vault.saveBrandedDocument(output.document);
    if (!mounted) return;
    await _openEditor(output.document);
  }

  Future<void> _duplicateDocument(BrandedDocument doc) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final copy = doc.copyWith(
      id: AppHelpers.genId(),
      title: '${doc.title} (Copy)',
      referenceNumber: BrandedDocument.generateReferenceNumber(
        _vault.brandedDocuments.length + 1,
      ),
      createdAt: nowIso,
      updatedAt: nowIso,
      clearDeletedAt: true,
    );
    await _vault.saveBrandedDocument(copy);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Duplicated "${doc.title}".'),
        backgroundColor: AppTheme.forestGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmDelete(BrandedDocument doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Branded Document'),
        content: Text('Delete "${doc.title}" from your workspace?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _vault.deleteBrandedDocument(doc.id);
    }
  }

  Future<void> _previewDocument(BrandedDocument doc) async {
    final format = doc.pageSize.toLowerCase() == 'letter'
        ? PrintPaperFormat.letter
        : PrintPaperFormat.a4;
    await AppPrintHelper.openPreview(
      context,
      initialPaperFormat: format,
      document: PrintableDocument(
        title: doc.title.trim().isNotEmpty ? doc.title.trim() : doc.documentType,
        filename: BrandedDocumentPdfBuilder.pdfFilename(doc),
        supportsThermalRoll: false,
        buildPdf: (pdfFmt) => BrandedDocumentPdfBuilder.buildPdfBytes(
          document: doc,
          settings: _vault.settings,
          pageFormatOverride: pdfFmt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vault,
      builder: (context, _) {
        final allDocs = _vault.brandedDocuments;
        final q = _query.trim().toLowerCase();
        final docs = q.isEmpty
            ? allDocs
            : allDocs.where((d) {
                return d.title.toLowerCase().contains(q) ||
                    d.documentType.toLowerCase().contains(q) ||
                    d.recipientName.toLowerCase().contains(q) ||
                    d.subject.toLowerCase().contains(q) ||
                    d.referenceNumber.toLowerCase().contains(q);
              }).toList();

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Branded Document Studio'),
            actions: [
              IconButton(
                key: const Key('btn_studio_ocr'),
                tooltip: 'Scan Invoice / Document via OCR',
                onPressed: () => _openSmartOcrConverter(
                  initialMode: DocSmartConversionMode.deliveryNote,
                ),
                icon: const Icon(Icons.document_scanner_outlined),
              ),
              IconButton(
                key: const Key('btn_new_blank_branded_doc'),
                tooltip: 'New Blank Branded Document',
                onPressed: () => _createFromTemplate(BrandedDocTemplate.blank),
                icon: const Icon(Icons.note_add_outlined),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            key: const Key('fab_new_branded_doc'),
            backgroundColor: AppTheme.forestGreen,
            foregroundColor: Colors.white,
            onPressed: () =>
                _createFromTemplate(BrandedDocTemplate.businessLetter),
            icon: const Icon(Icons.add),
            label: const Text('New Document'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 88),
            children: [
              Card(
                color: AppTheme.surfaceCard,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.document_scanner_outlined,
                            color: AppTheme.forestGreen,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Smart OCR & Invoice-to-Delivery-Note',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: AppTheme.slateInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Scan a paper invoice or LPO into a Delivery Note (prices & fee rows automatically stripped), auto-priced Quotation, or editable Word page — or convert any saved invoice in 1 tap.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const Key('btn_hub_scan_delivery_note'),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => _openSmartOcrConverter(
                              initialMode: DocSmartConversionMode.deliveryNote,
                            ),
                            icon: const Icon(
                              Icons.local_shipping_outlined,
                              size: 16,
                            ),
                            label: const Text('Scan -> Delivery Note'),
                          ),
                          FilledButton.tonalIcon(
                            key: const Key('btn_hub_from_saved_invoice'),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => _openSmartOcrConverter(
                              initialMode: DocSmartConversionMode.deliveryNote,
                              startOnSavedInvoicesTab: true,
                            ),
                            icon: const Icon(
                              Icons.receipt_long_outlined,
                              size: 16,
                            ),
                            label: const Text('From Saved Invoice'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('btn_hub_scan_any_doc'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => _openSmartOcrConverter(
                              initialMode:
                                  DocSmartConversionMode.fullEditableDocument,
                            ),
                            icon: const Icon(
                              Icons.photo_camera_outlined,
                              size: 16,
                            ),
                            label: const Text('Scan Quote / Letter'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'START A NEW BRANDED DOCUMENT',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppTheme.slateMuted,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 112,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _TemplateCard(
                      key: const Key('tpl_blank_doc'),
                      icon: Icons.insert_drive_file_outlined,
                      title: 'Blank Page',
                      subtitle: 'Official letterhead',
                      accent: AppTheme.forestGreen,
                      onTap: () =>
                          _createFromTemplate(BrandedDocTemplate.blank),
                    ),
                    const SizedBox(width: 10),
                    _TemplateCard(
                      key: const Key('tpl_business_letter'),
                      icon: Icons.mark_email_read_outlined,
                      title: 'Business Letter',
                      subtitle: 'Formal client letter',
                      accent: const Color(0xFF0F3D24),
                      onTap: () => _createFromTemplate(
                        BrandedDocTemplate.businessLetter,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _TemplateCard(
                      key: const Key('tpl_quotation'),
                      icon: Icons.table_chart_outlined,
                      title: 'Quotation',
                      subtitle: 'Pricing table & terms',
                      accent: AppTheme.leafGreen,
                      onTap: () =>
                          _createFromTemplate(BrandedDocTemplate.quotation),
                    ),
                    const SizedBox(width: 10),
                    _TemplateCard(
                      key: const Key('tpl_notice_memo'),
                      icon: Icons.campaign_outlined,
                      title: 'Notice / Memo',
                      subtitle: 'Advisory & bullets',
                      accent: AppTheme.info,
                      onTap: () =>
                          _createFromTemplate(BrandedDocTemplate.noticeMemo),
                    ),
                    const SizedBox(width: 10),
                    _TemplateCard(
                      key: const Key('tpl_delivery_note'),
                      icon: Icons.local_shipping_outlined,
                      title: 'Delivery Note',
                      subtitle: 'Dispatch sign-off',
                      accent: AppTheme.warning,
                      onTap: () =>
                          _createFromTemplate(BrandedDocTemplate.deliveryNote),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search letters, quotations, recipients...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'SAVED DOCUMENTS (${docs.length})',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppTheme.slateMuted,
                ),
              ),
              const SizedBox(height: 8),
              if (docs.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.article_outlined,
                          size: 40,
                          color: AppTheme.slateMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          allDocs.isEmpty
                              ? 'No custom branded documents yet'
                              : 'No documents match your search',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Pick any template above to open the MS Word-style workspace with Town Treasure PDF letterhead, fonts, tables, official stamp, and signature.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...docs.map(
                  (doc) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openEditor(doc),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: AppTheme.sageTint,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.description_outlined,
                                  color: AppTheme.forestGreen,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppTheme.leafGreen
                                                .withValues(alpha: 0.16),
                                            borderRadius:
                                                BorderRadius.circular(5),
                                          ),
                                          child: Text(
                                            doc.documentType,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800,
                                              color: AppTheme.forestGreenDeep,
                                            ),
                                          ),
                                        ),
                                        if (doc.referenceNumber
                                            .trim()
                                            .isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              doc.referenceNumber,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.slateMuted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      doc.title.trim().isNotEmpty
                                          ? doc.title
                                          : 'Untitled Document',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateInk,
                                      ),
                                    ),
                                    if (doc.recipientName.trim().isNotEmpty ||
                                        doc.subject.trim().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        [
                                          if (doc.recipientName
                                              .trim()
                                              .isNotEmpty)
                                            'To: ${doc.recipientName.trim()}',
                                          if (doc.subject.trim().isNotEmpty)
                                            doc.subject.trim(),
                                        ].join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          color: AppTheme.slateMuted,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Text(
                                      'Date: ${doc.date.isNotEmpty ? doc.date : 'Today'} · ${doc.blocks.length} block(s)',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        color: AppTheme.slateMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                onSelected: (action) {
                                  switch (action) {
                                    case 'preview':
                                      _previewDocument(doc);
                                    case 'duplicate':
                                      _duplicateDocument(doc);
                                    case 'delete':
                                      _confirmDelete(doc);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'preview',
                                    child: Text('Preview / Print PDF'),
                                  ),
                                  PopupMenuItem(
                                    value: 'duplicate',
                                    child: Text('Duplicate'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(
                                      'Delete',
                                      style: TextStyle(color: AppTheme.danger),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 142,
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 19, color: accent),
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: AppTheme.slateInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _WordRibbonTab { home, insert, layout, brandExport }

/// Full MS Word-style Branded Document Editor with tabbed formatting ribbon,
/// Undo/Redo stack, inline selection & paragraph formatting, interactive tables,
/// live Town Treasure A4 sheet canvas, and unified PDF preview/print/share/vault archive.
class BrandedDocumentEditorScreen extends StatefulWidget {
  const BrandedDocumentEditorScreen({
    super.key,
    required this.initialDocument,
    required this.vault,
    this.personalVaultService,
    this.ocrService,
  });

  final BrandedDocument initialDocument;
  final VaultRepository vault;
  final PersonalVaultService? personalVaultService;
  final OcrConsensusService? ocrService;

  @override
  State<BrandedDocumentEditorScreen> createState() =>
      _BrandedDocumentEditorScreenState();
}

class _BrandedDocumentEditorScreenState
    extends State<BrandedDocumentEditorScreen> {
  static const List<({String label, String hex, Color color})> _colorPalette = [
    (label: 'Ink', hex: '#1E293B', color: Color(0xFF1E293B)),
    (label: 'Forest', hex: '#1B5E20', color: Color(0xFF1B5E20)),
    (label: 'Leaf', hex: '#61B146', color: Color(0xFF61B146)),
    (label: 'Crimson', hex: '#B91C1C', color: Color(0xFFB91C1C)),
    (label: 'Navy', hex: '#1D4ED8', color: Color(0xFF1D4ED8)),
    (label: 'Muted', hex: '#64748B', color: Color(0xFF64748B)),
  ];

  late BrandedDocument _doc;
  _WordRibbonTab _activeTab = _WordRibbonTab.home;
  String? _activeBlockId;
  bool _isSaving = false;
  Timer? _autoSaveTimer;

  final List<BrandedDocument> _undoStack = [];
  final List<BrandedDocument> _redoStack = [];

  late final TextEditingController _titleCtrl;
  late final TextEditingController _subjectCtrl;
  late final TextEditingController _recipientNameCtrl;
  late final TextEditingController _recipientContactCtrl;
  late final TextEditingController _recipientAddressCtrl;
  late final TextEditingController _recipientPhoneCtrl;
  late final TextEditingController _recipientPinCtrl;

  final Map<String, WordRichTextController> _blockCtrls = {};
  final Map<String, FocusNode> _blockFocusNodes = {};

  @override
  void initState() {
    super.initState();
    _doc = widget.initialDocument;
    if (_doc.blocks.isNotEmpty) {
      _activeBlockId = _doc.blocks.first.id;
    }
    _titleCtrl = TextEditingController(text: _doc.title);
    _subjectCtrl = TextEditingController(text: _doc.subject);
    _recipientNameCtrl = TextEditingController(text: _doc.recipientName);
    _recipientContactCtrl = TextEditingController(text: _doc.recipientContact);
    _recipientAddressCtrl = TextEditingController(text: _doc.recipientAddress);
    _recipientPhoneCtrl = TextEditingController(text: _doc.recipientPhone);
    _recipientPinCtrl = TextEditingController(text: _doc.recipientKraPin);
    _syncBlockControllers();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _titleCtrl.dispose();
    _subjectCtrl.dispose();
    _recipientNameCtrl.dispose();
    _recipientContactCtrl.dispose();
    _recipientAddressCtrl.dispose();
    _recipientPhoneCtrl.dispose();
    _recipientPinCtrl.dispose();
    for (final c in _blockCtrls.values) {
      c.dispose();
    }
    for (final f in _blockFocusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _syncBlockControllers() {
    final validIds = _doc.blocks.map((b) => b.id).toSet();
    final staleIds =
        _blockCtrls.keys.where((id) => !validIds.contains(id)).toList();
    for (final id in staleIds) {
      _blockCtrls.remove(id)?.dispose();
      _blockFocusNodes.remove(id)?.dispose();
    }
    for (final block in _doc.blocks) {
      if (block.isTable || block.isDivider) continue;
      final ctrl = _blockCtrls.putIfAbsent(
        block.id,
        () => WordRichTextController(text: block.text),
      );
      if (ctrl.text != block.text) {
        ctrl.value = ctrl.value.copyWith(
          text: block.text,
          selection: TextSelection.collapsed(offset: block.text.length),
        );
      }
      _blockFocusNodes.putIfAbsent(block.id, () {
        final node = FocusNode();
        node.addListener(() {
          if (node.hasFocus && mounted && _activeBlockId != block.id) {
            setState(() => _activeBlockId = block.id);
          }
        });
        return node;
      });
    }
  }

  BrandedDocBlock? get _activeBlock {
    if (_doc.blocks.isEmpty) return null;
    if (_activeBlockId != null) {
      final idx = _doc.blocks.indexWhere((b) => b.id == _activeBlockId);
      if (idx >= 0) return _doc.blocks[idx];
    }
    return _doc.blocks.first;
  }

  void _pushUndoSnapshot() {
    _undoStack.add(_doc);
    if (_undoStack.length > 40) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _applyDocUpdate(
    BrandedDocument next, {
    bool recordUndo = true,
    bool syncControllers = true,
  }) {
    if (recordUndo) {
      _pushUndoSnapshot();
    }
    setState(() {
      _doc = next;
      if (syncControllers) {
        _syncBlockControllers();
      }
    });
    _scheduleAutoSave();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_doc);
    final prev = _undoStack.removeLast();
    setState(() {
      _doc = prev;
      _titleCtrl.text = _doc.title;
      _subjectCtrl.text = _doc.subject;
      _recipientNameCtrl.text = _doc.recipientName;
      _recipientContactCtrl.text = _doc.recipientContact;
      _recipientAddressCtrl.text = _doc.recipientAddress;
      _recipientPhoneCtrl.text = _doc.recipientPhone;
      _recipientPinCtrl.text = _doc.recipientKraPin;
      _syncBlockControllers();
    });
    _scheduleAutoSave();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_doc);
    final next = _redoStack.removeLast();
    setState(() {
      _doc = next;
      _titleCtrl.text = _doc.title;
      _subjectCtrl.text = _doc.subject;
      _recipientNameCtrl.text = _doc.recipientName;
      _recipientContactCtrl.text = _doc.recipientContact;
      _recipientAddressCtrl.text = _doc.recipientAddress;
      _recipientPhoneCtrl.text = _doc.recipientPhone;
      _recipientPinCtrl.text = _doc.recipientKraPin;
      _syncBlockControllers();
    });
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 900), () {
      _saveNow(silent: true);
    });
  }

  Future<void> _saveNow({bool silent = false}) async {
    _autoSaveTimer?.cancel();
    if (!silent && mounted) {
      setState(() => _isSaving = true);
    }
    try {
      await widget.vault.saveBrandedDocument(_doc);
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Branded document saved to encrypted vault.'),
            backgroundColor: AppTheme.forestGreen,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _mutateActiveBlock(
    BrandedDocBlock Function(BrandedDocBlock current) transform,
  ) {
    final active = _activeBlock;
    if (active == null) return;
    final nextBlocks = _doc.blocks
        .map((b) => b.id == active.id ? transform(b) : b)
        .toList();
    _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
  }

  void _toggleInlineOrBlockStyle({
    required String marker,
    required BrandedDocBlock Function(BrandedDocBlock b) toggleBlockProp,
  }) {
    final active = _activeBlock;
    if (active == null || active.isTable || active.isDivider) return;
    final ctrl = _blockCtrls[active.id];
    if (ctrl != null &&
        ctrl.selection.isValid &&
        !ctrl.selection.isCollapsed) {
      _pushUndoSnapshot();
      final nextVal =
          BrandedInlineParser.toggleSelectionMarker(ctrl.value, marker);
      ctrl.value = nextVal;
      final nextBlocks = _doc.blocks
          .map((b) => b.id == active.id ? b.copyWith(text: nextVal.text) : b)
          .toList();
      setState(() => _doc = _doc.copyWith(blocks: nextBlocks));
      _scheduleAutoSave();
      return;
    }
    _mutateActiveBlock(toggleBlockProp);
  }

  void _insertBlock(BrandedDocBlock newBlock) {
    final nextBlocks = List<BrandedDocBlock>.from(_doc.blocks);
    final activeIdx = _activeBlockId == null
        ? -1
        : nextBlocks.indexWhere((b) => b.id == _activeBlockId);
    if (activeIdx >= 0 && activeIdx < nextBlocks.length - 1) {
      nextBlocks.insert(activeIdx + 1, newBlock);
    } else {
      nextBlocks.add(newBlock);
    }
    _activeBlockId = newBlock.id;
    _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blockFocusNodes[newBlock.id]?.requestFocus();
    });
  }

  void _moveBlock(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _doc.blocks.length) return;
    final nextBlocks = List<BrandedDocBlock>.from(_doc.blocks);
    final item = nextBlocks.removeAt(index);
    nextBlocks.insert(target, item);
    _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
  }

  void _deleteBlock(int index) {
    if (_doc.blocks.length <= 1) {
      final cleared = BrandedDocBlock(id: AppHelpers.genId());
      _activeBlockId = cleared.id;
      _applyDocUpdate(_doc.copyWith(blocks: [cleared]));
      return;
    }
    final nextBlocks = List<BrandedDocBlock>.from(_doc.blocks)
      ..removeAt(index);
    _activeBlockId = nextBlocks.first.id;
    _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
  }

  Future<void> _pickRestaurantRecipient() async {
    final restaurants = widget.vault.restaurants;
    if (restaurants.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved restaurant clients found in vault yet.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final chosen = await showModalBottomSheet<Restaurant>(
      context: context,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Fill Recipient from Saved Client',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.slateInk,
                ),
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: restaurants.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, idx) {
                  final r = restaurants[idx];
                  return ListTile(
                    leading: const Icon(
                      Icons.storefront_outlined,
                      color: AppTheme.forestGreen,
                    ),
                    title: Text(
                      r.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        if (r.contact.isNotEmpty) r.contact,
                        if (r.phone.isNotEmpty) r.phone,
                        if (r.kraPin.isNotEmpty) 'PIN: ${r.kraPin}',
                      ].join(' · '),
                    ),
                    onTap: () => Navigator.of(ctx).pop(r),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    _recipientNameCtrl.text = chosen.name;
    _recipientContactCtrl.text = chosen.contact;
    _recipientAddressCtrl.text = chosen.address;
    _recipientPhoneCtrl.text = chosen.phone;
    _recipientPinCtrl.text = chosen.kraPin;
    _applyDocUpdate(
      _doc.copyWith(
        showRecipientCard: true,
        recipientName: chosen.name,
        recipientContact: chosen.contact,
        recipientAddress: chosen.address,
        recipientPhone: chosen.phone,
        recipientKraPin: chosen.kraPin,
      ),
      syncControllers: false,
    );
  }

  Future<void> _openTableDialog({BrandedDocBlock? existingTable}) async {
    var rowsCount = existingTable != null ? existingTable.tableRows.length : 4;
    var colsCount = existingTable != null && existingTable.tableRows.isNotEmpty
        ? existingTable.tableRows.first.length
        : 3;

    if (existingTable == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setModalState) => AlertDialog(
            title: const Text('Insert Branded Table'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Columns:'),
                    Row(
                      children: [
                        IconButton(
                          onPressed: colsCount > 1
                              ? () => setModalState(() => colsCount--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '$colsCount',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        IconButton(
                          onPressed: colsCount < 6
                              ? () => setModalState(() => colsCount++)
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Rows (incl. header):'),
                    Row(
                      children: [
                        IconButton(
                          onPressed: rowsCount > 2
                              ? () => setModalState(() => rowsCount--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '$rowsCount',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        IconButton(
                          onPressed: rowsCount < 15
                              ? () => setModalState(() => rowsCount++)
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('btn_confirm_insert_table'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Insert Table'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      final tableData = List<List<String>>.generate(
        rowsCount,
        (r) => List<String>.generate(
          colsCount,
          (c) => r == 0 ? 'Column ${c + 1}' : '',
        ),
      );
      _insertBlock(
        BrandedDocBlock(
          id: AppHelpers.genId(),
          kind: 'table',
          fontSize: 10,
          tableRows: tableData,
        ),
      );
    }
  }

  Future<void> _editTableCell(
    BrandedDocBlock tableBlock,
    int rIdx,
    int cIdx,
  ) async {
    final currentVal = tableBlock.tableRows[rIdx][cIdx];
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [currentVal],
        builder: (ctx, ctrls) => AlertDialog(
          title: Text(
            rIdx == 0
                ? 'Edit Column Header (${cIdx + 1})'
                : 'Edit Row $rIdx, Col ${cIdx + 1}',
          ),
          content: TextField(
            controller: ctrls[0],
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'Cell text (supports **bold**)',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrls[0].text),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (updated == null) return;
    final nextRows =
        tableBlock.tableRows.map((r) => List<String>.from(r)).toList();
    nextRows[rIdx][cIdx] = updated;
    final nextBlocks = _doc.blocks
        .map((b) => b.id == tableBlock.id ? b.copyWith(tableRows: nextRows) : b)
        .toList();
    _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
  }

  PrintableDocument _buildPrintableDescriptor() {
    return PrintableDocument(
      title: _doc.title.trim().isNotEmpty ? _doc.title.trim() : _doc.documentType,
      filename: BrandedDocumentPdfBuilder.pdfFilename(_doc),
      supportsThermalRoll: false,
      buildPdf: (pdfFmt) => BrandedDocumentPdfBuilder.buildPdfBytes(
        document: _doc,
        settings: widget.vault.settings,
        pageFormatOverride: pdfFmt,
      ),
    );
  }

  Future<void> _openPdfPreview() async {
    await _saveNow(silent: true);
    if (!mounted) return;
    final paperFmt = _doc.pageSize.toLowerCase() == 'letter'
        ? PrintPaperFormat.letter
        : PrintPaperFormat.a4;
    await AppPrintHelper.openPreview(
      context,
      initialPaperFormat: paperFmt,
      document: _buildPrintableDescriptor(),
    );
  }

  Future<void> _openPrintSheet() async {
    await _saveNow(silent: true);
    if (!mounted) return;
    await AppPrintHelper.openPrintCenter(
      context,
      document: _buildPrintableDescriptor(),
    );
  }

  Future<void> _sharePdf() async {
    await _saveNow(silent: true);
    try {
      await BrandedDocumentPdfBuilder.sharePdfFile(
        document: _doc,
        settings: widget.vault.settings,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(UserFriendlyError.format(e)),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _saveCopyToPersonalVault() async {
    PersonalVaultService? pvs = widget.personalVaultService;
    if (pvs == null) {
      try {
        pvs = context.read<PersonalVaultService>();
      } catch (_) {
        pvs = null;
      }
    }
    await _saveNow(silent: true);
    if (pvs == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Personal Vault service is unavailable in this view.'),
          backgroundColor: AppTheme.warning,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final pdfBytes = await BrandedDocumentPdfBuilder.buildPdfBytes(
        document: _doc,
        settings: widget.vault.settings,
      );
      final initialMeta = PersonalDocument(
        id: AppHelpers.genId(),
        title: _doc.title.trim().isNotEmpty
            ? _doc.title.trim()
            : _doc.documentType,
        category: PersonalDocCategory.contracts,
        docNumber: _doc.referenceNumber,
        issuer: 'Town Treasure Limited',
        issueDate: _doc.date,
        mimeType: 'application/pdf',
        originalFileName: BrandedDocumentPdfBuilder.pdfFilename(_doc),
        notes: 'Generated in Branded Document Studio (${_doc.referenceNumber})',
      );
      final meta = await pvs.encryptStoreAndUpload(
        meta: initialMeta,
        plainBytes: pdfBytes,
        workerUrl: widget.vault.personalDocsWorkerUrl,
      );
      await widget.vault.savePersonalDocumentMeta(meta);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Encrypted PDF copy saved to Personal Documents!'),
          backgroundColor: AppTheme.forestGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(UserFriendlyError.format(e)),
          backgroundColor: AppTheme.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openEditorOcrImport({
    bool startOnSavedInvoicesTab = false,
  }) async {
    final defaultMode = _doc.documentType.toUpperCase().contains('DELIVERY')
        ? DocSmartConversionMode.deliveryNote
        : (_doc.documentType.toUpperCase().contains('QUOT')
            ? DocSmartConversionMode.quotation
            : DocSmartConversionMode.deliveryNote);

    final output = await DocumentOcrImportSheet.show(
      context,
      vault: widget.vault,
      ocrService: widget.ocrService,
      initialMode: defaultMode,
      startOnSavedInvoicesTab: startOnSavedInvoicesTab,
      allowInsertIntoCurrentDoc: true,
    );
    if (output == null || !mounted) return;

    if (output.insertIntoCurrentDoc) {
      final nextBlocks = List<BrandedDocBlock>.from(_doc.blocks);
      final activeIdx = _activeBlockId == null
          ? -1
          : nextBlocks.indexWhere((b) => b.id == _activeBlockId);
      if (activeIdx >= 0 && activeIdx < nextBlocks.length - 1) {
        nextBlocks.insertAll(activeIdx + 1, output.insertBlocks);
      } else {
        nextBlocks.addAll(output.insertBlocks);
      }
      final updated = _doc.copyWith(
        blocks: nextBlocks,
        recipientName: _doc.recipientName.trim().isEmpty
            ? output.document.recipientName
            : _doc.recipientName,
        recipientContact: _doc.recipientContact.trim().isEmpty
            ? output.document.recipientContact
            : _doc.recipientContact,
        recipientAddress: _doc.recipientAddress.trim().isEmpty
            ? output.document.recipientAddress
            : _doc.recipientAddress,
        recipientPhone: _doc.recipientPhone.trim().isEmpty
            ? output.document.recipientPhone
            : _doc.recipientPhone,
        recipientKraPin: _doc.recipientKraPin.trim().isEmpty
            ? output.document.recipientKraPin
            : _doc.recipientKraPin,
        showRecipientCard:
            _doc.showRecipientCard || output.document.showRecipientCard,
      );
      _recipientNameCtrl.text = updated.recipientName;
      _recipientContactCtrl.text = updated.recipientContact;
      _recipientAddressCtrl.text = updated.recipientAddress;
      _recipientPhoneCtrl.text = updated.recipientPhone;
      _recipientPinCtrl.text = updated.recipientKraPin;
      _applyDocUpdate(updated);
      return;
    }

    // Replace current document content while keeping this document's ID
    final replaced = output.document.copyWith(
      id: _doc.id,
      createdAt: _doc.createdAt,
    );
    _titleCtrl.text = replaced.title;
    _subjectCtrl.text = replaced.subject;
    _recipientNameCtrl.text = replaced.recipientName;
    _recipientContactCtrl.text = replaced.recipientContact;
    _recipientAddressCtrl.text = replaced.recipientAddress;
    _recipientPhoneCtrl.text = replaced.recipientPhone;
    _recipientPinCtrl.text = replaced.recipientKraPin;
    _activeBlockId =
        replaced.blocks.isNotEmpty ? replaced.blocks.first.id : null;
    _applyDocUpdate(replaced);
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeBlock;
    return Scaffold(
      backgroundColor: const Color(0xFFE6ECE7),
      appBar: AppBar(
        title: Text(
          _doc.title.trim().isNotEmpty ? _doc.title : 'Document Studio',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextFieldTapRegion(
            child: IconButton(
              key: const Key('btn_editor_ocr_scan'),
              tooltip: 'Scan OCR or Import from Invoice',
              onPressed: () => _openEditorOcrImport(),
              icon: const Icon(Icons.document_scanner_outlined),
            ),
          ),
          TextFieldTapRegion(
            child: IconButton(
              key: const Key('btn_doc_preview_pdf'),
              tooltip: 'Preview Branded PDF',
              onPressed: _openPdfPreview,
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
          ),
          TextFieldTapRegion(
            child: IconButton(
              key: const Key('btn_doc_save'),
              tooltip: 'Save Document',
              onPressed: _isSaving ? null : () => _saveNow(silent: false),
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_outlined),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // MS Word-style Logical Ribbon wrapped in TextFieldTapRegion so
          // clicking Bold/Italic/Font/Size preserves active text selection!
          TextFieldTapRegion(
            child: _buildWordRibbon(active),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 40),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 740),
                    child: _buildA4PaperSheet(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWordRibbon(BrandedDocBlock? active) {
    return Material(
      color: AppTheme.surfaceCard,
      elevation: 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logical Ribbon Tabs (Home | Insert | Layout | Brand & Export)
          Container(
            color: const Color(0xFFF3F7F4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _RibbonTabPill(
                    key: const Key('ribbon_tab_home'),
                    label: 'Home',
                    icon: Icons.text_format,
                    selected: _activeTab == _WordRibbonTab.home,
                    onTap: () => setState(() => _activeTab = _WordRibbonTab.home),
                  ),
                  _RibbonTabPill(
                    key: const Key('ribbon_tab_insert'),
                    label: 'Insert',
                    icon: Icons.add_box_outlined,
                    selected: _activeTab == _WordRibbonTab.insert,
                    onTap: () =>
                        setState(() => _activeTab = _WordRibbonTab.insert),
                  ),
                  _RibbonTabPill(
                    key: const Key('ribbon_tab_layout'),
                    label: 'Layout',
                    icon: Icons.space_dashboard_outlined,
                    selected: _activeTab == _WordRibbonTab.layout,
                    onTap: () =>
                        setState(() => _activeTab = _WordRibbonTab.layout),
                  ),
                  _RibbonTabPill(
                    key: const Key('ribbon_tab_brand'),
                    label: 'Brand & Export',
                    icon: Icons.verified_outlined,
                    selected: _activeTab == _WordRibbonTab.brandExport,
                    onTap: () =>
                        setState(() => _activeTab = _WordRibbonTab.brandExport),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const Key('btn_doc_undo'),
                    tooltip: 'Undo',
                    visualDensity: VisualDensity.compact,
                    onPressed: _undoStack.isNotEmpty ? _undo : null,
                    icon: const Icon(Icons.undo, size: 18),
                  ),
                  IconButton(
                    key: const Key('btn_doc_redo'),
                    tooltip: 'Redo',
                    visualDensity: VisualDensity.compact,
                    onPressed: _redoStack.isNotEmpty ? _redo : null,
                    icon: const Icon(Icons.redo, size: 18),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: switch (_activeTab) {
              _WordRibbonTab.home => _buildHomeRibbon(active),
              _WordRibbonTab.insert => _buildInsertRibbon(),
              _WordRibbonTab.layout => _buildLayoutRibbon(),
              _WordRibbonTab.brandExport => _buildBrandExportRibbon(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHomeRibbon(BrandedDocBlock? active) {
    final isBold = active?.bold ?? false;
    final isItalic = active?.italic ?? false;
    final isUnderline = active?.underline ?? false;
    final fontSize = active?.fontSize ?? 11.0;
    final family = active?.fontFamily ?? _doc.defaultFontFamily;
    final align = active?.align ?? 'left';
    final kind = active?.kind ?? 'paragraph';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          // Style Preset Selector
          PopupMenuButton<String>(
            tooltip: 'Paragraph / Heading Style',
            onSelected: (nextKind) {
              _mutateActiveBlock((b) {
                return switch (nextKind) {
                  'heading1' => b.copyWith(
                      kind: 'heading1',
                      bold: true,
                      fontSize: 18,
                      colorHex: '#1B5E20',
                    ),
                  'heading2' => b.copyWith(
                      kind: 'heading2',
                      bold: true,
                      fontSize: 14,
                      colorHex: '#1B5E20',
                    ),
                  'heading3' => b.copyWith(
                      kind: 'heading3',
                      bold: true,
                      fontSize: 12.5,
                    ),
                  'callout' => b.copyWith(kind: 'callout', fontSize: 10.5),
                  'signatory' => b.copyWith(
                      kind: 'signatory',
                      text: b.isLegacySignatoryParagraph ? '' : b.text,
                    ),
                  _ => b.copyWith(
                      kind: 'paragraph',
                      bold: false,
                      fontSize: 11,
                    ),
                };
              });
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'paragraph', child: Text('Normal Body')),
              PopupMenuItem(value: 'heading1', child: Text('Heading 1')),
              PopupMenuItem(value: 'heading2', child: Text('Heading 2')),
              PopupMenuItem(value: 'heading3', child: Text('Heading 3')),
              PopupMenuItem(value: 'callout', child: Text('Callout Box')),
              PopupMenuItem(
                value: 'signatory',
                child: Text('Signatory & Stamp Grid'),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.borderSubtle),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    switch (kind) {
                      'heading1' => 'Heading 1',
                      'heading2' => 'Heading 2',
                      'heading3' => 'Heading 3',
                      'callout' => 'Callout',
                      'signatory' => 'Signatory',
                      'bullet' => 'Bullets',
                      'numbered' => 'Numbered',
                      _ => 'Body',
                    },
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Font Family Selector (Sans / Serif / Mono)
          PopupMenuButton<String>(
            tooltip: 'Font Family',
            onSelected: (nextFam) =>
                _mutateActiveBlock((b) => b.copyWith(fontFamily: nextFam)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'sans', child: Text('Sans-Serif (Modern)')),
              PopupMenuItem(value: 'serif', child: Text('Serif (Formal Times)')),
              PopupMenuItem(value: 'mono', child: Text('Monospace (Courier)')),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.borderSubtle),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    switch (family) {
                      'serif' => 'Serif',
                      'mono' => 'Mono',
                      _ => 'Sans',
                    },
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(Icons.arrow_drop_down, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Font Size - / pt / +
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.borderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () => _mutateActiveBlock(
                    (b) => b.copyWith(
                      fontSize: (b.fontSize - 1).clamp(8.0, 32.0),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                    child: Icon(Icons.text_decrease, size: 15),
                  ),
                ),
                Text(
                  '${fontSize.round()}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                InkWell(
                  key: const Key('btn_ribbon_font_increase'),
                  onTap: () => _mutateActiveBlock(
                    (b) => b.copyWith(
                      fontSize: (b.fontSize + 1).clamp(8.0, 32.0),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                    child: Icon(Icons.text_increase, size: 15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Bold / Italic / Underline
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_bold'),
            icon: Icons.format_bold,
            tooltip: 'Bold (selection or block)',
            active: isBold,
            onTap: () => _toggleInlineOrBlockStyle(
              marker: '**',
              toggleBlockProp: (b) => b.copyWith(bold: !b.bold),
            ),
          ),
          const SizedBox(width: 4),
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_italic'),
            icon: Icons.format_italic,
            tooltip: 'Italic (selection or block)',
            active: isItalic,
            onTap: () => _toggleInlineOrBlockStyle(
              marker: '*',
              toggleBlockProp: (b) => b.copyWith(italic: !b.italic),
            ),
          ),
          const SizedBox(width: 4),
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_underline'),
            icon: Icons.format_underlined,
            tooltip: 'Underline (selection or block)',
            active: isUnderline,
            onTap: () => _toggleInlineOrBlockStyle(
              marker: '__',
              toggleBlockProp: (b) => b.copyWith(underline: !b.underline),
            ),
          ),
          const SizedBox(width: 8),
          // Color Swatches
          for (final swatch in _colorPalette) ...[
            GestureDetector(
              onTap: () => _mutateActiveBlock(
                (b) => b.copyWith(colorHex: swatch.hex),
              ),
              child: Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: swatch.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: (active?.colorHex.toUpperCase() ?? '#1E293B') ==
                            swatch.hex
                        ? AppTheme.leafGreen
                        : Colors.white,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          // Alignment (Left / Center / Right / Justify)
          _RibbonToggleBtn(
            icon: Icons.format_align_left,
            tooltip: 'Align Left',
            active: align == 'left',
            onTap: () => _mutateActiveBlock((b) => b.copyWith(align: 'left')),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_align_center'),
            icon: Icons.format_align_center,
            tooltip: 'Center',
            active: align == 'center',
            onTap: () => _mutateActiveBlock((b) => b.copyWith(align: 'center')),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            icon: Icons.format_align_right,
            tooltip: 'Align Right',
            active: align == 'right',
            onTap: () => _mutateActiveBlock((b) => b.copyWith(align: 'right')),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            icon: Icons.format_align_justify,
            tooltip: 'Justify',
            active: align == 'justify',
            onTap: () =>
                _mutateActiveBlock((b) => b.copyWith(align: 'justify')),
          ),
          const SizedBox(width: 8),
          // Bullets & Numbering & Indent
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_bullets'),
            icon: Icons.format_list_bulleted,
            tooltip: 'Bulleted List',
            active: kind == 'bullet',
            onTap: () => _mutateActiveBlock(
              (b) => b.copyWith(
                kind: b.kind == 'bullet' ? 'paragraph' : 'bullet',
              ),
            ),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            key: const Key('btn_ribbon_numbered'),
            icon: Icons.format_list_numbered,
            tooltip: 'Numbered List',
            active: kind == 'numbered',
            onTap: () => _mutateActiveBlock(
              (b) => b.copyWith(
                kind: b.kind == 'numbered' ? 'paragraph' : 'numbered',
              ),
            ),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            icon: Icons.format_indent_decrease,
            tooltip: 'Decrease Indent',
            active: false,
            onTap: () => _mutateActiveBlock(
              (b) => b.copyWith(indent: (b.indent - 1).clamp(0, 4)),
            ),
          ),
          const SizedBox(width: 3),
          _RibbonToggleBtn(
            icon: Icons.format_indent_increase,
            tooltip: 'Increase Indent',
            active: false,
            onTap: () => _mutateActiveBlock(
              (b) => b.copyWith(indent: (b.indent + 1).clamp(0, 4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsertRibbon() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilledButton.icon(
            key: const Key('btn_insert_ocr_scan'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _openEditorOcrImport(startOnSavedInvoicesTab: false),
            icon: const Icon(Icons.document_scanner_outlined, size: 16),
            label: const Text('Scan OCR'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            key: const Key('btn_insert_from_invoice'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _openEditorOcrImport(startOnSavedInvoicesTab: true),
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: const Text('From Invoice'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            key: const Key('btn_insert_paragraph'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _insertBlock(
              BrandedDocBlock(
                id: AppHelpers.genId(),
                kind: 'paragraph',
                fontFamily: _doc.defaultFontFamily,
              ),
            ),
            icon: const Icon(Icons.notes, size: 16),
            label: const Text('Paragraph'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            key: const Key('btn_insert_heading'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _insertBlock(
              BrandedDocBlock(
                id: AppHelpers.genId(),
                kind: 'heading2',
                bold: true,
                fontSize: 14,
                colorHex: '#1B5E20',
                fontFamily: _doc.defaultFontFamily,
              ),
            ),
            icon: const Icon(Icons.title, size: 16),
            label: const Text('Heading'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            key: const Key('btn_insert_table'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _openTableDialog,
            icon: const Icon(Icons.table_chart_outlined, size: 16),
            label: const Text('Table'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _insertBlock(
              BrandedDocBlock(
                id: AppHelpers.genId(),
                kind: 'callout',
                text: '**Note:** Enter highlighted callout notice here.',
                fontSize: 10.5,
                colorHex: '#1B5E20',
              ),
            ),
            icon: const Icon(Icons.info_outline, size: 16),
            label: const Text('Callout Box'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            key: const Key('btn_insert_signatory'),
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _insertBlock(
              BrandedDocBlock(
                id: AppHelpers.genId(),
                kind: 'signatory',
              ),
            ),
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: const Text('Signatory Grid'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _insertBlock(
              BrandedDocBlock(id: AppHelpers.genId(), kind: 'divider'),
            ),
            icon: const Icon(Icons.horizontal_rule, size: 16),
            label: const Text('Divider'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            key: const Key('btn_insert_pick_client'),
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _pickRestaurantRecipient,
            icon: const Icon(Icons.storefront_outlined, size: 16),
            label: const Text('Fill Client'),
          ),
        ],
      ),
    );
  }

  Widget _buildLayoutRibbon() {
    const docTypes = [
      'OFFICIAL LETTER',
      'QUOTATION',
      'PROPOSAL',
      'DELIVERY NOTE',
      'MEMORANDUM',
      'NOTICE',
      'CONTRACT',
      'OFFICIAL DOCUMENT',
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Document Badge Type',
            onSelected: (val) => _applyDocUpdate(
              _doc.copyWith(documentType: val),
              syncControllers: false,
            ),
            itemBuilder: (_) => docTypes
                .map((t) => PopupMenuItem(value: t, child: Text(t)))
                .toList(),
            child: Chip(
              avatar: const Icon(Icons.badge_outlined, size: 16),
              label: Text(_doc.documentType),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.calendar_today_outlined, size: 15),
            label: Text(_doc.date.isNotEmpty ? _doc.date : 'Set Date'),
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              final init = AppHelpers.parseAppDate(_doc.date) ?? DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: init,
                firstDate: DateTime(2020),
                lastDate: DateTime(2035),
              );
              if (picked != null) {
                _applyDocUpdate(
                  _doc.copyWith(date: DateFormat('yyyy-MM-dd').format(picked)),
                  syncControllers: false,
                );
              }
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('A4'),
            selected: _doc.pageSize == 'a4',
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _applyDocUpdate(
              _doc.copyWith(pageSize: 'a4'),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            label: const Text('Letter'),
            selected: _doc.pageSize == 'letter',
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _applyDocUpdate(
              _doc.copyWith(pageSize: 'letter'),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: 'Page Margins',
            onSelected: (m) => _applyDocUpdate(
              _doc.copyWith(marginPreset: m),
              syncControllers: false,
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'narrow', child: Text('Narrow Margins')),
              PopupMenuItem(value: 'normal', child: Text('Normal Margins')),
              PopupMenuItem(value: 'wide', child: Text('Wide Margins')),
            ],
            child: Chip(
              label: Text('Margins: ${_doc.marginPreset}'),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Recipient Block'),
            selected: _doc.showRecipientCard,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showRecipientCard: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            key: const Key('chip_layout_show_kra_pin'),
            label: const Text('Include KRA PIN'),
            selected: _doc.showKraPin,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showKraPin: v),
              syncControllers: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandExportRibbon() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilterChip(
            label: const Text('Letterhead'),
            selected: _doc.showLetterheadBanner,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showLetterheadBanner: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Watermark'),
            selected: _doc.showWatermark,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showWatermark: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            key: const Key('chip_brand_show_kra_pin'),
            label: const Text('Include KRA PIN'),
            selected: _doc.showKraPin,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showKraPin: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Official Stamp'),
            selected: _doc.showStamp,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showStamp: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('Signature'),
            selected: _doc.showSignature,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showSignature: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 6),
          FilterChip(
            label: const Text('QR Code'),
            selected: _doc.showQrCode,
            visualDensity: VisualDensity.compact,
            onSelected: (v) => _applyDocUpdate(
              _doc.copyWith(showQrCode: v),
              syncControllers: false,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _openPdfPreview,
            icon: const Icon(Icons.visibility_outlined, size: 16),
            label: const Text('PDF Preview'),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _openPrintSheet,
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Print'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _sharePdf,
            icon: const Icon(Icons.share_outlined, size: 16),
            label: const Text('Share PDF'),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            key: const Key('btn_save_copy_to_personal_vault'),
            style:
                OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _saveCopyToPersonalVault,
            icon: const Icon(Icons.lock_outline, size: 16),
            label: const Text('Save to Vault'),
          ),
        ],
      ),
    );
  }

  Widget _buildA4PaperSheet() {
    return Container(
      key: const Key('branded_doc_a4_canvas'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live Town Treasure PDF Letterhead Banner
          if (_doc.showLetterheadBanner)
            Container(
              height: 68,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  stops: [0.0, 0.52, 0.53, 1.0],
                  colors: [
                    Color(0xFF61B146),
                    Color(0xFF61B146),
                    Color(0xFF313A43),
                    Color(0xFF313A43),
                  ],
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Image.asset(
                          'assets/logo.png',
                          height: 32,
                          width: 32,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.eco,
                            color: AppTheme.forestGreen,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Town Treasure Limited',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _doc.documentType,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Document Title + Ref/Date Row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('field_doc_title'),
                        controller: _titleCtrl,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateInk,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Document Title...',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          filled: false,
                        ),
                        onChanged: (v) => _applyDocUpdate(
                          _doc.copyWith(title: v),
                          recordUndo: false,
                          syncControllers: false,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _doc.referenceNumber,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        Text(
                          'Date: ${_doc.date}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // Optional Recipient Card
                if (_doc.showRecipientCard) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'TO / RECIPIENT',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.leafGreen,
                                letterSpacing: 0.7,
                              ),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: _pickRestaurantRecipient,
                              icon: const Icon(
                                Icons.storefront_outlined,
                                size: 15,
                              ),
                              label: const Text(
                                'Pick Saved Client',
                                style: TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _recipientNameCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Client / Organization Name',
                                  isDense: true,
                                ),
                                onChanged: (v) => _applyDocUpdate(
                                  _doc.copyWith(recipientName: v),
                                  recordUndo: false,
                                  syncControllers: false,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _recipientContactCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Attention / Contact Person',
                                  isDense: true,
                                ),
                                onChanged: (v) => _applyDocUpdate(
                                  _doc.copyWith(recipientContact: v),
                                  recordUndo: false,
                                  syncControllers: false,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _recipientAddressCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Address / Location',
                                  isDense: true,
                                ),
                                onChanged: (v) => _applyDocUpdate(
                                  _doc.copyWith(recipientAddress: v),
                                  recordUndo: false,
                                  syncControllers: false,
                                ),
                              ),
                            ),
                            if (_doc.showKraPin) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  key: const Key('field_doc_recipient_kra_pin'),
                                  controller: _recipientPinCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Recipient KRA PIN (Opt)',
                                    isDense: true,
                                  ),
                                  onChanged: (v) => _applyDocUpdate(
                                    _doc.copyWith(recipientKraPin: v),
                                    recordUndo: false,
                                    syncControllers: false,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                // Subject / RE: Bar
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF0FDF4),
                    border: Border(
                      left: BorderSide(color: Color(0xFF61B146), width: 3.5),
                    ),
                  ),
                  child: TextField(
                    key: const Key('field_doc_subject'),
                    controller: _subjectCtrl,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppTheme.forestGreenDeep,
                    ),
                    decoration: const InputDecoration(
                      prefixText: 'RE: ',
                      hintText: 'Subject line (leave blank to hide on PDF)',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      filled: false,
                    ),
                    onChanged: (v) => _applyDocUpdate(
                      _doc.copyWith(subject: v),
                      recordUndo: false,
                      syncControllers: false,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Rich Editable Document Body Blocks
                ..._buildEditableBodyBlocks(),

                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _insertBlock(
                      BrandedDocBlock(
                        id: AppHelpers.genId(),
                        kind: 'paragraph',
                        fontFamily: _doc.defaultFontFamily,
                      ),
                    ),
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Add Paragraph'),
                  ),
                ),

                // Live Stamp & Signature Preview Footer
                if (_doc.showStamp || _doc.showSignature) ...[
                  const Divider(height: 28),
                  Builder(
                    builder: (context) {
                      final liveSigBytes =
                          StampSignatureHelper.prepareSignaturePng(
                        widget.vault.settings.signature,
                      );
                      return Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          width: 210,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF313A43),
                              width: 1.9,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_doc.showStamp) ...[
                                Image.asset(
                                  'assets/stamp.png',
                                  height: 50,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const Text(
                                    'TOWN TREASURE LIMITED',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: const BoxDecoration(
                                    border: Border.symmetric(
                                      horizontal: BorderSide(
                                        color: Color(0xFF313A43),
                                        width: 0.8,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    _doc.stampCaption,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                              ],
                              if (_doc.showSignature) ...[
                                const SizedBox(height: 6),
                                if (liveSigBytes != null)
                                  Image.memory(
                                    liveSigBytes,
                                    height: 44,
                                    fit: BoxFit.contain,
                                  )
                                else
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: Text(
                                      'Authorized Signature Line',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.forestGreen,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 3),
                                Container(
                                  width: 145,
                                  height: 1,
                                  color: AppTheme.borderSubtle,
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  'AUTHORIZED SIGNATORY',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.5,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),

          // Live Dark Slate Footer Strip
          Container(
            color: const Color(0xFF313A43),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              _doc.footerNote,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildEditableBodyBlocks() {
    final items = <Widget>[];
    var numberedIdx = 0;

    for (var i = 0; i < _doc.blocks.length; i++) {
      final block = _doc.blocks[i];
      if (block.kind == 'numbered') {
        numberedIdx++;
      } else {
        numberedIdx = 0;
      }
      final isFocused = block.id == _activeBlockId;

      items.add(
        GestureDetector(
          onTap: () => setState(() => _activeBlockId = block.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.fromLTRB(
              8 + (block.indent * 16.0),
              6,
              6,
              6,
            ),
            decoration: BoxDecoration(
              color: block.kind == 'callout'
                  ? const Color(0xFFF0FDF4)
                  : (isFocused
                      ? AppTheme.sageTint.withValues(alpha: 0.35)
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: block.kind == 'callout'
                  ? const Border(
                      left: BorderSide(color: Color(0xFF61B146), width: 3.5),
                    )
                  : Border.all(
                      color: isFocused
                          ? AppTheme.leafGreen.withValues(alpha: 0.55)
                          : Colors.transparent,
                    ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (block.kind == 'bullet' || block.kind == 'numbered')
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 8),
                    child: Text(
                      block.kind == 'bullet' ? '•' : '$numberedIdx.',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: block.fontSize + 2,
                        color: AppTheme.leafGreen,
                      ),
                    ),
                  ),
                Expanded(
                  child: block.isDivider
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Divider(thickness: 1.2),
                        )
                      : block.isTable
                          ? _buildInteractiveTableWidget(block)
                          : block.isSignatory
                              ? _buildInteractiveSignatoryWidget(block)
                              : _buildBlockTextField(block),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Block Actions',
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_vert,
                    size: 17,
                    color: isFocused
                        ? AppTheme.slateInk
                        : AppTheme.slateMuted.withValues(alpha: 0.45),
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case 'up':
                        _moveBlock(i, -1);
                      case 'down':
                        _moveBlock(i, 1);
                      case 'add_row':
                        if (block.isTable && block.tableRows.isNotEmpty) {
                          final cols = block.tableRows.first.length;
                          final nextRows = [
                            ...block.tableRows.map((r) => List<String>.from(r)),
                            List<String>.filled(cols, ''),
                          ];
                          final nextBlocks = _doc.blocks
                              .map(
                                (b) => b.id == block.id
                                    ? b.copyWith(tableRows: nextRows)
                                    : b,
                              )
                              .toList();
                          _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
                        }
                      case 'add_col':
                        if (block.isTable) {
                          final nextRows = [
                            for (var r = 0; r < block.tableRows.length; r++)
                              [
                                ...block.tableRows[r],
                                r == 0
                                    ? 'Col ${block.tableRows[r].length + 1}'
                                    : '',
                              ],
                          ];
                          final nextBlocks = _doc.blocks
                              .map(
                                (b) => b.id == block.id
                                    ? b.copyWith(tableRows: nextRows)
                                    : b,
                              )
                              .toList();
                          _applyDocUpdate(_doc.copyWith(blocks: nextBlocks));
                        }
                      case 'delete':
                        _deleteBlock(i);
                    }
                  },
                  itemBuilder: (_) => [
                    if (i > 0)
                      const PopupMenuItem(value: 'up', child: Text('Move Up')),
                    if (i < _doc.blocks.length - 1)
                      const PopupMenuItem(
                        value: 'down',
                        child: Text('Move Down'),
                      ),
                    if (block.isTable) ...[
                      const PopupMenuItem(
                        value: 'add_row',
                        child: Text('Add Table Row'),
                      ),
                      const PopupMenuItem(
                        value: 'add_col',
                        child: Text('Add Table Column'),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete Block',
                        style: TextStyle(color: AppTheme.danger),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return items;
  }

  Widget _buildBlockTextField(BrandedDocBlock block) {
    final ctrl = _blockCtrls[block.id]!;
    final focusNode = _blockFocusNodes[block.id]!;
    final color = _parseUiColor(block.colorHex);
    final uiFontSize = (block.fontSize + 2.5).clamp(11.0, 30.0);
    final fontFamily = switch (block.fontFamily) {
      'serif' => 'serif',
      'mono' => 'monospace',
      _ => null,
    };
    final textAlign = switch (block.align) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.left,
    };

    return TextField(
      key: ValueKey('doc_block_field_${block.id}'),
      controller: ctrl,
      focusNode: focusNode,
      maxLines: null,
      textAlign: textAlign,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: uiFontSize,
        height: block.lineSpacing,
        fontWeight:
            (block.bold || block.isHeading) ? FontWeight.w800 : FontWeight.w400,
        fontStyle: block.italic ? FontStyle.italic : FontStyle.normal,
        decoration:
            block.underline ? TextDecoration.underline : TextDecoration.none,
        color: color,
      ),
      decoration: InputDecoration(
        hintText: block.isHeading
            ? 'Heading...'
            : 'Type here (select text and tap B / I / U to style)...',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 2),
        filled: false,
      ),
      onTap: () {
        if (_activeBlockId != block.id) {
          setState(() => _activeBlockId = block.id);
        }
      },
      onChanged: (val) {
        final nextBlocks = _doc.blocks
            .map((b) => b.id == block.id ? b.copyWith(text: val) : b)
            .toList();
        _doc = _doc.copyWith(blocks: nextBlocks);
        _scheduleAutoSave();
      },
    );
  }

  Widget _buildInteractiveSignatoryWidget(BrandedDocBlock block) {
    final dispatchHint =
        block.isLegacySignatoryParagraph ? '' : block.text.trim();

    Widget previewLine(String label, {String value = ''}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateMuted,
              ),
            ),
            Container(
              width: double.infinity,
              height: 22,
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.only(bottom: 2),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF475569), width: 1),
                ),
              ),
              child: value.isNotEmpty
                  ? Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateInk,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      );
    }

    return Container(
      key: Key('signatory_block_${block.id}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF94A3B8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
              border: Border(
                bottom: BorderSide(color: Color(0xFFCBD5E1)),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  size: 15,
                  color: AppTheme.forestGreen,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'DISPATCH & RECEIVING SIGNATORY GRID',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 430;
                final dispatchedCol = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '1. DISPATCHED BY',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.forestGreen,
                      ),
                    ),
                    const SizedBox(height: 6),
                    previewLine('Full Name:'),
                    previewLine('Dispatcher Signature:'),
                    previewLine('Dispatch Time / Vehicle:', value: dispatchHint),
                  ],
                );
                final receivedCol = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '2. RECEIVED BY',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.forestGreen,
                      ),
                    ),
                    const SizedBox(height: 6),
                    previewLine('Full Name & Designation:'),
                    previewLine('Receiver Signature:'),
                    previewLine('Arrival Date & Time:'),
                  ],
                );
                final stampCol = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '3. CLIENT STAMP',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.forestGreen,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: stacked ? 68 : 112,
                      width: double.infinity,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAFAFA),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: const Text(
                        'Official Receiving\nStamp & Date',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                    ),
                  ],
                );

                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      dispatchedCol,
                      const Divider(height: 16),
                      receivedCol,
                      const SizedBox(height: 6),
                      stampCol,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 38, child: dispatchedCol),
                    const SizedBox(width: 10),
                    Expanded(flex: 38, child: receivedCol),
                    const SizedBox(width: 10),
                    Expanded(flex: 26, child: stampCol),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveTableWidget(BrandedDocBlock block) {
    final rows = block.tableRows;
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.fold<int>(
      1,
      (m, r) => r.length > m ? r.length : m,
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFCBD5E1)),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Table(
        border: TableBorder.symmetric(
          inside: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(
                color: r == 0
                    ? const Color(0xFF61B146)
                    : (r.isEven ? const Color(0xFFF8FAFC) : Colors.white),
              ),
              children: [
                for (var c = 0; c < cols; c++)
                  InkWell(
                    onTap: () => _editTableCell(block, r, c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      child: Text(
                        c < rows[r].length && rows[r][c].isNotEmpty
                            ? rows[r][c]
                            : (r == 0 ? 'Header' : 'Tap to edit'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              r == 0 ? FontWeight.w800 : FontWeight.w500,
                          color: r == 0
                              ? Colors.white
                              : (c < rows[r].length && rows[r][c].isNotEmpty
                                  ? AppTheme.slateInk
                                  : AppTheme.slateMuted.withValues(alpha: 0.6)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Color _parseUiColor(String hex) {
    final clean = hex.trim().replaceAll('#', '');
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    return AppTheme.slateInk;
  }
}

class _RibbonTabPill extends StatelessWidget {
  const _RibbonTabPill({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppTheme.forestGreen : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? Colors.white : AppTheme.slateInk,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppTheme.slateInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RibbonToggleBtn extends StatelessWidget {
  const _RibbonToggleBtn({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: active
                ? AppTheme.leafGreen.withValues(alpha: 0.22)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active ? AppTheme.forestGreen : AppTheme.borderSubtle,
            ),
          ),
          child: Icon(
            icon,
            size: 17,
            color: active ? AppTheme.forestGreenDeep : AppTheme.slateInk,
          ),
        ),
      ),
    );
  }
}
