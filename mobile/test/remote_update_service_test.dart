import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:town_treasure_groceries/data/services/remote_update_service.dart';

void main() {
  group('RemoteUpdateService manifest & SHA-256 APK verification', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ttg_apk_update_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('checkForUpdate detects newer buildNumber', () async {
      final fakeApk = utf8.encode('fake-apk-binary');
      final digest = RemoteUpdateService.computeSha256Hex(fakeApk);
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'version': '1.1.0',
            'buildNumber': 2,
            'apkUrl': 'https://updates.example.com/app-1.1.0.apk',
            'sha256': digest,
            'releaseNotes': 'Bug fixes',
          }),
          200,
        );
      });

      final service = RemoteUpdateService(
        httpClient: client,
        versionProvider: () async => (version: '1.0.0', buildNumber: 1),
        tempDirProvider: () async => tempDir,
      );

      final check = await service.checkForUpdate(
        'https://updates.example.com/manifest.json',
      );
      expect(check.updateAvailable, isTrue);
      expect(check.manifest?.version, '1.1.0');
      expect(check.manifest?.sha256, digest);
    });

    test('downloadVerifyAndInstall succeeds and invokes opener when SHA-256 matches',
        () async {
      final apkBytes = List<int>.generate(256, (i) => (i * 7) % 256);
      final expectedSha = RemoteUpdateService.computeSha256Hex(apkBytes);
      String? openedPath;

      final client = MockClient((request) async {
        return http.Response.bytes(apkBytes, 200);
      });

      final service = RemoteUpdateService(
        httpClient: client,
        versionProvider: () async => (version: '1.0.0', buildNumber: 1),
        tempDirProvider: () async => tempDir,
        apkOpener: (path) async {
          openedPath = path;
          return true;
        },
      );

      final manifest = AppUpdateManifest(
        version: '1.2.0',
        buildNumber: 3,
        apkUrl: 'https://updates.example.com/app.apk',
        sha256: expectedSha,
      );

      final installed = await service.downloadVerifyAndInstall(manifest);
      expect(installed, isTrue);
      expect(openedPath, isNotNull);
      expect(await File(openedPath!).readAsBytes(), apkBytes);
    });

    test('downloadAndVerifyApk rejects tampered APK and leaves no corrupt file',
        () async {
      final apkBytes = utf8.encode('tampered-apk-payload');
      const wrongSha =
          '0000000000000000000000000000000000000000000000000000000000000000';
      var openerCalled = false;

      final client = MockClient((request) async {
        return http.Response.bytes(apkBytes, 200);
      });

      final service = RemoteUpdateService(
        httpClient: client,
        versionProvider: () async => (version: '1.0.0', buildNumber: 1),
        tempDirProvider: () async => tempDir,
        apkOpener: (_) async {
          openerCalled = true;
          return true;
        },
      );

      const manifest = AppUpdateManifest(
        version: '1.2.0',
        buildNumber: 3,
        apkUrl: 'https://updates.example.com/app.apk',
        sha256: wrongSha,
      );

      await expectLater(
        () => service.downloadVerifyAndInstall(manifest),
        throwsA(isA<ApkVerificationException>()),
      );
      expect(openerCalled, isFalse);
      expect(await tempDir.list().toList(), isEmpty);
    });
  });
}
