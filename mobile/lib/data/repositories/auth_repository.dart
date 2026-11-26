import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import '../services/crypto_service.dart';
import '../services/local_storage_service.dart';
import '../services/remote_update_service.dart';
import '../services/supabase_service.dart';
import 'vault_repository.dart';

/// Abstraction over `LocalAuthentication` for unit testing.
abstract class BiometricGateway {
  Future<bool> isDeviceSupported();
  Future<bool> canCheckBiometrics();
  Future<bool> authenticate({required String localizedReason});
}

class DeviceBiometricGateway implements BiometricGateway {
  DeviceBiometricGateway([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isDeviceSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> canCheckBiometrics() => _auth.canCheckBiometrics;

  @override
  Future<bool> authenticate({required String localizedReason}) {
    return _auth.authenticate(
      localizedReason: localizedReason,
      options: const AuthenticationOptions(
        stickyAuth: true,
        biometricOnly: false,
      ),
    );
  }
}

/// Manages invite-only Supabase authentication, E2EE key derivation/migration,
/// safe sync-gated sign-out, and device biometric quick-unlock.
class AuthRepository extends ChangeNotifier {
  AuthRepository({
    required this._supabase,
    required LocalStorageService localStorage,
    required CryptoService cryptoService,
    required VaultRepository vaultRepository,
    BiometricGateway? biometrics,
  })  : _storage = localStorage,
        _crypto = cryptoService,
        _vault = vaultRepository,
        _biometrics = biometrics ?? DeviceBiometricGateway();

  final SupabaseGateway _supabase;
  final LocalStorageService _storage;
  final CryptoService _crypto;
  final VaultRepository _vault;
  final BiometricGateway _biometrics;

  AuthUserInfo? _currentUser;

  AuthUserInfo? get currentUser => _currentUser;

  Future<AuthUserInfo?> getCurrentUser() async {
    final user = await _supabase.getCurrentUser();
    _currentUser = user;
    if (user != null) {
      await _storage.setUserId(user.id);
      if (user.email != null && user.email!.isNotEmpty) {
        await _storage.setUserEmail(user.email!);
      }
    }
    notifyListeners();
    return user;
  }

  Future<String?> getUserId() async {
    if (_currentUser != null) return _currentUser!.id;
    return _storage.getUserId();
  }

  Future<String?> getUserEmail() async {
    if (_currentUser?.email != null) {
      return _currentUser!.email!.toLowerCase().trim();
    }
    return _storage.getUserEmail();
  }

  /// Public sign-up is disabled (matching `supabase-config.js`).
  Future<void> signUp() {
    throw UnsupportedError(
      'Public sign-up is disabled. Ask the administrator for an invite.',
    );
  }

  /// Signs in with email and password, then derives/migrates the E2EE vault key.
  Future<AuthUserInfo> signIn(String email, String password) async {
    final normalizedEmail = email.trim().toLowerCase();
    final user = await _supabase.signInWithPassword(normalizedEmail, password);
    _currentUser = user;
    await _storage.setUserId(user.id);
    if (user.email != null && user.email!.isNotEmpty) {
      await _storage.setUserEmail(user.email!);
    }
    await _vault.migrateE2EKey(password, user.id);
    notifyListeners();
    return user;
  }

  /// Verifies that an email was invited by the administrator in Supabase Auth
  /// (rejecting uninvited emails immediately with `shouldCreateUser: false`).
  Future<void> verifyInvitedEmail(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    await _supabase.verifyInvitedEmail(normalizedEmail);
  }

  /// Verifies an invite signup OTP code, signs in, and initializes the E2EE vault key.
  Future<AuthUserInfo> verifyOtp({
    required String email,
    required String token,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    await _supabase.verifySignupOtp(normalizedEmail, token.trim());
    return signIn(normalizedEmail, password);
  }

  /// Syncs unsaved vault changes before signing out. Aborts sign-out if sync fails.
  Future<bool> signOut() async {
    final synced = await _vault.syncNow();
    if (!synced) {
      return false;
    }
    try {
      await _supabase.signOut();
    } catch (_) {
      return false;
    }
    _currentUser = null;
    await _vault.clearLocalData();
    await _storage.clearAllOnSignOut();
    await RemoteUpdateService.purgeStaleTempExports(purgeAll: true);
    notifyListeners();
    return true;
  }

  /// Verifies the signed-in user's master password against Supabase Auth and
  /// re-derives/persists their E2EE vault key without signing them out.
  Future<void> reunlockVaultKey(String password) async {
    if (password.isEmpty) {
      throw ArgumentError('Enter your account password.');
    }
    final user = await getCurrentUser();
    final email = (user?.email ?? await getUserEmail())?.trim().toLowerCase();
    if (user == null || email == null || email.isEmpty) {
      throw StateError(
        'No active account session was found. Please sign in again.',
      );
    }
    await _supabase.signInWithPassword(email, password);
    _currentUser = user;
    await _storage.setUserId(user.id);
    await _storage.setUserEmail(email);
    await _vault.migrateE2EKey(password, user.id);
    notifyListeners();
  }

  /// Changes the master password, re-derives the per-user E2EE key, re-encrypts
  /// and syncs the vault, and signs out other sessions.
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = await getCurrentUser();
    final email = user?.email;
    if (user == null || email == null || email.isEmpty) {
      throw StateError('Not authenticated.');
    }
    if (newPassword.length < 6) {
      throw ArgumentError('New password must be at least 6 characters long.');
    }

    await _supabase.signInWithPassword(email, currentPassword);
    await _supabase.updatePassword(newPassword);

    final newJwk = await _crypto.deriveKey(newPassword, user.id);
    await _storage.setE2eKey(newJwk);
    await _storage.setSaltVersion('2');

    final synced = await _vault.syncNow();
    if (!synced) {
      throw const VaultSyncException(
        'Password updated, but vault sync could not be confirmed.',
      );
    }

    try {
      await _supabase.signOut(othersOnly: true);
    } catch (_) {
      // Best-effort revocation of other sessions.
    }
    notifyListeners();
  }

  // --- Biometric App Lock ---

  Future<bool> canUseBiometrics() async {
    try {
      final supported = await _biometrics.isDeviceSupported();
      final canCheck = await _biometrics.canCheckBiometrics();
      return supported || canCheck;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isBiometricEnabled() => _storage.isBiometricEnabled();

  Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.setBiometricEnabled(enabled);
    notifyListeners();
  }

  Future<bool> authenticateWithBiometrics({
    String reason = 'Unlock Town Treasure Groceries vault',
  }) async {
    try {
      return await _biometrics.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}
