import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';

import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/cloudflare_backend_service.dart';
import '../../../data/services/crypto_service.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../data/services/supabase_service.dart';
import '../../../domain/models/models.dart';
import '../../core/developer_preview.dart';
import 'overdue_notification_service.dart';

const String ttgBackgroundUpdateTask = 'ttg_periodic_update_check';
const String ttgBackgroundOneOffTestTask = 'ttg_background_alert_test';
const String ttgDefaultManifestUrl =
    'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json';
const String ttgKeyNotifPrefs = 'ttg_notif_prefs';
const String ttgKeyLastNotifiedUpdateBuild = 'ttg_last_notified_update_build';
const String ttgKeyLastBgRunAt = 'ttg_last_bg_run_at';
const String ttgKeyLastBgRunStatus = 'ttg_last_bg_run_status';
const String ttgKeyBgWorkerVersion = 'ttg_bg_worker_version';

@pragma('vm:entry-point')
void ttgBackgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    LocalStorageService? storage;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      if (task != ttgBackgroundUpdateTask && task != ttgBackgroundOneOffTestTask) {
        return true;
      }

      storage = LocalStorageService();
      await storage.init();
      final notifier = FlutterLocalOverdueNotificationGateway();
      await notifier.initializeForBackground();

      try {
        try {
          await SupabaseService.initialize();
        } catch (_) {
          // Offline / background start without Supabase stays safe for local checks.
        }
        final supabase = CloudflareBackendService(
          authGateway: SupabaseService(),
        );
        final vault = VaultRepository(
          cryptoService: CryptoService(),
          localStorage: storage,
          supabase: supabase,
        );
        await vault.loadFromLocalCache();

        final manifestUrl =
            (inputData?['manifestUrl'] as String?)?.trim() ?? '';

        await BackgroundAlertRunner.runCheck(
          storage: storage,
          vault: vault,
          supabase: supabase,
          updateService: RemoteUpdateService(),
          overdueNotifier: notifier,
          smartNotifier: notifier,
          manifestUrl: manifestUrl.isNotEmpty ? manifestUrl : ttgDefaultManifestUrl,
        );
        if (task == ttgBackgroundOneOffTestTask) {
          await notifier.showCategoryNotification(
            category: NotificationCategory.syncHealth,
            title: 'Background Alerts Active',
            body:
                'Town Treasure background monitoring ran successfully while the app was closed.',
          );
        }
        await storage.setRaw(
          ttgKeyLastBgRunAt,
          DateTime.now().toUtc().toIso8601String(),
        );
        await storage.setRaw(ttgKeyLastBgRunStatus, 'ok');
        vault.dispose();
      } catch (e) {
        await storage.setRaw(
          ttgKeyLastBgRunAt,
          DateTime.now().toUtc().toIso8601String(),
        );
        await storage.setRaw(
          ttgKeyLastBgRunStatus,
          'error: ${e.toString().split('\n').first}',
        );
      } finally {
        // Keep the shared SQLite handle open so foreground VaultRepository never hits database_closed.
      }
    } catch (e) {
      try {
        await storage?.setRaw(
          ttgKeyLastBgRunAt,
          DateTime.now().toUtc().toIso8601String(),
        );
        await storage?.setRaw(ttgKeyLastBgRunStatus, 'error: $e');
      } catch (_) {}
    }
    return true;
  });
}

const String ttgKeyNotifiedBuildCompat = ttgKeyLastNotifiedUpdateBuild;

/// Executes all smart alert checks inside Android's WorkManager background isolate
/// (and unit tests) so overdue bills, new clerk dockets, payroll, recurring bills,
/// statements, and app updates fire even when the app is completely closed.
class BackgroundAlertRunner {
  BackgroundAlertRunner._();

  static const String _keyLegacyOverdue = 'ttg_overdue_notifications';
  static const String _keyLastPendingAt = 'ttg_last_pending_notif_at';
  static const String _keyLastUpdateCheckAt = 'ttg_last_update_check_at';
  static const String _keyLastClerkSig = 'ttg_last_notified_clerk_sig';
  static const String _keyLastPayrollMonth = 'ttg_last_notified_payroll_month';
  static const String _keyLastRecurringMonth = 'ttg_last_notified_recurring_month';
  static const String _keyLastStatementMonth = 'ttg_last_notified_statement_month';

  static Future<void> runCheck({
    required LocalStorageService storage,
    required VaultRepository vault,
    required SupabaseGateway supabase,
    required RemoteUpdateService updateService,
    required OverdueNotificationGateway overdueNotifier,
    required SmartNotificationGateway smartNotifier,
    String manifestUrl = ttgDefaultManifestUrl,
    DateTime Function()? clock,
  }) async {
    final now = (clock ?? DateTime.now)();
    final monthKey = DateFormat('yyyy-MM').format(now);
    final prefs = await _loadPrefs(storage);
    final moneyFmt = NumberFormat('#,##0.00', 'en_US');

    // 1. Offline-capable checks from encrypted local cache (no internet needed)
    final nonDrafts = vault.invoices.where((i) => !i.isDraft).toList();
    if (prefs.overdueAlertsEnabled) {
      final pendingBills = nonDrafts
          .where((i) => i.status == 'pending' || i.status == 'overdue')
          .toList();
      final overdueCount = pendingBills.where((i) {
        if (i.status == 'overdue') return true;
        final due = AppHelpers.parseAppDate(i.dueDate);
        if (due != null && due.isBefore(now)) return true;
        final invDate = AppHelpers.parseAppDate(i.date);
        return invDate != null && now.difference(invDate).inDays > 30;
      }).length;
      if (pendingBills.isNotEmpty) {
        final rawLast = await storage.getRaw(_keyLastPendingAt);
        final lastAt = DateTime.tryParse(rawLast ?? '');
        final inCooldown = lastAt != null &&
            !now.difference(lastAt).isNegative &&
            now.difference(lastAt) < const Duration(hours: 24);
        if (!inCooldown) {
          await overdueNotifier.showOverdueSummary(
            overdueCount: overdueCount,
            pendingCount: pendingBills.length,
          );
          await storage.setRaw(
            _keyLastPendingAt,
            now.toUtc().toIso8601String(),
          );
        }
      }
    }

    if (prefs.payrollAndBillsEnabled) {
      final unpaidStaff = vault.staff.where((s) {
        if (s.status != 'active') return false;
        final paid = vault.salaryPayments
            .any((p) => p.staffId == s.id && p.month == monthKey);
        if (paid) return false;
        final payDay = int.tryParse(s.payDay) ?? 5;
        return now.day >= payDay;
      }).toList();
      if (unpaidStaff.isNotEmpty) {
        final lastMonth = await storage.getRaw(_keyLastPayrollMonth) ?? '';
        if (lastMonth != monthKey) {
          final totalSal =
              unpaidStaff.fold<double>(0, (sum, s) => sum + s.salary);
          await smartNotifier.showCategoryNotification(
            category: NotificationCategory.payrollDue,
            title: 'Staff Salaries Due ($monthKey)',
            body:
                '${unpaidStaff.length} staff salar${unpaidStaff.length == 1 ? 'y' : 'ies'} totaling KES ${moneyFmt.format(totalSal)} due.',
          );
          await storage.setRaw(_keyLastPayrollMonth, monthKey);
        }
      }

      final dueRecurring = vault.recurringExpenses.where((r) {
        final paid = vault.expenses.any(
          (e) =>
              e.category == r.category &&
              e.desc == r.desc &&
              e.date.startsWith(monthKey),
        );
        if (paid) return false;
        final dueDay = int.tryParse(r.dueDay) ?? 1;
        return now.day >= dueDay;
      }).toList();
      if (dueRecurring.isNotEmpty) {
        final lastMonth = await storage.getRaw(_keyLastRecurringMonth) ?? '';
        if (lastMonth != monthKey) {
          final totalRec =
              dueRecurring.fold<double>(0, (sum, r) => sum + r.amount);
          await smartNotifier.showCategoryNotification(
            category: NotificationCategory.recurringBills,
            title: 'Recurring Bills Due ($monthKey)',
            body:
                '${dueRecurring.length} recurring expense${dueRecurring.length == 1 ? '' : 's'} totaling KES ${moneyFmt.format(totalRec)} pending.',
          );
          await storage.setRaw(_keyLastRecurringMonth, monthKey);
        }
      }

      final dueLoans = vault.settings.companyLoans.where((loan) {
        if (loan.isFullySettled || loan.isPaidForMonth(monthKey)) return false;
        final alertFromDay = (loan.debitDayOfMonth - 3).clamp(1, 28);
        return now.day >= alertFromDay;
      }).toList();
      if (dueLoans.isNotEmpty) {
        const loanAlertKey = 'ttg_last_notified_bank_loan_month';
        final lastLoanMonth = await storage.getRaw(loanAlertKey) ?? '';
        if (lastLoanMonth != monthKey) {
          final totalDue =
              dueLoans.fold<double>(0, (sum, l) => sum + l.monthlyInstallment);
          final names = dueLoans.map((l) => l.lenderName).toSet().join(', ');
          await smartNotifier.showCategoryNotification(
            category: NotificationCategory.recurringBills,
            title: 'Bank Facility Installment Due ($monthKey)',
            body:
                '$names monthly deduction of KES ${moneyFmt.format(totalDue)} is approaching. Ensure operating account float is ready.',
          );
          await storage.setRaw(loanAlertKey, monthKey);
        }
      }
    }

    if (prefs.statementAlertsEnabled && now.day <= 5 && nonDrafts.isNotEmpty) {
      final lastMonth = await storage.getRaw(_keyLastStatementMonth) ?? '';
      if (lastMonth != monthKey) {
        await smartNotifier.showCategoryNotification(
          category: NotificationCategory.monthlyStatements,
          title: 'Monthly Client Statements Ready',
          body:
              'New month started. Open Statements to generate and share client summaries.',
        );
        await storage.setRaw(_keyLastStatementMonth, monthKey);
      }
    }

    final expiringDocs = vault.settings.personalDocuments
        .where((d) => d.isExpired(now) || d.isExpiringSoon(now))
        .toList();
    if (expiringDocs.isNotEmpty) {
      final todayKey = DateFormat('yyyy-MM-dd').format(now);
      const lastDocKey = 'ttg_last_doc_expiry_notif_day';
      final lastDay = await storage.getRaw(lastDocKey) ?? '';
      if (lastDay != todayKey) {
        final expiredCount = expiringDocs.where((d) => d.isExpired(now)).length;
        await smartNotifier.showCategoryNotification(
          category: NotificationCategory.documentExpiry,
          title: expiredCount > 0
              ? '$expiredCount Personal Vault Doc${expiredCount == 1 ? '' : 's'} Expired'
              : '${expiringDocs.length} Vault Doc${expiringDocs.length == 1 ? '' : 's'} Expiring Soon',
          body:
              '${expiringDocs.first.title} needs attention in your encrypted Personal Vault.',
        );
        await storage.setRaw(lastDocKey, todayKey);
      }
    }

    // 2. Remote Field Clerk Dockets check (every ~30 min when online & signed in)
    if (prefs.clerkAlertsEnabled) {
      try {
        final currentUser = await supabase.getCurrentUser();
        final userId = currentUser?.id ?? await storage.getUserId();
        final userEmail = currentUser?.email ?? await storage.getUserEmail();
        if (currentUser != null && userId != null && userId.isNotEmpty) {
          final rows = await supabase
              .fetchPendingStagedInvoices()
              .timeout(const Duration(seconds: 8));
          final ownedIds = rows
              .map(StagingDocket.fromJson)
              .where(
                (item) =>
                    item.status == 'pending' &&
                    StagingRepository.isSubmissionForUser(
                      item,
                      userId: userId,
                      userEmail: userEmail,
                    ),
              )
              .map((item) => item.id)
              .where((id) => id.isNotEmpty)
              .toList()
            ..sort();
          if (ownedIds.isNotEmpty) {
            final sig = ownedIds.join(',');
            final lastSig = await storage.getRaw(_keyLastClerkSig) ?? '';
            if (sig != lastSig) {
              await smartNotifier.showCategoryNotification(
                category: NotificationCategory.clerkSubmissions,
                title:
                    'New Clerk Docket${ownedIds.length == 1 ? '' : 's'} Received',
                body:
                    '${ownedIds.length} field docket${ownedIds.length == 1 ? ' is' : 's are'} waiting for your approval.',
              );
              await storage.setRaw(_keyLastClerkSig, sig);
            }
          }
        }
      } catch (_) {
        // Offline or auth unavailable — retry silently on next background wake.
      }
    }

    // 3. Silent OTA App Update Check (12-hour interval so checks stay light)
    final bgEmail =
        (await supabase.getCurrentUser())?.email ?? await storage.getUserEmail();
    final effectiveManifestUrl = DeveloperPreviewConfig.resolveManifestUrl(
      bgEmail,
      manifestUrl,
    );
    if (prefs.appUpdatesEnabled && effectiveManifestUrl.trim().isNotEmpty) {
      try {
        final rawLastCheck = await storage.getRaw(_keyLastUpdateCheckAt);
        final lastCheck = DateTime.tryParse(rawLastCheck ?? '');
        final checkedRecently = lastCheck != null &&
            !now.difference(lastCheck).isNegative &&
            now.difference(lastCheck) < const Duration(hours: 12);
        if (!checkedRecently) {
          final check = await updateService
              .checkForUpdate(effectiveManifestUrl)
              .timeout(const Duration(seconds: 10));
          await storage.setRaw(
            _keyLastUpdateCheckAt,
            now.toUtc().toIso8601String(),
          );
          final manifest = check.manifest;
          if (check.updateAvailable && manifest != null) {
            final rawLastBuild =
                await storage.getRaw(ttgKeyLastNotifiedUpdateBuild);
            final lastBuild = int.tryParse(rawLastBuild ?? '') ?? 0;
            if (manifest.buildNumber > lastBuild) {
              await smartNotifier.showCategoryNotification(
                category: NotificationCategory.appUpdates,
                title: 'App Update Available (v${manifest.version})',
                body:
                    'A new Town Treasure Groceries release is ready. Tap to download and install.',
              );
              await storage.setRaw(
                ttgKeyLastNotifiedUpdateBuild,
                manifest.buildNumber.toString(),
              );
            }
          }
        }
      } catch (_) {
        // Retry silently on next background wake.
      }
    }
  }

  static Future<NotificationPreferences> _loadPrefs(
    LocalStorageService storage,
  ) async {
    final legacyEnabled = await storage.getRaw(_keyLegacyOverdue) == 'true';
    final rawPrefs = await storage.getRaw(ttgKeyNotifPrefs);
    if (rawPrefs != null && rawPrefs.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPrefs);
        if (decoded is Map) {
          return NotificationPreferences.fromJson(
            Map<String, dynamic>.from(decoded),
            legacyOverdueEnabled: legacyEnabled,
          );
        }
      } catch (_) {}
    }
    return NotificationPreferences(overdueAlertsEnabled: legacyEnabled);
  }
}

/// Schedules Android WorkManager background monitoring every 15 minutes so
/// clerk dockets, overdue bills, payroll, recurring bills, statements, and app
/// updates notify Veronica even when the app is completely closed or inactive.
class BackgroundUpdateWorker {
  BackgroundUpdateWorker._();

  static bool _workerInitialized = false;

  static Future<void> _ensureWorkerInitialized() async {
    if (_workerInitialized) return;
    await Workmanager().initialize(ttgBackgroundCallbackDispatcher);
    _workerInitialized = true;
  }

  static Future<void> initializeAndSchedule({
    String manifestUrl = ttgDefaultManifestUrl,
    LocalStorageService? localStorage,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ensureWorkerInitialized();
      final storage = localStorage ?? LocalStorageService();
      if (localStorage == null) {
        await storage.init();
      }
      final currentVer = await storage.getRaw(ttgKeyBgWorkerVersion) ?? '';
      final policy = currentVer == '2'
          ? ExistingPeriodicWorkPolicy.keep
          : ExistingPeriodicWorkPolicy.update;
      await Workmanager().registerPeriodicTask(
        ttgBackgroundUpdateTask,
        ttgBackgroundUpdateTask,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: policy,
        backoffPolicy: BackoffPolicy.exponential,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
        ),
        inputData: <String, dynamic>{'manifestUrl': manifestUrl},
      );
      if (currentVer != '2') {
        await storage.setRaw(ttgKeyBgWorkerVersion, '2');
      }
    } catch (_) {
      // Never block app startup if background scheduler is unavailable.
    }
  }

  /// Schedules a 10-second one-off WorkManager task so the user can close the
  /// app and verify real closed-app OS notifications end-to-end.
  static Future<void> scheduleOneOffVerificationTest({
    String manifestUrl = ttgDefaultManifestUrl,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _ensureWorkerInitialized();
    await Workmanager().registerOneOffTask(
      'ttg_bg_test_once',
      ttgBackgroundOneOffTestTask,
      initialDelay: const Duration(seconds: 10),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      inputData: <String, dynamic>{'manifestUrl': manifestUrl},
    );
  }
}
