import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/user_friendly_error.dart';
import 'background_update_worker.dart';
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
    SmartNotificationGateway? smartNotificationGateway,
    this._updateService,
    this._updateManifestUrl = ttgDefaultManifestUrl,
    ExcelExporter? excelExporter,
    DateTime Function()? clock,
  })  : _vault = vaultRepository,
        _auth = authRepository,
        _staging = stagingRepository,
        _storage = localStorage,
        _notifications =
            notificationGateway ?? FlutterLocalOverdueNotificationGateway(),
        _explicitSmartNotifications = smartNotificationGateway,
        _excelExporter = excelExporter ?? ExcelExporter(),
        _clock = clock ?? DateTime.now {
    _vault.addListener(_onDependencyChanged);
    _staging.addListener(_onDependencyChanged);
    _auth.addListener(_onDependencyChanged);
  }

  static const String keyOverdueNotifications = 'ttg_overdue_notifications';
  static const String keyLastPendingNotificationAt = 'ttg_last_pending_notif_at';
  static const String keyLastUpdateCheckAt = 'ttg_last_update_check_at';
  static const String keyLastNotifiedClerkSig = 'ttg_last_notified_clerk_sig';
  static const String keyLastNotifiedPayrollMonth = 'ttg_last_notified_payroll_month';
  static const String keyLastNotifiedRecurringMonth = 'ttg_last_notified_recurring_month';
  static const String keyLastNotifiedStatementMonth = 'ttg_last_notified_statement_month';
  static const Duration pendingNotificationCooldown = Duration(hours: 24);
  static const Duration silentUpdateCheckInterval = Duration(hours: 12);

  final VaultRepository _vault;
  final AuthRepository _auth;
  final StagingRepository _staging;
  final LocalStorageService? _storage;
  final OverdueNotificationGateway _notifications;
  final SmartNotificationGateway? _explicitSmartNotifications;
  final RemoteUpdateService? _updateService;
  final String _updateManifestUrl;
  final ExcelExporter _excelExporter;
  final DateTime Function() _clock;

  SmartNotificationGateway? get _smartNotifications {
    if (_explicitSmartNotifications != null) return _explicitSmartNotifications;
    final n = _notifications;
    return n is SmartNotificationGateway ? n as SmartNotificationGateway : null;
  }

  bool _isLoading = false;
  bool _isSyncing = false;
  bool _isExporting = false;
  bool _overdueNotificationsEnabled = false;
  NotificationPreferences _notificationPrefs = const NotificationPreferences();
  UpdateCheckResult? _availableUpdate;
  bool _biometricEnabled = false;
  bool _canUseBiometrics = false;
  String? _userEmail;
  String? _statusMessage;
  String? _errorMessage;

  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing || _vault.isSyncing;
  bool get isExporting => _isExporting;
  bool get overdueNotificationsEnabled => _overdueNotificationsEnabled;
  NotificationPreferences get notificationPrefs => _notificationPrefs;
  UpdateCheckResult? get availableUpdate => _availableUpdate;
  bool get hasUpdateAvailable => _availableUpdate?.updateAvailable == true;
  bool get biometricEnabled => _biometricEnabled;
  bool get canUseBiometrics => _canUseBiometrics;
  String? get userEmail => _userEmail;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  int get pendingClerkCount => _staging.pendingCount;
  VaultSettings get vaultSettings => _vault.settings;

  /// Actionable feed of live business, sync, and update alerts for the
  /// Smart Notification Center.
  List<NotificationAlertItem> get activeAlerts {
    final alerts = <NotificationAlertItem>[];
    final now = _clock();
    final thisMonth = DateFormat('yyyy-MM').format(now);
    final update = _availableUpdate;

    if (update != null && update.updateAvailable && update.manifest != null) {
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.appUpdates,
          title: 'App Update v${update.manifest!.version} Available',
          body: update.manifest!.releaseNotes.trim().isNotEmpty
              ? update.manifest!.releaseNotes.trim()
              : 'Tap Update to download and install the verified release.',
          severity: NotificationSeverity.info,
          actionLabel: 'Update',
        ),
      );
    }

    if (pendingClerkCount > 0) {
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.clerkSubmissions,
          title:
              '$pendingClerkCount Clerk Docket${pendingClerkCount == 1 ? '' : 's'} Pending Review',
          body: 'Submitted delivery dockets are waiting in your Clerks Inbox.',
          severity: NotificationSeverity.warning,
          actionLabel: 'Review',
        ),
      );
    }

    final nonDrafts = _vault.invoices.where((i) => !i.isDraft).toList();
    final overdueInvoices = nonDrafts.where((i) {
      if (i.status == 'paid') return false;
      if (i.status == 'overdue') return true;
      final due = AppHelpers.parseAppDate(i.dueDate);
      if (due != null && due.isBefore(now)) return true;
      final invDate = AppHelpers.parseAppDate(i.date);
      return invDate != null && now.difference(invDate).inDays > 30;
    }).toList();

    if (overdueInvoices.isNotEmpty) {
      final overdueAmt =
          overdueInvoices.fold<double>(0, (s, i) => s + i.totalSell);
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.overdueInvoices,
          title:
              '${overdueInvoices.length} Overdue Invoice${overdueInvoices.length == 1 ? '' : 's'}',
          body:
              'KES ${formatMoney(overdueAmt)} overdue (>30 days or past due date).',
          severity: NotificationSeverity.urgent,
          actionLabel: 'View',
        ),
      );
    } else if (metrics.pendingBillsCount > 0) {
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.overdueInvoices,
          title: '${metrics.pendingBillsCount} Pending Bills Awaiting Settlement',
          body:
              'Total unsettled amount: KES ${formatMoney(metrics.pendingBillsAmount)}.',
          severity: NotificationSeverity.info,
          actionLabel: 'View',
        ),
      );
    }

    final unpaidSalaries = _dueUnpaidStaff(now, thisMonth);
    if (unpaidSalaries.isNotEmpty) {
      final totalSal = unpaidSalaries.fold<double>(0, (s, x) => s + x.salary);
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.payrollDue,
          title:
              '${unpaidSalaries.length} Staff Salar${unpaidSalaries.length == 1 ? 'y' : 'ies'} Due',
          body:
              '${unpaidSalaries.map((s) => s.name).join(', ')} - KES ${formatMoney(totalSal)} due this month.',
          severity: NotificationSeverity.urgent,
          actionLabel: 'Payroll',
        ),
      );
    }

    final recurringDue = _dueRecurringExpenses(now, thisMonth);
    if (recurringDue.isNotEmpty) {
      final totalRec = recurringDue.fold<double>(0, (s, r) => s + r.amount);
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.recurringBills,
          title:
              '${recurringDue.length} Recurring Bill${recurringDue.length == 1 ? '' : 's'} Due',
          body:
              '${recurringDue.map((r) => r.desc).join(', ')} (KES ${formatMoney(totalRec)}).',
          severity: NotificationSeverity.warning,
          actionLabel: 'Pay',
        ),
      );
    }

    if (_vault.lastSyncError != null && _vault.lastSyncError!.trim().isNotEmpty) {
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.syncHealth,
          title: 'Cloud Sync Needs Retry',
          body: UserFriendlyError.format(
            _vault.lastSyncError!,
            fallback: 'Local edits are safe and waiting for internet sync.',
          ),
          severity: NotificationSeverity.warning,
          actionLabel: 'Sync',
        ),
      );
    }

    if (now.day <= 5 && nonDrafts.isNotEmpty) {
      alerts.add(
        const NotificationAlertItem(
          category: NotificationCategory.monthlyStatements,
          title: 'Monthly Client Statements Ready',
          body: 'Generate and share last month PDF statements with clients.',
          severity: NotificationSeverity.info,
          actionLabel: 'Statements',
        ),
      );
    }

    final expiringDocs = _vault.personalDocuments
        .where((d) => d.isExpired(now) || d.isExpiringSoon(now))
        .toList();
    if (expiringDocs.isNotEmpty) {
      final expiredCount = expiringDocs.where((d) => d.isExpired(now)).length;
      final firstTitle = expiringDocs.first.title;
      alerts.add(
        NotificationAlertItem(
          category: NotificationCategory.documentExpiry,
          title: expiredCount > 0
              ? '$expiredCount Vault Document${expiredCount == 1 ? '' : 's'} Expired'
              : '${expiringDocs.length} Vault Document${expiringDocs.length == 1 ? '' : 's'} Expiring Soon',
          body:
              '"$firstTitle"${expiringDocs.length > 1 ? ' and ${expiringDocs.length - 1} more' : ''} need renewal in Personal Vault.',
          severity: expiredCount > 0
              ? NotificationSeverity.urgent
              : NotificationSeverity.warning,
          actionLabel: 'Vault',
        ),
      );
    }

    return alerts;
  }

  List<Staff> _dueUnpaidStaff(DateTime now, String monthKey) {
    return _vault.staff.where((s) {
      if (s.status != 'active') return false;
      final paid = _vault.salaryPayments
          .any((p) => p.staffId == s.id && p.month == monthKey);
      if (paid) return false;
      final payDay = int.tryParse(s.payDay) ?? 5;
      return now.day >= payDay;
    }).toList();
  }

  List<RecurringExpense> _dueRecurringExpenses(DateTime now, String monthKey) {
    return _vault.recurringExpenses.where((r) {
      final paid = _vault.expenses.any(
        (e) =>
            e.category == r.category &&
            e.desc == r.desc &&
            e.date.startsWith(monthKey),
      );
      if (paid) return false;
      final dueDay = int.tryParse(r.dueDay) ?? 1;
      return now.day >= dueDay;
    }).toList();
  }

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

    await _loadNotificationPrefs();

    if (syncRemote) {
      await _vault.loadFromSupabase();
    }
    await _staging.getPendingSubmissions();

    await _maybeNotifyPendingBills();
    await _dispatchSmartNotifications();

    if (_updateService != null && _notificationPrefs.appUpdatesEnabled) {
      // Non-blocking silent check so slow networks never delay Dashboard.
      unawaited(runSilentUpdateCheck());
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadNotificationPrefs() async {
    if (_storage == null) return;
    final rawToggle = await _storage.getRaw(keyOverdueNotifications);
    final legacyEnabled = rawToggle == 'true';
    final rawPrefs = await _storage.getRaw(ttgKeyNotifPrefs);
    if (rawPrefs != null && rawPrefs.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPrefs);
        if (decoded is Map) {
          _notificationPrefs = NotificationPreferences.fromJson(
            Map<String, dynamic>.from(decoded),
            legacyOverdueEnabled: legacyEnabled,
          );
          _overdueNotificationsEnabled =
              _notificationPrefs.overdueAlertsEnabled;
          return;
        }
      } catch (_) {}
    }
    _overdueNotificationsEnabled = legacyEnabled;
    _notificationPrefs = NotificationPreferences(
      overdueAlertsEnabled: legacyEnabled,
    );
  }

  Future<void> updateNotificationPrefs(NotificationPreferences next) async {
    _notificationPrefs = next;
    _overdueNotificationsEnabled = next.overdueAlertsEnabled;
    await _storage?.setJson(ttgKeyNotifPrefs, next.toJson());
    await _storage?.setRaw(
      keyOverdueNotifications,
      next.overdueAlertsEnabled ? 'true' : 'false',
    );
    if (next.appUpdatesEnabled ||
        next.clerkAlertsEnabled ||
        next.overdueAlertsEnabled ||
        next.payrollAndBillsEnabled ||
        next.statementAlertsEnabled) {
      await _notifications.initializeAndRequestPermission();
    }
    notifyListeners();
  }

  /// Checks `app-update.json` silently without disrupting UI on errors.
  Future<void> runSilentUpdateCheck({bool force = false}) async {
    final updater = _updateService;
    if (updater == null || !_notificationPrefs.appUpdatesEnabled) return;
    if (_updateManifestUrl.trim().isEmpty) return;

    final now = _clock();
    if (!force && _storage != null) {
      final rawLast = await _storage.getRaw(keyLastUpdateCheckAt);
      final lastAt = DateTime.tryParse(rawLast ?? '');
      if (lastAt != null) {
        final elapsed = now.difference(lastAt);
        if (!elapsed.isNegative && elapsed < silentUpdateCheckInterval) {
          return;
        }
      }
    }

    try {
      final result = await updater
          .checkForUpdate(_updateManifestUrl)
          .timeout(const Duration(seconds: 6));
      await _storage?.setRaw(
        keyLastUpdateCheckAt,
        now.toUtc().toIso8601String(),
      );
      _availableUpdate = result;

      final manifest = result.manifest;
      if (result.updateAvailable && manifest != null) {
        final rawLastBuild =
            await _storage?.getRaw(ttgKeyLastNotifiedUpdateBuild);
        final lastBuild = int.tryParse(rawLastBuild ?? '') ?? 0;
        if (manifest.buildNumber > lastBuild) {
          await _smartNotifications?.showCategoryNotification(
            category: NotificationCategory.appUpdates,
            title: 'App Update Available (v${manifest.version})',
            body:
                'Tap to download and install the latest Town Treasure Groceries release.',
          );
          await _storage?.setRaw(
            ttgKeyLastNotifiedUpdateBuild,
            manifest.buildNumber.toString(),
          );
        }
      }
      notifyListeners();
    } catch (_) {
      // Silent update checks never surface offline errors to the user.
    }
  }

  Future<void> _dispatchSmartNotifications() async {
    final smart = _smartNotifications;
    if (smart == null) return;
    final now = _clock();
    final monthKey = DateFormat('yyyy-MM').format(now);

    if (_notificationPrefs.clerkAlertsEnabled && pendingClerkCount > 0) {
      final pendingIds = _staging.cachedSubmissions
          .where((d) => d.status == 'pending')
          .map((d) => d.id)
          .toList()
        ..sort();
      final sig = pendingIds.join(',');
      final lastSig = await _storage?.getRaw(keyLastNotifiedClerkSig) ?? '';
      if (sig.isNotEmpty && sig != lastSig) {
        await smart.showCategoryNotification(
          category: NotificationCategory.clerkSubmissions,
          title: 'New Clerk Docket${pendingClerkCount == 1 ? '' : 's'} Received',
          body:
              '$pendingClerkCount field docket${pendingClerkCount == 1 ? ' is' : 's are'} waiting for your approval.',
        );
        await _storage?.setRaw(keyLastNotifiedClerkSig, sig);
      }
    }

    if (_notificationPrefs.payrollAndBillsEnabled) {
      final unpaidStaff = _dueUnpaidStaff(now, monthKey);
      if (unpaidStaff.isNotEmpty) {
        final lastMonth =
            await _storage?.getRaw(keyLastNotifiedPayrollMonth) ?? '';
        if (lastMonth != monthKey) {
          final totalSal =
              unpaidStaff.fold<double>(0, (s, x) => s + x.salary);
          await smart.showCategoryNotification(
            category: NotificationCategory.payrollDue,
            title: 'Staff Salaries Due ($monthKey)',
            body:
                '${unpaidStaff.length} staff salar${unpaidStaff.length == 1 ? 'y' : 'ies'} totaling KES ${formatMoney(totalSal)} due.',
          );
          await _storage?.setRaw(keyLastNotifiedPayrollMonth, monthKey);
        }
      }

      final recurringDue = _dueRecurringExpenses(now, monthKey);
      if (recurringDue.isNotEmpty) {
        final lastMonth =
            await _storage?.getRaw(keyLastNotifiedRecurringMonth) ?? '';
        if (lastMonth != monthKey) {
          final totalRec =
              recurringDue.fold<double>(0, (s, r) => s + r.amount);
          await smart.showCategoryNotification(
            category: NotificationCategory.recurringBills,
            title: 'Recurring Bills Due',
            body:
                '${recurringDue.length} recurring bill${recurringDue.length == 1 ? '' : 's'} (KES ${formatMoney(totalRec)}) due this month.',
          );
          await _storage?.setRaw(keyLastNotifiedRecurringMonth, monthKey);
        }
      }
    }

    if (_notificationPrefs.statementAlertsEnabled &&
        now.day <= 5 &&
        _vault.invoices.any((i) => !i.isDraft)) {
      final lastStmtMonth =
          await _storage?.getRaw(keyLastNotifiedStatementMonth) ?? '';
      if (lastStmtMonth != monthKey) {
        await smart.showCategoryNotification(
          category: NotificationCategory.monthlyStatements,
          title: 'Monthly Statements Ready to Send',
          body: 'Send monthly account statements to hotel and restaurant clients.',
        );
        await _storage?.setRaw(keyLastNotifiedStatementMonth, monthKey);
      }
    }
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
    await _dispatchSmartNotifications();
    if (_notificationPrefs.appUpdatesEnabled) {
      unawaited(runSilentUpdateCheck());
    }

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
      _notificationPrefs = _notificationPrefs.copyWith(
        overdueAlertsEnabled: false,
      );
      await _storage?.setJson(ttgKeyNotifPrefs, _notificationPrefs.toJson());
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
      _notificationPrefs = _notificationPrefs.copyWith(
        overdueAlertsEnabled: false,
      );
      await _storage?.setJson(ttgKeyNotifPrefs, _notificationPrefs.toJson());
      await _storage?.setRaw(keyOverdueNotifications, 'false');
      _errorMessage = 'Notification permission was denied.';
      notifyListeners();
      return false;
    }

    _overdueNotificationsEnabled = true;
    _notificationPrefs = _notificationPrefs.copyWith(
      overdueAlertsEnabled: true,
    );
    await _storage?.setJson(ttgKeyNotifPrefs, _notificationPrefs.toJson());
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
