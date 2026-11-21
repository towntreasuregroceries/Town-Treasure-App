import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../domain/models/models.dart';
import '../../core/developer_preview.dart';
import '../../core/theme/app_theme.dart';
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
    final isDev = _vm.isDeveloperAccount;
    final redesignedActive = devPreview?.isRedesignedUiActiveFor(_vm.userEmail) ??
        DeveloperPreviewConfig.isDeveloperEmail(_vm.userEmail);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      floatingActionButton: widget.onCreateInvoice != null
          ? FloatingActionButton.extended(
              key: const Key('fab_create_invoice'),
              backgroundColor: AppTheme.forestGreen,
              foregroundColor: Colors.white,
              onPressed: widget.onCreateInvoice,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('New Invoice'),
            )
          : null,
      body: RefreshIndicator(
        color: AppTheme.forestGreen,
        onRefresh: _vm.refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildBrandedSliverHeader(context),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (isDev)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _DeveloperPreviewRibbon(
                        redesignedEnabled: redesignedActive,
                        onToggle: devPreview?.toggleRedesignedUi,
                      ),
                    ),
                  if (redesignedActive)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _ExecutiveHeroCard(
                        metrics: metrics,
                        onCreateInvoice: widget.onCreateInvoice,
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
                            padding: const EdgeInsets.only(bottom: 16),
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
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _PendingClerkBanner(
                              pendingCount: _vm.pendingClerkCount,
                              onOpenInbox: widget.onOpenClerkInbox,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  _KpiGrid(metrics: metrics),
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
                  _RecentInvoicesSection(
                    invoices: metrics.recentInvoices,
                    restaurantNameBuilder: _vm.restaurantDisplayName,
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
      actions: [
        IconButton(
          key: const Key('btn_dashboard_notify_toggle'),
          tooltip: 'Notification Center (${_vm.activeAlerts.length})',
          onPressed: _openNotificationCenter,
          icon: Badge.count(
            count: _vm.activeAlerts.length,
            isLabelVisible: _vm.activeAlerts.isNotEmpty,
            backgroundColor: _vm.hasUpdateAvailable
                ? AppTheme.info
                : AppTheme.warning,
            child: Icon(
              _vm.activeAlerts.isNotEmpty || _vm.overdueNotificationsEnabled
                  ? Icons.notifications_active
                  : Icons.notifications_none_outlined,
              color: _vm.overdueNotificationsEnabled || _vm.activeAlerts.isNotEmpty
                  ? const Color(0xFFBBF7D0)
                  : Colors.white,
            ),
          ),
        ),
        IconButton(
          key: const Key('btn_dashboard_sync'),
          tooltip: 'Sync encrypted vault',
          onPressed: _vm.isSyncing ? null : _vm.refresh,
          icon: _vm.isSyncing
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
        PopupMenuButton<_DashboardMenuAction>(
          key: const Key('btn_dashboard_menu'),
          tooltip: 'Account & Tools',
          icon: CircleAvatar(
            radius: 15,
            backgroundColor: AppTheme.leafGreen,
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
      ],
    );
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
  const _KpiGrid({required this.metrics});

  final DashboardMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final marginText = metrics.thisMonthMarginPercent != null
        ? '${metrics.thisMonthMarginPercent!.toStringAsFixed(1)}% margin'
        : 'No margin data yet';
    final pendingSubtitle = metrics.overdueBillsCount > 0
        ? '${metrics.overdueBillsCount} overdue · KES ${DashboardViewModel.formatMoney(metrics.pendingBillsAmount)}'
        : 'KES ${DashboardViewModel.formatMoney(metrics.pendingBillsAmount)}';

    final cards = [
      _KpiCardData(
        key: const Key('kpi_revenue'),
        title: 'Revenue (Month)',
        value: 'KES ${DashboardViewModel.formatMoney(metrics.thisMonthRevenue)}',
        subtitle:
            '${metrics.thisMonthInvoiceCount} ${metrics.thisMonthInvoiceCount == 1 ? 'invoice' : 'invoices'}',
        icon: Icons.trending_up_rounded,
        accentColor: AppTheme.forestGreen,
        tintColor: AppTheme.sageTint,
      ),
      _KpiCardData(
        key: const Key('kpi_profit'),
        title: 'Net Profit',
        value: 'KES ${DashboardViewModel.formatMoney(metrics.thisMonthProfit)}',
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
    this.onOpenInvoice,
    this.onCreateInvoice,
  });

  final List<Invoice> invoices;
  final String Function(Invoice invoice) restaurantNameBuilder;
  final void Function(Invoice invoice)? onOpenInvoice;
  final VoidCallback? onCreateInvoice;

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
                if (onCreateInvoice != null)
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
                      child: const Icon(Icons.description_outlined, size: 19),
                    ),
                    title: Text(
                      '$restName · ${inv.number}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    subtitle: Text(
                      '${inv.date} · Profit KES ${DashboardViewModel.formatMoney(inv.profit)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'KES ${DashboardViewModel.formatMoney(inv.totalSell)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppTheme.slateInk,
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

class _DeveloperPreviewRibbon extends StatelessWidget {
  const _DeveloperPreviewRibbon({
    required this.redesignedEnabled,
    this.onToggle,
  });

  final bool redesignedEnabled;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('dev_preview_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFA7F3D0)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.science_outlined,
            size: 18,
            color: Color(0xFF0F3D24),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Developer Preview · v1.2.0',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F3D24),
                  ),
                ),
                Text(
                  'Visible only to onderegerald@gmail.com before rollout',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF047857),
                  ),
                ),
              ],
            ),
          ),
          if (onToggle != null)
            ActionChip(
              key: const Key('btn_toggle_dev_ui_mode'),
              label: Text(redesignedEnabled ? 'UI v2' : 'Classic'),
              onPressed: onToggle,
            ),
        ],
      ),
    );
  }
}

class _ExecutiveHeroCard extends StatelessWidget {
  const _ExecutiveHeroCard({
    required this.metrics,
    this.onCreateInvoice,
    this.onOpenKraTaxCenter,
    this.onOpenStatements,
    this.onOpenExpenses,
  });

  final DashboardMetrics metrics;
  final VoidCallback? onCreateInvoice;
  final VoidCallback? onOpenKraTaxCenter;
  final VoidCallback? onOpenStatements;
  final VoidCallback? onOpenExpenses;

  @override
  Widget build(BuildContext context) {
    final total = metrics.thisMonthInvoiceCount;
    final paid = metrics.thisMonthPaidCount;
    final ratio = total > 0 ? (paid / total).clamp(0.0, 1.0) : 0.0;
    final marginLabel = metrics.thisMonthMarginPercent != null
        ? '${metrics.thisMonthMarginPercent!.toStringAsFixed(1)}% margin'
        : 'Margin N/A';

    return Container(
      key: const Key('dev_executive_hero_card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F3D24), Color(0xFF166534)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x220F3D24),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  marginLabel,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'KES ${DashboardViewModel.formatMoney(metrics.thisMonthRevenue)}',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Net Profit: KES ${DashboardViewModel.formatMoney(metrics.thisMonthProfit)} · $paid/$total settled',
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFD1FAE5),
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF86EFAC)),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _HeroActionPill(
                icon: Icons.add_box_outlined,
                label: 'Invoice',
                onTap: onCreateInvoice,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
                icon: Icons.qr_code_2,
                label: 'eTIMS Tax',
                onTap: onOpenKraTaxCenter,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
                icon: Icons.description_outlined,
                label: 'Statements',
                onTap: onOpenStatements,
              ),
              const SizedBox(width: 8),
              _HeroActionPill(
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
