import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/theme/app_theme.dart';
import 'restaurants_view_model.dart';

/// Mobile-first Material 3 Restaurant Clients management screen.
class RestaurantsScreen extends StatefulWidget {
  const RestaurantsScreen({
    super.key,
    this.onQuickStatement,
    this.viewModel,
  });

  /// Invoked when the user taps the Statement button on a restaurant card.
  final void Function(Restaurant restaurant)? onQuickStatement;

  /// Optional external ViewModel (helpful for tests or parent-scoped state).
  final RestaurantsViewModel? viewModel;

  @override
  State<RestaurantsScreen> createState() => _RestaurantsScreenState();
}

class _RestaurantsScreenState extends State<RestaurantsScreen> {
  RestaurantsViewModel? _ownedVm;
  final TextEditingController _searchController = TextEditingController();
  final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  RestaurantsViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      final vault = context.read<VaultRepository>();
      _ownedVm = RestaurantsViewModel(vault: vault);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
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

  Future<void> _openEditor({Restaurant? existing}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _RestaurantEditorSheet(
        existing: existing,
        viewModel: _vm,
        onResult: (res) => _showSnack(
          res.message,
          isError: !res.ok,
          isWarning: res.ok && !res.synced,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Restaurant restaurant) async {
    final refs = _vm.countLinkedInvoices(restaurant);
    if (refs > 0) {
      _showSnack(
        'Cannot delete ${restaurant.name}: $refs active or recycled invoice(s) are linked to it. Edit the restaurant and merge aliases into the correct record instead.',
        isError: true,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Restaurant'),
        content: Text(
          'Are you sure you want to delete ${restaurant.name}? Any associated records without links will show as Unknown.',
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
    if (confirmed != true) return;

    final result = await _vm.deleteRestaurant(restaurant.id);
    _showSnack(
      result.message,
      isError: !result.ok,
      isWarning: result.ok && !result.synced,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final restaurants = _vm.filteredRestaurants;
        final totalCount = _vm.allRestaurants.length;

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Restaurants'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.leafGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                  ),
                  onPressed: () => _openEditor(),
                  icon: const Icon(Icons.add_business_outlined, size: 18),
                  label: const Text('Add Client'),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: _vm.setSearchQuery,
                  decoration: InputDecoration(
                    hintText: 'Search name, alias, KRA PIN, contact or phone',
                    prefixIcon: const Icon(
                      Icons.search,
                      color: AppTheme.slateMuted,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              _vm.setSearchQuery('');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.storefront_outlined,
                      size: 16,
                      color: AppTheme.forestGreen,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$totalCount client${totalCount == 1 ? '' : 's'} registered',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.slateMuted,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.standard,
                  switchInCurve: AppMotion.standardCurve,
                  child: restaurants.isEmpty
                      ? _EmptyRestaurantsView(
                          hasQuery: _searchController.text.trim().isNotEmpty,
                          onAdd: () => _openEditor(),
                        )
                      : ListView.separated(
                          key: ValueKey(restaurants.length),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                          itemCount: restaurants.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final r = restaurants[index];
                            final totalSales = _vm.totalSalesFor(r);
                            final invCount = _vm.invoiceCountFor(r);
                            final similar = _vm.findSimilarRecords(r);
                            return _RestaurantCard(
                              restaurant: r,
                              totalSalesFormatted:
                                  'KES ${_moneyFormat.format(totalSales)}',
                              invoiceCount: invCount,
                              similarNames: similar
                                  .map((m) => m.restaurant.name)
                                  .toSet()
                                  .take(3)
                                  .toList(),
                              onEdit: () => _openEditor(existing: r),
                              onDelete: () => _confirmDelete(r),
                              onStatement: widget.onQuickStatement != null
                                  ? () => widget.onQuickStatement!(r)
                                  : null,
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

class _RestaurantCard extends StatelessWidget {
  const _RestaurantCard({
    required this.restaurant,
    required this.totalSalesFormatted,
    required this.invoiceCount,
    required this.similarNames,
    required this.onEdit,
    required this.onDelete,
    this.onStatement,
  });

  final Restaurant restaurant;
  final String totalSalesFormatted;
  final int invoiceCount;
  final List<String> similarNames;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onStatement;

  @override
  Widget build(BuildContext context) {
    final aliases = restaurant.aliases.where((a) => a.trim().isNotEmpty).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: AppTheme.sageTint,
                  child: const Icon(
                    Icons.restaurant_outlined,
                    color: AppTheme.forestGreen,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        restaurant.name,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (restaurant.kraPin.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.sageTint,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppTheme.forestGreen.withValues(
                                    alpha: 0.25,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.verified_user_outlined,
                                    size: 13,
                                    color: AppTheme.forestGreen,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'PIN: ${restaurant.kraPin}',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'monospace',
                                      color: AppTheme.forestGreenDeep,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceSage,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: AppTheme.borderSubtle),
                              ),
                              child: const Text(
                                'No KRA PIN',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.slateMuted,
                                ),
                              ),
                            ),
                          Text(
                            '$invoiceCount invoice${invoiceCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      totalSalesFormatted,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.forestGreen,
                          ),
                    ),
                    const Text(
                      'Total Sales',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (aliases.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.label_outline,
                    size: 15,
                    color: AppTheme.slateMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Also known as: ${aliases.join(', ')}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (restaurant.contact.isNotEmpty ||
                restaurant.phone.isNotEmpty ||
                restaurant.address.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  if (restaurant.contact.isNotEmpty)
                    _InfoChip(
                      icon: Icons.person_outline,
                      text: restaurant.contact,
                    ),
                  if (restaurant.phone.isNotEmpty)
                    _InfoChip(
                      icon: Icons.phone_outlined,
                      text: restaurant.phone,
                    ),
                  if (restaurant.address.isNotEmpty)
                    _InfoChip(
                      icon: Icons.location_on_outlined,
                      text: restaurant.address,
                    ),
                ],
              ),
            ],
            if (similarNames.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.warningSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AppTheme.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Review possible duplicates: ${similarNames.join(', ')}. Merge only if they are the same customer.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.warning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onStatement != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.sageTint,
                        foregroundColor: AppTheme.forestGreenDeep,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onPressed: onStatement,
                      icon: const Icon(Icons.receipt_long_outlined, size: 16),
                      label: const Text('Statement'),
                    ),
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Delete restaurant',
                  onPressed: onDelete,
                  color: AppTheme.danger,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppTheme.slateMuted),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(fontSize: 12.5, color: AppTheme.slateInk),
        ),
      ],
    );
  }
}

class _EmptyRestaurantsView extends StatelessWidget {
  const _EmptyRestaurantsView({
    required this.hasQuery,
    required this.onAdd,
  });

  final bool hasQuery;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off_outlined : Icons.storefront_outlined,
              size: 52,
              color: AppTheme.slateMuted,
            ),
            const SizedBox(height: 12),
            Text(
              hasQuery ? 'No matching restaurants' : 'No restaurants yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateInk,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? 'Try another name, alias, or KRA PIN.'
                  : 'Add your first restaurant client to get started.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.slateMuted),
            ),
            if (!hasQuery) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add Restaurant'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RestaurantEditorSheet extends StatefulWidget {
  const _RestaurantEditorSheet({
    required this.viewModel,
    required this.onResult,
    this.existing,
  });

  final Restaurant? existing;
  final RestaurantsViewModel viewModel;
  final void Function(RestaurantActionResult result) onResult;

  @override
  State<_RestaurantEditorSheet> createState() => _RestaurantEditorSheetState();
}

class _RestaurantEditorSheetState extends State<_RestaurantEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _aliasesCtrl;
  late final TextEditingController _kraPinCtrl;
  late final TextEditingController _contactCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _addressCtrl;
  String? _inlineError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    _nameCtrl = TextEditingController(text: r?.name ?? '');
    _aliasesCtrl = TextEditingController(
      text: r != null ? r.aliases.join('\n') : '',
    );
    _kraPinCtrl = TextEditingController(text: r?.kraPin ?? '');
    _contactCtrl = TextEditingController(text: r?.contact ?? '');
    _phoneCtrl = TextEditingController(text: r?.phone ?? '');
    _addressCtrl = TextEditingController(text: r?.address ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aliasesCtrl.dispose();
    _kraPinCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<bool> _askConfirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: AppTheme.danger)
                : null,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _inlineError = null);

    final check = widget.viewModel.prepareSave(
      existingId: widget.existing?.id,
      name: _nameCtrl.text,
      aliasesRaw: _aliasesCtrl.text,
      kraPinRaw: _kraPinCtrl.text,
      contact: _contactCtrl.text,
      phone: _phoneCtrl.text,
      address: _addressCtrl.text,
    );

    if (check.hasError) {
      setState(() => _inlineError = check.error);
      return;
    }

    if (check.needsFuzzyConfirmation) {
      final names = check.fuzzyCandidates.map((c) {
        final detail = [c.address, c.phone, c.contact]
            .where((v) => v.trim().isNotEmpty)
            .join(', ');
        return detail.isNotEmpty ? '${c.name} ($detail)' : c.name;
      }).join('; ');

      final proceed = await _askConfirm(
        title: 'Review Possible Duplicate',
        body:
            'The restaurant name or one of its aliases is similar to $names. Save this record only after checking that it is a different customer, or cancel and add the spelling to the existing restaurant as an alias.',
        confirmLabel: 'Save Separate Record',
        destructive: true,
      );
      if (!proceed || !mounted) return;
    }

    if (check.needsMergeConfirmation) {
      final names = check.duplicates.map((d) => d.name).join(', ');
      final proceed = await _askConfirm(
        title: 'Merge Duplicate Restaurants',
        body:
            'Merge $names into ${check.candidate!.name}? Existing invoices will be reassigned to ${check.candidate!.name}, and future OCR matches will use this restaurant.',
        confirmLabel: 'Merge & Save',
      );
      if (!proceed || !mounted) return;
    }

    setState(() => _saving = true);
    final result = await widget.viewModel.commitSave(
      check.candidate!,
      isNew: check.isNew,
      duplicates: check.duplicates,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onResult(result);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final bottomInset = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      math.max(
        MediaQuery.viewPaddingOf(context).bottom,
        MediaQuery.paddingOf(context).bottom,
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    isEdit ? Icons.edit_location_alt_outlined : Icons.add_business_outlined,
                    color: AppTheme.forestGreen,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isEdit ? 'Edit Restaurant' : 'Add Restaurant',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                    ),
                  ),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_inlineError != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.dangerSurface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.danger,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _inlineError!,
                          style: const TextStyle(
                            color: AppTheme.danger,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Restaurant / Client Name *',
                  hintText: 'e.g. Golden Crest Hotel',
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Name is required';
                  }
                  if (Restaurant.normalizeRestaurantName(val).isEmpty) {
                    return 'Enter a specific restaurant name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _kraPinCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Company KRA PIN (Optional)',
                  hintText: 'e.g. P051234567X',
                  helperText: '11-character KRA PIN for invoice billing header',
                ),
                validator: (val) {
                  final norm = Restaurant.normalizeKraPin(val);
                  if (norm.isNotEmpty && !Restaurant.isValidKraPin(norm)) {
                    return 'Invalid KRA PIN (e.g. P051234567X)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _aliasesCtrl,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Aliases / Alternate Spellings',
                  hintText: 'One per line or comma-separated',
                  helperText:
                      'Used for OCR matching and duplicate protection',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _contactCtrl,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Contact Person',
                        hintText: 'e.g. Chef James',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        hintText: '0712345678',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _addressCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Address / Location',
                  hintText: 'e.g. Westlands, Nairobi',
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(isEdit ? 'Save Changes' : 'Save Restaurant'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
