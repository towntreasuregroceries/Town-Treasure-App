import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import 'clerk_portal_screen.dart';
import 'clerk_review_sheet.dart';
import 'clerk_view_model.dart';

/// Owner Clerk Submissions Inbox with Pending/Approved/Rejected tabs,
/// invite link/token generator + WhatsApp/copy share, docket code import/export,
/// and review/approve sheet.
class ClerkSubmissionsScreen extends StatefulWidget {
  const ClerkSubmissionsScreen({
    super.key,
    required this.viewModel,
    this.onInvoiceApproved,
    this.onInspectInvoice,
  });

  final ClerkViewModel viewModel;
  final void Function(Invoice invoice)? onInvoiceApproved;
  final void Function(String invoiceId)? onInspectInvoice;

  @override
  State<ClerkSubmissionsScreen> createState() => _ClerkSubmissionsScreenState();
}

class _ClerkSubmissionsScreenState extends State<ClerkSubmissionsScreen> {
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');
  bool _isGeneratingInvite = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_onVmChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.loadSubmissions();
    });
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onVmChanged);
    super.dispose();
  }

  Future<void> _copyClerkInviteLink() async {
    setState(() => _isGeneratingInvite = true);
    try {
      final invite = await widget.viewModel.createClerkInviteLink();
      await Clipboard.setData(ClipboardData(text: invite.url));
      if (!mounted) return;
      _showInviteDialog(invite);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        'Could not create a secure Clerk Link: ${UserFriendlyError.format(e)}',
        color: AppTheme.danger,
      );
    } finally {
      if (mounted) setState(() => _isGeneratingInvite = false);
    }
  }

  Future<void> _shareClerkPortalWhatsApp() async {
    setState(() => _isGeneratingInvite = true);
    try {
      final invite = await widget.viewModel.createClerkInviteLink();
      final text =
          'Hi! Open this secure Town Treasure Groceries Clerk Portal link in your phone browser to submit dockets for ${invite.ownerName}\'s review (no app download needed). This link expires after 30 days; older links are no longer valid:\n\n${invite.url}';

      final launched = await AppLockGuard.runWithoutRelock(() async {
        final directUri = Uri.parse(
          'whatsapp://send?text=${Uri.encodeComponent(text)}',
        );
        if (await launchUrl(directUri, mode: LaunchMode.externalApplication)) {
          return true;
        }
        final webUri = Uri.parse(
          'https://wa.me/?text=${Uri.encodeComponent(text)}',
        );
        return launchUrl(webUri, mode: LaunchMode.externalApplication);
      });

      if (!launched) {
        await AppLockGuard.runWithoutRelock(
          () => Share.share(text, subject: 'Town Treasure Clerk Portal Link'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        'Could not create a secure Clerk Link: ${UserFriendlyError.format(e)}',
        color: AppTheme.danger,
      );
    } finally {
      if (mounted) setState(() => _isGeneratingInvite = false);
    }
  }

  void _showInviteDialog(ClerkInviteLink invite) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.link_outlined, color: AppTheme.forestGreen),
            SizedBox(width: 8),
            Expanded(child: Text('Secure Clerk Invite Created')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The portal link was copied to your clipboard. Previous clerk links were revoked; this link expires in 30 days.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            const Text(
              'MOBILE APP INVITE TOKEN',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateMuted,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              invite.token,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: invite.token));
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                _showSnack('Raw invite token copied to clipboard.');
              }
            },
            child: const Text('Copy Token Only'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _openImportDocketDialog() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Docket Code'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Paste docket code or JSON',
            hintText: 'Base64 code or exported docket JSON...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.isEmpty || !mounted) return;
    try {
      final imported = await widget.viewModel.importDocketFromCode(raw);
      if (!mounted) return;
      _showSnack(
        'Imported docket for ${imported.restaurantName} into staging queue.',
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('Import failed: $e', color: AppTheme.danger);
    }
  }

  Future<void> _openClerkPortal() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClerkPortalScreen(
          viewModel: widget.viewModel,
          allowOwnerQuickPair: true,
        ),
      ),
    );
    if (mounted) {
      widget.viewModel.loadSubmissions();
    }
  }

  Future<void> _confirmDelete(StagingDocket item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Docket'),
        content: Text(
          'Are you sure you want to delete the docket for "${item.restaurantName}"? This cannot be undone.',
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
      await widget.viewModel.deleteSubmission(item.id);
      if (mounted) _showSnack('Docket removed from review queue.');
    } catch (e) {
      if (mounted) _showSnack('Delete failed: $e', color: AppTheme.danger);
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
    final items = vm.filteredSubmissions;

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('Clerk Docket Submissions'),
        actions: [
          IconButton(
            tooltip: 'Import Docket Code',
            onPressed: _openImportDocketDialog,
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: vm.isLoadingInbox ? null : vm.loadSubmissions,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: vm.loadSubmissions,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Clerk Invite & Portal Actions Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Maker-Checker Clerk Portal',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Review, adjust wholesale costs, and approve clerk dockets before encrypting into your private vault.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              _isGeneratingInvite ? null : _copyClerkInviteLink,
                          icon: const Icon(Icons.link_outlined, size: 18),
                          label: const Text('Copy Clerk Link'),
                        ),
                        FilledButton.icon(
                          onPressed: _isGeneratingInvite
                              ? null
                              : _shareClerkPortalWhatsApp,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.leafGreen,
                          ),
                          icon: const Icon(Icons.share_outlined, size: 18),
                          label: const Text('WhatsApp Clerk'),
                        ),
                        FilledButton.icon(
                          onPressed: _openClerkPortal,
                          icon: const Icon(
                            Icons.assignment_ind_outlined,
                            size: 18,
                          ),
                          label: const Text('Open Clerk Portal'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Tabs: Pending / Approved / Rejected
            SegmentedButton<ClerkInboxTab>(
              segments: [
                ButtonSegment(
                  value: ClerkInboxTab.pending,
                  icon: const Icon(Icons.hourglass_top_outlined, size: 17),
                  label: Text('Pending (${vm.pendingCount})'),
                ),
                ButtonSegment(
                  value: ClerkInboxTab.approved,
                  icon: const Icon(Icons.check_circle_outline, size: 17),
                  label: Text('Approved (${vm.approvedCount})'),
                ),
                ButtonSegment(
                  value: ClerkInboxTab.rejected,
                  icon: const Icon(Icons.undo_outlined, size: 17),
                  label: Text('Rejected (${vm.rejectedCount})'),
                ),
              ],
              selected: {vm.activeTab},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  vm.setActiveTab(selection.first);
                }
              },
            ),
            const SizedBox(height: 14),

            if (vm.inboxError != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  vm.inboxError!,
                  style: const TextStyle(color: AppTheme.danger),
                ),
              ),

            if (vm.isLoadingInbox && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.forestGreen,
                  ),
                ),
              )
            else if (items.isEmpty)
              _buildEmptyState(vm.activeTab)
            else
              ...items.map((item) => _buildSubmissionCard(item)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ClerkInboxTab tab) {
    final msg = switch (tab) {
      ClerkInboxTab.pending => 'No pending clerk submissions.',
      ClerkInboxTab.approved => 'No approved submissions in history yet.',
      ClerkInboxTab.rejected => 'No rejected submissions.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        child: Column(
          children: [
            const Icon(
              Icons.inbox_outlined,
              size: 48,
              color: AppTheme.slateMuted,
            ),
            const SizedBox(height: 12),
            Text(
              msg,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateInk,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'When dispatch clerks enter or scan dockets via the Clerk Portal, they appear here awaiting your review and encrypted approval.',
              style: TextStyle(fontSize: 13, color: AppTheme.slateMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _openClerkPortal,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open Clerk Intake Portal'),
                ),
                OutlinedButton.icon(
                  onPressed: _openImportDocketDialog,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('Import Docket Code'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmissionCard(StagingDocket item) {
    final statusBadge = _statusChip(item);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.restaurantName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${item.invoiceDate} | By ${item.clerkName} | ${item.itemsJson.length} item${item.itemsJson.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                statusBadge,
              ],
            ),
            if (item.isRejected && item.rejectionReason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Return reason: ${item.rejectionReason}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'KES ${_moneyFmt.format(item.totalSell)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.forestGreen,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy Docket Code',
                  onPressed: () async {
                    final code = widget.viewModel.exportDocketCode(item);
                    await Clipboard.setData(ClipboardData(text: code));
                    if (mounted) _showSnack('Docket code copied to clipboard.');
                  },
                  icon: const Icon(Icons.qr_code_2_outlined, size: 20),
                ),
                if (!item.isApproved)
                  IconButton(
                    tooltip: 'Delete Docket',
                    onPressed: () => _confirmDelete(item),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppTheme.danger,
                      size: 20,
                    ),
                  ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: () => ClerkReviewSheet.show(
                    context,
                    viewModel: widget.viewModel,
                    docket: item,
                    onApproved: widget.onInvoiceApproved,
                    onInspectInvoice: widget.onInspectInvoice,
                  ),
                  icon: Icon(
                    item.isPending
                        ? Icons.visibility_outlined
                        : Icons.receipt_long_outlined,
                    size: 17,
                  ),
                  label: Text(item.isPending ? 'Review & Approve' : 'Details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(StagingDocket item) {
    if (item.isPending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.warningSurface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 13, color: AppTheme.warning),
            SizedBox(width: 4),
            Text(
              'Pending Review',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.warning,
              ),
            ),
          ],
        ),
      );
    }
    if (item.isApproved) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.successSurface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 13, color: AppTheme.forestGreen),
            SizedBox(width: 4),
            Text(
              'Approved',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.forestGreenDeep,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.dangerSurface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cancel_outlined, size: 13, color: AppTheme.danger),
          SizedBox(width: 4),
          Text(
            'Returned',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppTheme.danger,
            ),
          ),
        ],
      ),
    );
  }
}
