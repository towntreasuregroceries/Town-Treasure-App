import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/staging_repository.dart';
import '../../data/repositories/vault_repository.dart';
import '../../data/services/duplicate_detector_service.dart';
import '../../data/services/local_storage_service.dart';
import '../../data/services/ocr_consensus_service.dart';
import '../../data/services/remote_update_service.dart';
import '../../data/services/supabase_service.dart';
import '../../domain/models/models.dart';
import '../features/clerk/clerk_submissions_screen.dart';
import '../features/clerk/clerk_view_model.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/dashboard/dashboard_view_model.dart';
import '../features/dashboard/overdue_notification_service.dart';
import '../features/dashboard/signature_scanner_sheet.dart';
import '../features/dashboard/update_checker_sheet.dart';
import '../features/expenses/expenses_hub_screen.dart';
import '../features/expenses/expenses_view_model.dart';
import '../features/invoices/invoice_detail_screen.dart';
import '../features/invoices/invoice_editor_screen.dart';
import '../features/invoices/invoices_list_screen.dart';
import '../features/invoices/invoices_view_model.dart';
import '../features/invoices/recycle_bin_screen.dart';
import '../features/pricelists/pricelist_editor_screen.dart';
import '../features/pricelists/pricelists_screen.dart';
import '../features/pricelists/pricelists_view_model.dart';
import '../features/reports/reports_screen.dart';
import '../features/reports/reports_view_model.dart';
import '../features/reports/statements_screen.dart';
import '../features/restaurants/restaurants_screen.dart';
import '../features/restaurants/restaurants_view_model.dart';
import '../features/scanner/docket_scanner_sheet.dart';
import 'theme/app_theme.dart';

/// Authenticated workspace shell with Material 3 `NavigationBar`,
/// live clerk staging badge, cross-feature navigation & scanner wiring,
/// `AppMotion` transitions, and `PopScope` back handling.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.initialTabIndex = 0,
    this.onSignedOut,
    this.autoInitializeDashboard = true,
    this.updateManifestUrl = defaultUpdateManifestUrl,
    this.dashboardViewModel,
    this.clerkViewModel,
    this.invoicesViewModel,
    this.restaurantsViewModel,
    this.priceListsViewModel,
    this.expensesViewModel,
    this.reportsViewModel,
    this.signatureImagePicker,
  });

  static const String defaultUpdateManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json';

  final int initialTabIndex;
  final VoidCallback? onSignedOut;
  final bool autoInitializeDashboard;
  final String updateManifestUrl;
  final DashboardViewModel? dashboardViewModel;
  final ClerkViewModel? clerkViewModel;
  final InvoicesViewModel? invoicesViewModel;
  final RestaurantsViewModel? restaurantsViewModel;
  final PriceListsViewModel? priceListsViewModel;
  final ExpensesViewModel? expensesViewModel;
  final ReportsViewModel? reportsViewModel;
  final ImageBytesPicker? signatureImagePicker;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Stack indices: 0 = Dashboard, 1 = Invoices, 2 = Clerks, 3 = More.
  late int _tabIndex;
  bool _vmsInitialized = false;
  StreamSubscription<String?>? _notifTapSub;

  DashboardViewModel? _ownedDashboardVm;
  ClerkViewModel? _ownedClerkVm;
  InvoicesViewModel? _ownedInvoicesVm;
  RestaurantsViewModel? _ownedRestaurantsVm;
  PriceListsViewModel? _ownedPriceListsVm;
  ExpensesViewModel? _ownedExpensesVm;
  ReportsViewModel? _ownedReportsVm;

  DashboardViewModel get _dashboardVm =>
      widget.dashboardViewModel ?? _ownedDashboardVm!;
  ClerkViewModel get _clerkVm => widget.clerkViewModel ?? _ownedClerkVm!;
  InvoicesViewModel get _invoicesVm =>
      widget.invoicesViewModel ?? _ownedInvoicesVm!;
  RestaurantsViewModel get _restaurantsVm =>
      widget.restaurantsViewModel ?? _ownedRestaurantsVm!;
  PriceListsViewModel get _priceListsVm =>
      widget.priceListsViewModel ?? _ownedPriceListsVm!;
  ExpensesViewModel get _expensesVm =>
      widget.expensesViewModel ?? _ownedExpensesVm!;
  ReportsViewModel get _reportsVm =>
      widget.reportsViewModel ?? _ownedReportsVm!;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTabIndex.clamp(0, 3);
    _notifTapSub = FlutterLocalOverdueNotificationGateway.onNotificationTap
        .listen(_handleNotificationTapPayload);
  }

  void _handleNotificationTapPayload(String? payload) {
    if (!mounted || payload == null || payload.isEmpty) return;
    if (payload == NotificationCategory.appUpdates.name) {
      _openUpdateChecker();
    } else if (payload == NotificationCategory.clerkSubmissions.name) {
      _selectTab(2);
    } else if (payload == NotificationCategory.overdueInvoices.name) {
      _selectTab(1);
    } else if (payload == NotificationCategory.payrollDue.name) {
      _openExpensesHub(initialTabIndex: 1);
    } else if (payload == NotificationCategory.recurringBills.name) {
      _openExpensesHub(initialTabIndex: 2);
    } else if (payload == NotificationCategory.monthlyStatements.name) {
      _openStatements();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_vmsInitialized) return;
    _vmsInitialized = true;

    final vault = context.read<VaultRepository>();
    final auth = context.read<AuthRepository>();
    final staging = context.read<StagingRepository>();
    final supabase = context.read<SupabaseGateway>();
    final storage = context.read<LocalStorageService>();
    final ocr = context.read<OcrConsensusService>();
    final duplicateDetector = context.read<DuplicateDetectorService>();

    if (widget.dashboardViewModel == null) {
      RemoteUpdateService? updateService;
      try {
        updateService = context.read<RemoteUpdateService>();
      } catch (_) {
        updateService = null;
      }
      _ownedDashboardVm = DashboardViewModel(
        vaultRepository: vault,
        authRepository: auth,
        stagingRepository: staging,
        localStorage: storage,
        updateService: updateService,
        updateManifestUrl: widget.updateManifestUrl,
      );
    }
    if (widget.clerkViewModel == null) {
      _ownedClerkVm = ClerkViewModel(
        stagingRepository: staging,
        vaultRepository: vault,
        supabase: supabase,
        localStorage: storage,
        ocrService: ocr,
        duplicateDetector: duplicateDetector,
      );
    }
    if (widget.invoicesViewModel == null) {
      _ownedInvoicesVm = InvoicesViewModel(vault: vault);
    }
    if (widget.restaurantsViewModel == null) {
      _ownedRestaurantsVm = RestaurantsViewModel(vault: vault);
    }
    if (widget.priceListsViewModel == null) {
      _ownedPriceListsVm = PriceListsViewModel(vault: vault);
    }
    if (widget.expensesViewModel == null) {
      _ownedExpensesVm = ExpensesViewModel(vault: vault);
    }
    if (widget.reportsViewModel == null) {
      _ownedReportsVm = ReportsViewModel(vault: vault);
    }
  }

  @override
  void dispose() {
    _notifTapSub?.cancel();
    _ownedDashboardVm?.dispose();
    _ownedClerkVm?.dispose();
    _ownedInvoicesVm?.dispose();
    _ownedRestaurantsVm?.dispose();
    _ownedPriceListsVm?.dispose();
    _ownedExpensesVm?.dispose();
    _ownedReportsVm?.dispose();
    super.dispose();
  }

  int get _navSelectedIndex {
    return switch (_tabIndex) {
      0 => 0,
      1 => 1,
      2 => 3,
      3 => 4,
      _ => 0,
    };
  }

  void _selectTab(int nextTabIndex) {
    final clamped = nextTabIndex.clamp(0, 3);
    if (_tabIndex == clamped) {
      if (clamped == 2) {
        _clerkVm.loadSubmissions();
      }
      return;
    }
    setState(() => _tabIndex = clamped);
    if (clamped == 2) {
      _clerkVm.loadSubmissions();
    }
  }

  void _onNavDestinationSelected(int navIndex) {
    switch (navIndex) {
      case 0:
        _selectTab(0);
      case 1:
        _selectTab(1);
      case 2:
        _openNewOrScanSheet();
      case 3:
        _selectTab(2);
      case 4:
        _selectTab(3);
    }
  }

  Future<List<InvoiceLineItem>?> _openDocketScannerForInvoice(
    BuildContext ctx,
  ) async {
    final ocr = ctx.read<OcrConsensusService>();
    final output = await DocketScannerSheet.show(
      ctx,
      ocrService: ocr,
      mode: ScannerTargetMode.docket,
    );
    if (output == null) return null;
    if (output.docketResult != null) {
      return output.docketResult!.items;
    }
    if (output.csvItems.isNotEmpty) {
      return output.csvItems;
    }
    return null;
  }

  Future<List<PriceListItem>?> _openPriceListScanner(BuildContext ctx) async {
    final ocr = ctx.read<OcrConsensusService>();
    final output = await DocketScannerSheet.show(
      ctx,
      ocrService: ocr,
      mode: ScannerTargetMode.priceList,
    );
    return output?.priceListResult?.items;
  }

  Future<void> _openInvoiceEditor({
    Invoice? initialInvoice,
    List<InvoiceLineItem>? prefillItems,
    String? prefillRestaurantId,
    String? prefillDate,
  }) async {
    final navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => InvoiceEditorScreen(
          initialInvoice: initialInvoice,
          prefillItems: prefillItems,
          prefillRestaurantId: prefillRestaurantId,
          prefillDate: prefillDate,
          onOpenScanner: _openDocketScannerForInvoice,
          onSaved: (saved) {
            Navigator.of(routeContext).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => InvoiceDetailScreen(
                  invoiceId: saved.id,
                  onOpenScanner: _openDocketScannerForInvoice,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openInvoiceDetailById(String invoiceId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InvoiceDetailScreen(
          invoiceId: invoiceId,
          onOpenScanner: _openDocketScannerForInvoice,
        ),
      ),
    );
  }

  Future<void> _openStatements({String? initialRestaurantId}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StatementsScreen(
          viewModel: _reportsVm,
          initialRestaurantId: initialRestaurantId,
        ),
      ),
    );
  }

  Future<void> _openRestaurants() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => RestaurantsScreen(
          viewModel: _restaurantsVm,
          onQuickStatement: (restaurant) {
            Navigator.of(routeContext).push(
              MaterialPageRoute<void>(
                builder: (_) => StatementsScreen(
                  viewModel: _reportsVm,
                  initialRestaurantId: restaurant.id,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPriceLists() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PriceListsScreen(
          viewModel: _priceListsVm,
          onOpenScanner: _openPriceListScanner,
        ),
      ),
    );
  }

  Future<void> _openExpensesHub({int initialTabIndex = 0}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ExpensesHubScreen(
          viewModel: _expensesVm,
          initialTabIndex: initialTabIndex,
        ),
      ),
    );
  }

  Future<void> _openReports() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => ReportsScreen(
          viewModel: _reportsVm,
          onOpenStatements: () {
            Navigator.of(routeContext).push(
              MaterialPageRoute<void>(
                builder: (_) => StatementsScreen(viewModel: _reportsVm),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openRecycleBin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RecycleBinScreen(viewModel: _invoicesVm),
      ),
    );
  }

  Future<void> _openSignatureScanner() async {
    final vault = context.read<VaultRepository>();
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SignatureScannerSheet(
        initialSignatureUri: vault.settings.signature,
        onSaveSignature: _dashboardVm.saveSignature,
        imagePicker: widget.signatureImagePicker,
      ),
    );
  }

  Future<void> _openUpdateChecker() async {
    final updateService = context.read<RemoteUpdateService>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => UpdateCheckerSheet(
        updateService: updateService,
        manifestUrl: widget.updateManifestUrl,
      ),
    );
  }

  Future<void> _confirmAndSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
          'Your latest encrypted data will be synced before signing out. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _dashboardVm.signOut();
    if (ok && mounted) {
      widget.onSignedOut?.call();
    }
  }

  Future<void> _startScanToInvoice(ScannerTargetMode mode) async {
    final ocr = context.read<OcrConsensusService>();
    final vault = context.read<VaultRepository>();
    final output = await DocketScannerSheet.show(
      context,
      ocrService: ocr,
      mode: mode,
    );
    if (!mounted || output == null) return;

    if (output.docketResult != null) {
      final docket = output.docketResult!;
      final resolution = Restaurant.resolveName(
        docket.restaurantName,
        vault.restaurants,
      );
      final matchedRestId =
          resolution.status == RestaurantResolutionStatus.matched
              ? resolution.restaurant?.id
              : null;
      await _openInvoiceEditor(
        prefillItems: docket.items,
        prefillRestaurantId: matchedRestId,
        prefillDate: docket.date,
      );
      return;
    }

    if (output.csvItems.isNotEmpty) {
      await _openInvoiceEditor(prefillItems: output.csvItems);
    }
  }

  Future<void> _startScanToPriceList() async {
    final ocr = context.read<OcrConsensusService>();
    final output = await DocketScannerSheet.show(
      context,
      ocrService: ocr,
      mode: ScannerTargetMode.priceList,
    );
    if (!mounted) return;
    final items = output?.priceListResult?.items;
    if (items == null || items.isEmpty) return;

    final result = await _priceListsVm.createFromScannedItems(items);
    if (!mounted) return;
    if (result.saved != null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PriceListEditorScreen(
            priceListId: result.saved!.id,
            viewModel: _priceListsVm,
            onOpenScanner: _openPriceListScanner,
          ),
        ),
      );
      return;
    }
    await _openPriceLists();
  }

  Future<void> _openNewOrScanSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            key: const Key('new_scan_action_sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Quick Create & Scan',
                style: Theme.of(sheetCtx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
              ),
              const SizedBox(height: 10),
              ListTile(
                key: const Key('action_new_invoice'),
                leading: const CircleAvatar(
                  backgroundColor: AppTheme.sageTint,
                  foregroundColor: AppTheme.forestGreen,
                  child: Icon(Icons.receipt_long_outlined),
                ),
                title: const Text('New Invoice'),
                subtitle: const Text('Create an invoice or draft manually'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _openInvoiceEditor();
                },
              ),
              ListTile(
                key: const Key('action_scan_docket'),
                leading: const CircleAvatar(
                  backgroundColor: AppTheme.sageTint,
                  foregroundColor: AppTheme.forestGreen,
                  child: Icon(Icons.document_scanner_outlined),
                ),
                title: const Text('Scan Delivery Docket (OCR)'),
                subtitle: const Text('Capture docket photos and auto-fill invoice'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _startScanToInvoice(ScannerTargetMode.docket);
                },
              ),
              ListTile(
                key: const Key('action_import_csv_invoice'),
                leading: const CircleAvatar(
                  backgroundColor: AppTheme.sageTint,
                  foregroundColor: AppTheme.forestGreen,
                  child: Icon(Icons.upload_file_outlined),
                ),
                title: const Text('Import CSV to Invoice'),
                subtitle: const Text('Paste produce line items from CSV'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _startScanToInvoice(ScannerTargetMode.csvImport);
                },
              ),
              ListTile(
                key: const Key('action_scan_pricelist'),
                leading: const CircleAvatar(
                  backgroundColor: AppTheme.sageTint,
                  foregroundColor: AppTheme.forestGreen,
                  child: Icon(Icons.price_change_outlined),
                ),
                title: const Text('Scan Price List (OCR)'),
                subtitle: const Text('Extract a produce price sheet from photos'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _startScanToPriceList();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = context.watch<StagingRepository>().pendingCount;
    final updateService = context.read<RemoteUpdateService>();

    return PopScope(
      canPop: _tabIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tabIndex != 0) {
          _selectTab(0);
        }
      },
      child: Scaffold(
        body: TweenAnimationBuilder<double>(
          key: ValueKey(_tabIndex),
          tween: Tween(begin: 0, end: 1),
          duration: AppMotion.standard,
          curve: AppMotion.standardCurve,
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 6),
                child: child,
              ),
            );
          },
          child: IndexedStack(
            index: _tabIndex,
            children: [
              HeroMode(
                enabled: _tabIndex == 0,
                child: DashboardScreen(
                  viewModel: _dashboardVm,
                  updateService: updateService,
                  updateManifestUrl: widget.updateManifestUrl,
                  autoInitialize: widget.autoInitializeDashboard,
                  signatureImagePicker: widget.signatureImagePicker,
                  onOpenClerkInbox: () => _selectTab(2),
                  onOpenInvoicesTab: () => _selectTab(1),
                  onOpenExpensesHub: (tabIndex) =>
                      _openExpensesHub(initialTabIndex: tabIndex),
                  onOpenStatements: _openStatements,
                  onOpenInvoice: (inv) => _openInvoiceDetailById(inv.id),
                  onCreateInvoice: () => _openInvoiceEditor(),
                  onSignedOut: widget.onSignedOut,
                ),
              ),
              HeroMode(
                enabled: _tabIndex == 1,
                child: InvoicesListScreen(
                  viewModel: _invoicesVm,
                  onOpenScanner: _openDocketScannerForInvoice,
                  onOpenRecycleBin: _openRecycleBin,
                  onCreateInvoice: () => _openInvoiceEditor(),
                  onViewInvoice: (inv) => _openInvoiceDetailById(inv.id),
                ),
              ),
              HeroMode(
                enabled: _tabIndex == 2,
                child: ClerkSubmissionsScreen(
                  viewModel: _clerkVm,
                  onInspectInvoice: _openInvoiceDetailById,
                  onInvoiceApproved: (invoice) {
                    _openInvoiceDetailById(invoice.id);
                  },
                ),
              ),
              HeroMode(
                enabled: _tabIndex == 3,
                child: _MoreHubScreen(
                  dashboardViewModel: _dashboardVm,
                  onOpenRestaurants: _openRestaurants,
                  onOpenPriceLists: _openPriceLists,
                  onOpenExpenses: _openExpensesHub,
                  onOpenReports: _openReports,
                  onOpenStatements: () => _openStatements(),
                  onOpenRecycleBin: _openRecycleBin,
                  onCheckUpdates: _openUpdateChecker,
                  onOpenSignature: _openSignatureScanner,
                  onExportExcel: _dashboardVm.exportFullExcel,
                  onSignOut: _confirmAndSignOut,
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          key: const Key('app_navigation_bar'),
          selectedIndex: _navSelectedIndex,
          onDestinationSelected: _onNavDestinationSelected,
          destinations: [
            const NavigationDestination(
              key: Key('nav_dashboard'),
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            const NavigationDestination(
              key: Key('nav_invoices'),
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Invoices',
            ),
            const NavigationDestination(
              key: Key('nav_new_scan'),
              icon: Icon(Icons.add_circle_outline),
              selectedIcon: Icon(Icons.add_circle),
              label: 'New / Scan',
            ),
            NavigationDestination(
              key: const Key('nav_clerks'),
              icon: Badge.count(
                count: pendingCount,
                isLabelVisible: pendingCount > 0,
                child: const Icon(Icons.assignment_ind_outlined),
              ),
              selectedIcon: Badge.count(
                count: pendingCount,
                isLabelVisible: pendingCount > 0,
                child: const Icon(Icons.assignment_ind),
              ),
              label: 'Clerks',
            ),
            const NavigationDestination(
              key: Key('nav_more'),
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreHubScreen extends StatelessWidget {
  const _MoreHubScreen({
    required this.dashboardViewModel,
    required this.onOpenRestaurants,
    required this.onOpenPriceLists,
    required this.onOpenExpenses,
    required this.onOpenReports,
    required this.onOpenStatements,
    required this.onOpenRecycleBin,
    required this.onCheckUpdates,
    required this.onOpenSignature,
    required this.onExportExcel,
    required this.onSignOut,
  });

  final DashboardViewModel dashboardViewModel;
  final VoidCallback onOpenRestaurants;
  final VoidCallback onOpenPriceLists;
  final VoidCallback onOpenExpenses;
  final VoidCallback onOpenReports;
  final VoidCallback onOpenStatements;
  final VoidCallback onOpenRecycleBin;
  final VoidCallback onCheckUpdates;
  final VoidCallback onOpenSignature;
  final Future<void> Function() onExportExcel;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final vault = context.watch<VaultRepository>();
    final binCount = vault.deletedInvoices.length +
        vault.deletedStaff.length +
        vault.deletedPriceLists.length;

    return ListenableBuilder(
      listenable: dashboardViewModel,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('More & Tools'),
            actions: [
              IconButton(
                tooltip: 'Sync encrypted vault',
                onPressed: dashboardViewModel.isSyncing
                    ? null
                    : dashboardViewModel.refresh,
                icon: dashboardViewModel.isSyncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          body: ListView(
            key: const Key('more_hub_list'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: AppTheme.forestGreen,
                        foregroundColor: Colors.white,
                        child: Text(
                          dashboardViewModel.userInitials,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Town Treasure Groceries',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: AppTheme.slateInk,
                              ),
                            ),
                            Text(
                              dashboardViewModel.userEmail ??
                                  'Encrypted vault connected',
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: AppTheme.slateMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const _SectionLabel(title: 'Operations & Catalog'),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _MoreTile(
                      key: const Key('more_restaurants'),
                      icon: Icons.storefront_outlined,
                      title: 'Restaurants',
                      subtitle: 'Clients, KRA PINs, aliases & quick statements',
                      onTap: onOpenRestaurants,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_pricelists'),
                      icon: Icons.price_change_outlined,
                      title: 'Price Lists',
                      subtitle: 'Catalogs, OCR price scans & WhatsApp PDFs',
                      onTap: onOpenPriceLists,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_recycle_bin'),
                      icon: Icons.delete_sweep_outlined,
                      title: 'Recycle Bin',
                      subtitle: 'Recover deleted invoices, staff & price lists',
                      trailing: binCount > 0
                          ? Badge.count(count: binCount)
                          : const Icon(
                              Icons.chevron_right,
                              color: AppTheme.slateMuted,
                            ),
                      onTap: onOpenRecycleBin,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionLabel(title: 'Finance & Reporting'),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _MoreTile(
                      key: const Key('more_capital_finance'),
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Capital & Finance',
                      subtitle: 'Expenses, capital, payroll, recurring & loans',
                      onTap: onOpenExpenses,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_reports_insights'),
                      icon: Icons.analytics_outlined,
                      title: 'Reports & Insights',
                      subtitle: 'Charts, P&L, smart insights & report builder',
                      onTap: onOpenReports,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_monthly_statements'),
                      icon: Icons.description_outlined,
                      title: 'Monthly Statements',
                      subtitle: 'Client billing statements, PDF & WhatsApp',
                      onTap: onOpenStatements,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionLabel(title: 'Tools & Account'),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    _MoreTile(
                      key: const Key('more_signature'),
                      icon: Icons.draw_outlined,
                      title: 'Signature',
                      subtitle: 'Scan or update invoice authorization signature',
                      onTap: onOpenSignature,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_excel_export'),
                      icon: Icons.table_view_outlined,
                      title: 'Excel Export',
                      subtitle: 'Export full multi-sheet .xlsx workbook',
                      trailing: dashboardViewModel.isExporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.chevron_right,
                              color: AppTheme.slateMuted,
                            ),
                      onTap: dashboardViewModel.isExporting
                          ? null
                          : () => onExportExcel(),
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_check_updates'),
                      icon: Icons.system_update_outlined,
                      title: 'Check for Updates',
                      subtitle: 'Verify SHA-256 checksum & install latest APK',
                      onTap: onCheckUpdates,
                    ),
                    const Divider(height: 1),
                    _MoreTile(
                      key: const Key('more_sign_out'),
                      icon: Icons.logout,
                      iconColor: AppTheme.danger,
                      titleColor: AppTheme.danger,
                      title: 'Sign Out',
                      subtitle: 'Sync encrypted vault and sign out',
                      onTap: onSignOut,
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppTheme.slateMuted,
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor = AppTheme.forestGreen,
    this.titleColor = AppTheme.slateInk,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color iconColor;
  final Color titleColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: iconColor == AppTheme.danger
              ? AppTheme.dangerSurface
              : AppTheme.sageTint,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
          color: titleColor,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
      ),
      trailing: trailing ??
          const Icon(Icons.chevron_right, color: AppTheme.slateMuted),
      onTap: onTap,
    );
  }
}
