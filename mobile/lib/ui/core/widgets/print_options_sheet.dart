import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/print_service.dart';
import '../theme/app_theme.dart';
import '../user_friendly_error.dart';
import 'branded_pdf_viewer_screen.dart';

/// Descriptor for any printable business document (Invoice, Multi-Invoice Batch,
/// Price List, Client Statement, or Business Report).
class PrintableDocument {
  const PrintableDocument({
    required this.title,
    required this.filename,
    required this.buildPdf,
    this.buildEscPos,
    this.supportsThermalRoll = true,
  });

  final String title;
  final String filename;
  final Future<Uint8List> Function(PdfPageFormat format) buildPdf;
  final Uint8List Function(int lineWidth)? buildEscPos;
  final bool supportsThermalRoll;
}

/// Shows the unified print center bottom sheet (System/Mopria/USB Print,
/// Full-Screen Interactive Preview, Wi-Fi/LAN Direct IPP/9100 & ESC/POS Thermal,
/// Network Auto-Discovery, App/Bluetooth Share Bridge, and Open/Save PDF).
Future<void> showPrintOptionsSheet(
  BuildContext context, {
  required PrintableDocument document,
  PrintService? printService,
}) {
  VaultRepository? vault;
  try {
    vault = context.read<VaultRepository>();
  } catch (_) {
    vault = null;
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTheme.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => PrintOptionsSheet(
      document: document,
      printService: printService ?? PrintService(),
      vault: vault,
    ),
  );
}

class PrintOptionsSheet extends StatefulWidget {
  const PrintOptionsSheet({
    super.key,
    required this.document,
    required this.printService,
    this.vault,
  });

  final PrintableDocument document;
  final PrintService printService;
  final VaultRepository? vault;

  @override
  State<PrintOptionsSheet> createState() => _PrintOptionsSheetState();
}

class _PrintOptionsSheetState extends State<PrintOptionsSheet> {
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '631');

  PrintPaperFormat _paperFormat = PrintPaperFormat.a4;
  WifiPrintProtocol _protocol = WifiPrintProtocol.ippPdf;
  int _copies = 1;
  bool _busy = false;
  bool _scanning = false;
  String? _statusMsg;
  bool _statusIsError = false;
  List<DiscoveredLanPrinter> _discovered = const [];

  @override
  void initState() {
    super.initState();
    _loadSavedPrinter();
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedPrinter() async {
    final vault = widget.vault;
    if (vault == null) return;
    final raw = await vault.getSavedPrinterConfig();
    if (!mounted || raw.isEmpty) return;
    final saved = SavedPrinterConfig.fromJson(raw);
    setState(() {
      if (saved.host.isNotEmpty) {
        _hostCtrl.text = saved.host;
      }
      _protocol = saved.protocol;
      _portCtrl.text = saved.port.toString();
      if (widget.document.supportsThermalRoll || !saved.paperFormat.isThermalRoll) {
        _paperFormat = saved.paperFormat;
      }
    });
  }

  Future<void> _persistPrinterConfig() async {
    final vault = widget.vault;
    if (vault == null || _hostCtrl.text.trim().isEmpty) return;
    final parsed = PrintService.parseHostAndPort(
      _hostCtrl.text,
      fallbackPort:
          int.tryParse(_portCtrl.text.trim()) ?? _protocol.defaultPort,
    );
    await vault.savePrinterConfig(
      SavedPrinterConfig(
        host: parsed.host,
        port: parsed.port,
        protocol: _protocol,
        paperFormat: _paperFormat,
      ).toJson(),
    );
  }

  void _setStatus(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMsg = msg;
      _statusIsError = isError;
    });
  }

  Future<void> _handleSystemPrint() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final format = _paperFormat.pdfPageFormat;
      final ok = await widget.printService.printViaSystem(
        documentName: widget.document.filename,
        format: format,
        onLayout: (fmt) => widget.document.buildPdf(fmt),
      );
      if (mounted && ok) {
        _setStatus('Sent print job to Android print spooler.');
      }
    } catch (e) {
      _setStatus(
        UserFriendlyError.format(e, fallback: 'System print could not start.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleInteractivePreview() async {
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BrandedPdfViewerScreen(
          title: widget.document.title,
          filename: widget.document.filename,
          initialPaperFormat: _paperFormat,
          supportsThermalRoll: widget.document.supportsThermalRoll,
          buildPdf: widget.document.buildPdf,
          printService: widget.printService,
        ),
      ),
    );
  }

  Future<void> _handleShareToPrinterApp() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final bytes = await widget.document.buildPdf(_paperFormat.pdfPageFormat);
      await widget.printService.sharePdfToApps(
        bytes: bytes,
        filename: widget.document.filename,
        subject: widget.document.title,
      );
      _setStatus('Opened share sheet for external printer/app.');
    } catch (e) {
      _setStatus(
        UserFriendlyError.format(e, fallback: 'Could not share PDF.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleOpenPdfFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final bytes = await widget.document.buildPdf(_paperFormat.pdfPageFormat);
      final res = await widget.printService.openTempPdf(
        bytes: bytes,
        filename: widget.document.filename,
      );
      _setStatus('PDF saved and opened (${res.message}).');
    } catch (e) {
      _setStatus(
        UserFriendlyError.format(e, fallback: 'Could not open PDF file.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleScanWifiPrinters() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _statusMsg = null;
    });
    try {
      final found = await widget.printService.discoverLanPrinters();
      if (!mounted) return;
      setState(() => _discovered = found);
      if (found.isEmpty) {
        _setStatus(
          'No Wi-Fi printers responded automatically on ports 631/9100. Make sure your phone and printer are on the same Wi-Fi, or type the printer IP manually.',
        );
      } else {
        final first = found.first;
        _hostCtrl.text = first.host;
        _portCtrl.text = first.port.toString();
        setState(() {
          _protocol = first.protocol == WifiPrintProtocol.ippPdf
              ? WifiPrintProtocol.ippPdf
              : (widget.document.buildEscPos != null && _paperFormat.isThermalRoll
                  ? WifiPrintProtocol.escPos9100
                  : WifiPrintProtocol.rawPdf9100);
        });
        _setStatus(
          'Found ${found.length} network printer port(s). Tap one below or press Send to Wi-Fi Printer.',
        );
      }
    } catch (e) {
      _setStatus(
        UserFriendlyError.format(e, fallback: 'Wi-Fi printer scan failed.'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _handleDirectWifiSend() async {
    if (_busy) return;
    final rawHost = _hostCtrl.text.trim();
    if (rawHost.isEmpty) {
      _setStatus(
        'Enter the printer IP address (e.g. 192.168.1.50) or scan Wi-Fi.',
        isError: true,
      );
      return;
    }

    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final port =
          int.tryParse(_portCtrl.text.trim()) ?? _protocol.defaultPort;
      final pdfBytes = _protocol == WifiPrintProtocol.escPos9100
          ? Uint8List(0)
          : await widget.document.buildPdf(_paperFormat.pdfPageFormat);
      final escPosBytes = (_protocol == WifiPrintProtocol.escPos9100 &&
              widget.document.buildEscPos != null)
          ? widget.document.buildEscPos!(_paperFormat.escPosColumns)
          : null;

      final resultMsg = await widget.printService.sendDirectWifiPrint(
        hostInput: rawHost,
        port: port,
        protocol: _protocol,
        jobName: widget.document.title,
        pdfBytes: pdfBytes,
        escPosBytes: escPosBytes,
        copies: _copies,
      );
      await _persistPrinterConfig();
      _setStatus(resultMsg);
    } catch (e) {
      _setStatus(
        UserFriendlyError.format(
          e,
          fallback: 'Could not reach the Wi-Fi printer.',
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final formats = widget.document.supportsThermalRoll
        ? PrintPaperFormat.values
        : const [PrintPaperFormat.a4, PrintPaperFormat.letter];
    final availableProtocols = widget.document.buildEscPos != null
        ? WifiPrintProtocol.values
        : const [WifiPrintProtocol.ippPdf, WifiPrintProtocol.rawPdf9100];
    if (!availableProtocols.contains(_protocol)) {
      _protocol = WifiPrintProtocol.ippPdf;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.sageTint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.print_outlined,
                    color: AppTheme.forestGreen,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Print & Dispatch Center',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      Text(
                        widget.document.title,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.slateMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
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
            const SizedBox(height: 12),

            // Paper size & Copies row
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...formats.map(
                  (fmt) => ChoiceChip(
                    label: Text(fmt.label),
                    selected: _paperFormat == fmt,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _paperFormat = fmt),
                    selectedColor: AppTheme.sageTint,
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderSubtle),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Decrease copies',
                        onPressed: _copies > 1 && !_busy
                            ? () => setState(() => _copies--)
                            : null,
                        icon: const Icon(Icons.remove, size: 18),
                      ),
                      Text(
                        '$_copies ${_copies == 1 ? 'copy' : 'copies'}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Increase copies',
                        onPressed: _copies < 20 && !_busy
                            ? () => setState(() => _copies++)
                            : null,
                        icon: const Icon(Icons.add, size: 18),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Primary Android Print / Preview / App Bridge Actions
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('btn_system_print'),
                  onPressed: _busy ? null : _handleSystemPrint,
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('System / Wi-Fi Print'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_print_preview'),
                  onPressed: _busy ? null : _handleInteractivePreview,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('View PDF in App'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_share_printer_app'),
                  onPressed: _busy ? null : _handleShareToPrinterApp,
                  icon: const Icon(Icons.bluetooth_connected_outlined, size: 18),
                  label: const Text('Send to Printer App'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_open_pdf_file'),
                  onPressed: _busy ? null : _handleOpenPdfFile,
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('Open / Save PDF'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Direct Wi-Fi / LAN Printer Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSage,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.wifi_outlined,
                        color: AppTheme.forestGreen,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Direct Wi-Fi / LAN Network Printer',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.slateInk,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('btn_scan_wifi_printers'),
                        onPressed:
                            _scanning || _busy ? null : _handleScanWifiPrinters,
                        icon: _scanning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.radar, size: 18),
                        label: Text(_scanning ? 'Scanning...' : 'Scan Wi-Fi'),
                      ),
                    ],
                  ),
                  if (_discovered.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _discovered
                          .map(
                            (p) => ActionChip(
                              avatar: const Icon(Icons.print, size: 16),
                              label: Text(p.displayLabel),
                              onPressed: () {
                                setState(() {
                                  _hostCtrl.text = p.host;
                                  _portCtrl.text = p.port.toString();
                                  _protocol = p.protocol;
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          key: const Key('input_printer_ip'),
                          controller: _hostCtrl,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Printer IP / Host *',
                            hintText: '192.168.1.50',
                            filled: true,
                            fillColor: Colors.white,
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          key: const Key('input_printer_port'),
                          controller: _portCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            hintText: '631',
                            filled: true,
                            fillColor: Colors.white,
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<WifiPrintProtocol>(
                    key: const Key('dropdown_wifi_protocol'),
                    initialValue: _protocol,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Network Print Protocol',
                      filled: true,
                      fillColor: Colors.white,
                      isDense: true,
                    ),
                    items: availableProtocols
                        .map(
                          (p) => DropdownMenuItem(
                            value: p,
                            child: Text(
                              p.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      setState(() {
                        _protocol = val;
                        _portCtrl.text = val.defaultPort.toString();
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('btn_send_wifi_print'),
                    onPressed: _busy ? null : _handleDirectWifiSend,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_outlined, size: 18),
                    label: Text(
                      _busy ? 'Sending to Printer...' : 'Send to Wi-Fi Printer',
                    ),
                  ),
                ],
              ),
            ),

            if (_statusMsg != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _statusIsError
                      ? AppTheme.dangerSurface
                      : AppTheme.successSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _statusMsg!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _statusIsError
                        ? AppTheme.danger
                        : AppTheme.forestGreenDeep,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
