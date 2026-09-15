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
      // $100 at 1% = exactly the $1.00 corridor cap.
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

    test('USD-source fee is 1% of the amount below the \$1 cap', () async {
      // $50 at 1% = $0.50 — under the cap, the percentage applies.
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(5000, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      expect(q.fee, const Money.fromMinor(50, Currency.usd));
      expect(q.totalCost, const Money.fromMinor(5050, Currency.usd));
    });

    test('USD-source fee caps at \$1.00 for large amounts', () async {
      // $10,000 at 1% would be $100 — the corridor cap holds it to $1.
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(1000000, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      expect(
          q.fee,
          const Money.fromMinor(
              MockTransport.crossBorderFlatFeeUsdFixtureMinor, Currency.usd));
    });

    test('fee computation survives absurdly large amounts without overflow',
        () async {
      // ~$90T: far above the cap's break-even, close enough to 2^63 that
      // naive amount*rate math would wrap. The fixture must still return
      // exactly the cap and keep every emitted field non-negative.
      final q = await client.quotes.create(
        sourceAmount: const Money.fromMinor(9007199254740992, Currency.usd),
        targetCurrency: Currency.mxn,
      );
      expect(
          q.fee,
          const Money.fromMinor(
              MockTransport.crossBorderFlatFeeUsdFixtureMinor, Currency.usd));
      expect(q.totalCost!.minorUnits, greaterThan(0));
      expect(q.targetAmount.minorUnits, greaterThan(0));
    });

    test(
        'MXN-source fee is 1% up to the \$15.00 MXN cap, '
        'denominated in MXN', () async {
      // Region-change corridor (MXN wallet -> USD). The MXN-source cap is
      // $15.00 MXN (1500 centavos) in the SOURCE currency — never a
      // fixture-rate conversion, never $15 USD.
      final belowCap = await client.quotes.create(
        sourceAmount: const Money.fromMinor(100000, Currency.mxn),
        targetCurrency: Currency.usd,
      );
      // $1000 MXN at 1% = $10.00 MXN — under the cap.
      expect(belowCap.fee, const Money.fromMinor(1000, Currency.mxn));
      expect(belowCap.totalCost,
          const Money.fromMinor(101000, Currency.mxn));

      final atCap = await client.quotes.create(
        sourceAmount: const Money.fromMinor(500000, Currency.mxn),
        targetCurrency: Currency.usd,
      );
      // $5000 MXN would be $50 at 1% — the cap holds it to $15.00 MXN.
      expect(atCap.fee,
          const Money.fromMinor(MockTransport.remittanceCapMxnFixtureMinor,
              Currency.mxn));
    });

    test('USDC-source fee is 1% below, then capped in 6-decimal minor units',
        () async {
      // 10 USDC at 1% = 0.10 USDC = 100_000 minor units (6dp) — under the
      // $1.00 cap, which on this source is 1_000_000 minor units.
      final small = await client.quotes.create(
        sourceAmount: const Money.fromMinor(10000000, Currency.usdc),
        targetCurrency: Currency.mxn,
      );
      expect(small.fee, const Money.fromMinor(100000, Currency.usdc));

      final big = await client.quotes.create(
        sourceAmount: const Money.fromMinor(500000000, Currency.usdc),
        targetCurrency: Currency.mxn,
      );
      // 500 USDC would be 5 USDC at 1% — capped at $1.00 = 1_000_000.
      expect(big.fee, const Money.fromMinor(1000000, Currency.usdc));
      expect(big.feeBreakdown!.flatFee.minorUnits, 1000000);
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
