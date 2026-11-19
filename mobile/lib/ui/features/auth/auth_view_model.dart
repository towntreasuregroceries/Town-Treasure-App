import 'package:flutter/foundation.dart';

import '../../../data/repositories/auth_repository.dart';
import '../../../data/services/supabase_service.dart';

/// Active authentication view mode.
enum AuthMode {
  checking,
  quickUnlock,
  signIn,
  otpVerification,
  wizard,
  authenticated,
}

/// ViewModel managing invite-only Sign In, OTP verification, onboarding wizard,
/// and biometric/screen-lock quick unlock.
class AuthViewModel extends ChangeNotifier {
  AuthViewModel({
    required this._authRepository,
  });

  final AuthRepository _authRepository;

  AuthMode _mode = AuthMode.checking;
  int _wizardStep = 1;
  bool _isBusy = false;
  String? _errorMessage;
  String? _infoMessage;
  bool _canUseBiometrics = false;
  bool _biometricEnabled = false;
  AuthUserInfo? _authenticatedUser;

  String _wizardEmail = '';
  String _wizardPassword = '';

  AuthMode get mode => _mode;
  int get wizardStep => _wizardStep;
  bool get isBusy => _isBusy;
  String? get errorMessage => _errorMessage;
  String? get infoMessage => _infoMessage;
  bool get canUseBiometrics => _canUseBiometrics;
  bool get biometricEnabled => _biometricEnabled;
  AuthUserInfo? get authenticatedUser => _authenticatedUser;
  String get wizardEmail => _wizardEmail;

  /// Checks active session and biometric lock state on startup.
  Future<AuthUserInfo?> initialize() async {
    _mode = AuthMode.checking;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    _canUseBiometrics = await _authRepository.canUseBiometrics();
    _biometricEnabled = await _authRepository.isBiometricEnabled();

    final user = await _authRepository.getCurrentUser();
    if (user != null) {
      if (_biometricEnabled) {
        _mode = AuthMode.quickUnlock;
        notifyListeners();
        return null;
      }
      _authenticatedUser = user;
      _mode = AuthMode.authenticated;
      notifyListeners();
      return user;
    }

    _mode = AuthMode.signIn;
    notifyListeners();
    return null;
  }

  void showSignIn() {
    _mode = AuthMode.signIn;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();
  }

  void showOtpVerification({String initialEmail = ''}) {
    if (initialEmail.trim().isNotEmpty) {
      _wizardEmail = initialEmail.trim();
    }
    _mode = AuthMode.otpVerification;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();
  }

  void startWizard() {
    _mode = AuthMode.wizard;
    _wizardStep = 1;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();
  }

  void goToWizardStep(int step) {
    _wizardStep = step.clamp(1, 6);
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();
  }

  /// Validates format and checks Supabase Auth to ensure the email was invited
  /// before allowing the user to advance past Step 2 of the setup wizard.
  Future<bool> advanceFromEmailStep(String email) async {
    final trimmed = email.trim().toLowerCase();
    if (trimmed.isEmpty) {
      _errorMessage = 'Please enter your invited email address.';
      notifyListeners();
      return false;
    }
    if (!trimmed.contains('@') || !trimmed.contains('.')) {
      _errorMessage = 'Please enter a valid email address.';
      notifyListeners();
      return false;
    }

    _setBusy(true);
    try {
      await _authRepository.verifyInvitedEmail(trimmed);
      _wizardEmail = trimmed;
      _errorMessage = null;
      _infoMessage = 'Invite verified. A verification code was sent to $trimmed.';
      _wizardStep = 3;
      _setBusy(false);
      return true;
    } catch (e) {
      _errorMessage = _formatAuthError(
        e,
        fallback:
            'This email has not been invited yet. Please ask your administrator for an invite.',
      );
      _setBusy(false);
      return false;
    }
  }

  /// Validates and stores the master password on Wizard Step 4, then advances
  /// to Step 5 (Invite OTP verification).
  bool advanceFromPasswordStep(String password, String confirmPassword) {
    if (password.isEmpty) {
      _errorMessage = 'Password is required to secure your data.';
      notifyListeners();
      return false;
    }
    if (password.length < 6) {
      _errorMessage = 'Password must be at least 6 characters.';
      notifyListeners();
      return false;
    }
    if (password != confirmPassword) {
      _errorMessage = 'Passwords do not match. Please try again.';
      notifyListeners();
      return false;
    }
    _wizardPassword = password;
    _errorMessage = null;
    _wizardStep = 5;
    notifyListeners();
    return true;
  }

  /// Invite-only password Sign In + E2EE vault key migration.
  Future<AuthUserInfo?> signIn({
    required String email,
    required String password,
  }) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty || password.isEmpty) {
      _errorMessage = 'Enter both your email and password.';
      notifyListeners();
      return null;
    }

    _setBusy(true);
    try {
      final user = await _authRepository.signIn(trimmedEmail, password);
      _authenticatedUser = user;
      _mode = AuthMode.authenticated;
      _setBusy(false);
      return user;
    } catch (e) {
      _errorMessage = _formatAuthError(
        e,
        fallback: 'Incorrect email or password.',
      );
      _setBusy(false);
      return null;
    }
  }

  /// Verifies an invite OTP token (from wizard Step 5 or standalone OTP view),
  /// signs in, initializes the E2EE key, and moves to biometric setup (Step 6)
  /// or completes authentication.
  Future<AuthUserInfo?> verifyInviteOtp({
    required String email,
    required String token,
    required String password,
    bool enterWizardSuccessStep = false,
  }) async {
    final trimmedEmail = email.trim();
    final trimmedToken = token.trim();
    if (trimmedEmail.isEmpty || !trimmedEmail.contains('@')) {
      _errorMessage = 'Please enter a valid invited email address.';
      notifyListeners();
      return null;
    }
    if (trimmedToken.length < 6) {
      _errorMessage =
          'Please enter the verification code exactly as shown in your email.';
      notifyListeners();
      return null;
    }
    if (password.length < 6) {
      _errorMessage = 'Password must be at least 6 characters.';
      notifyListeners();
      return null;
    }

    _setBusy(true);
    try {
      final user = await _authRepository.verifyOtp(
        email: trimmedEmail,
        token: trimmedToken,
        password: password,
      );
      _authenticatedUser = user;
      _canUseBiometrics = await _authRepository.canUseBiometrics();
      if (enterWizardSuccessStep) {
        _mode = AuthMode.wizard;
        _wizardStep = 6;
        _setBusy(false);
        return null;
      }
      _mode = AuthMode.authenticated;
      _setBusy(false);
      return user;
    } catch (e) {
      _errorMessage = _formatAuthError(
        e,
        fallback: 'Invalid or expired code. Please try again.',
      );
      _setBusy(false);
      return null;
    }
  }

  /// Verifies the OTP entered in Wizard Step 5 using stored wizard email/password.
  Future<void> verifyWizardOtp(String token) async {
    await verifyInviteOtp(
      email: _wizardEmail,
      token: token,
      password: _wizardPassword,
      enterWizardSuccessStep: true,
    );
  }

  /// Checks if the user confirmed their invite via email link and signs in.
  Future<void> checkEmailConfirmedAndAdvance() async {
    await signIn(email: _wizardEmail, password: _wizardPassword).then((user) {
      if (user != null) {
        _mode = AuthMode.wizard;
        _wizardStep = 6;
        notifyListeners();
      } else {
        _errorMessage =
            'Email is not confirmed yet. Enter the OTP code or click the link in your inbox.';
        notifyListeners();
      }
    });
  }

  /// Enables biometric/screen lock on Wizard Step 6 and completes onboarding.
  Future<AuthUserInfo?> setupScreenLockAndFinish() async {
    _setBusy(true);
    final available = await _authRepository.canUseBiometrics();
    if (!available) {
      _infoMessage =
          'Screen lock is not available on this device. You can sign in with email and password.';
      await _authRepository.setBiometricEnabled(false);
      _biometricEnabled = false;
      final user = _authenticatedUser ?? await _authRepository.getCurrentUser();
      _authenticatedUser = user;
      _mode = AuthMode.authenticated;
      _setBusy(false);
      return user;
    }

    final verified = await _authRepository.authenticateWithBiometrics(
      reason: 'Enable screen lock for Town Treasure Groceries',
    );
    if (verified) {
      await _authRepository.setBiometricEnabled(true);
      _biometricEnabled = true;
      final user = _authenticatedUser ?? await _authRepository.getCurrentUser();
      _authenticatedUser = user;
      _mode = AuthMode.authenticated;
      _setBusy(false);
      return user;
    }

    _errorMessage =
        'Screen lock setup was cancelled. Try again or skip for now.';
    _setBusy(false);
    return null;
  }

  /// Skips screen lock setup on Wizard Step 6 and enters the app.
  Future<AuthUserInfo?> skipScreenLockAndFinish() async {
    await _authRepository.setBiometricEnabled(false);
    _biometricEnabled = false;
    final user = _authenticatedUser ?? await _authRepository.getCurrentUser();
    _authenticatedUser = user;
    if (user != null) {
      _mode = AuthMode.authenticated;
    } else {
      _mode = AuthMode.signIn;
    }
    notifyListeners();
    return user;
  }

  /// Authenticates a returning user with device biometrics / screen lock.
  Future<AuthUserInfo?> unlockWithBiometrics() async {
    _setBusy(true);
    final ok = await _authRepository.authenticateWithBiometrics(
      reason: 'Unlock Town Treasure Groceries vault',
    );
    if (!ok) {
      _errorMessage =
          'Screen lock failed or was cancelled. Try again or use email and password.';
      _setBusy(false);
      return null;
    }

    final user = await _authRepository.getCurrentUser();
    if (user == null) {
      _errorMessage = 'Session expired. Please sign in with email and password.';
      _mode = AuthMode.signIn;
      _setBusy(false);
      return null;
    }

    _authenticatedUser = user;
    _mode = AuthMode.authenticated;
    _setBusy(false);
    return user;
  }

  void clearMessages() {
    if (_errorMessage == null && _infoMessage == null) return;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();
  }

  void _setBusy(bool busy) {
    _isBusy = busy;
    if (busy) {
      _errorMessage = null;
      _infoMessage = null;
    }
    notifyListeners();
  }

  String _formatAuthError(Object error, {required String fallback}) {
    final raw = error.toString();
    final lower = raw.toLowerCase();

    if (lower.contains('invalid login credentials') ||
        lower.contains('invalid_credentials') ||
        lower.contains('invalid email or password')) {
      return 'Incorrect email or password. Please check your spelling and try again.';
    }
    if (lower.contains('signups not allowed') ||
        lower.contains('otp_disabled') ||
        lower.contains('user not found') ||
        lower.contains('not invited')) {
      return 'This email has not been invited yet. Please contact the administrator to request an invite.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Your email is not confirmed yet. Check your inbox for the invite code.';
    }
    if (lower.contains('token has expired') ||
        lower.contains('invalid token') ||
        lower.contains('otp_expired')) {
      return 'That verification code is invalid or has expired. Please request a fresh code.';
    }
    if (lower.contains('rate limit') ||
        lower.contains('too many requests') ||
        lower.contains('429')) {
      return 'Too many attempts. Please wait a minute and try again.';
    }
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception') ||
        lower.contains('network') ||
        lower.contains('timed out')) {
      return 'Unable to connect right now. Please check your internet connection and try again.';
    }
    return fallback;
  }
}
