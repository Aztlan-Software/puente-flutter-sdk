import 'package:clock/clock.dart';
import 'package:puente_railway/puente_railway.dart';
import 'package:puente_railway/testing.dart';
import 'package:test/test.dart';

/// Contract tests: the mock must mirror the real backend's treasury wire
/// contract — fixture values only, no financial computation of its own.
void main() {
  group('Mock treasury contract', () {
    late PuenteClient client;

    setUp(() {
      client = PuenteClient.mock(
        seed: 3,
        settlementLatency: Duration.zero,
        networkLatency: Duration.zero,
      );
    });

    tearDown(() => client.close());

    test('same-currency quote has zero total fee and zero flat fee', () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(5000, Currency.usd),
        targetCurrency: Currency.usd,
      );
      // Proves the app shows no fee unless the backend says so.
      expect(q.fee.isZero, isTrue);
      expect(q.feeBreakdown, isNotNull);
      expect(q.feeBreakdown!.flatFee.isZero, isTrue);
      expect(q.feeBreakdown!.totalFee.isZero, isTrue);
      expect(q.exchangeRate, 1.0);
      expect(q.targetAmount, const Money.fromMinor(5000, Currency.usd));
      expect(q.transferType, 'p2p_same_region');
      expect(q.currencyLeg, CurrencyLeg.usdc);
      expect(q.totalCost, const Money.fromMinor(5000, Currency.usd));
    });

    test('cross-currency quote fee equals the flat fee fixture', () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(10000, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      expect(
        q.fee,
        const Money.fromMinor(
            MockTransport.crossBorderFlatFeeUsdFixtureMinor, Currency.usd),
      );
      expect(q.feeBreakdown, isNotNull);
      expect(q.feeBreakdown!.flatFee.minorUnits,
          MockTransport.crossBorderFlatFeeUsdFixtureMinor);
      expect(q.feeBreakdown!.fxSpreadFee.isZero, isTrue);
      expect(q.feeBreakdown!.vendorFee.isZero, isTrue);
      expect(q.feeBreakdown!.totalFee.minorUnits,
          MockTransport.crossBorderFlatFeeUsdFixtureMinor);
      expect(q.totalCost, const Money.fromMinor(10100, Currency.usd));
      expect(q.transferType, 'cross_border');
      expect(q.currencyLeg, CurrencyLeg.cetes);
    });

    test(
        'MXN-source fee is the \$1.00 USD equivalent at the fixture rate, '
        'never \$1.00 MXN', () async {
      // Region-change corridor (MXN wallet -> USD): the backend policy is a
      // \$1.00 USD flat fee. Charged in the source currency at the 19.73
      // fixture rate that is 1973 centavos (\$19.73 MXN) — a literal 100
      // MXN minor units would silently reprice the fee to ~US\$0.05.
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(100000, Currency.mxn),
        targetCurrency: Currency.usd,
      );
      expect(q.fee, const Money.fromMinor(1973, Currency.mxn));
      expect(q.feeBreakdown!.flatFee.minorUnits, 1973);
      expect(q.totalCost, const Money.fromMinor(101973, Currency.mxn));
    });

    test('USDC-source fee is \$1.00 USD in 6-decimal minor units', () async {
      // USDC scales to 6 decimals: \$1.00 = 1_000_000 minor units, not the
      // raw 100 of the USD fixture constant.
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(10000000, Currency.usdc),
        targetCurrency: Currency.mxn,
      );
      expect(q.fee, const Money.fromMinor(1000000, Currency.usdc));
      expect(q.feeBreakdown!.flatFee.minorUnits, 1000000);
    });

    group('reais (mock-priced ahead of the backend)', () {
      test('BRL to BRL is same-region P2P with no fee', () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(5000, Currency.brl),
          targetCurrency: Currency.brl,
        );
        expect(q.fee.isZero, isTrue);
        expect(q.exchangeRate, 1.0);
        expect(q.targetAmount, const Money.fromMinor(5000, Currency.brl));
        expect(q.totalCost, const Money.fromMinor(5000, Currency.brl));
        expect(q.transferType, 'p2p_same_region');
      });

      test('USD to BRL converts at the derived rate for a \$1.00 fee',
          () async {
        // 19.73 / 3.45 reais per dollar: \$100.00 is R\$571.88.
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(10000, Currency.usd),
          targetCurrency: Currency.brl,
        );
        expect(q.targetAmount, const Money.fromMinor(57188, Currency.brl));
        expect(q.fee, const Money.fromMinor(100, Currency.usd));
        expect(q.totalCost, const Money.fromMinor(10100, Currency.usd));
        expect(q.transferType, 'cross_border');
        expect(q.currencyLeg, CurrencyLeg.usdc);
      });

      test('BRL to MXN pays 3.45 pesos per real and charges \$1.00 in reais',
          () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(10000, Currency.brl),
          targetCurrency: Currency.mxn,
        );
        expect(q.targetAmount, const Money.fromMinor(34500, Currency.mxn));
        // \$1.00 USD at 19.73 / 3.45 reais per dollar, floored: R\$5.71.
        expect(q.fee, const Money.fromMinor(571, Currency.brl));
        expect(q.totalCost, const Money.fromMinor(10571, Currency.brl));
        expect(q.currencyLeg, CurrencyLeg.cetes);
      });

      test('MXN to BRL uses the inverse of the same anchor', () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(120000, Currency.mxn),
          targetCurrency: Currency.brl,
        );
        expect(q.targetAmount, const Money.fromMinor(34782, Currency.brl));
        expect(q.fee, const Money.fromMinor(1973, Currency.mxn));
      });
    });

    group('fee-inclusive (a whole balance changing currency)', () {
      // \$12,450.00 MXN — the Pesito demo seed — moving to dollars.
      test('the requested amount is the total and the fee comes out first',
          () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(1245000, Currency.mxn),
          targetCurrency: Currency.usd,
          feeInclusive: true,
        );
        expect(q.totalCost, const Money.fromMinor(1245000, Currency.mxn));
        expect(q.fee, const Money.fromMinor(1973, Currency.mxn));
        expect(q.sourceAmount, const Money.fromMinor(1243027, Currency.mxn));
        // 12,430.27 pesos at 19.73: \$630.01, floored.
        expect(q.targetAmount, const Money.fromMinor(63001, Currency.usd));
        expect(q.transferType, 'cross_border');
      });

      test('into reais the same way', () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(1245000, Currency.mxn),
          targetCurrency: Currency.brl,
          feeInclusive: true,
        );
        expect(q.totalCost, const Money.fromMinor(1245000, Currency.mxn));
        // 12,430.27 pesos at 3.45 per real: R\$3,602.97, floored.
        expect(q.targetAmount, const Money.fromMinor(360297, Currency.brl));
      });

      test('an empty balance pays no fee', () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(0, Currency.mxn),
          targetCurrency: Currency.usd,
          feeInclusive: true,
        );
        expect(q.fee.isZero, isTrue);
        expect(q.totalCost, const Money.fromMinor(0, Currency.mxn));
        expect(q.targetAmount.isZero, isTrue);
      });

      test('a balance below the fee pays all of itself and converts nothing',
          () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(1000, Currency.mxn),
          targetCurrency: Currency.usd,
          feeInclusive: true,
        );
        expect(q.fee, const Money.fromMinor(1000, Currency.mxn));
        expect(q.feeBreakdown!.flatFee.minorUnits, 1000);
        expect(q.totalCost, const Money.fromMinor(1000, Currency.mxn));
        expect(q.sourceAmount.isZero, isTrue);
        expect(q.targetAmount.isZero, isTrue);
      });

      test('same currency has no fee, so the total converts one to one',
          () async {
        final q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(5000, Currency.brl),
          targetCurrency: Currency.brl,
          feeInclusive: true,
        );
        expect(q.totalCost, const Money.fromMinor(5000, Currency.brl));
        expect(q.targetAmount, const Money.fromMinor(5000, Currency.brl));
      });

      test('a server that ignores the flag is refused, not believed', () async {
        final quotes = QuotesResource(_DropsFeeInclusive(MockTransport(
          seed: 3,
          settlementLatency: Duration.zero,
          networkLatency: Duration.zero,
        )));
        await expectLater(
          quotes.create(
            sourceAmount: const Money.fromMinor(1245000, Currency.mxn),
            targetCurrency: Currency.usd,
            feeInclusive: true,
          ),
          throwsA(isA<DecodeException>()
              .having((e) => e.target, 'target', 'Quote.totalCost')),
        );
      });
    });

    test('transfer created from a quote uses the quote amounts verbatim',
        () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(12345, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      final t = await client.transfers.create(
        quoteId: q.id,
        receiverClabe: '012180012345678901',
        receiverName: 'María García López',
      );
      expect(t.sourceAmount, q.sourceAmount);
      expect(t.targetAmount, q.targetAmount);
      expect(t.quoteId, q.id);
      expect(t.transferType, 'cross_border');
      expect(t.feeBreakdown, q.feeBreakdown);
    });

    test('createFromIntent executes a P2P intent with user ids', () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(7000000, Currency.usdc),
        targetCurrency: Currency.usdc,
      );
      final t = await client.transfers.createFromIntent(TransferIntent(
        quoteId: q.id,
        receiverName: 'Ana López',
        senderUserId: 'user_sender',
        receiverUserId: 'user_receiver',
      ));
      expect(t.status, TransferStatus.settled);
      expect(t.sourceAmount, q.sourceAmount);
      expect(t.targetAmount, q.targetAmount);
      expect(t.receiverClabe, isNull);
      expect(t.transferType, 'p2p_same_region');
      // Same-currency P2P: zero fee unless the backend says otherwise.
      expect(t.feeBreakdown!.totalFee.isZero, isTrue);
    });

    test('P2P intent without user ids is rejected 422', () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(1000, Currency.usd),
        targetCurrency: Currency.usd,
      );
      await expectLater(
        () => client.transfers.createFromIntent(TransferIntent(
          quoteId: q.id,
          receiverName: 'Ana',
        )),
        throwsA(isA<ValidationException>()
            .having((e) => e.statusCode, 'statusCode', 422)),
      );
    });

    test('receipt returns a parseable TransferReceipt after settlement',
        () async {
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(10000, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      final t = await client.transfers.create(
        quoteId: q.id,
        receiverClabe: '012180012345678901',
        receiverName: 'María García López',
        memo: 'Para la familia',
      );
      expect(t.status, TransferStatus.settled);

      final r = await client.transfers.receipt(t.id);
      expect(r.transactionId, t.id);
      expect(r.status, TransferStatus.settled);
      expect(r.transferType, 'cross_border');
      expect(r.currencyLeg, CurrencyLeg.cetes);
      expect(r.sourceAmount, q.sourceAmount);
      expect(r.targetAmount, q.targetAmount);
      expect(r.fxRate, '19.73');
      expect(r.feeBreakdown, q.feeBreakdown);
      expect(r.vendorCosts, isNotNull);
      expect(r.vendorCosts!.etherfuse.isZero, isTrue);
      expect(r.vendorCosts!.network.isZero, isTrue);
      expect(r.vendorCosts!.other.isZero, isTrue);
      expect(r.memo, 'Para la familia');
      expect(r.receiverName, 'María García López');
      expect(r.reference, 'SPEI-MOCK');
      expect(r.settledAt.isUtc, isTrue);
      // Deterministic cNFT fixture.
      expect(r.cnft, isNotNull);
      expect(r.cnft!.folio, startsWith('PES-'));
      expect(r.cnft!.metadataUri, 'mock://receipts/${t.id}');
      expect(r.cnft!.assetId, isNull);
      expect(r.cnft!.mintSignature, isNull);
    });

    test('receipt is a 409-shaped error before settlement', () async {
      client.close();
      client = PuenteClient.mock(
        seed: 4,
        settlementLatency: const Duration(seconds: 30),
        networkLatency: Duration.zero,
      );
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(10000, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      final t = await client.transfers.create(
        quoteId: q.id,
        receiverClabe: '012180012345678901',
        receiverName: 'María García López',
      );
      expect(t.status, TransferStatus.pending);

      await expectLater(
        () => client.transfers.receipt(t.id),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', startsWith('receipt_unavailable'))),
      );
    });

    test('unknown quote_id is a 404-shaped ApiException', () async {
      await expectLater(
        () => client.transfers.create(
          quoteId: 'qt_does_not_exist',
          receiverClabe: '012180012345678901',
          receiverName: 'María García López',
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.code, 'code', 'quote_not_found')),
      );
    });

    test('expired quote is rejected with 409 quote_expired', () async {
      final t0 = DateTime.utc(2026, 7, 1, 12);
      late final Quote q;
      await withClock(Clock.fixed(t0), () async {
        q = await client.quotes.create(
          sourceAmount: const Money.fromMinor(10000, Currency.usd),
          targetCurrency: Currency.mxn,
        );
      });
      // Mock quotes live 2 minutes; three minutes later the quote is dead.
      await withClock(Clock.fixed(t0.add(const Duration(minutes: 3))),
          () async {
        // Server-emitted 409 quote_expired now maps to the same typed
        // exception the client-side createFromQuote guard raises, so
        // callers only need one catch — see resource_base.dart mapping.
        await expectLater(
          () => client.transfers.create(
            quoteId: q.id,
            receiverClabe: '012180012345678901',
            receiverName: 'María García López',
          ),
          throwsA(isA<StaleQuoteException>()
              .having((e) => e.serverEmitted, 'serverEmitted', true)),
        );
      });
    });
  });
}

/// A backend from before fee-inclusive pricing: axum drops the unknown
/// `fee_inclusive` key, so the quote comes back with the fee on top.
class _DropsFeeInclusive implements PuenteTransport {
  _DropsFeeInclusive(this._inner);

  final PuenteTransport _inner;

  @override
  Future<PuenteResponse> send(PuenteRequest request) {
    final body = request.body;
    if (body is! Map<String, dynamic>) return _inner.send(request);
    return _inner.send(request.copyWith(
      body: Map<String, dynamic>.of(body)..remove('fee_inclusive'),
    ));
  }

  @override
  void close() => _inner.close();
}
