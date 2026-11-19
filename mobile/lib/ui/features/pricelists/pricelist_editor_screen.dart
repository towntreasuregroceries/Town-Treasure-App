import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import 'pricelist_preview_screen.dart';
import 'pricelists_screen.dart';
import 'pricelists_view_model.dart';

/// Price List Editor matching `editPriceList` & `publishPriceList` in `pricelist.js`.
class PriceListEditorScreen extends StatefulWidget {
  const PriceListEditorScreen({
    super.key,
    required this.priceListId,
    this.viewModel,
    this.onOpenScanner,
  });

  final String priceListId;
  final PriceListsViewModel? viewModel;
  final PriceListScannerCallback? onOpenScanner;

  @override
  State<PriceListEditorScreen> createState() => _PriceListEditorScreenState();
}

class _PriceListEditorScreenState extends State<PriceListEditorScreen> {
  PriceListsViewModel? _ownedVm;
  late TextEditingController _nameController;
  late TextEditingController _subtitleController;
  String _status = 'draft';
  List<PriceListItem> _items = [];
  bool _initialized = false;
  bool _saving = false;

  PriceListsViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _subtitleController = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = PriceListsViewModel(vault: context.read<VaultRepository>());
    }
    if (!_initialized) {
      _initialized = true;
      final pl = _vm.findById(widget.priceListId);
      if (pl != null) {
        _nameController.text = pl.name;
        _subtitleController.text = pl.subtitle;
        _status = pl.status;
        _items = pl.items.isEmpty
            ? [_blankItem()]
            : List<PriceListItem>.from(pl.items);
      } else {
        _items = [_blankItem()];
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _subtitleController.dispose();
    _ownedVm?.dispose();
    super.dispose();
  }

  PriceListItem _blankItem({
    String category = 'vegetables',
    String unit = 'kgs',
  }) {
    return PriceListItem(
      id: AppHelpers.genId(),
      name: '',
      category: category,
      unit: unit,
      price: 0,
      notes: '',
    );
  }

  PriceListItem _blankHeader() {
    return PriceListItem(
      id: AppHelpers.genId(),
      name: '',
      isHeader: true,
    );
  }

  PriceList _buildDraftModel() {
    final existing = _vm.findById(widget.priceListId);
    return PriceList(
      id: widget.priceListId,
      name: _nameController.text,
      subtitle: _subtitleController.text,
      status: _status,
      shareId: existing?.shareId,
      items: _items,
      createdAt: existing?.createdAt,
      updatedAt: existing?.updatedAt,
    );
  }

  void _triggerAutoSave() {
    _vm.scheduleAutoSave(_buildDraftModel());
  }

  void _insertItemAt(int index, {PriceListItem? reference}) {
    var category = 'vegetables';
    var unit = 'kgs';
    if (reference != null) {
      if (reference.isHeader) {
        category = PriceListsViewModel.guessCategory(reference.name);
      } else {
        category = reference.category;
        unit = reference.unit;
      }
    }
    setState(() {
      _items.insert(index, _blankItem(category: category, unit: unit));
    });
    _triggerAutoSave();
  }

  void _insertHeaderAt(int index) {
    setState(() {
      _items.insert(index, _blankHeader());
    });
    _triggerAutoSave();
  }

  void _removeAt(int index) {
    if (_items.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Must have at least one item')),
      );
      return;
    }
    setState(() {
      _items.removeAt(index);
    });
    _triggerAutoSave();
  }

  void _updateItem(int index, PriceListItem updated) {
    setState(() {
      _items[index] = updated;
    });
    _triggerAutoSave();
  }

  void _handleSmartImport() {
    final result = _vm.smartImportFromInvoices(_items);
    if (result.newItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message ?? 'No new items available to import.',
          ),
        ),
      );
      return;
    }

    setState(() {
      if (_items.length == 1 &&
          !_items.first.isHeader &&
          _items.first.name.trim().isEmpty) {
        _items = List<PriceListItem>.from(result.newItems);
      } else {
        _items.addAll(result.newItems);
      }
    });
    _triggerAutoSave();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message ?? 'Imported items')),
    );
  }

  Future<void> _handleScanAppend() async {
    final scanner = widget.onOpenScanner;
    if (scanner == null) return;
    final scanned = await scanner(context);
    if (!mounted || scanned == null || scanned.isEmpty) return;

    final hasMeaningful =
        _items.any((i) => !i.isHeader && i.name.trim().isNotEmpty);
    setState(() {
      final normalized = scanned
          .map((i) => i.id.isEmpty ? i.copyWith(id: AppHelpers.genId()) : i)
          .toList();
      if (!hasMeaningful) {
        _items = normalized;
      } else {
        _items.addAll(normalized);
      }
    });
    _triggerAutoSave();
    final dups = PriceListsViewModel.auditDuplicates(_items);
    final scannedCount = scanned.where((i) => !i.isHeader).length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          dups.isNotEmpty
              ? 'Appended $scannedCount items. ${dups.length} duplicate commodities flagged'
              : 'Appended $scannedCount items from optical scan',
        ),
      ),
    );
  }

  Future<void> _handleSave({bool bypassDuplicateCheck = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    final result = await _vm.publishPriceList(
      _buildDraftModel(),
      bypassDuplicateCheck: bypassDuplicateCheck,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (result.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.errorMessage!)),
      );
      return;
    }

    if (result.collision != null) {
      final proceed = await _showCollisionModal(result.collision!);
      if (proceed && mounted) {
        await _handleSave(bypassDuplicateCheck: true);
      }
      return;
    }

    if (result.internalDuplicates.isNotEmpty) {
      final proceed =
          await _showInternalDuplicatesModal(result.internalDuplicates);
      if (proceed && mounted) {
        await _handleSave(bypassDuplicateCheck: true);
      }
      return;
    }

    if (result.saved != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Price list saved')),
      );
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PriceListPreviewScreen(
            priceListId: result.saved!.id,
            viewModel: _vm,
          ),
        ),
      );
    }
  }

  Future<bool> _showCollisionModal(PriceListCollision collision) async {
    final matchPct = (collision.confidence * 100).round();
    final overlapPct = (collision.overlapRatio * 100).round();
    final validCount =
        _items.where((i) => !i.isHeader && i.name.trim().isNotEmpty).length;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.gpp_maybe_outlined, color: AppTheme.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Duplicate Price List Detected',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Smart Audit detected $matchPct% similarity with "${collision.matched.name}".',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.dangerSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Existing: ${collision.matched.name} (${collision.existingItemCount} lines)',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  Text(
                    'Active Draft: ${_nameController.text.trim()} ($validCount lines)',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  if (collision.matchingKeys.isNotEmpty)
                    Text(
                      'Overlap: ${collision.matchingKeys.length} commodities ($overlapPct%)',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.danger,
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
            child: const Text('Review'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Override & Save'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<bool> _showInternalDuplicatesModal(
    List<DuplicateCommodityGroup> dups,
  ) async {
    final names = dups.map((d) => '${d.name} (${d.count}x)').join(', ');
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Duplicate Produce Commodities',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
          ],
        ),
        content: Text(
          'The following items appear multiple times in this price list: $names.\n\n'
          'Consolidate prices or distinguish varieties before saving, or override to save anyway.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Review Rows'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save Anyway'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final duplicates = PriceListsViewModel.auditDuplicates(_items);
    final duplicateIds = duplicates.expand((d) => d.itemIds).toSet();
    final duplicateCountsById = <String, int>{};
    for (final d in duplicates) {
      for (final id in d.itemIds) {
        duplicateCountsById[id] = d.count;
      }
    }

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('Edit Price List'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : () => _handleSave(),
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_outlined, color: Colors.white),
            label: Text(
              _saving ? 'Saving...' : 'Save',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: 'Price List Name',
                          ),
                          onChanged: (_) => _triggerAutoSave(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _status == 'active' ? 'active' : 'draft',
                          items: const [
                            DropdownMenuItem(
                              value: 'draft',
                              child: Text('Draft'),
                            ),
                            DropdownMenuItem(
                              value: 'active',
                              child: Text('Active'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _status = v);
                            _triggerAutoSave();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _subtitleController,
                    decoration: const InputDecoration(
                      labelText: 'Document Subtitle',
                      hintText: 'Food Supplies (Veg and Fruits)',
                    ),
                    onChanged: (_) => _triggerAutoSave(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: AppMotion.fast,
            child: duplicates.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.dangerSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.danger, width: 1.5),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: AppTheme.danger,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Duplicate Produce Commodities Detected (${duplicates.length})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.danger,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Repeated items: ${duplicates.map((d) => '"${d.name}" (${d.count}x)').join(', ')}. '
                                'Consolidate prices or distinguish varieties.',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF7F1D1D),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _insertItemAt(
                  0,
                  reference: _items.isNotEmpty ? _items.first : null,
                ),
                icon: const Icon(Icons.vertical_align_top, size: 17),
                label: const Text('Add Top Item'),
              ),
              OutlinedButton.icon(
                onPressed: () => _insertHeaderAt(0),
                icon: const Icon(Icons.title, size: 17),
                label: const Text('Add Top Header'),
              ),
              OutlinedButton.icon(
                onPressed: _handleSmartImport,
                icon: const Icon(Icons.file_download_outlined, size: 17),
                label: const Text('Smart Import'),
              ),
              if (widget.onOpenScanner != null)
                OutlinedButton.icon(
                  onPressed: _handleScanAppend,
                  icon: const Icon(Icons.document_scanner_outlined, size: 17),
                  label: const Text('Scan & Append'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _items[i].isHeader
                  ? _CategoryHeaderEditorCard(
                      key: ValueKey(_items[i].id),
                      item: _items[i],
                      onChanged: (updated) => _updateItem(i, updated),
                      onInsertItemBelow: () =>
                          _insertItemAt(i + 1, reference: _items[i]),
                      onInsertHeaderBelow: () => _insertHeaderAt(i + 1),
                      onRemove: () => _removeAt(i),
                    )
                  : _ProduceRowEditorCard(
                      key: ValueKey(_items[i].id),
                      item: _items[i],
                      duplicateCount: duplicateIds.contains(_items[i].id)
                          ? duplicateCountsById[_items[i].id]
                          : null,
                      onChanged: (updated) => _updateItem(i, updated),
                      onInsertItemBelow: () =>
                          _insertItemAt(i + 1, reference: _items[i]),
                      onInsertHeaderBelow: () => _insertHeaderAt(i + 1),
                      onRemove: () => _removeAt(i),
                    ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _insertItemAt(
                    _items.length,
                    reference: _items.isNotEmpty ? _items.last : null,
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Item'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _insertHeaderAt(_items.length),
                  icon: const Icon(Icons.view_headline),
                  label: const Text('Add Header'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : () => _handleSave(),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(_saving ? 'Saving...' : 'Save Price List'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryHeaderEditorCard extends StatelessWidget {
  const _CategoryHeaderEditorCard({
    super.key,
    required this.item,
    required this.onChanged,
    required this.onInsertItemBelow,
    required this.onInsertHeaderBelow,
    required this.onRemove,
  });

  final PriceListItem item;
  final ValueChanged<PriceListItem> onChanged;
  final VoidCallback onInsertItemBelow;
  final VoidCallback onInsertHeaderBelow;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.leafGreen, Color(0xFF4A9E36)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.label_important_outline, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              initialValue: item.name,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: 'Section Header (e.g. Fruits, Vegetables)',
                hintStyle: TextStyle(color: Colors.white70),
              ),
              onChanged: (v) => onChanged(item.copyWith(name: v)),
            ),
          ),
          IconButton(
            tooltip: 'Add Header Below',
            icon: const Icon(Icons.title, color: Colors.white, size: 20),
            onPressed: onInsertHeaderBelow,
          ),
          IconButton(
            tooltip: 'Add Item Below',
            icon: const Icon(Icons.add_circle_outline,
                color: Colors.white, size: 20),
            onPressed: onInsertItemBelow,
          ),
          IconButton(
            tooltip: 'Remove Header',
            icon: const Icon(Icons.close, color: Colors.white, size: 20),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _ProduceRowEditorCard extends StatelessWidget {
  const _ProduceRowEditorCard({
    super.key,
    required this.item,
    required this.duplicateCount,
    required this.onChanged,
    required this.onInsertItemBelow,
    required this.onInsertHeaderBelow,
    required this.onRemove,
  });

  final PriceListItem item;
  final int? duplicateCount;
  final ValueChanged<PriceListItem> onChanged;
  final VoidCallback onInsertItemBelow;
  final VoidCallback onInsertHeaderBelow;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isDup = duplicateCount != null && duplicateCount! > 1;
    final categoryValue = PriceListsViewModel.categories.contains(item.category)
        ? item.category
        : 'other';
    final unitValue = PriceListsViewModel.units.contains(item.unit)
        ? item.unit
        : 'kgs';

    return Card(
      color: isDup ? const Color(0xFFFFF5F5) : AppTheme.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isDup ? AppTheme.danger : AppTheme.borderSubtle,
          width: isDup ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.name,
                    decoration: InputDecoration(
                      labelText: 'Item Name',
                      hintText: 'e.g. Tomatoes',
                      suffixIcon: isDup
                          ? Tooltip(
                              message: 'Duplicate (${duplicateCount}x)',
                              child: const Icon(
                                Icons.warning_amber_rounded,
                                color: AppTheme.danger,
                              ),
                            )
                          : null,
                    ),
                    onChanged: (v) => onChanged(item.copyWith(name: v)),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 115,
                  child: TextFormField(
                    initialValue: item.price > 0 ? item.price.toString() : '',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'KES',
                      hintText: '0.00',
                    ),
                    onChanged: (v) => onChanged(
                      item.copyWith(price: double.tryParse(v.trim()) ?? 0),
                    ),
                  ),
                ),
              ],
            ),
            if (isDup)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.dangerSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Duplicate (${duplicateCount}x)',
                      style: const TextStyle(
                        color: AppTheme.danger,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: categoryValue,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: PriceListsViewModel.categories
                        .map(
                          (c) => DropdownMenuItem(
                            value: c,
                            child: Text(
                              c[0].toUpperCase() + c.substring(1),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) onChanged(item.copyWith(category: v));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: unitValue,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: PriceListsViewModel.units
                        .map(
                          (u) => DropdownMenuItem(
                            value: u,
                            child: Text(
                              u[0].toUpperCase() + u.substring(1),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) onChanged(item.copyWith(unit: v));
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Grade A, etc.',
                    ),
                    onChanged: (v) => onChanged(item.copyWith(notes: v)),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Add Header Below',
                  onPressed: onInsertHeaderBelow,
                  icon: const Icon(Icons.title, color: AppTheme.forestGreen),
                ),
                IconButton(
                  tooltip: 'Add Item Below',
                  onPressed: onInsertItemBelow,
                  icon: const Icon(
                    Icons.add_circle_outline,
                    color: AppTheme.forestGreen,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove Row',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
