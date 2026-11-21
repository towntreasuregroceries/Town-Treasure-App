import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../../data/services/print_service.dart';
import '../app_lock_guard.dart';
import '../theme/app_theme.dart';
import '../user_friendly_error.dart';

/// Single rasterized page emitted by [PdfRasterProvider] for in-app viewing.
class RasterizedPdfPage {
  const RasterizedPdfPage({
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  final Uint8List pngBytes;
  final int width;
  final int height;
}

typedef PdfRasterStreamProvider = Stream<RasterizedPdfPage> Function(
  Uint8List pdfBytes,
  double dpi,
);

/// Town Treasure Groceries branded in-app PDF viewer requiring zero external PDF apps.
/// Features progressive high-DPI rasterization, pinch/double-tap zoom, paper format
/// switching, thumbnail page strip, Android Print Spooler dispatch, and PDF sharing.
class BrandedPdfViewerScreen extends StatefulWidget {
  const BrandedPdfViewerScreen({
    super.key,
    required this.title,
    required this.filename,
    required this.buildPdf,
    this.initialPaperFormat = PrintPaperFormat.a4,
    this.supportsThermalRoll = true,
    this.printService,
    this.rasterStreamProvider,
    this.onOpenPrintCenter,
  });

  final String title;
  final String filename;
  final Future<Uint8List> Function(PdfPageFormat format) buildPdf;
  final PrintPaperFormat initialPaperFormat;
  final bool supportsThermalRoll;
  final PrintService? printService;
  final PdfRasterStreamProvider? rasterStreamProvider;
  final void Function(PrintPaperFormat format)? onOpenPrintCenter;

  @override
  State<BrandedPdfViewerScreen> createState() => _BrandedPdfViewerScreenState();
}

class _BrandedPdfViewerScreenState extends State<BrandedPdfViewerScreen> {
  late PrintPaperFormat _paperFormat;
  late final PrintService _printService;
  final PageController _pageController = PageController();
  final TransformationController _zoomController = TransformationController();

  Uint8List? _pdfBytes;
  final List<RasterizedPdfPage> _pages = [];
  bool _loading = true;
  bool _streaming = false;
  bool _actionBusy = false;
  String? _error;
  int _currentPage = 0;
  double _currentScale = 1.0;
  Offset? _doubleTapLocalPos;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _paperFormat = widget.initialPaperFormat;
    _printService = widget.printService ?? PrintService();
    _zoomController.addListener(_onZoomChanged);
    _loadDocument();
  }

  @override
  void dispose() {
    _loadEpoch++;
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    if ((scale - _currentScale).abs() > 0.02 && mounted) {
      setState(() => _currentScale = scale);
    }
  }

  Future<void> _loadDocument() async {
    final epoch = ++_loadEpoch;
    setState(() {
      _loading = true;
      _streaming = true;
      _error = null;
      _pages.clear();
      _pdfBytes = null;
      _currentPage = 0;
    });
    _resetZoom();

    try {
      final bytes = await AppLockGuard.runWithoutRelock(
        () => widget.buildPdf(_paperFormat.pdfPageFormat),
      );
      if (!mounted || epoch != _loadEpoch) return;
      _pdfBytes = bytes;

      final stream = (widget.rasterStreamProvider ?? _defaultRasterStream)(
        bytes,
        150.0,
      );

      await for (final page in stream) {
        if (!mounted || epoch != _loadEpoch) return;
        setState(() {
          _pages.add(page);
          _loading = false;
        });
      }

      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _streaming = false;
        if (_pages.isEmpty) {
          _error = 'PDF rendered 0 pages.';
        }
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _streaming = false;
        _error = UserFriendlyError.format(
          e,
          fallback: 'Could not render PDF preview inside the app.',
        );
      });
    }
  }

  static Stream<RasterizedPdfPage> _defaultRasterStream(
    Uint8List pdfBytes,
    double dpi,
  ) async* {
    await for (final page in Printing.raster(pdfBytes, dpi: dpi)) {
      final png = await page.toPng();
      yield RasterizedPdfPage(
        pngBytes: png,
        width: page.width,
        height: page.height,
      );
    }
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
    if (_currentScale != 1.0 && mounted) {
      setState(() => _currentScale = 1.0);
    }
  }

  void _setZoomScale(double targetScale, {Offset? focalPoint}) {
    final clamped = targetScale.clamp(1.0, 4.0);
    if ((clamped - 1.0).abs() < 0.05) {
      _resetZoom();
      return;
    }
    if (focalPoint != null) {
      final dx = -focalPoint.dx * (clamped - 1.0);
      final dy = -focalPoint.dy * (clamped - 1.0);
      _zoomController.value = Matrix4.translationValues(dx, dy, 0)
        ..scaleByDouble(clamped, clamped, 1.0, 1.0);
    } else {
      _zoomController.value =
          Matrix4.diagonal3Values(clamped, clamped, 1.0);
    }
  }

  void _handleDoubleTap() {
    if (_currentScale > 1.2) {
      _resetZoom();
    } else {
      _setZoomScale(2.2, focalPoint: _doubleTapLocalPos);
    }
  }

  void _jumpToPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    _resetZoom();
    _pageController.animateToPage(
      index,
      duration: AppMotion.fast,
      curve: AppMotion.standardCurve,
    );
  }

  Future<void> _handleSystemPrint() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await _printService.printViaSystem(
        documentName: widget.filename,
        format: _paperFormat.pdfPageFormat,
        onLayout: (fmt) => widget.buildPdf(fmt),
      );
    } catch (e) {
      _showSnack(
        UserFriendlyError.format(e, fallback: 'Print dialog could not open.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _handleSharePdf() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final bytes =
          _pdfBytes ?? await widget.buildPdf(_paperFormat.pdfPageFormat);
      await _printService.sharePdfToApps(
        bytes: bytes,
        filename: widget.filename,
        subject: widget.title,
      );
    } catch (e) {
      _showSnack(
        UserFriendlyError.format(e, fallback: 'Could not share PDF.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.danger : AppTheme.forestGreen,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final availableFormats = widget.supportsThermalRoll
        ? PrintPaperFormat.values
        : const [PrintPaperFormat.a4, PrintPaperFormat.letter];
    final isZoomed = _currentScale > 1.05;

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.eco_outlined, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Town Treasure Document Viewer',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<PrintPaperFormat>(
            key: const Key('btn_viewer_paper_format'),
            tooltip: 'Paper format',
            onSelected: (fmt) {
              if (fmt == _paperFormat) return;
              setState(() => _paperFormat = fmt);
              _loadDocument();
            },
            itemBuilder: (_) => availableFormats
                .map(
                  (fmt) => CheckedPopupMenuItem(
                    value: fmt,
                    checked: fmt == _paperFormat,
                    child: Text(fmt.label),
                  ),
                )
                .toList(),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _paperFormat.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.arrow_drop_down,
                    color: Colors.white,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: const BoxDecoration(
          color: AppTheme.surfaceCard,
          border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('btn_viewer_print'),
                  onPressed: _actionBusy
                      ? null
                      : () {
                          if (widget.onOpenPrintCenter != null) {
                            widget.onOpenPrintCenter!(_paperFormat);
                          } else {
                            _handleSystemPrint();
                          }
                        },
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('btn_viewer_share'),
                onPressed: _actionBusy ? null : _handleSharePdf,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Share'),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Top branded status & zoom control ribbon
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: const BoxDecoration(
              color: AppTheme.surfaceCard,
              border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.sageTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _pages.isEmpty
                        ? (_loading ? 'Rendering PDF...' : '0 pages')
                        : 'Page ${_currentPage + 1} of ${_pages.length}${_streaming ? '+' : ''}',
                    key: const Key('lbl_viewer_page_counter'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.forestGreenDeep,
                    ),
                  ),
                ),
                if (_streaming && _pages.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                const Spacer(),
                IconButton(
                  tooltip: 'Zoom out',
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentScale > 1.05
                      ? () => _setZoomScale(_currentScale - 0.5)
                      : null,
                  icon: const Icon(Icons.zoom_out, size: 20),
                ),
                InkWell(
                  onTap: isZoomed ? _resetZoom : () => _setZoomScale(1.8),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      '${(_currentScale * 100).round()}%',
                      key: const Key('lbl_viewer_zoom'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: AppTheme.slateInk,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  visualDensity: VisualDensity.compact,
                  onPressed: _currentScale < 3.9
                      ? () => _setZoomScale(_currentScale + 0.5)
                      : null,
                  icon: const Icon(Icons.zoom_in, size: 20),
                ),
              ],
            ),
          ),

          // Main interactive paper viewport
          Expanded(
            child: _buildViewport(isZoomed),
          ),

          // Multi-page thumbnail strip
          if (_pages.length > 1)
            Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: AppTheme.surfaceCard,
                border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
              ),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _pages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final active = idx == _currentPage;
                  return InkWell(
                    onTap: () => _jumpToPage(idx),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 48,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: active
                              ? AppTheme.forestGreen
                              : AppTheme.borderSubtle,
                          width: active ? 2 : 1,
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.memory(
                              _pages[idx].pngBytes,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            right: 2,
                            bottom: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? AppTheme.forestGreen
                                    : AppTheme.slateDark.withValues(alpha: 0.78),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${idx + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
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
        ],
      ),
    );
  }

  Widget _buildViewport(bool isZoomed) {
    if (_loading && _pages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.forestGreen),
            SizedBox(height: 14),
            Text(
              'Preparing Town Treasure document...',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.slateDark,
              ),
            ),
          ],
        ),
      );
    }

    if (_error != null && _pages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: AppTheme.danger,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.slateInk),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadDocument,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          physics: isZoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          onPageChanged: (idx) {
            _resetZoom();
            setState(() => _currentPage = idx);
          },
          itemCount: _pages.length,
          itemBuilder: (context, index) {
            final page = _pages[index];
            return GestureDetector(
              onDoubleTapDown: (details) =>
                  _doubleTapLocalPos = details.localPosition,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _zoomController,
                minScale: 1.0,
                maxScale: 4.0,
                panEnabled: isZoomed,
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: _paperFormat.isThermalRoll ? 360 : 620,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.borderSubtle),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Image.memory(
                            page.pngBytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (_pages.length > 1 && !isZoomed) ...[
          if (_currentPage > 0)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  tooltip: 'Previous page',
                  onPressed: () => _jumpToPage(_currentPage - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
              ),
            ),
          if (_currentPage < _pages.length - 1)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filledTonal(
                  tooltip: 'Next page',
                  onPressed: () => _jumpToPage(_currentPage + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
