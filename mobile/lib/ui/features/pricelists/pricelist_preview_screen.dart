import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/print_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/stamp_signature_helper.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/app_print_helper.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../invoices/invoice_formatters.dart';
import 'pricelist_pdf_builder.dart';
import 'pricelists_view_model.dart';

/// Watermarked Price List A4 preview, PDF export, and WhatsApp share screen.
class PriceListPreviewScreen extends StatefulWidget {
  const PriceListPreviewScreen({
    super.key,
    required this.priceListId,
    this.viewModel,
    this.onEdit,
  });

  final String priceListId;
  final PriceListsViewModel? viewModel;
  final VoidCallback? onEdit;

  @override
  State<PriceListPreviewScreen> createState() => _PriceListPreviewScreenState();
}

class _PriceListPreviewScreenState extends State<PriceListPreviewScreen> {
  PriceListsViewModel? _ownedVm;
  bool _busy = false;

  PriceListsViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = PriceListsViewModel(vault: context.read<VaultRepository>());
    }
  }

  @override
  void dispose() {
    _ownedVm?.dispose();
    super.dispose();
  }

  Future<void> _downloadOrPrintPdf(PriceList pl) async {
    await AppPrintHelper.openPreview(
      context,
      document: PrintableDocument(
        title: pl.name,
        filename: '${pl.name.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')}.pdf',
        supportsThermalRoll: false,
        buildPdf: (_) => PriceListPdfBuilder.buildPdfBytes(
          pl,
          settings: _vm.settings,
        ),
        buildEscPos: (cols) => EscPosReceiptBuilder.buildSummaryReceipt(
          title: pl.name,
          lines: pl.items
              .map(
                (it) => it.isHeader
                    ? '[ ${it.name} ]'
                    : '${it.name} (${it.unit}): KES ${InvoiceFormatters.formatMoney(it.price)}',
              )
              .toList(),
          lineWidth: cols,
        ),
      ),
    );
  }

  Future<void> _sharePdfFile(PriceList pl) async {
    setState(() => _busy = true);
    try {
      final file = await PriceListPdfBuilder.writeTempPdfFile(
        pl,
        settings: _vm.settings,
      );
      await AppLockGuard.runWithoutRelock(
        () => Share.shareXFiles(
          [
            XFile(
              file.path,
              mimeType: 'application/pdf',
              name: file.uri.pathSegments.last,
            ),
          ],
          subject: pl.name,
          text: PriceListsViewModel.buildWhatsAppShareText(pl),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not share PDF: ${UserFriendlyError.format(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWhatsApp(PriceList pl) async {
    await _sharePdfFile(pl);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final pl = _vm.findById(widget.priceListId);
        if (pl == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Price List Preview')),
            body: const Center(child: Text('Price list not found.')),
          );
        }

        final sections = PriceListsViewModel.groupSections(pl);
        final sigBytes = _decodeSignature(_vm.settings.signature);
        final dateText = PriceListsViewModel.formatDate(
          DateTime.now().toIso8601String().substring(0, 10),
        );

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: Text(pl.name),
            actions: [
              if (widget.onEdit != null)
                IconButton(
                  tooltip: 'Edit Price List',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: widget.onEdit,
                ),
              IconButton(
                tooltip: 'Download / Print PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: _busy ? null : () => _downloadOrPrintPdf(pl),
              ),
              IconButton(
                tooltip: 'Share PDF',
                icon: const Icon(Icons.share_outlined),
                onPressed: _busy ? null : () => _sharePdfFile(pl),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _downloadOrPrintPdf(pl),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('PDF'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _shareWhatsApp(pl),
                      icon: const Icon(Icons.chat_outlined),
                      label: const Text('WhatsApp'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: Transform.rotate(
                              angle: -0.52,
                              child: Text(
                                'Town Treasure Limited',
                                style: TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.grey.withValues(alpha: 0.08),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(height: 10, color: AppTheme.leafGreen),
                          Container(height: 3, color: AppTheme.slateDark),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
                            child: Column(
                              children: [
                                Image.asset(
                                  'assets/logo.png',
                                  height: 76,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) => const Text(
                                    'TOWN TREASURE GROCERIES',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.forestGreen,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  pl.subtitle.isNotEmpty
                                      ? pl.subtitle
                                      : 'Food Supplies (Veg and Fruits)',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.slateDark,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Email: thetowntreasure25@gmail.com | TEL: 0708567696',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.slateDark,
                                  ),
                                ),
                                const Divider(height: 24),
                                const Text(
                                  'Price List',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.leafGreen,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                for (final section in sections) ...[
                                  if (section.header != null &&
                                      section.header!.trim().isNotEmpty)
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            AppTheme.leafGreen,
                                            Color(0xFF4A9E36),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.only(
                                          topLeft: Radius.circular(6),
                                          topRight: Radius.circular(6),
                                        ),
                                      ),
                                      child: Text(
                                        section.header!.toUpperCase(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ),
                                  if (section.items.isNotEmpty)
                                    _PreviewSectionTable(items: section.items),
                                  const SizedBox(height: 14),
                                ],
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Transform.rotate(
                                    angle: -0.06,
                                    child: Container(
                                      width: 200,
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: AppTheme.slateDark,
                                          width: 2.2,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Column(
                                        children: [
                                          Image.asset(
                                            'assets/stamp.png',
                                            height: 34,
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, _, _) =>
                                                const Text(
                                              'TOWN TREASURE GROCERIES',
                                              style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          const Text(
                                            'APPROVED PRICING',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 0.8,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'DATE: $dateText',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: AppTheme.danger,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          if (sigBytes != null)
                                            Image.memory(
                                              sigBytes,
                                              height: 42,
                                              fit: BoxFit.contain,
                                            )
                                          else
                                            const Padding(
                                              padding: EdgeInsets.only(top: 14),
                                              child: Text(
                                                'Authorized Signature',
                                                style: TextStyle(fontSize: 10),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            color: AppTheme.slateDark,
                            child: const Center(
                              child: Text(
                                'Town Treasure Groceries — Fresh & Affordable',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontStyle: FontStyle.italic,
                                  fontSize: 12,
                                ),
                              ),
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
        );
      },
    );
  }

  Uint8List? _decodeSignature(String? raw) {
    return StampSignatureHelper.prepareSignaturePng(raw);
  }
}

class _PreviewSectionTable extends StatelessWidget {
  const _PreviewSectionTable({required this.items});

  final List<PriceListItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD1D5DB)),
      ),
      child: Column(
        children: [
          Container(
            color: AppTheme.leafGreen,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: const Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    'Commodity Description',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Measurement',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'Price (KES)',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final item in items)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFFD1D5DB), width: 0.7),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      item.name,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateInk,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      PriceListsViewModel.formatMeasurement(item.unit),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      PriceListsViewModel.formatMoney(item.price),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.forestGreenDeep,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
