import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';

import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/crypto_service.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../data/services/supabase_service.dart';
import '../../../domain/models/models.dart';
import 'overdue_notification_service.dart';

const String ttgBackgroundUpdateTask = 'ttg_periodic_update_check';
const String ttgDefaultManifestUrl =
    'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json';
const String ttgKeyNotifPrefs = 'ttg_notif_prefs';
const String ttgKeyLastNotifiedUpdateBuild = 'ttg_last_notified_update_build';

@pragma('vm:entry-point')
void ttgBackgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      if (task != ttgBackgroundUpdateTask) return true;

      final storage = LocalStorageService();
      await storage.init();
      try {
        try {
          await SupabaseService.initialize();
        } catch (_) {
          // Offline / background start without Supabase stays safe for local checks.
        }
        final supabase = SupabaseService();
        final vault = VaultRepository(
          cryptoService: CryptoService(),
          localStorage: storage,
          supabase: supabase,
        );
        await vault.loadFromLocalCache();

        final notifier = FlutterLocalOverdueNotificationGateway();
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
        vault.dispose();
      } finally {
        await storage.close();
      }
    } catch (_) {
      // Background failures are silently retried on the next 30-min WorkManager window.
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
      final overdueCount =
          pendingBills.where((i) => i.status == 'overdue').length;
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
    if (prefs.appUpdatesEnabled && manifestUrl.trim().isNotEmpty) {
      try {
        final rawLastCheck = await storage.getRaw(_keyLastUpdateCheckAt);
        final lastCheck = DateTime.tryParse(rawLastCheck ?? '');
        final checkedRecently = lastCheck != null &&
            !now.difference(lastCheck).isNegative &&
            now.difference(lastCheck) < const Duration(hours: 12);
        if (!checkedRecently) {
          final check = await updateService
              .checkForUpdate(manifestUrl)
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

/// Schedules Android WorkManager background monitoring every 30 minutes so
/// clerk dockets, overdue bills, payroll, recurring bills, statements, and app
/// updates notify Veronica even when the app is completely closed or inactive.
class BackgroundUpdateWorker {
  BackgroundUpdateWorker._();

  static Future<void> initializeAndSchedule({
    String manifestUrl = ttgDefaultManifestUrl,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Workmanager().initialize(ttgBackgroundCallbackDispatcher);
      await Workmanager().registerPeriodicTask(
        ttgBackgroundUpdateTask,
        ttgBackgroundUpdateTask,
        frequency: const Duration(minutes: 30),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
        ),
        inputData: <String, dynamic>{'manifestUrl': manifestUrl},
      );
    } catch (_) {
      // Never block app startup if background scheduler is unavailable.
    }
  }
}
