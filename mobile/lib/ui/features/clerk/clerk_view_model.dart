import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/staging_repository.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/services/duplicate_detector_service.dart';
import '../../../data/services/local_storage_service.dart';
import '../../../data/services/ocr_consensus_service.dart';
import '../../../data/services/remote_update_service.dart';
import '../../../data/services/supabase_service.dart';
import '../../../domain/models/models.dart';

enum ClerkInboxTab { pending, approved, rejected }

enum ReviewAuditState { idle, checking, clear, duplicate, error }

class ClerkInviteLink {
  const ClerkInviteLink({
    required this.token,
    required this.url,
    required this.ownerName,
    this.ownerEmail,
    this.expiresAt,
  });

  final String token;
  final String url;
  final String ownerName;
  final String? ownerEmail;
  final String? expiresAt;
}

sealed class ApprovalOutcome {
  const ApprovalOutcome();
}

class ApprovalSuccess extends ApprovalOutcome {
  const ApprovalSuccess(this.invoice);
  final Invoice invoice;
}

class ApprovalNeedsAliasMatch extends ApprovalOutcome {
  const ApprovalNeedsAliasMatch({
    required this.candidate,
    required this.score,
    required this.rawName,
    required this.isSuggested,
  });

  final Restaurant candidate;
  final double score;
  final String rawName;
  final bool isSuggested;
}

class ApprovalNeedsCreateRestaurant extends ApprovalOutcome {
  const ApprovalNeedsCreateRestaurant({
    required this.rawName,
    required this.similarCandidates,
  });

  final String rawName;
  final List<Restaurant> similarCandidates;
}

class ApprovalBlocked extends ApprovalOutcome {
  const ApprovalBlocked(this.message);
  final String message;
}

class ClerkSubmitResult {
  const ClerkSubmitResult._({
    this.savedDocket,
    this.duplicateAudit,
    this.candidateDocket,
    this.error,
  });

  factory ClerkSubmitResult.submitted(StagingDocket docket) =>
      ClerkSubmitResult._(savedDocket: docket);

  factory ClerkSubmitResult.duplicateDetected(
    StagingDocket candidate,
    AuditResult audit,
  ) =>
      ClerkSubmitResult._(
        candidateDocket: candidate,
        duplicateAudit: audit,
      );

  factory ClerkSubmitResult.failure(String message) =>
      ClerkSubmitResult._(error: message);

  final StagingDocket? savedDocket;
  final AuditResult? duplicateAudit;
  final StagingDocket? candidateDocket;
  final String? error;

  bool get isSuccess => savedDocket != null;
  bool get isDuplicate => duplicateAudit != null;
}

/// ViewModel coordinating Owner Clerk Submissions inbox, Ledger Integrity Review,
/// and Native Clerk Intake Mode (invite-token paired).
class ClerkViewModel extends ChangeNotifier {
  ClerkViewModel({
    required StagingRepository stagingRepository,
    required VaultRepository vaultRepository,
    required this._supabase,
    required LocalStorageService localStorage,
    required OcrConsensusService ocrService,
    required DuplicateDetectorService duplicateDetector,
    this._updateService,
    this._updateManifestUrl = RemoteUpdateService.defaultClerkManifestUrl,
    DateTime Function()? clock,
  })  : _staging = stagingRepository,
        _vault = vaultRepository,
        _storage = localStorage,
        _ocr = ocrService,
        _audit = duplicateDetector,
        _clock = clock ?? DateTime.now;

  static const String keyClerkInviteToken = 'ttg_clerk_invite_token';
  static const String keyClerkInviteMeta = 'ttg_clerk_invite_meta';
  static const String keyClerkName = 'ttg_clerk_name';
  static const String keyClerkSubmissionKey = 'ttg_clerk_submission_key';
  static const String keyLastClerkUpdateCheckAt =
      'ttg_clerk_last_update_check_at';
  static const Duration silentUpdateCheckInterval = Duration(hours: 6);
  static const String defaultClerkWebBaseUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk.html';

  final StagingRepository _staging;
  final VaultRepository _vault;
  final SupabaseGateway _supabase;
  final LocalStorageService _storage;
  final OcrConsensusService _ocr;
  final DuplicateDetectorService _audit;
  final RemoteUpdateService? _updateService;
  final String _updateManifestUrl;
  final DateTime Function() _clock;

  OcrConsensusService get ocrService => _ocr;
  DuplicateDetectorService get duplicateDetector => _audit;
  List<Restaurant> get vaultRestaurants => _vault.restaurants;
  RemoteUpdateService? get updateService => _updateService;
  String get updateManifestUrl => _updateManifestUrl;

  // --- Owner Inbox State ---
  List<StagingDocket> _submissions = [];
  ClerkInboxTab _activeTab = ClerkInboxTab.pending;
  bool _isLoadingInbox = false;
  String? _inboxError;

  List<StagingDocket> get submissions => List.unmodifiable(_submissions);
  ClerkInboxTab get activeTab => _activeTab;
  bool get isLoadingInbox => _isLoadingInbox;
  String? get inboxError => _inboxError;

  int get pendingCount => _submissions.where((d) => d.isPending).length;
  int get approvedCount => _submissions.where((d) => d.isApproved).length;
  int get rejectedCount => _submissions.where((d) => d.isRejected).length;

  List<StagingDocket> get filteredSubmissions {
    return _submissions.where((d) {
      switch (_activeTab) {
        case ClerkInboxTab.pending:
          return d.isPending;
        case ClerkInboxTab.approved:
          return d.isApproved;
        case ClerkInboxTab.rejected:
          return d.isRejected;
      }
    }).toList();
  }

  // --- Active Review State ---
  StagingDocket? _activeReviewDocket;
  ReviewAuditState _reviewAuditState = ReviewAuditState.idle;
  AuditResult? _reviewAuditResult;
  int _reviewAuditRecordCount = 0;
  bool _reviewRestaurantVerified = false;
  String? _reviewAuditError;
  bool _supplementaryConfirmed = false;
  bool _isProcessingReview = false;

  StagingDocket? get activeReviewDocket => _activeReviewDocket;
  ReviewAuditState get reviewAuditState => _reviewAuditState;
  AuditResult? get reviewAuditResult => _reviewAuditResult;
  int get reviewAuditRecordCount => _reviewAuditRecordCount;
  bool get reviewRestaurantVerified => _reviewRestaurantVerified;
  String? get reviewAuditError => _reviewAuditError;
  bool get supplementaryConfirmed => _supplementaryConfirmed;
  bool get isProcessingReview => _isProcessingReview;

  bool get canApproveActiveReview {
    if (_activeReviewDocket == null || !_activeReviewDocket!.isPending) {
      return false;
    }
    if (_isProcessingReview) return false;
    if (_reviewAuditState == ReviewAuditState.clear) return true;
    if (_reviewAuditState == ReviewAuditState.duplicate &&
        _supplementaryConfirmed) {
      return true;
    }
    return false;
  }

  // --- Clerk Intake Mode State ---
  String _clerkInviteToken = '';
  String _savedClerkName = '';
  String _inviteOwnerName = 'account owner';
  String _inviteOwnerEmail = '';
  DateTime? _inviteExpiresAt;
  DateTime? _inviteIdleExpiresAt;
  DateTime? _inviteEffectiveExpiresAt;
  bool _inviteVerified = false;
  String? _inviteTokenError;
  List<StagingDocket> _clerkHistory = [];
  bool _isLoadingClerkHistory = false;
  String? _clerkHistoryError;
  AuditResult? _liveDuplicateWarning;
  UpdateCheckResult? _availableUpdate;

  String get clerkInviteToken => _clerkInviteToken;
  UpdateCheckResult? get availableUpdate => _availableUpdate;
  bool get hasUpdateAvailable => _availableUpdate?.updateAvailable == true;

  /// Silently checks `clerk-update.json` for a newer standalone Clerk APK without interrupting offline work.
  Future<void> runSilentUpdateCheck({bool force = false}) async {
    final updater = _updateService;
    if (updater == null) return;
    if (_updateManifestUrl.trim().isEmpty) return;

    final now = _clock();
    if (!force) {
      final rawLast = await _storage.getRaw(keyLastClerkUpdateCheckAt);
      final lastAt = DateTime.tryParse(rawLast ?? '');
      if (lastAt != null) {
        final elapsed = now.difference(lastAt);
        if (!elapsed.isNegative && elapsed < silentUpdateCheckInterval) {
          return;
        }
      }
    }

    try {
      final result = await updater
          .checkForUpdate(_updateManifestUrl)
          .timeout(const Duration(seconds: 6));
      await _storage.setRaw(
        keyLastClerkUpdateCheckAt,
        now.toUtc().toIso8601String(),
      );
      _availableUpdate = result;
      notifyListeners();
    } catch (_) {
      // Offline / DNS failures stay silent on startup checks.
    }
  }
  bool get hasClerkInvite => _clerkInviteToken.isNotEmpty;
  String get savedClerkName => _savedClerkName;
  String get inviteOwnerName => _inviteOwnerName;
  String get inviteOwnerEmail => _inviteOwnerEmail;
  DateTime? get inviteExpiresAt => _inviteExpiresAt;
  DateTime? get inviteIdleExpiresAt => _inviteIdleExpiresAt;
  DateTime? get inviteEffectiveExpiresAt => _inviteEffectiveExpiresAt;
  bool get isInviteVerified => _inviteVerified;
  bool get isInviteExpired =>
      _inviteEffectiveExpiresAt != null &&
      !_inviteEffectiveExpiresAt!.isAfter(DateTime.now());
  String? get inviteTokenError => _inviteTokenError;
  bool get canSubmitWithToken =>
      hasClerkInvite && _inviteVerified && !isInviteExpired;
  List<StagingDocket> get clerkHistory => List.unmodifiable(_clerkHistory);
  List<StagingDocket> get clerkReturnedDockets =>
      _clerkHistory.where((d) => d.isRejected).toList();
  bool get isLoadingClerkHistory => _isLoadingClerkHistory;
  String? get clerkHistoryError => _clerkHistoryError;
  AuditResult? get liveDuplicateWarning => _liveDuplicateWarning;

  void setActiveTab(ClerkInboxTab tab) {
    _activeTab = tab;
    notifyListeners();
  }

  Future<void> loadSubmissions() async {
    _isLoadingInbox = true;
    _inboxError = null;
    notifyListeners();
    try {
      _submissions = await _staging.getAllSubmissions();
    } catch (e) {
      _inboxError = e.toString();
    } finally {
      _isLoadingInbox = false;
      notifyListeners();
    }
  }

  /// Generates a fresh 30-day clerk invite link via `clerk-api` (revoking older links).
  Future<ClerkInviteLink> createClerkInviteLink({
    String webBaseUrl = defaultClerkWebBaseUrl,
  }) async {
    final result = await _supabase.invokeClerkApi({'action': 'create_invite'});
    final token = (result['token'] ?? '').toString().trim();
    if (token.isEmpty) {
      throw StateError('The server did not return a clerk invite token.');
    }
    final invite = result['invite'] is Map
        ? Map<String, dynamic>.from(result['invite'] as Map)
        : const <String, dynamic>{};
    final user = await _supabase.getCurrentUser();
    final ownerEmail =
        (invite['owner_email'] ?? user?.email ?? '').toString().trim();
    final ownerName = (invite['owner_name'] ??
            (ownerEmail.isNotEmpty ? ownerEmail.split('@').first : 'account owner'))
        .toString()
        .trim();
    final url = '$webBaseUrl#invite=${Uri.encodeComponent(token)}';
    return ClerkInviteLink(
      token: token,
      url: url,
      ownerName: ownerName,
      ownerEmail: ownerEmail.isEmpty ? null : ownerEmail,
      expiresAt: invite['expires_at']?.toString(),
    );
  }

  /// Imports a portable docket code or JSON into the staging queue (deduplicated by ID).
  Future<StagingDocket> importDocketFromCode(String rawCode) async {
    final parsed = StagingRepository.parseDocketCode(rawCode);
    if (parsed.id.isNotEmpty) {
      final existing = await _staging.getAllSubmissions(filterForCurrentUser: false);
      final found = existing.where((d) => d.id == parsed.id).toList();
      if (found.isNotEmpty) {
        await loadSubmissions();
        return found.first;
      }
    }
    final saved = await _staging.submitDocket(parsed);
    await loadSubmissions();
    return saved;
  }

  String exportDocketCode(StagingDocket docket) =>
      StagingRepository.exportDocketAsCode(docket);

  /// Opens a docket for review, hydrates photos, and runs the Ledger Integrity Guard check.
  Future<void> openReview(StagingDocket summary) async {
    _activeReviewDocket = summary;
    _reviewAuditState = ReviewAuditState.checking;
    _reviewAuditResult = null;
    _reviewAuditRecordCount = 0;
    _reviewRestaurantVerified = false;
    _reviewAuditError = null;
    _supplementaryConfirmed = false;
    notifyListeners();

    StagingDocket fullDocket = summary;
    try {
      final fetched = await _staging.getSubmission(summary.id);
      if (fetched != null) {
        fullDocket = fetched;
      }
    } catch (_) {
      // Keep summary docket if full fetch fails; remote sync check below governs approval.
    }

    if (_activeReviewDocket?.id != summary.id) return;
    _activeReviewDocket = fullDocket;
    notifyListeners();

    await _runReviewIntegrityAudit(fullDocket);
  }

  Future<void> _runReviewIntegrityAudit(StagingDocket item) async {
    final id = item.id;
    try {
      final allStaged =
          await _staging.getAllSubmissions(filterForCurrentUser: false);
      if (!await _vault.syncNow()) {
        throw StateError(
          'Could not sync the current account ledger before duplicate review.',
        );
      }
      final remoteSnapshot = await _vault.getRemoteInvoiceSnapshot();
      if (!remoteSnapshot.ok) {
        throw StateError(
          'Could not read the current account ledger from the server.',
        );
      }

      if (_activeReviewDocket?.id != id) return;

      final restaurantName = item.restaurantName;
      final restaurantKey =
          Restaurant.normalizeRestaurantName(restaurantName);
      final restaurantMatch =
          Restaurant.resolveName(restaurantName, _vault.restaurants);

      bool sameRestaurant(String otherName) {
        if (restaurantMatch.status == RestaurantResolutionStatus.matched) {
          final otherMatch =
              Restaurant.resolveName(otherName, _vault.restaurants);
          return otherMatch.status == RestaurantResolutionStatus.matched &&
              otherMatch.restaurant?.id == restaurantMatch.restaurant?.id;
        }
        return restaurantMatch.status != RestaurantResolutionStatus.ambiguous &&
            restaurantKey.isNotEmpty &&
            Restaurant.normalizeRestaurantName(otherName) == restaurantKey;
      }

      final otherPending = allStaged
          .where(
            (record) =>
                record.id != id &&
                record.isPending &&
                sameRestaurant(record.restaurantName),
          )
          .map(AuditRecord.fromDocket)
          .toList();

      final ledgerInvoices = remoteSnapshot.invoices
          .where((invoice) {
            if (invoice.isDraft) return false;
            if (restaurantMatch.status == RestaurantResolutionStatus.matched &&
                restaurantMatch.restaurant != null) {
              return Restaurant.invoiceBelongsToRestaurant(
                invoice,
                restaurantMatch.restaurant!,
                _vault.restaurants,
              );
            }
            return restaurantMatch.status !=
                    RestaurantResolutionStatus.ambiguous &&
                restaurantKey.isNotEmpty &&
                Restaurant.normalizeRestaurantName(invoice.restaurantName) ==
                    restaurantKey;
          })
          .map(AuditRecord.fromInvoice)
          .toList();

      final auditPool = [...ledgerInvoices, ...otherPending];
      final audit = await _audit.auditSubmission(
        AuditRecord.fromDocket(item),
        auditPool,
      );

      if (_activeReviewDocket?.id != id) return;

      _reviewAuditResult = audit;
      _reviewAuditRecordCount = auditPool.length;
      _reviewRestaurantVerified =
          restaurantMatch.status == RestaurantResolutionStatus.matched;
      _reviewAuditState =
          (audit.isDuplicate || audit.determination == 'EXACT_DUPLICATE')
              ? ReviewAuditState.duplicate
              : ReviewAuditState.clear;
      _reviewAuditError = null;
      notifyListeners();
    } catch (e) {
      if (_activeReviewDocket?.id != id) return;
      _reviewAuditState = ReviewAuditState.error;
      _reviewAuditError = e.toString();
      notifyListeners();
    }
  }

  void setSupplementaryConfirmed(bool confirmed) {
    _supplementaryConfirmed = confirmed;
    notifyListeners();
  }

  /// Validates audit guard and restaurant identity, then approves into encrypted vault.
  Future<ApprovalOutcome> approveActiveReview({
    required String restaurantName,
    required String invoiceDate,
    required List<InvoiceLineItem> items,
    required double deliveryCost,
    required double otherCost,
  }) async {
    final docket = _activeReviewDocket;
    if (docket == null) {
      return const ApprovalBlocked('No active docket selected.');
    }
    if (_reviewAuditState != ReviewAuditState.clear &&
        _reviewAuditState != ReviewAuditState.duplicate) {
      return const ApprovalBlocked(
        'Wait for the duplicate check to finish before approving this docket.',
      );
    }
    if (_reviewAuditState == ReviewAuditState.duplicate &&
        !_supplementaryConfirmed) {
      return const ApprovalBlocked(
        'Confirm this intentional repeat dispatch before approving.',
      );
    }

    final trimmedRest = restaurantName.trim();
    if (trimmedRest.isEmpty) {
      return const ApprovalBlocked('Restaurant name is required.');
    }

    final validItems = items
        .where((it) => it.desc.trim().isNotEmpty)
        .map(
          (it) => it.copyWith(
            desc: it.desc.trim(),
            qty: it.qty <= 0 ? 1 : it.qty,
          ),
        )
        .toList();
    if (validItems.isEmpty) {
      return const ApprovalBlocked(
        'Please fill in descriptions for at least one line item.',
      );
    }

    final resolution =
        Restaurant.resolveName(trimmedRest, _vault.restaurants);
    switch (resolution.status) {
      case RestaurantResolutionStatus.empty:
        return const ApprovalBlocked(
          'Enter a specific restaurant name; generic words alone are not enough.',
        );
      case RestaurantResolutionStatus.ambiguous:
        final names =
            resolution.candidates.map((c) => c.restaurant.name).join(', ');
        return ApprovalBlocked(
          '"$trimmedRest" matches multiple restaurant records ($names). Merge duplicates or clarify the restaurant name before approving.',
        );
      case RestaurantResolutionStatus.suggested:
        final candidate = resolution.restaurant!;
        return ApprovalNeedsAliasMatch(
          candidate: candidate,
          score: resolution.score,
          rawName: trimmedRest,
          isSuggested: true,
        );
      case RestaurantResolutionStatus.possible:
        if (resolution.candidates.length == 1) {
          return ApprovalNeedsAliasMatch(
            candidate: resolution.candidates.first.restaurant,
            score: resolution.score,
            rawName: trimmedRest,
            isSuggested: false,
          );
        }
        return ApprovalNeedsCreateRestaurant(
          rawName: trimmedRest,
          similarCandidates:
              resolution.candidates.map((c) => c.restaurant).toList(),
        );
      case RestaurantResolutionStatus.unmatched:
        return ApprovalNeedsCreateRestaurant(
          rawName: trimmedRest,
          similarCandidates:
              resolution.candidates.map((c) => c.restaurant).toList(),
        );
      case RestaurantResolutionStatus.matched:
        final canonicalName = resolution.restaurant!.name;
        _isProcessingReview = true;
        notifyListeners();
        try {
          final invoice = await _staging.approveSubmission(
            docket.id,
            restaurantName: canonicalName,
            date: invoiceDate,
            items: validItems,
            deliveryCost: deliveryCost,
            otherCost: otherCost,
          );
          await loadSubmissions();
          return ApprovalSuccess(invoice);
        } catch (e) {
          return ApprovalBlocked(e.toString());
        } finally {
          _isProcessingReview = false;
          notifyListeners();
        }
    }
  }

  /// Registers `aliasName` on `targetRestaurant` (checking for conflicts) and approves.
  Future<ApprovalOutcome> registerAliasAndApprove({
    required Restaurant targetRestaurant,
    required String aliasName,
    required String invoiceDate,
    required List<InvoiceLineItem> items,
    required double deliveryCost,
    required double otherCost,
  }) async {
    final key = Restaurant.normalizeRestaurantName(aliasName);
    if (key.isEmpty) {
      return const ApprovalBlocked('Alias cannot be empty.');
    }
    final conflicts = _vault.restaurants.where((r) {
      if (r.id == targetRestaurant.id) return false;
      return Restaurant.nameVariants(r)
          .any((v) => Restaurant.normalizeRestaurantName(v) == key);
    }).toList();

    if (conflicts.isNotEmpty) {
      final names = conflicts.map((r) => r.name).join(', ');
      return ApprovalBlocked(
        'That spelling is already assigned to $names. Merge duplicate records first.',
      );
    }

    final updatedAliases = List<String>.from(targetRestaurant.aliases);
    if (!updatedAliases.any(
      (a) => Restaurant.normalizeRestaurantName(a) == key,
    )) {
      updatedAliases.add(aliasName.trim());
    }
    final updatedRestaurant = targetRestaurant.copyWith(
      aliases: updatedAliases,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final nextList = _vault.restaurants
        .map((r) => r.id == targetRestaurant.id ? updatedRestaurant : r)
        .toList();
    await _vault.setRestaurants(nextList);

    return approveActiveReview(
      restaurantName: targetRestaurant.name,
      invoiceDate: invoiceDate,
      items: items,
      deliveryCost: deliveryCost,
      otherCost: otherCost,
    );
  }

  /// Creates a new restaurant record from an unmatched clerk docket and approves.
  Future<ApprovalOutcome> createRestaurantAndApprove({
    required String restaurantName,
    required String invoiceDate,
    required List<InvoiceLineItem> items,
    required double deliveryCost,
    required double otherCost,
  }) async {
    final latest = Restaurant.resolveName(restaurantName, _vault.restaurants);
    if (latest.status == RestaurantResolutionStatus.matched &&
        latest.restaurant != null) {
      return approveActiveReview(
        restaurantName: latest.restaurant!.name,
        invoiceDate: invoiceDate,
        items: items,
        deliveryCost: deliveryCost,
        otherCost: otherCost,
      );
    }
    if (latest.status == RestaurantResolutionStatus.ambiguous) {
      return const ApprovalBlocked(
        'The restaurant list is ambiguous. Merge duplicate records before approving.',
      );
    }
    if (latest.status == RestaurantResolutionStatus.empty) {
      return const ApprovalBlocked(
        'Enter a specific restaurant name before creating a new record.',
      );
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final newRestaurant = Restaurant(
      id: AppHelpers.genId(),
      name: restaurantName.trim(),
      aliases: const [],
      contact: '',
      createdAt: now,
      updatedAt: now,
    );
    await _vault.setRestaurants([..._vault.restaurants, newRestaurant]);

    return approveActiveReview(
      restaurantName: newRestaurant.name,
      invoiceDate: invoiceDate,
      items: items,
      deliveryCost: deliveryCost,
      otherCost: otherCost,
    );
  }

  Future<void> rejectReview(String id, String reason) async {
    _isProcessingReview = true;
    notifyListeners();
    try {
      await _staging.rejectSubmission(id, reason);
      await loadSubmissions();
    } finally {
      _isProcessingReview = false;
      notifyListeners();
    }
  }

  Future<void> deleteSubmission(String id) async {
    _isProcessingReview = true;
    notifyListeners();
    try {
      await _staging.deleteSubmission(id);
      await loadSubmissions();
    } finally {
      _isProcessingReview = false;
      notifyListeners();
    }
  }

  // --- Native Clerk Intake Mode Methods ---

  /// Extracts a raw invite token from either a full `#invite=...` URL or a plain token string.
  static String parseInviteTokenInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && (uri.hasScheme || trimmed.contains('invite='))) {
      if (uri.fragment.isNotEmpty) {
        final fragParams = Uri.splitQueryString(uri.fragment);
        final tok = fragParams['invite'];
        if (tok != null && tok.trim().isNotEmpty) return tok.trim();
      }
      final qTok = uri.queryParameters['invite'];
      if (qTok != null && qTok.trim().isNotEmpty) return qTok.trim();
    }
    return trimmed;
  }

  static String clerkDuplicateRestaurantKey(String? value) {
    if (value == null || value.isEmpty) return '';
    return value
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(
          RegExp(r'\b(the|hotel|hotels|restaurant|restaurants|limited|ltd)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  Future<void> loadClerkSession({String? initialInviteToken}) async {
    _savedClerkName = (await _storage.getRaw(keyClerkName)) ?? '';
    if (initialInviteToken != null && initialInviteToken.trim().isNotEmpty) {
      _clerkInviteToken = parseInviteTokenInput(initialInviteToken);
      await _storage.setRaw(keyClerkInviteToken, _clerkInviteToken);
      _inviteVerified = false;
      _inviteExpiresAt = null;
      _inviteIdleExpiresAt = null;
      _inviteEffectiveExpiresAt = null;
    } else {
      _clerkInviteToken = (await _storage.getRaw(keyClerkInviteToken)) ?? '';
      await _loadCachedInviteMeta();
    }
    notifyListeners();
    if (_clerkInviteToken.isNotEmpty) {
      await loadClerkHistory();
    }
  }

  Future<void> _loadCachedInviteMeta() async {
    final meta = await _storage.getJsonMap(keyClerkInviteMeta);
    if (meta.isEmpty) return;
    _inviteOwnerName =
        (meta['owner_name'] ?? _inviteOwnerName).toString().trim();
    _inviteOwnerEmail =
        (meta['owner_email'] ?? _inviteOwnerEmail).toString().trim();
    _inviteExpiresAt = DateTime.tryParse(meta['expires_at']?.toString() ?? '');
    _inviteIdleExpiresAt = DateTime.tryParse(
      meta['idle_expires_at']?.toString() ?? '',
    );
    _inviteEffectiveExpiresAt = DateTime.tryParse(
      meta['effective_expires_at']?.toString() ?? '',
    );
    _inviteVerified = meta['verified'] == true && !isInviteExpired;
    if (isInviteExpired) {
      _inviteTokenError =
          'This clerk token expired (30-day max or 7 days idle). Request a new token link from the owner.';
    }
  }

  Future<void> _saveInviteMeta() async {
    await _storage.setJson(keyClerkInviteMeta, {
      'owner_name': _inviteOwnerName,
      'owner_email': _inviteOwnerEmail,
      'expires_at': _inviteExpiresAt?.toIso8601String(),
      'idle_expires_at': _inviteIdleExpiresAt?.toIso8601String(),
      'effective_expires_at': _inviteEffectiveExpiresAt?.toIso8601String(),
      'verified': _inviteVerified,
    });
  }

  static bool _isTokenAuthError(Object err) {
    final lower = err.toString().toLowerCase();
    return lower.contains('invalid') ||
        lower.contains('expired') ||
        lower.contains('revoked') ||
        lower.contains('inactivity') ||
        lower.contains('401') ||
        lower.contains('ask the account owner for a new link');
  }

  Future<void> pairWithInviteToken(String rawInput) async {
    final token = parseInviteTokenInput(rawInput);
    if (token.isEmpty) {
      throw ArgumentError('Please enter a valid clerk invite link or token.');
    }
    _clerkInviteToken = token;
    _inviteVerified = false;
    _inviteTokenError = null;
    _inviteExpiresAt = null;
    _inviteIdleExpiresAt = null;
    _inviteEffectiveExpiresAt = null;
    await _storage.setRaw(keyClerkInviteToken, token);
    notifyListeners();
    try {
      await loadClerkHistory(rethrowAuthErrors: true);
    } catch (e) {
      _clerkInviteToken = '';
      _inviteVerified = false;
      _inviteTokenError = e.toString();
      await _storage.deleteKey(keyClerkInviteToken);
      await _storage.deleteKey(keyClerkInviteMeta);
      notifyListeners();
      rethrow;
    }
  }

  /// Allows an authenticated owner inside the APK to generate and immediately
  /// pair a fresh invite token for in-app Clerk Intake Mode.
  Future<ClerkInviteLink> pairWithOwnOwnerInvite() async {
    final link = await createClerkInviteLink();
    await pairWithInviteToken(link.token);
    return link;
  }

  Future<void> unpairClerkToken() async {
    _clerkInviteToken = '';
    _clerkHistory = [];
    _clerkHistoryError = null;
    _inviteOwnerName = 'account owner';
    _inviteOwnerEmail = '';
    _inviteExpiresAt = null;
    _inviteIdleExpiresAt = null;
    _inviteEffectiveExpiresAt = null;
    _inviteVerified = false;
    _inviteTokenError = null;
    _liveDuplicateWarning = null;
    await _storage.deleteKey(keyClerkInviteToken);
    await _storage.deleteKey(keyClerkInviteMeta);
    notifyListeners();
  }

  Future<void> loadClerkHistory({bool rethrowAuthErrors = false}) async {
    if (_clerkInviteToken.isEmpty) return;
    _isLoadingClerkHistory = true;
    _clerkHistoryError = null;
    notifyListeners();
    try {
      final result = await _supabase.invokeClerkApi({
        'action': 'list',
        'invite_token': _clerkInviteToken,
        'include_photos': false,
      });
      final owner = result['owner'] is Map
          ? Map<String, dynamic>.from(result['owner'] as Map)
          : const <String, dynamic>{};
      final ownerName = (owner['name'] ?? '').toString().trim();
      if (ownerName.isNotEmpty) _inviteOwnerName = ownerName;
      _inviteOwnerEmail = (owner['email'] ?? '').toString().trim();

      final invite = result['invite'] is Map
          ? Map<String, dynamic>.from(result['invite'] as Map)
          : null;
      if (invite != null) {
        _inviteExpiresAt = DateTime.tryParse(
          invite['expires_at']?.toString() ?? '',
        );
        _inviteIdleExpiresAt = DateTime.tryParse(
          invite['idle_expires_at']?.toString() ?? '',
        );
        _inviteEffectiveExpiresAt = DateTime.tryParse(
          invite['effective_expires_at']?.toString() ?? '',
        ) ??
            _inviteIdleExpiresAt ??
            _inviteExpiresAt;
      }

      if (isInviteExpired) {
        _inviteVerified = false;
        _inviteTokenError =
            'This clerk token expired (30-day max or 7 days idle). Request a new link from the owner.';
        await _saveInviteMeta();
        if (rethrowAuthErrors) {
          throw StateError(_inviteTokenError!);
        }
        return;
      }

      _inviteVerified = true;
      _inviteTokenError = null;
      await _saveInviteMeta();

      final rawList = result['submissions'];
      _clerkHistory = rawList is List
          ? rawList
              .whereType<Map>()
              .map((m) => StagingDocket.fromJson(Map<String, dynamic>.from(m)))
              .where((d) => d.id.isNotEmpty && !d.id.startsWith('stg_demo_'))
              .toList()
          : <StagingDocket>[];
    } catch (e) {
      if (_isTokenAuthError(e)) {
        _inviteVerified = false;
        _inviteTokenError = e.toString();
        await _storage.deleteKey(keyClerkInviteMeta);
        if (rethrowAuthErrors) {
          rethrow;
        }
      }
      _clerkHistoryError = e.toString();
    } finally {
      _isLoadingClerkHistory = false;
      notifyListeners();
    }
  }

  Future<StagingDocket?> fetchClerkDocketWithPhotos(String id) async {
    if (_clerkInviteToken.isEmpty) {
      throw StateError('Valid clerk invite link is required.');
    }
    final result = await _supabase.invokeClerkApi({
      'action': 'list',
      'invite_token': _clerkInviteToken,
      'submission_id': id,
      'include_photos': true,
    });
    final rawList = result['submissions'];
    if (rawList is! List) return null;
    for (final row in rawList.whereType<Map>()) {
      final docket = StagingDocket.fromJson(Map<String, dynamic>.from(row));
      if (docket.id == id) return docket;
    }
    return null;
  }

  Future<void> runLiveClerkDuplicateCheck({
    required String restaurantName,
    required String invoiceDate,
    required List<InvoiceLineItem> items,
  }) async {
    final rest = restaurantName.trim();
    final date = invoiceDate.trim();
    if (rest.isEmpty || date.isEmpty || _clerkHistory.isEmpty) {
      if (_liveDuplicateWarning != null) {
        _liveDuplicateWarning = null;
        notifyListeners();
      }
      return;
    }

    final key = clerkDuplicateRestaurantKey(rest);
    final pool = _clerkHistory
        .where(
          (r) =>
              !r.isRejected &&
              clerkDuplicateRestaurantKey(r.restaurantName) == key,
        )
        .map(AuditRecord.fromDocket)
        .toList();

    if (pool.isEmpty) {
      if (_liveDuplicateWarning != null) {
        _liveDuplicateWarning = null;
        notifyListeners();
      }
      return;
    }

    final total = items.fold<double>(0, (s, i) => s + i.total);
    final cand = AuditRecord(
      id: '',
      restaurantName: rest,
      date: date,
      items: items,
      totalSell: total,
    );
    final audit = await _audit.auditSubmission(cand, pool, useDeepAudit: false);
    _liveDuplicateWarning = audit.isDuplicate ? audit : null;
    notifyListeners();
  }

  Future<String> _getOrCreateSubmissionKey() async {
    final existing = await _storage.getRaw(keyClerkSubmissionKey);
    if (existing != null && RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(existing)) {
      return existing;
    }
    final generated = _generateSubmissionKey();
    await _storage.setRaw(keyClerkSubmissionKey, generated);
    return generated;
  }

  Future<void> resetClerkSubmissionKey() =>
      _storage.deleteKey(keyClerkSubmissionKey);

  static String _generateSubmissionKey() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final rng = Random.secure();
    final buf = StringBuffer('sub_');
    for (var i = 0; i < 28; i++) {
      buf.write(chars[rng.nextInt(chars.length)]);
    }
    return buf.toString();
  }

  Future<ClerkSubmitResult> submitClerkDocket({
    String? editingDocketId,
    required String clerkName,
    required String restaurantName,
    required String invoiceDate,
    required List<InvoiceLineItem> items,
    required double deliveryCost,
    required double otherCost,
    required String notes,
    required List<String> receiptPhotos,
    bool bypassDuplicateCheck = false,
  }) async {
    if (!canSubmitWithToken) {
      return ClerkSubmitResult.failure(
        _inviteTokenError ??
            'A verified, active clerk invite token (valid 30 days max / 7 days idle) is required before sending.',
      );
    }
    final cleanClerk = clerkName.trim();
    if (cleanClerk.isEmpty) {
      return ClerkSubmitResult.failure('Please enter your name.');
    }
    final cleanRest = restaurantName.trim();
    if (cleanRest.isEmpty) {
      return ClerkSubmitResult.failure('Please select or enter a restaurant client.');
    }
    final normDate = AppHelpers.normalizeAppDate(invoiceDate);
    if (normDate.isEmpty) {
      return ClerkSubmitResult.failure('Please select a valid docket date.');
    }
    final validItems = items
        .where((it) => it.desc.trim().isNotEmpty && it.qty > 0)
        .map(
          (it) => it.copyWith(
            desc: it.desc.trim(),
            buyPrice: 0,
            total: it.qty * it.sellPrice,
          ),
        )
        .toList();
    if (validItems.isEmpty) {
      return ClerkSubmitResult.failure(
        'Please enter descriptions and quantities for at least one produce item.',
      );
    }

    _savedClerkName = cleanClerk;
    await _storage.setRaw(keyClerkName, cleanClerk);

    final subtotal = validItems.fold<double>(0, (s, i) => s + i.total);
    final grandTotal = subtotal + deliveryCost + otherCost;
    final submissionKey = await _getOrCreateSubmissionKey();
    final isResubmit = editingDocketId != null && editingDocketId.isNotEmpty;

    final candidate = StagingDocket(
      id: editingDocketId ?? '',
      submissionKey: submissionKey,
      clerkName: cleanClerk,
      restaurantName: cleanRest,
      invoiceDate: normDate,
      itemsJson: validItems,
      deliveryCost: deliveryCost,
      otherCost: otherCost,
      totalSell: grandTotal,
      totalBuy: 0,
      receiptPhoto: receiptPhotos.isNotEmpty ? receiptPhotos.first : null,
      receiptPhotos: receiptPhotos,
      notes: notes.trim(),
    );

    if (!bypassDuplicateCheck && !isResubmit) {
      try {
        await loadClerkHistory();
        final restKey = clerkDuplicateRestaurantKey(cleanRest);
        final pool = _clerkHistory
            .where(
              (r) =>
                  !r.isRejected &&
                  clerkDuplicateRestaurantKey(r.restaurantName) == restKey,
            )
            .map(AuditRecord.fromDocket)
            .toList();
        final audit = await _audit.auditSubmission(
          AuditRecord.fromDocket(candidate),
          pool,
          excludeId: editingDocketId,
        );
        if (audit.isDuplicate ||
            audit.recommendedAction == 'BLOCK_SUBMISSION') {
          return ClerkSubmitResult.duplicateDetected(candidate, audit);
        }
      } catch (e) {
        return ClerkSubmitResult.failure(
          'Duplicate check could not finish: $e',
        );
      }
    }

    try {
      final apiDocket = candidate.toJson();
      if (!isResubmit) {
        apiDocket.remove('id');
      }
      final result = await _supabase.invokeClerkApi({
        'action': 'submit',
        'invite_token': _clerkInviteToken,
        'submission_key': submissionKey,
        'docket': apiDocket,
      });
      final subMap = result['submission'];
      if (subMap is! Map) {
        return ClerkSubmitResult.failure(
          'The server did not confirm the saved docket. Keep this form open and retry.',
        );
      }
      final saved = StagingDocket.fromJson(Map<String, dynamic>.from(subMap));
      await resetClerkSubmissionKey();
      await loadClerkHistory();
      return ClerkSubmitResult.submitted(saved);
    } catch (e) {
      return ClerkSubmitResult.failure('Error submitting docket: $e');
    }
  }

  Future<void> deleteClerkDocket(String id) async {
    if (_clerkInviteToken.isEmpty) {
      throw StateError('Valid clerk invite link is required.');
    }
    final result = await _supabase.invokeClerkApi({
      'action': 'delete',
      'invite_token': _clerkInviteToken,
      'id': id,
    });
    if (result['deleted'] != true) {
      throw StateError('The server did not confirm this docket deletion.');
    }
    await loadClerkHistory();
  }
}
