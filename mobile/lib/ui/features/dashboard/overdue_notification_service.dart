import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Abstraction over local notifications so DashboardViewModel is unit-testable.
abstract class OverdueNotificationGateway {
  Future<bool> initializeAndRequestPermission();
  Future<void> showOverdueSummary({
    required int overdueCount,
    required int pendingCount,
  });
  Future<void> cancelAll();
}

/// Live `flutter_local_notifications` implementation for Android/iOS.
class FlutterLocalOverdueNotificationGateway
    implements OverdueNotificationGateway {
  FlutterLocalOverdueNotificationGateway([
    FlutterLocalNotificationsPlugin? plugin,
  ]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const int _overdueNotificationId = 1001;
  static const String _channelId = 'ttg_overdue_invoices';
  static const String _channelName = 'Overdue & Pending Invoices';
  static const String _channelDescription =
      'Reminders for pending and overdue Town Treasure invoices.';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<bool> initializeAndRequestPermission() async {
    if (kIsWeb) return false;

    if (!_initialized) {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const settings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );
      final ok = await _plugin.initialize(settings);
      _initialized = ok ?? true;
    }

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      final granted = await androidPlugin.requestNotificationsPermission();
      return granted ?? true;
    }

    return true;
  }

  @override
  Future<void> showOverdueSummary({
    required int overdueCount,
    required int pendingCount,
  }) async {
    if (overdueCount <= 0 && pendingCount <= 0) return;

    final parts = <String>[];
    if (overdueCount > 0) {
      parts.add(
        '$overdueCount overdue ${overdueCount == 1 ? 'invoice' : 'invoices'}',
      );
    }
    if (pendingCount > 0) {
      parts.add(
        '$pendingCount pending ${pendingCount == 1 ? 'bill' : 'bills'}',
      );
    }
    final body = 'You have ${parts.join(' and ')} awaiting settlement.';

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.show(
      _overdueNotificationId,
      'Town Treasure Groceries',
      body,
      details,
    );
  }

  @override
  Future<void> cancelAll() async {
    await _plugin.cancel(_overdueNotificationId);
  }
}
