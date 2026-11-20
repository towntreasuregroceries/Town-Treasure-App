import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/branded_pdf_viewer_screen.dart';
import '../../core/widgets/scoped_text_controllers.dart';
import '../invoices/invoice_formatters.dart';

/// KRA VAT3 Compliance Center & iTax Helper for Town Treasure Limited.
/// Supports Seller KRA PIN/eTIMS profile configuration, mixed VAT-Exempt produce vs
/// 16% Standard VAT invoice tagging, client KRA PIN compliance audit, monthly Input VAT
/// recording, and 1-tap VAT3 PDF + iTax CSV ledger exports.
class KraTaxCenterScreen extends StatefulWidget {
  const KraTaxCenterScreen({
    super.key,
    required this.vault,
  });

  final VaultRepository vault;

  @override
  State<KraTaxCenterScreen> createState() => _KraTaxCenterScreenState();
}

class _KraTaxCenterScreenState extends State<KraTaxCenterScreen> {
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');
  late String _selectedMonth;

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateFormat('yyyy-MM').format(DateTime.now());
    widget.vault.addListener(_onVaultChanged);
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVaultChanged);
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String msg, {Color color = AppTheme.forestGreen}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  List<String> _monthOptions() {
    final months = <String>{_selectedMonth};
    for (final inv in widget.vault.invoices) {
      if (!inv.isDraft && inv.date.length >= 7) {
        months.add(inv.date.substring(0, 7));
      }
    }
    for (final exp in widget.vault.expenses) {
      if (!exp.isCapital && exp.date.length >= 7) {
        months.add(exp.date.substring(0, 7));
      }
    }
    final sorted = months.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  Future<void> _editCompanyTaxProfile() async {
    final profile = widget.vault.kraProfile;
    var vatReg = profile.vatRegistered;
    var defaultRate = profile.defaultTaxRate;
    var defaultMode = profile.defaultVatMode;
    String? errorMsg;

    await showDialog<void>(
      context: context,
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          profile.sellerKraPin,
          profile.vatNumber,
          profile.cuSerialNumber,
          profile.etimsBranchId,
        ],
        builder: (ctx, ctrls) {
          final pinCtrl = ctrls[0];
          final vatNoCtrl = ctrls[1];
          final cuSerialCtrl = ctrls[2];
          final branchCtrl = ctrls[3];
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Town Treasure KRA Profile'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('field_kra_seller_pin'),
                  controller: pinCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Company KRA PIN *',
                    hintText: 'e.g. P051234567X',
                    helperText: 'Printed on invoices and iTax VAT3 pack headers',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: vatNoCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'VAT Registration No. (Optional)',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('VAT Registered (VAT3)'),
                  subtitle: const Text('16% Taxable + Exempt Produce split'),
                  value: vatReg,
                  onChanged: (v) => setDialogState(() => vatReg = v),
                ),
                DropdownButtonFormField<KraTaxRate>(
                  initialValue: defaultRate,
                  decoration: const InputDecoration(
                    labelText: 'Default Line Tax Classification',
                  ),
                  items: KraTaxRate.values
                      .map(
                        (r) => DropdownMenuItem(value: r, child: Text(r.label)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => defaultRate = v);
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<KraVatMode>(
                  initialValue: defaultMode,
                  decoration: const InputDecoration(
                    labelText: 'Default Price Tax Mode',
                  ),
                  items: KraVatMode.values
                      .map(
                        (m) => DropdownMenuItem(value: m, child: Text(m.label)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => defaultMode = v);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: cuSerialCtrl,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'eTIMS CU Serial',
                          hintText: 'Optional',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: branchCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Branch ID',
                          hintText: '00',
                        ),
                      ),
                    ),
                  ],
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorMsg!,
                    style: const TextStyle(color: AppTheme.danger, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('btn_save_kra_profile'),
              onPressed: () async {
                final pinNorm = Restaurant.normalizeKraPin(pinCtrl.text);
                if (pinNorm.isNotEmpty && !Restaurant.isValidKraPin(pinNorm)) {
                  setDialogState(
                    () => errorMsg = 'Enter a valid 11-character KRA PIN (e.g. P051234567X).',
                  );
                  return;
                }
                final next = KraCompanyProfile(
                  sellerKraPin: pinNorm,
                  vatNumber: vatNoCtrl.text.trim().toUpperCase(),
                  vatRegistered: vatReg,
                  defaultTaxRate: defaultRate,
                  defaultVatMode: defaultMode,
                  cuSerialNumber: cuSerialCtrl.text.trim().toUpperCase(),
                  etimsBranchId: branchCtrl.text.trim().isEmpty
                      ? '00'
                      : branchCtrl.text.trim(),
                );
                await widget.vault.saveKraProfile(next);
                if (ctx.mounted) Navigator.of(ctx).pop();
                _showSnack('Company KRA tax profile saved.');
              },
              child: const Text('Save'),
            ),
          ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openInvoiceTaxSheet(Invoice invoice) async {
    final profile = widget.vault.kraProfile;
    var items = List<InvoiceLineItem>.from(invoice.items);
    var vatMode = KraVatMode.fromCode(
      invoice.vatMode ?? profile.defaultVatMode.code,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          invoice.cuInvoiceNumber ?? '',
          invoice.etimsQrData ?? '',
        ],
        builder: (ctx, ctrls) {
          final cuNoCtrl = ctrls[0];
          final qrCtrl = ctrls[1];
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
          final previewInv = invoice.copyWith(
            items: items,
            vatMode: vatMode.code,
          );
          final taxSummary = KraTaxCalculator.computeInvoiceTaxSummary(
            previewInv,
            profile: profile,
          );

          void applyRateToAll(KraTaxRate rate) {
            setSheetState(() {
              items = items
                  .map((it) => it.copyWith(taxRate: rate.code))
                  .toList();
            });
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              16,
              18,
              MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Tax & eTIMS — ${invoice.number}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  Text(
                    '${invoice.restaurantName} · ${InvoiceFormatters.formatDisplayDate(invoice.date)}',
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'VAT Mode:',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Inclusive'),
                        selected: vatMode == KraVatMode.inclusive,
                        onSelected: (_) =>
                            setSheetState(() => vatMode = KraVatMode.inclusive),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('Exclusive'),
                        selected: vatMode == KraVatMode.exclusive,
                        onSelected: (_) =>
                            setSheetState(() => vatMode = KraVatMode.exclusive),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        label: const Text('All VAT Exempt (Produce)'),
                        onPressed: () => applyRateToAll(KraTaxRate.exempt),
                      ),
                      ActionChip(
                        key: const Key('chip_mark_all_vat16'),
                        label: const Text('All 16% VAT'),
                        onPressed: () => applyRateToAll(KraTaxRate.standard16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...List.generate(items.length, (i) {
                    final it = items[i];
                    final rate = KraTaxRate.fromCode(it.taxRate);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceSage,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  it.desc,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  'KES ${_moneyFmt.format(it.total)}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          DropdownButton<KraTaxRate>(
                            value: rate,
                            underline: const SizedBox.shrink(),
                            items: KraTaxRate.values
                                .map(
                                  (r) => DropdownMenuItem(
                                    value: r,
                                    child: Text(
                                      r == KraTaxRate.standard16
                                          ? '16% VAT'
                                          : (r == KraTaxRate.zeroRated
                                              ? '0%'
                                              : 'Exempt'),
                                      style: const TextStyle(fontSize: 12.5),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (nextRate) {
                              if (nextRate == null) return;
                              setSheetState(() {
                                items[i] = it.copyWith(taxRate: nextRate.code);
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.infoSurface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Exempt: KES ${_moneyFmt.format(taxSummary.exemptTotal)}  |  Taxable Net: KES ${_moneyFmt.format(taxSummary.taxableNetTotal)}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Output VAT (16%): KES ${_moneyFmt.format(taxSummary.outputVatTotal)}  ·  Total w/ VAT: KES ${_moneyFmt.format(taxSummary.grandTotalWithVat)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('field_etims_cu_number'),
                    controller: cuNoCtrl,
                    decoration: const InputDecoration(
                      labelText: 'eTIMS CU Invoice No. (Optional)',
                      hintText: 'e.g. KRAMW0123456/0042',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('field_etims_qr_url'),
                    controller: qrCtrl,
                    decoration: const InputDecoration(
                      labelText: 'eTIMS Verification QR URL (Optional)',
                      hintText: 'https://etims.kra.go.ke/...',
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    key: const Key('btn_save_invoice_tax'),
                    onPressed: () async {
                      final nowIso = DateTime.now().toUtc().toIso8601String();
                      final updated = invoice.copyWith(
                        items: items,
                        vatMode: vatMode.code,
                        cuInvoiceNumber: cuNoCtrl.text.trim(),
                        etimsQrData: qrCtrl.text.trim(),
                        etimsSubmittedAt: cuNoCtrl.text.trim().isNotEmpty
                            ? (invoice.etimsSubmittedAt ?? nowIso)
                            : null,
                        updatedAt: nowIso,
                      );
                      final list = List<Invoice>.from(widget.vault.invoices);
                      final idx = list.indexWhere((i) => i.id == updated.id);
                      if (idx >= 0) {
                        list[idx] = updated;
                        await widget.vault.setInvoices(list);
                      }
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _showSnack('Updated KRA tax & eTIMS details for ${invoice.number}.');
                    },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save Tax & eTIMS Details'),
                  ),
                ],
              ),
            ),
          );
            },
          );
        },
      ),
    );
  }

  Future<void> _assignClientKraPin(Invoice invoice) async {
    final rest = Restaurant.resolveInvoiceRestaurant(
      invoice,
      widget.vault.restaurants,
    ).restaurant;
    if (rest == null) {
      _showSnack(
        'Link this invoice to a saved restaurant client before assigning KRA PIN.',
        color: AppTheme.warning,
      );
      return;
    }

    String? errorMsg;

    await showDialog<void>(
      context: context,
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [rest.kraPin],
        builder: (ctx, ctrls) {
          final ctrl = ctrls[0];
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
          title: Text('KRA PIN — ${rest.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Buyer KRA PIN',
                  hintText: 'e.g. P051234567X',
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final pin = Restaurant.normalizeKraPin(ctrl.text);
                if (pin.isEmpty || !Restaurant.isValidKraPin(pin)) {
                  setDialogState(
                    () => errorMsg = 'Enter a valid 11-character KRA PIN (e.g. P051234567X).',
                  );
                  return;
                }
                final list = List<Restaurant>.from(widget.vault.restaurants);
                final idx = list.indexWhere((r) => r.id == rest.id);
                if (idx >= 0) {
                  list[idx] = rest.copyWith(
                    kraPin: pin,
                    updatedAt: DateTime.now().toUtc().toIso8601String(),
                  );
                  await widget.vault.setRestaurants(list);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
                _showSnack('Updated KRA PIN for ${rest.name}.');
              },
              child: const Text('Save PIN'),
            ),
          ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _editExpenseInputVat(Expense exp) async {
    String? errorMsg;

    await showDialog<void>(
      context: context,
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          exp.supplierKraPin ?? '',
          (exp.inputVatAmount ?? 0) > 0
              ? exp.inputVatAmount!.toStringAsFixed(2)
              : '',
        ],
        builder: (ctx, ctrls) {
          final pinCtrl = ctrls[0];
          final vatCtrl = ctrls[1];
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Input VAT — ${exp.desc}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Expense Total: KES ${_moneyFmt.format(exp.amount)}',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pinCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Supplier KRA PIN',
                  hintText: 'e.g. P051234567X',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: vatCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Claimable Input VAT (KES)',
                  suffixIcon: TextButton(
                    onPressed: () {
                      final est = (exp.amount * 16 / 116);
                      setDialogState(() => vatCtrl.text = est.toStringAsFixed(2));
                    },
                    child: const Text('16%'),
                  ),
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final pin = Restaurant.normalizeKraPin(pinCtrl.text);
                if (pin.isNotEmpty && !Restaurant.isValidKraPin(pin)) {
                  setDialogState(
                    () => errorMsg = 'Invalid Supplier KRA PIN (11 chars e.g. P051234567X).',
                  );
                  return;
                }
                final vatVal = double.tryParse(vatCtrl.text.trim()) ?? 0;
                final list = List<Expense>.from(widget.vault.expenses);
                final idx = list.indexWhere((e) => e.id == exp.id);
                if (idx >= 0) {
                  list[idx] = exp.copyWith(
                    supplierKraPin: pin,
                    inputVatAmount: vatVal,
                    updatedAt: DateTime.now().toUtc().toIso8601String(),
                  );
                  await widget.vault.setExpenses(list);
                }
                if (ctx.mounted) Navigator.of(ctx).pop();
                _showSnack('Updated Input VAT record.');
              },
              child: const Text('Save'),
            ),
          ],
            ),
          );
        },
      ),
    );
  }

  Future<Uint8List> _buildVat3ReturnPdf(KraMonthlyVat3Summary summary) async {
    final profile = widget.vault.kraProfile;
    final monthInvoices = widget.vault.invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final monthExpenses = widget.vault.expenses
        .where((e) => !e.isCapital && e.date.startsWith(_selectedMonth) && (e.inputVatAmount ?? 0) > 0)
        .toList();

    final doc = pw.Document(
      title: 'KRA VAT3 Tax Pack $_selectedMonth',
      author: 'Town Treasure Limited',
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (_) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'TOWN TREASURE LIMITED',
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColor.fromInt(0xFF166534),
                    ),
                  ),
                  pw.Text(
                    'KRA VAT3 Monthly Filing Pack ($_selectedMonth)',
                    style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
                  ),
                  if (profile.normalizedSellerPin.isNotEmpty)
                    pw.Text(
                      'Taxpayer PIN: ${profile.normalizedSellerPin}${profile.vatNumber.isNotEmpty ? ' | VAT No: ${profile.vatNumber}' : ''}',
                      style: const pw.TextStyle(fontSize: 9.5),
                    ),
                ],
              ),
              pw.Text(
                'Due: ${DateFormat('dd MMM yyyy').format(summary.filingDeadline)}',
                style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColor.fromInt(0xFFDFE7DF)),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pdfStatRow('16% Standard Rated Sales (Net)', 'KES ${_moneyFmt.format(summary.taxableNetSalesTotal)}'),
                _pdfStatRow('Output VAT (16%)', 'KES ${_moneyFmt.format(summary.outputVatTotal)}'),
                _pdfStatRow('VAT-Exempt Produce Sales', 'KES ${_moneyFmt.format(summary.exemptSalesTotal)}'),
                _pdfStatRow('Zero-Rated Sales (0%)', 'KES ${_moneyFmt.format(summary.zeroRatedSalesTotal)}'),
                _pdfStatRow('Claimable Input VAT (Expenses)', 'KES ${_moneyFmt.format(summary.inputVatTotal)}'),
                pw.Divider(),
                _pdfStatRow(
                  summary.netVatPayable >= 0 ? 'Net VAT Payable' : 'Net VAT Credit Carried Forward',
                  'KES ${_moneyFmt.format(summary.netVatPayable.abs())}',
                  bold: true,
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'Sales & Output Tax Ledger (${monthInvoices.length} invoices)',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF313A43)),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headers: ['Date', 'Inv No.', 'Client', 'Client PIN', 'Exempt', 'Net 16%', 'VAT 16%', 'CU Inv'],
            data: monthInvoices.map((inv) {
              final rest = Restaurant.resolveInvoiceRestaurant(inv, widget.vault.restaurants).restaurant;
              final tax = KraTaxCalculator.computeInvoiceTaxSummary(inv, profile: profile);
              return [
                inv.date,
                inv.number,
                rest?.name ?? inv.restaurantName,
                Restaurant.normalizeKraPin(rest?.kraPin),
                _moneyFmt.format(tax.exemptTotal),
                _moneyFmt.format(tax.taxableNetTotal),
                _moneyFmt.format(tax.outputVatTotal),
                inv.cuInvoiceNumber ?? '',
              ];
            }).toList(),
          ),
          if (monthExpenses.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Text(
              'Claimable Input VAT Purchases (${monthExpenses.length})',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF166534)),
              cellStyle: const pw.TextStyle(fontSize: 8),
              headers: ['Date', 'Supplier PIN', 'Description', 'Gross Amt', 'Input VAT'],
              data: monthExpenses.map((e) => [
                e.date,
                e.supplierKraPin ?? '',
                e.desc,
                _moneyFmt.format(e.amount),
                _moneyFmt.format(e.inputVatAmount ?? 0),
              ]).toList(),
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _pdfStatRow(String label, String value, {bool bold = false}) {
    final style = pw.TextStyle(
      fontSize: bold ? 10.5 : 9.5,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    );
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [pw.Text(label, style: style), pw.Text(value, style: style)],
      ),
    );
  }

  String _csvEsc(String v) => '"${v.replaceAll('"', '""')}"';

  Future<void> _exportItaxCsv() async {
    final profile = widget.vault.kraProfile;
    final monthInvoices = widget.vault.invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final buf = StringBuffer();
    buf.writeln(
      'Section,Type,PIN,Party Name,Date,Doc Number,CU Invoice Number,Taxable Net (16%),Output/Input VAT (16%),Exempt Amount,Zero Rated (0%)',
    );
    for (final inv in monthInvoices) {
      final rest = Restaurant.resolveInvoiceRestaurant(inv, widget.vault.restaurants).restaurant;
      final pin = Restaurant.normalizeKraPin(rest?.kraPin);
      final tax = KraTaxCalculator.computeInvoiceTaxSummary(inv, profile: profile);
      buf.writeln([
        'Sales',
        tax.hasTaxableVatLines ? 'Taxable 16%' : 'Exempt Produce',
        _csvEsc(pin),
        _csvEsc(rest?.name ?? inv.restaurantName),
        _csvEsc(inv.date),
        _csvEsc(inv.number),
        _csvEsc(inv.cuInvoiceNumber ?? ''),
        tax.taxableNetTotal.toStringAsFixed(2),
        tax.outputVatTotal.toStringAsFixed(2),
        tax.exemptTotal.toStringAsFixed(2),
        tax.zeroRatedTotal.toStringAsFixed(2),
      ].join(','));
    }

    for (final exp in widget.vault.expenses.where(
      (e) => !e.isCapital && e.date.startsWith(_selectedMonth) && (e.inputVatAmount ?? 0) > 0,
    )) {
      final vat = exp.inputVatAmount ?? 0;
      buf.writeln([
        'Purchases',
        'Input VAT',
        _csvEsc(exp.supplierKraPin ?? ''),
        _csvEsc(exp.desc),
        _csvEsc(exp.date),
        _csvEsc(exp.id),
        '""',
        (exp.amount - vat).clamp(0, exp.amount).toStringAsFixed(2),
        vat.toStringAsFixed(2),
        '0.00',
        '0.00',
      ].join(','));
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/TownTreasure_iTax_VAT3_$_selectedMonth.csv');
    await file.writeAsString(buf.toString(), flush: true);
    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(
        [XFile(file.path)],
        subject: 'KRA VAT3 iTax CSV ($_selectedMonth)',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.vault.kraProfile;
    final months = _monthOptions();
    final summary = KraTaxCalculator.computeMonthlySummary(
      monthYm: _selectedMonth,
      invoices: widget.vault.invoices,
      expenses: widget.vault.expenses,
      restaurants: widget.vault.restaurants,
      profile: profile,
    );
    final monthInvoices = widget.vault.invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final monthExpenses = widget.vault.expenses
        .where((e) => !e.isCapital && e.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('KRA & VAT3 Tax Center'),
        actions: [
          IconButton(
            key: const Key('btn_edit_kra_profile'),
            tooltip: 'Company KRA Tax Profile',
            onPressed: _editCompanyTaxProfile,
            icon: const Icon(Icons.account_balance_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // 1. Company KRA Profile card
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.sageTint,
                foregroundColor: AppTheme.forestGreenDeep,
                child: const Icon(Icons.verified_outlined),
              ),
              title: Text(
                profile.hasValidSellerPin
                    ? 'Seller KRA PIN: ${profile.normalizedSellerPin}'
                    : 'Set Company KRA PIN & VAT Profile',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${profile.vatRegistered ? 'VAT3 Registered' : 'Non-VAT'} · Default: ${profile.defaultTaxRate.label} (${profile.defaultVatMode.label})${profile.cuSerialNumber.isNotEmpty ? ' · CU: ${profile.cuSerialNumber}' : ''}',
                style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
              trailing: TextButton(
                onPressed: _editCompanyTaxProfile,
                child: const Text('Edit'),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Month Picker + Deadline
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedMonth,
                  decoration: const InputDecoration(
                    labelText: 'Tax Period (Month)',
                    prefixIcon: Icon(Icons.calendar_month_outlined),
                    isDense: true,
                  ),
                  items: months
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedMonth = v);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.warningSurface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'VAT3 DEADLINE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.warning,
                      ),
                    ),
                    Text(
                      DateFormat('dd MMM yyyy').format(summary.filingDeadline),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: AppTheme.slateInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 3. VAT3 Return Breakdown Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Monthly VAT3 Return Estimate',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _statLine('VAT-Exempt Produce Sales', summary.exemptSalesTotal),
                  _statLine('Zero-Rated Sales (0%)', summary.zeroRatedSalesTotal),
                  _statLine('16% Taxable Sales (Net)', summary.taxableNetSalesTotal),
                  _statLine('Output VAT (16%)', summary.outputVatTotal,
                      color: AppTheme.info),
                  _statLine('Deductible Input VAT (Expenses)', summary.inputVatTotal,
                      color: AppTheme.forestGreen),
                  const Divider(),
                  _statLine(
                    summary.netVatPayable >= 0
                        ? 'Net VAT Payable'
                        : 'Net VAT Credit',
                    summary.netVatPayable.abs(),
                    bold: true,
                    color: summary.netVatPayable > 0
                        ? AppTheme.danger
                        : AppTheme.forestGreenDeep,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('btn_export_vat3_pdf'),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => BrandedPdfViewerScreen(
                                  title: 'KRA VAT3 Pack ($_selectedMonth)',
                                  filename: 'KRA_VAT3_$_selectedMonth.pdf',
                                  supportsThermalRoll: false,
                                  buildPdf: (_) => _buildVat3ReturnPdf(summary),
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('VAT3 PDF Pack'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('btn_export_itax_csv'),
                          onPressed: _exportItaxCsv,
                          icon: const Icon(Icons.table_chart_outlined),
                          label: const Text('iTax CSV'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 4. B2B Client KRA PIN Audit
          if (summary.invoicesMissingClientPin.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: AppTheme.warningSurface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${summary.invoicesMissingClientPin.length} Invoice(s) Missing Client KRA PIN',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.warning,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap an invoice below to assign the client’s 11-character KRA PIN for iTax VAT3 compliance:',
                      style: TextStyle(fontSize: 12, color: AppTheme.slateInk),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: summary.invoicesMissingClientPin
                          .take(6)
                          .map(
                            (inv) => ActionChip(
                              label: Text('${inv.number} · ${inv.restaurantName}'),
                              onPressed: () => _assignClientKraPin(inv),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // 5. Invoices Tax & eTIMS Tagging List
          const SizedBox(height: 16),
          Text(
            'Invoices Tax & eTIMS Tagging (${monthInvoices.length})',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.slateInk,
            ),
          ),
          const SizedBox(height: 8),
          if (monthInvoices.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No finalized invoices for this month.'),
              ),
            )
          else
            ...monthInvoices.map((inv) {
              final tax = KraTaxCalculator.computeInvoiceTaxSummary(
                inv,
                profile: profile,
              );
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  key: Key('kra_inv_${inv.id}'),
                  onTap: () => _openInvoiceTaxSheet(inv),
                  title: Text(
                    '${inv.number} · ${inv.restaurantName}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Exempt: ${_moneyFmt.format(tax.exemptTotal)} · Net 16%: ${_moneyFmt.format(tax.taxableNetTotal)} · VAT: ${_moneyFmt.format(tax.outputVatTotal)}${inv.cuInvoiceNumber?.isNotEmpty == true ? ' · CU: ${inv.cuInvoiceNumber}' : ''}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                  ),
                  trailing: const Icon(Icons.edit_note_outlined),
                ),
              );
            }),

          // 6. Monthly Input VAT Expenses
          const SizedBox(height: 16),
          Text(
            'Monthly Expenses — Claimable Input VAT (${monthExpenses.length})',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.slateInk,
            ),
          ),
          const SizedBox(height: 8),
          if (monthExpenses.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No expenses recorded for this month.'),
              ),
            )
          else
            ...monthExpenses.map(
              (exp) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  onTap: () => _editExpenseInputVat(exp),
                  title: Text(
                    exp.desc,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${exp.date} · Amt: KES ${_moneyFmt.format(exp.amount)}${(exp.inputVatAmount ?? 0) > 0 ? ' · Input VAT: KES ${_moneyFmt.format(exp.inputVatAmount!)}' : ' · Tap to add Supplier PIN / Input VAT'}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                  ),
                  trailing: const Icon(Icons.receipt_outlined),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statLine(
    String label,
    double amount, {
    bool bold = false,
    Color color = AppTheme.slateInk,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: bold ? 14 : 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: AppTheme.slateInk,
            ),
          ),
          Text(
            'KES ${_moneyFmt.format(amount)}',
            style: TextStyle(
              fontSize: bold ? 15 : 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
