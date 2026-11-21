import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/repositories/auth_repository.dart';
import 'data/repositories/staging_repository.dart';
import 'data/repositories/vault_repository.dart';
import 'data/services/crypto_service.dart';
import 'data/services/duplicate_detector_service.dart';
import 'data/services/local_storage_service.dart';
import 'data/services/ocr_consensus_service.dart';
import 'data/services/personal_vault_service.dart';
import 'data/services/remote_update_service.dart';
import 'data/services/cloudflare_backend_service.dart';
import 'data/services/supabase_service.dart';
import 'ui/core/app_lock_guard.dart';
import 'ui/core/app_shell.dart';
import 'ui/core/developer_preview.dart';
import 'ui/core/theme/app_theme.dart';
import 'ui/features/auth/auth_screen.dart';
import 'ui/features/auth/auth_view_model.dart';
import 'ui/features/dashboard/background_update_worker.dart';
import 'ui/features/dashboard/signature_scanner_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();

  final cryptoService = CryptoService();
  final localStorageService = LocalStorageService();
  await localStorageService.init();

  final supabaseService = CloudflareBackendService(
    authGateway: SupabaseService(),
  );
  final vaultRepository = VaultRepository(
    cryptoService: cryptoService,
    localStorage: localStorageService,
    supabase: supabaseService,
  );
  await vaultRepository.loadFromLocalCache();

  final authRepository = AuthRepository(
    supabase: supabaseService,
    localStorage: localStorageService,
    cryptoService: cryptoService,
    vaultRepository: vaultRepository,
  );
  final stagingRepository = StagingRepository(
    supabase: supabaseService,
    localStorage: localStorageService,
    vaultRepository: vaultRepository,
  );
  final remoteUpdateService = RemoteUpdateService();
  final ocrService = OcrConsensusService();
  final duplicateDetectorService = DuplicateDetectorService();

  await BackgroundUpdateWorker.initializeAndSchedule(
    localStorage: localStorageService,
  );

  runApp(
    TownTreasureApp(
      cryptoService: cryptoService,
      localStorageService: localStorageService,
      supabaseService: supabaseService,
      vaultRepository: vaultRepository,
      authRepository: authRepository,
      stagingRepository: stagingRepository,
      remoteUpdateService: remoteUpdateService,
      ocrService: ocrService,
      duplicateDetectorService: duplicateDetectorService,
    ),
  );
}

class TownTreasureApp extends StatelessWidget {
  const TownTreasureApp({
    super.key,
    required this.cryptoService,
    required this.localStorageService,
    required this.supabaseService,
    required this.vaultRepository,
    required this.authRepository,
    required this.stagingRepository,
    required this.remoteUpdateService,
    this.ocrService,
    this.duplicateDetectorService,
    this.authViewModel,
    this.autoInitializeAuth = true,
    this.autoInitializeDashboard = true,
    this.initialTabIndex = 0,
    this.updateManifestUrl = AppShell.defaultUpdateManifestUrl,
    this.signatureImagePicker,
  });

  final CryptoService cryptoService;
  final LocalStorageService localStorageService;
  final SupabaseGateway supabaseService;
  final VaultRepository vaultRepository;
  final AuthRepository authRepository;
  final StagingRepository stagingRepository;
  final RemoteUpdateService remoteUpdateService;
  final OcrConsensusService? ocrService;
  final DuplicateDetectorService? duplicateDetectorService;
  final AuthViewModel? authViewModel;
  final bool autoInitializeAuth;
  final bool autoInitializeDashboard;
  final int initialTabIndex;
  final String updateManifestUrl;
  final ImageBytesPicker? signatureImagePicker;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<CryptoService>.value(value: cryptoService),
        Provider<LocalStorageService>.value(value: localStorageService),
        Provider<SupabaseGateway>.value(value: supabaseService),
        Provider<RemoteUpdateService>.value(value: remoteUpdateService),
        Provider<OcrConsensusService>(
          create: (_) => ocrService ?? OcrConsensusService(),
          dispose: (_, service) {
            if (ocrService == null) {
              service.dispose().catchError((_) {});
            }
          },
        ),
        Provider<DuplicateDetectorService>.value(
          value: duplicateDetectorService ?? DuplicateDetectorService(),
        ),
        Provider<PersonalVaultService>.value(
          value: PersonalVaultService(
            cryptoService: cryptoService,
            localStorage: localStorageService,
            supabase: supabaseService,
          ),
        ),
        ChangeNotifierProvider<VaultRepository>.value(value: vaultRepository),
        ChangeNotifierProvider<AuthRepository>.value(value: authRepository),
        ChangeNotifierProvider<StagingRepository>.value(
          value: stagingRepository,
        ),
        ChangeNotifierProvider<DeveloperPreviewController>(
          create: (_) => DeveloperPreviewController(),
        ),
      ],
      child: Consumer2<AuthRepository, DeveloperPreviewController>(
        builder: (_, auth, devPreview, _) => MaterialApp(
          title: 'Town Treasure Groceries',
          debugShowCheckedModeBanner: false,
          theme: devPreview.isRedesignedUiActiveFor(auth.currentUser?.email)
              ? AppTheme.redesignedLight()
              : AppTheme.light(),
          home: AuthGate(
            authViewModel: authViewModel,
            autoInitializeAuth: autoInitializeAuth,
            autoInitializeDashboard: autoInitializeDashboard,
            initialTabIndex: initialTabIndex,
            updateManifestUrl: updateManifestUrl,
            signatureImagePicker: signatureImagePicker,
          ),
        ),
      ),
    );
  }
}

/// Coordinates startup session checks, biometric/screen-lock unlock,
/// standalone Clerk Intake Portal access, and the authenticated `AppShell`.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    this.authViewModel,
    this.autoInitializeAuth = true,
    this.autoInitializeDashboard = true,
    this.initialTabIndex = 0,
    this.updateManifestUrl = AppShell.defaultUpdateManifestUrl,
    this.signatureImagePicker,
  });

  final AuthViewModel? authViewModel;
  final bool autoInitializeAuth;
  final bool autoInitializeDashboard;
  final int initialTabIndex;
  final String updateManifestUrl;
  final ImageBytesPicker? signatureImagePicker;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  AuthRepository? _authRepo;
  AuthUserInfo? _unlockedUser;
  bool _biometricLockEnabled = false;
  bool _lockedInBackground = false;
  int _authEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = context.read<AuthRepository>();
    if (_authRepo != repo) {
      _authRepo?.removeListener(_onAuthRepositoryChanged);
      _authRepo = repo;
      _authRepo!.addListener(_onAuthRepositoryChanged);
      _refreshBiometricStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authRepo?.removeListener(_onAuthRepositoryChanged);
    super.dispose();
  }

  Future<void> _refreshBiometricStatus() async {
    final repo = _authRepo;
    if (repo == null) return;
    final enabled = await repo.isBiometricEnabled();
    if (mounted) {
      _biometricLockEnabled = enabled;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _lockOnBackgroundIfEnabled();
    } else if (state == AppLifecycleState.resumed &&
        _lockedInBackground &&
        _unlockedUser == null) {
      _lockedInBackground = false;
      if (mounted) {
        setState(() {
          _authEpoch++;
        });
      }
    }
  }

  Future<void> _lockOnBackgroundIfEnabled() async {
    if (_unlockedUser == null || AppLockGuard.isSuppressed) return;

    if (_biometricLockEnabled) {
      _lockedInBackground = true;
      if (mounted) {
        setState(() {
          _unlockedUser = null;
          _authEpoch++;
        });
      }
      return;
    }

    final repo = _authRepo;
    if (repo == null) return;
    final enabled = await repo.isBiometricEnabled();
    _biometricLockEnabled = enabled;
    if (enabled && mounted && _unlockedUser != null && !AppLockGuard.isSuppressed) {
      _lockedInBackground = true;
      setState(() {
        _unlockedUser = null;
        _authEpoch++;
      });
    }
  }

  void _onAuthRepositoryChanged() {
    if (!mounted) return;
    _refreshBiometricStatus();
    if (_unlockedUser != null && _authRepo?.currentUser == null) {
      setState(() {
        _unlockedUser = null;
        _authEpoch++;
      });
    }
  }

  void _handleAuthenticated(AuthUserInfo user) {
    if (!mounted) return;
    _refreshBiometricStatus();
    setState(() {
      _unlockedUser = user;
    });
  }

  void _handleSignedOut() {
    if (!mounted) return;
    setState(() {
      _biometricLockEnabled = false;
      _unlockedUser = null;
      _authEpoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = _unlockedUser != null;

    return AnimatedSwitcher(
      duration: AppMotion.standard,
      switchInCurve: AppMotion.standardCurve,
      switchOutCurve: AppMotion.exitCurve,
      child: isUnlocked
          ? AppShell(
              key: ValueKey('app_shell_${_unlockedUser!.id}'),
              initialTabIndex: widget.initialTabIndex,
              autoInitializeDashboard: widget.autoInitializeDashboard,
              updateManifestUrl: widget.updateManifestUrl,
              signatureImagePicker: widget.signatureImagePicker,
              onSignedOut: _handleSignedOut,
            )
          : AuthScreen(
              key: ValueKey('auth_screen_$_authEpoch'),
              viewModel: widget.authViewModel,
              autoInitialize: widget.autoInitializeAuth,
              onAuthenticated: _handleAuthenticated,
            ),
    );
  }
}
