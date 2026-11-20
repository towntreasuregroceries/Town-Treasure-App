import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// WebCrypto-compatible E2EE service matching `Crypto` in `data.js`.
///
/// Key derivation: PBKDF2-HMAC-SHA256, 100,000 iterations, 256-bit AES-GCM key.
/// Salts:
/// - v2: `ttg-vault-v2-<userId>`
/// - v1 (legacy): `town-treasure-secure-salt-v1`
///
/// Ciphertext layout (base64 encoded):
/// `[12-byte IV] + [AES-GCM ciphertext] + [16-byte authentication tag]`.
class CryptoService {
  CryptoService({
    Pbkdf2? pbkdf2,
    AesGcm? aesGcm,
  })  : _pbkdf2 = pbkdf2 ??
            Pbkdf2(
              macAlgorithm: Hmac.sha256(),
              iterations: pbkdf2Iterations,
              bits: 256,
            ),
        _aesGcm = aesGcm ?? AesGcm.with256bits();

  static const int pbkdf2Iterations = 100000;
  static const int ivLengthBytes = 12;
  static const int macLengthBytes = 16;
  static const String legacySalt = 'town-treasure-secure-salt-v1';
  static const String v2SaltPrefix = 'ttg-vault-v2-';

  final Pbkdf2 _pbkdf2;
  final AesGcm _aesGcm;

  /// Returns the salt string matching `data.js` `Crypto.deriveKey`.
  static String saltForUser(String? userId) {
    if (userId != null && userId.isNotEmpty) {
      return '$v2SaltPrefix$userId';
    }
    return legacySalt;
  }

  /// Derives a WebCrypto-compatible JWK map with per-user salt (or legacy fallback).
  Future<Map<String, dynamic>> deriveKey(
    String password, [
    String? userId,
  ]) async {
    final saltStr = saltForUser(userId);
    final secretKey = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: utf8.encode(saltStr),
    );
    final keyBytes = await secretKey.extractBytes();
    return bytesToJwk(keyBytes);
  }

  /// Derives a WebCrypto-compatible JWK map with the legacy v1 static salt.
  Future<Map<String, dynamic>> deriveKeyLegacy(String password) {
    return deriveKey(password, null);
  }

  /// Converts 32 raw AES-256 bytes to WebCrypto JWK format.
  static Map<String, dynamic> bytesToJwk(List<int> keyBytes) {
    if (keyBytes.length != 32) {
      throw ArgumentError.value(
        keyBytes.length,
        'keyBytes',
        'AES-256 key must be 32 bytes',
      );
    }
    final k = base64Url.encode(keyBytes).replaceAll('=', '');
    return <String, dynamic>{
      'kty': 'oct',
      'k': k,
      'alg': 'A256GCM',
      'ext': true,
      'key_ops': ['encrypt', 'decrypt'],
    };
  }

  /// Imports a WebCrypto JWK map into a `SecretKey`.
  static SecretKey jwkToSecretKey(Map<String, dynamic> jwk) {
    final k = jwk['k']?.toString();
    if (k == null || k.isEmpty) {
      throw ArgumentError('JWK is missing "k" material');
    }
    final padded = k.padRight((k.length + 3) ~/ 4 * 4, '=');
    final bytes = base64Url.decode(padded);
    if (bytes.length != 32) {
      throw ArgumentError('AES-256 JWK key must decode to 32 bytes');
    }
    return SecretKey(bytes);
  }

  /// Encrypts raw binary data (such as personal vault PDFs/images) and returns
  /// `[IV(12) | cipher | tag(16)]`.
  Future<Uint8List> encryptBytes(
    Uint8List plainBytes,
    Map<String, dynamic> jwkKey,
  ) async {
    final secretKey = jwkToSecretKey(jwkKey);
    final nonce = _aesGcm.newNonce();
    if (nonce.length != ivLengthBytes) {
      throw StateError('Unexpected AES-GCM nonce length: ${nonce.length}');
    }
    final secretBox = await _aesGcm.encrypt(
      plainBytes,
      secretKey: secretKey,
      nonce: nonce,
    );
    final macBytes = secretBox.mac.bytes;
    if (macBytes.length != macLengthBytes) {
      throw StateError('Unexpected AES-GCM MAC length: ${macBytes.length}');
    }

    final payload = Uint8List(
      ivLengthBytes + secretBox.cipherText.length + macLengthBytes,
    );
    payload.setRange(0, ivLengthBytes, nonce);
    payload.setRange(
      ivLengthBytes,
      ivLengthBytes + secretBox.cipherText.length,
      secretBox.cipherText,
    );
    payload.setRange(
      ivLengthBytes + secretBox.cipherText.length,
      payload.length,
      macBytes,
    );
    return payload;
  }

  /// Decrypts raw `[IV(12) | cipher | tag(16)]` binary ciphertext produced by [encryptBytes].
  Future<Uint8List?> decryptBytes(
    Uint8List? payload,
    Map<String, dynamic>? jwkKey,
  ) async {
    if (payload == null ||
        payload.length < ivLengthBytes + macLengthBytes + 1 ||
        jwkKey == null) {
      return null;
    }
    try {
      final secretKey = jwkToSecretKey(jwkKey);
      final iv = payload.sublist(0, ivLengthBytes);
      final cipherText = payload.sublist(
        ivLengthBytes,
        payload.length - macLengthBytes,
      );
      final macBytes = payload.sublist(payload.length - macLengthBytes);

      final secretBox = SecretBox(
        cipherText,
        nonce: iv,
        mac: Mac(macBytes),
      );
      final decrypted = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
      return Uint8List.fromList(decrypted);
    } catch (_) {
      return null;
    }
  }

  /// Encrypts a JSON-serializable object and returns base64 `[IV(12) | cipher | tag(16)]`.
  Future<String> encrypt(
    Map<String, dynamic> dataObj,
    Map<String, dynamic> jwkKey,
  ) async {
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(dataObj)));
    final encrypted = await encryptBytes(plaintext, jwkKey);
    return base64Encode(encrypted);
  }

  /// Decrypts a base64 `[IV(12) | cipher | tag(16)]` payload produced by `data.js` or this service.
  /// Returns `null` when decryption or JSON decoding fails (matching `data.js`).
  Future<Map<String, dynamic>?> decrypt(
    String? base64Str,
    Map<String, dynamic>? jwkKey,
  ) async {
    if (base64Str == null || base64Str.isEmpty || jwkKey == null) return null;
    try {
      final payload = Uint8List.fromList(base64Decode(base64Str));
      if (payload.length < ivLengthBytes + macLengthBytes) {
        return null;
      }
      final secretKey = jwkToSecretKey(jwkKey);
      final iv = payload.sublist(0, ivLengthBytes);
      final cipherText = payload.sublist(
        ivLengthBytes,
        payload.length - macLengthBytes,
      );
      final macBytes = payload.sublist(payload.length - macLengthBytes);

      final secretBox = SecretBox(
        cipherText,
        nonce: iv,
        mac: Mac(macBytes),
      );
      final decrypted = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
      final decoded = jsonDecode(utf8.decode(decrypted));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
