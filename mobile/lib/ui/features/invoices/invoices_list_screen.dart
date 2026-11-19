import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/print_service.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/print_options_sheet.dart';
import 'invoice_detail_screen.dart';
import 'invoice_editor_screen.dart';
import 'invoice_formatters.dart';
import 'invoice_pdf_builder.dart';
import 'invoices_view_model.dart';
import 'recycle_bin_screen.dart';

/// Mobile-first Material 3 Invoices list with search, status/restaurant filters,
/// saved drafts panel, soft-delete, and navigation to editor/detail/recycle bin.
class InvoicesListScreen extends StatefulWidget {
  const InvoicesListScreen({
    super.key,
    this.viewModel,
    this.onOpenRecycleBin,
    this.onOpenScanner,
    this.onCreateInvoice,
    this.onViewInvoice,
  });

  final InvoicesViewModel? viewModel;
  final VoidCallback? onOpenRecycleBin;
  final Future<List<InvoiceLineItem>?> Function(BuildContext context)?
      onOpenScanner;
  final VoidCallback? onCreateInvoice;
  final void Function(Invoice invoice)? onViewInvoice;

  @override
  State<InvoicesListScreen> createState() => _InvoicesListScreenState();
}

class _InvoicesListScreenState extends State<InvoicesListScreen> {
  InvoicesViewModel? _ownedVm;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _draftsExpanded = true;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};
  bool _isBatchMarkingPaid = false;

  InvoicesViewModel get _vm => widget.viewModel ?? _ownedVm!;

  void _enterSelectionMode([String? initialId]) {
    setState(() {
      _selectionMode = true;
      if (initialId != null && initialId.isNotEmpty) {
        _selectedIds.add(initialId);
      }
    });
  }

  void _exitSelectionMode() {
    if (!_selectionMode && _selectedIds.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(Invoice inv) {
    if (inv.status == 'paid' || _isBatchMarkingPaid) return;
    setState(() {
      if (_selectedIds.contains(inv.id)) {
        _selectedIds.remove(inv.id);
      } else {
        _selectedIds.add(inv.id);
      }
    });
  }

  void _openBatchPrintSheet(List<Invoice> selectedInvoices) {
    if (selectedInvoices.isEmpty) return;
    final vault = context.read<VaultRepository>();
    showPrintOptionsSheet(
      context,
      document: PrintableDocument(
        title: selectedInvoices.length == 1
            ? 'Invoice ${selectedInvoices.first.number}'
            : '${selectedInvoices.length} Selected Invoices',
        filename: selectedInvoices.length == 1
            ? InvoicePdfBuilder.pdfFilename(
                selectedInvoices.first,
                _vm.resolveRestaurant(selectedInvoices.first),
              )
            : 'Invoices_Batch_${InvoiceFormatters.todayIso()}.pdf',
        supportsThermalRoll: true,
        buildPdf: (format) => InvoicePdfBuilder.buildMultiInvoicePdfBytes(
          invoices: selectedInvoices,
          restaurants: vault.restaurants,
          settings: vault.settings,
          pageFormat: format,
        ),
        buildEscPos: (cols) => EscPosReceiptBuilder.buildInvoicesReceipt(
          invoices: selectedInvoices,
          restaurants: vault.restaurants,
          lineWidth: cols,
        ),
      ),
    );
  }

  Future<void> _confirmBatchMarkPaid(List<Invoice> selectedUnpaid) async {
    if (selectedUnpaid.isEmpty || _isBatchMarkingPaid) return;
    final totalAmount = selectedUnpaid.fold<double>(
      0.0,
      (sum, inv) => sum + inv.totalSell,
    );
    final count = selectedUnpaid.length;
    final noun = count == 1 ? 'invoice' : 'invoices';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark Invoices Paid'),
        content: Text(
          'Mark $count selected $noun totaling KES ${InvoiceFormatters.formatMoney(totalAmount)} as paid today?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, Mark Paid'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _isBatchMarkingPaid = true);
    try {
      final res = await _vm.markInvoicesAsPaid(
        selectedUnpaid.map((i) => i.id).toList(),
      );
      if (!mounted) return;
      if (res.ok) {
        _exitSelectionMode();
      }
      _showSnack(res.message, isError: !res.ok, isWarning: res.ok && !res.synced);
    } finally {
      if (mounted) {
        setState(() => _isBatchMarkingPaid = false);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = InvoicesViewModel(vault: context.read<VaultRepository>());
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  Future<void> _openEditor({Invoice? initialInvoice}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceEditorScreen(
          viewModel: _vm,
          initialInvoice: initialInvoice,
          onOpenScanner: widget.onOpenScanner,
          onSaved: (saved) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => InvoiceDetailScreen(
                  invoiceId: saved.id,
                  viewModel: _vm,
                  onOpenScanner: widget.onOpenScanner,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDetail(Invoice invoice) async {
    if (widget.onViewInvoice != null) {
      widget.onViewInvoice!(invoice);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceDetailScreen(
          invoiceId: invoice.id,
          viewModel: _vm,
          onOpenScanner: widget.onOpenScanner,
        ),
      ),
    );
  }

  Future<void> _openRecycleBin() async {
    if (widget.onOpenRecycleBin != null) {
      widget.onOpenRecycleBin!();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RecycleBinScreen(viewModel: _vm),
      ),
    );
  }

  Future<void> _confirmDeleteInvoice(Invoice inv) async {
    final ok = await showDialog<bool>(
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
    if (ok != true) return;
    final res = await _vm.softDeleteInvoice(inv.id);
    _showSnack(res.message, isWarning: !res.synced);
  }

  Future<void> _confirmDeleteDraft(Invoice draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Draft'),
        content: const Text('Are you sure you want to delete this draft?'),
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
    if (ok != true) return;
    final res = await _vm.deleteDraft(draft.id);
    _showSnack(res.message, isWarning: !res.synced);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final invoices = _vm.filteredInvoices;
        final drafts = _vm.drafts;
        final rests = _vm.restaurants;
        final months = _vm.availableMonths;
        final selectedMonth = months.contains(_vm.filterMonth)
            ? _vm.filterMonth
            : '';
        final visibleUnpaid =
            invoices.where((inv) => inv.status != 'paid').toList();
        final selectedVisibleUnpaid = visibleUnpaid
            .where((inv) => _selectedIds.contains(inv.id))
            .toList();
        final allUnpaidSelected = visibleUnpaid.isNotEmpty &&
            visibleUnpaid.every((inv) => _selectedIds.contains(inv.id));
        final selectedTotal = selectedVisibleUnpaid.fold<double>(
          0.0,
          (sum, inv) => sum + inv.totalSell,
        );

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            leading: _selectionMode
                ? IconButton(
                    tooltip: 'Cancel selection',
                    onPressed: _isBatchMarkingPaid ? null : _exitSelectionMode,
                    icon: const Icon(Icons.close),
                  )
                : null,
            title: Text(
              _selectionMode
                  ? '${selectedVisibleUnpaid.length} selected'
                  : 'Invoices',
            ),
            actions: [
              if (!_selectionMode)
                IconButton(
                  key: const Key('btn_select_multiple_invoices'),
                  tooltip: 'Select multiple to mark paid',
                  onPressed: invoices.isEmpty ? null : () => _enterSelectionMode(),
                  icon: const Icon(Icons.checklist_outlined),
                ),
              if (!_selectionMode)
                IconButton(
                  tooltip: 'Recycle Bin',
                  onPressed: _openRecycleBin,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
            ],
          ),
          floatingActionButton: _selectionMode
              ? null
              : FloatingActionButton.extended(
                  backgroundColor: AppTheme.forestGreen,
                  foregroundColor: Colors.white,
                  onPressed: widget.onCreateInvoice ?? () => _openEditor(),
                  icon: const Icon(Icons.add),
                  label: const Text('New Invoice'),
                ),
          bottomNavigationBar: _selectionMode
              ? Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  decoration: const BoxDecoration(
                    color: AppTheme.surfaceCard,
                    border: Border(
                      top: BorderSide(color: AppTheme.borderSubtle),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${selectedVisibleUnpaid.length} unpaid invoice(s) selected',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.slateInk,
                                ),
                              ),
                              Text(
                                'Total: KES ${InvoiceFormatters.formatMoney(selectedTotal)}',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.forestGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          key: const Key('btn_batch_print_invoices'),
                          onPressed: (selectedVisibleUnpaid.isEmpty ||
                                  _isBatchMarkingPaid)
                              ? null
                              : () => _openBatchPrintSheet(
                                    selectedVisibleUnpaid,
                                  ),
                          icon: const Icon(Icons.print_outlined, size: 18),
                          label: const Text('Print'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          key: const Key('btn_batch_mark_paid'),
                          onPressed: (selectedVisibleUnpaid.isEmpty ||
                                  _isBatchMarkingPaid)
                              ? null
                              : () => _confirmBatchMarkPaid(
                                    selectedVisibleUnpaid,
                                  ),
                          icon: _isBatchMarkingPaid
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.check_circle_outline, size: 18),
                          label: Text(
                            _isBatchMarkingPaid
                                ? 'Updating...'
                                : 'Mark Paid (${selectedVisibleUnpaid.length})',
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  children: [
                    TextField(
                      controller: _searchCtrl,
                      onChanged: _vm.setSearchQuery,
                      decoration: InputDecoration(
                        hintText: 'Search #, restaurant, or month (e.g. Nov 2026)',
                        prefixIcon: const Icon(
                          Icons.search,
                          color: AppTheme.slateMuted,
                        ),
                        suffixIcon: _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  _vm.setSearchQuery('');
                                },
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            initialValue: rests.any(
                              (r) => r.id == _vm.filterRestaurantId,
                            )
                                ? _vm.filterRestaurantId
                                : '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              prefixIcon: Icon(
                                Icons.storefront_outlined,
                                size: 18,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text(
                                  'All Restaurants',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ...rests.map(
                                (r) => DropdownMenuItem(
                                  value: r.id,
                                  child: Text(
                                    r.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (val) =>
                                _vm.setFilterRestaurantId(val ?? ''),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            key: const Key('dropdown_filter_month'),
                            initialValue: selectedMonth,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              prefixIcon: Icon(
                                Icons.calendar_month_outlined,
                                size: 18,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text(
                                  'All Months',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ...months.map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(
                                    InvoiceFormatters.formatMonthLabel(m),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (val) => _vm.setFilterMonth(val ?? ''),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _StatusChip(
                            label: 'All',
                            selected: _vm.filterStatus.isEmpty,
                            onSelected: () => _vm.setFilterStatus(''),
                          ),
                          const SizedBox(width: 8),
                          _StatusChip(
                            label: 'Pending',
                            selected: _vm.filterStatus == 'pending',
                            onSelected: () => _vm.setFilterStatus('pending'),
                          ),
                          const SizedBox(width: 8),
                          _StatusChip(
                            label: 'Paid',
                            selected: _vm.filterStatus == 'paid',
                            onSelected: () => _vm.setFilterStatus('paid'),
                          ),
                          const SizedBox(width: 8),
                          _StatusChip(
                            label: 'Overdue',
                            selected: _vm.filterStatus == 'overdue',
                            onSelected: () => _vm.setFilterStatus('overdue'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_selectionMode)
                Container(
                  key: const Key('bar_invoice_select_all'),
                  color: AppTheme.surfaceCard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        key: const Key('chk_select_all_unpaid'),
                        value: allUnpaidSelected,
                        onChanged: (visibleUnpaid.isEmpty || _isBatchMarkingPaid)
                            ? null
                            : (checked) {
                                setState(() {
                                  final unpaidIds = visibleUnpaid
                                      .map((e) => e.id)
                                      .toList();
                                  if (checked == true) {
                                    _selectedIds.addAll(unpaidIds);
                                  } else {
                                    _selectedIds.removeAll(unpaidIds);
                                  }
                                });
                              },
                      ),
                      Expanded(
                        child: Text(
                          visibleUnpaid.isEmpty
                              ? 'No unpaid invoices match current filter'
                              : (allUnpaidSelected
                                    ? 'All ${visibleUnpaid.length} unpaid selected'
                                    : 'Select all unpaid (${visibleUnpaid.length})'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.slateInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (drafts.isNotEmpty && !_selectionMode)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Card(
                    color: AppTheme.warningSurface.withValues(alpha: 0.65),
                    child: Column(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(
                            () => _draftsExpanded = !_draftsExpanded,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.edit_note_outlined,
                                  color: AppTheme.warning,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Saved Drafts (${drafts.length})',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.slateInk,
                                    ),
                                  ),
                                ),
                                Icon(
                                  _draftsExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  color: AppTheme.slateMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                        AnimatedCrossFade(
                          duration: AppMotion.fast,
                          crossFadeState: _draftsExpanded
                              ? CrossFadeState.showFirst
                              : CrossFadeState.showSecond,
                          firstChild: Column(
                            children: drafts.map((d) {
                              return ListTile(
                                dense: true,
                                title: Text(
                                  _vm.displayRestaurantName(d),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '${InvoiceFormatters.formatDisplayDate(d.createdAt ?? d.date)} - ${d.items.length} item(s)',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton(
                                      onPressed: () =>
                                          _openEditor(initialInvoice: d),
                                      child: const Text('Resume'),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete draft',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: AppTheme.danger,
                                        size: 20,
                                      ),
                                      onPressed: () => _confirmDeleteDraft(d),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                          secondChild: const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.standard,
                  switchInCurve: AppMotion.standardCurve,
                  child: invoices.isEmpty
                      ? Center(
                          key: const ValueKey('empty'),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.receipt_long_outlined,
                                  size: 52,
                                  color: AppTheme.slateMuted,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No invoices found',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.slateInk,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  'Create an invoice or adjust your filters.',
                                  style: TextStyle(color: AppTheme.slateMuted),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          key: ValueKey(invoices.length),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 92),
                          itemCount: invoices.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final inv = invoices[index];
                            final selectable = inv.status != 'paid';
                            return _InvoiceListCard(
                              invoice: inv,
                              clientName: _vm.displayRestaurantName(inv),
                              selectionMode: _selectionMode,
                              selected: selectable && _selectedIds.contains(inv.id),
                              onToggleSelect: () => _toggleSelected(inv),
                              onLongPress: selectable
                                  ? () => _enterSelectionMode(inv.id)
                                  : null,
                              onView: () => _openDetail(inv),
                              onEdit: () => _openEditor(initialInvoice: inv),
                              onDelete: () => _confirmDeleteInvoice(inv),
                            );
                          },
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: AppTheme.sageTint,
      labelStyle: TextStyle(
        color: selected ? AppTheme.forestGreenDeep : AppTheme.slateInk,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }
}

class _InvoiceListCard extends StatelessWidget {
  const _InvoiceListCard({
    required this.invoice,
    required this.clientName,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onLongPress,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
  });

  final Invoice invoice;
  final String clientName;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback? onLongPress;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isPaid = invoice.status == 'paid';
    final selectable = !isPaid;
    final isOverdue = invoice.status == 'overdue';
    final badgeBg = isPaid
        ? AppTheme.successSurface
        : (isOverdue ? AppTheme.dangerSurface : AppTheme.warningSurface);
    final badgeFg = isPaid
        ? AppTheme.forestGreen
        : (isOverdue ? AppTheme.danger : AppTheme.warning);

    return Opacity(
      opacity: (selectionMode && isPaid) ? 0.58 : 1.0,
      child: Card(
        color: selected ? AppTheme.sageTint.withValues(alpha: 0.4) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? const BorderSide(color: AppTheme.forestGreen, width: 1.8)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: selectionMode
              ? (selectable ? onToggleSelect : null)
              : onView,
          onLongPress: selectionMode ? null : onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (selectionMode) ...[
                      Checkbox(
                        value: selected,
                        onChanged: selectable ? (_) => onToggleSelect() : null,
                      ),
                      const SizedBox(width: 2),
                    ],
                    Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceSage,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.borderSubtle),
                    ),
                    child: Text(
                      invoice.number,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                        color: AppTheme.slateDark,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      clientName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      invoice.status.toUpperCase(),
                      style: TextStyle(
                        color: badgeFg,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${InvoiceFormatters.formatDisplayDate(invoice.date)} - ${invoice.items.length} item(s)',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'KES ${InvoiceFormatters.formatMoney(invoice.totalSell)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      Text(
                        'Profit: KES ${InvoiceFormatters.formatMoney(invoice.profit)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: invoice.profit >= 0
                              ? AppTheme.forestGreen
                              : AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (!selectionMode) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: onView,
                      icon: const Icon(Icons.visibility_outlined, size: 16),
                      label: const Text('View'),
                    ),
                    TextButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                    ),
                    IconButton(
                      tooltip: 'Delete invoice',
                      onPressed: onDelete,
                      icon: const Icon(
                        Icons.delete_outline,
                        color: AppTheme.danger,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}
