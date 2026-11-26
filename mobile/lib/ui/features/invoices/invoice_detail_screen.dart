import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/print_service.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_print_helper.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../documents/document_ocr_converter.dart';
import '../documents/document_ocr_import_sheet.dart';
import '../documents/document_studio_screen.dart';
import '../kra/kra_tax_center_screen.dart';
import 'invoice_editor_screen.dart';
import 'invoice_formatters.dart';
import 'invoice_pdf_builder.dart';
import 'invoices_view_model.dart';

/// Mobile-first Invoice Detail preview screen with Paid/Unpaid toggle,
/// A4 PDF download/print, Share PDF, WhatsApp dispatch summary, Edit, and Delete.
class InvoiceDetailScreen extends StatefulWidget {
  const InvoiceDetailScreen({
    super.key,
    required this.invoiceId,
    this.viewModel,
    this.onOpenScanner,
    this.onEdit,
  });

  final String invoiceId;
  final InvoicesViewModel? viewModel;
  final Future<List<InvoiceLineItem>?> Function(BuildContext context)?
      onOpenScanner;
  final void Function(Invoice invoice)? onEdit;

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  InvoicesViewModel? _ownedVm;
  bool _pdfBusy = false;
  bool _showKraPin = true;

  InvoicesViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = InvoicesViewModel(vault: context.read<VaultRepository>());
    }
  }

  @override
  void dispose() {
    _ownedVm?.dispose();
    super.dispose();
  }

  void _showSnack(String message, {bool isError = false, bool isWarning = false}) {
    if (!mounted) return;
    final bg = isError
        ? AppTheme.danger
        : (isWarning ? AppTheme.warning : AppTheme.forestGreen);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _togglePaidStatus(Invoice inv) async {
    if (inv.isPaid) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Undo Paid Status'),
          content: Text(
            'Are you sure you want to mark Invoice ${inv.number} as UNPAID? This will return it to pending status.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Yes, Mark Unpaid'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      final res = await _vm.markAsUnpaid(inv.id);
      _showSnack(res.message, isWarning: !res.synced);
    } else {
      final res = await _vm.markAsPaid(inv.id);
      _showSnack(res.message, isWarning: !res.synced);
    }
  }

  PrintableDocument _buildPrintableDoc(
    Invoice inv,
    Restaurant? rest,
    VaultRepository vault,
  ) {
    return PrintableDocument(
      title: 'Invoice ${inv.number}',
      filename: InvoicePdfBuilder.pdfFilename(inv, rest),
      supportsThermalRoll: true,
      buildPdf: (format) => InvoicePdfBuilder.buildPdfBytes(
        invoice: inv,
        restaurant: rest,
        settings: vault.settings,
        pageFormat: format,
        showKraPin: _showKraPin,
      ),
      buildEscPos: (cols) => EscPosReceiptBuilder.buildInvoicesReceipt(
        invoices: [inv],
        restaurants: vault.restaurants,
        settings: _showKraPin
            ? vault.settings
            : vault.settings.withKraProfile(
                vault.settings.kraProfile.copyWith(sellerKraPin: ''),
              ),
        lineWidth: cols,
      ),
    );
  }

  Future<void> _handleGenerateDeliveryNote(
    Invoice inv,
    VaultRepository vault,
  ) async {
    final output = await DocumentOcrImportSheet.show(
      context,
      vault: vault,
      initialMode: DocSmartConversionMode.deliveryNote,
      preselectedInvoice: inv,
    );
    if (output == null || !mounted) return;
    await vault.saveBrandedDocument(output.document);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BrandedDocumentEditorScreen(
          initialDocument: output.document,
          vault: vault,
        ),
      ),
    );
  }

  Future<void> _handleViewPdf(Invoice inv, Restaurant? rest) async {
    final vault = context.read<VaultRepository>();
    final doc = _buildPrintableDoc(inv, rest, vault);
    await AppPrintHelper.openPreview(context, document: doc);
  }

  Future<void> _handlePrintPdf(Invoice inv, Restaurant? rest) async {
    final vault = context.read<VaultRepository>();
    await AppPrintHelper.openPrintCenter(
      context,
      document: _buildPrintableDoc(inv, rest, vault),
    );
  }

  Future<void> _handleSharePdf(Invoice inv, Restaurant? rest) async {
    final vault = context.read<VaultRepository>();
    setState(() => _pdfBusy = true);
    try {
      await InvoicePdfBuilder.sharePdfFile(
        invoice: inv,
        restaurant: rest,
        settings: vault.settings,
        showKraPin: _showKraPin,
      );
    } catch (e) {
      _showSnack('Failed to share PDF: $e', isError: true);
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  Future<void> _handleShareWhatsApp(Invoice inv, Restaurant? rest) async {
    final vault = context.read<VaultRepository>();
    setState(() => _pdfBusy = true);
    try {
      await InvoicePdfBuilder.shareViaWhatsApp(
        invoice: inv,
        restaurant: rest,
        settings: vault.settings,
        showKraPin: _showKraPin,
      );
    } catch (e) {
      _showSnack('Could not open WhatsApp: $e', isError: true);
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  Future<bool> _confirmFiscalizedAction(
    Invoice inv,
    VaultRepository vault,
    String verb,
  ) async {
    if (!inv.isFiscalized) return true;
    final hasLiveOscu = (inv.etimsInvcNo ?? 0) > 0;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('eTIMS Invoice Locked'),
        content: Text(
          'Invoice ${inv.number} already has an official KRA eTIMS record (${inv.cuInvoiceNumber}). '
          'In KRA rules, issued invoices cannot be ${verb.toLowerCase()} directly — issue a Credit Note in KRA Tax Center instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('Close'),
          ),
          if (!hasLiveOscu)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('unlock'),
              child: Text('$verb Manual Entry'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('kra'),
            child: const Text('Open KRA Tax Center'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (choice == 'kra') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => KraTaxCenterScreen(vault: vault),
        ),
      );
      return false;
    }
    return choice == 'unlock';
  }

  Future<void> _handleIssueDailyEtims(Invoice inv, VaultRepository vault) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Invoice Before eTIMS'),
        content: Text(
          'Check that items, weights, and prices for ${inv.number} (${inv.restaurantName}) are final. '
          'Once eTIMS is issued, this invoice will be locked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Review First'),
          ),
          FilledButton(
            key: const Key('btn_confirm_issue_daily_etims'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue to eTIMS'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await KraTaxCenterScreen.showInvoiceEtimsSheet(
      context,
      vault: vault,
      invoice: inv,
      onFeedback: (msg, {isError = false}) => _showSnack(msg, isError: isError),
    );
  }

  Future<void> _handleEdit(Invoice inv, VaultRepository vault) async {
    if (!await _confirmFiscalizedAction(inv, vault, 'Edit')) return;
    if (!mounted) return;
    if (widget.onEdit != null) {
      widget.onEdit!(inv);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceEditorScreen(
          viewModel: _vm,
          initialInvoice: inv,
          onOpenScanner: widget.onOpenScanner,
        ),
      ),
    );
  }

  Future<void> _handleDelete(Invoice inv, VaultRepository vault) async {
    if (!await _confirmFiscalizedAction(inv, vault, 'Delete')) return;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Invoice'),
        content: Text(
          'Invoice ${inv.number} will be moved to the Recycle Bin. You can restore it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final res = await _vm.softDeleteInvoice(inv.id);
    if (!mounted) return;
    _showSnack(res.message, isWarning: !res.synced);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vault = context.watch<VaultRepository>();

    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final inv = _vm.findInvoiceById(widget.invoiceId);
        if (inv == null) {
          return Scaffold(
            backgroundColor: AppTheme.surfaceSage,
            appBar: AppBar(title: const Text('Invoice')),
            body: const Center(
              child: Text('Invoice was not found or has been deleted.'),
            ),
          );
        }

        final rest = _vm.resolveRestaurant(inv);
        final clientName = _vm.displayRestaurantName(inv);
        final kraPin = Restaurant.normalizeKraPin(rest?.kraPin);
        final signatureBytes =
            InvoicePdfBuilder.decodeSignatureDataUrl(vault.settings.signature);

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: Text('Invoice ${inv.number}'),
            actions: [
              IconButton(
                tooltip: 'Edit invoice',
                icon: Icon(
                  inv.isFiscalized ? Icons.lock_outline : Icons.edit_outlined,
                ),
                onPressed: () => _handleEdit(inv, vault),
              ),
              IconButton(
                tooltip: 'Delete invoice',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _handleDelete(inv, vault),
              ),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              color: AppTheme.surfaceCard,
              border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
            ),
            padding: EdgeInsets.fromLTRB(
              16,
              10,
              16,
              10 +
                  math.max(
                    MediaQuery.viewPaddingOf(context).bottom,
                    MediaQuery.paddingOf(context).bottom,
                  ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        inv.isPaid ? AppTheme.slateDark : AppTheme.forestGreen,
                  ),
                  onPressed: () => _togglePaidStatus(inv),
                  icon: Icon(
                    inv.isPaid
                        ? Icons.undo_outlined
                        : Icons.check_circle_outline,
                    size: 18,
                  ),
                  label: Text(inv.isPaid ? 'Mark as Unpaid' : 'Mark as Paid'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_view_invoice_pdf'),
                  onPressed: _pdfBusy ? null : () => _handleViewPdf(inv, rest),
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: const Text('PDF'),
                ),
                OutlinedButton.icon(
                  onPressed: _pdfBusy ? null : () => _handlePrintPdf(inv, rest),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print'),
                ),
                OutlinedButton.icon(
                  onPressed: _pdfBusy ? null : () => _handleSharePdf(inv, rest),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_invoice_generate_delivery_note'),
                  onPressed: _pdfBusy
                      ? null
                      : () => _handleGenerateDeliveryNote(inv, vault),
                  icon: const Icon(Icons.local_shipping_outlined, size: 18),
                  label: const Text('Delivery Note'),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.sageTint,
                    foregroundColor: AppTheme.forestGreenDeep,
                  ),
                  onPressed:
                      _pdfBusy ? null : () => _handleShareWhatsApp(inv, rest),
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: const Text('WhatsApp'),
                ),
              ],
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (inv.isFiscalized)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: AppTheme.sageTint,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.qr_code_2, color: AppTheme.forestGreen),
                    title: Text(
                      inv.hasCreditNote
                          ? 'eTIMS Reversed (Credit Note Issued)'
                          : 'eTIMS QR Issued',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.forestGreenDeep,
                      ),
                    ),
                    subtitle: Text(
                      'CU: ${inv.cuInvoiceNumber ?? ''}${inv.hasCreditNote ? ' · CN: ${inv.etimsCreditNoteCuNo}' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: TextButton(
                      onPressed: () => KraTaxCenterScreen.showInvoiceEtimsSheet(
                        context,
                        vault: vault,
                        invoice: inv,
                        onFeedback: (msg, {isError = false}) =>
                            _showSnack(msg, isError: isError),
                      ),
                      child: const Text('View'),
                    ),
                  ),
                )
              else if (!inv.isDraft && rest?.etimsCadence == EtimsCadence.daily)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: AppTheme.warningSurface,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.qr_code_scanner, color: AppTheme.warning),
                    title: const Text(
                      'Daily eTIMS QR Needed',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Confirm quantities & prices before issuing KRA eTIMS.',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: FilledButton(
                      key: const Key('btn_invoice_detail_issue_etims'),
                      onPressed: () => _handleIssueDailyEtims(inv, vault),
                      child: const Text('Issue eTIMS'),
                    ),
                  ),
                )
              else if (!inv.isDraft && rest?.etimsCadence == EtimsCadence.monthly)
                const Card(
                  margin: EdgeInsets.only(bottom: 12),
                  color: AppTheme.infoSurface,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.apartment_outlined, color: AppTheme.info),
                    title: Text(
                      'Monthly Statement eTIMS Client',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Combined at month-end under KRA & eTIMS Tax -> Monthly Hotel.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: AppTheme.leafGreen,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      child: Row(
                        children: [
                          Image.asset(
                            'assets/logo.png',
                            height: 44,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.eco_outlined,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: inv.isPaid
                                  ? AppTheme.forestGreenDeep
                                  : AppTheme.slateDark,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              inv.isPaid
                                  ? 'PAID & PROCESSED'
                                  : inv.status.toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'INVOICE',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.leafGreen,
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'Receipt No: ${inv.number}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.slateInk,
                                    ),
                                  ),
                                  Text(
                                    'Order Date: ${InvoiceFormatters.formatDisplayDate(inv.date)}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  FilterChip(
                                    key: const Key('chip_invoice_show_kra_pin'),
                                    label: const Text('Include KRA PIN'),
                                    selected: _showKraPin,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (v) =>
                                        setState(() => _showKraPin = v),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'FROM:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateMuted,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Town Treasure Limited',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.forestGreen,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      '0708567696',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      'thetowntreasure25@gmail.com',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      'towntreasuregroceries.com',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Text(
                                      'BILLED TO:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateMuted,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      clientName,
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateInk,
                                      ),
                                    ),
                                    if (_showKraPin && kraPin.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        'KRA PIN: $kraPin',
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.slateDark,
                                        ),
                                      ),
                                    ],
                                    if (rest != null &&
                                        rest.address.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        rest.address,
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                    if (rest != null &&
                                        rest.phone.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        rest.phone,
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Container(
                            color: AppTheme.slateDark,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: const Row(
                              children: [
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    '#',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    'ITEM',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    'QTY',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    'TOTAL',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ...List.generate(inv.items.length, (i) {
                            final it = inv.items[i];
                            final lineTotal = it.total > 0
                                ? it.total
                                : (it.qty * it.sellPrice);
                            return Container(
                              color: i.isOdd
                                  ? AppTheme.surfaceSage
                                  : AppTheme.surfaceCard,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 28,
                                    child: Text(
                                      (i + 1).toString().padLeft(2, '0'),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          it.desc,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          'KSh ${InvoiceFormatters.formatMoney(it.sellPrice)} / ${it.unit}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.slateMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      '${it.qty} ${it.unit}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      'KSh ${InvoiceFormatters.formatMoney(lineTotal)}',
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.leafGreen,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                const Flexible(
                                  child: Text(
                                    'Grand Total:',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'KSh ${InvoiceFormatters.formatMoney(inv.totalSell)}',
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: 210,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: AppTheme.slateDark,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                children: [
                                  Image.asset(
                                    'assets/stamp.png',
                                    height: 52,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => const Text(
                                      'TOWN TREASURE GROCERIES',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    inv.isPaid
                                        ? 'PAID & PROCESSED'
                                        : 'AUTHORIZED',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.9,
                                    ),
                                  ),
                                  Text(
                                    'DATE: ${InvoiceFormatters.formatDisplayDate(InvoiceFormatters.todayIso())}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                      color: AppTheme.danger,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (signatureBytes != null) ...[
                                    Image.memory(
                                      signatureBytes,
                                      height: 46,
                                      fit: BoxFit.contain,
                                    ),
                                    const SizedBox(height: 2),
                                  ] else
                                    const Padding(
                                      padding: EdgeInsets.symmetric(vertical: 8),
                                      child: Text(
                                        'No saved signature',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.slateMuted,
                                        ),
                                      ),
                                    ),
                                  Container(
                                    width: 150,
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
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Internal Cost & Profit Summary',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Buy: KES ${InvoiceFormatters.formatMoney(inv.totalBuy)}  |  Ops: KES ${InvoiceFormatters.formatMoney(inv.deliveryCost + inv.otherCost)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'KES ${InvoiceFormatters.formatMoney(inv.profit)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: inv.profit >= 0
                              ? AppTheme.forestGreen
                              : AppTheme.danger,
                        ),
                      ),
                    ],
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
