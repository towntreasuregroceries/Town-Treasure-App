import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../../data/services/local_storage_service.dart';
import '../../../data/services/remote_update_service.dart';
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

      final rawPrefs = await storage.getRaw(ttgKeyNotifPrefs);
      if (rawPrefs != null && rawPrefs.isNotEmpty) {
        try {
          final map = jsonDecode(rawPrefs);
          if (map is Map && map['appUpdatesEnabled'] == false) {
            await storage.close();
            return true;
          }
        } catch (_) {}
      }

      final url = (inputData?['manifestUrl'] as String?)?.trim();
      final manifestUrl =
          (url != null && url.isNotEmpty) ? url : ttgDefaultManifestUrl;
      final updateService = RemoteUpdateService();
      final check = await updateService
          .checkForUpdate(manifestUrl)
          .timeout(const Duration(seconds: 10));

      final manifest = check.manifest;
      if (check.updateAvailable && manifest != null) {
        final rawLastBuild = await storage.getRaw(ttgKeyNotifiedBuildCompat);
        final lastBuild = int.tryParse(rawLastBuild ?? '') ?? 0;
        if (manifest.buildNumber > lastBuild) {
          final notifier = FlutterLocalOverdueNotificationGateway();
          await notifier.showCategoryNotification(
            category: NotificationCategory.appUpdates,
            title: 'App Update Available (v${manifest.version})',
            body:
                'A new Town Treasure Groceries release is ready. Open the app and tap Update to install.',
          );
          await storage.setRaw(
            ttgKeyNotifiedBuildCompat,
            manifest.buildNumber.toString(),
          );
        }
      }
      await storage.close();
    } catch (_) {
      // Offline / background failures are silently retried on next 24h window.
    }
    return true;
  });
}

const String ttgKeyNotifiedBuildCompat = ttgKeyLastNotifiedUpdateBuild;

/// Schedules a daily Workmanager task on Android when connectivity is present
/// to check for new APK releases silently without draining battery.
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
        frequency: const Duration(hours: 24),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        inputData: <String, dynamic>{'manifestUrl': manifestUrl},
      );
    } catch (_) {
      // Never block app startup if background scheduler is unavailable.
    }
  }
}
