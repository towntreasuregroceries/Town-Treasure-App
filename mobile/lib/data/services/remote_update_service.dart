import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Parsed remote release manifest for self-hosted APK updates.
class AppUpdateManifest {
  const AppUpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.apkUrl,
    required this.sha256,
    this.releaseNotes = '',
    this.mandatory = false,
  });

  final String version;
  final int buildNumber;
  final String apkUrl;
  final String sha256;
  final String releaseNotes;
  final bool mandatory;

  factory AppUpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] ?? '').toString().trim();
    final buildRaw = json['buildNumber'] ?? json['versionCode'] ?? 0;
    final buildNumber = buildRaw is num
        ? buildRaw.toInt()
        : int.tryParse(buildRaw.toString()) ?? 0;
    final apkUrl = (json['apkUrl'] ?? '').toString().trim();
    final sha256 = (json['sha256'] ?? '').toString().trim().toLowerCase();

    if (version.isEmpty || buildNumber <= 0 || apkUrl.isEmpty || sha256.length != 64) {
      throw const ApkVerificationException(
        'Invalid update manifest: missing version, buildNumber, apkUrl, or valid SHA-256.',
      );
    }

    return AppUpdateManifest(
      version: version,
      buildNumber: buildNumber,
      apkUrl: apkUrl,
      sha256: sha256,
      releaseNotes: (json['releaseNotes'] ?? '').toString(),
      mandatory: json['mandatory'] == true,
    );
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.updateAvailable,
    required this.currentVersion,
    required this.currentBuildNumber,
    this.manifest,
  });

  final bool updateAvailable;
  final String currentVersion;
  final int currentBuildNumber;
  final AppUpdateManifest? manifest;
}

class ApkVerificationException implements Exception {
  const ApkVerificationException(this.message);
  final String message;

  @override
  String toString() => 'ApkVerificationException: $message';
}

typedef PackageVersionProvider = Future<({String version, int buildNumber})> Function();
typedef TempDirProvider = Future<Directory> Function();
typedef ApkFileOpener = Future<bool> Function(String filePath);

/// Checks a remote JSON manifest, validates HTTPS + trusted GitHub release host,
/// downloads the APK, verifies its SHA-256 digest, and hands off installation
/// to Android via `open_filex` + FileProvider.
class RemoteUpdateService {
  static const String defaultOwnerManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json';
  static const String defaultClerkManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk-update.json';

  static const Set<String> defaultAllowedApkHosts = {
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'towntreasuregroceries.github.io',
  };

  static const String _expectedGitHubRepoPrefix =
      '/towntreasuregroceries/town-treasure-app/';

  RemoteUpdateService({
    http.Client? httpClient,
    PackageVersionProvider? versionProvider,
    TempDirProvider? tempDirProvider,
    ApkFileOpener? apkOpener,
    Set<String>? allowedApkHosts,
  })  : _httpClient = httpClient ?? http.Client(),
        _versionProvider = versionProvider ?? _defaultVersionProvider,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory,
        _apkOpener = apkOpener ?? _defaultApkOpener,
        _allowedApkHosts = (allowedApkHosts ?? defaultAllowedApkHosts)
            .map((h) => h.trim().toLowerCase())
            .where((h) => h.isNotEmpty)
            .toSet();

  final http.Client _httpClient;
  final PackageVersionProvider _versionProvider;
  final TempDirProvider _tempDirProvider;
  final ApkFileOpener _apkOpener;
  final Set<String> _allowedApkHosts;

  static Future<({String version, int buildNumber})> _defaultVersionProvider() async {
    final info = await PackageInfo.fromPlatform();
    return (
      version: info.version,
      buildNumber: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  static Future<bool> _defaultApkOpener(String filePath) async {
    final result = await OpenFilex.open(
      filePath,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  }

  /// Validates that an OTA URL uses `https://` and points strictly to an
  /// allowlisted Town Treasure GitHub release host.
  static Uri validateTrustedHttpsUrl(
    String rawUrl, {
    Set<String> allowedHosts = defaultAllowedApkHosts,
    bool enforceRepoPathOnGitHub = true,
  }) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) {
      throw const ApkVerificationException(
        'Untrusted update URL: HTTPS is required.',
      );
    }
    final host = uri.host.toLowerCase();
    if (!allowedHosts.contains(host)) {
      throw ApkVerificationException(
        'Untrusted update host "$host": updates are restricted to official Town Treasure GitHub releases.',
      );
    }
    if (enforceRepoPathOnGitHub &&
        host == 'github.com' &&
        !uri.path.toLowerCase().startsWith(_expectedGitHubRepoPrefix)) {
      throw const ApkVerificationException(
        'Untrusted GitHub repository path in update URL.',
      );
    }
    return uri;
  }

  /// Purges stale temporary exported PDFs, rendered page JPEGs, and downloaded
  /// update APKs so sensitive exports do not linger indefinitely in cache.
  ///
  /// By default (`purgeAll == false`), only files older than [maxAge] (24 hours)
  /// are removed so active WhatsApp/print share intents are never interrupted.
  static Future<int> purgeStaleTempExports({
    Directory? directory,
    Duration maxAge = const Duration(hours: 24),
    bool purgeAll = false,
    DateTime? now,
  }) async {
    try {
      final dir = directory ?? await getTemporaryDirectory();
      if (!await dir.exists()) return 0;
      final refNow = now ?? DateTime.now();
      var deletedCount = 0;

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final lower = name.toLowerCase();
        final isSensitiveTemp = lower.endsWith('.pdf') ||
            (lower.startsWith('ttg_update_') && lower.endsWith('.apk')) ||
            (lower.startsWith('ttg_pdf_') && lower.endsWith('.jpg'));
        if (!isSensitiveTemp) continue;

        if (!purgeAll) {
          final stat = await entity.stat();
          if (refNow.difference(stat.modified) < maxAge) {
            continue;
          }
        }
        try {
          await entity.delete();
          deletedCount++;
        } catch (_) {}
      }
      return deletedCount;
    } catch (_) {
      return 0;
    }
  }

  /// Checks `manifestUrl` and compares `buildNumber` and semantic `version`.
  Future<UpdateCheckResult> checkForUpdate(String manifestUrl) async {
    final current = await _versionProvider();
    final uri = validateTrustedHttpsUrl(
      manifestUrl,
      allowedHosts: _allowedApkHosts,
      enforceRepoPathOnGitHub: false,
    );
    final response = await _httpClient.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApkVerificationException(
        'Manifest request failed with status ${response.statusCode}.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const ApkVerificationException('Manifest JSON must be an object.');
    }
    final manifest = AppUpdateManifest.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    validateTrustedHttpsUrl(
      manifest.apkUrl,
      allowedHosts: _allowedApkHosts,
    );

    final isNewer = manifest.buildNumber > current.buildNumber ||
        _compareSemver(manifest.version, current.version) > 0;

    return UpdateCheckResult(
      updateAvailable: isNewer,
      currentVersion: current.version,
      currentBuildNumber: current.buildNumber,
      manifest: manifest,
    );
  }

  /// Computes lowercase hex SHA-256 for any byte buffer.
  static String computeSha256Hex(List<int> bytes) {
    return crypto.sha256.convert(bytes).toString().toLowerCase();
  }

  /// Downloads the APK from `manifest.apkUrl`, verifies SHA-256 against
  /// `manifest.sha256`, deletes corrupt files, and returns the verified `File`.
  Future<File> downloadAndVerifyApk(
    AppUpdateManifest manifest, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final uri = validateTrustedHttpsUrl(
      manifest.apkUrl,
      allowedHosts: _allowedApkHosts,
    );
    final request = http.Request('GET', uri);
    final streamed = await _httpClient.send(request);
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw ApkVerificationException(
        'APK download failed with status ${streamed.statusCode}.',
      );
    }

    final dir = await _tempDirProvider();
    final safeVersion = manifest.version.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final targetFile = File(
      p.join(dir.path, 'ttg_update_${safeVersion}_${manifest.buildNumber}.apk'),
    );
    if (await targetFile.exists()) {
      await targetFile.delete();
    }

    final bytesBuilder = <int>[];
    final total = streamed.contentLength ?? -1;
    var received = 0;

    await for (final chunk in streamed.stream) {
      bytesBuilder.addAll(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }

    final actualSha256 = computeSha256Hex(bytesBuilder);
    final expectedSha256 = manifest.sha256.trim().toLowerCase();
    if (actualSha256 != expectedSha256) {
      throw ApkVerificationException(
        'APK SHA-256 mismatch: expected $expectedSha256, got $actualSha256.',
      );
    }

    await targetFile.writeAsBytes(bytesBuilder, flush: true);
    return targetFile;
  }

  /// Opens a verified APK file to trigger Android's package installer.
  Future<bool> installVerifiedApk(
    File apkFile, {
    required String expectedSha256,
  }) async {
    if (!await apkFile.exists()) {
      throw const ApkVerificationException('Verified APK file not found.');
    }
    final bytes = await apkFile.readAsBytes();
    final actual = computeSha256Hex(bytes);
    if (actual != expectedSha256.trim().toLowerCase()) {
      await apkFile.delete();
      throw const ApkVerificationException(
        'APK failed pre-install integrity check and was removed.',
      );
    }
    return _apkOpener(apkFile.path);
  }

  /// Convenience wrapper: downloads, verifies SHA-256, and triggers install.
  Future<bool> downloadVerifyAndInstall(
    AppUpdateManifest manifest, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final file = await downloadAndVerifyApk(manifest, onProgress: onProgress);
    return installVerifiedApk(file, expectedSha256: manifest.sha256);
  }

  static int _compareSemver(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }
}
