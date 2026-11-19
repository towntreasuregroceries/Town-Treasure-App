import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import 'pricelist_editor_screen.dart';
import 'pricelist_preview_screen.dart';
import 'pricelists_view_model.dart';

/// Optional callback invoked when the user taps "Scan Price List".
/// Should open the optical scanner sheet and return extracted items, or null.
typedef PriceListScannerCallback =
    Future<List<PriceListItem>?> Function(BuildContext context);

/// Price Lists catalog screen matching `renderPriceLists()` in `pricelist.js`.
class PriceListsScreen extends StatefulWidget {
  const PriceListsScreen({
    super.key,
    this.viewModel,
    this.onOpenScanner,
  });

  final PriceListsViewModel? viewModel;
  final PriceListScannerCallback? onOpenScanner;

  @override
  State<PriceListsScreen> createState() => _PriceListsScreenState();
}

class _PriceListsScreenState extends State<PriceListsScreen> {
  PriceListsViewModel? _ownedVm;
  String _searchQuery = '';
  String _statusFilter = 'all';

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

  Future<void> _handleCreateNew() async {
    final result = await _vm.createOrResumeTodayDraft();
    if (!mounted) return;
    if (result.resumed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Resumed today\'s active draft price list'),
        ),
      );
    }
    await _openEditor(result.priceList);
  }

  Future<void> _handleScanNew() async {
    final scanner = widget.onOpenScanner;
    if (scanner == null) return;
    final items = await scanner(context);
    if (!mounted || items == null || items.isEmpty) return;

    var publishResult = await _vm.createFromScannedItems(items);
    if (!mounted) return;

    if (publishResult.collision != null) {
      final override = await _showCollisionDialog(publishResult.collision!);
      if (!override || !mounted) return;
      publishResult = await _vm.createFromScannedItems(
        items,
        bypassDuplicateCheck: true,
      );
    }

    if (!mounted) return;
    if (publishResult.saved != null) {
      final count =
          publishResult.saved!.items.where((i) => !i.isHeader).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Created new price list with $count items from optical scan',
          ),
        ),
      );
      await _openEditor(publishResult.saved!);
    } else if (publishResult.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(publishResult.errorMessage!)),
      );
    }
  }

  Future<bool> _showCollisionDialog(PriceListCollision collision) async {
    final matchPct = (collision.confidence * 100).round();
    final overlapPct = (collision.overlapRatio * 100).round();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Duplicate Price List Detected',
                style: TextStyle(
                  color: AppTheme.danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Smart Audit detected $matchPct% similarity with "${collision.matched.name}" '
          '(${collision.matchingKeys.length} matching commodities, $overlapPct% overlap).\n\n'
          'Do you want to create a separate price list anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Proceed Anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _openEditor(PriceList pl) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PriceListEditorScreen(
          priceListId: pl.id,
          viewModel: _vm,
          onOpenScanner: widget.onOpenScanner,
        ),
      ),
    );
  }

  Future<void> _openPreview(PriceList pl) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PriceListPreviewScreen(
          priceListId: pl.id,
          viewModel: _vm,
          onEdit: () {
            Navigator.of(context).pop();
            _openEditor(pl);
          },
        ),
      ),
    );
  }

  Future<void> _handleDuplicate(PriceList pl) async {
    final copy = await _vm.duplicatePriceList(pl.id);
    if (!mounted || copy == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Duplicated "${pl.name}"')),
    );
  }

  Future<void> _handleDelete(PriceList pl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Price List'),
        content: Text(
          '"${pl.name}" will be moved to the Recycle Bin.',
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
    if (confirmed != true || !mounted) return;
    final synced = await _vm.softDeletePriceList(pl.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          synced
              ? 'Price list moved to Recycle Bin and synced'
              : 'Price list moved to Recycle Bin locally',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final all = _vm.priceLists;
        final filtered = all.where((pl) {
          if (_statusFilter != 'all' && pl.status != _statusFilter) {
            return false;
          }
          if (_searchQuery.trim().isNotEmpty) {
            final q = _searchQuery.trim().toLowerCase();
            return pl.name.toLowerCase().contains(q) ||
                pl.subtitle.toLowerCase().contains(q);
          }
          return true;
        }).toList();

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Price Lists'),
            actions: [
              if (widget.onOpenScanner != null)
                IconButton(
                  tooltip: 'Scan Price List',
                  icon: const Icon(Icons.document_scanner_outlined),
                  onPressed: _handleScanNew,
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _handleCreateNew,
            backgroundColor: AppTheme.forestGreen,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add),
            label: const Text('New Price List'),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search price lists...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    setState(() => _searchQuery = ''),
                              )
                            : null,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final entry in const [
                          ('all', 'All'),
                          ('active', 'Active'),
                          ('draft', 'Draft'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(entry.$2),
                              selected: _statusFilter == entry.$1,
                              onSelected: (_) =>
                                  setState(() => _statusFilter = entry.$1),
                            ),
                          ),
                        const Spacer(),
                        if (widget.onOpenScanner != null)
                          OutlinedButton.icon(
                            onPressed: _handleScanNew,
                            icon: const Icon(
                              Icons.camera_alt_outlined,
                              size: 18,
                            ),
                            label: const Text('Scan'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.standard,
                  child: filtered.isEmpty
                      ? _EmptyPriceListsState(onCreate: _handleCreateNew)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final pl = filtered[index];
                            return _PriceListCard(
                              priceList: pl,
                              onView: () => _openPreview(pl),
                              onEdit: () => _openEditor(pl),
                              onDuplicate: () => _handleDuplicate(pl),
                              onDelete: () => _handleDelete(pl),
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

class _PriceListCard extends StatelessWidget {
  const _PriceListCard({
    required this.priceList,
    required this.onView,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  final PriceList priceList;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final itemCount = priceList.items.where((i) => !i.isHeader).length;
    final isActive = priceList.status == 'active';
    final statusColor = isActive ? AppTheme.forestGreen : AppTheme.warning;
    final statusBg =
        isActive ? AppTheme.successSurface : AppTheme.warningSurface;
    final isLinked =
        priceList.shareId != null && priceList.shareId!.isNotEmpty;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onView,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                      Icons.price_change_outlined,
                      color: AppTheme.forestGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          priceList.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          priceList.subtitle.isNotEmpty
                              ? priceList.subtitle
                              : 'Food Supplies (Veg and Fruits)',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (action) {
                      switch (action) {
                        case 'view':
                          onView();
                        case 'edit':
                          onEdit();
                        case 'duplicate':
                          onDuplicate();
                        case 'delete':
                          onDelete();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'view', child: Text('Preview')),
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
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
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _BadgePill(
                    label: priceList.status.toUpperCase(),
                    color: statusColor,
                    background: statusBg,
                  ),
                  _BadgePill(
                    label: isLinked ? 'Linked' : 'Private',
                    color: AppTheme.info,
                    background: AppTheme.infoSurface,
                  ),
                  Text(
                    '$itemCount items',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  Text(
                    'Updated ${PriceListsViewModel.formatDate(priceList.updatedAt)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onView,
                      icon: const Icon(Icons.visibility_outlined, size: 17),
                      label: const Text('View'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('Edit'),
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
}

class _BadgePill extends StatelessWidget {
  const _BadgePill({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _EmptyPriceListsState extends StatelessWidget {
  const _EmptyPriceListsState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.sageTint,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.receipt_long_outlined,
                size: 32,
                color: AppTheme.forestGreen,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'No price lists yet',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateInk,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Create your first price list to share with restaurants.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.slateMuted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('New Price List'),
            ),
          ],
        ),
      ),
    );
  }
}
