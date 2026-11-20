import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../domain/models/models.dart';
import 'crypto_service.dart';
import 'local_storage_service.dart';
import 'supabase_service.dart';

typedef VaultDirProvider = Future<Directory> Function();

/// Result from picking or scanning a file before encrypting it into the Vault.
class StagedVaultFile {
  const StagedVaultFile({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;
}

/// Manages Zero-Knowledge AES-256-GCM encryption/decryption of Personal Documents,
/// encrypted local `.enc` offline cache, and lazy sync with the Cloudflare R2 Worker.
class PersonalVaultService {
  PersonalVaultService({
    required CryptoService cryptoService,
    required LocalStorageService localStorage,
    required this._supabase,
    http.Client? httpClient,
    VaultDirProvider? vaultDirProvider,
  })  : _crypto = cryptoService,
        _storage = localStorage,
        _http = httpClient ?? http.Client(),
        _dirProvider = vaultDirProvider ?? _defaultVaultDir;

  /// Deployed Cloudflare Worker backed by the private `towntreasure` R2 bucket.
  static const String defaultWorkerUrl =
      'https://ttg-vault-docs.towntreasuregroceries.workers.dev';

  final CryptoService _crypto;
  final LocalStorageService _storage;
  final SupabaseGateway _supabase;
  final http.Client _http;
  final VaultDirProvider _dirProvider;

  static Future<Directory> _defaultVaultDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'ttg_personal_vault'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String computeSha256(Uint8List bytes) {
    return crypto.sha256.convert(bytes).toString().toLowerCase();
  }

  static String normalizeWorkerUrl(String? rawUrl) {
    final candidate = (rawUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    return candidate.isNotEmpty ? candidate : defaultWorkerUrl;
  }

  /// Combines one or more camera/gallery photos into a clean A4 PDF ready for
  /// E2EE vault storage and `BrandedPdfViewerScreen` preview.
  static Future<Uint8List> packImagesToPdf(
    List<Uint8List> imagePages, {
    String title = 'Scanned Document',
  }) async {
    if (imagePages.isEmpty) {
      throw ArgumentError('At least one image page is required.');
    }
    final doc = pw.Document(title: title, author: 'Town Treasure Vault');
    for (final rawBytes in imagePages) {
      final decoded = img.decodeImage(rawBytes);
      Uint8List normalized = rawBytes;
      if (decoded != null) {
        final resized = decoded.width > 1800
            ? img.copyResize(decoded, width: 1800)
            : decoded;
        normalized = Uint8List.fromList(img.encodeJpg(resized, quality: 88));
      }
      final memImg = pw.MemoryImage(normalized);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(18),
          build: (_) => pw.Center(
            child: pw.Image(memImg, fit: pw.BoxFit.contain),
          ),
        ),
      );
    }
    return doc.save();
  }

  Future<File> _localEncryptedFile(String docId) async {
    final safeId = docId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dir = await _dirProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File(p.join(dir.path, '$safeId.enc'));
  }

  Future<bool> hasLocalEncryptedCopy(String docId) async {
    final file = await _localEncryptedFile(docId);
    return file.exists();
  }

  /// Encrypts [plainBytes] locally with the user's E2EE AES-256-GCM vault key,
  /// writes the ciphertext to `.enc` cache, and uploads ciphertext to Cloudflare R2
  /// when [workerUrl] and an authenticated Supabase JWT are available.
  Future<PersonalDocument> encryptStoreAndUpload({
    required PersonalDocument meta,
    required Uint8List plainBytes,
    String? workerUrl,
  }) async {
    final jwk = await _storage.getE2eKey();
    if (jwk == null) {
      throw StateError(
        'Encryption vault key is locked or missing. Sign in again before saving documents.',
      );
    }

    final sha = computeSha256(plainBytes);
    final cipherBytes = await _crypto.encryptBytes(plainBytes, jwk);

    final localFile = await _localEncryptedFile(meta.id);
    await localFile.writeAsBytes(cipherBytes, flush: true);

    var synced = false;
    final cleanUrl = normalizeWorkerUrl(workerUrl);
    if (cleanUrl.isNotEmpty) {
      synced = await _uploadEncryptedBlob(
        workerUrl: cleanUrl,
        docId: meta.id,
        cipherBytes: cipherBytes,
        sha256: sha,
        mimeType: meta.mimeType,
      );
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    return meta.copyWith(
      plainBytes: plainBytes.length,
      sha256: sha,
      r2Synced: synced,
      createdAt: meta.createdAt ?? nowIso,
      updatedAt: nowIso,
    );
  }

  /// Syncs an existing locally encrypted `.enc` file up to Cloudflare R2.
  Future<bool> syncLocalToR2({
    required PersonalDocument meta,
    required String workerUrl,
  }) async {
    final cleanUrl = normalizeWorkerUrl(workerUrl);
    if (cleanUrl.isEmpty) return false;
    final localFile = await _localEncryptedFile(meta.id);
    if (!await localFile.exists()) return false;
    final cipherBytes = await localFile.readAsBytes();
    return _uploadEncryptedBlob(
      workerUrl: cleanUrl,
      docId: meta.id,
      cipherBytes: cipherBytes,
      sha256: meta.sha256,
      mimeType: meta.mimeType,
    );
  }

  /// Loads and decrypts [meta] in-memory: prefers local `.enc` cache, falling back
  /// lazily to Cloudflare R2 Worker when opening on another device.
  Future<Uint8List> loadAndDecryptDocument(
    PersonalDocument meta, {
    String? workerUrl,
  }) async {
    final jwk = await _storage.getE2eKey();
    if (jwk == null) {
      throw StateError('Unlock your vault first to view this document.');
    }

    Uint8List? cipherBytes;
    final localFile = await _localEncryptedFile(meta.id);
    if (await localFile.exists()) {
      cipherBytes = await localFile.readAsBytes();
    }

    if (cipherBytes == null || cipherBytes.isEmpty) {
      final cleanUrl = normalizeWorkerUrl(workerUrl);
      if (cleanUrl.isEmpty) {
        throw StateError(
          'Document file is not cached on this device yet and no Cloudflare R2 Worker URL is set.',
        );
      }
      cipherBytes = await _downloadEncryptedBlob(
        workerUrl: cleanUrl,
        docId: meta.id,
      );
      await localFile.writeAsBytes(cipherBytes, flush: true);
    }

    final plain = await _crypto.decryptBytes(cipherBytes, jwk);
    if (plain == null) {
      throw StateError(
        'Could not decrypt document "${meta.title}" with your current vault key.',
      );
    }
    if (meta.sha256.isNotEmpty) {
      final actualSha = computeSha256(plain);
      if (actualSha != meta.sha256.toLowerCase()) {
        throw StateError(
          'Integrity verification failed for "${meta.title}" (SHA-256 mismatch).',
        );
      }
    }
    return plain;
  }

  /// Deletes the local `.enc` file and issues `DELETE /docs/:docId` to R2 if configured.
  Future<void> deleteEncryptedBlob(
    String docId, {
    String? workerUrl,
  }) async {
    final localFile = await _localEncryptedFile(docId);
    if (await localFile.exists()) {
      await localFile.delete();
    }

    final cleanUrl = normalizeWorkerUrl(workerUrl);
    if (cleanUrl.isEmpty) return;
    final token = await _supabase.getAccessToken();
    if (token == null || token.isEmpty) return;

    try {
      await _http
          .delete(
            Uri.parse('$cleanUrl/docs/${Uri.encodeComponent(docId)}'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      // Soft-delete metadata tombstone ensures it stays hidden even if offline.
    }
  }

  Future<bool> _uploadEncryptedBlob({
    required String workerUrl,
    required String docId,
    required Uint8List cipherBytes,
    required String sha256,
    required String mimeType,
  }) async {
    final token = await _supabase.getAccessToken();
    if (token == null || token.isEmpty) return false;

    try {
      final res = await _http
          .put(
            Uri.parse('$workerUrl/docs/${Uri.encodeComponent(docId)}'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/octet-stream',
              if (sha256.isNotEmpty) 'X-Doc-Sha256': sha256,
              if (mimeType.isNotEmpty) 'X-Doc-Mime': mimeType,
            },
            body: cipherBytes,
          )
          .timeout(const Duration(seconds: 45));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List> _downloadEncryptedBlob({
    required String workerUrl,
    required String docId,
  }) async {
    final token = await _supabase.getAccessToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to download this document from Cloudflare R2.');
    }
    final res = await _http
        .get(
          Uri.parse('$workerUrl/docs/${Uri.encodeComponent(docId)}'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 45));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Cloudflare R2 returned HTTP ${res.statusCode} while fetching encrypted document.',
      );
    }
    return res.bodyBytes;
  }
}
