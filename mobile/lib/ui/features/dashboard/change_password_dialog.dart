import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Master password change dialog matching `dashboard.js` and `index.html`:
/// validates current password, enforces 6+ character length and confirmation,
/// warns about E2EE key irreversibility, and invokes `onChangePassword`.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({
    super.key,
    required this.onChangePassword,
  });

  final Future<void> Function({
    required String currentPassword,
    required String newPassword,
  }) onChangePassword;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _showPasswords = false;
  bool _understoodWarning = false;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final currentPass = _currentCtrl.text;
    final newPass = _newCtrl.text;
    final confirmPass = _confirmCtrl.text;

    if (currentPass.isEmpty || newPass.isEmpty || confirmPass.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all password fields.');
      return;
    }
    if (newPass.length < 6) {
      setState(
        () => _errorMessage = 'New password must be at least 6 characters long.',
      );
      return;
    }
    if (newPass != confirmPass) {
      setState(() => _errorMessage = 'New passwords do not match.');
      return;
    }
    if (!_understoodWarning) {
      setState(
        () => _errorMessage =
            'Please acknowledge that you have recorded your new password.',
      );
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      await widget.onChangePassword(
        currentPassword: currentPass,
        newPassword: newPass,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_reset_outlined, color: AppTheme.forestGreen),
          SizedBox(width: 8),
          Expanded(child: Text('Change Master Password')),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your password derives the encryption key for your entire vault. If you lose your new password, your data cannot be recovered.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.slateMuted,
                    ),
              ),
              const SizedBox(height: 12),
              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
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
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              TextField(
                key: const Key('input_cp_current'),
                controller: _currentCtrl,
                obscureText: !_showPasswords,
                decoration: const InputDecoration(
                  labelText: 'Current Password',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('input_cp_new'),
                controller: _newCtrl,
                obscureText: !_showPasswords,
                decoration: const InputDecoration(
                  labelText: 'New Password (min 6 chars)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('input_cp_confirm'),
                controller: _confirmCtrl,
                obscureText: !_showPasswords,
                decoration: const InputDecoration(
                  labelText: 'Confirm New Password',
                ),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                key: const Key('chk_cp_show'),
                value: _showPasswords,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: const Text('Show passwords'),
                onChanged: _isSaving
                    ? null
                    : (v) => setState(() => _showPasswords = v ?? false),
              ),
              Material(
                color: AppTheme.warningSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: AppTheme.warning.withValues(alpha: 0.35),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: CheckboxListTile(
                    key: const Key('chk_cp_understand'),
                    value: _understoodWarning,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: const Text(
                      'I have safely recorded my new password and understand that lost passwords cannot be recovered.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onChanged: _isSaving
                        ? null
                        : (v) =>
                            setState(() => _understoodWarning = v ?? false),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('btn_cp_submit'),
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Change Password'),
        ),
      ],
    );
  }
}
