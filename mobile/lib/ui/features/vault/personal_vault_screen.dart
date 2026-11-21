import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/personal_vault_service.dart';
import '../../../domain/models/models.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';
import '../../core/widgets/app_print_helper.dart';
import '../../core/widgets/print_options_sheet.dart';
import '../../core/widgets/scoped_text_controllers.dart';

/// Abstraction over device biometric / PIN confirmation for Personal Documents entry.
abstract class VaultAuthGateway {
  Future<bool> authenticate({required String reason});
}

class LocalVaultAuthGateway implements VaultAuthGateway {
  LocalVaultAuthGateway([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        return true;
      }
      return await AppLockGuard.runWithoutRelock(
        () => _auth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            biometricOnly: false,
            stickyAuth: true,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

typedef DocumentFilePicker = Future<StagedVaultFile?> Function();
typedef VaultImagePagesPicker = Future<List<Uint8List>> Function();

/// Private fingerprint-locked folder for personal and business compliance documents.
/// Documents remain saved indefinitely until deleted at the owner's discretion.
class PersonalVaultScreen extends StatefulWidget {
  const PersonalVaultScreen({
    super.key,
    required this.vault,
    required this.vaultService,
    this.authGateway,
    this.documentPicker,
    this.cameraPagePicker,
    this.galleryPagesPicker,
    this.requireBiometricLock = true,
  });

  final VaultRepository vault;
  final PersonalVaultService vaultService;
  final VaultAuthGateway? authGateway;
  final DocumentFilePicker? documentPicker;
  final VaultImagePagesPicker? cameraPagePicker;
  final VaultImagePagesPicker? galleryPagesPicker;
  final bool requireBiometricLock;

  @override
  State<PersonalVaultScreen> createState() => _PersonalVaultScreenState();
}

class _PersonalVaultScreenState extends State<PersonalVaultScreen> {
  static const MethodChannel _pickerChannel =
      MethodChannel('com.towntreasuregroceries/pdf_picker');

  late final VaultAuthGateway _auth;
  late final TextEditingController _searchCtrl;

  bool _unlocked = false;
  bool _isAuthenticating = false;
  bool _isBusy = false;
  PersonalDocCategory? _selectedCategory;
  String? _authError;

  @override
  void initState() {
    super.initState();
    _auth = widget.authGateway ?? LocalVaultAuthGateway();
    _searchCtrl = TextEditingController();
    widget.vault.addListener(_onVaultChanged);
    if (!widget.requireBiometricLock) {
      _unlocked = true;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptUnlock());
    }
  }

  @override
  void dispose() {
    widget.vault.removeListener(_onVaultChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onVaultChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _promptUnlock() async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _authError = null;
    });
    final ok = await _auth.authenticate(
      reason: 'Confirm fingerprint or phone PIN to open Personal Documents',
    );
    if (!mounted) return;
    setState(() {
      _isAuthenticating = false;
      _unlocked = ok;
      if (!ok) {
        _authError = 'Documents remain locked. Tap Unlock to verify identity.';
      }
    });
  }

  void _showSnack(String msg, {Color color = AppTheme.forestGreen}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  Future<StagedVaultFile?> _pickRawDocument() async {
    if (widget.documentPicker != null) {
      return widget.documentPicker!();
    }
    final res = await AppLockGuard.runWithoutRelock(
      () => _pickerChannel.invokeMethod<dynamic>('pickRawDocument'),
    );
    if (res is! Map) return null;
    final rawBytes = res['bytes'];
    if (rawBytes is! Uint8List || rawBytes.isEmpty) return null;
    return StagedVaultFile(
      bytes: rawBytes,
      mimeType: (res['mimeType'] ?? 'application/pdf').toString(),
      fileName: (res['fileName'] ?? 'document.pdf').toString(),
    );
  }

  Future<List<Uint8List>> _pickCameraPage() async {
    if (widget.cameraPagePicker != null) {
      return widget.cameraPagePicker!();
    }
    final picker = ImagePicker();
    final photo = await AppLockGuard.runWithoutRelock(
      () => picker.pickImage(source: ImageSource.camera, imageQuality: 90),
    );
    if (photo == null) return const [];
    return [await photo.readAsBytes()];
  }

  Future<List<Uint8List>> _pickGalleryPages() async {
    if (widget.galleryPagesPicker != null) {
      return widget.galleryPagesPicker!();
    }
    final picker = ImagePicker();
    final photos = await AppLockGuard.runWithoutRelock(
      () => picker.pickMultiImage(imageQuality: 90),
    );
    if (photos.isEmpty) return const [];
    final pages = <Uint8List>[];
    for (final p in photos) {
      pages.add(await p.readAsBytes());
    }
    return pages;
  }

  Future<void> _syncAllUnsyncedToCloud() async {
    final workerUrl = PersonalVaultService.normalizeWorkerUrl(
      widget.vault.personalDocsWorkerUrl,
    );
    final docs =
        widget.vault.personalDocuments.where((d) => !d.r2Synced).toList();
    if (docs.isEmpty) {
      _showSnack('All documents are already backed up to your private cloud.');
      return;
    }

    setState(() => _isBusy = true);
    var syncedCount = 0;
    try {
      for (final doc in docs) {
        final ok = await widget.vaultService.syncLocalToR2(
          meta: doc,
          workerUrl: workerUrl,
        );
        if (ok) {
          await widget.vault.savePersonalDocumentMeta(
            doc.copyWith(r2Synced: true),
            sync: false,
          );
          syncedCount++;
        }
      }
      if (syncedCount > 0) {
        await widget.vault.syncNow();
      }
      _showSnack(
        syncedCount > 0
            ? 'Backed up $syncedCount document(s) to cloud.'
            : 'Could not reach cloud backup right now. Your documents are still saved safely on this phone.',
        color: syncedCount > 0 ? AppTheme.forestGreen : AppTheme.warning,
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _openAddDocumentSheet() async {
    var category = PersonalDocCategory.kraTax;
    StagedVaultFile? stagedFile;
    final cameraPages = <Uint8List>[];
    var isPacking = false;
    String? formError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ScopedTextControllers(
        initialTexts: const ['', '', ''],
        builder: (ctx, ctrls) {
          final titleCtrl = ctrls[0];
          final numberCtrl = ctrls[1];
          final notesCtrl = ctrls[2];
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              Future<void> attachFile() async {
                try {
                  final picked = await _pickRawDocument();
                  if (picked != null) {
                    setSheetState(() {
                      cameraPages.clear();
                      stagedFile = picked;
                      formError = null;
                      if (titleCtrl.text.trim().isEmpty) {
                        titleCtrl.text = picked.fileName.replaceAll(
                          RegExp(r'\.[A-Za-z0-9]+$'),
                          '',
                        );
                      }
                    });
                  }
                } catch (e) {
                  setSheetState(() => formError = UserFriendlyError.format(e));
                }
              }

              Future<void> addCameraOrGallery(bool fromCamera) async {
                try {
                  final pages = fromCamera
                      ? await _pickCameraPage()
                      : await _pickGalleryPages();
                  if (pages.isEmpty) return;
                  setSheetState(() {
                    isPacking = true;
                    formError = null;
                    cameraPages.addAll(pages);
                  });
                  final pdfBytes = await PersonalVaultService.packImagesToPdf(
                    cameraPages,
                    title: titleCtrl.text.trim().isEmpty
                        ? 'Scanned Document'
                        : titleCtrl.text.trim(),
                  );
                  setSheetState(() {
                    isPacking = false;
                    stagedFile = StagedVaultFile(
                      bytes: pdfBytes,
                      mimeType: 'application/pdf',
                      fileName: 'scan_${cameraPages.length}p.pdf',
                    );
                  });
                } catch (e) {
                  setSheetState(() {
                    isPacking = false;
                    formError = UserFriendlyError.format(e);
                  });
                }
              }

              Future<void> submit() async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) {
                  setSheetState(() => formError = 'Enter a document name.');
                  return;
                }
                if (stagedFile == null || stagedFile!.bytes.isEmpty) {
                  setSheetState(
                    () => formError =
                        'Please upload a file, take a photo, or choose from gallery first.',
                  );
                  return;
                }
                setSheetState(() {
                  isPacking = true;
                  formError = null;
                });
                try {
                  final rawMeta = PersonalDocument(
                    id: 'doc_${AppHelpers.genId()}',
                    title: title,
                    category: category,
                    docNumber: numberCtrl.text.trim(),
                    mimeType: stagedFile!.mimeType,
                    originalFileName: stagedFile!.fileName,
                    notes: notesCtrl.text.trim(),
                  );
                  final savedMeta = await widget.vaultService.encryptStoreAndUpload(
                    meta: rawMeta,
                    plainBytes: stagedFile!.bytes,
                    workerUrl: PersonalVaultService.normalizeWorkerUrl(
                      widget.vault.personalDocsWorkerUrl,
                    ),
                  );
                  await widget.vault.savePersonalDocumentMeta(savedMeta);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  _showSnack(
                    savedMeta.r2Synced
                        ? 'Document locked & backed up to cloud.'
                        : 'Document locked & saved on this phone.',
                  );
                } catch (e) {
                  setSheetState(() {
                    isPacking = false;
                    formError = UserFriendlyError.format(e);
                  });
                }
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
                      const Text(
                        'Add Private Document',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateInk,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Your document is locked automatically before saving and stays here until you choose to delete it.',
                        style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            key: const Key('btn_vault_pick_file'),
                            onPressed: isPacking ? null : attachFile,
                            icon: const Icon(Icons.upload_file_outlined, size: 18),
                            label: const Text('Upload PDF / File'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('btn_vault_scan_camera'),
                            onPressed:
                                isPacking ? null : () => addCameraOrGallery(true),
                            icon: const Icon(Icons.camera_alt_outlined, size: 18),
                            label: Text(
                              cameraPages.isEmpty
                                  ? 'Take Photo'
                                  : 'Add Page (${cameraPages.length})',
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('btn_vault_pick_gallery'),
                            onPressed:
                                isPacking ? null : () => addCameraOrGallery(false),
                            icon: const Icon(Icons.photo_library_outlined, size: 18),
                            label: const Text('Gallery'),
                          ),
                        ],
                      ),
                      if (stagedFile != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.successSurface,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.check_circle_outline,
                                color: AppTheme.forestGreen,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Ready: ${stagedFile!.fileName} (${(stagedFile!.bytes.length / 1024).toStringAsFixed(1)} KB)',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.forestGreenDeep,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('field_vault_title'),
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Document Name *',
                          hintText: 'e.g. KRA PIN Certificate / Business Permit',
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<PersonalDocCategory>(
                        initialValue: category,
                        decoration: const InputDecoration(labelText: 'Folder / Type'),
                        items: PersonalDocCategory.values
                            .map(
                              (c) => DropdownMenuItem(
                                value: c,
                                child: Text(c.label),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setSheetState(() => category = v);
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: numberCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Document / Ref Number (Optional)',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: notesCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Notes (Optional)',
                        ),
                      ),
                      if (formError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          formError!,
                          style: const TextStyle(
                            color: AppTheme.danger,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        key: const Key('btn_vault_save_doc'),
                        onPressed: isPacking ? null : submit,
                        icon: const Icon(Icons.lock_outline),
                        label: Text(
                          isPacking ? 'Saving...' : 'Lock & Save Document',
                        ),
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

  Future<void> _openDocument(PersonalDocument doc) async {
    setState(() => _isBusy = true);
    try {
      final plainBytes = await widget.vaultService.loadAndDecryptDocument(
        doc,
        workerUrl: PersonalVaultService.normalizeWorkerUrl(
          widget.vault.personalDocsWorkerUrl,
        ),
      );
      if (!mounted) return;
      setState(() => _isBusy = false);

      if (doc.isPdf) {
        final safeName = '${doc.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.pdf';
        await AppPrintHelper.openPreview(
          context,
          document: PrintableDocument(
            title: doc.title,
            filename: safeName,
            supportsThermalRoll: false,
            buildPdf: (_) async => plainBytes,
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(
                title: Text(doc.title),
                actions: [
                  IconButton(
                    tooltip: 'Share Copy',
                    icon: const Icon(Icons.share_outlined),
                    onPressed: () async {
                      final dir = await getTemporaryDirectory();
                      final ext = doc.mimeType.contains('png') ? 'png' : 'jpg';
                      final tmp = File('${dir.path}/${doc.id}.$ext');
                      await tmp.writeAsBytes(plainBytes, flush: true);
                      await AppLockGuard.runWithoutRelock(
                        () => Share.shareXFiles([XFile(tmp.path)], text: doc.title),
                      );
                    },
                  ),
                ],
              ),
              backgroundColor: Colors.black,
              body: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Center(child: Image.memory(plainBytes)),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isBusy = false);
        _showSnack(UserFriendlyError.format(e), color: AppTheme.danger);
      }
    }
  }

  Future<void> _deleteDocument(PersonalDocument doc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Document?'),
        content: Text(
          'Permanently delete "${doc.title}" from your phone and cloud backup?',
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
    if (confirm != true) return;
    await widget.vaultService.deleteEncryptedBlob(
      doc.id,
      workerUrl: PersonalVaultService.normalizeWorkerUrl(
        widget.vault.personalDocsWorkerUrl,
      ),
    );
    await widget.vault.deletePersonalDocumentMeta(doc.id);
    _showSnack('Deleted "${doc.title}".');
  }

  @override
  Widget build(BuildContext context) {
    final docs = widget.vault.personalDocuments;
    final query = _searchCtrl.text.trim().toLowerCase();
    final filtered = docs.where((d) {
      if (_selectedCategory != null && d.category != _selectedCategory) {
        return false;
      }
      if (query.isNotEmpty) {
        return d.title.toLowerCase().contains(query) ||
            d.docNumber.toLowerCase().contains(query) ||
            d.notes.toLowerCase().contains(query);
      }
      return true;
    }).toList();

    final backedUpCount = docs.where((d) => d.r2Synced).length;

    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      appBar: AppBar(
        title: const Text('Personal Documents'),
        actions: [
          if (_unlocked)
            IconButton(
              key: const Key('btn_vault_r2_sync'),
              tooltip: 'Back Up Documents to Cloud',
              onPressed: _isBusy ? null : _syncAllUnsyncedToCloud,
              icon: const Icon(Icons.cloud_upload_outlined),
            ),
        ],
      ),
      floatingActionButton: _unlocked
          ? FloatingActionButton.extended(
              key: const Key('fab_add_vault_doc'),
              onPressed: _isBusy ? null : _openAddDocumentSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add Document'),
            )
          : null,
      body: !_unlocked
          ? _buildLockScreen()
          : Column(
              children: [
                if (_isBusy) const LinearProgressIndicator(minHeight: 3),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceCard,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.borderSubtle),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: AppTheme.sageTint,
                              foregroundColor: AppTheme.forestGreenDeep,
                              child: const Icon(Icons.lock_outline),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Private Folder · ${docs.length} Saved',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.slateInk,
                                    ),
                                  ),
                                  Text(
                                    docs.isEmpty
                                        ? 'Only you can view files saved here — they stay until you delete them.'
                                        : '$backedUpCount of ${docs.length} backed up safely to cloud',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.slateMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search documents...',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: const Text('All'),
                                selected: _selectedCategory == null,
                                onSelected: (_) =>
                                    setState(() => _selectedCategory = null),
                              ),
                            ),
                            ...PersonalDocCategory.values.map(
                              (c) => Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(c.label),
                                  selected: _selectedCategory == c,
                                  onSelected: (_) => setState(
                                    () => _selectedCategory =
                                        _selectedCategory == c ? null : c,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              docs.isEmpty
                                  ? 'Tap + Add Document to store KRA certificates, Business Permits, National IDs, Contracts, or Food Handler cards privately.'
                                  : 'No documents match your filter.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppTheme.slateMuted),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, idx) =>
                              _buildDocumentTile(filtered[idx]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildLockScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.sageTint,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.fingerprint,
                size: 40,
                color: AppTheme.forestGreen,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Personal Vault Locked',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateInk,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _authError ??
                  'Use your fingerprint, face unlock, or phone PIN to open your private documents.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _authError != null ? AppTheme.danger : AppTheme.slateMuted,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('btn_unlock_personal_vault'),
              onPressed: _isAuthenticating ? null : _promptUnlock,
              icon: const Icon(Icons.lock_open_outlined),
              label: Text(
                _isAuthenticating ? 'Verifying...' : 'Unlock Documents',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentTile(PersonalDocument doc) {
    return Card(
      child: ListTile(
        key: Key('vault_doc_${doc.id}'),
        onTap: () => _openDocument(doc),
        leading: CircleAvatar(
          backgroundColor: AppTheme.sageTint,
          foregroundColor: AppTheme.forestGreenDeep,
          child: Icon(
            doc.isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
          ),
        ),
        title: Text(
          doc.title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppTheme.slateInk,
          ),
        ),
        subtitle: Text(
          [
            doc.category.label,
            if (doc.docNumber.isNotEmpty) doc.docNumber,
            doc.r2Synced ? 'Cloud Backed Up' : 'On Phone',
          ].join(' · '),
          style: const TextStyle(fontSize: 12, color: AppTheme.slateMuted),
        ),
        trailing: IconButton(
          key: Key('btn_delete_doc_${doc.id}'),
          tooltip: 'Delete',
          onPressed: () => _deleteDocument(doc),
          icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
        ),
      ),
    );
  }
}
