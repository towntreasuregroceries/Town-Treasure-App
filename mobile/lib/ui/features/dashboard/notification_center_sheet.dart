import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'dashboard_view_model.dart';
import 'overdue_notification_service.dart';

/// Smart Notification Center showing actionable business/update alerts and
/// per-category notification toggles.
class NotificationCenterSheet extends StatelessWidget {
  const NotificationCenterSheet({
    super.key,
    required this.viewModel,
    this.onCheckUpdates,
    this.onOpenClerkInbox,
    this.onOpenInvoices,
    this.onOpenExpenses,
    this.onOpenStatements,
    this.onOpenPersonalVault,
  });

  final DashboardViewModel viewModel;
  final VoidCallback? onCheckUpdates;
  final VoidCallback? onOpenClerkInbox;
  final VoidCallback? onOpenInvoices;
  final void Function(int tabIndex)? onOpenExpenses;
  final VoidCallback? onOpenStatements;
  final VoidCallback? onOpenPersonalVault;

  static Future<void> show(
    BuildContext context, {
    required DashboardViewModel viewModel,
    VoidCallback? onCheckUpdates,
    VoidCallback? onOpenClerkInbox,
    VoidCallback? onOpenInvoices,
    void Function(int tabIndex)? onOpenExpenses,
    VoidCallback? onOpenStatements,
    VoidCallback? onOpenPersonalVault,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.88,
        child: NotificationCenterSheet(
          viewModel: viewModel,
          onCheckUpdates: onCheckUpdates,
          onOpenClerkInbox: onOpenClerkInbox,
          onOpenInvoices: onOpenInvoices,
          onOpenExpenses: onOpenExpenses,
          onOpenStatements: onOpenStatements,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = math.max(
      MediaQuery.viewPaddingOf(context).bottom,
      MediaQuery.paddingOf(context).bottom,
    );

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final alerts = viewModel.activeAlerts;
        final prefs = viewModel.notificationPrefs;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.sageTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.notifications_active_outlined,
                      color: AppTheme.forestGreen,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Smart Notification Center',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        Text(
                          alerts.isEmpty
                              ? 'All business & update alerts clear'
                              : '${alerts.length} active alert${alerts.length == 1 ? '' : 's'} needing attention',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 20 + bottomSafe),
                children: [
                  if (alerts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.successSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.forestGreen.withValues(alpha: 0.25),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.verified_outlined,
                            color: AppTheme.forestGreen,
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'You are all caught up. No urgent updates, overdue bills, or unpaid salaries right now.',
                              style: TextStyle(
                                color: AppTheme.forestGreenDeep,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    const Text(
                      'ACTIVE ALERTS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final alert in alerts)
                      _AlertCard(
                        alert: alert,
                        onAction: () => _handleAlertAction(context, alert),
                      ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    'NOTIFICATION PREFERENCES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: AppTheme.slateMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          key: const Key('pref_app_updates'),
                          secondary: const Icon(
                            Icons.system_update_outlined,
                            color: AppTheme.forestGreen,
                          ),
                          title: const Text('Silent App Update Alerts'),
                          subtitle: const Text(
                            'Check automatically once daily and notify when a new release is ready',
                          ),
                          value: prefs.appUpdatesEnabled,
                          activeThumbColor: AppTheme.forestGreen,
                          onChanged: (v) => viewModel.updateNotificationPrefs(
                            prefs.copyWith(appUpdatesEnabled: v),
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const Key('pref_clerk_alerts'),
                          secondary: const Icon(
                            Icons.assignment_ind_outlined,
                            color: AppTheme.forestGreen,
                          ),
                          title: const Text('New Clerk Docket Alerts'),
                          subtitle: const Text(
                            'Notify when field clerks submit new dockets for review',
                          ),
                          value: prefs.clerkAlertsEnabled,
                          activeThumbColor: AppTheme.forestGreen,
                          onChanged: (v) => viewModel.updateNotificationPrefs(
                            prefs.copyWith(clerkAlertsEnabled: v),
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const Key('pref_overdue_alerts'),
                          secondary: const Icon(
                            Icons.schedule_outlined,
                            color: AppTheme.warning,
                          ),
                          title: const Text('Overdue & Pending Bill Alerts'),
                          subtitle: const Text(
                            'Summarizes unsettled invoices at most once every 24 hours',
                          ),
                          value: prefs.overdueAlertsEnabled,
                          activeThumbColor: AppTheme.forestGreen,
                          onChanged: (v) => viewModel.toggleOverdueNotifications(v),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const Key('pref_payroll_bills'),
                          secondary: const Icon(
                            Icons.payments_outlined,
                            color: AppTheme.forestGreen,
                          ),
                          title: const Text('Payroll & Recurring Bills'),
                          subtitle: const Text(
                            'Remind on staff payday and recurring rent or utility due dates',
                          ),
                          value: prefs.payrollAndBillsEnabled,
                          activeThumbColor: AppTheme.forestGreen,
                          onChanged: (v) => viewModel.updateNotificationPrefs(
                            prefs.copyWith(payrollAndBillsEnabled: v),
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          key: const Key('pref_monthly_statements'),
                          secondary: const Icon(
                            Icons.summarize_outlined,
                            color: AppTheme.forestGreen,
                          ),
                          title: const Text('Month-End Statement Prompts'),
                          subtitle: const Text(
                            'Remind at the start of the month to share client statements',
                          ),
                          value: prefs.statementAlertsEnabled,
                          activeThumbColor: AppTheme.forestGreen,
                          onChanged: (v) => viewModel.updateNotificationPrefs(
                            prefs.copyWith(statementAlertsEnabled: v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onCheckUpdates != null) ...[
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      key: const Key('btn_notif_check_updates'),
                      onPressed: () {
                        Navigator.of(context).pop();
                        onCheckUpdates?.call();
                      },
                      icon: const Icon(Icons.system_update_outlined),
                      label: const Text('Check for App Updates Now'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _handleAlertAction(BuildContext context, NotificationAlertItem alert) {
    Navigator.of(context).pop();
    switch (alert.category) {
      case NotificationCategory.appUpdates:
        onCheckUpdates?.call();
      case NotificationCategory.clerkSubmissions:
        onOpenClerkInbox?.call();
      case NotificationCategory.overdueInvoices:
        onOpenInvoices?.call();
      case NotificationCategory.payrollDue:
        onOpenExpenses?.call(1);
      case NotificationCategory.recurringBills:
        onOpenExpenses?.call(2);
      case NotificationCategory.syncHealth:
        viewModel.refresh();
      case NotificationCategory.monthlyStatements:
        onOpenStatements?.call();
      case NotificationCategory.documentExpiry:
        onOpenPersonalVault?.call();
    }
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.alert,
    required this.onAction,
  });

  final NotificationAlertItem alert;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg, icon) = switch (alert.severity) {
      NotificationSeverity.urgent => (
          AppTheme.dangerSurface,
          AppTheme.danger.withValues(alpha: 0.35),
          AppTheme.danger,
          Icons.priority_high_rounded,
        ),
      NotificationSeverity.warning => (
          AppTheme.warningSurface,
          AppTheme.warning.withValues(alpha: 0.4),
          AppTheme.warning,
          Icons.notifications_active_outlined,
        ),
      NotificationSeverity.info => (
          AppTheme.infoSurface,
          AppTheme.info.withValues(alpha: 0.35),
          AppTheme.info,
          Icons.info_outline,
        ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  alert.body,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.slateInk,
                  ),
                ),
              ],
            ),
          ),
          if (alert.actionLabel != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: Text(alert.actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
