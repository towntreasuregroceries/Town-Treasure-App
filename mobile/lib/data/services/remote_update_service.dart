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

/// Checks a remote JSON manifest, downloads the APK, verifies its SHA-256 digest,
/// and hands off installation to Android via `open_filex` + FileProvider.
class RemoteUpdateService {
  static const String defaultOwnerManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json';
  static const String defaultClerkManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/clerk-update.json';

  RemoteUpdateService({
    http.Client? httpClient,
    PackageVersionProvider? versionProvider,
    TempDirProvider? tempDirProvider,
    ApkFileOpener? apkOpener,
  })  : _httpClient = httpClient ?? http.Client(),
        _versionProvider = versionProvider ?? _defaultVersionProvider,
        _tempDirProvider = tempDirProvider ?? getTemporaryDirectory,
        _apkOpener = apkOpener ?? _defaultApkOpener;

  final http.Client _httpClient;
  final PackageVersionProvider _versionProvider;
  final TempDirProvider _tempDirProvider;
  final ApkFileOpener _apkOpener;

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

  /// Checks `manifestUrl` and compares `buildNumber` and semantic `version`.
  Future<UpdateCheckResult> checkForUpdate(String manifestUrl) async {
    final current = await _versionProvider();
    final uri = Uri.parse(manifestUrl);
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
    final uri = Uri.parse(manifest.apkUrl);
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
