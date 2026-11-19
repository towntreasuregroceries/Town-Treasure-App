import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../data/services/ocr_consensus_service.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import '../scanner/docket_scanner_sheet.dart';
import 'clerk_view_model.dart';

class _EditableReviewRow {
  _EditableReviewRow({
    required this.descController,
    required this.qtyController,
    required this.buyController,
    required this.sellController,
    required this.unit,
  });

  final TextEditingController descController;
  final TextEditingController qtyController;
  final TextEditingController buyController;
  final TextEditingController sellController;
  String unit;

  void dispose() {
    descController.dispose();
    qtyController.dispose();
    buyController.dispose();
    sellController.dispose();
  }
}

/// Side-by-side / scrollable Owner Review & Approval sheet with pinch-to-zoom
/// docket viewer, inline editable line items & wholesale buy costs, Ledger
/// Integrity Guard alert, supplementary dispatch override, reject, and delete.
class ClerkReviewSheet extends StatefulWidget {
  const ClerkReviewSheet({
    super.key,
    required this.viewModel,
    required this.docket,
    this.onApproved,
    this.onInspectInvoice,
  });

  final ClerkViewModel viewModel;
  final StagingDocket docket;
  final void Function(Invoice invoice)? onApproved;
  final void Function(String invoiceId)? onInspectInvoice;

  static Future<bool?> show(
    BuildContext context, {
    required ClerkViewModel viewModel,
    required StagingDocket docket,
    void Function(Invoice invoice)? onApproved,
    void Function(String invoiceId)? onInspectInvoice,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceSage,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.95,
        child: ClerkReviewSheet(
          viewModel: viewModel,
          docket: docket,
          onApproved: onApproved,
          onInspectInvoice: onInspectInvoice,
        ),
      ),
    );
  }

  @override
  State<ClerkReviewSheet> createState() => _ClerkReviewSheetState();
}

class _ClerkReviewSheetState extends State<ClerkReviewSheet> {
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');

  late TextEditingController _restaurantController;
  late TextEditingController _dateController;
  late TextEditingController _deliveryController;
  late TextEditingController _otherController;
  final List<_EditableReviewRow> _rows = [];
  int _activePhotoIndex = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.docket;
    _restaurantController = TextEditingController(text: d.restaurantName);
    final normDate = AppHelpers.normalizeAppDate(d.invoiceDate);
    _dateController = TextEditingController(
      text: normDate.isNotEmpty
          ? normDate
          : AppHelpers.normalizeAppDate(DateTime.now()),
    );
    _deliveryController = TextEditingController(
      text: d.deliveryCost > 0 ? _fmtNum(d.deliveryCost) : '0',
    );
    _otherController = TextEditingController(
      text: d.otherCost > 0 ? _fmtNum(d.otherCost) : '0',
    );

    if (d.itemsJson.isEmpty) {
      _addRow();
    } else {
      for (final it in d.itemsJson) {
        _addRow(
          desc: it.desc,
          qty: it.qty,
          unit: OcrConsensusService.normalizeDropdownUnit(it.unit),
          buy: it.buyPrice,
          sell: it.sellPrice,
        );
      }
    }

    widget.viewModel.addListener(_onVmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.viewModel.openReview(widget.docket);
      }
    });
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onVmChanged);
    _restaurantController.dispose();
    _dateController.dispose();
    _deliveryController.dispose();
    _otherController.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _addRow({
    String desc = '',
    double qty = 1,
    String unit = 'kgs',
    double buy = 0,
    double sell = 0,
  }) {
    final normalizedUnit = OcrConsensusService.normalizeDropdownUnit(unit);
    final row = _EditableReviewRow(
      descController: TextEditingController(text: desc),
      qtyController: TextEditingController(text: _fmtNum(qty)),
      buyController: TextEditingController(text: buy > 0 ? _fmtNum(buy) : '0'),
      sellController:
          TextEditingController(text: sell > 0 ? _fmtNum(sell) : '0'),
      unit: normalizedUnit,
    );
    setState(() => _rows.add(row));
  }

  void _removeRow(int index) {
    if (_rows.length <= 1) return;
    final removed = _rows.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  List<InvoiceLineItem> _collectItems() {
    return _rows.map((row) {
      final qty = double.tryParse(row.qtyController.text.trim()) ?? 0;
      final buy = double.tryParse(row.buyController.text.trim()) ?? 0;
      final sell = double.tryParse(row.sellController.text.trim()) ?? 0;
      return InvoiceLineItem(
        desc: row.descController.text.trim(),
        qty: qty,
        unit: row.unit,
        buyPrice: buy,
        sellPrice: sell,
        total: qty * sell,
      );
    }).toList();
  }

  ({double totalSell, double totalCost, double profit}) _calcTotals() {
    final items = _collectItems();
    final sell = items.fold<double>(0, (s, i) => s + i.total);
    final buy = items.fold<double>(0, (s, i) => s + (i.qty * i.buyPrice));
    final del = double.tryParse(_deliveryController.text.trim()) ?? 0;
    final oth = double.tryParse(_otherController.text.trim()) ?? 0;
    final totalCost = buy + del + oth;
    return (totalSell: sell, totalCost: totalCost, profit: sell - totalCost);
  }

  Future<void> _pickDate() async {
    final initial =
        AppHelpers.parseAppDate(_dateController.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) {
      setState(() {
        _dateController.text = AppHelpers.normalizeAppDate(picked);
      });
    }
  }

  Future<void> _handleApprove() async {
    final items = _collectItems();
    final del = double.tryParse(_deliveryController.text.trim()) ?? 0;
    final oth = double.tryParse(_otherController.text.trim()) ?? 0;
    final outcome = await widget.viewModel.approveActiveReview(
      restaurantName: _restaurantController.text,
      invoiceDate: _dateController.text,
      items: items,
      deliveryCost: del,
      otherCost: oth,
    );
    if (!mounted) return;
    await _handleApprovalOutcome(outcome, items, del, oth);
  }

  Future<void> _handleApprovalOutcome(
    ApprovalOutcome outcome,
    List<InvoiceLineItem> items,
    double del,
    double oth,
  ) async {
    switch (outcome) {
      case ApprovalSuccess(:final invoice):
        widget.onApproved?.call(invoice);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Invoice ${invoice.number} approved, encrypted, and saved to vault.',
            ),
            backgroundColor: AppTheme.forestGreen,
          ),
        );
        Navigator.of(context).pop(true);
      case ApprovalBlocked(:final message):
        _showError(message);
      case ApprovalNeedsAliasMatch(
          :final candidate,
          :final score,
          :final rawName,
          :final isSuggested,
        ):
        final detail = [
          candidate.address,
          candidate.phone,
          candidate.contact,
        ].where((s) => s.isNotEmpty).join(', ');
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirm Restaurant Match'),
            content: Text(
              'The docket says "$rawName". It ${isSuggested ? 'looks similar' : 'may refer'} to '
              '"${candidate.name}"${detail.isNotEmpty ? ' ($detail)' : ''} '
              '(${(score * 100).round()}% name similarity). Save this spelling as an alias and approve?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Link & Continue'),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted) {
          _restaurantController.text = candidate.name;
          final next = await widget.viewModel.registerAliasAndApprove(
            targetRestaurant: candidate,
            aliasName: rawName,
            invoiceDate: _dateController.text,
            items: items,
            deliveryCost: del,
            otherCost: oth,
          );
          if (mounted) await _handleApprovalOutcome(next, items, del, oth);
        }
      case ApprovalNeedsCreateRestaurant(
          :final rawName,
          :final similarCandidates,
        ):
        final similarText = similarCandidates.isNotEmpty
            ? '\n\nSimilar registered names: ${similarCandidates.map((r) => r.name).join(', ')}.'
            : '';
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restaurant Not Registered'),
            content: Text(
              'No exact restaurant or alias matches "$rawName".$similarText\n\nCreate a separate restaurant record and approve?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Create Separate Restaurant'),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted) {
          final next = await widget.viewModel.createRestaurantAndApprove(
            restaurantName: rawName,
            invoiceDate: _dateController.text,
            items: items,
            deliveryCost: del,
            otherCost: oth,
          );
          if (mounted) await _handleApprovalOutcome(next, items, del, oth);
        }
    }
  }

  Future<void> _handleReject() async {
    final reasonController = TextEditingController(
      text: 'Please verify quantities and prices on the receipt',
    );
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Return Docket for Correction'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Feedback for clerk',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
            onPressed: () => Navigator.of(ctx).pop(reasonController.text.trim()),
            child: const Text('Return to Clerk'),
          ),
        ],
      ),
    );
    reasonController.dispose();
    if (reason == null || !mounted) return;
    try {
      await widget.viewModel.rejectReview(widget.docket.id, reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Docket returned to clerk for correction.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _showError('Error returning docket: $e');
    }
  }

  Future<void> _handleDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Docket'),
        content: const Text(
          'Are you sure you want to delete this docket? It will be permanently removed from the review queue.',
        ),
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
    if (ok != true || !mounted) return;
    try {
      await widget.viewModel.deleteSubmission(widget.docket.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _showError('Delete failed: $e');
    }
  }

  Future<void> _exportDocketCode(StagingDocket docket) async {
    final code = widget.viewModel.exportDocketCode(docket);
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Portable docket code copied to clipboard.'),
        backgroundColor: AppTheme.forestGreen,
      ),
    );
  }

  void _openFullScreenPhoto(List<String> photos, int initialIndex) {
    if (photos.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('Docket Page ${initialIndex + 1} of ${photos.length}'),
          ),
          body: InteractiveViewer(
            minScale: 0.6,
            maxScale: 6.0,
            child: Center(
              child: DocketReceiptImage(dataUrl: photos[initialIndex]),
            ),
          ),
        ),
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppTheme.danger),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final docket = vm.activeReviewDocket ?? widget.docket;
    final photos = docket.receiptPhotos.isNotEmpty
        ? docket.receiptPhotos
        : (docket.receiptPhoto != null && docket.receiptPhoto!.isNotEmpty
            ? [docket.receiptPhoto!]
            : <String>[]);
    if (_activePhotoIndex >= photos.length) _activePhotoIndex = 0;

    final totals = _calcTotals();
    final isPending = docket.isPending;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
          decoration: const BoxDecoration(
            color: AppTheme.surfaceCard,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(bottom: BorderSide(color: AppTheme.borderSubtle)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.sageTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.fact_check_outlined,
                  color: AppTheme.forestGreen,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Review & Approve Clerk Docket',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    Text(
                      'Submitted by ${docket.clerkName} (${_fmtCreatedAt(docket.createdAt)})',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy Docket Code',
                onPressed: () => _exportDocketCode(docket),
                icon: const Icon(Icons.qr_code_2_outlined),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),

        // Scrollable Body
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 1. Ledger Integrity Alert Banner
              AnimatedSwitcher(
                duration: AppMotion.standard,
                child: _buildIntegrityBanner(vm, docket),
              ),
              const SizedBox(height: 14),

              // 2. Pinch-to-Zoom Receipt Photo Viewer
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.photo_camera_back_outlined,
                            size: 18,
                            color: AppTheme.forestGreen,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Physical Docket Photo (Pinch to Zoom)',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                          ),
                          const Spacer(),
                          if (photos.isNotEmpty)
                            IconButton(
                              tooltip: 'Fullscreen zoom',
                              onPressed: () => _openFullScreenPhoto(
                                photos,
                                _activePhotoIndex,
                              ),
                              icon: const Icon(Icons.fullscreen, size: 20),
                            ),
                        ],
                      ),
                      if (photos.length > 1) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          children: List.generate(photos.length, (i) {
                            final selected = i == _activePhotoIndex;
                            return ChoiceChip(
                              label: Text('Page ${i + 1}'),
                              selected: selected,
                              onSelected: (_) =>
                                  setState(() => _activePhotoIndex = i),
                            );
                          }),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (photos.isNotEmpty)
                        Container(
                          height: 260,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSage,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderSubtle),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InteractiveViewer(
                            minScale: 0.8,
                            maxScale: 5.0,
                            child: Center(
                              child: DocketReceiptImage(
                                dataUrl: photos[_activePhotoIndex],
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.all(24),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSage,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Column(
                            children: [
                              Icon(
                                Icons.image_not_supported_outlined,
                                size: 32,
                                color: AppTheme.slateMuted,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'No physical receipt photo was attached to this docket.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceSage,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'CLERK NOTES / REMARKS',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.slateMuted,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              docket.notes.isNotEmpty
                                  ? docket.notes
                                  : 'No notes provided by clerk.',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.slateInk,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 3. Extracted Produce & Wholesale Pricing Form
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Extracted Produce & Wholesale Costs',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _restaurantController,
                        enabled: isPending,
                        decoration: const InputDecoration(
                          labelText: 'Restaurant / Client',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _dateController,
                        readOnly: true,
                        onTap: isPending ? _pickDate : null,
                        decoration: const InputDecoration(
                          labelText: 'Delivery / Invoice Date',
                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Line Items',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...List.generate(_rows.length, (i) {
                        final row = _rows[i];
                        final qty =
                            double.tryParse(row.qtyController.text.trim()) ?? 0;
                        final sell =
                            double.tryParse(row.sellController.text.trim()) ??
                                0;
                        final lineTotal = qty * sell;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceSage,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppTheme.borderSubtle),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: row.descController,
                                      enabled: isPending,
                                      decoration: const InputDecoration(
                                        labelText: 'Item Description',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  if (isPending && _rows.length > 1)
                                    IconButton(
                                      onPressed: () => _removeRow(i),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: AppTheme.danger,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: row.qtyController,
                                      enabled: isPending,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                      decoration: const InputDecoration(
                                        labelText: 'Qty',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: row.unit,
                                      isDense: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Unit',
                                        isDense: true,
                                      ),
                                      items: OcrConsensusService
                                          .docketDropdownUnits
                                          .map(
                                            (u) => DropdownMenuItem(
                                              value: u,
                                              child: Text(u),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: isPending
                                          ? (v) {
                                              if (v != null) {
                                                setState(() => row.unit = v);
                                              }
                                            }
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: row.buyController,
                                      enabled: isPending,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                      decoration: const InputDecoration(
                                        labelText: 'Buy (KES)',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: row.sellController,
                                      enabled: isPending,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                      decoration: const InputDecoration(
                                        labelText: 'Sell (KES)',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      const Text(
                                        'Total',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.slateMuted,
                                        ),
                                      ),
                                      Text(
                                        'KES ${_moneyFmt.format(lineTotal)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: AppTheme.forestGreenDeep,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }),
                      if (isPending)
                        OutlinedButton.icon(
                          onPressed: () => _addRow(),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add Line Item'),
                        ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _deliveryController,
                              enabled: isPending,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Delivery Fee (KES)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _otherController,
                              enabled: isPending,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Other Costs (KES)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // Owner-only Profit Summary Box
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.successSurface.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppTheme.leafGreen.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Column(
                          children: [
                            _summaryLine(
                              'Total Invoice Amount (Selling)',
                              'KES ${_moneyFmt.format(totals.totalSell)}',
                              AppTheme.forestGreenDeep,
                            ),
                            const SizedBox(height: 4),
                            _summaryLine(
                              'Total Cost (Buy + Ops)',
                              'KES ${_moneyFmt.format(totals.totalCost)}',
                              AppTheme.slateInk,
                            ),
                            const Divider(height: 16),
                            _summaryLine(
                              'Projected Profit',
                              'KES ${_moneyFmt.format(totals.profit)}',
                              totals.profit >= 0
                                  ? AppTheme.forestGreen
                                  : AppTheme.danger,
                              bold: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // Footer Actions
        Container(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
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
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              if (!docket.isApproved)
                OutlinedButton.icon(
                  onPressed: vm.isProcessingReview ? null : _handleDelete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    side: BorderSide(
                      color: AppTheme.danger.withValues(alpha: 0.5),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
              if (isPending) ...[
                OutlinedButton.icon(
                  onPressed: vm.isProcessingReview ? null : _handleReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.warning,
                    side: BorderSide(
                      color: AppTheme.warning.withValues(alpha: 0.6),
                    ),
                  ),
                  icon: const Icon(Icons.undo_outlined, size: 18),
                  label: const Text('Return to Clerk'),
                ),
                FilledButton.icon(
                  onPressed: vm.canApproveActiveReview ? _handleApprove : null,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: Text(
                    vm.isProcessingReview
                        ? 'Encrypting...'
                        : 'Approve & Encrypt',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildIntegrityBanner(ClerkViewModel vm, StagingDocket docket) {
    switch (vm.reviewAuditState) {
      case ReviewAuditState.idle:
      case ReviewAuditState.checking:
        return Container(
          key: const ValueKey('audit_checking'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.infoSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.info.withValues(alpha: 0.4)),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.info,
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Checking docket against encrypted ledger for duplicates...',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateInk,
                  ),
                ),
              ),
            ],
          ),
        );
      case ReviewAuditState.clear:
        final msg = vm.reviewAuditRecordCount == 0
            ? (vm.reviewRestaurantVerified
                ? 'No saved invoices or pending dockets are linked to this restaurant yet.'
                : 'No exact same-name records were available to compare. Confirm or register this restaurant before relying on the duplicate check.')
            : 'Town Treasure Smart Audit: No duplicate found among ${vm.reviewAuditRecordCount} same-customer record(s) checked.';
        return Container(
          key: const ValueKey('audit_clear'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.successSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.leafGreen),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  color: AppTheme.forestGreen),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
              ),
            ],
          ),
        );
      case ReviewAuditState.duplicate:
        final audit = vm.reviewAuditResult;
        final matched = audit?.matchedRecord;
        final matchedNum = (matched?.number.isNotEmpty ?? false)
            ? matched!.number
            : 'Existing Invoice';
        final matchedAmt = _moneyFmt.format(matched?.totalSell ?? 0);
        return Container(
          key: const ValueKey('audit_duplicate'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.dangerSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.danger, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'LEDGER COLLISION DETECTED: DUPLICATE ORDER RISK',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: AppTheme.danger,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                audit?.explanation ?? 'Matching order found in vault.',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.slateInk,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Matched: $matchedNum | Date: ${matched?.date ?? ''} | KES $matchedAmt',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.danger,
                ),
              ),
              if (matched != null &&
                  matched.id.isNotEmpty &&
                  widget.onInspectInvoice != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => widget.onInspectInvoice!(matched.id),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text('Inspect $matchedNum'),
                ),
              ],
              if (docket.isPending) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: vm.supplementaryConfirmed,
                  onChanged: (v) => vm.setSupplementaryConfirmed(v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.danger,
                  title: const Text(
                    'Override Duplicate Lock: Confirm Intentional 2nd Dispatch',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.danger,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      case ReviewAuditState.error:
        return Container(
          key: const ValueKey('audit_error'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warningSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.warning),
          ),
          child: Row(
            children: [
              const Icon(Icons.sync_problem_outlined, color: AppTheme.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  vm.reviewAuditError ??
                      'Could not verify the current server ledger. Retry before approving.',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateInk,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => vm.openReview(docket),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
    }
  }

  Widget _summaryLine(
    String label,
    String value,
    Color valueColor, {
    bool bold = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: bold ? 14 : 13,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: AppTheme.slateInk,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: bold ? 16 : 13,
            fontWeight: FontWeight.w700,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static String _fmtCreatedAt(String? iso) {
    if (iso == null || iso.isEmpty) return 'recently';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return DateFormat('dd MMM yyyy, HH:mm').format(dt);
  }
}
