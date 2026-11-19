import 'app_helpers.dart';
import 'borrowing.dart';
import 'expense.dart';
import 'invoice.dart';
import 'price_list.dart';
import 'record_action.dart';
import 'recurring_expense.dart';
import 'restaurant.dart';
import 'salary_payment.dart';
import 'staff.dart';
import 'vault_settings.dart';

/// Complete encrypted vault payload schema matching `appState` in `data.js`.
class VaultData {
  const VaultData({
    this.vaultVersion = 0,
    this.lastSync,
    this.invoices = const [],
    this.deletedInvoiceIds = const [],
    this.restoredInvoiceIds = const [],
    this.recordActions = const {},
    this.expenses = const [],
    this.restaurants = const [],
    this.deletedRestaurantIds = const [],
    this.deletedInvoices = const [],
    this.staff = const [],
    this.salaryPayments = const [],
    this.recurringExpenses = const [],
    this.priceLists = const [],
    this.deletedStaff = const [],
    this.deletedPriceLists = const [],
    this.borrowings = const [],
    this.settings = const VaultSettings(),
  });

  final int vaultVersion;
  final String? lastSync;
  final List<Invoice> invoices;
  final List<String> deletedInvoiceIds;
  final List<String> restoredInvoiceIds;
  final Map<String, Map<String, RecordAction>> recordActions;
  final List<Expense> expenses;
  final List<Restaurant> restaurants;
  final List<String> deletedRestaurantIds;
  final List<Invoice> deletedInvoices;
  final List<Staff> staff;
  final List<SalaryPayment> salaryPayments;
  final List<RecurringExpense> recurringExpenses;
  final List<PriceList> priceLists;
  final List<Staff> deletedStaff;
  final List<PriceList> deletedPriceLists;
  final List<Borrowing> borrowings;
  final VaultSettings settings;

  factory VaultData.fromJson(Map<String, dynamic> json) {
    List<T> parseList<T>(
      Object? raw,
      T Function(Map<String, dynamic>) mapper,
    ) {
      if (raw is! List) return <T>[];
      return raw
          .whereType<Map>()
          .map((e) => mapper(Map<String, dynamic>.from(e)))
          .toList();
    }

    List<String> parseStrings(Object? raw) {
      if (raw is! List) return <String>[];
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }

    final parsedActions = <String, Map<String, RecordAction>>{};
    final rawActions = json['recordActions'];
    if (rawActions is Map) {
      rawActions.forEach((collection, records) {
        if (records is Map) {
          final byId = <String, RecordAction>{};
          records.forEach((id, action) {
            if (action is Map) {
              byId[id.toString()] =
                  RecordAction.fromJson(Map<String, dynamic>.from(action));
            }
          });
          parsedActions[collection.toString()] = byId;
        }
      });
    }

    final rawSettings = json['settings'];
    final settings = rawSettings is Map
        ? VaultSettings.fromJson(Map<String, dynamic>.from(rawSettings))
        : const VaultSettings();

    return VaultData(
      vaultVersion: AppHelpers.parseInt(json['_vaultVersion']),
      lastSync: json['_lastSync']?.toString(),
      invoices: parseList(json['invoices'], Invoice.fromJson),
      deletedInvoiceIds: parseStrings(json['deletedInvoiceIds']),
      restoredInvoiceIds: parseStrings(json['restoredInvoiceIds']),
      recordActions: parsedActions,
      expenses: parseList(json['expenses'], Expense.fromJson),
      restaurants: parseList(json['restaurants'], Restaurant.fromJson),
      deletedRestaurantIds: parseStrings(json['deletedRestaurantIds']),
      deletedInvoices: parseList(json['deletedInvoices'], Invoice.fromJson),
      staff: parseList(json['staff'], Staff.fromJson),
      salaryPayments: parseList(json['salaryPayments'], SalaryPayment.fromJson),
      recurringExpenses:
          parseList(json['recurringExpenses'], RecurringExpense.fromJson),
      priceLists: parseList(json['priceLists'], PriceList.fromJson),
      deletedStaff: parseList(json['deletedStaff'], Staff.fromJson),
      deletedPriceLists: parseList(json['deletedPriceLists'], PriceList.fromJson),
      borrowings: parseList(json['borrowings'], Borrowing.fromJson),
      settings: settings,
    );
  }

  Map<String, dynamic> toJson() {
    final actionsJson = <String, dynamic>{};
    recordActions.forEach((collection, records) {
      actionsJson[collection] = records.map(
        (id, action) => MapEntry(id, action.toJson()),
      );
    });

    return {
      '_vaultVersion': vaultVersion,
      if (lastSync != null) '_lastSync': lastSync,
      'invoices': invoices.map((e) => e.toJson()).toList(),
      'deletedInvoiceIds': deletedInvoiceIds,
      'restoredInvoiceIds': restoredInvoiceIds,
      'recordActions': actionsJson,
      'expenses': expenses.map((e) => e.toJson()).toList(),
      'restaurants': restaurants.map((e) => e.toJson()).toList(),
      'deletedRestaurantIds': deletedRestaurantIds,
      'deletedInvoices': deletedInvoices.map((e) => e.toJson()).toList(),
      'staff': staff.map((e) => e.toJson()).toList(),
      'salaryPayments': salaryPayments.map((e) => e.toJson()).toList(),
      'recurringExpenses': recurringExpenses.map((e) => e.toJson()).toList(),
      'priceLists': priceLists.map((e) => e.toJson()).toList(),
      'deletedStaff': deletedStaff.map((e) => e.toJson()).toList(),
      'deletedPriceLists': deletedPriceLists.map((e) => e.toJson()).toList(),
      'borrowings': borrowings.map((e) => e.toJson()).toList(),
      'settings': settings.toJson(),
    };
  }
}
