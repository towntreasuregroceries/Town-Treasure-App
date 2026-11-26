import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:town_treasure_groceries/data/services/local_storage_service.dart';
import 'package:town_treasure_groceries/data/services/remote_update_service.dart';

import 'test_fakes.dart';

void main() {
  sqfliteFfiInit();

  group('RemoteUpdateService manifest, host allowlist & SHA-256 verification', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ttg_apk_update_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('checkForUpdate detects newer buildNumber from official GitHub host', () async {
      final fakeApk = utf8.encode('fake-apk-binary');
      final digest = RemoteUpdateService.computeSha256Hex(fakeApk);
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'version': '1.1.0',
            'buildNumber': 2,
            'apkUrl':
                'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/download/v1.1.0/TownTreasureGroceries.apk',
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
        RemoteUpdateService.defaultOwnerManifestUrl,
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
        apkUrl:
            'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/download/v1.2.0/TownTreasureGroceries.apk',
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
        apkUrl:
            'https://github.com/towntreasuregroceries/Town-Treasure-App/releases/download/v1.2.0/TownTreasureGroceries.apk',
        sha256: wrongSha,
      );

      await expectLater(
        () => service.downloadVerifyAndInstall(manifest),
        throwsA(isA<ApkVerificationException>()),
      );
      expect(openerCalled, isFalse);
      expect(await tempDir.list().toList(), isEmpty);
    });

    test('rejects insecure HTTP URLs, untrusted hosts, and foreign GitHub repos',
        () async {
      const dummySha =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final service = RemoteUpdateService(
        httpClient: MockClient((_) async => http.Response('', 200)),
        versionProvider: () async => (version: '1.0.0', buildNumber: 1),
        tempDirProvider: () async => tempDir,
      );

      // 1. Plaintext HTTP rejected
      await expectLater(
        () => service.downloadVerifyAndInstall(
          const AppUpdateManifest(
            version: '1.3.0',
            buildNumber: 9,
            apkUrl:
                'http://github.com/towntreasuregroceries/Town-Treasure-App/releases/download/v1.3.0/app.apk',
            sha256: dummySha,
          ),
        ),
        throwsA(isA<ApkVerificationException>()),
      );

      // 2. Arbitrary third-party host rejected
      await expectLater(
        () => service.downloadVerifyAndInstall(
          const AppUpdateManifest(
            version: '1.3.0',
            buildNumber: 9,
            apkUrl: 'https://evil-attacker.example.com/trojan.apk',
            sha256: dummySha,
          ),
        ),
        throwsA(isA<ApkVerificationException>()),
      );

      // 3. Wrong GitHub org/repo rejected
      await expectLater(
        () => service.downloadVerifyAndInstall(
          const AppUpdateManifest(
            version: '1.3.0',
            buildNumber: 9,
            apkUrl: 'https://github.com/attacker-org/Town-Treasure-App/releases/download/v1/app.apk',
            sha256: dummySha,
          ),
        ),
        throwsA(isA<ApkVerificationException>()),
      );
    });

    test('purgeStaleTempExports keeps fresh shares alive and wipes >24h or sign-out exports',
        () async {
      final freshPdf = File(p.join(tempDir.path, 'Invoice_TTG-101.pdf'))
        ..writeAsStringSync('fresh');
      final stalePdf = File(p.join(tempDir.path, 'Invoice_TTG-099.pdf'))
        ..writeAsStringSync('stale');
      final staleApk = File(p.join(tempDir.path, 'ttg_update_1.2.8_2022.apk'))
        ..writeAsStringSync('apk');
      final unrelatedFile = File(p.join(tempDir.path, 'keep_notes.txt'))
        ..writeAsStringSync('keep');

      final now = DateTime(2026, 11, 26, 12, 0);
      stalePdf.setLastModifiedSync(now.subtract(const Duration(hours: 30)));
      staleApk.setLastModifiedSync(now.subtract(const Duration(hours: 48)));
      freshPdf.setLastModifiedSync(now.subtract(const Duration(minutes: 10)));

      final deletedStartup = await RemoteUpdateService.purgeStaleTempExports(
        directory: tempDir,
        now: now,
      );
      expect(deletedStartup, 2);
      expect(freshPdf.existsSync(), isTrue);
      expect(stalePdf.existsSync(), isFalse);
      expect(staleApk.existsSync(), isFalse);
      expect(unrelatedFile.existsSync(), isTrue);

      final deletedSignOut = await RemoteUpdateService.purgeStaleTempExports(
        directory: tempDir,
        purgeAll: true,
      );
      expect(deletedSignOut, 1);
      expect(freshPdf.existsSync(), isFalse);
      expect(unrelatedFile.existsSync(), isTrue);
    });
  });

  group('LocalStorageService transparent AES-256-GCM SQLite encryption & auto-migration', () {
    test('seamlessly migrates legacy plaintext SQLite rows and stores ciphertext at rest',
        () async {
      final dbDir = await Directory.systemTemp.createTemp('ttg_sql_enc_test_');
      addTearDown(() async {
        if (await dbDir.exists()) {
          await dbDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(dbDir.path, 'ttg_vault_cache.db');
      final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
      await rawDb.execute('''
        CREATE TABLE kv_store (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      // Seed a legacy v1.2.9 plaintext invoice row (simulating Veronicah's existing phone cache)
      await rawDb.insert('kv_store', {
        'key': LocalStorageService.keyInvoices,
        'value': jsonEncode([
          {'id': 'inv_vero_1', 'restaurantName': 'Serena Hotel', 'totalSell': 18500}
        ]),
        'updated_at': 1700000000000,
      });

      final secureStore = InMemorySecureKeyStore();
      final storage = LocalStorageService(
        secureStore: secureStore,
        databaseOpener: () => databaseFactoryFfi.openDatabase(dbPath),
      );
      await storage.init();

      // 1. Underlying SQLite disk row is now AES-256-GCM ciphertext (not plaintext!)
      final onDiskAfterInit = await rawDb.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: [LocalStorageService.keyInvoices],
      );
      final rawStoredValue = onDiskAfterInit.single['value'] as String;
      expect(rawStoredValue.startsWith(LocalStorageService.encryptedRowPrefix), isTrue);
      expect(rawStoredValue.contains('Serena Hotel'), isFalse);

      // 2. Reading via LocalStorageService transparently returns Veronicah's exact data!
      final invoices = await storage.getJsonList(LocalStorageService.keyInvoices);
      expect(invoices.single['restaurantName'], 'Serena Hotel');
      expect(invoices.single['totalSell'], 18500);

      // 3. New writes also store ciphertext on disk
      await storage.setJson(LocalStorageService.keyStaff, [
        {'id': 'st_1', 'name': 'Peter', 'salary': 25000}
      ]);
      final staffDisk = await rawDb.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: [LocalStorageService.keyStaff],
      );
      final staffRaw = staffDisk.single['value'] as String;
      expect(staffRaw.startsWith(LocalStorageService.encryptedRowPrefix), isTrue);
      expect(staffRaw.contains('Peter'), isFalse);

      // 4. Evicting in-memory keys on biometric background lock clears RAM cache,
      //    then transparently reloads from SecureKeyStore with zero data loss!
      await storage.setE2eKey({'kty': 'oct', 'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'});
      expect(storage.hasCachedInMemoryKeys, isTrue);
      storage.evictInMemoryKeys();
      expect(storage.hasCachedInMemoryKeys, isFalse);

      final reloadedStaff = await storage.getJsonList(LocalStorageService.keyStaff);
      expect(reloadedStaff.single['name'], 'Peter');

      await storage.close();
      await rawDb.close();
    });
  });
}
