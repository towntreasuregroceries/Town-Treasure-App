import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/repositories/staging_repository.dart';
import 'data/repositories/vault_repository.dart';
import 'data/services/crypto_service.dart';
import 'data/services/duplicate_detector_service.dart';
import 'data/services/local_storage_service.dart';
import 'data/services/ocr_consensus_service.dart';
import 'data/services/remote_update_service.dart';
import 'data/services/cloudflare_backend_service.dart';
import 'data/services/supabase_service.dart';
import 'ui/core/theme/app_theme.dart';
import 'ui/features/clerk/clerk_portal_screen.dart';
import 'ui/features/clerk/clerk_view_model.dart';

/// Standalone Town Treasure Clerk Intake APK entrypoint (`--flavor clerk -t lib/main_clerk.dart`).
/// Boots directly into the token-gated Clerk Intake Portal with Camera/Gallery/PDF OCR,
/// compact produce row verification, duplicate checking, and 30-day / 7-day idle token enforcement.
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
  final stagingRepository = StagingRepository(
    supabase: supabaseService,
    localStorage: localStorageService,
    vaultRepository: vaultRepository,
  );
  final ocrService = OcrConsensusService();
  final duplicateDetectorService = DuplicateDetectorService();
  final remoteUpdateService = RemoteUpdateService();

  final clerkViewModel = ClerkViewModel(
    stagingRepository: stagingRepository,
    vaultRepository: vaultRepository,
    supabase: supabaseService,
    localStorage: localStorageService,
    ocrService: ocrService,
    duplicateDetector: duplicateDetectorService,
    updateService: remoteUpdateService,
    updateManifestUrl: RemoteUpdateService.defaultClerkManifestUrl,
  );

  runApp(
    TownTreasureClerkApp(
      localStorageService: localStorageService,
      supabaseService: supabaseService,
      vaultRepository: vaultRepository,
      stagingRepository: stagingRepository,
      ocrService: ocrService,
      duplicateDetectorService: duplicateDetectorService,
      remoteUpdateService: remoteUpdateService,
      clerkViewModel: clerkViewModel,
    ),
  );
}

class TownTreasureClerkApp extends StatelessWidget {
  const TownTreasureClerkApp({
    super.key,
    required this.localStorageService,
    required this.supabaseService,
    required this.vaultRepository,
    required this.stagingRepository,
    required this.ocrService,
    required this.duplicateDetectorService,
    required this.remoteUpdateService,
    required this.clerkViewModel,
  });

  final LocalStorageService localStorageService;
  final SupabaseGateway supabaseService;
  final VaultRepository vaultRepository;
  final StagingRepository stagingRepository;
  final OcrConsensusService ocrService;
  final DuplicateDetectorService duplicateDetectorService;
  final RemoteUpdateService remoteUpdateService;
  final ClerkViewModel clerkViewModel;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LocalStorageService>.value(value: localStorageService),
        Provider<SupabaseGateway>.value(value: supabaseService),
        Provider<OcrConsensusService>.value(value: ocrService),
        Provider<DuplicateDetectorService>.value(value: duplicateDetectorService),
        Provider<RemoteUpdateService>.value(value: remoteUpdateService),
        ChangeNotifierProvider<VaultRepository>.value(value: vaultRepository),
        ChangeNotifierProvider<StagingRepository>.value(
          value: stagingRepository,
        ),
        ChangeNotifierProvider<ClerkViewModel>.value(value: clerkViewModel),
      ],
      child: MaterialApp(
        title: 'Town Treasure Clerk',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: ClerkPortalScreen(
          viewModel: clerkViewModel,
          allowOwnerQuickPair: false,
          standaloneClerkApp: true,
          updateService: remoteUpdateService,
          updateManifestUrl: RemoteUpdateService.defaultClerkManifestUrl,
        ),
      ),
    );
  }
}
