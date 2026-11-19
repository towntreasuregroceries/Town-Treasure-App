import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/repositories/staging_repository.dart';
import '../../../data/services/duplicate_detector_service.dart';
import '../../../data/services/ocr_consensus_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../scanner/docket_scanner_sheet.dart';
import 'clerk_view_model.dart';

class _ClerkLineRow {
  _ClerkLineRow({
    required this.descController,
    required this.qtyController,
    required this.priceController,
    required this.unit,
  });

  final TextEditingController descController;
  final TextEditingController qtyController;
  final TextEditingController priceController;
  String unit;

  void dispose() {
    descController.dispose();
    qtyController.dispose();
    priceController.dispose();
  }
}

/// Native Clerk Intake Portal screen inside the APK.
/// Uses an owner-issued invite token (`clerk-api`) so dispatch clerks can
/// capture docket photos, run OCR, check duplicates, submit dockets, view
/// history, and edit/resubmit returned dockets.
class ClerkPortalScreen extends StatefulWidget {
  const ClerkPortalScreen({
    super.key,
    required this.viewModel,
    this.initialInviteToken,
    this.allowOwnerQuickPair = false,
  });

  final ClerkViewModel viewModel;
  final String? initialInviteToken;
  final bool allowOwnerQuickPair;

  @override
  State<ClerkPortalScreen> createState() => _ClerkPortalScreenState();
}

class _ClerkPortalScreenState extends State<ClerkPortalScreen> {
  static const List<String> _defaultRestaurants = [
    'The Golden Crest Hotel',
    'Sankara Suites',
    'Villa Rosa Kempinski',
    'Sarova Stanley',
    'Hemingways Nairobi',
    'Radisson Blu',
    'Nairobi Serena Hotel',
    'Fairmont The Norfolk',
    'Tamarind Tree Hotel',
    'Movenpick Hotel',
    'Crowne Plaza',
    'Ole Sereni Hotel',
    'Safari Park Hotel',
    'Windsor Golf Hotel',
    'Eka Hotel',
    'Boma Nairobi',
  ];

  static const List<({String name, String unit})> _quickChips = [
    (name: 'Red Onions', unit: 'kgs'),
    (name: 'Tomatoes', unit: 'crates'),
    (name: 'Potatoes (Warus)', unit: 'bags'),
    (name: 'Sukuma Wiki', unit: 'bundles'),
    (name: 'Cabbages', unit: 'pieces'),
    (name: 'Dhania', unit: 'bundles'),
    (name: 'Spinach', unit: 'bundles'),
    (name: 'Carrots', unit: 'kgs'),
    (name: 'Capsicum (Hoho)', unit: 'kgs'),
    (name: 'Garlic', unit: 'kgs'),
  ];

  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _clerkNameController = TextEditingController();
  final TextEditingController _customRestController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _deliveryController = TextEditingController();
  final TextEditingController _otherController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  final List<_ClerkLineRow> _rows = [];
  final List<OcrImagePage> _photoPages = [];

  String _selectedRestaurant = '';
  String? _editingDocketId;
  String? _editingRejectionReason;
  bool _isRunningOcr = false;
  String _ocrStatus = '';
  bool _isSubmitting = false;
  bool _isPairing = false;
  StagingDocket? _lastSubmittedRecord;
  Timer? _liveDupDebounce;

  List<String> get _restaurantOptions {
    final seen = <String>{};
    final out = <String>[];
    for (final r in widget.viewModel.vaultRestaurants) {
      if (r.name.isNotEmpty && seen.add(r.name)) out.add(r.name);
    }
    for (final name in _defaultRestaurants) {
      if (seen.add(name)) out.add(name);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _dateController.text = AppHelpers.normalizeAppDate(DateTime.now());
    _addLineRow();
    widget.viewModel.addListener(_onVmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.viewModel.loadClerkSession(
        initialInviteToken: widget.initialInviteToken,
      );
      if (mounted &&
          widget.viewModel.savedClerkName.isNotEmpty &&
          _clerkNameController.text.isEmpty) {
        _clerkNameController.text = widget.viewModel.savedClerkName;
      }
    });
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _liveDupDebounce?.cancel();
    widget.viewModel.removeListener(_onVmChanged);
    _tokenController.dispose();
    _clerkNameController.dispose();
    _customRestController.dispose();
    _dateController.dispose();
    _deliveryController.dispose();
    _otherController.dispose();
    _notesController.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addLineRow({
    String desc = '',
    double qty = 1,
    String unit = 'kgs',
    double price = 0,
  }) {
    final normUnit = OcrConsensusService.normalizeDropdownUnit(unit);
    final row = _ClerkLineRow(
      descController: TextEditingController(text: desc),
      qtyController: TextEditingController(text: _fmtNum(qty)),
      priceController: TextEditingController(
        text: price > 0 ? _fmtNum(price) : '',
      ),
      unit: normUnit,
    );
    setState(() => _rows.add(row));
    _scheduleLiveDuplicateCheck();
  }

  void _removeLineRow(int index) {
    if (_rows.length <= 1) return;
    final removed = _rows.removeAt(index);
    removed.dispose();
    setState(() {});
    _scheduleLiveDuplicateCheck();
  }

  List<InvoiceLineItem> _collectItems() {
    return _rows.map((r) {
      final qty = double.tryParse(r.qtyController.text.trim()) ?? 0;
      final price = double.tryParse(r.priceController.text.trim()) ?? 0;
      return InvoiceLineItem(
        desc: r.descController.text.trim(),
        qty: qty,
        unit: r.unit,
        buyPrice: 0,
        sellPrice: price,
        total: qty * price,
      );
    }).toList();
  }

  String get _effectiveRestaurant {
    if (_selectedRestaurant == '__other__') {
      return _customRestController.text.trim();
    }
    return _selectedRestaurant.trim();
  }

  void _scheduleLiveDuplicateCheck() {
    _liveDupDebounce?.cancel();
    _liveDupDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      widget.viewModel.runLiveClerkDuplicateCheck(
        restaurantName: _effectiveRestaurant,
        invoiceDate: _dateController.text,
        items: _collectItems()
            .where((it) => it.desc.isNotEmpty)
            .toList(),
      );
    });
  }

  Future<void> _pairWithToken() async {
    final raw = _tokenController.text.trim();
    if (raw.isEmpty) {
      _showSnack('Paste an invite link or token first.', color: AppTheme.danger);
      return;
    }
    setState(() => _isPairing = true);
    try {
      await widget.viewModel.pairWithInviteToken(raw);
      if (mounted) {
        _tokenController.clear();
        _showSnack('Paired with ${widget.viewModel.inviteOwnerName}.');
      }
    } catch (e) {
      if (mounted) _showSnack('Pairing failed: $e', color: AppTheme.danger);
    } finally {
      if (mounted) setState(() => _isPairing = false);
    }
  }

  Future<void> _quickPairOwner() async {
    setState(() => _isPairing = true);
    try {
      await widget.viewModel.pairWithOwnOwnerInvite();
      if (mounted) {
        _showSnack('Created and paired fresh Clerk Intake invite.');
      }
    } catch (e) {
      if (mounted) _showSnack('Could not create invite: $e', color: AppTheme.danger);
    } finally {
      if (mounted) setState(() => _isPairing = false);
    }
  }

  Future<void> _pickCamera() async {
    try {
      final page = await widget.viewModel.ocrService.pickCameraPage();
      if (page != null && mounted) {
        setState(() => _photoPages.add(page));
      }
    } catch (e) {
      if (mounted) _showSnack('Camera error: $e', color: AppTheme.danger);
    }
  }

  Future<void> _pickGallery() async {
    try {
      final pages = await widget.viewModel.ocrService.pickGalleryPages();
      if (pages.isNotEmpty && mounted) {
        setState(() => _photoPages.addAll(pages));
      }
    } catch (e) {
      if (mounted) _showSnack('Gallery error: $e', color: AppTheme.danger);
    }
  }

  Future<void> _pickPdf() async {
    try {
      final pages = await AppLockGuard.runWithoutRelock(
        () => widget.viewModel.ocrService.pickPdfPages(),
      );
      if (pages.isNotEmpty && mounted) {
        setState(() => _photoPages.addAll(pages));
      }
    } catch (e) {
      if (mounted) _showSnack('PDF load error: $e', color: AppTheme.danger);
    }
  }

  Future<void> _runOcr() async {
    if (_photoPages.isEmpty) {
      _showSnack('Attach at least one docket photo first.',
          color: AppTheme.warning);
      return;
    }
    setState(() {
      _isRunningOcr = true;
      _ocrStatus =
          'Initializing analysis for ${_photoPages.length} page(s)...';
    });
    try {
      final res = await widget.viewModel.ocrService.processDocket(
        _photoPages,
        onProgress: (msg) {
          if (mounted) setState(() => _ocrStatus = msg);
        },
      );
      if (!mounted) return;

      if (res.restaurantName.isNotEmpty) {
        final match = _restaurantOptions.where(
          (name) =>
              name.toLowerCase().contains(res.restaurantName.toLowerCase()),
        );
        if (match.isNotEmpty) {
          _selectedRestaurant = match.first;
        } else {
          _selectedRestaurant = '__other__';
          _customRestController.text = res.restaurantName;
        }
      }
      if (res.date.isNotEmpty) {
        _dateController.text = res.date;
      }
      for (final r in _rows) {
        r.dispose();
      }
      _rows.clear();
      if (res.items.isEmpty) {
        _addLineRow();
      } else {
        for (final it in res.items) {
          _rows.add(
            _ClerkLineRow(
              descController: TextEditingController(text: it.desc),
              qtyController: TextEditingController(text: _fmtNum(it.qty)),
              priceController: TextEditingController(
                text: it.sellPrice > 0 ? _fmtNum(it.sellPrice) : '',
              ),
              unit: OcrConsensusService.normalizeDropdownUnit(it.unit),
            ),
          );
        }
      }
      setState(() {});
      _scheduleLiveDuplicateCheck();
      _showSnack(
        'Extracted ${res.items.length} items using ${res.enginesUsed.join(' + ')}.',
      );
    } catch (e) {
      if (mounted) {
        _showSnack('OCR extraction failed: $e', color: AppTheme.danger);
      }
    } finally {
      if (mounted) setState(() => _isRunningOcr = false);
    }
  }

  Future<void> _exportCsv() async {
    final items = _collectItems().where((i) => i.desc.isNotEmpty).toList();
    if (items.isEmpty) return;
    final csv = OcrConsensusService.itemsToCsv(items);
    await Clipboard.setData(ClipboardData(text: csv));
    if (mounted) _showSnack('Extracted items CSV copied to clipboard.');
  }

  Future<void> _submitDocket({bool bypassDuplicateCheck = false}) async {
    setState(() => _isSubmitting = true);
    try {
      final del = double.tryParse(_deliveryController.text.trim()) ?? 0;
      final oth = double.tryParse(_otherController.text.trim()) ?? 0;
      final result = await widget.viewModel.submitClerkDocket(
        editingDocketId: _editingDocketId,
        clerkName: _clerkNameController.text,
        restaurantName: _effectiveRestaurant,
        invoiceDate: _dateController.text,
        items: _collectItems(),
        deliveryCost: del,
        otherCost: oth,
        notes: _notesController.text,
        receiptPhotos: _photoPages.map((p) => p.dataUrl).toList(),
        bypassDuplicateCheck: bypassDuplicateCheck,
      );
      if (!mounted) return;

      if (result.isDuplicate && result.duplicateAudit != null) {
        await _showDuplicateGateDialog(
          result.candidateDocket!,
          result.duplicateAudit!,
        );
        return;
      }

      if (!result.isSuccess) {
        _showSnack(
          result.error ?? 'Submission failed.',
          color: AppTheme.danger,
        );
        return;
      }

      final isResubmit = _editingDocketId != null;
      _resetForm(clearEditingOnly: false);
      setState(() => _lastSubmittedRecord = result.savedDocket);
      _showSnack(
        isResubmit
            ? 'Corrected docket resubmitted to ${widget.viewModel.inviteOwnerName}.'
            : 'Docket submitted to ${widget.viewModel.inviteOwnerName}\'s review queue.',
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _showDuplicateGateDialog(
    StagingDocket candidate,
    AuditResult audit,
  ) async {
    final matched = audit.matchedRecord;
    final submitter = (matched?.clerkName.isNotEmpty ?? false)
        ? matched!.clerkName
        : 'Clerk';
    final refNum = (matched?.number.isNotEmpty ?? false)
        ? matched!.number
        : ((matched?.id.isNotEmpty ?? false)
            ? matched!.id.substring(0, matched.id.length.clamp(0, 10))
            : 'Docket');
    final matchCount = audit.heuristicScore?.itemCmp.matchingCount ?? 0;

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Town Treasure Smart Audit',
                style: TextStyle(color: AppTheme.danger, fontSize: 17),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CRITICAL DUPLICATE DELIVERY HAZARD',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.danger,
                ),
              ),
              const SizedBox(height: 8),
              Text(audit.explanation, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Client: ${candidate.restaurantName}',
                        style: const TextStyle(fontSize: 12)),
                    Text('Date: ${candidate.invoiceDate}',
                        style: const TextStyle(fontSize: 12)),
                    Text(
                      'Total: KES ${_moneyFmt.format(candidate.totalSell)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text('Recorded By: $submitter ($refNum)',
                        style: const TextStyle(fontSize: 12)),
                    if (matchCount > 0)
                      Text(
                        '$matchCount of ${candidate.itemsJson.length} produce items match previous entry.',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.danger,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'If this physical docket was already entered, discard it to prevent double-billing. If this is a genuine 2nd delivery, flag it as a supplementary dispatch.',
                style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            icon: const Icon(Icons.check, size: 17),
            label: const Text('Discard Duplicate'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(ctx).pop('supplementary'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.danger,
              side: const BorderSide(color: AppTheme.danger),
            ),
            icon: const Icon(Icons.add_circle_outline, size: 17),
            label: const Text('2nd Dispatch (Supplementary)'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (action == 'discard') {
      _resetForm(clearEditingOnly: false);
      _showSnack('Duplicate docket discarded. Form reset.');
    } else if (action == 'supplementary') {
      const tag = '[Supplementary Dispatch #2]';
      if (!_notesController.text.contains(tag)) {
        _notesController.text = '$tag ${_notesController.text}'.trim();
      }
      await widget.viewModel.resetClerkSubmissionKey();
      await _submitDocket(bypassDuplicateCheck: true);
    }
  }

  Future<void> _editReturnedDocket(StagingDocket summary) async {
    try {
      final full =
          await widget.viewModel.fetchClerkDocketWithPhotos(summary.id) ??
              summary;
      if (!mounted) return;

      _editingDocketId = full.id;
      _editingRejectionReason = full.rejectionReason;
      if (_restaurantOptions.any(
        (r) => r.toLowerCase() == full.restaurantName.toLowerCase(),
      )) {
        _selectedRestaurant = _restaurantOptions.firstWhere(
          (r) => r.toLowerCase() == full.restaurantName.toLowerCase(),
        );
        _customRestController.clear();
      } else {
        _selectedRestaurant = '__other__';
        _customRestController.text = full.restaurantName;
      }
      _dateController.text = AppHelpers.normalizeAppDate(full.invoiceDate);
      _deliveryController.text =
          full.deliveryCost > 0 ? _fmtNum(full.deliveryCost) : '';
      _otherController.text = full.otherCost > 0 ? _fmtNum(full.otherCost) : '';
      _notesController.text = full.notes;

      for (final r in _rows) {
        r.dispose();
      }
      _rows.clear();
      if (full.itemsJson.isEmpty) {
        _addLineRow();
      } else {
        for (final it in full.itemsJson) {
          _rows.add(
            _ClerkLineRow(
              descController: TextEditingController(text: it.desc),
              qtyController: TextEditingController(text: _fmtNum(it.qty)),
              priceController: TextEditingController(
                text: it.sellPrice > 0 ? _fmtNum(it.sellPrice) : '',
              ),
              unit: OcrConsensusService.normalizeDropdownUnit(it.unit),
            ),
          );
        }
      }

      _photoPages
        ..clear()
        ..addAll(full.receiptPhotos.map((u) => OcrImagePage(dataUrl: u)));

      setState(() {});
      _showSnack(
        'Loaded ${full.restaurantName} for correction. Make changes and tap Resubmit.',
      );
    } catch (e) {
      if (mounted) _showSnack('Error loading docket: $e', color: AppTheme.danger);
    }
  }

  Future<void> _deleteClerkDocket(StagingDocket item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Submission'),
        content: Text(
          'Delete submission for "${item.restaurantName}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.viewModel.deleteClerkDocket(item.id);
      if (mounted) _showSnack('Submission deleted.');
    } catch (e) {
      if (mounted) _showSnack('Delete failed: $e', color: AppTheme.danger);
    }
  }

  Future<void> _notifyOwnerWhatsApp(StagingDocket record) async {
    final ownerName = widget.viewModel.inviteOwnerName;
    final totalFmt = _moneyFmt.format(record.totalSell);
    final text =
        'Hi $ownerName, I have submitted a new docket for *${record.restaurantName}* (KES $totalFmt) via the Clerk Portal.\n\nPlease review and approve it in Town Treasure Groceries.';
    final uri = Uri.parse(
      'https://api.whatsapp.com/send?text=${Uri.encodeComponent(text)}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _showSnack('WhatsApp message copied to clipboard.');
    }
  }

  void _resetForm({bool clearEditingOnly = false}) {
    _editingDocketId = null;
    _editingRejectionReason = null;
    if (!clearEditingOnly) {
      _photoPages.clear();
      _deliveryController.clear();
      _otherController.clear();
      _notesController.clear();
      for (final r in _rows) {
        r.dispose();
      }
      _rows.clear();
      _addLineRow();
    }
    setState(() {});
  }

  Future<void> _pickDate() async {
    final initial =
        AppHelpers.parseAppDate(_dateController.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) {
      setState(() => _dateController.text = AppHelpers.normalizeAppDate(picked));
      _scheduleLiveDuplicateCheck();
    }
  }

  void _showSnack(String msg, {Color color = AppTheme.forestGreen}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final items = _collectItems();
    final subtotal = items.fold<double>(0, (s, i) => s + i.total);
    final del = double.tryParse(_deliveryController.text.trim()) ?? 0;
    final oth = double.tryParse(_otherController.text.trim()) ?? 0;
    final grandTotal = subtotal + del + oth;

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('Clerk Intake Portal'),
        actions: [
          if (vm.hasClerkInvite)
            IconButton(
              tooltip: 'Refresh History',
              onPressed: vm.isLoadingClerkHistory ? null : vm.loadClerkHistory,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. Invite Token Pairing / Verified Route Banner
          if (!vm.hasClerkInvite)
            _buildPairingCard(vm)
          else
            _buildRoutingBanner(vm),

          // 2. Submission Success Banner with 1-Tap WhatsApp Notify
          if (_lastSubmittedRecord != null) ...[
            const SizedBox(height: 12),
            _buildSuccessBanner(_lastSubmittedRecord!, vm.inviteOwnerName),
          ],

          // 3. Returned Dockets Alert
          if (vm.clerkReturnedDockets.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.dangerSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.danger),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppTheme.danger),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${vm.clerkReturnedDockets.length} Docket(s) Returned for Correction! Scroll to My Recent Submissions and tap Edit & Resubmit.',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // 4. Editing Returned Docket Banner
          if (_editingDocketId != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.warningSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.warning),
              ),
              child: Row(
                children: [
                  const Icon(Icons.edit_note, color: AppTheme.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Editing Returned Docket',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.warning,
                          ),
                        ),
                        Text(
                          'Reviewer feedback: "${_editingRejectionReason?.isNotEmpty == true ? _editingRejectionReason : 'Correction requested'}"',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _resetForm(clearEditingOnly: false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // 5. Docket Form Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.assignment_outlined,
                        color: AppTheme.forestGreen,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Delivery Docket Intake',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _clerkNameController,
                    decoration: const InputDecoration(
                      labelText: 'Clerk / Secretary Name',
                      hintText: 'e.g. Daniel Ochieng',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRestaurant.isEmpty
                        ? null
                        : (_restaurantOptions.contains(_selectedRestaurant) ||
                                _selectedRestaurant == '__other__'
                            ? _selectedRestaurant
                            : '__other__'),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Restaurant / Client',
                      prefixIcon: Icon(Icons.storefront_outlined),
                    ),
                    items: [
                      ..._restaurantOptions.map(
                        (name) => DropdownMenuItem(
                          value: name,
                          child: Text(name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: '__other__',
                        child: Text('+ Other / Enter Custom Name'),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() => _selectedRestaurant = val ?? '');
                      _scheduleLiveDuplicateCheck();
                    },
                  ),
                  if (_selectedRestaurant == '__other__') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _customRestController,
                      onChanged: (_) => _scheduleLiveDuplicateCheck(),
                      decoration: const InputDecoration(
                        labelText: 'Custom Restaurant Name',
                        prefixIcon: Icon(Icons.edit_outlined),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _dateController,
                    readOnly: true,
                    onTap: _pickDate,
                    decoration: const InputDecoration(
                      labelText: 'Delivery / Docket Date',
                      prefixIcon: Icon(Icons.calendar_today_outlined),
                    ),
                  ),

                  // Live Duplicate Warning
                  AnimatedSwitcher(
                    duration: AppMotion.standard,
                    child: vm.liveDuplicateWarning != null
                        ? Container(
                            key: const ValueKey('live_dup_warn'),
                            margin: const EdgeInsets.only(top: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.dangerSurface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.danger),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: AppTheme.danger,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    vm.liveDuplicateWarning!.explanation,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.danger,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  const SizedBox(height: 16),

                  // Physical Docket Photos + OCR
                  const Text(
                    'Physical Docket Photos (Single or Multi-Page)',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.sageTint.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppTheme.leafGreen.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: _pickCamera,
                              icon: const Icon(Icons.camera_alt_outlined,
                                  size: 18),
                              label: const Text('Take Photo'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _pickGallery,
                              icon: const Icon(Icons.photo_library_outlined,
                                  size: 18),
                              label: const Text('Gallery (Multi)'),
                            ),
                            OutlinedButton.icon(
                              key: const Key('btn_clerk_pick_pdf'),
                              onPressed: _pickPdf,
                              icon: const Icon(Icons.picture_as_pdf_outlined,
                                  size: 18),
                              label: const Text('Upload PDF'),
                            ),
                          ],
                        ),
                        if (_photoPages.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 112,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _photoPages.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (ctx, i) {
                                return Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: SizedBox(
                                        width: 90,
                                        height: 112,
                                        child: DocketReceiptImage(
                                          dataUrl: _photoPages[i].dataUrl,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top: 4,
                                      right: 4,
                                      child: InkWell(
                                        onTap: () => setState(
                                          () => _photoPages.removeAt(i),
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.all(3),
                                          decoration: const BoxDecoration(
                                            color: AppTheme.danger,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.close,
                                            size: 12,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _isRunningOcr ? null : _runOcr,
                                  icon: const Icon(Icons.bolt_outlined,
                                      size: 18),
                                  label: Text(
                                    'Auto-Extract from ${_photoPages.length} Page${_photoPages.length > 1 ? 's' : ''}',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              IconButton(
                                tooltip: 'Clear photos',
                                onPressed: _isRunningOcr
                                    ? null
                                    : () => setState(() => _photoPages.clear()),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AppTheme.danger,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (_isRunningOcr) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.forestGreen,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _ocrStatus,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Quick-Add Produce Chips
                  const Text(
                    'Quick-Add Produce',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _quickChips
                        .map(
                          (c) => ActionChip(
                            avatar: const Icon(
                              Icons.add,
                              size: 15,
                              color: AppTheme.forestGreen,
                            ),
                            label: Text(c.name),
                            onPressed: () =>
                                _addLineRow(desc: c.name, unit: c.unit),
                          ),
                        )
                        .toList(),
                  ),

                  const SizedBox(height: 14),

                  // Line Items
                  ...List.generate(_rows.length, (i) {
                    final row = _rows[i];
                    final qty =
                        double.tryParse(row.qtyController.text.trim()) ?? 0;
                    final price =
                        double.tryParse(row.priceController.text.trim()) ?? 0;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceSage,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.borderSubtle),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: row.descController,
                                  onChanged: (_) =>
                                      _scheduleLiveDuplicateCheck(),
                                  decoration: const InputDecoration(
                                    labelText: 'Produce Item',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              if (_rows.length > 1)
                                IconButton(
                                  onPressed: () => _removeLineRow(i),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: AppTheme.danger,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: row.qtyController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  onChanged: (_) {
                                    setState(() {});
                                    _scheduleLiveDuplicateCheck();
                                  },
                                  decoration: const InputDecoration(
                                    labelText: 'Qty',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: row.unit,
                                  isDense: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Unit',
                                    isDense: true,
                                  ),
                                  items: OcrConsensusService.docketDropdownUnits
                                      .map(
                                        (u) => DropdownMenuItem(
                                          value: u,
                                          child: Text(u),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => row.unit = v);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: row.priceController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  onChanged: (_) {
                                    setState(() {});
                                    _scheduleLiveDuplicateCheck();
                                  },
                                  decoration: const InputDecoration(
                                    labelText: 'Price',
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'Line Total: KES ${_moneyFmt.format(qty * price)}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.forestGreenDeep,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),

                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _addLineRow(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add Row'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _exportCsv,
                        icon: const Icon(Icons.table_view_outlined, size: 18),
                        label: const Text('Copy CSV'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _deliveryController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Delivery Cost (KES)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _otherController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Other Costs (KES)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Docket Notes / Comments',
                      hintText: 'e.g. Received at kitchen 6:30 AM',
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Grand Total Card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceSage,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderSubtle),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Subtotal: KES ${_moneyFmt.format(subtotal)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                            Text(
                              'Delivery & Other: KES ${_moneyFmt.format(del + oth)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'GRAND TOTAL',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.slateMuted,
                              ),
                            ),
                            Text(
                              'KES ${_moneyFmt.format(grandTotal)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.forestGreen,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (!vm.hasClerkInvite || _isSubmitting)
                          ? null
                          : () => _submitDocket(),
                      icon: const Icon(Icons.send_outlined),
                      label: Text(
                        _isSubmitting
                            ? 'Verifying & Submitting...'
                            : (_editingDocketId != null
                                ? 'Resubmit Corrected Docket for Approval'
                                : 'Submit Docket for ${vm.inviteOwnerName}\'s Approval'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 6. Clerk Recent Submissions History
          _buildHistorySection(vm),
        ],
      ),
    );
  }

  Widget _buildPairingCard(ClerkViewModel vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.vpn_key_outlined, color: AppTheme.forestGreen),
                SizedBox(width: 8),
                Text(
                  'Pair with Owner Invite Token',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppTheme.slateInk,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Paste the secure Clerk Link or invite token shared by the account owner to submit dockets directly to their review inbox.',
              style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Invite Link or Token',
                hintText: 'https://...#invite=... or token',
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _isPairing ? null : _pairWithToken,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(_isPairing ? 'Verifying...' : 'Pair Invite Token'),
                ),
                if (widget.allowOwnerQuickPair)
                  OutlinedButton.icon(
                    onPressed: _isPairing ? null : _quickPairOwner,
                    icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                    label: const Text('Generate & Pair My Invite'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoutingBanner(ClerkViewModel vm) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.successSurface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.leafGreen),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: AppTheme.forestGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Submitting directly to: ${vm.inviteOwnerName}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
                Text(
                  vm.inviteOwnerEmail.isNotEmpty
                      ? '${vm.inviteOwnerEmail} | Verified Route'
                      : 'Maker-Checker Protection Active',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.forestGreen,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Switch invite token',
            onPressed: vm.unpairClerkToken,
            icon: const Icon(Icons.link_off_outlined, color: AppTheme.slateInk),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessBanner(StagingDocket record, String ownerName) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.successSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.forestGreen, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: AppTheme.forestGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Docket Submitted to $ownerName!',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.forestGreenDeep,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _lastSubmittedRecord = null),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          Text(
            '${record.restaurantName} | KES ${_moneyFmt.format(record.totalSell)}',
            style: const TextStyle(fontSize: 13, color: AppTheme.forestGreen),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => _notifyOwnerWhatsApp(record),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.leafGreen),
            icon: const Icon(Icons.share_outlined, size: 18),
            label: Text('Notify $ownerName via WhatsApp'),
          ),
        ],
      ),
    );
  }

  Widget _buildHistorySection(ClerkViewModel vm) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, color: AppTheme.forestGreen),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'My Recent Submissions',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.slateInk,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: vm.hasClerkInvite ? vm.loadClerkHistory : null,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            if (vm.clerkHistoryError != null) ...[
              const SizedBox(height: 8),
              Text(
                vm.clerkHistoryError!,
                style: const TextStyle(fontSize: 12, color: AppTheme.danger),
              ),
            ],
            if (!vm.hasClerkInvite)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'Pair an invite token above to view your submission history.',
                    style: TextStyle(fontSize: 13, color: AppTheme.slateMuted),
                  ),
                ),
              )
            else if (vm.isLoadingClerkHistory && vm.clerkHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.forestGreen,
                  ),
                ),
              )
            else if (vm.clerkHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'No submissions recorded yet.',
                    style: TextStyle(fontSize: 13, color: AppTheme.slateMuted),
                  ),
                ),
              )
            else
              ...vm.clerkHistory.take(15).map((item) {
                return Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceSage,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.restaurantName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppTheme.slateInk,
                              ),
                            ),
                          ),
                          _historyStatusBadge(item),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${item.invoiceDate} | ${item.itemsJson.length} items | KES ${_moneyFmt.format(item.totalSell)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      if (item.isRejected && item.rejectionReason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Reason: "${item.rejectionReason}"',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.danger,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (!item.isApproved) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'Copy Docket Code',
                              onPressed: () async {
                                final code =
                                    StagingRepository.exportDocketAsCode(item);
                                await Clipboard.setData(
                                  ClipboardData(text: code),
                                );
                                if (mounted) {
                                  _showSnack('Docket code copied.');
                                }
                              },
                              icon: const Icon(Icons.qr_code_2_outlined,
                                  size: 18),
                            ),
                            if (item.isRejected)
                              FilledButton.icon(
                                onPressed: () => _editReturnedDocket(item),
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                label: const Text('Edit & Resubmit'),
                              ),
                            const SizedBox(width: 6),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => _deleteClerkDocket(item),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.danger,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _historyStatusBadge(StagingDocket item) {
    if (item.isPending) {
      return const Text(
        'Waiting for Review',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.warning,
        ),
      );
    }
    if (item.isApproved) {
      return const Text(
        'Approved & Synced',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.forestGreen,
        ),
      );
    }
    return const Text(
      'Returned for Correction',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppTheme.danger,
      ),
    );
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
