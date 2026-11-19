import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import 'auth_view_model.dart';

/// Invite-only authentication, OTP verification, onboarding wizard, and
/// biometric screen-lock unlock UI.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.onAuthenticated,
    this.viewModel,
    this.autoInitialize = true,
  });

  final void Function(AuthUserInfo user) onAuthenticated;
  final AuthViewModel? viewModel;
  final bool autoInitialize;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final AuthViewModel _vm;
  late final bool _ownsViewModel;

  final _loginEmailCtrl = TextEditingController();
  final _loginPasswordCtrl = TextEditingController();
  final _otpEmailCtrl = TextEditingController();
  final _otpCodeCtrl = TextEditingController();
  final _otpPasswordCtrl = TextEditingController();
  final _wizEmailCtrl = TextEditingController();
  final _wizPasswordCtrl = TextEditingController();
  final _wizConfirmCtrl = TextEditingController();
  final _wizOtpCtrl = TextEditingController();

  bool _obscureLoginPassword = true;
  bool _obscureOtpPassword = true;
  bool _obscureWizPassword = true;
  bool _notifiedAuth = false;

  @override
  void initState() {
    super.initState();
    if (widget.viewModel != null) {
      _vm = widget.viewModel!;
      _ownsViewModel = false;
    } else {
      _vm = AuthViewModel(authRepository: context.read<AuthRepository>());
      _ownsViewModel = true;
    }
    _vm.addListener(_onVmChanged);

    if (widget.autoInitialize) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final user = await _vm.initialize();
        if (mounted && user != null) {
          _notifyAuthenticated(user);
        }
      });
    }
  }

  void _onVmChanged() {
    if (!mounted) return;
    setState(() {});
    final user = _vm.authenticatedUser;
    if (_vm.mode == AuthMode.authenticated && user != null) {
      _notifyAuthenticated(user);
    }
  }

  void _notifyAuthenticated(AuthUserInfo user) {
    if (_notifiedAuth) return;
    _notifiedAuth = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onAuthenticated(user);
      }
    });
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmChanged);
    if (_ownsViewModel) {
      _vm.dispose();
    }
    _loginEmailCtrl.dispose();
    _loginPasswordCtrl.dispose();
    _otpEmailCtrl.dispose();
    _otpCodeCtrl.dispose();
    _otpPasswordCtrl.dispose();
    _wizEmailCtrl.dispose();
    _wizPasswordCtrl.dispose();
    _wizConfirmCtrl.dispose();
    _wizOtpCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceSage,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.sageTint,
              AppTheme.surfaceSage,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: const BorderSide(color: AppTheme.borderSubtle),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: AnimatedSwitcher(
                          duration: AppMotion.standard,
                          switchInCurve: AppMotion.standardCurve,
                          switchOutCurve: AppMotion.exitCurve,
                          child: _buildActivePanel(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActivePanel(BuildContext context) {
    switch (_vm.mode) {
      case AuthMode.checking:
        return _buildCheckingPanel();
      case AuthMode.quickUnlock:
        return _buildQuickUnlockPanel(context);
      case AuthMode.signIn:
        return _buildSignInPanel(context);
      case AuthMode.otpVerification:
        return _buildOtpPanel(context);
      case AuthMode.wizard:
        return _buildWizardPanel(context);
      case AuthMode.authenticated:
        return _buildAuthenticatedPanel(context);
    }
  }

  Widget _buildAuthenticatedPanel(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('authenticated'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _BrandLogo(height: 56),
            const SizedBox(height: 16),
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: AppTheme.successSurface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.verified_user_outlined,
                color: AppTheme.forestGreen,
                size: 26,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Vault unlocked',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateDark,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Opening your encrypted workspace...',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.slateMuted,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckingPanel({String label = 'Checking encrypted session...'}) {
    return KeyedSubtree(
      key: ValueKey('checking_$label'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _BrandLogo(height: 60),
            const SizedBox(height: 20),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.8),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.slateMuted,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickUnlockPanel(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('quick_unlock'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BrandLogo(height: 64),
          const SizedBox(height: 16),
          Text(
            'Welcome back',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Use your device screen lock or biometrics to unlock your vault',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.slateMuted,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _ErrorBanner(message: _vm.errorMessage),
          FilledButton.icon(
            key: const Key('btn_quick_unlock'),
            onPressed: _vm.isBusy ? null : () => _vm.unlockWithBiometrics(),
            icon: _vm.isBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.fingerprint),
            label: const Text('Unlock with Screen Lock'),
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const Key('btn_use_password_instead'),
            onPressed: _vm.isBusy ? null : _vm.showSignIn,
            child: const Text('Use email and password instead'),
          ),
        ],
      ),
    );
  }

  Widget _buildSignInPanel(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('sign_in'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BrandLogo(height: 60),
          const SizedBox(height: 14),
          Text(
            'Welcome back',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Sign in to access your encrypted books',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.slateMuted,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          _ErrorBanner(message: _vm.errorMessage),
          TextField(
            key: const Key('input_login_email'),
            controller: _loginEmailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'your@email.com',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('input_login_password'),
            controller: _loginPasswordCtrl,
            obscureText: _obscureLoginPassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _handleSignIn(),
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: 'Your password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscureLoginPassword = !_obscureLoginPassword;
                  });
                },
                icon: Icon(
                  _obscureLoginPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const Key('btn_sign_in'),
            onPressed: _vm.isBusy ? null : _handleSignIn,
            child: _vm.isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Sign In'),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceSage,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  size: 18,
                  color: AppTheme.forestGreen,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Invite-only access. Contact the administrator for an invite.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.slateMuted,
                        ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: [
              TextButton.icon(
                key: const Key('btn_open_otp'),
                onPressed: _vm.isBusy
                    ? null
                    : () => _vm.showOtpVerification(
                          initialEmail: _loginEmailCtrl.text,
                        ),
                icon: const Icon(Icons.pin_outlined, size: 18),
                label: const Text('Verify Invite OTP'),
              ),
              TextButton.icon(
                key: const Key('btn_start_wizard'),
                onPressed: _vm.isBusy ? null : _vm.startWizard,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Setup Guide'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOtpPanel(BuildContext context) {
    if (_otpEmailCtrl.text.isEmpty && _vm.wizardEmail.isNotEmpty) {
      _otpEmailCtrl.text = _vm.wizardEmail;
    }
    return KeyedSubtree(
      key: const ValueKey('otp_verification'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _vm.isBusy ? null : _vm.showSignIn,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Verify Invite Code',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.slateDark,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the invited email address, the verification code from your inbox, and the password you set for your vault.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.slateMuted,
                ),
          ),
          const SizedBox(height: 16),
          _ErrorBanner(message: _vm.errorMessage),
          TextField(
            key: const Key('input_otp_email'),
            controller: _otpEmailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Invited Email',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('input_otp_code'),
            controller: _otpCodeCtrl,
            keyboardType: TextInputType.number,
            maxLength: 8,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
            decoration: const InputDecoration(
              labelText: 'Invite OTP Code',
              hintText: '8-digit code',
              counterText: '',
              prefixIcon: Icon(Icons.password_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('input_otp_password'),
            controller: _otpPasswordCtrl,
            obscureText: _obscureOtpPassword,
            decoration: InputDecoration(
              labelText: 'Vault Password (min 6 chars)',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscureOtpPassword = !_obscureOtpPassword;
                  });
                },
                icon: Icon(
                  _obscureOtpPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const Key('btn_verify_otp_submit'),
            onPressed: _vm.isBusy
                ? null
                : () async {
                    await _vm.verifyInviteOtp(
                      email: _otpEmailCtrl.text,
                      token: _otpCodeCtrl.text,
                      password: _otpPasswordCtrl.text,
                      enterWizardSuccessStep: true,
                    );
                  },
            child: _vm.isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Verify and Continue'),
          ),
        ],
      ),
    );
  }

  Widget _buildWizardPanel(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey('wizard_step_${_vm.wizardStep}'),
      child: AnimatedSwitcher(
        duration: AppMotion.standard,
        switchInCurve: AppMotion.standardCurve,
        switchOutCurve: AppMotion.exitCurve,
        child: switch (_vm.wizardStep) {
          1 => _buildWizardStep1(context),
          2 => _buildWizardStep2(context),
          3 => _buildWizardStep3(context),
          4 => _buildWizardStep4(context),
          5 => _buildWizardStep5(context),
          _ => _buildWizardStep6(context),
        },
      ),
    );
  }

  Widget _buildWizardStep1(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_1'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BrandLogo(height: 64),
          const SizedBox(height: 16),
          Text(
            'Welcome to Town Treasure',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Your personal business companion for invoices, bookkeeping, payroll, and financial reports.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.slateMuted,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('btn_wiz_get_started'),
            onPressed: () => _vm.goToWizardStep(2),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Let us Get Started'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _vm.showSignIn,
            child: const Text('Already have an account? Sign In'),
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep2(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_2'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WizardHeader(
            stepLabel: 'Step 1 of 3',
            icon: Icons.mail_outline,
            title: 'Your invited email',
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the email address invited by your administrator.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.slateMuted,
                ),
          ),
          const SizedBox(height: 16),
          _ErrorBanner(message: _vm.errorMessage),
          TextField(
            key: const Key('input_wiz_email'),
            controller: _wizEmailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Email Address',
              hintText: 'name@example.com',
              prefixIcon: Icon(Icons.mail_outline),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _vm.goToWizardStep(1),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('btn_wiz_email_next'),
                  onPressed: _vm.isBusy
                      ? null
                      : () async {
                          await _vm.advanceFromEmailStep(_wizEmailCtrl.text);
                        },
                  child: _vm.isBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Verify & Continue'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep3(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_3'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WizardHeader(
            stepLabel: 'Step 2 of 3',
            icon: Icons.shield_outlined,
            title: 'Your data is completely private',
          ),
          const SizedBox(height: 12),
          const _SecurityPoint(
            title: 'Encrypted and Personal',
            description:
                'All your invoices, finances, and client records are encrypted before leaving your device.',
          ),
          const SizedBox(height: 10),
          const _SecurityPoint(
            title: 'Zero-Knowledge Key',
            description:
                'Only your password unlocks your vault key. Not even the server administrator can read it.',
          ),
          const SizedBox(height: 10),
          const _SecurityPoint(
            title: 'Screen Lock Protection',
            description:
                'After setup, unlock quickly with your fingerprint, face, or device PIN.',
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _vm.goToWizardStep(2),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('btn_wiz_security_next'),
                  onPressed: () => _vm.goToWizardStep(4),
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep4(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_4'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WizardHeader(
            stepLabel: 'Step 3 of 3',
            icon: Icons.lock_outline,
            title: 'Set your vault password',
          ),
          const SizedBox(height: 8),
          Text(
            'This password protects your encrypted business data. Choose at least 6 characters.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.slateMuted,
                ),
          ),
          const SizedBox(height: 14),
          _ErrorBanner(message: _vm.errorMessage),
          TextField(
            key: const Key('input_wiz_password'),
            controller: _wizPasswordCtrl,
            obscureText: _obscureWizPassword,
            decoration: InputDecoration(
              labelText: 'Password (min 6 characters)',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscureWizPassword = !_obscureWizPassword;
                  });
                },
                icon: Icon(
                  _obscureWizPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('input_wiz_confirm_password'),
            controller: _wizConfirmCtrl,
            obscureText: _obscureWizPassword,
            decoration: const InputDecoration(
              labelText: 'Confirm Password',
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _vm.goToWizardStep(3),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('btn_wiz_password_next'),
                  onPressed: () => _vm.advanceFromPasswordStep(
                    _wizPasswordCtrl.text,
                    _wizConfirmCtrl.text,
                  ),
                  child: const Text('Verify Invite'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep5(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_5'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WizardHeader(
            stepLabel: 'Verification',
            icon: Icons.mark_email_read_outlined,
            title: 'Check your email',
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the verification code sent to ${_vm.wizardEmail}.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.slateMuted,
                ),
          ),
          const SizedBox(height: 14),
          _ErrorBanner(message: _vm.errorMessage),
          TextField(
            key: const Key('input_wiz_otp'),
            controller: _wizOtpCtrl,
            keyboardType: TextInputType.number,
            maxLength: 8,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
            decoration: const InputDecoration(
              labelText: 'Verification Code',
              hintText: '8-digit code',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('btn_wiz_verify_otp'),
            onPressed: _vm.isBusy
                ? null
                : () => _vm.verifyWizardOtp(_wizOtpCtrl.text),
            child: _vm.isBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Verify Code'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                _vm.isBusy ? null : () => _vm.checkEmailConfirmedAndAdvance(),
            child: const Text('Or tap here if you confirmed via email link'),
          ),
          TextButton(
            onPressed: _vm.isBusy ? null : () => _vm.goToWizardStep(4),
            child: const Text('Back to password'),
          ),
        ],
      ),
    );
  }

  Widget _buildWizardStep6(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('wiz_6'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: AppTheme.successSurface,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_outline,
              size: 32,
              color: AppTheme.forestGreen,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'You are all set',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.slateDark,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Your vault is encrypted and private to your account. Enable screen lock so you can open the app instantly next time.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.slateMuted,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          _ErrorBanner(message: _vm.errorMessage),
          if (_vm.infoMessage != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _vm.infoMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.warning,
                    ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          FilledButton.icon(
            key: const Key('btn_setup_biometrics'),
            onPressed:
                _vm.isBusy ? null : () => _vm.setupScreenLockAndFinish(),
            icon: const Icon(Icons.fingerprint),
            label: const Text('Set Up Screen Lock'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('btn_skip_biometrics'),
            onPressed:
                _vm.isBusy ? null : () => _vm.skipScreenLockAndFinish(),
            child: const Text('Skip for now'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSignIn() async {
    await _vm.signIn(
      email: _loginEmailCtrl.text,
      password: _loginPasswordCtrl.text,
    );
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/logo.png',
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: height,
          height: height,
          decoration: BoxDecoration(
            color: AppTheme.sageTint,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.storefront_outlined,
            size: 32,
            color: AppTheme.forestGreen,
          ),
        );
      },
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.fast,
      curve: AppMotion.standardCurve,
      child: message == null
          ? const SizedBox.shrink()
          : Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.dangerSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 18,
                    color: AppTheme.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      message!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.danger,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _WizardHeader extends StatelessWidget {
  const _WizardHeader({
    required this.stepLabel,
    required this.icon,
    required this.title,
  });

  final String stepLabel;
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.sageTint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            stepLabel,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.forestGreenDeep,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppTheme.sageTint,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: AppTheme.forestGreen, size: 26),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTheme.slateDark,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _SecurityPoint extends StatelessWidget {
  const _SecurityPoint({
    required this.title,
    required this.description,
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSage,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: AppTheme.forestGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, color: Colors.white, size: 15),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.slateInk,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    color: AppTheme.slateMuted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
