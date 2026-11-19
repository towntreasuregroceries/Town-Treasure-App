import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/user_friendly_error.dart';
import 'excel_exporter.dart';
import 'overdue_notification_service.dart';

/// Immutable snapshot of Dashboard KPIs and recent activity.
class DashboardMetrics {
  const DashboardMetrics({
    required this.thisMonthRevenue,
    required this.thisMonthProfit,
    required this.thisMonthMarginPercent,
    required this.thisMonthInvoiceCount,
    required this.thisMonthPaidCount,
    required this.pendingBillsCount,
    required this.overdueBillsCount,
    required this.pendingBillsAmount,
    required this.recentInvoices,
  });

  final double thisMonthRevenue;
  final double thisMonthProfit;
  final double? thisMonthMarginPercent;
  final int thisMonthInvoiceCount;
  final int thisMonthPaidCount;
  final int pendingBillsCount;
  final int overdueBillsCount;
  final double pendingBillsAmount;
  final List<Invoice> recentInvoices;
}

/// ViewModel for the Town Treasure Dashboard, mirroring `dashboard.js`,
/// `app.js`, `signature.js`, and `data.js`.
class DashboardViewModel extends ChangeNotifier {
  DashboardViewModel({
    required VaultRepository vaultRepository,
    required AuthRepository authRepository,
    required StagingRepository stagingRepository,
    LocalStorageService? localStorage,
    OverdueNotificationGateway? notificationGateway,
    ExcelExporter? excelExporter,
    DateTime Function()? clock,
  })  : _vault = vaultRepository,
        _auth = authRepository,
        _staging = stagingRepository,
        _storage = localStorage,
        _notifications =
            notificationGateway ?? FlutterLocalOverdueNotificationGateway(),
        _excelExporter = excelExporter ?? ExcelExporter(),
        _clock = clock ?? DateTime.now {
    _vault.addListener(_onDependencyChanged);
    _staging.addListener(_onDependencyChanged);
    _auth.addListener(_onDependencyChanged);
  }

  static const String keyOverdueNotifications = 'ttg_overdue_notifications';
  static const String keyLastPendingNotificationAt = 'ttg_last_pending_notif_at';
  static const Duration pendingNotificationCooldown = Duration(hours: 24);

  final VaultRepository _vault;
  final AuthRepository _auth;
  final StagingRepository _staging;
  final LocalStorageService? _storage;
  final OverdueNotificationGateway _notifications;
  final ExcelExporter _excelExporter;
  final DateTime Function() _clock;

  bool _isLoading = false;
  bool _isSyncing = false;
  bool _isExporting = false;
  bool _overdueNotificationsEnabled = false;
  bool _biometricEnabled = false;
  bool _canUseBiometrics = false;
  String? _userEmail;
  String? _statusMessage;
  String? _errorMessage;

  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing || _vault.isSyncing;
  bool get isExporting => _isExporting;
  bool get overdueNotificationsEnabled => _overdueNotificationsEnabled;
  bool get biometricEnabled => _biometricEnabled;
  bool get canUseBiometrics => _canUseBiometrics;
  String? get userEmail => _userEmail;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  int get pendingClerkCount => _staging.pendingCount;
  VaultSettings get vaultSettings => _vault.settings;

  String get userInitials {
    final email = (_userEmail ?? '').trim();
    if (email.isEmpty) return 'TT';
    final prefix = email.split('@').first;
    if (prefix.isEmpty) return 'TT';
    return prefix.substring(0, prefix.length >= 2 ? 2 : 1).toUpperCase();
  }

  String restaurantDisplayName(Invoice invoice) {
    return Restaurant.invoiceDisplayName(invoice, _vault.restaurants);
  }

  static String formatMoney(double amount) {
    return NumberFormat('#,##0.00', 'en_US').format(amount);
  }

  /// Computes KPIs and recent invoices matching `refreshDashboard()` in `dashboard.js`.
  DashboardMetrics get metrics {
    final now = _clock();
    final nonDrafts = _vault.invoices.where((i) => !i.isDraft).toList();

    final thisMonth = nonDrafts.where((inv) {
      final parsed = AppHelpers.parseAppDate(inv.date);
      if (parsed == null) return false;
      return parsed.month == now.month && parsed.year == now.year;
    }).toList();

    final totalSales =
        thisMonth.fold<double>(0, (sum, inv) => sum + inv.totalSell);
    final grossProfit =
        thisMonth.fold<double>(0, (sum, inv) => sum + inv.profit);
    final thisMonthExpenses = _vault.expenses.where((exp) {
      if (exp.type != 'expense') return false;
      final parsed = AppHelpers.parseAppDate(exp.date);
      if (parsed == null) return false;
      return parsed.month == now.month && parsed.year == now.year;
    }).fold<double>(0, (sum, exp) => sum + exp.amount);

    final netProfit = grossProfit - thisMonthExpenses;
    final marginPercent =
        totalSales > 0 ? (netProfit / totalSales) * 100.0 : null;
    final paidCount = thisMonth.where((i) => i.status == 'paid').length;

    final pendingBills = nonDrafts
        .where((i) => i.status == 'pending' || i.status == 'overdue')
        .toList();
    final overdueCount =
        pendingBills.where((i) => i.status == 'overdue').length;
    final pendingAmount =
        pendingBills.fold<double>(0, (sum, inv) => sum + inv.totalSell);

    final recent = List<Invoice>.from(thisMonth)
      ..sort((a, b) {
        final dateCmp = AppHelpers.appDateKey(b.date)
            .compareTo(AppHelpers.appDateKey(a.date));
        if (dateCmp != 0) return dateCmp;
        return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
      });

    return DashboardMetrics(
      thisMonthRevenue: totalSales,
      thisMonthProfit: netProfit,
      thisMonthMarginPercent: marginPercent,
      thisMonthInvoiceCount: thisMonth.length,
      thisMonthPaidCount: paidCount,
      pendingBillsCount: pendingBills.length,
      overdueBillsCount: overdueCount,
      pendingBillsAmount: pendingAmount,
      recentInvoices: recent.take(8).toList(),
    );
  }

  /// Hydrates identity, preferences, remote vault state, and pending clerk dockets.
  Future<void> initialize({bool syncRemote = true}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    _userEmail = await _auth.getUserEmail();
    _canUseBiometrics = await _auth.canUseBiometrics();
    _biometricEnabled = await _auth.isBiometricEnabled();

    if (_storage != null) {
      final rawToggle = await _storage.getRaw(keyOverdueNotifications);
      _overdueNotificationsEnabled = rawToggle == 'true';
    }

    if (syncRemote) {
      await _vault.loadFromSupabase();
    }
    await _staging.getPendingSubmissions();

    await _maybeNotifyPendingBills();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _maybeNotifyPendingBills({bool force = false}) async {
    if (!_overdueNotificationsEnabled) return;
    final m = metrics;
    if (m.pendingBillsCount == 0 && m.overdueBillsCount == 0) return;

    final now = _clock();
    if (!force && _storage != null) {
      final rawLast = await _storage.getRaw(keyLastPendingNotificationAt);
      final lastAt = DateTime.tryParse(rawLast ?? '');
      if (lastAt != null) {
        final elapsed = now.difference(lastAt);
        if (!elapsed.isNegative && elapsed < pendingNotificationCooldown) {
          return;
        }
      }
    }

    await _notifications.showOverdueSummary(
      overdueCount: m.overdueBillsCount,
      pendingCount: m.pendingBillsCount,
    );
    await _storage?.setRaw(
      keyLastPendingNotificationAt,
      now.toUtc().toIso8601String(),
    );
  }

  Future<void> refresh() async {
    _isSyncing = true;
    _errorMessage = null;
    _statusMessage = null;
    notifyListeners();

    final synced = await _vault.syncNow();
    if (!synced) {
      await _vault.loadFromSupabase();
    }
    await _staging.getPendingSubmissions();

    await _maybeNotifyPendingBills();

    _isSyncing = false;
    _statusMessage = synced
        ? 'Vault synced with cloud.'
        : (_vault.lastSyncError != null
            ? UserFriendlyError.format(
                _vault.lastSyncError!,
                fallback: 'Saved locally; cloud sync will retry later.',
              )
            : 'Refreshed local view.');
    notifyListeners();
  }

  Future<bool> toggleOverdueNotifications(bool enabled) async {
    _errorMessage = null;
    _statusMessage = null;

    if (!enabled) {
      _overdueNotificationsEnabled = false;
      await _storage?.setRaw(keyOverdueNotifications, 'false');
      await _storage?.setRaw(keyLastPendingNotificationAt, '');
      await _notifications.cancelAll();
      _statusMessage = 'Overdue invoice alerts turned off.';
      notifyListeners();
      return true;
    }

    final granted = await _notifications.initializeAndRequestPermission();
    if (!granted) {
      _overdueNotificationsEnabled = false;
      await _storage?.setRaw(keyOverdueNotifications, 'false');
      _errorMessage = 'Notification permission was denied.';
      notifyListeners();
      return false;
    }

    _overdueNotificationsEnabled = true;
    await _storage?.setRaw(keyOverdueNotifications, 'true');

    final m = metrics;
    if (m.pendingBillsCount > 0 || m.overdueBillsCount > 0) {
      await _maybeNotifyPendingBills(force: true);
      _statusMessage =
          'Alerts enabled (${m.pendingBillsCount} pending/overdue invoices). Reminds at most once every 24 hours.';
    } else {
      _statusMessage = 'Overdue invoice alerts enabled.';
    }
    notifyListeners();
    return true;
  }

  Future<bool> toggleBiometricLock(bool enabled) async {
    _errorMessage = null;
    _statusMessage = null;

    if (!enabled) {
      await _auth.setBiometricEnabled(false);
      _biometricEnabled = false;
      _statusMessage = 'Screen lock disabled.';
      notifyListeners();
      return true;
    }

    final supported = await _auth.canUseBiometrics();
    if (!supported) {
      _errorMessage = 'Device biometrics / screen lock are not available.';
      notifyListeners();
      return false;
    }

    final verified = await AppLockGuard.runWithoutRelock(
      () => _auth.authenticateWithBiometrics(
        reason: 'Confirm screen lock to enable quick unlock',
      ),
    );
    if (!verified) {
      _errorMessage = 'Screen lock confirmation failed.';
      notifyListeners();
      return false;
    }

    await _auth.setBiometricEnabled(true);
    _biometricEnabled = true;
    _statusMessage = 'Screen lock enabled.';
    notifyListeners();
    return true;
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _auth.updatePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    _statusMessage = 'Master password updated and vault re-encrypted.';
    notifyListeners();
  }

  Future<void> saveSignature(String? dataUri) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final nextSettings = _vault.settings.copyWith(
      signature: dataUri,
      clearSignature: dataUri == null || dataUri.isEmpty,
      updatedAt: nowIso,
    );
    await _vault.setSettings(nextSettings);
    _statusMessage = dataUri == null || dataUri.isEmpty
        ? 'Signature removed from vault.'
        : 'Signature saved to encrypted vault.';
    notifyListeners();
  }

  Future<File?> exportFullExcel() async {
    _isExporting = true;
    _errorMessage = null;
    _statusMessage = null;
    notifyListeners();

    try {
      final file = await _excelExporter.exportAndShare(_vault);
      _isExporting = false;
      _statusMessage = 'Exported Excel workbook (${file.uri.pathSegments.last}).';
      notifyListeners();
      return file;
    } catch (e) {
      _isExporting = false;
      _errorMessage = 'Excel export failed: $e';
      notifyListeners();
      return null;
    }
  }

  Future<bool> signOut() async {
    _errorMessage = null;
    final ok = await _auth.signOut();
    if (!ok) {
      _errorMessage =
          'Sign out paused: could not sync latest changes. Check your connection and retry.';
      notifyListeners();
    }
    return ok;
  }

  void clearMessages() {
    if (_statusMessage == null && _errorMessage == null) return;
    _statusMessage = null;
    _errorMessage = null;
    notifyListeners();
  }

  void _onDependencyChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _vault.removeListener(_onDependencyChanged);
    _staging.removeListener(_onDependencyChanged);
    _auth.removeListener(_onDependencyChanged);
    super.dispose();
  }
}
