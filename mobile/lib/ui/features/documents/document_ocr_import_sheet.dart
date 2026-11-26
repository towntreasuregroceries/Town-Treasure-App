import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/ocr_consensus_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../invoices/invoice_formatters.dart';
import 'document_ocr_converter.dart';

/// Result returned when the user confirms a smart OCR or Saved-Invoice import
/// into Branded Document Studio.
class DocumentOcrImportOutput {
  const DocumentOcrImportOutput({
    required this.document,
    required this.insertBlocks,
    required this.mode,
    this.insertIntoCurrentDoc = false,
  });

  final BrandedDocument document;
  final List<BrandedDocBlock> insertBlocks;
  final DocSmartConversionMode mode;
  final bool insertIntoCurrentDoc;
}

/// Smart Optical (OCR) & Invoice-to-Branded-Document sheet supporting:
/// 1. Camera / Multi-Photo Gallery / PDF Upload / CSV Paste OCR
/// 2. 1-Tap Import from any Saved Invoice in `VaultRepository`
/// 3. Role-aware conversion:
///    - **Delivery Note** (strips ALL prices, totals & non-goods fee rows; supports partial deliveries)
///    - **Quotation / Proforma** (auto-hydrates missing LPO prices from Vault Price Lists / Invoices)
///    - **Dispatch / Credit Memo**
///    - **Full Editable Word Document** (headings, paragraphs, bullets & tables)
class DocumentOcrImportSheet extends StatefulWidget {
  const DocumentOcrImportSheet({
    super.key,
    required this.vault,
    required this.ocrService,
    this.initialMode = DocSmartConversionMode.deliveryNote,
    this.preselectedInvoice,
    this.startOnSavedInvoicesTab = false,
    this.allowInsertIntoCurrentDoc = false,
  });

  final VaultRepository vault;
  final OcrConsensusService ocrService;
  final DocSmartConversionMode initialMode;
  final Invoice? preselectedInvoice;
  final bool startOnSavedInvoicesTab;
  final bool allowInsertIntoCurrentDoc;

  static Future<DocumentOcrImportOutput?> show(
    BuildContext context, {
    required VaultRepository vault,
    OcrConsensusService? ocrService,
    DocSmartConversionMode initialMode = DocSmartConversionMode.deliveryNote,
    Invoice? preselectedInvoice,
    bool startOnSavedInvoicesTab = false,
    bool allowInsertIntoCurrentDoc = false,
  }) {
    OcrConsensusService resolvedOcr;
    if (ocrService != null) {
      resolvedOcr = ocrService;
    } else {
      try {
        resolvedOcr = context.read<OcrConsensusService>();
      } catch (_) {
        resolvedOcr = OcrConsensusService();
      }
    }

    return showModalBottomSheet<DocumentOcrImportOutput>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceSage,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.94,
        child: DocumentOcrImportSheet(
          vault: vault,
          ocrService: resolvedOcr,
          initialMode: initialMode,
          preselectedInvoice: preselectedInvoice,
          startOnSavedInvoicesTab:
              startOnSavedInvoicesTab || preselectedInvoice != null,
          allowInsertIntoCurrentDoc: allowInsertIntoCurrentDoc,
        ),
      ),
    );
  }

  @override
  State<DocumentOcrImportSheet> createState() => _DocumentOcrImportSheetState();
}

class _DocumentOcrImportSheetState extends State<DocumentOcrImportSheet>
    with SingleTickerProviderStateMixin {
  late TabController _sourceTabCtrl;
  late DocSmartConversionMode _mode;

  final List<OcrImagePage> _pages = [];
  final TextEditingController _invoiceSearchCtrl = TextEditingController();
  final TextEditingController _recipientCtrl = TextEditingController();
  final TextEditingController _sourceRefCtrl = TextEditingController();
  final TextEditingController _dateCtrl = TextEditingController();
  final TextEditingController _dispatchInfoCtrl = TextEditingController();
  final TextEditingController _csvPasteCtrl = TextEditingController();

  bool _isScanning = false;
  bool _showCsvBox = false;
  bool _showOrderedQtyColumn = false;
  late bool _showKraPin;
  bool _userToggledKraPin = false;
  String _progressText = '';
  String? _errorText;
  String _invoiceQuery = '';

  List<InvoiceLineItem> _rawExtractedItems = [];
  List<SelectableDocItem> _stagedItems = [];
  OcrBrandedDocResult? _fullDocResult;
  Restaurant? _matchedRestaurant;
  String? _selectedSavedInvoiceId;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _showKraPin = widget.initialMode != DocSmartConversionMode.deliveryNote;
    _sourceTabCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.startOnSavedInvoicesTab ? 1 : 0,
    );
    _dateCtrl.text = AppHelpers.normalizeAppDate(DateTime.now());

    if (widget.preselectedInvoice != null) {
      _loadFromSavedInvoice(widget.preselectedInvoice!);
    }
  }

  @override
  void dispose() {
    _sourceTabCtrl.dispose();
    _invoiceSearchCtrl.dispose();
    _recipientCtrl.dispose();
    _sourceRefCtrl.dispose();
    _dateCtrl.dispose();
    _dispatchInfoCtrl.dispose();
    _csvPasteCtrl.dispose();
    super.dispose();
  }

  void _resolveRecipient(String rawName, {String? restaurantId}) {
    Restaurant? matched;
    if (restaurantId != null && restaurantId.isNotEmpty) {
      final idx =
          widget.vault.restaurants.indexWhere((r) => r.id == restaurantId);
      if (idx >= 0) matched = widget.vault.restaurants[idx];
    }
    matched ??= rawName.trim().isNotEmpty
        ? Restaurant.resolveName(rawName, widget.vault.restaurants).restaurant
        : null;

    _matchedRestaurant = matched;
    _recipientCtrl.text = matched?.name ?? rawName.trim();
  }

  void _rebuildStagedItems() {
    if (_rawExtractedItems.isEmpty) {
      _stagedItems = [];
      return;
    }
    _stagedItems = DocumentOcrConverter.prepareSelectableItems(
      sourceItems: _rawExtractedItems,
      mode: _mode,
      vault: widget.vault,
      matchedRestaurant: _matchedRestaurant,
    );
  }

  void _loadFromSavedInvoice(Invoice inv) {
    _selectedSavedInvoiceId = inv.id;
    _resolveRecipient(inv.restaurantName, restaurantId: inv.restaurantId);
    _sourceRefCtrl.text = inv.number;
    _dateCtrl.text = AppHelpers.normalizeAppDate(inv.date).isNotEmpty
        ? AppHelpers.normalizeAppDate(inv.date)
        : AppHelpers.normalizeAppDate(DateTime.now());
    _rawExtractedItems = List<InvoiceLineItem>.from(inv.items);
    _fullDocResult = null;
    _errorText = null;
    _rebuildStagedItems();
  }

  void _changeMode(DocSmartConversionMode nextMode) {
    if (_mode == nextMode) return;
    setState(() {
      _mode = nextMode;
      if (!_userToggledKraPin) {
        _showKraPin = nextMode != DocSmartConversionMode.deliveryNote;
      }
      _rebuildStagedItems();
    });
  }

  Future<void> _pickCamera() async {
    setState(() => _errorText = null);
    try {
      final page = await AppLockGuard.runWithoutRelock(
        () => widget.ocrService.pickCameraPage(),
      );
      if (page != null && mounted) {
        setState(() => _pages.add(page));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorText = UserFriendlyError.format(e));
      }
    }
  }

  Future<void> _pickGallery() async {
    setState(() => _errorText = null);
    try {
      final picked = await AppLockGuard.runWithoutRelock(
        () => widget.ocrService.pickGalleryPages(),
      );
      if (picked.isNotEmpty && mounted) {
        setState(() => _pages.addAll(picked));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorText = UserFriendlyError.format(e));
      }
    }
  }

  Future<void> _pickPdf() async {
    setState(() {
      _errorText = null;
      _progressText = 'Rendering PDF pages for OCR...';
    });
    try {
      final picked = await AppLockGuard.runWithoutRelock(
        () => widget.ocrService.pickPdfPages(),
      );
      if (mounted) {
        setState(() {
          _progressText = '';
          if (picked.isNotEmpty) _pages.addAll(picked);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progressText = '';
          _errorText = UserFriendlyError.format(e);
        });
      }
    }
  }

  void _parseCsvInput() {
    final parsed = OcrConsensusService.csvToItems(_csvPasteCtrl.text);
    if (parsed.isEmpty) {
      setState(() {
        _errorText =
            'No valid CSV items found. Include header row: Item Description,Quantity,Unit,Unit Price,Total';
      });
      return;
    }
    setState(() {
      _errorText = null;
      _rawExtractedItems = parsed;
      _fullDocResult = null;
      _rebuildStagedItems();
    });
  }

  Future<void> _runOpticalScan() async {
    if (_pages.isEmpty) {
      setState(
        () => _errorText = 'Add at least one photo or PDF page to scan.',
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _errorText = null;
      _progressText = 'Scanning ${_pages.length} page(s)...';
    });

    try {
      if (_mode == DocSmartConversionMode.fullEditableDocument) {
        final docRes = await widget.ocrService.processGeneralDocument(
          _pages,
          onProgress: (msg) {
            if (mounted) setState(() => _progressText = msg);
          },
        );
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _fullDocResult = docRes;
          _rawExtractedItems = docRes.items;
          _resolveRecipient(docRes.recipientName);
          if (docRes.referenceNumber.isNotEmpty) {
            _sourceRefCtrl.text = docRes.referenceNumber;
          }
          if (docRes.date.isNotEmpty) {
            _dateCtrl.text = docRes.date;
          }
          _rebuildStagedItems();
        });
      } else {
        // Docket / Invoice / LPO line-item consensus OCR with fallback to general doc items
        OcrDocketResult? docketRes;
        try {
          docketRes = await widget.ocrService.processDocket(
            _pages,
            onProgress: (msg) {
              if (mounted) setState(() => _progressText = msg);
            },
          );
        } catch (_) {
          docketRes = null;
        }

        if (docketRes != null && docketRes.items.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _isScanning = false;
            _fullDocResult = null;
            _rawExtractedItems = docketRes!.items;
            _resolveRecipient(docketRes.restaurantName);
            if (docketRes.invoiceNumber.isNotEmpty) {
              _sourceRefCtrl.text = docketRes.invoiceNumber;
            }
            if (docketRes.date.isNotEmpty) {
              _dateCtrl.text = docketRes.date;
            }
            _rebuildStagedItems();
          });
          return;
        }

        // Seamless fallback: try general document layout OCR if it's an LPO/table without standard invoice totals
        final docRes = await widget.ocrService.processGeneralDocument(
          _pages,
          onProgress: (msg) {
            if (mounted) setState(() => _progressText = msg);
          },
        );
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _fullDocResult = docRes;
          _rawExtractedItems = docRes.items;
          _resolveRecipient(docRes.recipientName);
          if (docRes.referenceNumber.isNotEmpty) {
            _sourceRefCtrl.text = docRes.referenceNumber;
          }
          if (docRes.date.isNotEmpty) {
            _dateCtrl.text = docRes.date;
          }
          _rebuildStagedItems();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorText = UserFriendlyError.format(
          e,
          fallback:
              'Could not extract clear items from that page. Try a sharper photo or pick a saved invoice.',
        );
      });
    }
  }

  bool get _canConfirm {
    if (_mode == DocSmartConversionMode.fullEditableDocument &&
        _fullDocResult != null) {
      return _fullDocResult!.blocks.isNotEmpty ||
          _stagedItems.any((i) => i.selected);
    }
    return _stagedItems.any((i) => i.selected);
  }

  void _confirm({required bool insertIntoCurrentDoc}) {
    if (!_canConfirm) return;

    if (_mode == DocSmartConversionMode.fullEditableDocument &&
        _fullDocResult != null &&
        _fullDocResult!.blocks.isNotEmpty) {
      final fullDoc = DocumentOcrConverter.buildFullDocumentFromOcr(
        ocrResult: _fullDocResult!,
        vault: widget.vault,
        showKraPin: _showKraPin,
      ).copyWith(
        recipientName: _recipientCtrl.text.trim().isNotEmpty
            ? _recipientCtrl.text.trim()
            : _fullDocResult!.recipientName,
        date: _dateCtrl.text.trim().isNotEmpty
            ? _dateCtrl.text.trim()
            : _fullDocResult!.date,
      );
      Navigator.of(context).pop(
        DocumentOcrImportOutput(
          document: fullDoc,
          insertBlocks: fullDoc.blocks,
          mode: _mode,
          insertIntoCurrentDoc: insertIntoCurrentDoc,
        ),
      );
      return;
    }

    final activeItems = _stagedItems.where((i) => i.selected).toList();
    final builtDoc = DocumentOcrConverter.buildDocumentFromItems(
      mode: _mode,
      items: _stagedItems,
      vault: widget.vault,
      recipientName: _recipientCtrl.text,
      matchedRestaurant: _matchedRestaurant,
      sourceReference: _sourceRefCtrl.text,
      dateIso: _dateCtrl.text,
      driverOrVehicle: _dispatchInfoCtrl.text,
      showOrderedQtyColumn: _showOrderedQtyColumn,
      showKraPin: _showKraPin,
    );
    final insertBlocks = DocumentOcrConverter.buildBlocksForItems(
      mode: _mode,
      activeItems: activeItems,
      sourceReference: _sourceRefCtrl.text,
      driverOrVehicle: _dispatchInfoCtrl.text,
      showOrderedQtyColumn: _showOrderedQtyColumn,
    );

    Navigator.of(context).pop(
      DocumentOcrImportOutput(
        document: builtDoc,
        insertBlocks: insertBlocks,
        mode: _mode,
        insertIntoCurrentDoc: insertIntoCurrentDoc,
      ),
    );
  }

  Future<void> _editItemQtyOrUnit(int index) async {
    final item = _stagedItems[index];
    final qtyCtrl = TextEditingController(
      text: item.dispatchedQty == item.dispatchedQty.roundToDouble()
          ? item.dispatchedQty.toInt().toString()
          : item.dispatchedQty.toString(),
    );
    final unitCtrl = TextEditingController(text: item.unit);
    final remarksCtrl = TextEditingController(text: item.remarks);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Adjust "${item.desc}"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('field_edit_dispatched_qty'),
                    controller: qtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _mode == DocSmartConversionMode.deliveryNote
                          ? 'Qty Dispatched'
                          : 'Quantity',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: unitCtrl,
                    decoration: const InputDecoration(labelText: 'Unit'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: remarksCtrl,
              decoration: const InputDecoration(
                labelText: 'Remarks (e.g. Partial dispatch / Crate #)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final parsedQty =
          double.tryParse(qtyCtrl.text.trim()) ?? item.dispatchedQty;
      setState(() {
        _stagedItems[index] = item.copyWith(
          dispatchedQty: parsedQty > 0 ? parsedQty : item.dispatchedQty,
          unit: unitCtrl.text.trim().isNotEmpty
              ? unitCtrl.text.trim()
              : item.unit,
          remarks: remarksCtrl.text.trim(),
        );
      });
    }
    qtyCtrl.dispose();
    unitCtrl.dispose();
    remarksCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _stagedItems.where((i) => i.selected).length;
    final excludedCount = _stagedItems.length - selectedCount;
    final hydratedCount = _stagedItems
        .where((i) => i.selected && i.priceAutoFilledFromVault)
        .length;

    return Column(
      children: [
        // Sheet Header + Source Tabs
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 10, 0),
          decoration: const BoxDecoration(
            color: AppTheme.surfaceCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Column(
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppTheme.borderSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.sageTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.document_scanner_outlined,
                      color: AppTheme.forestGreen,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smart OCR & Document Converter',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        Text(
                          'Scan invoices/LPOs into clean Delivery Notes, Quotes, or Word Docs',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TabBar(
                controller: _sourceTabCtrl,
                labelColor: AppTheme.forestGreen,
                unselectedLabelColor: AppTheme.slateMuted,
                indicatorColor: AppTheme.forestGreen,
                tabs: const [
                  Tab(
                    key: Key('tab_doc_ocr_camera'),
                    icon: Icon(Icons.photo_camera_outlined, size: 17),
                    text: 'Optical Scan (OCR)',
                  ),
                  Tab(
                    key: Key('tab_doc_saved_invoice'),
                    icon: Icon(Icons.receipt_long_outlined, size: 17),
                    text: 'From Saved Invoice',
                  ),
                ],
              ),
            ],
          ),
        ),

        // Target Role Selector Strip
        Container(
          color: const Color(0xFFF3F7F4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final m in DocSmartConversionMode.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          key: Key('mode_chip_${m.name}'),
                          label: Text(m.label),
                          selected: _mode == m,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => _changeMode(m),
                        ),
                      ),
                    FilterChip(
                      key: const Key('chip_import_show_kra_pin'),
                      label: const Text('Include KRA PIN'),
                      selected: _showKraPin,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) => setState(() {
                        _userToggledKraPin = true;
                        _showKraPin = v;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _mode.subtitle,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.forestGreenDeep,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        // Main Scrollable Body
        Expanded(
          child: TabBarView(
            controller: _sourceTabCtrl,
            children: [
              _buildOpticalScanTab(
                selectedCount: selectedCount,
                excludedCount: excludedCount,
                hydratedCount: hydratedCount,
              ),
              _buildSavedInvoiceTab(
                selectedCount: selectedCount,
                excludedCount: excludedCount,
                hydratedCount: hydratedCount,
              ),
            ],
          ),
        ),

        // Sticky Action Footer
        Container(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            14 +
                math.max(
                  MediaQuery.viewPaddingOf(context).bottom,
                  MediaQuery.paddingOf(context).bottom,
                ),
          ),
          decoration: const BoxDecoration(
            color: AppTheme.surfaceCard,
            border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              if (widget.allowInsertIntoCurrentDoc) ...[
                OutlinedButton.icon(
                  key: const Key('btn_insert_blocks_into_doc'),
                  onPressed: _canConfirm
                      ? () => _confirm(insertIntoCurrentDoc: true)
                      : null,
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('Insert at Cursor'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton.icon(
                key: const Key('btn_create_converted_branded_doc'),
                onPressed: _canConfirm
                    ? () => _confirm(insertIntoCurrentDoc: false)
                    : null,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(
                  switch (_mode) {
                    DocSmartConversionMode.deliveryNote =>
                      'Create Delivery Note',
                    DocSmartConversionMode.quotation => 'Create Quotation',
                    DocSmartConversionMode.discrepancyMemo => 'Create Memo',
                    DocSmartConversionMode.fullEditableDocument =>
                      'Open in Studio',
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOpticalScanTab({
    required int selectedCount,
    required int excludedCount,
    required int hydratedCount,
  }) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (_errorText != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.dangerSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
            ),
            child: Text(
              _errorText!,
              style: const TextStyle(
                color: AppTheme.danger,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('btn_doc_ocr_camera'),
                      onPressed: _isScanning ? null : _pickCamera,
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Camera'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('btn_doc_ocr_gallery'),
                      onPressed: _isScanning ? null : _pickGallery,
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Gallery'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('btn_doc_ocr_pdf'),
                      onPressed: _isScanning ? null : _pickPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: const Text('Upload PDF'),
                    ),
                    TextButton.icon(
                      key: const Key('btn_doc_ocr_toggle_csv'),
                      onPressed: () =>
                          setState(() => _showCsvBox = !_showCsvBox),
                      icon: const Icon(Icons.table_rows_outlined, size: 18),
                      label: const Text('Paste CSV'),
                    ),
                  ],
                ),
                if (_showCsvBox) ...[
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('field_doc_ocr_csv'),
                    controller: _csvPasteCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText:
                          'Item Description,Quantity,Unit,Unit Price,Total\nRoma Tomatoes,20,kgs,120,2400\nDelivery Fee,1,pcs,300,300',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      key: const Key('btn_doc_ocr_parse_csv'),
                      onPressed: _parseCsvInput,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Extract CSV Items'),
                    ),
                  ),
                ],
                if (_pages.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 98,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _pages.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, idx) {
                        final page = _pages[idx];
                        final bytes = page.bytes ??
                            OcrConsensusService.decodeImageDataUrl(page.dataUrl)
                                ?.bytes;
                        return Stack(
                          children: [
                            Container(
                              width: 78,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border:
                                    Border.all(color: AppTheme.borderSubtle),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: bytes != null
                                  ? Image.memory(bytes, fit: BoxFit.cover)
                                  : const Center(
                                      child: Icon(Icons.insert_drive_file),
                                    ),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _pages.removeAt(idx)),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: AppTheme.danger,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('btn_run_doc_ocr_extract'),
                    onPressed: _isScanning ? null : _runOpticalScan,
                    icon: const Icon(Icons.bolt_outlined),
                    label: Text(
                      _isScanning
                          ? 'Scanning...'
                          : 'Scan & Extract (${_pages.length} page${_pages.length == 1 ? '' : 's'})',
                    ),
                  ),
                ],
                if (_isScanning || _progressText.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _progressText,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        if (_stagedItems.isNotEmpty || _fullDocResult != null) ...[
          const SizedBox(height: 12),
          _buildExtractedReviewSection(
            selectedCount: selectedCount,
            excludedCount: excludedCount,
            hydratedCount: hydratedCount,
          ),
        ],
      ],
    );
  }

  Widget _buildSavedInvoiceTab({
    required int selectedCount,
    required int excludedCount,
    required int hydratedCount,
  }) {
    final nonDrafts = widget.vault.invoices
        .where((i) => !i.isDraft)
        .toList()
      ..sort(
        (a, b) => AppHelpers.appDateKey(b.date)
            .compareTo(AppHelpers.appDateKey(a.date)),
      );
    final q = _invoiceQuery.trim().toLowerCase();
    final filtered = q.isEmpty
        ? nonDrafts
        : nonDrafts.where((inv) {
            final rName = Restaurant.invoiceDisplayName(
              inv,
              widget.vault.restaurants,
            ).toLowerCase();
            return inv.number.toLowerCase().contains(q) ||
                rName.contains(q) ||
                inv.date.contains(q);
          }).toList();

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        TextField(
          controller: _invoiceSearchCtrl,
          onChanged: (v) => setState(() => _invoiceQuery = v),
          decoration: const InputDecoration(
            hintText: 'Search invoice # or client name...',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No saved invoices found. Use the Optical Scan tab to photograph a paper invoice or LPO.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.slateMuted),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 195),
            child: Card(
              margin: EdgeInsets.zero,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: filtered.take(30).length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, idx) {
                  final inv = filtered[idx];
                  final selected = inv.id == _selectedSavedInvoiceId;
                  final clientName = Restaurant.invoiceDisplayName(
                    inv,
                    widget.vault.restaurants,
                  );
                  return ListTile(
                    key: ValueKey('pick_inv_${inv.id}'),
                    dense: true,
                    selected: selected,
                    selectedTileColor:
                        AppTheme.sageTint.withValues(alpha: 0.55),
                    leading: Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.receipt_long_outlined,
                      color: AppTheme.forestGreen,
                    ),
                    title: Text(
                      '${inv.number} · $clientName',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${inv.date} · ${inv.items.length} line(s) · KES ${InvoiceFormatters.formatMoney(inv.totalSell)}',
                    ),
                    onTap: () => setState(() => _loadFromSavedInvoice(inv)),
                  );
                },
              ),
            ),
          ),
        if (_stagedItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildExtractedReviewSection(
            selectedCount: selectedCount,
            excludedCount: excludedCount,
            hydratedCount: hydratedCount,
          ),
        ],
      ],
    );
  }

  Widget _buildExtractedReviewSection({
    required int selectedCount,
    required int excludedCount,
    required int hydratedCount,
  }) {
    if (_mode == DocSmartConversionMode.fullEditableDocument &&
        _fullDocResult != null) {
      final res = _fullDocResult!;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Extracted ${res.blocks.length} Editable Block(s)',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                  color: AppTheme.forestGreenDeep,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _recipientCtrl,
                decoration: const InputDecoration(
                  labelText: 'Recipient (Optional)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              ...res.blocks.take(6).map(
                    (b) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        b.isTable
                            ? '[Table: ${b.tableRows.length} rows]'
                            : b.isSignatory
                                ? '[Signatory & Receiving Verification Grid]'
                                : '[${b.kind}] ${b.text}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.slateInk,
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      );
    }

    return Card(
      key: const Key('doc_ocr_staged_review_card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _mode == DocSmartConversionMode.deliveryNote
                        ? 'Delivery Note Items ($selectedCount deliverable)'
                        : 'Extracted Items ($selectedCount selected)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
                if (_matchedRestaurant != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.sageTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Client Matched',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.forestGreenDeep,
                      ),
                    ),
                  ),
              ],
            ),
            if (_mode == DocSmartConversionMode.deliveryNote) ...[
              const SizedBox(height: 4),
              Text(
                excludedCount > 0
                    ? 'Prices stripped · $excludedCount non-goods fee line(s) automatically excluded'
                    : 'All prices, totals & financial columns stripped for receiving bay',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.forestGreen,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ] else if (hydratedCount > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Auto-filled $hydratedCount item price(s) from your Vault Price Lists / Invoices!',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.forestGreen,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _recipientCtrl,
                    onChanged: (v) => _resolveRecipient(v),
                    decoration: const InputDecoration(
                      labelText: 'Client / Deliver To',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _sourceRefCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Order / Invoice / LPO Ref',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            if (_mode == DocSmartConversionMode.deliveryNote) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('field_delivery_vehicle_driver'),
                      controller: _dispatchInfoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Driver / Vehicle Reg (Opt)',
                        hintText: 'e.g. KDM 412T · James',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Ordered Col'),
                    tooltip: 'Show both Qty Ordered & Qty Dispatched columns',
                    selected: _showOrderedQtyColumn,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) =>
                        setState(() => _showOrderedQtyColumn = v),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            for (var i = 0; i < _stagedItems.length; i++)
              _buildStagedItemTile(i, _stagedItems[i]),
          ],
        ),
      ),
    );
  }

  Widget _buildStagedItemTile(int index, SelectableDocItem item) {
    final qtyStr = item.dispatchedQty == item.dispatchedQty.roundToDouble()
        ? item.dispatchedQty.toInt().toString()
        : item.dispatchedQty.toString();

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: item.selected,
        onChanged: (v) {
          setState(() {
            _stagedItems[index] = item.copyWith(selected: v ?? false);
          });
        },
      ),
      title: Text(
        item.desc,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          decoration:
              item.selected ? TextDecoration.none : TextDecoration.lineThrough,
          color: item.selected ? AppTheme.slateInk : AppTheme.slateMuted,
        ),
      ),
      subtitle: Text(
        [
          '$qtyStr ${item.unit}',
          if (item.isPartialQty) 'Ordered: ${item.orderedQty.toStringAsFixed(0)}',
          if (_mode == DocSmartConversionMode.quotation && item.sellPrice > 0)
            '@ KES ${InvoiceFormatters.formatMoney(item.sellPrice)}${item.priceAutoFilledFromVault ? ' (Vault)' : ''}',
          if (item.excludedReason != null && !item.selected)
            item.excludedReason!,
          if (item.remarks.isNotEmpty) item.remarks,
        ].join(' · '),
        style: TextStyle(
          fontSize: 11.5,
          color: (!item.selected && item.excludedReason != null)
              ? AppTheme.warning
              : AppTheme.slateMuted,
        ),
      ),
      trailing: IconButton(
        key: ValueKey('btn_adjust_staged_item_$index'),
        tooltip: 'Adjust quantity / unit / remarks',
        icon: const Icon(Icons.tune, size: 18),
        onPressed: () => _editItemQtyOrUnit(index),
      ),
    );
  }
}
