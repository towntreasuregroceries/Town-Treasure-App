import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';

typedef TempDirLookup = Future<Directory> Function();
typedef ShareFilesCallback = Future<void> Function(
  List<XFile> files, {
  String? subject,
  String? text,
});

/// Exports the full encrypted vault into an `.xlsx` workbook matching the
/// financial tables in `data.js` (`exportToExcel('all')` + full sheets).
class ExcelExporter {
  ExcelExporter({
    TempDirLookup? tempDirLookup,
    ShareFilesCallback? shareFiles,
  })  : _tempDirLookup = tempDirLookup ?? getTemporaryDirectory,
        _shareFiles = shareFiles ?? _defaultShareFiles;

  final TempDirLookup _tempDirLookup;
  final ShareFilesCallback _shareFiles;

  static Future<void> _defaultShareFiles(
    List<XFile> files, {
    String? subject,
    String? text,
  }) async {
    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(files, subject: subject, text: text),
    );
  }

  /// Builds the full multi-sheet `.xlsx` byte payload from [vault].
  static Uint8List buildWorkbookBytes(VaultRepository vault) {
    final workbook = Excel.createExcel();
    const defaultSheet = 'Sheet1';
    if (workbook.sheets.containsKey(defaultSheet)) {
      workbook.rename(defaultSheet, 'Invoices');
    }

    final invoicesSheet = workbook['Invoices'];
    invoicesSheet.appendRow([
      TextCellValue('Invoice #'),
      TextCellValue('Restaurant'),
      TextCellValue('Date'),
      TextCellValue('Due Date'),
      TextCellValue('Items'),
      TextCellValue('Total Sell (KES)'),
      TextCellValue('Total Buy (KES)'),
      TextCellValue('Delivery Cost (KES)'),
      TextCellValue('Other Cost (KES)'),
      TextCellValue('Profit (KES)'),
      TextCellValue('Status'),
    ]);

    for (final inv in vault.invoices.where((i) => !i.isDraft)) {
      final restName =
          Restaurant.invoiceDisplayName(inv, vault.restaurants);
      invoicesSheet.appendRow([
        TextCellValue(inv.number),
        TextCellValue(restName),
        TextCellValue(inv.date),
        TextCellValue(inv.dueDate),
        IntCellValue(inv.items.length),
        DoubleCellValue(inv.totalSell),
        DoubleCellValue(inv.totalBuy),
        DoubleCellValue(inv.deliveryCost),
        DoubleCellValue(inv.otherCost),
        DoubleCellValue(inv.profit),
        TextCellValue(inv.status),
      ]);
    }

    final expensesSheet = workbook['Expenses'];
    expensesSheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Description'),
      TextCellValue('Category'),
      TextCellValue('Amount (KES)'),
      TextCellValue('Type'),
    ]);
    for (final exp in vault.expenses) {
      expensesSheet.appendRow([
        TextCellValue(exp.date),
        TextCellValue(exp.desc),
        TextCellValue(exp.category),
        DoubleCellValue(exp.amount),
        TextCellValue(exp.type),
      ]);
    }

    final staffSheet = workbook['Staff'];
    staffSheet.appendRow([
      TextCellValue('Name'),
      TextCellValue('Role'),
      TextCellValue('Monthly Salary (KES)'),
      TextCellValue('Phone'),
      TextCellValue('Pay Day'),
      TextCellValue('Status'),
    ]);
    for (final member in vault.staff) {
      staffSheet.appendRow([
        TextCellValue(member.name),
        TextCellValue(member.role),
        DoubleCellValue(member.salary),
        TextCellValue(member.phone),
        TextCellValue(member.payDay),
        TextCellValue(member.status),
      ]);
    }

    final restaurantsSheet = workbook['Restaurants'];
    restaurantsSheet.appendRow([
      TextCellValue('Name'),
      TextCellValue('KRA PIN'),
      TextCellValue('Contact'),
      TextCellValue('Phone'),
      TextCellValue('Address'),
      TextCellValue('Total Sales (KES)'),
    ]);
    for (final restaurant in vault.restaurants) {
      final totalSales = vault.invoices
          .where(
            (inv) =>
                !inv.isDraft &&
                Restaurant.invoiceBelongsToRestaurant(
                  inv,
                  restaurant,
                  vault.restaurants,
                ),
          )
          .fold<double>(0, (sum, inv) => sum + inv.totalSell);
      restaurantsSheet.appendRow([
        TextCellValue(restaurant.name),
        TextCellValue(restaurant.kraPin),
        TextCellValue(restaurant.contact),
        TextCellValue(restaurant.phone),
        TextCellValue(restaurant.address),
        DoubleCellValue(totalSales),
      ]);
    }

    final payrollSheet = workbook['Salary Payments'];
    payrollSheet.appendRow([
      TextCellValue('Staff Name'),
      TextCellValue('Month'),
      TextCellValue('Amount (KES)'),
      TextCellValue('Date Paid'),
    ]);
    for (final payment in vault.salaryPayments) {
      payrollSheet.appendRow([
        TextCellValue(payment.staffName),
        TextCellValue(payment.month),
        DoubleCellValue(payment.amount),
        TextCellValue(payment.datePaid),
      ]);
    }

    final borrowingsSheet = workbook['Borrowings'];
    borrowingsSheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Description'),
      TextCellValue('Amount (KES)'),
      TextCellValue('Repaid (KES)'),
      TextCellValue('Outstanding (KES)'),
    ]);
    for (final borrowing in vault.borrowings) {
      borrowingsSheet.appendRow([
        TextCellValue(borrowing.date),
        TextCellValue(borrowing.desc),
        DoubleCellValue(borrowing.amount),
        DoubleCellValue(borrowing.totalRepaid),
        DoubleCellValue(borrowing.outstandingBalance),
      ]);
    }

    final encoded = workbook.encode();
    if (encoded == null) {
      throw StateError('Failed to encode Excel workbook.');
    }
    return Uint8List.fromList(encoded);
  }

  /// Writes the `.xlsx` workbook to a temporary file and opens the share sheet.
  Future<File> exportAndShare(VaultRepository vault) async {
    final bytes = buildWorkbookBytes(vault);
    final dir = await _tempDirLookup();
    final today = AppHelpers.normalizeAppDate(DateTime.now());
    final filename = 'TTG_Full_Export_$today.xlsx';
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes, flush: true);

    await _shareFiles(
      [XFile(file.path, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
      subject: 'Town Treasure Groceries Financial Export ($today)',
      text: 'Full financial workbook exported from Town Treasure Groceries.',
    );
    return file;
  }
}
