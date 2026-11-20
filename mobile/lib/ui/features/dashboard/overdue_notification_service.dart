import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Categories supported by Town Treasure's Smart Notification Center.
enum NotificationCategory {
  appUpdates,
  clerkSubmissions,
  overdueInvoices,
  payrollDue,
  recurringBills,
  syncHealth,
  monthlyStatements,
  documentExpiry,
}

enum NotificationSeverity { info, warning, urgent }

/// An actionable alert rendered inside the in-app Notification Center.
class NotificationAlertItem {
  const NotificationAlertItem({
    required this.category,
    required this.title,
    required this.body,
    required this.severity,
    this.actionLabel,
  });

  final NotificationCategory category;
  final String title;
  final String body;
  final NotificationSeverity severity;
  final String? actionLabel;
}

/// Persisted user notification preferences.
class NotificationPreferences {
  const NotificationPreferences({
    this.appUpdatesEnabled = true,
    this.clerkAlertsEnabled = true,
    this.overdueAlertsEnabled = false,
    this.payrollAndBillsEnabled = true,
    this.statementAlertsEnabled = true,
  });

  final bool appUpdatesEnabled;
  final bool clerkAlertsEnabled;
  final bool overdueAlertsEnabled;
  final bool payrollAndBillsEnabled;
  final bool statementAlertsEnabled;

  NotificationPreferences copyWith({
    bool? appUpdatesEnabled,
    bool? clerkAlertsEnabled,
    bool? overdueAlertsEnabled,
    bool? payrollAndBillsEnabled,
    bool? statementAlertsEnabled,
  }) {
    return NotificationPreferences(
      appUpdatesEnabled: appUpdatesEnabled ?? this.appUpdatesEnabled,
      clerkAlertsEnabled: clerkAlertsEnabled ?? this.clerkAlertsEnabled,
      overdueAlertsEnabled: overdueAlertsEnabled ?? this.overdueAlertsEnabled,
      payrollAndBillsEnabled:
          payrollAndBillsEnabled ?? this.payrollAndBillsEnabled,
      statementAlertsEnabled:
          statementAlertsEnabled ?? this.statementAlertsEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'appUpdatesEnabled': appUpdatesEnabled,
        'clerkAlertsEnabled': clerkAlertsEnabled,
        'overdueAlertsEnabled': overdueAlertsEnabled,
        'payrollAndBillsEnabled': payrollAndBillsEnabled,
        'statementAlertsEnabled': statementAlertsEnabled,
      };

  factory NotificationPreferences.fromJson(
    Map<String, dynamic> json, {
    bool legacyOverdueEnabled = false,
  }) {
    return NotificationPreferences(
      appUpdatesEnabled: json['appUpdatesEnabled'] != false,
      clerkAlertsEnabled: json['clerkAlertsEnabled'] != false,
      overdueAlertsEnabled: json.containsKey('overdueAlertsEnabled')
          ? json['overdueAlertsEnabled'] == true
          : legacyOverdueEnabled,
      payrollAndBillsEnabled: json['payrollAndBillsEnabled'] != false,
      statementAlertsEnabled: json['statementAlertsEnabled'] != false,
    );
  }
}

/// Abstraction over local notifications so DashboardViewModel is unit-testable.
abstract class OverdueNotificationGateway {
  Future<bool> initializeAndRequestPermission();
  Future<void> showOverdueSummary({
    required int overdueCount,
    required int pendingCount,
  });
  Future<void> cancelAll();
}

/// Extended multi-channel smart notification interface.
abstract class SmartNotificationGateway {
  Future<void> showCategoryNotification({
    required NotificationCategory category,
    required String title,
    required String body,
  });
}

/// Live `flutter_local_notifications` implementation for Android/iOS covering
/// overdue alerts, app updates, clerk submissions, payroll/bills, and statements.
class FlutterLocalOverdueNotificationGateway
    implements OverdueNotificationGateway, SmartNotificationGateway {
  FlutterLocalOverdueNotificationGateway([
    FlutterLocalNotificationsPlugin? plugin,
  ]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const int _overdueNotificationId = 1001;
  static const String _channelId = 'ttg_overdue_invoices';
  static const String _channelName = 'Overdue & Pending Invoices';
  static const String _channelDescription =
      'Reminders for pending and overdue Town Treasure invoices.';

  static final StreamController<String?> _tapController =
      StreamController<String?>.broadcast();

  static Stream<String?> get onNotificationTap => _tapController.stream;

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
      final ok = await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (resp) {
          _tapController.add(resp.payload);
        },
      );
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
      payload: NotificationCategory.overdueInvoices.name,
    );
  }

  @override
  Future<void> showCategoryNotification({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) {
      await initializeAndRequestPermission();
    }
    final (channelId, channelName, channelDesc, id) = switch (category) {
      NotificationCategory.appUpdates => (
          'ttg_app_updates',
          'App Updates',
          'Silent background release update alerts.',
          1002,
        ),
      NotificationCategory.clerkSubmissions => (
          'ttg_clerk_submissions',
          'Field Clerk Dockets',
          'Alerts when new field clerk dockets await approval.',
          1003,
        ),
      NotificationCategory.overdueInvoices => (
          _channelId,
          _channelName,
          _channelDescription,
          1001,
        ),
      NotificationCategory.payrollDue ||
      NotificationCategory.recurringBills => (
          'ttg_bills_payroll',
          'Payroll & Recurring Bills',
          'Reminders for staff paydays and recurring expenses.',
          1004,
        ),
      NotificationCategory.syncHealth => (
          'ttg_sync_health',
          'Cloud Sync Status',
          'Reminders when offline changes need cloud sync.',
          1005,
        ),
      NotificationCategory.monthlyStatements => (
          'ttg_statements',
          'Monthly Client Statements',
          'Start-of-month reminders to send client statements.',
          1006,
        ),
      NotificationCategory.documentExpiry => (
          'ttg_vault_expiry',
          'Vault Document Expiries',
          'Alerts when personal or KRA compliance documents are expiring soon.',
          1007,
        ),
    };

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDesc,
      importance: Importance.high,
      priority: Priority.high,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    );
    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: category.name,
    );
  }

  @override
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
