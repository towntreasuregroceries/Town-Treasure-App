import 'package:flutter_test/flutter_test.dart';
import 'package:town_treasure_groceries/data/repositories/auth_repository.dart';
import 'package:town_treasure_groceries/data/repositories/vault_repository.dart';
import 'package:town_treasure_groceries/data/services/crypto_service.dart';
import 'package:town_treasure_groceries/data/services/supabase_service.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';

import 'test_fakes.dart';

void main() {
  group('VaultRepository CAS merge and tombstone parity', () {
    test('mergeRecordActions and isRecordDeleted honor latest delete vs restore',
        () {
      final merged = VaultRepository.mergeRecordActions(
        {
          'invoices': {
            'inv_deleted': const RecordAction(deletedAt: 500, restoredAt: 100),
            'inv_restored': const RecordAction(deletedAt: 200, restoredAt: 400),
          },
        },
        {
          'invoices': {
            'inv_deleted': const RecordAction(deletedAt: 100, restoredAt: 300),
            'inv_restored': const RecordAction(deletedAt: 300, restoredAt: 600),
          },
        },
      );

      expect(VaultRepository.isRecordDeleted(merged, 'invoices', 'inv_deleted'), isTrue);
      expect(VaultRepository.isRecordDeleted(merged, 'invoices', 'inv_restored'), isFalse);
    });

    test('mergeInvoicesById prevents stale remote snapshot from resurrecting deleted invoice',
        () {
      final actions = VaultRepository.includeLegacyInvoiceActions(
        {
          'invoices': {
            'inv_del': const RecordAction(deletedAt: 1000, restoredAt: 0),
          },
        },
        deletedIds: const ['inv_del'],
      );

      const localInv = Invoice(
        id: 'inv_keep',
        number: 'TTG-1001',
        restaurantId: 'r1',
        restaurantName: 'Client',
        date: '2026-11-18',
        totalSell: 2000,
        updatedAt: '2026-11-18T12:00:00Z',
      );
      const staleRemoteInv = Invoice(
        id: 'inv_keep',
        number: 'TTG-1001',
        restaurantId: 'r1',
        restaurantName: 'Client',
        date: '2026-11-18',
        totalSell: 1000,
        updatedAt: '2026-11-18T08:00:00Z',
      );
      const resurrectedRemoteInv = Invoice(
        id: 'inv_del',
        number: 'TTG-1002',
        restaurantId: 'r1',
        restaurantName: 'Client',
        date: '2026-11-17',
        totalSell: 500,
      );

      final merged = VaultRepository.mergeInvoicesById(
        [localInv],
        [staleRemoteInv, resurrectedRemoteInv],
        actions,
      );

      expect(merged.map((i) => i.id).toList(), ['inv_keep']);
      expect(merged.first.totalSell, 2000);
    });

    test('syncNow retries CAS conflict, merges concurrent remote edit, and advances revision',
        () async {
      final storage = await createTestLocalStorage();
      final crypto = CryptoService();
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'user-cas', email: 'owner@ttg.test');
      final jwk = await crypto.deriveKey('pw', 'user-cas');
      await storage.setE2eKey(jwk);
      await storage.setUserId('user-cas');

      // Seed server at revision 1 with restaurant r1.
      final rev1Vault = const VaultData(
        restaurants: [Restaurant(id: 'r1', name: 'Alpha Bistro')],
      );
      supabase.hasVaultRow = true;
      supabase.vaultRevision = 1;
      supabase.vaultData = await crypto.encrypt(rev1Vault.toJson(), jwk);

      // Prepare a concurrent revision 2 edit on server (restaurant r2).
      final rev2Vault = const VaultData(
        restaurants: [
          Restaurant(id: 'r1', name: 'Alpha Bistro'),
          Restaurant(id: 'r2', name: 'Concurrent Remote Diner'),
        ],
      );
      supabase.forceConflictOnce = true;
      supabase.nextConflictRemoteRevision = 2;
      supabase.nextConflictRemoteData =
          await crypto.encrypt(rev2Vault.toJson(), jwk);

      final repo = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
      );
      await repo.setRestaurants(
        const [Restaurant(id: 'r3', name: 'Offline Local Cafe')],
        sync: false,
      );

      final synced = await repo.syncNow();
      expect(synced, isTrue);
      expect(repo.remoteRevision, 3);
      expect(supabase.vaultRevision, 3);
      expect(
        repo.restaurants.map((r) => r.id).toSet(),
        {'r1', 'r2', 'r3'},
      );
      await storage.close();
    });

    test('migrateE2EKey falls back to legacy v1 key and re-encrypts vault to v2 via CAS',
        () async {
      final storage = await createTestLocalStorage();
      final crypto = CryptoService();
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'user-mig', email: 'owner@ttg.test');
      await storage.setUserId('user-mig');

      final legacyKey = await crypto.deriveKeyLegacy('secret123');
      final v1Vault = const VaultData(
        restaurants: [Restaurant(id: 'r_leg', name: 'Legacy Hotel')],
      );
      supabase.hasVaultRow = true;
      supabase.vaultRevision = 4;
      supabase.vaultData = await crypto.encrypt(v1Vault.toJson(), legacyKey);

      final repo = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
      );

      final res = await repo.migrateE2EKey('secret123', 'user-mig');
      expect(res.migrated, isTrue);
      expect(supabase.vaultRevision, 5);
      expect(repo.restaurants.first.name, 'Legacy Hotel');

      // Server payload must now decrypt with v2 key, not legacy key.
      final v2Key = await crypto.deriveKey('secret123', 'user-mig');
      final decryptedWithV2 = await crypto.decrypt(supabase.vaultData, v2Key);
      expect(decryptedWithV2, isNotNull);
      expect(await crypto.decrypt(supabase.vaultData, legacyKey), isNull);
      await storage.close();
    });

    test('AuthRepository.signOut aborts if sync fails and clears data if sync succeeds',
        () async {
      final storage = await createTestLocalStorage();
      final crypto = CryptoService();
      final supabase = FakeSupabaseGateway()
        ..user = const AuthUserInfo(id: 'user-out', email: 'owner@ttg.test')
        ..failSaveOnce = true;
      final jwk = await crypto.deriveKey('pw', 'user-out');
      await storage.setE2eKey(jwk);
      await storage.setUserId('user-out');

      final vault = VaultRepository(
        cryptoService: crypto,
        localStorage: storage,
        supabase: supabase,
      );
      await vault.setRestaurants(
        const [Restaurant(id: 'r1', name: 'Kept Safe')],
        sync: false,
      );

      final auth = AuthRepository(
        supabase: supabase,
        localStorage: storage,
        cryptoService: crypto,
        vaultRepository: vault,
      );

      // First attempt fails sync -> signOut aborted, local data preserved.
      expect(await auth.signOut(), isFalse);
      expect(vault.restaurants, hasLength(1));
      expect(supabase.signOutCalls, 0);

      // Second attempt succeeds -> local data cleared and signed out.
      expect(await auth.signOut(), isTrue);
      expect(vault.restaurants, isEmpty);
      expect(await storage.getE2eKey(), isNull);
      expect(supabase.signOutCalls, 1);
      await storage.close();
    });
  });
}
