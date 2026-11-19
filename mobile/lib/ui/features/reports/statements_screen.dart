import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/print_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../invoices/invoice_formatters.dart';
import 'reports_view_model.dart';
import 'statement_pdf_builder.dart';

/// Monthly Client Statements builder, A4 PDF, and WhatsApp sharing screen.
class StatementsScreen extends StatefulWidget {
  const StatementsScreen({
    super.key,
    this.viewModel,
    this.initialRestaurantId,
    this.initialMonth,
  });

  final ReportsViewModel? viewModel;
  final String? initialRestaurantId;
  final String? initialMonth;

  @override
  State<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends State<StatementsScreen> {
  static const String _allKey = '__all__';

  ReportsViewModel? _ownedVm;
  late String _selectedRestaurantId;
  late String _selectedMonth;
  bool _busy = false;

  ReportsViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _selectedMonth =
        widget.initialMonth ?? DateFormat('yyyy-MM').format(DateTime.now());
    _selectedRestaurantId = widget.initialRestaurantId ?? '';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = ReportsViewModel(vault: context.read<VaultRepository>());
    }
  }

  @override
  void dispose() {
    _ownedVm?.dispose();
    super.dispose();
  }

  Future<void> _pickMonth() async {
    final parts = _selectedMonth.split('-');
    final initial = DateTime(
      int.tryParse(parts.firstOrNull ?? '') ?? DateTime.now().year,
      int.tryParse(parts.elementAtOrNull(1) ?? '') ?? DateTime.now().month,
      1,
    );
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
      helpText: 'Select Statement Month',
    );
    if (picked != null) {
      setState(() {
        _selectedMonth = DateFormat('yyyy-MM').format(picked);
      });
    }
  }

  Restaurant? _selectedSingleRestaurant() {
    if (_selectedRestaurantId.isEmpty || _selectedRestaurantId == _allKey) {
      return null;
    }
    return _vm.restaurants
        .where((r) => r.id == _selectedRestaurantId)
        .firstOrNull;
  }

  Future<void> _downloadPdf() async {
    final rest = _selectedSingleRestaurant();
    if (rest == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a specific restaurant to generate a PDF'),
        ),
      );
      return;
    }
    final stmt = _vm.buildStatement(rest, _selectedMonth);
    await showPrintOptionsSheet(
      context,
      document: PrintableDocument(
        title: 'Statement - ${rest.name} (${stmt.monthName})',
        filename:
            'Statement_${rest.name.replaceAll(' ', '_')}_${stmt.monthName}.pdf',
        supportsThermalRoll: false,
        buildPdf: (_) => StatementPdfBuilder.buildPdfBytes(
          stmt,
          settings: _vm.settings,
        ),
        buildEscPos: (cols) => EscPosReceiptBuilder.buildSummaryReceipt(
          title: 'Statement: ${rest.name}',
          lines: [
            'Period: ${stmt.monthName}',
            'Entries: ${stmt.transactions.length}',
            'Opening: KES ${InvoiceFormatters.formatMoney(stmt.openingBalance)}',
            'Billed: KES ${InvoiceFormatters.formatMoney(stmt.monthInvoicedTotal)}',
            'Paid: KES ${InvoiceFormatters.formatMoney(stmt.monthPaidTotal)}',
            'Balance Due: KES ${InvoiceFormatters.formatMoney(stmt.closingBalance)}',
          ],
          lineWidth: cols,
        ),
      ),
    );
  }

  Future<void> _sharePdf() async {
    final rest = _selectedSingleRestaurant();
    if (rest == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a specific restaurant to share a PDF'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final stmt = _vm.buildStatement(rest, _selectedMonth);
      final file = await StatementPdfBuilder.writeTempPdfFile(
        stmt,
        settings: _vm.settings,
      );
      final text = ReportsViewModel.buildStatementWhatsAppText(
        rest,
        stmt.monthName,
      );
      await AppLockGuard.runWithoutRelock(
        () => Share.shareXFiles(
          [
            XFile(
              file.path,
              mimeType: 'application/pdf',
              name: file.uri.pathSegments.last,
            ),
          ],
          subject: 'Statement - ${rest.name} (${stmt.monthName})',
          text: text,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not share statement: ${UserFriendlyError.format(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareWhatsApp() async {
    final rest = _selectedSingleRestaurant();
    if (rest == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a specific restaurant to share via WhatsApp'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final stmt = _vm.buildStatement(rest, _selectedMonth);
    final text = ReportsViewModel.buildStatementWhatsAppText(
      rest,
      stmt.monthName,
    );
    try {
      final file = await StatementPdfBuilder.writeTempPdfFile(
        stmt,
        settings: _vm.settings,
      );
      await AppLockGuard.runWithoutRelock(
        () => Share.shareXFiles(
          [
            XFile(
              file.path,
              mimeType: 'application/pdf',
              name: file.uri.pathSegments.last,
            ),
          ],
          subject: 'Statement - ${rest.name} (${stmt.monthName})',
          text: text,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not attach statement PDF: ${UserFriendlyError.format(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final rests = _vm.restaurants;
        final validValue = (_selectedRestaurantId == _allKey ||
                rests.any((r) => r.id == _selectedRestaurantId))
            ? _selectedRestaurantId
            : '';

        final statements = validValue == _allKey
            ? _vm.buildAllStatements(_selectedMonth)
            : (_selectedSingleRestaurant() != null
                ? [_vm.buildStatement(_selectedSingleRestaurant()!, _selectedMonth)]
                : <ClientStatementData>[]);

        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Monthly Statements'),
            actions: [
              IconButton(
                tooltip: 'Download / Print PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: _busy ? null : _downloadPdf,
              ),
              IconButton(
                tooltip: 'Share Statement',
                icon: const Icon(Icons.share_outlined),
                onPressed: _busy ? null : _sharePdf,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: validValue,
                        decoration:
                            const InputDecoration(labelText: 'Restaurant'),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Select restaurant...'),
                          ),
                          const DropdownMenuItem(
                            value: _allKey,
                            child: Text('All Restaurants (Consolidated)'),
                          ),
                          for (final r in rests)
                            DropdownMenuItem(
                              value: r.id,
                              child: Text(r.name),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _selectedRestaurantId = v ?? '');
                        },
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickMonth,
                              icon: const Icon(Icons.calendar_month, size: 18),
                              label: Text('Month: $_selectedMonth'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _busy ? null : _downloadPdf,
                            icon: const Icon(Icons.download_outlined, size: 18),
                            label: const Text('PDF'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _shareWhatsApp,
                            icon: const Icon(Icons.chat_outlined, size: 18),
                            label: const Text('WhatsApp'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              if (statements.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'Select a restaurant and month to preview its monthly statement.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.slateMuted),
                      ),
                    ),
                  ),
                )
              else
                for (final stmt in statements) ...[
                  _StatementPreviewCard(statement: stmt),
                  const SizedBox(height: 14),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _StatementPreviewCard extends StatelessWidget {
  const _StatementPreviewCard({required this.statement});

  final ClientStatementData statement;

  @override
  Widget build(BuildContext context) {
    final firstMonthWord = statement.monthName.split(' ').first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 8, color: AppTheme.leafGreen),
          Container(height: 3, color: AppTheme.slateDark),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'MONTHLY STATEMENT',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.leafGreen,
                      ),
                    ),
                    Text(
                      statement.monthName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FROM:',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                        Text(
                          'Town Treasure Limited',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.forestGreen,
                          ),
                        ),
                        Text('0708567696', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'TO:',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.slateMuted,
                          ),
                        ),
                        Text(
                          statement.restaurant.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (statement.restaurant.phone.isNotEmpty)
                          Text(
                            statement.restaurant.phone,
                            style: const TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceSage,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.borderSubtle),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Previous Unpaid Balance (Prior to 1 $firstMonthWord):',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        'KES ${ReportsViewModel.formatMoney(statement.openingBalance)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: statement.openingBalance > 0
                              ? AppTheme.danger
                              : AppTheme.forestGreen,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (statement.transactions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        'No transactions this month',
                        style: TextStyle(color: AppTheme.slateMuted),
                      ),
                    ),
                  )
                else
                  for (final tx in statement.transactions)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 6,
                      ),
                      decoration: BoxDecoration(
                        color: tx.type == 'payment'
                            ? AppTheme.successSurface.withValues(alpha: 0.45)
                            : Colors.transparent,
                        border: const Border(
                          bottom: BorderSide(
                            color: AppTheme.borderSubtle,
                            width: 0.8,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tx.desc,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${ReportsViewModel.formatDate(tx.date)}'
                                  '${tx.itemsLabel.isNotEmpty ? ' | ${tx.itemsLabel}' : ''}',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.slateMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (tx.debit > 0)
                                Text(
                                  '+KES ${ReportsViewModel.formatMoney(tx.debit)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              if (tx.credit > 0)
                                Text(
                                  '-KES ${ReportsViewModel.formatMoney(tx.credit)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.forestGreen,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              Text(
                                'Bal KES ${ReportsViewModel.formatMoney(tx.balance)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 14),
                _TotalRow(
                  label: 'Total Invoiced:',
                  value:
                      'KES ${ReportsViewModel.formatMoney(statement.monthInvoicedTotal)}',
                  color: AppTheme.danger,
                ),
                _TotalRow(
                  label: 'Total Paid:',
                  value:
                      'KES ${ReportsViewModel.formatMoney(statement.monthPaidTotal)}',
                  color: AppTheme.forestGreen,
                ),
                const Divider(color: AppTheme.leafGreen, thickness: 1.5),
                _TotalRow(
                  label: 'Total Amount Owed:',
                  value:
                      'KES ${ReportsViewModel.formatMoney(statement.closingBalance)}',
                  color: statement.closingBalance > 0
                      ? AppTheme.danger
                      : AppTheme.forestGreen,
                  bold: true,
                ),
                if (statement.closingBalance > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFED7AA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Debt Age Analysis',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF92400E),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _AgeBucket(
                              label: 'Current',
                              amount: statement.ageAnalysis.current,
                              color: AppTheme.forestGreen,
                            ),
                            _AgeBucket(
                              label: '30 Days',
                              amount: statement.ageAnalysis.days30,
                              color: AppTheme.warning,
                            ),
                            _AgeBucket(
                              label: '60 Days',
                              amount: statement.ageAnalysis.days60,
                              color: const Color(0xFFEA580C),
                            ),
                            _AgeBucket(
                              label: '90+ Days',
                              amount: statement.ageAnalysis.days90,
                              color: AppTheme.danger,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.slateDark,
            child: Text(
              'Thank you for your business, ${statement.restaurant.name}!',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.value,
    required this.color,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              fontSize: bold ? 14 : 13,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: bold ? 14.5 : 13,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgeBucket extends StatelessWidget {
  const _AgeBucket({
    required this.label,
    required this.amount,
    required this.color,
  });

  final String label;
  final double amount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.slateMuted),
        ),
        Text(
          'KES ${ReportsViewModel.formatMoney(amount)}',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}
