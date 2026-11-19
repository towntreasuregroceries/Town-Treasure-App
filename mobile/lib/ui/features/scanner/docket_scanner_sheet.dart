import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/services/ocr_consensus_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';

/// Target workflow for `DocketScannerSheet`.
enum ScannerTargetMode {
  docket,
  priceList,
  csvImport,
}

/// Output returned when the user applies scanned or CSV-imported items.
class DocketScannerOutput {
  const DocketScannerOutput({
    this.docketResult,
    this.priceListResult,
    this.csvItems = const [],
  });

  final OcrDocketResult? docketResult;
  final OcrPriceListResult? priceListResult;
  final List<InvoiceLineItem> csvItems;
}

/// Multi-page photo/CSV docket scanner modal returning extracted items to
/// invoice editor, clerk intake form, or price list editor via callback.
class DocketScannerSheet extends StatefulWidget {
  const DocketScannerSheet({
    super.key,
    required this.ocrService,
    this.mode = ScannerTargetMode.docket,
    this.geminiApiKey,
    this.onApplyDocket,
    this.onApplyPriceList,
    this.onApplyCsvItems,
    this.initialPages = const [],
  });

  final OcrConsensusService ocrService;
  final ScannerTargetMode mode;
  final String? geminiApiKey;
  final void Function(OcrDocketResult result)? onApplyDocket;
  final void Function(OcrPriceListResult result)? onApplyPriceList;
  final void Function(List<InvoiceLineItem> items)? onApplyCsvItems;
  final List<OcrImagePage> initialPages;

  /// Opens the scanner modal sheet and returns [DocketScannerOutput] if applied.
  static Future<DocketScannerOutput?> show(
    BuildContext context, {
    required OcrConsensusService ocrService,
    ScannerTargetMode mode = ScannerTargetMode.docket,
    String? geminiApiKey,
    void Function(OcrDocketResult result)? onApplyDocket,
    void Function(OcrPriceListResult result)? onApplyPriceList,
    void Function(List<InvoiceLineItem> items)? onApplyCsvItems,
    List<OcrImagePage> initialPages = const [],
  }) {
    return showModalBottomSheet<DocketScannerOutput>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceSage,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.94,
        child: DocketScannerSheet(
          ocrService: ocrService,
          mode: mode,
          geminiApiKey: geminiApiKey,
          onApplyDocket: onApplyDocket,
          onApplyPriceList: onApplyPriceList,
          onApplyCsvItems: onApplyCsvItems,
          initialPages: initialPages,
        ),
      ),
    );
  }

  @override
  State<DocketScannerSheet> createState() => _DocketScannerSheetState();
}

class _DocketScannerSheetState extends State<DocketScannerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<OcrImagePage> _pages = [];
  final TextEditingController _csvController = TextEditingController();
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');

  bool _isScanning = false;
  String _progressText = '';
  String? _errorText;
  OcrDocketResult? _docketResult;
  OcrPriceListResult? _priceListResult;
  List<InvoiceLineItem> _csvParsedItems = [];

  @override
  void initState() {
    super.initState();
    _pages.addAll(widget.initialPages);
    _tabController = TabController(
      length: widget.mode == ScannerTargetMode.priceList ? 1 : 2,
      vsync: this,
      initialIndex: widget.mode == ScannerTargetMode.csvImport ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _csvController.dispose();
    super.dispose();
  }

  Future<void> _pickFromCamera() async {
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
        setState(() => _errorText = 'Could not open camera: ${UserFriendlyError.format(e)}');
      }
    }
  }

  Future<void> _pickFromGallery() async {
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
        setState(() => _errorText = 'Could not pick photo: ${UserFriendlyError.format(e)}');
      }
    }
  }

  Future<void> _pickFromPdf() async {
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
          if (picked.isNotEmpty) {
            _pages.addAll(picked);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progressText = '';
          _errorText = 'Could not load PDF: ${UserFriendlyError.format(e)}';
        });
      }
    }
  }

  Future<void> _runOcr() async {
    if (_pages.isEmpty) {
      setState(() => _errorText = 'Please attach at least one docket photo.');
      return;
    }

    setState(() {
      _isScanning = true;
      _errorText = null;
      _progressText = 'Initializing analysis for ${_pages.length} page(s)...';
    });

    try {
      if (widget.mode == ScannerTargetMode.priceList) {
        final result = await widget.ocrService.processPriceList(
          _pages,
          geminiApiKey: widget.geminiApiKey,
          onProgress: (status) {
            if (mounted) setState(() => _progressText = status);
          },
        );
        if (!mounted) return;
        setState(() {
          _priceListResult = result;
          _isScanning = false;
        });
      } else {
        final result = await widget.ocrService.processDocket(
          _pages,
          geminiApiKey: widget.geminiApiKey,
          onProgress: (status) {
            if (mounted) setState(() => _progressText = status);
          },
        );
        if (!mounted) return;
        setState(() {
          _docketResult = result;
          _isScanning = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _errorText = UserFriendlyError.format(
          e,
          fallback:
              'Could not read line items from this docket photo. Please try a clearer photo or paste CSV.',
        );
      });
    }
  }

  void _parseCsvText() {
    final parsed = OcrConsensusService.csvToItems(_csvController.text);
    setState(() {
      _csvParsedItems = parsed;
      _errorText = parsed.isEmpty
          ? 'No valid line items found in CSV. Include the header row and at least one item row.'
          : null;
    });
  }

  void _loadCsvSample() {
    const sample = 'Item Description,Quantity,Unit,Unit Price,Total\n'
        '"Red Onions (Medium)",50,kgs,155,7750\n'
        '"Roma Tomatoes",3,crates,3200,9600\n'
        '"Potatoes (Shangi)",2,bags,4200,8400';
    _csvController.text = sample;
    _parseCsvText();
  }

  Future<void> _exportCsv() async {
    final items = _docketResult?.items ?? _csvParsedItems;
    if (items.isEmpty) return;
    final csv = OcrConsensusService.itemsToCsv(items);
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('CSV copied to clipboard.'),
        backgroundColor: AppTheme.forestGreen,
      ),
    );
    await AppLockGuard.runWithoutRelock(
      () => Share.share(csv, subject: 'Town Treasure Docket Items CSV'),
    );
  }

  void _applyExtracted() {
    if (widget.mode == ScannerTargetMode.priceList &&
        _priceListResult != null) {
      widget.onApplyPriceList?.call(_priceListResult!);
      Navigator.of(context).pop(
        DocketScannerOutput(priceListResult: _priceListResult),
      );
      return;
    }

    if (_docketResult != null) {
      widget.onApplyDocket?.call(_docketResult!);
      Navigator.of(context).pop(
        DocketScannerOutput(docketResult: _docketResult),
      );
      return;
    }

    if (_csvParsedItems.isNotEmpty) {
      widget.onApplyCsvItems?.call(_csvParsedItems);
      Navigator.of(context).pop(
        DocketScannerOutput(csvItems: _csvParsedItems),
      );
    }
  }

  void _openZoomPage(OcrImagePage page, int index) {
    final bytes = page.bytes ??
        OcrConsensusService.decodeImageDataUrl(page.dataUrl)?.bytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('Docket Page ${index + 1}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
          body: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: Center(
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPriceList = widget.mode == ScannerTargetMode.priceList;
    final hasResult = _docketResult != null ||
        _priceListResult != null ||
        _csvParsedItems.isNotEmpty;

    return Column(
      children: [
        // Sheet Header
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
          decoration: const BoxDecoration(
            color: AppTheme.surfaceCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(
              bottom: BorderSide(color: AppTheme.borderSubtle),
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
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
                    child: Icon(
                      isPriceList
                          ? Icons.receipt_long_outlined
                          : Icons.document_scanner_outlined,
                      color: AppTheme.forestGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPriceList
                              ? 'Scan Produce Price List'
                              : 'Scan Paper Docket (OCR)',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        const Text(
                          'Multi-page photos, PDF upload, offline AI OCR & CSV',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (!isPriceList) ...[
                const SizedBox(height: 10),
                TabBar(
                  controller: _tabController,
                  labelColor: AppTheme.forestGreen,
                  unselectedLabelColor: AppTheme.slateMuted,
                  indicatorColor: AppTheme.forestGreen,
                  tabs: const [
                    Tab(
                      icon: Icon(Icons.photo_camera_outlined, size: 18),
                      text: 'Photo Scanner',
                    ),
                    Tab(
                      icon: Icon(Icons.table_chart_outlined, size: 18),
                      text: 'CSV Import',
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        // Body
        Expanded(
          child: isPriceList
              ? _buildPhotoScannerTab(isPriceList: true)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildPhotoScannerTab(isPriceList: false),
                    _buildCsvImportTab(),
                  ],
                ),
        ),

        // Footer Actions
        Container(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            16 +
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
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              if (_docketResult != null || _csvParsedItems.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: _exportCsv,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Export CSV'),
                ),
                const SizedBox(width: 10),
              ],
              FilledButton.icon(
                onPressed: hasResult ? _applyExtracted : null,
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(
                  isPriceList ? 'Apply Price List' : 'Apply Items',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoScannerTab({required bool isPriceList}) {
    return ListView(
      padding: const EdgeInsets.all(16),
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
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: AppTheme.danger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _errorText!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Capture / Upload Zone
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_pages.isEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 22,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.sageTint.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.leafGreen.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.add_a_photo_outlined,
                          size: 40,
                          color: AppTheme.forestGreen,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          isPriceList
                              ? 'Capture or Pick Price List Pages'
                              : 'Scan or Import Wholesale Docket',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.forestGreenDeep,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Snap physical pages, pick multiple photos from gallery, or upload a PDF document.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.slateMuted,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: _pickFromCamera,
                              icon: const Icon(Icons.camera_alt_outlined),
                              label: const Text('Take Photo'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _pickFromGallery,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Gallery (Multi)'),
                            ),
                            OutlinedButton.icon(
                              key: const Key('btn_scanner_pick_pdf'),
                              onPressed: _pickFromPdf,
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              label: const Text('Upload PDF'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Text(
                        'Docket Pages (${_pages.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              TextButton.icon(
                                onPressed: _pickFromCamera,
                                icon: const Icon(Icons.add_a_photo_outlined, size: 16),
                                label: const Text('+ Camera'),
                              ),
                              TextButton.icon(
                                onPressed: _pickFromGallery,
                                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                                label: const Text('+ Gallery'),
                              ),
                              TextButton.icon(
                                key: const Key('btn_scanner_add_pdf'),
                                onPressed: _pickFromPdf,
                                icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                                label: const Text('+ PDF'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 136,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _pages.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final page = _pages[index];
                        final bytes = page.bytes ??
                            OcrConsensusService.decodeImageDataUrl(page.dataUrl)
                                ?.bytes;
                        return GestureDetector(
                          onTap: () => _openZoomPage(page, index),
                          child: Container(
                            width: 106,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.borderSubtle),
                              color: AppTheme.surfaceSage,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (bytes != null)
                                  Image.memory(bytes, fit: BoxFit.cover)
                                else
                                  const Center(
                                    child: Icon(
                                      Icons.receipt_outlined,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    color: Colors.black.withValues(alpha: 0.65),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      'Page ${index + 1}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: InkWell(
                                    onTap: () =>
                                        setState(() => _pages.removeAt(index)),
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                        color: AppTheme.danger,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.close,
                                        size: 13,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isScanning ? null : _runOcr,
                          icon: const Icon(Icons.bolt_outlined),
                          label: Text(
                            'Auto-Extract from ${_pages.length} Page${_pages.length > 1 ? 's' : ''}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Clear all pages',
                        onPressed: _isScanning
                            ? null
                            : () => setState(() {
                                  _pages.clear();
                                  _docketResult = null;
                                  _priceListResult = null;
                                }),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        // Animated Progress
        AnimatedSwitcher(
          duration: AppMotion.standard,
          child: _isScanning
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.forestGreen,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _progressText,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.slateInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),

        // Extracted Docket Results
        if (_docketResult != null) ...[
          const SizedBox(height: 14),
          _buildDocketResultCard(_docketResult!),
        ],

        // Extracted Price List Results
        if (_priceListResult != null) ...[
          const SizedBox(height: 14),
          _buildPriceListResultCard(_priceListResult!),
        ],
      ],
    );
  }

  Widget _buildDocketResultCard(OcrDocketResult result) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${result.items.length} Items Extracted',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppTheme.slateInk,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.successSurface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${result.confidence}% Confidence',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.forestGreenDeep,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Engines: ${result.enginesUsed.join(' + ')}',
              style: const TextStyle(fontSize: 11, color: AppTheme.slateMuted),
            ),
            if (result.restaurantName.isNotEmpty || result.date.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (result.restaurantName.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.storefront_outlined,
                        size: 16,
                        color: AppTheme.forestGreen,
                      ),
                      label: Text(result.restaurantName),
                    ),
                  if (result.date.isNotEmpty)
                    Chip(
                      avatar: const Icon(
                        Icons.calendar_today_outlined,
                        size: 15,
                        color: AppTheme.forestGreen,
                      ),
                      label: Text(result.date),
                    ),
                ],
              ),
            ],
            const Divider(height: 20),
            ...result.items.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.desc,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppTheme.slateInk,
                            ),
                          ),
                          Text(
                            '${_fmtQty(item.qty)} ${item.unit} x KES ${_moneyFmt.format(item.sellPrice)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      'KES ${_moneyFmt.format(item.total)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.forestGreenDeep,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Calculated Subtotal',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateMuted,
                  ),
                ),
                Text(
                  'KES ${_moneyFmt.format(result.subtotal)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppTheme.forestGreen,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceListResultCard(OcrPriceListResult result) {
    final itemCount = result.items.where((i) => !i.isHeader).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    result.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                Chip(label: Text('$itemCount items')),
              ],
            ),
            Text(
              '${result.subtitle} (${result.effectiveDate})',
              style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            ),
            const Divider(height: 20),
            ...result.items.map((it) {
              if (it.isHeader) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    it.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.forestGreen,
                      letterSpacing: 0.6,
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        it.name,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    Text(
                      'KES ${_moneyFmt.format(it.price)} / ${it.unit}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.forestGreenDeep,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildCsvImportTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Paste CSV Line Items',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _loadCsvSample,
                      child: const Text('Load Sample'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Columns: Item Description, Quantity, Unit, Unit Price, Total',
                  style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _csvController,
                  minLines: 6,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText:
                        'Item Description,Quantity,Unit,Unit Price,Total\n"Red Onions",50,kgs,155,7750',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _parseCsvText,
                  icon: const Icon(Icons.playlist_add_check_outlined),
                  label: const Text('Parse CSV Rows'),
                ),
              ],
            ),
          ),
        ),
        if (_csvParsedItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parsed ${_csvParsedItems.length} Line Item(s)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.forestGreenDeep,
                    ),
                  ),
                  const Divider(height: 16),
                  ..._csvParsedItems.map(
                    (it) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${it.desc} (${_fmtQty(it.qty)} ${it.unit})',
                            ),
                          ),
                          Text(
                            'KES ${_moneyFmt.format(it.total)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _fmtQty(double qty) {
    return qty == qty.roundToDouble()
        ? qty.toInt().toString()
        : qty.toStringAsFixed(2);
  }
}

/// Renders a docket photo from a `data:image/...;base64,...` URL or SVG fallback.
class DocketReceiptImage extends StatelessWidget {
  const DocketReceiptImage({
    super.key,
    required this.dataUrl,
    this.fit = BoxFit.contain,
    this.height,
  });

  final String dataUrl;
  final BoxFit fit;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final decoded = OcrConsensusService.decodeImageDataUrl(dataUrl);
    if (decoded != null) {
      return Image.memory(
        decoded.bytes,
        fit: fit,
        height: height,
        errorBuilder: (_, _, _) => _fallbackBox(),
      );
    }
    if (dataUrl.startsWith('data:image/svg+xml')) {
      return Container(
        height: height ?? 160,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.sageTint,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderSubtle),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 36, color: AppTheme.forestGreen),
            SizedBox(height: 8),
            Text(
              'Digital Vector Docket Preview',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.forestGreenDeep,
              ),
            ),
          ],
        ),
      );
    }
    return _fallbackBox();
  }

  Widget _fallbackBox() {
    return Container(
      height: height ?? 140,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.surfaceSage,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, color: AppTheme.slateMuted),
          SizedBox(height: 6),
          Text(
            'Unable to render receipt image',
            style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
          ),
        ],
      ),
    );
  }
}
