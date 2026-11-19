import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';

void main() {
  group('CryptoService WebCrypto PBKDF2 + AES-GCM parity', () {
    final crypto = CryptoService();

    test('derives exact WebCrypto JWK for v2 per-user salt', () async {
      final jwk = await crypto.deriveKey('test-pass-123', 'user-abc-123');
      expect(jwk['kty'], 'oct');
      expect(jwk['alg'], 'A256GCM');
      expect(jwk['ext'], true);
      expect(jwk['key_ops'], ['encrypt', 'decrypt']);
      // Exact value produced by WebCrypto subtle.deriveKey in Node/Chrome.
      expect(jwk['k'], 'LLZk65pKdLz6gVZmQt3BNoDMQKEREHiuy9-zDcC1Vf8');
    });

    test('decrypts genuine WebCrypto AES-GCM ciphertext produced by data.js layout',
        () async {
      final jwk = await crypto.deriveKey('test-pass-123', 'user-abc-123');
      const webCryptoBase64 =
          'AQIDBAUGBwgJCgsMxGRU8DgaRdAN47S+l3i6zgD4C5JlI4rmQMqCEoIXuZCqVAN1BBU++j5ClBsegH5CyD4PwSSEokvS+rUAf39IL3EaKKJikSB+wMZBDu4E9tSSfJZkichp6js2pOueh5cpGdDNb2MdmKHdbg6D/vZLiVXuINaUT2dPIKX2Bn+cW15yUpKvguuNZZrhwv/u2Li3AIBWD7LTp50UeDju+D8=';

      final decrypted = await crypto.decrypt(webCryptoBase64, jwk);
      expect(decrypted, isNotNull);
      expect(decrypted!['invoices'], hasLength(1));
      expect(decrypted['invoices'][0]['number'], 'TTG-AB12');
      expect(decrypted['restaurants'][0]['kraPin'], 'P051234567X');
    });

    test('encrypt + decrypt round-trip preserves 12-byte IV + cipher + 16-byte MAC layout',
        () async {
      final jwk = await crypto.deriveKey('my-secret-pass', 'uid-999');
      final payloadObj = {
        '_vaultVersion': 4,
        'invoices': [
          {'id': 'inv_1', 'number': 'TTG-1001', 'totalSell': 2500.5},
        ],
        'settings': {'signature': 'data:image/png;base64,AAAA'},
      };

      final encrypted = await crypto.encrypt(payloadObj, jwk);
      final rawBytes = base64Decode(encrypted);
      // 12-byte IV + ciphertext + 16-byte MAC tag.
      expect(rawBytes.length, greaterThan(28));

      final decrypted = await crypto.decrypt(encrypted, jwk);
      expect(decrypted, equals(payloadObj));
    });

    test('legacy v1 salt differs from v2 salt and wrong key returns null',
        () async {
      final v2Key = await crypto.deriveKey('passphrase', 'user-1');
      final legacyKey = await crypto.deriveKeyLegacy('passphrase');
      expect(v2Key['k'], isNot(equals(legacyKey['k'])));

      final encrypted = await crypto.encrypt({'secret': 'vault'}, legacyKey);
      expect(await crypto.decrypt(encrypted, v2Key), isNull);
      expect(await crypto.decrypt(encrypted, legacyKey), {'secret': 'vault'});

      // Corrupt ciphertext byte returns null cleanly.
      final bytes = base64Decode(encrypted);
      bytes[bytes.length - 1] ^= 0xFF;
      expect(await crypto.decrypt(base64Encode(bytes), legacyKey), isNull);
    });
  });
}
