import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../core/theme/app_theme.dart';
import 'invoice_formatters.dart';
import 'invoices_view_model.dart';

/// Tabbed Recycle Bin recovery screen for deleted Invoices (single & multi-select
/// batch restore), Staff, and Price Lists (`invoices.js`, `payroll.js`, `pricelist.js`).
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({
    super.key,
    this.viewModel,
  });

  final InvoicesViewModel? viewModel;

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen>
    with SingleTickerProviderStateMixin {
  InvoicesViewModel? _ownedVm;
  late final TabController _tabController;
  final Set<String> _selectedIds = {};

  InvoicesViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (_tabController.indexIsChanging) return;
        setState(() => _selectedIds.clear());
      });
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
    _tabController.dispose();
    _ownedVm?.dispose();
    super.dispose();
  }

  void _showSnack(String message, {bool isWarning = false, bool isError = false}) {
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

  List<String> _currentTabIds() {
    switch (_tabController.index) {
      case 0:
        return _vm.deletedInvoices.map((e) => e.id).toList();
      case 1:
        return _vm.deletedStaff.map((e) => e.id).toList();
      case 2:
        return _vm.deletedPriceLists.map((e) => e.id).toList();
      default:
        return const [];
    }
  }

  Future<void> _restoreSingle(int tabIndex, String id) async {
    final ActionOutcome res;
    switch (tabIndex) {
      case 0:
        res = await _vm.restoreInvoices([id]);
      case 1:
        res = await _vm.restoreStaffMembers([id]);
      case 2:
        res = await _vm.restorePriceLists([id]);
      default:
        return;
    }
    setState(() => _selectedIds.remove(id));
    _showSnack(res.message, isError: !res.ok, isWarning: res.ok && !res.synced);
  }

  Future<void> _restoreSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) {
      _showSnack('No items selected.', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Items'),
        content: Text('Restore ${ids.length} selected item(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ActionOutcome res;
    switch (_tabController.index) {
      case 0:
        res = await _vm.restoreInvoices(ids);
      case 1:
        res = await _vm.restoreStaffMembers(ids);
      case 2:
        res = await _vm.restorePriceLists(ids);
      default:
        return;
    }
    setState(() => _selectedIds.clear());
    _showSnack(res.message, isError: !res.ok, isWarning: res.ok && !res.synced);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final invoices = _vm.deletedInvoices;
        final staff = _vm.deletedStaff;
        final priceLists = _vm.deletedPriceLists;
        final tabIds = _currentTabIds();
        final allSelected =
            tabIds.isNotEmpty && tabIds.every(_selectedIds.contains);

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Recycle Bin'),
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: AppTheme.leafGreen,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              tabs: [
                Tab(
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  text: 'Invoices (${invoices.length})',
                ),
                Tab(
                  icon: const Icon(Icons.badge_outlined, size: 18),
                  text: 'Staff (${staff.length})',
                ),
                Tab(
                  icon: const Icon(Icons.list_alt_outlined, size: 18),
                  text: 'Price Lists (${priceLists.length})',
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              if (tabIds.isNotEmpty)
                Container(
                  color: AppTheme.surfaceCard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: allSelected,
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _selectedIds.addAll(tabIds);
                            } else {
                              _selectedIds.removeAll(tabIds);
                            }
                          });
                        },
                      ),
                      Text(
                        _selectedIds.isEmpty
                            ? 'Select all'
                            : '${_selectedIds.length} selected',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: AppMotion.fast,
                        child: _selectedIds.isNotEmpty
                            ? FilledButton.icon(
                                key: const ValueKey('batch-restore'),
                                onPressed: _restoreSelected,
                                icon: const Icon(
                                  Icons.restore_from_trash_outlined,
                                  size: 18,
                                ),
                                label: const Text('Restore Selected'),
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('no-selection'),
                              ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildInvoicesTab(invoices),
                    _buildStaffTab(staff),
                    _buildPriceListsTab(priceLists),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInvoicesTab(List<dynamic> invoices) {
    if (invoices.isEmpty) {
      return const _EmptyBinState(title: 'No deleted invoices');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: invoices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final inv = _vm.deletedInvoices[index];
        final checked = _selectedIds.contains(inv.id);
        final deletedStr = inv.deletedAt != null
            ? InvoiceFormatters.formatDisplayDate(inv.deletedAt)
            : '-';
        return Card(
          child: ListTile(
            leading: Checkbox(
              value: checked,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedIds.add(inv.id);
                  } else {
                    _selectedIds.remove(inv.id);
                  }
                });
              },
            ),
            title: Text(
              '${inv.number} - ${inv.restaurantName.isNotEmpty ? inv.restaurantName : 'Unknown'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              'Date: ${InvoiceFormatters.formatDisplayDate(inv.date)} | KES ${InvoiceFormatters.formatMoney(inv.totalSell)}\nDeleted on: $deletedStr',
            ),
            isThreeLine: true,
            trailing: FilledButton.tonalIcon(
              onPressed: () => _restoreSingle(0, inv.id),
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Restore'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStaffTab(List<dynamic> staff) {
    if (staff.isEmpty) {
      return const _EmptyBinState(title: 'No deleted staff');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: staff.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final s = _vm.deletedStaff[index];
        final checked = _selectedIds.contains(s.id);
        final deletedStr = s.deletedAt != null
            ? InvoiceFormatters.formatDisplayDate(s.deletedAt)
            : '-';
        return Card(
          child: ListTile(
            leading: Checkbox(
              value: checked,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedIds.add(s.id);
                  } else {
                    _selectedIds.remove(s.id);
                  }
                });
              },
            ),
            title: Text(
              s.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${s.role.isNotEmpty ? s.role : 'Staff'} | KES ${InvoiceFormatters.formatMoney(s.salary)}\nDeleted on: $deletedStr',
            ),
            isThreeLine: true,
            trailing: FilledButton.tonalIcon(
              onPressed: () => _restoreSingle(1, s.id),
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Restore'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPriceListsTab(List<dynamic> priceLists) {
    if (priceLists.isEmpty) {
      return const _EmptyBinState(title: 'No deleted price lists');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: priceLists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final pl = _vm.deletedPriceLists[index];
        final checked = _selectedIds.contains(pl.id);
        final deletedStr = pl.deletedAt != null
            ? InvoiceFormatters.formatDisplayDate(pl.deletedAt)
            : '-';
        return Card(
          child: ListTile(
            leading: Checkbox(
              value: checked,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selectedIds.add(pl.id);
                  } else {
                    _selectedIds.remove(pl.id);
                  }
                });
              },
            ),
            title: Text(
              pl.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${pl.items.length} item(s)\nDeleted on: $deletedStr',
            ),
            isThreeLine: true,
            trailing: FilledButton.tonalIcon(
              onPressed: () => _restoreSingle(2, pl.id),
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Restore'),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyBinState extends StatelessWidget {
  const _EmptyBinState({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.delete_outline,
            size: 52,
            color: AppTheme.slateMuted,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateInk,
                ),
          ),
        ],
      ),
    );
  }
}
