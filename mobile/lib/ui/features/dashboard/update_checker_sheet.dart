import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/services/remote_update_service.dart';
import '../../core/app_lock_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/user_friendly_error.dart';

/// Modal bottom sheet using `RemoteUpdateService` to check for APK releases,
/// display release notes, verify SHA-256 checksums, and trigger installation.
class UpdateCheckerSheet extends StatefulWidget {
  const UpdateCheckerSheet({
    super.key,
    required this.updateService,
    required this.manifestUrl,
  });

  final RemoteUpdateService updateService;
  final String manifestUrl;

  /// Opens the OTA updater bottom sheet with a standard modal presentation.
  static Future<void> show(
    BuildContext context, {
    required RemoteUpdateService updateService,
    required String manifestUrl,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => UpdateCheckerSheet(
        updateService: updateService,
        manifestUrl: manifestUrl,
      ),
    );
  }

  @override
  State<UpdateCheckerSheet> createState() => _UpdateCheckerSheetState();
}

/// Shared in-app banner notifying Owner or Clerk users of a newer APK release.
class UpdateAvailableBanner extends StatelessWidget {
  const UpdateAvailableBanner({
    super.key,
    required this.version,
    required this.releaseNotes,
    required this.onOpenUpdater,
  });

  final String version;
  final String releaseNotes;
  final VoidCallback onOpenUpdater;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('banner_update_available'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.infoSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.info.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.info.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.system_update_outlined,
              color: AppTheme.info,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Update Available (v$version)',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateInk,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  releaseNotes.isNotEmpty
                      ? releaseNotes
                      : 'A newer signed release is ready to install.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const Key('btn_open_update_banner'),
            onPressed: onOpenUpdater,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.info,
              foregroundColor: Colors.white,
            ),
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }
}

class _UpdateCheckerSheetState extends State<UpdateCheckerSheet> {
  late final TextEditingController _urlCtrl;

  bool _isChecking = false;
  bool _isDownloading = false;
  double? _downloadProgress;
  String? _errorMessage;
  String? _statusMessage;
  UpdateCheckResult? _checkResult;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.manifestUrl);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _urlCtrl.text.trim().isNotEmpty) {
        _checkForUpdates();
      }
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkForUpdates() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _errorMessage = 'Enter a release manifest URL.');
      return;
    }

    setState(() {
      _isChecking = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final result = await widget.updateService.checkForUpdate(url);
      if (!mounted) return;
      setState(() {
        _checkResult = result;
        _isChecking = false;
        _statusMessage = result.updateAvailable
            ? 'Update v${result.manifest!.version} (build ${result.manifest!.buildNumber}) is available.'
            : 'You are on the latest version (v${result.currentVersion}, build ${result.currentBuildNumber}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isChecking = false;
        _errorMessage = UserFriendlyError.format(
          e,
          fallback: 'Could not check for updates right now. Please try again later.',
        );
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final manifest = _checkResult?.manifest;
    if (manifest == null) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _errorMessage = null;
      _statusMessage = 'Downloading and verifying SHA-256...';
    });

    try {
      final opened = await AppLockGuard.runWithoutRelock(
        () => widget.updateService.downloadVerifyAndInstall(
          manifest,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _downloadProgress = total > 0 ? received / total : null;
            });
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 1;
        _statusMessage = opened
            ? 'Installer opened after safety verification.'
            : 'Update verified, but the Android installer could not be launched.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = null;
        _errorMessage = UserFriendlyError.format(
          e,
          fallback: 'Could not download or install the update. Please try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _checkResult?.manifest;
    final updateAvailable = _checkResult?.updateAvailable ?? false;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: 20 +
              math.max(
                MediaQuery.viewInsetsOf(context).bottom,
                math.max(
                  MediaQuery.viewPaddingOf(context).bottom,
                  MediaQuery.paddingOf(context).bottom,
                ),
              ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.system_update_outlined,
                  color: AppTheme.forestGreen,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'App Updates',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.slateDark,
                        ),
                  ),
                ),
                IconButton(
                  onPressed:
                      _isDownloading ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('input_update_manifest_url'),
              controller: _urlCtrl,
              enabled: !_isChecking && !_isDownloading,
              decoration: const InputDecoration(
                labelText: 'Release Manifest URL',
                prefixIcon: Icon(Icons.link_outlined),
              ),
            ),
            const SizedBox(height: 14),
            if (_isChecking)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    SizedBox(width: 12),
                    Text('Checking release manifest...'),
                  ],
                ),
              ),
            if (_statusMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: updateAvailable
                      ? AppTheme.infoSurface
                      : AppTheme.successSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      updateAvailable
                          ? Icons.new_releases_outlined
                          : Icons.check_circle_outline,
                      color: updateAvailable
                          ? AppTheme.info
                          : AppTheme.forestGreen,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: updateAvailable
                              ? AppTheme.info
                              : AppTheme.forestGreenDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (manifest != null && manifest.releaseNotes.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceSage,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Release Notes',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: AppTheme.slateInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      manifest.releaseNotes,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.slateMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_isDownloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _downloadProgress),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.dangerSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: AppTheme.danger,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('btn_check_update_now'),
                    onPressed:
                        _isChecking || _isDownloading ? null : _checkForUpdates,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check Now'),
                  ),
                ),
                if (updateAvailable && manifest != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('btn_install_update'),
                      onPressed: _isDownloading ? null : _downloadAndInstall,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Install Update'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
