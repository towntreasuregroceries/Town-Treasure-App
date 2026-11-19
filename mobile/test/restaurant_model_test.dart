import 'package:flutter_test/flutter_test.dart';
import 'package:town_treasure_groceries/domain/models/models.dart';

void main() {
  group('Restaurant KRA PIN normalization and validation', () {
    test('normalizes whitespace and casing', () {
      expect(Restaurant.normalizeKraPin(' p051 234 567x '), 'P051234567X');
      expect(Restaurant.normalizeKraPin('a009876543b'), 'A009876543B');
      expect(Restaurant.normalizeKraPin(null), '');
    });

    test('validates 11-char KRA PIN format [PA][0-9]{9}[A-Z]', () {
      expect(Restaurant.isValidKraPin('P051234567X'), isTrue);
      expect(Restaurant.isValidKraPin(' a001234567z '), isTrue);
      expect(Restaurant.isValidKraPin('B051234567X'), isFalse);
      expect(Restaurant.isValidKraPin('P05123456X'), isFalse);
      expect(Restaurant.isValidKraPin('P0512345671'), isFalse);
      expect(Restaurant.isValidKraPin(''), isFalse);
    });
  });

  group('Restaurant name normalization and fuzzy resolution', () {
    final restaurants = [
      const Restaurant(
        id: 'r1',
        name: 'The Golden Crest Hotel',
        kraPin: 'P051234567X',
        aliases: ['Golden Crest', 'Crest Kitchen'],
      ),
      const Restaurant(
        id: 'r2',
        name: 'Sankara Suites',
        aliases: ['Sankara Westlands'],
      ),
    ];

    test('strips generic hospitality words and punctuation', () {
      expect(
        Restaurant.normalizeRestaurantName('The Golden Crest Hotel Ltd.'),
        'goldencrest',
      );
      expect(
        Restaurant.normalizeRestaurantName('Sankara Suites & Resort'),
        'sankaraand',
      );
    });

    test('resolves exact name and alias matches', () {
      final byName = Restaurant.resolveName('Golden Crest Hotel', restaurants);
      expect(byName.status, RestaurantResolutionStatus.matched);
      expect(byName.restaurant?.id, 'r1');
      expect(byName.method, 'name');

      final byAlias = Restaurant.resolveName('Crest Kitchen', restaurants);
      expect(byAlias.status, RestaurantResolutionStatus.matched);
      expect(byAlias.restaurant?.id, 'r1');
      expect(byAlias.method, 'alias');
    });

    test('returns suggested for close spelling without auto-matching', () {
      final res = Restaurant.resolveName('Goldn Crest', restaurants);
      expect(res.status, RestaurantResolutionStatus.suggested);
      expect(res.restaurant?.id, 'r1');
    });

    test('collectMergeCandidates follows transitive alias overlaps', () {
      final existing = [
        const Restaurant(id: 'rA', name: 'Savannah Bistro', aliases: ['Savanna']),
        const Restaurant(id: 'rB', name: 'Savanna Kitchen', aliases: ['Savanna']),
        const Restaurant(id: 'rC', name: 'Other Place'),
      ];
      const target = Restaurant(
        id: 'rTarget',
        name: 'Savannah Bistro',
        aliases: [],
      );
      final dupes = Restaurant.collectMergeCandidates(target, existing);
      expect(dupes.map((d) => d.id).toSet(), {'rA', 'rB'});
    });
  });

  group('VaultData JSON round-trip', () {
    test('serializes and deserializes all domain entities cleanly', () {
      final vault = VaultData(
        vaultVersion: 3,
        lastSync: '2026-11-18T10:00:00Z',
        restaurants: const [
          Restaurant(
            id: 'r1',
            name: 'Savannah Bistro',
            kraPin: 'P051234567X',
            aliases: ['Savanna'],
            contact: 'Jane',
            phone: '0700000000',
            address: 'Nairobi',
          ),
        ],
        invoices: const [
          Invoice(
            id: 'inv1',
            number: 'TTG-1001',
            restaurantId: 'r1',
            restaurantName: 'Savannah Bistro',
            date: '2026-11-18',
            items: [
              InvoiceLineItem(
                desc: 'Onions',
                qty: 10,
                unit: 'kgs',
                buyPrice: 80,
                sellPrice: 120,
                total: 1200,
              ),
            ],
            totalSell: 1200,
            totalBuy: 800,
            deliveryCost: 100,
            otherCost: 0,
            profit: 300,
          ),
        ],
        expenses: const [
          Expense(
            id: 'exp1',
            type: 'expense',
            date: '2026-11-18',
            desc: 'Fuel',
            category: 'transport',
            amount: 500,
          ),
        ],
        staff: const [
          Staff(id: 'st1', name: 'Daniel', role: 'Driver', salary: 25000),
        ],
        salaryPayments: const [
          SalaryPayment(
            id: 'sp1',
            staffId: 'st1',
            staffName: 'Daniel',
            month: '2026-11',
            amount: 25000,
            datePaid: '2026-11-05',
          ),
        ],
        recurringExpenses: const [
          RecurringExpense(
            id: 're1',
            desc: 'Warehouse Rent',
            category: 'rent',
            amount: 30000,
            dueDay: '1',
          ),
        ],
        priceLists: const [
          PriceList(
            id: 'pl1',
            name: 'Nov 2026',
            status: 'active',
            items: [
              PriceListItem(id: 'h1', name: 'Vegetables', isHeader: true),
              PriceListItem(id: 'i1', name: 'Tomatoes', price: 140),
            ],
          ),
        ],
        borrowings: const [
          Borrowing(
            id: 'b1',
            date: '2026-11-01',
            desc: 'Float',
            amount: 10000,
            repayments: [
              Repayment(id: 'rep1', date: '2026-11-10', amount: 4000, desc: 'Part'),
            ],
          ),
        ],
        recordActions: const {
          'invoices': {'inv_old': RecordAction(deletedAt: 1000, restoredAt: 0)},
        },
        settings: const VaultSettings(
          signature: 'data:image/png;base64,AA==',
          updatedAt: '2026-11-18T10:00:00Z',
        ),
      );

      final roundTripped = VaultData.fromJson(vault.toJson());
      expect(roundTripped.restaurants.first.kraPin, 'P051234567X');
      expect(roundTripped.invoices.first.profit, 300);
      expect(roundTripped.borrowings.first.outstandingBalance, 6000);
      expect(roundTripped.priceLists.first.items.first.isHeader, isTrue);
      expect(
        roundTripped.recordActions['invoices']?['inv_old']?.isDeleted,
        isTrue,
      );
      expect(roundTripped.settings.signature, 'data:image/png;base64,AA==');
    });
  });
}
