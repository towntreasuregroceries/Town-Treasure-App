import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/kra_oscu_service.dart';
import '../../../data/services/print_service.dart';
import '../../../data/services/supabase_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/app_print_helper.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../../core/widgets/scoped_text_controllers.dart';
import '../invoices/invoice_formatters.dart';
import '../invoices/invoice_pdf_builder.dart';
import '../reports/reports_view_model.dart';
import '../reports/statement_pdf_builder.dart';

/// KRA & eTIMS Tax Center for Town Treasure Limited.
/// Designed in plain business English with an in-app Help guide, uncluttered Tax
/// & OSCU setup sheet, mixed Exempt Produce vs 16% VAT tagging, live or manual
/// eTIMS QR generation on TAX INVOICE PDFs, and iTax CSV/PDF monthly packs.
class KraTaxCenterScreen extends StatefulWidget {
  const KraTaxCenterScreen({
    super.key,
    required this.vault,
    this.oscuService,
  });

  final VaultRepository vault;
  final KraOscuService? oscuService;

  /// Shared entry point so verified finalized invoices on `InvoiceDetailScreen`
  /// open the exact same eTIMS & VAT sheet as KRA Tax Center.
  static Future<void> showInvoiceEtimsSheet(
    BuildContext context, {
    required VaultRepository vault,
    required Invoice invoice,
    KraOscuService? oscuService,
    void Function(String msg, {bool isError})? onFeedback,
  }) {
    final oscu = oscuService ?? KraOscuService(supabase: SupabaseService());
    final rest = Restaurant.resolveInvoiceRestaurant(
      invoice,
      vault.restaurants,
    ).restaurant;
    return _showEtimsEditorSheet(
      context,
      vault: vault,
      oscu: oscu,
      sheetTitle: 'eTIMS & VAT — ${invoice.number}',
      sheetSubtitle:
          '${invoice.restaurantName} · ${InvoiceFormatters.formatDisplayDate(invoice.date)}',
      initialInvoice: invoice,
      resolvedBuyer: rest,
      previewLabel: 'Preview PDF',
      canIssueCreditNote: invoice.isFiscalized &&
          (invoice.etimsInvcNo ?? 0) > 0 &&
          !invoice.hasCreditNote,
      onPreviewPdf: (draft, _) {
        final buyer = Restaurant.resolveInvoiceRestaurant(
          draft,
          vault.restaurants,
        ).restaurant;
        AppPrintHelper.openPreview(
          context,
          document: PrintableDocument(
            title: 'Tax Invoice ${draft.number}',
            filename: InvoicePdfBuilder.pdfFilename(draft, buyer),
            supportsThermalRoll: true,
            buildPdf: (format) => InvoicePdfBuilder.buildPdfBytes(
              invoice: draft,
              restaurant: buyer,
              settings: vault.settings,
              pageFormat: format,
            ),
            buildEscPos: (cols) => EscPosReceiptBuilder.buildInvoicesReceipt(
              invoices: [draft],
              restaurants: vault.restaurants,
              settings: vault.settings,
              lineWidth: cols,
            ),
          ),
        );
      },
      onSave: (draft, summary) async {
        final vatMode = KraVatMode.fromCode(
          draft.vatMode ?? vault.kraProfile.defaultVatMode.code,
        );
        // Keep dashboard/ledger totals consistent when 16% VAT is added on top.
        final syncedInvoice =
            (vatMode == KraVatMode.exclusive && summary.outputVatTotal > 0)
                ? draft.copyWith(
                    totalSell: summary.grandTotalWithVat,
                    profit: summary.grandTotalWithVat -
                        draft.totalBuy -
                        draft.deliveryCost -
                        draft.otherCost,
                  )
                : draft;

        final taxableNames = syncedInvoice.items
            .where((it) => KraTaxRate.fromCode(it.taxRate) == KraTaxRate.standard16)
            .map((it) => it.desc);
        await vault.learnTaxableKeywords(taxableNames);

        final list = List<Invoice>.from(vault.invoices);
        final idx = list.indexWhere((i) => i.id == syncedInvoice.id);
        if (idx >= 0) {
          list[idx] = syncedInvoice;
          await vault.setInvoices(list);
        }
        onFeedback?.call('Saved eTIMS QR & VAT settings for ${invoice.number}.');
      },
      onCreditNoteIssued: (origInv, cnResult) async {
        final nowIso = DateTime.now().toUtc().toIso8601String();
        final list = List<Invoice>.from(vault.invoices);
        final idx = list.indexWhere((i) => i.id == origInv.id);
        if (idx >= 0) {
          list[idx] = origInv.copyWith(
            etimsCreditNoteCuNo: cnResult.cuInvoiceNumber,
            etimsCreditNoteQrData: cnResult.qrCodeUrl,
            etimsCreditNoteAt: nowIso,
            updatedAt: nowIso,
          );
          await vault.setInvoices(list);
        }
        onFeedback?.call(
          'Credit Note ${cnResult.cuInvoiceNumber} issued for ${origInv.number}.',
        );
      },
    );
  }

  static Future<void> _showEtimsEditorSheet(
    BuildContext context, {
    required VaultRepository vault,
    required KraOscuService oscu,
    required String sheetTitle,
    required String sheetSubtitle,
    required Invoice initialInvoice,
    required Restaurant? resolvedBuyer,
    required String previewLabel,
    required void Function(Invoice draft, KraInvoiceTaxSummary summary) onPreviewPdf,
    required Future<void> Function(Invoice draft, KraInvoiceTaxSummary summary) onSave,
    Future<void> Function(Invoice origInv, OscuFiscalResult cnResult)? onCreditNoteIssued,
    String? warningBanner,
    bool canIssueCreditNote = false,
  }) async {
    final profile = vault.kraProfile;
    final moneyFmt = NumberFormat('#,##0.00');
    var items = List<InvoiceLineItem>.from(initialInvoice.items);
    var vatMode = KraVatMode.fromCode(
      initialInvoice.vatMode ?? profile.defaultVatMode.code,
    );
    var isIssuingOscu = false;
    var sdcDateTime = initialInvoice.etimsSdcDateTime ?? '';
    var intrData = initialInvoice.etimsIntrData ?? '';
    int? issuedInvcNo = initialInvoice.etimsInvcNo;
    String? sheetError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          initialInvoice.cuInvoiceNumber ?? '',
          initialInvoice.etimsRcptSign ?? '',
          initialInvoice.etimsQrData ?? '',
        ],
        builder: (ctx, ctrls) {
          final cuNoCtrl = ctrls[0];
          final signCtrl = ctrls[1];
          final qrCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              Invoice buildDraft() {
                final nowIso = DateTime.now().toUtc().toIso8601String();
                final finalQr = qrCtrl.text.trim().isNotEmpty
                    ? qrCtrl.text.trim()
                    : KraTaxCalculator.buildEtimsQrUrl(
                        sellerKraPin: profile.normalizedSellerPin,
                        branchId: profile.etimsBranchId,
                        receiptSignature: signCtrl.text.trim(),
                        sandbox: profile.oscuSandbox,
                      );
                return initialInvoice.copyWith(
                  items: items,
                  vatMode: vatMode.code,
                  cuInvoiceNumber: cuNoCtrl.text.trim(),
                  etimsRcptSign: signCtrl.text.trim(),
                  etimsQrData: finalQr,
                  etimsSdcDateTime: sdcDateTime.trim(),
                  etimsIntrData: intrData.trim(),
                  etimsInvcNo: issuedInvcNo,
                  etimsSubmittedAt: cuNoCtrl.text.trim().isNotEmpty
                      ? (initialInvoice.etimsSubmittedAt ?? nowIso)
                      : null,
                  updatedAt: nowIso,
                );
              }

              final previewInv = buildDraft();
              final taxSummary = KraTaxCalculator.computeInvoiceTaxSummary(
                previewInv,
                profile: profile,
              );
              final alreadyFiscalized = previewInv.isFiscalized;

              void applyRateToAll(KraTaxRate rate) {
                setSheetState(() {
                  items = items
                      .map((it) => it.copyWith(taxRate: rate.code))
                      .toList();
                });
              }

              void autoTagExceptions() {
                final learned = vault.settings.kraTaxableKeywords;
                setSheetState(() {
                  items = items
                      .map(
                        (it) => it.copyWith(
                          taxRate: KraTaxCalculator.suggestTaxRate(
                            it.desc,
                            profile: profile,
                            learnedKeywords: learned,
                          ).code,
                        ),
                      )
                      .toList();
                });
              }

              void syncQrFromSignature(String sig) {
                final built = KraTaxCalculator.buildEtimsQrUrl(
                  sellerKraPin: profile.normalizedSellerPin,
                  branchId: profile.etimsBranchId,
                  receiptSignature: sig,
                  sandbox: profile.oscuSandbox,
                );
                if (built.isNotEmpty) {
                  setSheetState(() => qrCtrl.text = built);
                }
              }

              Future<void> issueViaOscu() async {
                setSheetState(() {
                  isIssuingOscu = true;
                  sheetError = null;
                });
                try {
                  final result = await oscu.submitSalesInvoice(
                    invoice: previewInv,
                    profile: profile,
                    buyer: resolvedBuyer,
                  );
                  setSheetState(() {
                    isIssuingOscu = false;
                    cuNoCtrl.text = result.cuInvoiceNumber;
                    signCtrl.text = result.receiptSignature;
                    qrCtrl.text = result.qrCodeUrl;
                    sdcDateTime = result.sdcDateTime;
                    intrData = result.internalData;
                    issuedInvcNo = result.invcNo ?? issuedInvcNo;
                  });
                } catch (e) {
                  setSheetState(() {
                    isIssuingOscu = false;
                    sheetError = UserFriendlyError.format(e);
                  });
                }
              }

              Future<void> issueCreditNoteViaOscu() async {
                final confirmed = await showDialog<bool>(
                  context: ctx,
                  builder: (dCtx) => AlertDialog(
                    title: const Text('Issue KRA Credit Note?'),
                    content: Text(
                      'This sends a reversal Credit Note (rcptTyCd = R) for CU Invoice ${previewInv.cuInvoiceNumber} to KRA eTIMS.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dCtx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                        onPressed: () => Navigator.of(dCtx).pop(true),
                        child: const Text('Confirm Credit Note'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                setSheetState(() {
                  isIssuingOscu = true;
                  sheetError = null;
                });
                try {
                  final cn = await oscu.submitCreditNote(
                    originalInvoice: previewInv,
                    profile: profile,
                    buyer: resolvedBuyer,
                  );
                  await onCreditNoteIssued?.call(previewInv, cn);
                  setSheetState(() => isIssuingOscu = false);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                } catch (e) {
                  setSheetState(() {
                    isIssuingOscu = false;
                    sheetError = UserFriendlyError.format(e);
                  });
                }
              }

              return Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  16,
                  18,
                  MediaQuery.of(ctx).viewInsets.bottom + 24,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        sheetTitle,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      Text(
                        sheetSubtitle,
                        style: const TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                      ),
                      if (warningBanner != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.warningSurface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppTheme.warning.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            warningBanner,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.warning,
                            ),
                          ),
                        ),
                      ],
                      if (profile.vatRegistered) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            ActionChip(
                              label: const Text('Auto-Tag 16% Items'),
                              onPressed: alreadyFiscalized ? null : autoTagExceptions,
                            ),
                            ActionChip(
                              label: const Text('All Fresh Produce (No VAT)'),
                              onPressed: alreadyFiscalized
                                  ? null
                                  : () => applyRateToAll(KraTaxRate.exempt),
                            ),
                            ActionChip(
                              key: const Key('chip_mark_all_vat16'),
                              label: const Text('Mark All 16% VAT'),
                              onPressed: alreadyFiscalized
                                  ? null
                                  : () => applyRateToAll(KraTaxRate.standard16),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ChoiceChip(
                              label: const Text('VAT Included'),
                              selected: vatMode == KraVatMode.inclusive,
                              onSelected: alreadyFiscalized
                                  ? null
                                  : (_) => setSheetState(
                                        () => vatMode = KraVatMode.inclusive,
                                      ),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Add 16% on Top'),
                              selected: vatMode == KraVatMode.exclusive,
                              onSelected: alreadyFiscalized
                                  ? null
                                  : (_) => setSheetState(
                                        () => vatMode = KraVatMode.exclusive,
                                      ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ...List.generate(items.length, (i) {
                          final it = items[i];
                          final rate = KraTaxRate.fromCode(
                            it.taxRate,
                            fallback: profile.defaultTaxRate,
                          );
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
                                        'KES ${moneyFmt.format(it.total)}',
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
                                  items: const [
                                    DropdownMenuItem(
                                      value: KraTaxRate.exempt,
                                      child: Text('No VAT', style: TextStyle(fontSize: 12.5)),
                                    ),
                                    DropdownMenuItem(
                                      value: KraTaxRate.standard16,
                                      child: Text('16% VAT', style: TextStyle(fontSize: 12.5)),
                                    ),
                                    DropdownMenuItem(
                                      value: KraTaxRate.zeroRated,
                                      child: Text('0% Rated', style: TextStyle(fontSize: 12.5)),
                                    ),
                                  ],
                                  onChanged: alreadyFiscalized
                                      ? null
                                      : (nextRate) {
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
                          child: Text(
                            'No VAT: KES ${moneyFmt.format(taxSummary.exemptTotal)} · '
                            '16% Net: KES ${moneyFmt.format(taxSummary.taxableNetTotal)} · '
                            'VAT: KES ${moneyFmt.format(taxSummary.outputVatTotal)}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (!alreadyFiscalized)
                        OutlinedButton.icon(
                          key: const Key('btn_issue_oscu'),
                          onPressed: isIssuingOscu ? null : issueViaOscu,
                          icon: isIssuingOscu
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.qr_code_2),
                          label: Text(
                            isIssuingOscu
                                ? 'Contacting KRA OSCU...'
                                : 'Issue Official eTIMS QR (OSCU)',
                          ),
                        )
                      else ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.sageTint,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            [
                              'eTIMS Fiscalized · CU: ${cuNoCtrl.text.trim()}',
                              if (sdcDateTime.isNotEmpty) 'SDC Time: $sdcDateTime',
                              if (initialInvoice.hasCreditNote)
                                'Credit Note: ${initialInvoice.etimsCreditNoteCuNo}',
                            ].join('\n'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.forestGreenDeep,
                            ),
                          ),
                        ),
                        if (canIssueCreditNote && onCreditNoteIssued != null) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            key: const Key('btn_issue_credit_note'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.danger,
                            ),
                            onPressed: isIssuingOscu ? null : issueCreditNoteViaOscu,
                            icon: const Icon(Icons.assignment_return_outlined),
                            label: const Text('Issue KRA Credit Note (Reverse)'),
                          ),
                        ],
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('field_etims_cu_number'),
                        controller: cuNoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'eTIMS CU / Receipt Number',
                          hintText: 'e.g. KRAMW0123456/0042',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('field_etims_rcpt_sign'),
                        controller: signCtrl,
                        onChanged: syncQrFromSignature,
                        decoration: const InputDecoration(
                          labelText: 'KRA Receipt Signature (Auto-Builds QR)',
                          hintText: 'Paste 16-char KRA signature to build QR link',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('field_etims_qr_url'),
                        controller: qrCtrl,
                        decoration: const InputDecoration(
                          labelText: 'eTIMS QR Verification Link',
                          hintText: 'https://etims.kra.go.ke/...',
                        ),
                      ),
                      if (sheetError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          sheetError!,
                          style: const TextStyle(color: AppTheme.danger, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('btn_preview_etims_pdf'),
                              onPressed: () {
                                final draft = buildDraft();
                                final sum = KraTaxCalculator.computeInvoiceTaxSummary(
                                  draft,
                                  profile: profile,
                                );
                                onPreviewPdf(draft, sum);
                              },
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              label: Text(previewLabel),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('btn_save_invoice_tax'),
                              onPressed: () async {
                                final draft = buildDraft();
                                final sum = KraTaxCalculator.computeInvoiceTaxSummary(
                                  draft,
                                  profile: profile,
                                );
                                await onSave(draft, sum);
                                if (ctx.mounted) Navigator.of(ctx).pop();
                              },
                              icon: const Icon(Icons.save_outlined),
                              label: const Text('Save'),
                            ),
                          ),
                        ],
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

  @override
  State<KraTaxCenterScreen> createState() => _KraTaxCenterScreenState();
}

class _KraTaxCenterScreenState extends State<KraTaxCenterScreen> {
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');
  late String _selectedMonth;
  bool _monthlyEtimsMode = false;
  bool _showAllClients = false;

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

  KraOscuService get _oscu =>
      widget.oscuService ?? KraOscuService(supabase: SupabaseService());

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

  Future<void> _openHelpGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppTheme.sageTint,
                    foregroundColor: AppTheme.forestGreen,
                    child: const Icon(Icons.help_outline),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'How KRA & eTIMS Tax Center Works',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateInk,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                children: [
                  const Text(
                    'Use this screen to give hotels and corporate clients KRA-compliant Tax Invoices with an eTIMS QR code, track monthly VAT, and export figures ready for iTax.',
                    style: TextStyle(fontSize: 13.5, color: AppTheme.slateInk),
                  ),
                  const SizedBox(height: 14),
                  _helpStepCard(
                    step: '1',
                    title: 'Set Up Town Treasure PIN & OSCU Once',
                    body:
                        'Tap Setup on the top card to save Town Treasure Limited’s 11-character KRA PIN, Branch ID (00), and OSCU settings. Once saved, your KRA PIN prints automatically on every invoice & statement PDF.',
                  ),
                  const SizedBox(height: 10),
                  _helpStepCard(
                    step: '2',
                    title: 'Daily OR Monthly Consolidated eTIMS QR',
                    body:
                        'Choose how each hotel bills under eTIMS Invoices:\n'
                        '• Daily (Per Invoice): Tap any single delivery invoice to mark Fresh Produce (No VAT) or 16% VAT and print an eTIMS QR on that invoice PDF.\n'
                        '• Monthly (By Hotel): Switch to Monthly (By Hotel) to combine a client’s full month deliveries into ONE consolidated eTIMS QR that prints directly onto their Monthly Statement PDF.',
                  ),
                  const SizedBox(height: 10),
                  _helpStepCard(
                    step: '3',
                    title: 'Check Missing Hotel KRA PINs',
                    body:
                        'If any corporate customer is missing a KRA PIN for the selected month, tap the yellow alert banner to save their PIN right from here so your iTax sheet is clean.',
                  ),
                  const SizedBox(height: 10),
                  _helpStepCard(
                    step: '4',
                    title: 'File Monthly Return Before the 20th',
                    body:
                        'Before the 20th of next month, review "Net VAT to Pay KRA", tap Expenses to record VAT you paid on supplies (this reduces VAT owed), then download the Tax Summary (PDF) or iTax Sheet (CSV).',
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('btn_kra_help_got_it'),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Got It'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _helpStepCard({
    required String step,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSage,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppTheme.forestGreen,
            foregroundColor: Colors.white,
            child: Text(
              step,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppTheme.slateInk,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 12.8,
                    height: 1.4,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editCompanyTaxProfile() async {
    final profile = widget.vault.kraProfile;
    var vatReg = profile.vatRegistered;
    var defaultRate = profile.defaultTaxRate;
    var defaultMode = profile.defaultVatMode;
    var oscuSandbox = profile.oscuSandbox;
    String? errorMsg;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: [
          profile.sellerKraPin,
          profile.vatNumber,
          profile.cuSerialNumber,
          profile.etimsBranchId,
          profile.oscuRelayUrl.isNotEmpty
              ? profile.oscuRelayUrl
              : KraOscuService.defaultOscuRelayUrl,
        ],
        builder: (ctx, ctrls) {
          final pinCtrl = ctrls[0];
          final vatNoCtrl = ctrls[1];
          final cuSerialCtrl = ctrls[2];
          final branchCtrl = ctrls[3];
          final oscuUrlCtrl = ctrls[4];
          return StatefulBuilder(
            builder: (ctx, setSheetState) => Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                16,
                18,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Town Treasure KRA & OSCU Setup',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.slateInk,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Section 1: Business KRA Details
                    const Text(
                      '1. Business KRA Details',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppTheme.forestGreen,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('field_kra_seller_pin'),
                      controller: pinCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Company KRA PIN *',
                        hintText: 'e.g. P051234567X',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: vatNoCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'VAT Certificate No. (Optional)',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Registered for VAT'),
                      subtitle: const Text('Supports both Fresh Produce (No VAT) & 16% VAT'),
                      value: vatReg,
                      onChanged: (v) => setSheetState(() => vatReg = v),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Default Tax for New Items',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Fresh Produce (No VAT)'),
                          selected: defaultRate == KraTaxRate.exempt,
                          onSelected: (_) => setSheetState(
                            () => defaultRate = KraTaxRate.exempt,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('16% VAT'),
                          selected: defaultRate == KraTaxRate.standard16,
                          onSelected: (_) => setSheetState(
                            () => defaultRate = KraTaxRate.standard16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'How Item Prices Are Entered',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('VAT Already Included in Price'),
                          selected: defaultMode == KraVatMode.inclusive,
                          onSelected: (_) => setSheetState(
                            () => defaultMode = KraVatMode.inclusive,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Add 16% VAT on Top'),
                          selected: defaultMode == KraVatMode.exclusive,
                          onSelected: (_) => setSheetState(
                            () => defaultMode = KraVatMode.exclusive,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 12),

                    // Section 2: eTIMS OSCU Online Setup
                    const Text(
                      '2. KRA eTIMS Online Connection (OSCU)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: AppTheme.forestGreen,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Used to generate official eTIMS Tax Invoices and QR codes for company buyers.',
                      style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
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
                              labelText: 'OSCU Device Serial',
                              hintText: 'Optional',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
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
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        oscuSandbox ? 'OSCU Mode: KRA Test (Sandbox)' : 'OSCU Mode: KRA Live',
                      ),
                      subtitle: const Text('Switch off when KRA approves live OSCU billing'),
                      value: oscuSandbox,
                      onChanged: (v) => setSheetState(() => oscuSandbox = v),
                    ),
                    TextField(
                      controller: oscuUrlCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'eTIMS OSCU Server Address',
                        hintText: KraOscuService.defaultOscuRelayUrl,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final draftProf = profile.copyWith(
                              sellerKraPin: Restaurant.normalizeKraPin(pinCtrl.text),
                              cuSerialNumber: cuSerialCtrl.text.trim().toUpperCase(),
                              etimsBranchId: branchCtrl.text.trim().isEmpty
                                  ? '00'
                                  : branchCtrl.text.trim(),
                              oscuSandbox: oscuSandbox,
                              oscuRelayUrl: oscuUrlCtrl.text.trim(),
                            );
                            try {
                              await _oscu.initializeDevice(profile: draftProf);
                              _showSnack('OSCU device initialized with KRA.');
                            } catch (e) {
                              setSheetState(
                                () => errorMsg = UserFriendlyError.format(e),
                              );
                            }
                          },
                          icon: const Icon(Icons.link_outlined, size: 17),
                          label: const Text('Initialize OSCU Device'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final draftProf = profile.copyWith(
                              sellerKraPin: Restaurant.normalizeKraPin(pinCtrl.text),
                              cuSerialNumber: cuSerialCtrl.text.trim().toUpperCase(),
                              etimsBranchId: branchCtrl.text.trim().isEmpty
                                  ? '00'
                                  : branchCtrl.text.trim(),
                              oscuSandbox: oscuSandbox,
                              oscuRelayUrl: oscuUrlCtrl.text.trim(),
                            );
                            try {
                              await _oscu.syncProduceCategories(profile: draftProf);
                              _showSnack('Synced 6 KRA produce & tax categories.');
                            } catch (e) {
                              setSheetState(
                                () => errorMsg = UserFriendlyError.format(e),
                              );
                            }
                          },
                          icon: const Icon(Icons.category_outlined, size: 17),
                          label: const Text('Sync Produce Categories'),
                        ),
                      ],
                    ),

                    if (errorMsg != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorMsg!,
                        style: const TextStyle(color: AppTheme.danger, fontSize: 12.5),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const Key('btn_save_kra_profile'),
                      onPressed: () async {
                        final pinNorm = Restaurant.normalizeKraPin(pinCtrl.text);
                        if (pinNorm.isNotEmpty && !Restaurant.isValidKraPin(pinNorm)) {
                          setSheetState(
                            () => errorMsg =
                                'Enter a valid 11-character KRA PIN (e.g. P051234567X).',
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
                          oscuSandbox: oscuSandbox,
                          oscuRelayUrl: oscuUrlCtrl.text.trim(),
                        );
                        await widget.vault.saveKraProfile(next);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        _showSnack('Town Treasure KRA & OSCU settings saved.');
                      },
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Save Settings'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openInvoiceTaxSheet(Invoice invoice) {
    return KraTaxCenterScreen.showInvoiceEtimsSheet(
      context,
      vault: widget.vault,
      invoice: invoice,
      oscuService: _oscu,
      onFeedback: (msg, {isError = false}) => _showSnack(
        msg,
        color: isError ? AppTheme.danger : AppTheme.forestGreen,
      ),
    );
  }

  List<_MonthlyClientGroup> _buildMonthlyClientGroups(List<Invoice> monthInvoices) {
    final grouped = <String, List<Invoice>>{};
    final resolvedRestaurants = <String, Restaurant?>{};
    final displayNames = <String, String>{};

    for (final inv in monthInvoices) {
      final res = Restaurant.resolveInvoiceRestaurant(
        inv,
        widget.vault.restaurants,
      );
      final rest = res.restaurant;
      if (!_showAllClients && rest?.etimsCadence == EtimsCadence.daily) {
        continue;
      }
      final keyId = MonthlyClientEtims.buildId(
        _selectedMonth,
        rest,
        inv.restaurantName,
      );
      grouped.putIfAbsent(keyId, () => []).add(inv);
      resolvedRestaurants[keyId] ??= rest;
      displayNames[keyId] ??= rest?.name ?? inv.restaurantName;
    }

    final result = <_MonthlyClientGroup>[];
    for (final entry in grouped.entries) {
      final invs = entry.value..sort((a, b) => a.date.compareTo(b.date));
      final rest = resolvedRestaurants[entry.key];
      final name = displayNames[entry.key] ?? 'Client';
      final totalSell = invs.fold<double>(0, (s, i) => s + i.totalSell);
      final existing = widget.vault.settings.findMonthlyEtims(
        _selectedMonth,
        rest,
        fallbackName: name,
      );
      result.add(
        _MonthlyClientGroup(
          keyId: entry.key,
          clientName: name,
          restaurant: rest,
          invoices: invs,
          totalSell: totalSell,
          existingEtims: existing,
        ),
      );
    }
    result.sort((a, b) => b.totalSell.compareTo(a.totalSell));
    return result;
  }

  Future<void> _openMonthlyClientEtimsSheet(_MonthlyClientGroup group) async {
    final profile = widget.vault.kraProfile;
    final existing = group.existingEtims;
    final consolidatedItems = <InvoiceLineItem>[];
    var dailyFiscalizedCount = 0;

    for (final inv in group.invoices) {
      if (inv.isFiscalized) dailyFiscalizedCount++;
      if (inv.items.isEmpty) {
        final desc = 'Delivery ${inv.number} (${inv.date})';
        final key = '${consolidatedItems.length}:$desc';
        consolidatedItems.add(
          InvoiceLineItem(
            desc: desc,
            qty: 1,
            buyPrice: 0,
            sellPrice: inv.totalSell,
            total: inv.totalSell,
            taxRate: existing?.lineTaxRates[key] ?? KraTaxRate.exempt.code,
          ),
        );
      } else {
        for (final item in inv.items) {
          final desc = '${inv.number} · ${item.desc}';
          final key = '${consolidatedItems.length}:$desc';
          consolidatedItems.add(
            item.copyWith(
              desc: desc,
              taxRate: existing?.lineTaxRates[key] ?? item.taxRate,
            ),
          );
        }
      }
    }

    final yrMonthCompact = _selectedMonth.replaceAll('-', '');
    final consolidatedTemplate = Invoice(
      id: group.keyId,
      number: 'STMT-$yrMonthCompact-${group.keyId.hashCode.abs() % 10000}',
      restaurantId: group.restaurant?.id ?? '',
      restaurantName: group.clientName,
      date: '$_selectedMonth-28',
      items: consolidatedItems,
      totalSell: group.totalSell,
      vatMode: existing?.vatMode ?? profile.defaultVatMode.code,
      cuInvoiceNumber: existing?.cuInvoiceNumber ?? '',
      etimsRcptSign: existing?.rcptSign ?? '',
      etimsQrData: existing?.qrCodeUrl ?? '',
      etimsSdcDateTime: existing?.sdcDateTime ?? '',
      etimsIntrData: existing?.intrData ?? '',
      etimsInvcNo: existing?.invcNo,
    );

    MonthlyClientEtims toMonthlyRecord(
      Invoice draft,
      KraInvoiceTaxSummary taxSummary,
    ) {
      final lineRates = <String, String>{};
      for (var i = 0; i < draft.items.length; i++) {
        final it = draft.items[i];
        if (it.taxRate != null && it.taxRate!.isNotEmpty) {
          lineRates['$i:${it.desc}'] = it.taxRate!;
        }
      }
      return MonthlyClientEtims(
        id: group.keyId,
        month: _selectedMonth,
        restaurantId: group.restaurant?.id ?? '',
        restaurantName: group.clientName,
        cuInvoiceNumber: (draft.cuInvoiceNumber ?? '').trim(),
        rcptSign: (draft.etimsRcptSign ?? '').trim(),
        qrCodeUrl: (draft.etimsQrData ?? '').trim(),
        vatMode: draft.vatMode ?? KraVatMode.inclusive.code,
        totalAmount: taxSummary.grandTotalWithVat,
        exemptAmount: taxSummary.exemptTotal,
        taxableNetAmount: taxSummary.taxableNetTotal,
        outputVatAmount: taxSummary.outputVatTotal,
        invoiceIds: group.invoices.map((i) => i.id).toList(),
        invcNo: draft.etimsInvcNo,
        sdcDateTime: draft.etimsSdcDateTime ?? '',
        intrData: draft.etimsIntrData ?? '',
        lineTaxRates: lineRates,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
    }

    await KraTaxCenterScreen._showEtimsEditorSheet(
      context,
      vault: widget.vault,
      oscu: _oscu,
      sheetTitle: 'Monthly eTIMS — ${group.clientName}',
      sheetSubtitle:
          '${group.invoices.length} deliveries · ${DateFormat('MMMM yyyy').format(DateTime.parse('$_selectedMonth-01'))}',
      initialInvoice: consolidatedTemplate,
      resolvedBuyer: group.restaurant,
      previewLabel: 'Preview Statement',
      warningBanner: dailyFiscalizedCount > 0
          ? 'Heads up: $dailyFiscalizedCount invoice(s) for ${group.clientName} already have Daily eTIMS issued. Issuing Monthly eTIMS for the same sales may double-report revenue to KRA.'
          : null,
      onPreviewPdf: (draft, taxSummary) {
        final rest = group.restaurant ??
            Restaurant(id: group.keyId, name: group.clientName);
        final stmt = ReportsViewModel(vault: widget.vault).buildStatement(
          rest,
          _selectedMonth,
        );
        final previewRecord = toMonthlyRecord(draft, taxSummary);
        final currentRecords = List<MonthlyClientEtims>.from(
          widget.vault.monthlyEtimsRecords,
        )..removeWhere((r) => r.id == previewRecord.id);
        currentRecords.insert(0, previewRecord);
        final previewSettings =
            widget.vault.settings.withMonthlyEtims(currentRecords);

        AppPrintHelper.openPreview(
          context,
          document: PrintableDocument(
            title: 'Statement — ${group.clientName}',
            filename: 'Statement_${group.clientName}_$_selectedMonth.pdf',
            supportsThermalRoll: false,
            buildPdf: (_) => StatementPdfBuilder.buildPdfBytes(
              stmt,
              settings: previewSettings,
            ),
          ),
        );
      },
      onSave: (draft, taxSummary) async {
        final taxableNames = draft.items
            .where((it) => KraTaxRate.fromCode(it.taxRate) == KraTaxRate.standard16)
            .map((it) => it.desc);
        await widget.vault.learnTaxableKeywords(taxableNames);
        await widget.vault.saveMonthlyEtimsRecord(
          toMonthlyRecord(draft, taxSummary),
        );
        _showSnack(
          'Saved consolidated monthly eTIMS QR for ${group.clientName}.',
        );
      },
    );
  }

  Future<void> _assignClientKraPin(Invoice invoice) async {
    final rest = Restaurant.resolveInvoiceRestaurant(
      invoice,
      widget.vault.restaurants,
    ).restaurant;
    if (rest == null) {
      _showSnack(
        'Link this invoice to a saved restaurant client first.',
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
                      labelText: 'Customer KRA PIN',
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
                    _showSnack('Saved KRA PIN for ${rest.name}.');
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
          exp.supplierName ?? '',
          exp.supplierKraPin ?? '',
          exp.supplierCuInvoiceNumber ?? '',
          (exp.inputVatAmount ?? 0) > 0
              ? exp.inputVatAmount!.toStringAsFixed(2)
              : '',
        ],
        builder: (ctx, ctrls) {
          final supplierNameCtrl = ctrls[0];
          final pinCtrl = ctrls[1];
          final cuCtrl = ctrls[2];
          final vatCtrl = ctrls[3];
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: Text('VAT Paid — ${exp.desc}'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Expense Total: KES ${_moneyFmt.format(exp.amount)}',
                      style: const TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: supplierNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Supplier Name (for iTax)',
                        hintText: 'e.g. Wakulima Traders Ltd',
                      ),
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
                      controller: cuCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Supplier eTIMS CU Invoice No.',
                        hintText: 'Required for iTax Input VAT claim',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: vatCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'VAT Paid (KES)',
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
                        () => errorMsg = 'Enter a valid 11-character Supplier KRA PIN.',
                      );
                      return;
                    }
                    final vatVal = double.tryParse(vatCtrl.text.trim()) ?? 0;
                    final list = List<Expense>.from(widget.vault.expenses);
                    final idx = list.indexWhere((e) => e.id == exp.id);
                    if (idx >= 0) {
                      list[idx] = exp.copyWith(
                        supplierName: supplierNameCtrl.text.trim(),
                        supplierKraPin: pin,
                        supplierCuInvoiceNumber: cuCtrl.text.trim().toUpperCase(),
                        inputVatAmount: vatVal,
                        updatedAt: DateTime.now().toUtc().toIso8601String(),
                      );
                      await widget.vault.setExpenses(list);
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    _showSnack('Updated expense VAT record.');
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
      title: 'KRA Monthly Tax Report $_selectedMonth',
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
                    'Monthly KRA Tax Summary ($_selectedMonth)',
                    style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
                  ),
                  if (profile.normalizedSellerPin.isNotEmpty)
                    pw.Text(
                      'Company PIN: ${profile.normalizedSellerPin}',
                      style: const pw.TextStyle(fontSize: 9.5),
                    ),
                ],
              ),
              pw.Text(
                'File before: ${DateFormat('dd MMM yyyy').format(summary.filingDeadline)}',
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
                _pdfStatRow('Fresh Produce Sales (No VAT)', 'KES ${_moneyFmt.format(summary.exemptSalesTotal)}'),
                _pdfStatRow('Taxable Goods Sales (Net 16%)', 'KES ${_moneyFmt.format(summary.taxableNetSalesTotal)}'),
                _pdfStatRow('VAT Collected on Sales', 'KES ${_moneyFmt.format(summary.outputVatTotal)}'),
                _pdfStatRow('VAT Paid on Purchases', 'KES ${_moneyFmt.format(summary.inputVatTotal)}'),
                pw.Divider(),
                _pdfStatRow(
                  summary.netVatPayable >= 0 ? 'Net VAT to Pay KRA' : 'VAT Credit Carried Forward',
                  'KES ${_moneyFmt.format(summary.netVatPayable.abs())}',
                  bold: true,
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'Invoices (${monthInvoices.length})',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF313A43)),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headers: ['Date', 'Inv No.', 'Client', 'Client PIN', 'No VAT', 'Net 16%', 'VAT 16%', 'CU Inv'],
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
              'Purchases with VAT Paid (${monthExpenses.length})',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 6),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF166534)),
              cellStyle: const pw.TextStyle(fontSize: 8),
              headers: ['Date', 'Supplier PIN', 'Description', 'Amount', 'VAT Paid'],
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
    final monthlyRecs = widget.vault.monthlyEtimsRecords
        .where((r) => r.month == _selectedMonth && r.isFiscalized)
        .toList();
    final monthlyByInvId = <String, MonthlyClientEtims>{};
    for (final rec in monthlyRecs) {
      for (final id in rec.invoiceIds) {
        monthlyByInvId[id] = rec;
      }
    }

    final vatSalesBuf = StringBuffer(
      'PIN of Purchaser,Name of Purchaser,ETR/CU Invoice Date,CU Invoice Number,Description of Goods/Services,Taxable Value (KES),VAT Amount (KES)\n',
    );
    final exemptSalesBuf = StringBuffer(
      'PIN of Purchaser,Name of Purchaser,Invoice Date,Document / CU No,Description,Exempt Value (KES)\n',
    );
    final purchasesBuf = StringBuffer(
      'PIN of Supplier,Name of Supplier,Invoice Date,Supplier eTIMS CU No,Description,Taxable Value (KES),Input VAT Claimed (KES)\n',
    );

    final handledMonthlyIds = <String>{};
    var hasVatSales = false;
    var hasExemptSales = false;

    for (final inv in monthInvoices) {
      final rest = Restaurant.resolveInvoiceRestaurant(inv, widget.vault.restaurants).restaurant;
      final pin = Restaurant.normalizeKraPin(rest?.kraPin);
      final name = rest?.name ?? inv.restaurantName;

      final hasDailyExplicit = inv.isFiscalized ||
          inv.items.any((it) => KraTaxRate.fromCode(it.taxRate) == KraTaxRate.standard16);
      final monthlyRec = monthlyByInvId[inv.id];

      if (!hasDailyExplicit && monthlyRec != null) {
        if (handledMonthlyIds.add(monthlyRec.id)) {
          if (monthlyRec.taxableNetAmount > 0 || monthlyRec.outputVatAmount > 0) {
            hasVatSales = true;
            vatSalesBuf.writeln([
              _csvEsc(pin),
              _csvEsc(monthlyRec.restaurantName),
              _csvEsc('$_selectedMonth-28'),
              _csvEsc(monthlyRec.cuInvoiceNumber),
              _csvEsc('Consolidated Monthly Taxable Supplies'),
              monthlyRec.taxableNetAmount.toStringAsFixed(2),
              monthlyRec.outputVatAmount.toStringAsFixed(2),
            ].join(','));
          }
          if (monthlyRec.exemptAmount > 0) {
            hasExemptSales = true;
            exemptSalesBuf.writeln([
              _csvEsc(pin),
              _csvEsc(monthlyRec.restaurantName),
              _csvEsc('$_selectedMonth-28'),
              _csvEsc(monthlyRec.cuInvoiceNumber),
              _csvEsc('Consolidated Monthly Fresh Produce'),
              monthlyRec.exemptAmount.toStringAsFixed(2),
            ].join(','));
          }
        }
        continue;
      }

      final tax = KraTaxCalculator.computeInvoiceTaxSummary(inv, profile: profile);
      if (tax.taxableNetTotal > 0 || tax.outputVatTotal > 0) {
        hasVatSales = true;
        vatSalesBuf.writeln([
          _csvEsc(pin),
          _csvEsc(name),
          _csvEsc(inv.date),
          _csvEsc(inv.cuInvoiceNumber ?? inv.number),
          _csvEsc('Invoice ${inv.number} Taxable Goods'),
          tax.taxableNetTotal.toStringAsFixed(2),
          tax.outputVatTotal.toStringAsFixed(2),
        ].join(','));
      }
      if (tax.exemptTotal > 0 || tax.zeroRatedTotal > 0) {
        hasExemptSales = true;
        exemptSalesBuf.writeln([
          _csvEsc(pin),
          _csvEsc(name),
          _csvEsc(inv.date),
          _csvEsc(inv.cuInvoiceNumber ?? inv.number),
          _csvEsc('Invoice ${inv.number} Fresh Produce'),
          (tax.exemptTotal + tax.zeroRatedTotal).toStringAsFixed(2),
        ].join(','));
      }
    }

    var hasPurchases = false;
    for (final exp in widget.vault.expenses.where(
      (e) => !e.isCapital && e.date.startsWith(_selectedMonth) && (e.inputVatAmount ?? 0) > 0,
    )) {
      hasPurchases = true;
      final vat = exp.inputVatAmount ?? 0;
      purchasesBuf.writeln([
        _csvEsc(exp.supplierKraPin ?? ''),
        _csvEsc(exp.supplierName?.isNotEmpty == true ? exp.supplierName! : exp.desc),
        _csvEsc(exp.date),
        _csvEsc(exp.supplierCuInvoiceNumber ?? ''),
        _csvEsc(exp.desc),
        (exp.amount - vat).clamp(0, exp.amount).toStringAsFixed(2),
        vat.toStringAsFixed(2),
      ].join(','));
    }

    final dir = await getTemporaryDirectory();
    final files = <XFile>[];
    if (hasVatSales) {
      final f = File('${dir.path}/TownTreasure_iTax_Sales_16VAT_$_selectedMonth.csv');
      await f.writeAsString(vatSalesBuf.toString(), flush: true);
      files.add(XFile(f.path));
    }
    if (hasExemptSales || files.isEmpty) {
      final f = File('${dir.path}/TownTreasure_iTax_Sales_Exempt_$_selectedMonth.csv');
      await f.writeAsString(exemptSalesBuf.toString(), flush: true);
      files.add(XFile(f.path));
    }
    if (hasPurchases) {
      final f = File('${dir.path}/TownTreasure_iTax_Purchases_$_selectedMonth.csv');
      await f.writeAsString(purchasesBuf.toString(), flush: true);
      files.add(XFile(f.path));
    }

    await AppLockGuard.runWithoutRelock(
      () => Share.shareXFiles(
        files,
        subject: 'KRA iTax VAT3 Pack ($_selectedMonth)',
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
      monthlyEtimsRecords: widget.vault.monthlyEtimsRecords,
    );
    final monthInvoices = widget.vault.invoices
        .where((inv) => !inv.isDraft && inv.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final dailyVisibleInvoices = _showAllClients
        ? monthInvoices
        : monthInvoices.where((inv) {
            final rest = Restaurant.resolveInvoiceRestaurant(
              inv,
              widget.vault.restaurants,
            ).restaurant;
            return rest?.etimsCadence != EtimsCadence.monthly;
          }).toList();
    final monthlyGroups = _buildMonthlyClientGroups(monthInvoices);
    final monthExpenses = widget.vault.expenses
        .where((e) => !e.isCapital && e.date.startsWith(_selectedMonth))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('KRA & eTIMS Tax'),
        actions: [
          IconButton(
            key: const Key('btn_kra_help'),
            tooltip: 'How KRA & eTIMS Works',
            onPressed: _openHelpGuide,
            icon: const Icon(Icons.help_outline),
          ),
          IconButton(
            key: const Key('btn_edit_kra_profile'),
            tooltip: 'Tax & OSCU Setup',
            onPressed: _editCompanyTaxProfile,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // 1. Clean Business Tax & OSCU Banner
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.sageTint,
                foregroundColor: AppTheme.forestGreenDeep,
                child: const Icon(Icons.verified_outlined),
              ),
              title: Text(
                profile.hasValidSellerPin
                    ? 'Company PIN: ${profile.normalizedSellerPin}'
                    : 'Set Town Treasure KRA PIN',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${profile.vatRegistered ? 'VAT Registered' : 'Non-VAT'} · OSCU ${profile.oscuSandbox ? 'Test' : 'Live'}${profile.cuSerialNumber.isNotEmpty ? ' · ${profile.cuSerialNumber}' : ''}',
                style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
              trailing: TextButton(
                onPressed: _editCompanyTaxProfile,
                child: const Text('Setup'),
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
                    labelText: 'Month',
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
              if (profile.vatRegistered) ...[
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
                        'FILE BEFORE',
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
            ],
          ),
          const SizedBox(height: 12),

          // 3. Monthly Tax Summary Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    profile.vatRegistered
                        ? 'Monthly Tax Summary'
                        : 'Monthly eTIMS Sales Summary',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (profile.vatRegistered) ...[
                    _statLine('Fresh Produce (No VAT)', summary.exemptSalesTotal),
                    _statLine('16% VAT Goods (Net)', summary.taxableNetSalesTotal),
                    _statLine('VAT Collected on Sales', summary.outputVatTotal,
                        color: AppTheme.info),
                    _statLine('VAT Paid on Purchases', summary.inputVatTotal,
                        color: AppTheme.forestGreen),
                    const Divider(),
                    _statLine(
                      summary.netVatPayable >= 0
                          ? 'Net VAT to Pay KRA'
                          : 'VAT Credit Balance',
                      summary.netVatPayable.abs(),
                      bold: true,
                      color: summary.netVatPayable > 0
                          ? AppTheme.danger
                          : AppTheme.forestGreenDeep,
                    ),
                  ] else ...[
                    _statLine(
                      'Total Sales (${summary.invoiceCount} invoices)',
                      summary.exemptSalesTotal + summary.zeroRatedSalesTotal,
                      bold: true,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('btn_export_vat3_pdf'),
                          onPressed: () {
                            AppPrintHelper.openPreview(
                              context,
                              document: PrintableDocument(
                                title: 'Tax Summary ($_selectedMonth)',
                                filename: 'KRA_Summary_$_selectedMonth.pdf',
                                supportsThermalRoll: false,
                                buildPdf: (_) => _buildVat3ReturnPdf(summary),
                              ),
                            );
                          },
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('Tax Summary PDF'),
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

          // 4. Missing Hotel/Company KRA PINs
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
                      '${summary.invoicesMissingClientPin.length} Client(s) Missing KRA PIN',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.warning,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap an invoice below to add the hotel or company KRA PIN:',
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

          // 5. eTIMS Invoices List — Daily (Per Invoice) or Monthly (Consolidated by Hotel)
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'eTIMS QR & VAT Billing',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateInk,
                  ),
                ),
              ),
              FilterChip(
                label: const Text('Show All', style: TextStyle(fontSize: 11.5)),
                selected: _showAllClients,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _showAllClients = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            key: const Key('segmented_etims_cadence'),
            segments: [
              ButtonSegment<bool>(
                value: false,
                icon: const Icon(Icons.receipt_long_outlined, size: 17),
                label: Text('Daily (${dailyVisibleInvoices.length})'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: const Icon(Icons.apartment_outlined, size: 17),
                label: Text('Monthly Hotel (${monthlyGroups.length})'),
              ),
            ],
            selected: {_monthlyEtimsMode},
            onSelectionChanged: (sel) {
              setState(() => _monthlyEtimsMode = sel.first);
            },
          ),
          const SizedBox(height: 10),
          if (!_monthlyEtimsMode) ...[
            if (dailyVisibleInvoices.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No daily-billed invoices for this month.'),
                ),
              )
            else
              ...dailyVisibleInvoices.map((inv) {
                final tax = KraTaxCalculator.computeInvoiceTaxSummary(
                  inv,
                  profile: profile,
                );
                final hasQr = (inv.etimsQrData ?? '').trim().isNotEmpty;
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
                      [
                        if (hasQr) 'eTIMS QR Ready',
                        if (inv.hasCreditNote) 'Reversed (CN: ${inv.etimsCreditNoteCuNo})',
                        if (!hasQr && inv.cuInvoiceNumber?.isNotEmpty == true)
                          'CU: ${inv.cuInvoiceNumber}',
                        if (profile.vatRegistered && tax.outputVatTotal > 0)
                          'VAT: KES ${_moneyFmt.format(tax.outputVatTotal)}'
                        else
                          'Produce (No VAT): KES ${_moneyFmt.format(tax.exemptTotal)}',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: hasQr ? AppTheme.forestGreen : AppTheme.slateMuted,
                        fontWeight: hasQr ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    trailing: Icon(
                      hasQr ? Icons.qr_code_2 : Icons.edit_note_outlined,
                      color: hasQr ? AppTheme.forestGreen : AppTheme.slateMuted,
                    ),
                  ),
                );
              }),
          ] else ...[
            if (monthlyGroups.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No monthly-billed hotels found for this month.'),
                ),
              )
            else
              ...monthlyGroups.map((group) {
                final rec = group.existingEtims;
                final hasMonthlyQr = rec?.hasQr == true;
                final currentIds = group.invoices.map((i) => i.id).toList();
                final isStale = rec != null &&
                    rec.isFiscalized &&
                    (!listEquals(rec.invoiceIds, currentIds) ||
                        (rec.totalAmount - group.totalSell).abs() > 1.0);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    key: Key('kra_monthly_${group.keyId}'),
                    onTap: () => _openMonthlyClientEtimsSheet(group),
                    title: Text(
                      group.clientName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        '${group.invoices.length} invoices · KES ${_moneyFmt.format(group.totalSell)}',
                        if (hasMonthlyQr && isStale)
                          'Deliveries updated — review monthly eTIMS'
                        else if (hasMonthlyQr)
                          'Monthly QR Ready${rec!.cuInvoiceNumber.isNotEmpty ? ' · CU: ${rec.cuInvoiceNumber}' : ''}'
                        else
                          'Tap to issue monthly eTIMS QR',
                      ].join('\n'),
                      style: TextStyle(
                        fontSize: 12,
                        color: isStale
                            ? AppTheme.warning
                            : (hasMonthlyQr
                                ? AppTheme.forestGreen
                                : AppTheme.slateMuted),
                        fontWeight: (hasMonthlyQr || isStale)
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: Icon(
                      isStale
                          ? Icons.sync_problem_outlined
                          : (hasMonthlyQr
                              ? Icons.qr_code_2
                              : Icons.summarize_outlined),
                      color: isStale
                          ? AppTheme.warning
                          : (hasMonthlyQr
                              ? AppTheme.forestGreen
                              : AppTheme.slateMuted),
                    ),
                  ),
                );
              }),
          ],

          // 6. Monthly Purchases VAT (VAT-registered businesses only)
          if (profile.vatRegistered) ...[
            const SizedBox(height: 16),
            Text(
              'Monthly Expenses — Record VAT Paid (${monthExpenses.length})',
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
                      '${exp.date} · KES ${_moneyFmt.format(exp.amount)}${(exp.inputVatAmount ?? 0) > 0 ? ' · VAT Paid: KES ${_moneyFmt.format(exp.inputVatAmount!)}' : ' · Tap if purchase included 16% VAT'}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                    ),
                    trailing: const Icon(Icons.receipt_outlined),
                  ),
                ),
              ),
          ],
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

class _MonthlyClientGroup {
  const _MonthlyClientGroup({
    required this.keyId,
    required this.clientName,
    required this.restaurant,
    required this.invoices,
    required this.totalSell,
    required this.existingEtims,
  });

  final String keyId;
  final String clientName;
  final Restaurant? restaurant;
  final List<Invoice> invoices;
  final double totalSell;
  final MonthlyClientEtims? existingEtims;
}
