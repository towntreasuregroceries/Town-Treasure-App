import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/vault_key_recovery_dialog.dart';
import '../restaurants/restaurants_view_model.dart';
import 'invoice_formatters.dart';
import 'invoices_view_model.dart';

/// Mobile-first Invoice & Draft Editor with sticky live total/margin bar,
/// line-item CRUD, operational costs, scanner prefill callback, and CSV import/export.
class InvoiceEditorScreen extends StatefulWidget {
  const InvoiceEditorScreen({
    super.key,
    this.viewModel,
    this.initialInvoice,
    this.prefillItems,
    this.prefillRestaurantId,
    this.prefillDate,
    this.onOpenScanner,
    this.onSaved,
  });

  final InvoicesViewModel? viewModel;
  final Invoice? initialInvoice;
  final List<InvoiceLineItem>? prefillItems;
  final String? prefillRestaurantId;
  final String? prefillDate;
  final Future<List<InvoiceLineItem>?> Function(BuildContext context)?
      onOpenScanner;
  final void Function(Invoice savedInvoice)? onSaved;

  @override
  State<InvoiceEditorScreen> createState() => _InvoiceEditorScreenState();
}

class _InvoiceEditorScreenState extends State<InvoiceEditorScreen> {
  InvoicesViewModel? _ownedVm;
  RestaurantsViewModel? _restVm;
  bool _initialized = false;
  int _itemsRevision = 0;
  bool _compactItemView = true;
  bool _opsExpanded = false;

  late final TextEditingController _dateCtrl;
  late final TextEditingController _dueDateCtrl;
  late final TextEditingController _deliveryCtrl;
  late final TextEditingController _otherCtrl;
  late final TextEditingController _notesCtrl;

  InvoicesViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _dateCtrl = TextEditingController();
    _dueDateCtrl = TextEditingController();
    _deliveryCtrl = TextEditingController();
    _otherCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final vault = context.read<VaultRepository>();
      if (widget.viewModel == null) {
        _ownedVm = InvoicesViewModel(vault: vault);
      }
      _restVm = RestaurantsViewModel(vault: vault);

      if (widget.initialInvoice != null) {
        _vm.loadInvoiceForEdit(widget.initialInvoice!);
      } else {
        _vm.resetEditor(
          prefillRestaurantId: widget.prefillRestaurantId,
          prefillDate: widget.prefillDate,
          prefillItems: widget.prefillItems,
        );
      }
      _syncControllersFromVm();
    }
  }

  @override
  void didUpdateWidget(covariant InvoiceEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialInvoice != oldWidget.initialInvoice ||
        widget.prefillRestaurantId != oldWidget.prefillRestaurantId ||
        widget.prefillDate != oldWidget.prefillDate ||
        widget.prefillItems != oldWidget.prefillItems) {
      if (widget.initialInvoice != null) {
        _vm.loadInvoiceForEdit(widget.initialInvoice!);
      } else {
        _vm.resetEditor(
          prefillRestaurantId: widget.prefillRestaurantId,
          prefillDate: widget.prefillDate,
          prefillItems: widget.prefillItems,
        );
      }
      _syncControllersFromVm();
    }
  }

  void _syncControllersFromVm() {
    _dateCtrl.text = _vm.date;
    _dueDateCtrl.text = _vm.dueDate;
    _deliveryCtrl.text =
        _vm.deliveryCost > 0 ? _formatNumInput(_vm.deliveryCost) : '';
    _otherCtrl.text = _vm.otherCost > 0 ? _formatNumInput(_vm.otherCost) : '';
    _notesCtrl.text = _vm.notes;
    if (_vm.deliveryCost > 0 || _vm.otherCost > 0 || _vm.notes.trim().isNotEmpty) {
      _opsExpanded = true;
    }
    _itemsRevision++;
  }

  String _formatNumInput(double val) {
    if (val == val.roundToDouble()) return val.toInt().toString();
    return val.toString();
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _dueDateCtrl.dispose();
    _deliveryCtrl.dispose();
    _otherCtrl.dispose();
    _notesCtrl.dispose();
    _restVm?.dispose();
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

  Future<void> _pickDate({required bool isDueDate}) async {
    final initial = AppHelpers.parseAppDate(
          isDueDate ? _dueDateCtrl.text : _dateCtrl.text,
        ) ??
        DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    final iso = AppHelpers.normalizeAppDate(picked);
    if (isDueDate) {
      _dueDateCtrl.text = iso;
      _vm.setEditorDueDate(iso);
    } else {
      _dateCtrl.text = iso;
      _vm.setEditorDate(iso);
    }
  }

  Future<void> _handleScanDocket() async {
    if (widget.onOpenScanner == null) return;
    final scanned = await widget.onOpenScanner!(context);
    if (!mounted || scanned == null || scanned.isEmpty) return;
    _vm.applyImportedItems(scanned, replace: true);
    setState(() => _itemsRevision++);
    _showSnack('Applied ${scanned.length} scanned item(s) to invoice.');
  }

  Future<void> _openCsvImportModal() async {
    final csvCtrl = TextEditingController();
    var replaceExisting = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.upload_file_outlined,
                      color: AppTheme.forestGreen,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Import Items from CSV',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Columns: Item Description, Quantity, Unit, Unit Price, Total',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: csvCtrl,
                  maxLines: 6,
                  minLines: 4,
                  decoration: const InputDecoration(
                    hintText:
                        'Item Description,Quantity,Unit,Unit Price,Total\nTomatoes,10,kgs,120,1200',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Replace existing line items'),
                  value: replaceExisting,
                  onChanged: (v) => setModalState(() => replaceExisting = v),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    final count = _vm.importCsvText(
                      csvCtrl.text,
                      replace: replaceExisting,
                    );
                    if (count == 0) {
                      _showSnack(
                        'No valid line items found in CSV.',
                        isError: true,
                      );
                      return;
                    }
                    Navigator.of(ctx).pop();
                    setState(() => _itemsRevision++);
                    _showSnack('Imported $count line item(s) from CSV.');
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('Apply CSV Items'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    csvCtrl.dispose();
  }

  Future<void> _exportCsv() async {
    final csv = _vm.exportEditorItemsCsv();
    if (csv.trim().split('\n').length <= 1) {
      _showSnack('No line items to export.', isWarning: true);
      return;
    }
    try {
      await AppLockGuard.runWithoutRelock(
        () => Share.share(
          csv,
          subject: 'invoice_items_${_vm.date}.csv',
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      _showSnack('CSV copied to clipboard.');
    }
  }

  Future<void> _saveDraft() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final res = await _vm.saveDraft(silent: false);
    _showSnack(
      res.message,
      isError: !res.ok,
      isWarning: res.ok && !res.synced,
    );
  }

  Future<void> _saveInvoice({bool bypassDuplicateCheck = false}) async {
    if (_vm.isSaving) return;
    FocusManager.instance.primaryFocus?.unfocus();

    if (!bypassDuplicateCheck) {
      try {
        final vault = context.read<VaultRepository>();
        if (await vault.needsE2eKeyUnlock() && mounted) {
          await VaultKeyRecoveryDialog.show(context);
          if (!mounted) return;
        }
      } catch (_) {}
    }

    final res = await _vm.saveInvoice(
      bypassDuplicateCheck: bypassDuplicateCheck,
    );
    if (!mounted) return;

    switch (res.outcome) {
      case SaveInvoiceOutcome.validationError:
        _showSnack(res.message, isError: true);
      case SaveInvoiceOutcome.duplicateCheckUnavailable:
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Duplicate Check Unavailable'),
            content: Text(res.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Save on This Device'),
              ),
            ],
          ),
        );
        if (proceed == true) {
          await _saveInvoice(bypassDuplicateCheck: true);
        }
      case SaveInvoiceOutcome.duplicateDetected:
        final dup = res.matchedDuplicate!;
        final restName = _vm.displayRestaurantName(dup);
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Possible Duplicate Invoice'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(res.message),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.warningSurface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Existing: #${dup.number} ($restName)',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Date: ${dup.date} - ${dup.items.length} items - KES ${InvoiceFormatters.formatMoney(dup.totalSell)}',
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Produce Overlap: ${res.matchingItemsCount} matching line(s)',
                        style: const TextStyle(
                          color: AppTheme.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Review Invoice'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Save as 2nd Delivery Anyway'),
              ),
            ],
          ),
        );
        if (proceed == true) {
          await _saveInvoice(bypassDuplicateCheck: true);
        }
      case SaveInvoiceOutcome.saved:
        _showSnack(res.message, isWarning: !res.synced);
        if (widget.onSaved != null && res.invoice != null) {
          widget.onSaved!(res.invoice!);
        } else if (mounted) {
          Navigator.of(context).pop(res.invoice);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final rests = _vm.restaurants;
        final isEditing = _vm.editingInvoiceId != null;
        final selectedRestId = rests.any((r) => r.id == _vm.restaurantId)
            ? _vm.restaurantId
            : '';

        final liveDup = _vm.liveDuplicateMatch;

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: Text(isEditing ? 'Edit Invoice' : 'New Invoice'),
            actions: [
              TextFieldTapRegion(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: _vm.isSaving ? null : _saveDraft,
                  icon: const Icon(Icons.save_as_outlined, size: 18),
                  label: const Text('Save Draft'),
                ),
              ),
            ],
          ),
          bottomNavigationBar: TextFieldTapRegion(
            child: _StickyTotalsBar(
              totalSell: _vm.totalSell,
              totalCost: _vm.totalBuy + _vm.opsCost,
              profit: _vm.profit,
              marginPercent: _vm.marginPercent,
              isSaving: _vm.isSaving,
              onSave: () => _saveInvoice(),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              if (liveDup != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    key: const Key('live_duplicate_invoice_banner'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warningSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.warning.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: AppTheme.warning,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Same-day duplicate detected: #${liveDup.invoice.number}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: AppTheme.slateInk,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_vm.displayRestaurantName(liveDup.invoice)} · ${liveDup.invoice.date} · KES ${InvoiceFormatters.formatMoney(liveDup.invoice.totalSell)} (${liveDup.score.matchingItemsCount} matching item${liveDup.score.matchingItemsCount == 1 ? '' : 's'})',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedRestId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Restaurant / Client *',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Select restaurant...'),
                          ),
                          ...rests.map(
                            (r) => DropdownMenuItem(
                              value: r.id,
                              child: Text(
                                _restVm?.optionLabel(r) ?? r.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) =>
                            _vm.setEditorRestaurantId(val ?? ''),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _dateCtrl,
                              readOnly: true,
                              onTap: () => _pickDate(isDueDate: false),
                              decoration: const InputDecoration(
                                labelText: 'Invoice Date *',
                                prefixIcon: Icon(Icons.calendar_today_outlined),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _dueDateCtrl,
                              readOnly: true,
                              onTap: () => _pickDate(isDueDate: true),
                              decoration: InputDecoration(
                                labelText: 'Due Date (Opt)',
                                prefixIcon:
                                    const Icon(Icons.event_available_outlined),
                                suffixIcon: _dueDateCtrl.text.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear, size: 18),
                                        onPressed: () {
                                          _dueDateCtrl.clear();
                                          _vm.setEditorDueDate('');
                                        },
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Compact action strip + View density toggle (Compact fits 6-8 items/screen)
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _vm.addLineItem,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('Add Item'),
                        ),
                        if (widget.onOpenScanner != null)
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: _handleScanDocket,
                            icon: const Icon(
                              Icons.document_scanner_outlined,
                              size: 17,
                            ),
                            label: const Text('Scan Docket'),
                          ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _openCsvImportModal,
                          icon: const Icon(Icons.upload_file_outlined, size: 17),
                          label: const Text('Import CSV'),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _exportCsv,
                          icon: const Icon(Icons.download_outlined, size: 17),
                          label: const Text('Export CSV'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    'Line Items (${_vm.items.length})',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.slateInk,
                        ),
                  ),
                  const Spacer(),
                  SegmentedButton<bool>(
                    key: const Key('btn_toggle_item_density'),
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    segments: const [
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('Compact'),
                        icon: Icon(Icons.view_agenda_outlined, size: 15),
                      ),
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Cards'),
                        icon: Icon(Icons.view_stream_outlined, size: 15),
                      ),
                    ],
                    selected: {_compactItemView},
                    onSelectionChanged: (sel) {
                      if (sel.isNotEmpty) {
                        setState(() => _compactItemView = sel.first);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_compactItemView)
                Card(
                  key: const Key('compact_items_ledger'),
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.sageTint.withValues(alpha: 0.55),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(14),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(
                                'ITEM / QTY / UNIT',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.forestGreenDeep,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                'BUY / SELL / TOTAL',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.forestGreenDeep,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (var index = 0; index < _vm.items.length; index++) ...[
                        if (index > 0) const Divider(height: 1),
                        _CompactLineItemRow(
                          key: ValueKey('compact_item_${_itemsRevision}_$index'),
                          index: index,
                          item: _vm.items[index],
                          canRemove: _vm.items.length > 1,
                          onChanged: ({
                            String? desc,
                            double? qty,
                            String? unit,
                            double? buyPrice,
                            double? sellPrice,
                          }) {
                            _vm.updateLineItem(
                              index,
                              desc: desc,
                              qty: qty,
                              unit: unit,
                              buyPrice: buyPrice,
                              sellPrice: sellPrice,
                            );
                          },
                          onRemove: () {
                            _vm.removeLineItem(index);
                            setState(() => _itemsRevision++);
                          },
                        ),
                      ],
                      const Divider(height: 1),
                      InkWell(
                        key: const Key('btn_inline_add_item'),
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(14),
                        ),
                        onTap: _vm.addLineItem,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.add_circle_outline,
                                size: 17,
                                color: AppTheme.forestGreen,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'Add Another Line Item',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: AppTheme.forestGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...List.generate(_vm.items.length, (index) {
                  final item = _vm.items[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _LineItemEditorCard(
                      key: ValueKey('item_${_itemsRevision}_$index'),
                      index: index,
                      item: item,
                      canRemove: _vm.items.length > 1,
                      onChanged: ({
                        String? desc,
                        double? qty,
                        String? unit,
                        double? buyPrice,
                        double? sellPrice,
                      }) {
                        _vm.updateLineItem(
                          index,
                          desc: desc,
                          qty: qty,
                          unit: unit,
                          buyPrice: buyPrice,
                          sellPrice: sellPrice,
                        );
                      },
                      onRemove: () {
                        _vm.removeLineItem(index);
                        setState(() => _itemsRevision++);
                      },
                    ),
                  );
                }),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => setState(() => _opsExpanded = !_opsExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _opsExpanded
                                    ? 'Operational Costs & Notes'
                                    : 'Ops Costs & Notes (KES ${InvoiceFormatters.formatMoney(_vm.opsCost)})',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.slateInk,
                                    ),
                              ),
                            ),
                            Icon(
                              _opsExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              color: AppTheme.slateMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_opsExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _deliveryCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Delivery Cost (KES)',
                                      hintText: '0.00',
                                      isDense: true,
                                    ),
                                    onChanged: (v) => _vm.setEditorDeliveryCost(
                                      double.tryParse(v.trim()) ?? 0,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextFormField(
                                    controller: _otherCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Other Ops Cost (KES)',
                                      hintText: '0.00',
                                      isDense: true,
                                    ),
                                    onChanged: (v) => _vm.setEditorOtherCost(
                                      double.tryParse(v.trim()) ?? 0,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _notesCtrl,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                labelText: 'Notes / Dispatch Remarks',
                                hintText: 'Optional delivery notes...',
                                isDense: true,
                              ),
                              onChanged: _vm.setEditorNotes,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CompactLineItemRow extends StatefulWidget {
  const _CompactLineItemRow({
    super.key,
    required this.index,
    required this.item,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final InvoiceLineItem item;
  final bool canRemove;
  final void Function({
    String? desc,
    double? qty,
    String? unit,
    double? buyPrice,
    double? sellPrice,
  }) onChanged;
  final VoidCallback onRemove;

  @override
  State<_CompactLineItemRow> createState() => _CompactLineItemRowState();
}

class _CompactLineItemRowState extends State<_CompactLineItemRow> {
  late final TextEditingController _descCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _buyCtrl;
  late final TextEditingController _sellCtrl;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.item.desc);
    _qtyCtrl = TextEditingController(text: _fmtVal(widget.item.qty));
    _buyCtrl = TextEditingController(
      text: widget.item.buyPrice > 0 ? _fmtVal(widget.item.buyPrice) : '',
    );
    _sellCtrl = TextEditingController(
      text: widget.item.sellPrice > 0 ? _fmtVal(widget.item.sellPrice) : '',
    );
  }

  String _fmtVal(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _descCtrl.dispose();
    _qtyCtrl.dispose();
    _buyCtrl.dispose();
    _sellCtrl.dispose();
    super.dispose();
  }

  static const InputDecoration _compactCellDecoration = InputDecoration(
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 7, vertical: 6),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(7)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final unitOptions = <String>{
      ...InvoiceFormatters.supportedUnits,
      widget.item.unit,
    }.toList();
    final lineTotal = widget.item.qty * widget.item.sellPrice;
    final lineProfit = lineTotal - (widget.item.qty * widget.item.buyPrice);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppTheme.sageTint,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${widget.index + 1}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextFormField(
                  controller: _descCtrl,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Produce description *',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    border: UnderlineInputBorder(),
                  ),
                  onChanged: (v) => widget.onChanged(desc: v),
                ),
              ),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'KES ${InvoiceFormatters.formatMoney(lineTotal)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  Text(
                    '${lineProfit >= 0 ? '+' : ''}${InvoiceFormatters.formatMoney(lineProfit)}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: lineProfit >= 0
                          ? AppTheme.forestGreen
                          : AppTheme.danger,
                    ),
                  ),
                ],
              ),
              if (widget.canRemove)
                SizedBox(
                  width: 26,
                  height: 26,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: 'Remove item',
                    onPressed: widget.onRemove,
                    icon: const Icon(
                      Icons.close,
                      color: AppTheme.danger,
                      size: 16,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _qtyCtrl,
                  style: const TextStyle(fontSize: 12.5),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _compactCellDecoration.copyWith(
                    labelText: 'Qty',
                  ),
                  onChanged: (v) =>
                      widget.onChanged(qty: double.tryParse(v.trim()) ?? 0),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue: widget.item.unit,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.slateInk,
                  ),
                  decoration: _compactCellDecoration.copyWith(
                    labelText: 'Unit',
                  ),
                  items: unitOptions
                      .map(
                        (u) => DropdownMenuItem(
                          value: u,
                          child: Text(u, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => widget.onChanged(unit: v),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _buyCtrl,
                  style: const TextStyle(fontSize: 12.5),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _compactCellDecoration.copyWith(
                    labelText: 'Buy',
                    hintText: '0',
                  ),
                  onChanged: (v) => widget.onChanged(
                    buyPrice: double.tryParse(v.trim()) ?? 0,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _sellCtrl,
                  style: const TextStyle(fontSize: 12.5),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _compactCellDecoration.copyWith(
                    labelText: 'Sell',
                    hintText: '0',
                  ),
                  onChanged: (v) => widget.onChanged(
                    sellPrice: double.tryParse(v.trim()) ?? 0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LineItemEditorCard extends StatefulWidget {
  const _LineItemEditorCard({
    super.key,
    required this.index,
    required this.item,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final InvoiceLineItem item;
  final bool canRemove;
  final void Function({
    String? desc,
    double? qty,
    String? unit,
    double? buyPrice,
    double? sellPrice,
  }) onChanged;
  final VoidCallback onRemove;

  @override
  State<_LineItemEditorCard> createState() => _LineItemEditorCardState();
}

class _LineItemEditorCardState extends State<_LineItemEditorCard> {
  late final TextEditingController _descCtrl;
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _buyCtrl;
  late final TextEditingController _sellCtrl;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.item.desc);
    _qtyCtrl = TextEditingController(text: _fmtVal(widget.item.qty));
    _buyCtrl = TextEditingController(
      text: widget.item.buyPrice > 0 ? _fmtVal(widget.item.buyPrice) : '',
    );
    _sellCtrl = TextEditingController(
      text: widget.item.sellPrice > 0 ? _fmtVal(widget.item.sellPrice) : '',
    );
  }

  String _fmtVal(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _qtyCtrl.dispose();
    _buyCtrl.dispose();
    _sellCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unitOptions = <String>{
      ...InvoiceFormatters.supportedUnits,
      widget.item.unit,
    }.toList();
    final lineTotal = widget.item.qty * widget.item.sellPrice;
    final lineProfit =
        lineTotal - (widget.item.qty * widget.item.buyPrice);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: AppTheme.sageTint,
                  child: Text(
                    '${widget.index + 1}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.forestGreenDeep,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Line Total: KES ${InvoiceFormatters.formatMoney(lineTotal)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
                Text(
                  'Margin: KES ${InvoiceFormatters.formatMoney(lineProfit)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: lineProfit >= 0
                        ? AppTheme.forestGreen
                        : AppTheme.danger,
                  ),
                ),
                if (widget.canRemove)
                  IconButton(
                    tooltip: 'Remove item',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onRemove,
                    icon: const Icon(
                      Icons.close,
                      color: AppTheme.danger,
                      size: 18,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _descCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Item Description *',
                hintText: 'e.g. Tomatoes',
              ),
              onChanged: (v) => widget.onChanged(desc: v),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _qtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Qty *'),
                    onChanged: (v) =>
                        widget.onChanged(qty: double.tryParse(v.trim()) ?? 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    initialValue: widget.item.unit,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: unitOptions
                        .map(
                          (u) => DropdownMenuItem(
                            value: u,
                            child: Text(u),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => widget.onChanged(unit: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _buyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Buy Price',
                      hintText: '0.00',
                    ),
                    onChanged: (v) => widget.onChanged(
                      buyPrice: double.tryParse(v.trim()) ?? 0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _sellCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Sell Price *',
                      hintText: '0.00',
                    ),
                    onChanged: (v) => widget.onChanged(
                      sellPrice: double.tryParse(v.trim()) ?? 0,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StickyTotalsBar extends StatelessWidget {
  const _StickyTotalsBar({
    required this.totalSell,
    required this.totalCost,
    required this.profit,
    required this.marginPercent,
    required this.isSaving,
    required this.onSave,
  });

  final double totalSell;
  final double totalCost;
  final double profit;
  final double marginPercent;
  final bool isSaving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final profitColor = profit >= 0 ? AppTheme.forestGreen : AppTheme.danger;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surfaceCard,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 +
            math.max(
              MediaQuery.viewPaddingOf(context).bottom,
              MediaQuery.paddingOf(context).bottom,
            ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total: KES ${InvoiceFormatters.formatMoney(totalSell)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Cost: KES ${InvoiceFormatters.formatMoney(totalCost)}  |  Profit: KES ${InvoiceFormatters.formatMoney(profit)} (${marginPercent.toStringAsFixed(1)}%)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: profitColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('btn_save_invoice'),
                onPressed: isSaving ? null : onSave,
                icon: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline, size: 18),
                label: Text(isSaving ? 'Saving...' : 'Save Invoice'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
