import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../domain/models/models.dart';
import '../../core/developer_preview.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/vault_key_recovery_dialog.dart';
import 'change_password_dialog.dart';
import 'dashboard_view_model.dart';
import 'notification_center_sheet.dart';
import 'signature_scanner_sheet.dart';
import 'update_checker_sheet.dart';

enum _DashboardMenuAction {
  signature,
  exportExcel,
  changePassword,
  biometrics,
  notifications,
  updates,
  signOut,
}

/// Main Dashboard screen with animated Town Treasure header, KPI cards,
/// pending clerk docket banner, recent invoices, overdue alerts, signature
/// scanner, Excel export, password change, and APK update checker.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.viewModel,
    this.updateService,
    this.updateManifestUrl =
        'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json',
    this.onOpenClerkInbox,
    this.onOpenInvoicesTab,
    this.onOpenExpensesHub,
    this.onOpenStatements,
    this.onOpenKraTaxCenter,
    this.onOpenReports,
    this.onOpenDocumentStudio,
    this.onOpenInvoice,
    this.onCreateInvoice,
    this.onSignedOut,
    this.signatureImagePicker,
    this.autoInitialize = true,
  });

  final DashboardViewModel? viewModel;
  final RemoteUpdateService? updateService;
  final String updateManifestUrl;
  final VoidCallback? onOpenClerkInbox;
  final VoidCallback? onOpenInvoicesTab;
  final void Function(int tabIndex)? onOpenExpensesHub;
  final VoidCallback? onOpenStatements;
  final VoidCallback? onOpenKraTaxCenter;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenDocumentStudio;
  final void Function(Invoice invoice)? onOpenInvoice;
  final VoidCallback? onCreateInvoice;
  final VoidCallback? onSignedOut;
  final ImageBytesPicker? signatureImagePicker;
  final bool autoInitialize;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late final DashboardViewModel _vm;
  late final bool _ownsViewModel;
  late final AnimationController _headerAnimController;
  late final Animation<double> _headerFade;
  late final Animation<Offset> _headerSlide;

  String? _lastShownStatus;
  String? _lastShownError;

  @override
  void initState() {
    super.initState();
    if (widget.viewModel != null) {
      _vm = widget.viewModel!;
      _ownsViewModel = false;
    } else {
      _vm = DashboardViewModel(
        vaultRepository: context.read<VaultRepository>(),
        authRepository: context.read<AuthRepository>(),
        stagingRepository: context.read<StagingRepository>(),
        localStorage: _tryRead<LocalStorageService>(context),
        updateService: widget.updateService ?? _tryRead<RemoteUpdateService>(context),
        updateManifestUrl: widget.updateManifestUrl,
      );
      _ownsViewModel = true;
    }
    _vm.addListener(_onVmChanged);

    _headerAnimController = AnimationController(
      vsync: this,
      duration: AppMotion.gentle,
    );
    _headerFade = CurvedAnimation(
      parent: _headerAnimController,
      curve: AppMotion.standardCurve,
    );
    _headerSlide = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _headerAnimController,
        curve: AppMotion.standardCurve,
      ),
    );
    _headerAnimController.forward();

    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _vm.initialize();
        }
      });
    }
  }

  T? _tryRead<T>(BuildContext context) {
    try {
      return context.read<T>();
    } catch (_) {
      return null;
    }
  }

  void _onVmChanged() {
    if (!mounted) return;
    setState(() {});

    final err = _vm.errorMessage;
    if (err != null && err != _lastShownError) {
      _lastShownError = err;
      _showSnack(err, isError: true);
    } else if (err == null) {
      _lastShownError = null;
    }

    final status = _vm.statusMessage;
    if (status != null && status != _lastShownStatus) {
      _lastShownStatus = status;
      _showSnack(status, isError: false);
    } else if (status == null) {
      _lastShownStatus = null;
    }
  }

  void _showSnack(String message, {required bool isError}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? AppTheme.danger : AppTheme.forestGreenDeep,
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmChanged);
    if (_ownsViewModel) {
      _vm.dispose();
    }
    _headerAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _vm.metrics;
    DeveloperPreviewController? devPreview;
    try {
      devPreview = context.watch<DeveloperPreviewController>();
    } catch (_) {
      devPreview = null;
    }
    final redesignedActive = devPreview?.isRedesignedUiActiveFor(_vm.userEmail) ?? true;
    final hideBalances = _vm.hideBalances;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      floatingActionButton: widget.onCreateInvoice != null
          ? FloatingActionButton.extended(
              key: const Key('fab_create_invoice'),
              backgroundColor: redesignedActive
                  ? const Color(0xFF0F3D24)
                  : AppTheme.forestGreen,
              foregroundColor: Colors.white,
              elevation: redesignedActive ? 2 : null,
              shape: redesignedActive
                  ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    )
                  : null,
              onPressed: widget.onCreateInvoice,
              icon: Icon(
                redesignedActive ? Icons.add_rounded : Icons.add_circle_outline,
              ),
              label: const Text('New Invoice'),
            )
          : null,
      body: RefreshIndicator(
        color: AppTheme.forestGreen,
        onRefresh: _vm.refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (redesignedActive)
              _buildEditorialSliverHeader(context, metrics)
            else
              _buildBrandedSliverHeader(context),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (_vm.needsVaultKeyUnlock)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: VaultKeyWarningBanner(
                        onUnlockPressed: () async {
                          final ok = await VaultKeyRecoveryDialog.show(context);
                          if (ok && mounted) {
                            await _vm.refresh();
                          }
                        },
                      ),
                    ),
                  if (redesignedActive)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _ExecutiveHeroCard(
                        metrics: metrics,
                        hideBalances: hideBalances,
                        onToggleHideBalances: _vm.toggleHideBalances,
                        onOpenReports: widget.onOpenReports,
                        onOpenKraTaxCenter: widget.onOpenKraTaxCenter,
                        onOpenStatements: widget.onOpenStatements,
                        onOpenExpenses: widget.onOpenExpensesHub != null
                            ? () => widget.onOpenExpensesHub!(0)
                            : null,
                      ),
                    ),
                  AnimatedSize(
                    duration: AppMotion.standard,
                    curve: AppMotion.standardCurve,
                    child: _vm.hasUpdateAvailable &&
                            _vm.availableUpdate?.manifest != null
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: UpdateAvailableBanner(
                              version: _vm.availableUpdate!.manifest!.version,
                              releaseNotes:
                                  _vm.availableUpdate!.manifest!.releaseNotes,
                              onOpenUpdater: _openUpdateChecker,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  AnimatedSize(
                    duration: AppMotion.standard,
                    curve: AppMotion.standardCurve,
                    child: _vm.pendingClerkCount > 0
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _PendingClerkBanner(
                              pendingCount: _vm.pendingClerkCount,
                              onOpenInbox: widget.onOpenClerkInbox,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (!redesignedActive) ...[
                    _KpiGrid(
                      metrics: metrics,
                      hideBalances: hideBalances,
                    ),
                    const SizedBox(height: 16),
                    _QuickToolsCard(
                      overdueAlertsEnabled: _vm.overdueNotificationsEnabled,
                      isExporting: _vm.isExporting,
                      onToggleOverdueAlerts: (val) =>
                          _vm.toggleOverdueNotifications(val),
                      onOpenSignature: _openSignatureScanner,
                      onExportExcel: _vm.exportFullExcel,
                      onCheckUpdates: _openUpdateChecker,
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    _CompactUtilitiesBar(
                      isExporting: _vm.isExporting,
                      alertCount: _vm.activeAlerts.length,
                      onOpenDocumentStudio: widget.onOpenDocumentStudio,
                      onOpenSignature: _openSignatureScanner,
                      onExportExcel: _vm.exportFullExcel,
                      onOpenAlerts: _openNotificationCenter,
                      onCheckUpdates: _openUpdateChecker,
                    ),
                    const SizedBox(height: 14),
                    _ExecutivePulseRow(
                      metrics: metrics,
                      hideBalances: hideBalances,
                      onOpenInvoices: widget.onOpenInvoicesTab,
                      onOpenKraTaxCenter: widget.onOpenKraTaxCenter,
                      onOpenExpenses: widget.onOpenExpensesHub != null
                          ? () => widget.onOpenExpensesHub!(0)
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _CashflowTrendCard(
                      trend: metrics.monthlyTrend,
                      hideBalances: hideBalances,
                      onToggleHideBalances: _vm.toggleHideBalances,
                      onOpenReports: widget.onOpenReports,
                    ),
                    const SizedBox(height: 14),
                    _TopClientsMonthCard(
                      clients: metrics.topClients,
                      totalMonthRevenue: metrics.thisMonthRevenue,
                      hideBalances: hideBalances,
                      onOpenStatements: widget.onOpenStatements,
                    ),
                    const SizedBox(height: 14),
                  ],
                  _RecentInvoicesSection(
                    invoices: metrics.recentInvoices,
                    restaurantNameBuilder: _vm.restaurantDisplayName,
                    redesigned: redesignedActive,
                    hideBalances: hideBalances,
                    onViewAll: widget.onOpenInvoicesTab,
                    onOpenInvoice: widget.onOpenInvoice,
                    onCreateInvoice: widget.onCreateInvoice,
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverAppBar _buildEditorialSliverHeader(
    BuildContext context,
    DashboardMetrics metrics,
  ) {
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final subtitle =
        metrics.monthLabel.isNotEmpty ? metrics.monthLabel : 'Business Overview';
    return SliverAppBar(
      pinned: true,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      toolbarHeight: 62,
      backgroundColor: bgColor,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppTheme.slateInk,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      title: FadeTransition(
        opacity: _headerFade,
        child: SlideTransition(
          position: _headerSlide,
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE2EAE2)),
                ),
                child: Image.asset(
                  'assets/logo.png',
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(
                      Icons.storefront_outlined,
                      size: 20,
                      color: AppTheme.forestGreen,
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Town Treasure',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.slateInk,
                        letterSpacing: -0.3,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
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
      actions: _buildHeaderActions(lightSurface: true),
    );
  }

  SliverAppBar _buildBrandedSliverHeader(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 112,
      backgroundColor: AppTheme.forestGreenDeep,
      foregroundColor: Colors.white,
      title: FadeTransition(
        opacity: _headerFade,
        child: SlideTransition(
          position: _headerSlide,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Image.asset(
                  'assets/logo.png',
                  height: 28,
                  width: 28,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(
                      Icons.storefront_outlined,
                      size: 24,
                      color: AppTheme.forestGreen,
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Town Treasure',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      'Business Dashboard',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFD1FAE5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.forestGreenDeep,
                AppTheme.forestGreen,
              ],
            ),
          ),
        ),
      ),
      actions: _buildHeaderActions(lightSurface: false),
    );
  }

  List<Widget> _buildHeaderActions({required bool lightSurface}) {
    final bellColor = _vm.overdueNotificationsEnabled || _vm.activeAlerts.isNotEmpty
        ? (lightSurface ? AppTheme.forestGreen : const Color(0xFFBBF7D0))
        : (lightSurface ? AppTheme.slateInk : Colors.white);
    final syncColor = lightSurface ? AppTheme.slateInk : Colors.white;
    final spinnerColor = lightSurface ? AppTheme.forestGreen : Colors.white;
    final avatarBg = lightSurface ? const Color(0xFF0F3D24) : AppTheme.leafGreen;

    return [
      IconButton(
        key: const Key('btn_dashboard_notify_toggle'),
        tooltip: 'Notification Center (${_vm.activeAlerts.length})',
        onPressed: _openNotificationCenter,
        icon: Badge.count(
          count: _vm.activeAlerts.length,
          isLabelVisible: _vm.activeAlerts.isNotEmpty,
          backgroundColor:
              _vm.hasUpdateAvailable ? AppTheme.info : AppTheme.warning,
          child: Icon(
            _vm.activeAlerts.isNotEmpty || _vm.overdueNotificationsEnabled
                ? Icons.notifications_active
                : Icons.notifications_none_outlined,
            color: bellColor,
          ),
        ),
      ),
      IconButton(
        key: const Key('btn_dashboard_sync'),
        tooltip: 'Sync encrypted vault',
        onPressed: _vm.isSyncing ? null : _vm.refresh,
        icon: _vm.isSyncing
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: spinnerColor,
                ),
              )
            : Icon(Icons.sync, color: syncColor),
      ),
      PopupMenuButton<_DashboardMenuAction>(
        key: const Key('btn_dashboard_menu'),
        tooltip: 'Account & Tools',
        icon: CircleAvatar(
          radius: 15,
          backgroundColor: avatarBg,
          foregroundColor: Colors.white,
          child: Text(
            _vm.userInitials,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        onSelected: _handleMenuSelection,
        itemBuilder: (context) => [
          if (_vm.userEmail != null && _vm.userEmail!.isNotEmpty)
            PopupMenuItem<_DashboardMenuAction>(
              enabled: false,
              child: Text(
                _vm.userEmail!,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: AppTheme.slateInk,
                ),
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _DashboardMenuAction.signature,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.draw_outlined),
              title: Text('My Signature'),
            ),
          ),
          const PopupMenuItem(
            value: _DashboardMenuAction.exportExcel,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.table_view_outlined),
              title: Text('Export Excel (.xlsx)'),
            ),
          ),
          PopupMenuItem(
            value: _DashboardMenuAction.notifications,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _vm.overdueNotificationsEnabled
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: const Text('Notification Center'),
            ),
          ),
          PopupMenuItem(
            value: _DashboardMenuAction.biometrics,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.fingerprint),
              title: Text(
                _vm.biometricEnabled
                    ? 'Disable Screen Lock'
                    : 'Enable Screen Lock',
              ),
            ),
          ),
          const PopupMenuItem(
            value: _DashboardMenuAction.changePassword,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_reset_outlined),
              title: Text('Change Password'),
            ),
          ),
          const PopupMenuItem(
            value: _DashboardMenuAction.updates,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.system_update_outlined),
              title: Text('Check for Updates'),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _DashboardMenuAction.signOut,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout, color: AppTheme.danger),
              title: Text(
                'Sign Out',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(width: 4),
    ];
  }

  Future<void> _handleMenuSelection(_DashboardMenuAction action) async {
    switch (action) {
      case _DashboardMenuAction.signature:
        await _openSignatureScanner();
      case _DashboardMenuAction.exportExcel:
        await _vm.exportFullExcel();
      case _DashboardMenuAction.notifications:
        await _openNotificationCenter();
      case _DashboardMenuAction.biometrics:
        await _vm.toggleBiometricLock(!_vm.biometricEnabled);
      case _DashboardMenuAction.changePassword:
        await _openChangePasswordDialog();
      case _DashboardMenuAction.updates:
        await _openUpdateChecker();
      case _DashboardMenuAction.signOut:
        await _confirmAndSignOut();
    }
  }

  Future<void> _openSignatureScanner() async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SignatureScannerSheet(
        initialSignatureUri: _vm.vaultSettings.signature,
        onSaveSignature: _vm.saveSignature,
        imagePicker: widget.signatureImagePicker,
      ),
    );
  }

  Future<void> _openChangePasswordDialog() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => ChangePasswordDialog(
        onChangePassword: _vm.changePassword,
      ),
    );
  }

  Future<void> _openUpdateChecker() async {
    final service = widget.updateService ??
        _tryRead<RemoteUpdateService>(context) ??
        RemoteUpdateService();
    await UpdateCheckerSheet.show(
      context,
      updateService: service,
      manifestUrl: _vm.effectiveUpdateManifestUrl,
    );
  }

  Future<void> _openNotificationCenter() async {
    await NotificationCenterSheet.show(
      context,
      viewModel: _vm,
      onCheckUpdates: _openUpdateChecker,
      onOpenClerkInbox: widget.onOpenClerkInbox,
      onOpenInvoices: widget.onOpenInvoicesTab,
      onOpenExpenses: widget.onOpenExpensesHub,
      onOpenStatements: widget.onOpenStatements,
    );
  }

  Future<void> _confirmAndSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
          'Your latest encrypted data will be synced before signing out. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final ok = await _vm.signOut();
      if (ok && mounted) {
        widget.onSignedOut?.call();
      }
    }
  }
}

class _PendingClerkBanner extends StatelessWidget {
  const _PendingClerkBanner({
    required this.pendingCount,
    this.onOpenInbox,
  });

  final int pendingCount;
  final VoidCallback? onOpenInbox;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('banner_pending_clerk_dockets'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warningSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.warning.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.inbox_outlined,
              color: AppTheme.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$pendingCount Clerk ${pendingCount == 1 ? 'Docket' : 'Dockets'} Awaiting Review',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateInk,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Review and approve submitted deliveries into your encrypted vault.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const Key('btn_open_clerk_inbox'),
            onPressed: onOpenInbox,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.warning,
              foregroundColor: Colors.white,
            ),
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({
    required this.metrics,
    this.hideBalances = false,
  });

  final DashboardMetrics metrics;
  final bool hideBalances;

  @override
  Widget build(BuildContext context) {
    final marginText = hideBalances
        ? '••% margin'
        : (metrics.thisMonthMarginPercent != null
            ? '${metrics.thisMonthMarginPercent!.toStringAsFixed(1)}% margin'
            : 'No margin data yet');
    final pendingAmt = DashboardViewModel.formatMoneyOrMask(
      metrics.pendingBillsAmount,
      hidden: hideBalances,
    );
    final pendingSubtitle = metrics.overdueBillsCount > 0
        ? '${metrics.overdueBillsCount} overdue · KES $pendingAmt'
        : 'KES $pendingAmt';

    final cards = [
      _KpiCardData(
        key: const Key('kpi_revenue'),
        title: 'Revenue (Month)',
        value:
            'KES ${DashboardViewModel.formatMoneyOrMask(metrics.thisMonthRevenue, hidden: hideBalances)}',
        subtitle:
            '${metrics.thisMonthInvoiceCount} ${metrics.thisMonthInvoiceCount == 1 ? 'invoice' : 'invoices'}',
        icon: Icons.trending_up_rounded,
        accentColor: AppTheme.forestGreen,
        tintColor: AppTheme.sageTint,
      ),
      _KpiCardData(
        key: const Key('kpi_profit'),
        title: 'Net Profit',
        value:
            'KES ${DashboardViewModel.formatMoneyOrMask(metrics.thisMonthProfit, hidden: hideBalances)}',
        subtitle: marginText,
        icon: Icons.account_balance_wallet_outlined,
        accentColor: metrics.thisMonthProfit >= 0
            ? AppTheme.leafGreen
            : AppTheme.danger,
        tintColor: metrics.thisMonthProfit >= 0
            ? AppTheme.successSurface
            : AppTheme.dangerSurface,
      ),
      _KpiCardData(
        key: const Key('kpi_pending_bills'),
        title: 'Pending Bills',
        value: '${metrics.pendingBillsCount}',
        subtitle: pendingSubtitle,
        icon: Icons.schedule_outlined,
        accentColor:
            metrics.overdueBillsCount > 0 ? AppTheme.danger : AppTheme.warning,
        tintColor: metrics.overdueBillsCount > 0
            ? AppTheme.dangerSurface
            : AppTheme.warningSurface,
      ),
      _KpiCardData(
        key: const Key('kpi_paid_count'),
        title: 'Paid Invoices',
        value: '${metrics.thisMonthPaidCount} / ${metrics.thisMonthInvoiceCount}',
        subtitle: 'Settled this month',
        icon: Icons.check_circle_outline,
        accentColor: AppTheme.forestGreenDeep,
        tintColor: AppTheme.sageTint,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 4 : 2;
        const spacing = 12.0;
        final itemWidth =
            (constraints.maxWidth - (spacing * (columns - 1))) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < cards.length; i++)
              SizedBox(
                width: itemWidth,
                child: _AnimatedKpiCard(
                  data: cards[i],
                  delayIndex: i,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _KpiCardData {
  const _KpiCardData({
    required this.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.tintColor,
  });

  final Key key;
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final Color tintColor;
}

class _AnimatedKpiCard extends StatelessWidget {
  const _AnimatedKpiCard({
    required this.data,
    required this.delayIndex,
  });

  final _KpiCardData data;
  final int delayIndex;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(
      milliseconds: (AppMotion.standard.inMilliseconds + delayIndex * 40)
          .clamp(150, 360),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: AppMotion.standardCurve,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
      child: Card(
        key: data.key,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: data.tintColor,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(data.icon, size: 19, color: data.accentColor),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      data.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                data.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.slateInk,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                data.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.slateMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickToolsCard extends StatelessWidget {
  const _QuickToolsCard({
    required this.overdueAlertsEnabled,
    required this.isExporting,
    required this.onToggleOverdueAlerts,
    required this.onOpenSignature,
    required this.onExportExcel,
    required this.onCheckUpdates,
  });

  final bool overdueAlertsEnabled;
  final bool isExporting;
  final ValueChanged<bool> onToggleOverdueAlerts;
  final VoidCallback onOpenSignature;
  final VoidCallback onExportExcel;
  final VoidCallback onCheckUpdates;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.tune_outlined,
                  size: 18,
                  color: AppTheme.forestGreen,
                ),
                const SizedBox(width: 8),
                Text(
                  'Quick Tools',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              key: const Key('switch_overdue_notifications'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeThumbColor: AppTheme.forestGreen,
              secondary: Icon(
                overdueAlertsEnabled
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_none_outlined,
                color: overdueAlertsEnabled
                    ? AppTheme.forestGreen
                    : AppTheme.slateMuted,
              ),
              title: const Text(
                'Overdue Bill Alerts',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
              ),
              subtitle: const Text(
                'Local notifications for pending and overdue invoices',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
              value: overdueAlertsEnabled,
              onChanged: onToggleOverdueAlerts,
            ),
            const Divider(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  key: const Key('chip_my_signature'),
                  avatar: const Icon(
                    Icons.draw_outlined,
                    size: 17,
                    color: AppTheme.forestGreen,
                  ),
                  label: const Text('My Signature'),
                  onPressed: onOpenSignature,
                ),
                ActionChip(
                  key: const Key('chip_export_excel'),
                  avatar: isExporting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.download_outlined,
                          size: 17,
                          color: AppTheme.forestGreen,
                        ),
                  label: Text(isExporting ? 'Exporting...' : 'Export Excel'),
                  onPressed: isExporting ? null : onExportExcel,
                ),
                ActionChip(
                  key: const Key('chip_check_updates'),
                  avatar: const Icon(
                    Icons.system_update_outlined,
                    size: 17,
                    color: AppTheme.forestGreen,
                  ),
                  label: const Text('Check Updates'),
                  onPressed: onCheckUpdates,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentInvoicesSection extends StatelessWidget {
  const _RecentInvoicesSection({
    required this.invoices,
    required this.restaurantNameBuilder,
    this.redesigned = false,
    this.hideBalances = false,
    this.onViewAll,
    this.onOpenInvoice,
    this.onCreateInvoice,
  });

  final List<Invoice> invoices;
  final String Function(Invoice invoice) restaurantNameBuilder;
  final bool redesigned;
  final bool hideBalances;
  final VoidCallback? onViewAll;
  final void Function(Invoice invoice)? onOpenInvoice;
  final VoidCallback? onCreateInvoice;

  String _monogram(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'TT';
    if (words.length == 1) {
      return words.first.substring(0, words.first.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.receipt_long_outlined,
                  size: 18,
                  color: AppTheme.forestGreen,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recent Invoices',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateDark,
                        ),
                  ),
                ),
                if (redesigned && onViewAll != null)
                  TextButton(
                    onPressed: onViewAll,
                    child: const Text('View All'),
                  ),
                if (!redesigned && onCreateInvoice != null)
                  TextButton.icon(
                    key: const Key('btn_recent_create_invoice'),
                    onPressed: onCreateInvoice,
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Create'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (invoices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.receipt_outlined,
                        size: 38,
                        color: AppTheme.slateMuted.withValues(alpha: 0.45),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'No invoices yet this month',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Create an invoice to see revenue and profit here.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.slateMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: invoices.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final inv = invoices[index];
                  final restName = restaurantNameBuilder(inv);
                  return ListTile(
                    key: Key('recent_invoice_${inv.id}'),
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    onTap: onOpenInvoice == null
                        ? null
                        : () => onOpenInvoice!(inv),
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.sageTint,
                      foregroundColor: AppTheme.forestGreenDeep,
                      child: redesigned
                          ? Text(
                              _monogram(restName),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : const Icon(Icons.description_outlined, size: 19),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$restName · ${inv.number}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: AppTheme.slateInk,
                            ),
                          ),
                        ),
                        if (redesigned && inv.isFiscalized) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.successSurface,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'QR',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.forestGreenDeep,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '${inv.date} · Profit KES ${DashboardViewModel.formatMoneyOrMask(inv.profit, hidden: hideBalances)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                        fontFeatures: redesigned
                            ? const [FontFeature.tabularFigures()]
                            : null,
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'KES ${DashboardViewModel.formatMoneyOrMask(inv.totalSell, hidden: hideBalances)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppTheme.slateInk,
                            fontFeatures: redesigned
                                ? const [FontFeature.tabularFigures()]
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _StatusBadge(status: inv.status),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final (Color bg, Color fg) = switch (normalized) {
      'paid' => (AppTheme.successSurface, AppTheme.forestGreenDeep),
      'overdue' => (AppTheme.dangerSurface, AppTheme.danger),
      _ => (AppTheme.warningSurface, AppTheme.warning),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        normalized.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _ExecutiveHeroCard extends StatelessWidget {
  const _ExecutiveHeroCard({
    required this.metrics,
    this.hideBalances = false,
    this.onToggleHideBalances,
    this.onOpenReports,
    this.onOpenKraTaxCenter,
    this.onOpenStatements,
    this.onOpenExpenses,
  });

  final DashboardMetrics metrics;
  final bool hideBalances;
  final VoidCallback? onToggleHideBalances;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenKraTaxCenter;
  final VoidCallback? onOpenStatements;
  final VoidCallback? onOpenExpenses;

  @override
  Widget build(BuildContext context) {
    final total = metrics.thisMonthInvoiceCount;
    final paid = metrics.thisMonthPaidCount;
    final ratio = total > 0 ? (paid / total).clamp(0.0, 1.0) : 0.0;
    final marginLabel = hideBalances
        ? '••% margin'
        : (metrics.thisMonthMarginPercent != null
            ? '${metrics.thisMonthMarginPercent!.toStringAsFixed(1)}% margin'
            : 'Margin N/A');
    final revDelta = metrics.revenueChangePercent;
    final deltaPrefix = (revDelta ?? 0) >= 0 ? '+' : '';
    final deltaText = revDelta != null
        ? '$deltaPrefix${revDelta.round()}% vs ${metrics.previousMonthShortLabel}'
        : null;

    return Container(
      key: const Key('dev_executive_hero_card'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F3D24), Color(0xFF165B33)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1E0F3D24),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'THIS MONTH PERFORMANCE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9,
                    color: Color(0xFFA7F3D0),
                  ),
                ),
              ),
              if (!hideBalances && deltaText != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    deltaText,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFD1FAE5),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  marginLabel,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: AnimatedSwitcher(
                    duration: AppMotion.fast,
                    child: Text(
                      'KES ${DashboardViewModel.formatMoneyOrMask(metrics.thisMonthRevenue, hidden: hideBalances)}',
                      key: ValueKey<bool>(hideBalances),
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.6,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
              if (onToggleHideBalances != null) ...[
                const SizedBox(width: 10),
                Tooltip(
                  message: hideBalances ? 'Show balances' : 'Hide balances',
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.14),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const Key('btn_toggle_metrics_privacy'),
                      onTap: onToggleHideBalances,
                      child: Padding(
                        padding: const EdgeInsets.all(9),
                        child: Icon(
                          hideBalances
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Net Profit: KES ${DashboardViewModel.formatMoneyOrMask(metrics.thisMonthProfit, hidden: hideBalances)} · $paid/$total settled',
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFD1FAE5),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF86EFAC)),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _HeroActionPill(
                key: const Key('hero_pill_reports'),
                icon: Icons.bar_chart_rounded,
                label: 'Reports',
                onTap: onOpenReports,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
                key: const Key('hero_pill_etims'),
                icon: Icons.qr_code_2,
                label: 'eTIMS Tax',
                onTap: onOpenKraTaxCenter,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
                key: const Key('hero_pill_statements'),
                icon: Icons.description_outlined,
                label: 'Statements',
                onTap: onOpenStatements,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
                key: const Key('hero_pill_expenses'),
                icon: Icons.account_balance_wallet_outlined,
                label: 'Expenses',
                onTap: onOpenExpenses,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroActionPill extends StatelessWidget {
  const _HeroActionPill({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExecutivePulseRow extends StatelessWidget {
  const _ExecutivePulseRow({
    required this.metrics,
    this.hideBalances = false,
    this.onOpenInvoices,
    this.onOpenKraTaxCenter,
    this.onOpenExpenses,
  });

  final DashboardMetrics metrics;
  final bool hideBalances;
  final VoidCallback? onOpenInvoices;
  final VoidCallback? onOpenKraTaxCenter;
  final VoidCallback? onOpenExpenses;

  @override
  Widget build(BuildContext context) {
    final hasOverdue = metrics.overdueBillsCount > 0;
    final etimsTotal = metrics.thisMonthInvoiceCount;
    final etimsReady = metrics.thisMonthEtimsReadyCount;
    final etimsRatio =
        etimsTotal > 0 ? (etimsReady / etimsTotal).clamp(0.0, 1.0) : 0.0;
    final etimsPctLabel = '${(etimsRatio * 100).round()}%';

    final expRatioLabel = hideBalances
        ? 'Amounts hidden'
        : (metrics.thisMonthRevenue > 0
            ? '${((metrics.thisMonthExpenses / metrics.thisMonthRevenue) * 100).toStringAsFixed(1)}% of revenue'
            : 'Recorded this month');

    return Card(
      key: const Key('dev_executive_pulse_row'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onOpenInvoices,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'RECEIVABLES',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.7,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'KES ${DashboardViewModel.formatMoneyOrMask(metrics.pendingBillsAmount, hidden: hideBalances)}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.slateInk,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            hasOverdue
                                ? '${metrics.overdueBillsCount} overdue · ${metrics.pendingBillsCount} open'
                                : '${metrics.pendingBillsCount} open',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: hasOverdue
                                  ? AppTheme.danger
                                  : AppTheme.slateMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Color(0xFFE4EAE4),
                ),
                Expanded(
                  child: InkWell(
                    onTap: onOpenExpenses,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'OPERATING COSTS',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.7,
                              color: AppTheme.slateMuted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'KES ${DashboardViewModel.formatMoneyOrMask(metrics.thisMonthExpenses, hidden: hideBalances)}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.slateInk,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            expRatioLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.slateMuted,
                              fontFeatures: [FontFeature.tabularFigures()],
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
          const Divider(height: 1, thickness: 1, color: Color(0xFFE4EAE4)),
          InkWell(
            onTap: onOpenKraTaxCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.qr_code_2_outlined,
                        size: 16,
                        color: Color(0xFF0F3D24),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'KRA eTIMS Compliance · $etimsReady of $etimsTotal fiscalized',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.slateInk,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        etimsPctLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F3D24),
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: etimsRatio,
                      minHeight: 5,
                      backgroundColor: const Color(0xFFEDF2ED),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF0F3D24),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CashflowTrendCard extends StatelessWidget {
  const _CashflowTrendCard({
    required this.trend,
    this.hideBalances = false,
    this.onToggleHideBalances,
    this.onOpenReports,
  });

  final List<DashboardMonthPoint> trend;
  final bool hideBalances;
  final VoidCallback? onToggleHideBalances;
  final VoidCallback? onOpenReports;

  String _formatAxisCompact(double value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(0)}k';
    }
    return value.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final hasData =
        trend.isNotEmpty && trend.any((p) => p.revenue > 0 || p.netProfit > 0);
    final rawMax = trend.fold<double>(
      0,
      (m, p) => math.max(m, math.max(p.revenue, math.max(p.netProfit, 0))),
    );
    final maxY = rawMax <= 0 ? 1000.0 : rawMax * 1.18;

    return Card(
      key: const Key('dev_cashflow_trend_card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bar_chart_rounded,
                  size: 18,
                  color: Color(0xFF0F3D24),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '6-Month Cashflow',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
                if (onOpenReports != null)
                  TextButton(
                    onPressed: onOpenReports,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Reports'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Row(
              children: [
                _ChartLegendItem(color: Color(0xFF0F3D24), label: 'Revenue'),
                SizedBox(width: 14),
                _ChartLegendItem(color: AppTheme.leafGreen, label: 'Net Profit'),
              ],
            ),
            const SizedBox(height: 14),
            if (hideBalances)
              Container(
                key: const Key('cashflow_hidden_placeholder'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 22,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F7F4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE4EAE4)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.visibility_off_outlined,
                      size: 20,
                      color: AppTheme.slateMuted,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Amounts hidden',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                    if (onToggleHideBalances != null) ...[
                      const SizedBox(height: 2),
                      TextButton(
                        onPressed: onToggleHideBalances,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Show'),
                      ),
                    ],
                  ],
                ),
              )
            else if (!hasData)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Monthly cashflow trends appear once invoices are recorded.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                ),
              )
            else
              SizedBox(
                height: 152,
                child: BarChart(
                  BarChartData(
                    maxY: maxY,
                    alignment: BarChartAlignment.spaceAround,
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => const Color(0xFF0F172A),
                        tooltipRoundedRadius: 10,
                        tooltipPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final pt = trend[groupIndex];
                          final label = rodIndex == 0 ? 'Revenue' : 'Net Profit';
                          return BarTooltipItem(
                            '${pt.label} · $label\nKES ${DashboardViewModel.formatMoney(rod.toY)}',
                            const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 11.5,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 40,
                          getTitlesWidget: (val, meta) {
                            if (val >= meta.max * 0.96 && val > 0) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Text(
                                _formatAxisCompact(val),
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppTheme.slateMuted,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          getTitlesWidget: (val, meta) {
                            final idx = val.toInt();
                            if (idx < 0 || idx >= trend.length) {
                              return const SizedBox.shrink();
                            }
                            final isCurrent = idx == trend.length - 1;
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                trend[idx].label,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isCurrent
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: isCurrent
                                      ? AppTheme.slateInk
                                      : AppTheme.slateMuted,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (value) => const FlLine(
                        color: Color(0xFFE8ECE8),
                        strokeWidth: 1,
                        dashArray: [3, 3],
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barGroups: [
                      for (var i = 0; i < trend.length; i++)
                        BarChartGroupData(
                          x: i,
                          barsSpace: 3,
                          barRods: [
                            BarChartRodData(
                              toY: trend[i].revenue.clamp(0.0, double.infinity),
                              color: i == trend.length - 1
                                  ? const Color(0xFF0F3D24)
                                  : const Color(0xFF0F3D24)
                                      .withValues(alpha: 0.68),
                              width: 9,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                            BarChartRodData(
                              toY: trend[i].netProfit > 0
                                  ? trend[i].netProfit
                                  : 0,
                              color: i == trend.length - 1
                                  ? AppTheme.leafGreen
                                  : AppTheme.leafGreen.withValues(alpha: 0.68),
                              width: 9,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChartLegendItem extends StatelessWidget {
  const _ChartLegendItem({
    required this.color,
    required this.label,
  });

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.slateMuted,
          ),
        ),
      ],
    );
  }
}

class _TopClientsMonthCard extends StatelessWidget {
  const _TopClientsMonthCard({
    required this.clients,
    this.totalMonthRevenue = 0,
    this.hideBalances = false,
    this.onOpenStatements,
  });

  final List<DashboardTopClient> clients;
  final double totalMonthRevenue;
  final bool hideBalances;
  final VoidCallback? onOpenStatements;

  @override
  Widget build(BuildContext context) {
    final maxRevenue =
        clients.isNotEmpty && clients.first.revenue > 0 ? clients.first.revenue : 1.0;

    return Card(
      key: const Key('dev_top_clients_card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.apartment_outlined,
                  size: 18,
                  color: Color(0xFF0F3D24),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Top Hotels & Clients (Month)',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
                if (onOpenStatements != null)
                  TextButton(
                    onPressed: onOpenStatements,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Statements'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (clients.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'No client deliveries recorded yet this month.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                ),
              )
            else
              ...clients.map((c) {
                final barRatio = (c.revenue / maxRevenue).clamp(0.06, 1.0);
                final shareText = totalMonthRevenue > 0
                    ? ' · ${((c.revenue / totalMonthRevenue) * 100).round()}%'
                    : '';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${c.name} (${c.invoiceCount})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.slateInk,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            hideBalances
                                ? 'KES ${DashboardViewModel.maskedAmount}'
                                : 'KES ${DashboardViewModel.formatMoney(c.revenue)}$shareText',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F3D24),
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: hideBalances ? 0.0 : barRatio,
                          minHeight: 4,
                          backgroundColor: const Color(0xFFEDF2ED),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            AppTheme.forestGreen,
                          ),
                        ),
                      ),
                      if (c.unpaidAmount > 0) ...[
                        const SizedBox(height: 3),
                        Text(
                          hideBalances
                              ? 'KES ${DashboardViewModel.maskedAmount} unpaid balance'
                              : 'KES ${DashboardViewModel.formatMoney(c.unpaidAmount)} unpaid balance',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.warning,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _CompactUtilitiesBar extends StatelessWidget {
  const _CompactUtilitiesBar({
    required this.isExporting,
    required this.alertCount,
    this.onOpenDocumentStudio,
    required this.onOpenSignature,
    required this.onExportExcel,
    required this.onOpenAlerts,
    required this.onCheckUpdates,
  });

  final bool isExporting;
  final int alertCount;
  final VoidCallback? onOpenDocumentStudio;
  final VoidCallback onOpenSignature;
  final VoidCallback onExportExcel;
  final VoidCallback onOpenAlerts;
  final VoidCallback onCheckUpdates;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('dev_quick_utilities_bar'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            if (onOpenDocumentStudio != null)
              _UtilityIconBtn(
                key: const Key('btn_utility_doc_studio'),
                icon: Icons.article_outlined,
                label: 'Docs',
                onTap: onOpenDocumentStudio,
              ),
            _UtilityIconBtn(
              icon: Icons.draw_outlined,
              label: 'Signature',
              onTap: onOpenSignature,
            ),
            _UtilityIconBtn(
              icon: Icons.table_view_outlined,
              label: isExporting ? 'Export...' : 'Excel',
              onTap: isExporting ? null : onExportExcel,
            ),
            _UtilityIconBtn(
              icon: alertCount > 0
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_none_outlined,
              label: alertCount > 0 ? 'Alerts ($alertCount)' : 'Alerts',
              highlight: alertCount > 0,
              onTap: onOpenAlerts,
            ),
            _UtilityIconBtn(
              icon: Icons.system_update_outlined,
              label: 'Updates',
              onTap: onCheckUpdates,
            ),
          ],
        ),
      ),
    );
  }
}

class _UtilityIconBtn extends StatelessWidget {
  const _UtilityIconBtn({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final fg = highlight ? AppTheme.warning : const Color(0xFF0F3D24);
    final wellBg = highlight ? AppTheme.warningSurface : const Color(0xFFEFF5EF);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: wellBg,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 18, color: fg),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: highlight ? AppTheme.warning : AppTheme.slateInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
