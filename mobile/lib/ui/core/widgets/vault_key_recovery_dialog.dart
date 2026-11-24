import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/auth_repository.dart';
import '../theme/app_theme.dart';
import '../user_friendly_error.dart';
import 'scoped_text_controllers.dart';

/// Shared inline password confirmation dialog & warning banner for restoring
/// a missing or invalidated device E2EE vault key without signing out.
class VaultKeyRecoveryDialog {
  VaultKeyRecoveryDialog._();

  static AuthRepository? _tryReadAuth(BuildContext context) {
    try {
      return context.read<AuthRepository>();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> show(
    BuildContext context, {
    AuthRepository? authRepository,
    String description =
        'Your phone secure key store needs a quick confirmation after updating. Enter your Town Treasure account password once to restore cloud sync and cross-device duplicate protection without signing out.',
  }) async {
    final authRepo = authRepository ?? _tryReadAuth(context);
    if (authRepo == null || !context.mounted) return false;

    var isUnlocking = false;
    var obscure = true;
    String? dialogError;

    final restored = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => ScopedTextControllers(
        initialTexts: const [''],
        builder: (dialogCtx, ctrls) {
          final passwordCtrl = ctrls[0];
          return StatefulBuilder(
            builder: (dialogCtx, setDialogState) {
              Future<void> unlock() async {
                final pwd = passwordCtrl.text;
                if (pwd.isEmpty) {
                  setDialogState(
                    () => dialogError = 'Enter your account password.',
                  );
                  return;
                }
                setDialogState(() {
                  isUnlocking = true;
                  dialogError = null;
                });
                try {
                  await authRepo.reunlockVaultKey(pwd);
                  if (dialogCtx.mounted) {
                    Navigator.of(dialogCtx).pop(true);
                  }
                } catch (e) {
                  if (!dialogCtx.mounted) return;
                  setDialogState(() {
                    isUnlocking = false;
                    dialogError = UserFriendlyError.format(
                      e,
                      fallback:
                          'Could not verify that password. Please check your password and try again.',
                    );
                  });
                }
              }

              return AlertDialog(
                title: const Text('Unlock Encryption Key'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('field_restore_vault_password'),
                        controller: passwordCtrl,
                        obscureText: obscure,
                        autofocus: true,
                        onSubmitted: (_) => isUnlocking ? null : unlock(),
                        decoration: InputDecoration(
                          labelText: 'Account Password',
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setDialogState(() => obscure = !obscure),
                            icon: Icon(
                              obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          dialogError!,
                          style: const TextStyle(
                            color: AppTheme.danger,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: isUnlocking
                        ? null
                        : () => Navigator.of(dialogCtx).pop(false),
                    child: const Text('Later'),
                  ),
                  FilledButton.icon(
                    key: const Key('btn_confirm_restore_vault_key'),
                    onPressed: isUnlocking ? null : unlock,
                    icon: isUnlocking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.key_outlined, size: 18),
                    label: Text(isUnlocking ? 'Unlocking...' : 'Unlock Key'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
    return restored == true;
  }
}

class VaultKeyWarningBanner extends StatelessWidget {
  const VaultKeyWarningBanner({
    super.key,
    required this.onUnlockPressed,
  });

  final VoidCallback onUnlockPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('banner_unlock_vault_key'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warningSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.warning.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.key_off_outlined, color: AppTheme.warning),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cloud Sync Key Locked',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: AppTheme.slateInk,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Confirm your password once to re-enable encrypted cloud sync and cross-device duplicate checks.',
                  style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const Key('btn_banner_unlock_key'),
            onPressed: onUnlockPressed,
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }
}
