import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/print_options_sheet.dart';
import 'reports_view_model.dart';
import 'statements_screen.dart';

/// Reports, Analytics Charts, Monthly P&L, Smart Insights, and PDF/Excel Export screen.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    this.viewModel,
    this.onOpenStatements,
  });

  final ReportsViewModel? viewModel;
  final VoidCallback? onOpenStatements;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen>
    with SingleTickerProviderStateMixin {
  ReportsViewModel? _ownedVm;
  late TabController _tabController;

  late String _pnlMonth;
  String _reportType = 'general';
  String _dateType = 'single';
  late String _singleDate;
  late String _fromDate;
  late String _toDate;
  String? _selectedRestaurantId;
  String? _selectedProductKey;
  GeneratedReportData? _activeReport;
  bool _exporting = false;
  int? _touchedBarIndex;

  ReportsViewModel get _vm => widget.viewModel ?? _ownedVm!;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    final now = DateTime.now();
    _pnlMonth = DateFormat('yyyy-MM').format(now);
    final today = DateFormat('yyyy-MM-dd').format(now);
    _singleDate = today;
    _fromDate = today;
    _toDate = today;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.viewModel == null && _ownedVm == null) {
      _ownedVm = ReportsViewModel(vault: context.read<VaultRepository>());
    }
    _activeReport ??= _generateCurrentReport();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _ownedVm?.dispose();
    super.dispose();
  }

  GeneratedReportData _generateCurrentReport() {
    return _vm.generateReport(
      type: _reportType,
      dateType: _dateType,
      singleDate: _singleDate,
      fromDate: _fromDate,
      toDate: _toDate,
      restaurantId: _selectedRestaurantId,
      productQuery: _selectedProductKey,
    );
  }

  void _refreshReport() {
    if (_reportType == 'product' &&
        (_selectedProductKey == null || _selectedProductKey!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a product first')),
      );
      return;
    }
    setState(() {
      _activeReport = _generateCurrentReport();
    });
  }

  Future<void> _pickPnlMonth() async {
    final parts = _pnlMonth.split('-');
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
      helpText: 'Select P&L Month',
    );
    if (picked != null) {
      setState(() {
        _pnlMonth = DateFormat('yyyy-MM').format(picked);
      });
    }
  }

  Future<void> _pickFilterDate({required String target}) async {
    final currentStr = switch (target) {
      'single' => _singleDate,
      'from' => _fromDate,
      _ => _toDate,
    };
    final initial = DateTime.tryParse(currentStr) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) {
      final formatted = DateFormat('yyyy-MM-dd').format(picked);
      setState(() {
        if (target == 'single') _singleDate = formatted;
        if (target == 'from') _fromDate = formatted;
        if (target == 'to') _toDate = formatted;
      });
    }
  }

  Future<void> _exportPdf() async {
    final report = _activeReport ?? _generateCurrentReport();
    await showPrintOptionsSheet(
      context,
      document: PrintableDocument(
        title: 'Report: ${report.dateRangeLabel}',
        filename: 'Report_${report.type}.pdf',
        supportsThermalRoll: false,
        buildPdf: (_) => _vm.buildReportPdfBytes(report),
      ),
    );
  }

  Future<void> _exportExcel() async {
    final report = _activeReport ?? _generateCurrentReport();
    setState(() => _exporting = true);
    try {
      final file = await _vm.writeTempExcelFile(report);
      await AppLockGuard.runWithoutRelock(
        () => Share.shareXFiles(
          [XFile(file.path)],
          subject: 'Town Treasure Financial Export (${report.dateRangeLabel})',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not export Excel: ${UserFriendlyError.format(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _openStatements() {
    if (widget.onOpenStatements != null) {
      widget.onOpenStatements!();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatementsScreen(viewModel: _vm),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppTheme.surfaceSage,
          appBar: AppBar(
            title: const Text('Reports & Insights'),
            actions: [
              TextButton.icon(
                onPressed: _openStatements,
                icon: const Icon(
                  Icons.description_outlined,
                  color: Colors.white,
                  size: 18,
                ),
                label: const Text(
                  'Statements',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: AppTheme.leafGreen,
              tabs: const [
                Tab(icon: Icon(Icons.bar_chart_outlined), text: 'Charts'),
                Tab(icon: Icon(Icons.lightbulb_outline), text: 'Insights'),
                Tab(icon: Icon(Icons.account_balance_outlined), text: 'Monthly P&L'),
                Tab(icon: Icon(Icons.analytics_outlined), text: 'Report Builder'),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildChartsTab(),
              _buildInsightsTab(),
              _buildMonthlyPnlTab(),
              _buildReportBuilderTab(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChartsTab() {
    final trend = _vm.buildMonthlyTrend(months: 6);
    final breakdown = _vm.buildExpenseBreakdown(_pnlMonth);
    final maxVal = trend.fold<double>(
      1000,
      (m, p) => [m, p.revenue, p.profit].reduce((a, b) => a > b ? a : b),
    );

    const sliceColors = [
      AppTheme.forestGreen,
      AppTheme.leafGreen,
      AppTheme.info,
      AppTheme.warning,
      AppTheme.danger,
      AppTheme.slateDark,
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Revenue vs Gross Profit (6 Months)',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppTheme.slateInk,
                  ),
                ),
                const SizedBox(height: 6),
                const Row(
                  children: [
                    _LegendDot(color: AppTheme.forestGreen, label: 'Revenue'),
                    SizedBox(width: 14),
                    _LegendDot(color: AppTheme.leafGreen, label: 'Profit'),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 230,
                  child: BarChart(
                    BarChartData(
                      maxY: maxVal * 1.15,
                      barTouchData: BarTouchData(
                        touchCallback: (event, response) {
                          if (!event.isInterestedForInteractions ||
                              response == null ||
                              response.spot == null) {
                            setState(() => _touchedBarIndex = null);
                            return;
                          }
                          setState(
                            () => _touchedBarIndex =
                                response.spot!.touchedBarGroupIndex,
                          );
                        },
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            final pt = trend[groupIndex];
                            final label = rodIndex == 0 ? 'Revenue' : 'Profit';
                            return BarTooltipItem(
                              '${pt.label} $label\nKES ${ReportsViewModel.formatMoney(rod.toY)}',
                              const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 11.5,
                              ),
                            );
                          },
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 48,
                            getTitlesWidget: (val, meta) => Text(
                              val >= 1000
                                  ? '${(val / 1000).toStringAsFixed(0)}k'
                                  : val.toStringAsFixed(0),
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (val, meta) {
                              final idx = val.toInt();
                              if (idx < 0 || idx >= trend.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  trend[idx].label,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: _touchedBarIndex == idx
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: AppTheme.slateInk,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: const FlGridData(show: true),
                      borderData: FlBorderData(show: false),
                      barGroups: [
                        for (var i = 0; i < trend.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: trend[i].revenue,
                                color: AppTheme.forestGreen,
                                width: 12,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4),
                                ),
                              ),
                              BarChartRodData(
                                toY: trend[i].profit < 0 ? 0 : trend[i].profit,
                                color: AppTheme.leafGreen,
                                width: 12,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Expenses by Category',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    TextButton(
                      onPressed: _pickPnlMonth,
                      child: Text(_pnlMonth),
                    ),
                  ],
                ),
                if (breakdown.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        'No expense entries recorded for this month.',
                        style: TextStyle(color: AppTheme.slateMuted),
                      ),
                    ),
                  )
                else ...[
                  SizedBox(
                    height: 190,
                    child: PieChart(
                      PieChartData(
                        centerSpaceRadius: 36,
                        sectionsSpace: 2,
                        sections: [
                          for (var i = 0; i < breakdown.length; i++)
                            PieChartSectionData(
                              value: breakdown[i].amount,
                              color: sliceColors[i % sliceColors.length],
                              title: '',
                              radius: 48,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < breakdown.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: sliceColors[i % sliceColors.length],
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(breakdown[i].label)),
                          Text(
                            'KES ${ReportsViewModel.formatMoney(breakdown[i].amount)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInsightsTab() {
    final insights = _vm.generateInsights();
    if (insights.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Everything looks good! No alerts right now.',
            style: TextStyle(color: AppTheme.slateMuted),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (insights.urgent.isNotEmpty)
          _InsightGroupCard(
            title: 'Urgent',
            icon: Icons.error_outline,
            color: AppTheme.danger,
            background: AppTheme.dangerSurface,
            messages: insights.urgent,
          ),
        if (insights.attention.isNotEmpty)
          _InsightGroupCard(
            title: 'Attention',
            icon: Icons.warning_amber_rounded,
            color: AppTheme.warning,
            background: AppTheme.warningSurface,
            messages: insights.attention,
          ),
        if (insights.good.isNotEmpty)
          _InsightGroupCard(
            title: 'Good News',
            icon: Icons.check_circle_outline,
            color: AppTheme.forestGreen,
            background: AppTheme.successSurface,
            messages: insights.good,
          ),
      ],
    );
  }

  Widget _buildMonthlyPnlTab() {
    final pnl = _vm.buildMonthlyPnL(_pnlMonth);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Monthly P&L',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.slateInk,
                          ),
                        ),
                        Text(
                          pnl.monthName,
                          style: const TextStyle(color: AppTheme.slateMuted),
                        ),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: _pickPnlMonth,
                      icon: const Icon(Icons.calendar_month, size: 18),
                      label: Text(_pnlMonth),
                    ),
                  ],
                ),
                if (pnl.revenueChangePct != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: pnl.revenueChangePct! >= 0
                          ? AppTheme.successSurface
                          : AppTheme.dangerSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${pnl.revenueChangePct! >= 0 ? 'Up' : 'Down'} '
                      '${pnl.revenueChangePct!.abs().toStringAsFixed(1)}% vs last month',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: pnl.revenueChangePct! >= 0
                            ? AppTheme.forestGreen
                            : AppTheme.danger,
                      ),
                    ),
                  ),
                ],
                const Divider(height: 24),
                const Text(
                  'INCOME',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateMuted,
                  ),
                ),
                const SizedBox(height: 8),
                _PnlLine(
                  label: 'Sales Revenue',
                  value: 'KES ${ReportsViewModel.formatMoney(pnl.revenue)}',
                  valueColor: AppTheme.forestGreen,
                  bold: true,
                ),
                _PnlLine(
                  label: 'Less: Cost of Goods',
                  value: '(KES ${ReportsViewModel.formatMoney(pnl.cogs)})',
                  valueColor: AppTheme.danger,
                ),
                const Divider(height: 16),
                _PnlLine(
                  label: 'Gross Profit',
                  value:
                      'KES ${ReportsViewModel.formatMoney(pnl.grossProfit)}'
                      '${pnl.grossMarginPct != null ? ' (${pnl.grossMarginPct!.toStringAsFixed(1)}%)' : ''}',
                  valueColor: pnl.grossProfit >= 0
                      ? AppTheme.forestGreen
                      : AppTheme.danger,
                  bold: true,
                ),
                const SizedBox(height: 18),
                const Text(
                  'EXPENSES',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateMuted,
                  ),
                ),
                const SizedBox(height: 8),
                if (pnl.salaryTotal > 0)
                  _PnlLine(
                    label: 'Salaries & Payroll',
                    value:
                        '(KES ${ReportsViewModel.formatMoney(pnl.salaryTotal)})',
                    valueColor: AppTheme.danger,
                  ),
                for (final entry in pnl.expensesByCategory)
                  _PnlLine(
                    label: entry.key,
                    value: '(KES ${ReportsViewModel.formatMoney(entry.value)})',
                    valueColor: AppTheme.danger,
                  ),
                const Divider(height: 16),
                _PnlLine(
                  label: 'Total Expenses',
                  value:
                      '(KES ${ReportsViewModel.formatMoney(pnl.totalExpenses)})',
                  valueColor: AppTheme.danger,
                  bold: true,
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: pnl.netProfit >= 0
                        ? AppTheme.successSurface
                        : AppTheme.dangerSurface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'NET PROFIT',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'KES ${ReportsViewModel.formatMoney(pnl.netProfit)}'
                        '${pnl.netMarginPct != null ? ' (${pnl.netMarginPct!.toStringAsFixed(1)}%)' : ''}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: pnl.netProfit >= 0
                              ? AppTheme.forestGreen
                              : AppTheme.danger,
                        ),
                      ),
                    ],
                  ),
                ),
                if (pnl.capitalAdded > 0) ...[
                  const SizedBox(height: 12),
                  _PnlLine(
                    label: 'Capital Added',
                    value:
                        'KES ${ReportsViewModel.formatMoney(pnl.capitalAdded)}',
                    valueColor: AppTheme.info,
                    bold: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReportBuilderTab() {
    final products = _vm.getProductCatalog();
    final report = _activeReport ?? _generateCurrentReport();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _reportType,
                  decoration: const InputDecoration(labelText: 'Report Type'),
                  items: const [
                    DropdownMenuItem(
                      value: 'general',
                      child: Text('General — All Sales'),
                    ),
                    DropdownMenuItem(
                      value: 'restaurant',
                      child: Text('By Restaurant'),
                    ),
                    DropdownMenuItem(
                      value: 'product',
                      child: Text('By Product'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _reportType = v;
                    });
                  },
                ),
                if (_reportType == 'restaurant') ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _vm.restaurants.any(
                            (r) => r.id == _selectedRestaurantId)
                        ? _selectedRestaurantId
                        : null,
                    decoration: const InputDecoration(labelText: 'Restaurant'),
                    items: _vm.restaurants
                        .map(
                          (r) => DropdownMenuItem(
                            value: r.id,
                            child: Text(r.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedRestaurantId = v),
                  ),
                ],
                if (_reportType == 'product') ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue:
                        products.any((p) => p.key == _selectedProductKey)
                            ? _selectedProductKey
                            : null,
                    decoration: const InputDecoration(labelText: 'Product'),
                    items: products
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.key,
                            child: Text(
                              '${p.name} — ${p.qty} ${p.unit} (${p.count}x)',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedProductKey = v),
                  ),
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _dateType,
                  decoration: const InputDecoration(labelText: 'Date Filter'),
                  items: const [
                    DropdownMenuItem(
                      value: 'single',
                      child: Text('Single Date'),
                    ),
                    DropdownMenuItem(
                      value: 'range',
                      child: Text('Date Range'),
                    ),
                    DropdownMenuItem(
                      value: 'all',
                      child: Text('All Time'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _dateType = v);
                  },
                ),
                if (_dateType == 'single') ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _pickFilterDate(target: 'single'),
                    icon: const Icon(Icons.calendar_today, size: 17),
                    label: Text('Date: ${ReportsViewModel.formatDate(_singleDate)}'),
                  ),
                ] else if (_dateType == 'range') ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pickFilterDate(target: 'from'),
                          child: Text(
                            'From: ${ReportsViewModel.formatDate(_fromDate)}',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pickFilterDate(target: 'to'),
                          child: Text(
                            'To: ${ReportsViewModel.formatDate(_toDate)}',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _refreshReport,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Generate'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exporting ? null : _exportPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exporting ? null : _exportExcel,
                      icon: const Icon(Icons.table_chart_outlined),
                      label: const Text('Excel'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  report.isProduct ? 'PRODUCT REPORT' : 'FINANCIAL REPORT',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.leafGreen,
                  ),
                ),
                Text(
                  '${report.targetLabel} | ${report.dateRangeLabel}',
                  style: const TextStyle(
                    color: AppTheme.slateMuted,
                    fontSize: 12.5,
                  ),
                ),
                const Divider(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    if (report.isProduct)
                      _MetricTile(
                        label: 'Qty Sold',
                        value: report.unitSummary,
                        color: AppTheme.info,
                      ),
                    _MetricTile(
                      label: 'Total Sales',
                      value: 'KES ${ReportsViewModel.formatMoney(report.totalSell)}',
                      color: AppTheme.forestGreen,
                    ),
                    _MetricTile(
                      label: 'Total Cost',
                      value: 'KES ${ReportsViewModel.formatMoney(report.totalBuy)}',
                      color: AppTheme.danger,
                    ),
                    _MetricTile(
                      label: report.isGeneral ? 'Gross Profit' : 'Profit',
                      value:
                          'KES ${ReportsViewModel.formatMoney(report.totalProfit)}',
                      color: report.totalProfit >= 0
                          ? AppTheme.forestGreen
                          : AppTheme.danger,
                    ),
                    if (report.isGeneral) ...[
                      _MetricTile(
                        label: 'Expenses',
                        value:
                            'KES ${ReportsViewModel.formatMoney(report.totalExpenses)}',
                        color: AppTheme.danger,
                      ),
                      _MetricTile(
                        label: 'Capital In',
                        value:
                            'KES ${ReportsViewModel.formatMoney(report.totalCapital)}',
                        color: AppTheme.info,
                      ),
                      _MetricTile(
                        label: 'Net Position',
                        value:
                            'KES ${ReportsViewModel.formatMoney(report.netPosition)}',
                        color: report.netPosition >= 0
                            ? AppTheme.forestGreen
                            : AppTheme.danger,
                      ),
                    ],
                  ],
                ),
                if (report.byRestaurant.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Sales by Restaurant',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  for (final row in report.byRestaurant)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        row.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('${row.count} orders'),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'KES ${ReportsViewModel.formatMoney(row.sell)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            'Profit KES ${ReportsViewModel.formatMoney(row.profit)}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.forestGreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (report.isProduct && report.productTransactions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Transaction History',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  for (final tx in report.productTransactions)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${tx.invoiceNumber} — ${tx.restaurantName}'),
                      subtitle: Text(
                        '${ReportsViewModel.formatDate(tx.date)} | ${tx.qty} ${tx.unit}',
                      ),
                      trailing: Text(
                        'KES ${ReportsViewModel.formatMoney(tx.total)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
        ),
      ],
    );
  }
}

class _InsightGroupCard extends StatelessWidget {
  const _InsightGroupCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.background,
    required this.messages,
  });

  final String title;
  final IconData icon;
  final Color color;
  final Color background;
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final msg in messages)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  msg,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.slateInk,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PnlLine extends StatelessWidget {
  const _PnlLine({
    required this.label,
    required this.value,
    required this.valueColor,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: bold ? AppTheme.slateInk : AppTheme.slateMuted,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSage,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.slateMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
