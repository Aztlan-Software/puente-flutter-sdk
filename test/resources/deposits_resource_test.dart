import 'package:clock/clock.dart';
import 'package:puente_railway/puente_railway.dart';
import 'package:puente_railway/testing.dart';
import 'package:test/test.dart';

/// A transport that answers every request with one canned response —
/// used to prove malformed server output surfaces as a typed exception.
class _StaticTransport implements PuenteTransport {
  final PuenteResponse response;
  _StaticTransport(this.response);

  @override
  Future<PuenteResponse> send(PuenteRequest request) async => response;

  @override
  void close() {}
}

void main() {
  group('DepositsResource flow (mock backend)', () {
    late PuenteClient client;

    setUp(() {
      client = PuenteClient.mock(
        seed: 7,
        settlementLatency: Duration.zero,
        networkLatency: Duration.zero,
      );
    });

    tearDown(() => client.close());

    Future<DepositSession> createSession({String userId = 'usr_flow'}) async {
      final assets = await client.deposits.getSupportedAssets();
      final asset = assets.firstWhere((a) => a.network == 'base');
      return client.deposits.createSession(
        userId: userId,
        sourceNetwork: asset.network,
        sourceAssetId: asset.id,
        sourceWalletAddress: '0x1111111111111111111111111111111111111111',
        sourceAmountMinor: 100000000, // 100 USDC (6 decimals)
      );
    }

    test('create → quote → prepare → submit → settle_finalized → credited',
        () async {
      final assets = await client.deposits.getSupportedAssets();
      expect(assets, hasLength(2));
      expect(assets.every((a) => a.enabled), isTrue);
      expect(assets.map((a) => a.network), containsAll(['base', 'ethereum']));

      final session = await createSession();
      expect(session.id, startsWith('dep_'));
      expect(session.status, DepositStatus.created);
      expect(session.provider, 'mock');
      expect(session.riskStatus, 'none');
      expect(session.destinationNetwork, 'solana');
      expect(session.destinationMint, MockTransport.depositUsdcMintFixture);
      expect(session.destinationAddress, isNotNull);
      expect(session.quote, isNull);

      final quoted = await client.deposits.getQuote(session.id);
      expect(quoted.status, DepositStatus.quoted);
      final quote = quoted.quote!;
      // Integer passthrough of the mock's fixture policy — the SDK does
      // NO math; these pins prove the wire values arrive verbatim.
      // Fixture math mirrors the backend mock: 0.4% service + $0.18 gas.
      const fixtureFees =
          100000000 * MockTransport.depositServiceFeeBpsFixture ~/ 10000 +
              MockTransport.depositGasFeeUsdcFixtureMinor;
      expect(quote.sourceAmountMinor, 100000000);
      expect(quote.expectedDestinationMinor, 100000000 - fixtureFees);
      expect(
          quote.minimumDestinationMinor, (100000000 - fixtureFees) * 99 ~/ 100);
      expect(quote.fees, hasLength(2));
      expect(quote.display!.fxType, 'indicative');
      expect(quoted.expectedDestinationMinor, quote.expectedDestinationMinor);

      final prepared = await client.deposits.prepare(session.id);
      expect(prepared.session.status, DepositStatus.prepared);
      expect(prepared.providerRouteId, isNotNull);
      expect(prepared.providerRouteId, isNotEmpty);
      expect(prepared.spender, MockTransport.depositSpenderFixture);
      final approval = prepared.approval;
      expect(approval, isA<EvmErc20ApprovalSigningRequest>());
      final erc20 = approval as EvmErc20ApprovalSigningRequest;
      expect(erc20.spender, prepared.spender);
      expect(erc20.amountMinor, '100000000'); // exact-amount, never unlimited
      expect(erc20.chainId, 8453);
      expect(prepared.transaction, isA<EvmTransactionSigningRequest>());

      final submitted = await client.deposits.reportSubmission(
        session.id,
        transactionHash: '0xabc123',
      );
      // Mirrors the real backend: nothing settles on its own — the
      // session stays `submitted` until the mock-events driver advances
      // it (smoke.sh precedent).
      expect(submitted.status, DepositStatus.submitted);
      expect(submitted.sourceTxHash, '0xabc123');

      final credited =
          await client.deposits.sendMockEvent(session.id, 'settle_finalized');
      expect(credited.status, DepositStatus.credited);
      expect(credited.actualDestinationMinor, quote.expectedDestinationMinor);
      expect(credited.creditedAt, isNotNull);
      expect(credited.destinationTxSignature, isNotNull);
      expect(credited.ledgerTransactionId, isNotNull);
      expect(credited.destinationEventIndex, 0);

      final seen = await client.deposits
          .watch(
            session.id,
            pollInterval: const Duration(milliseconds: 5),
            timeout: const Duration(seconds: 2),
          )
          .toList();
      expect(seen, isNotEmpty);
      expect(seen.last.status, DepositStatus.credited);
      expect(seen.last.status.isTerminal, isTrue);

      // Events mirror the backend: the first recorded event is
      // created → quoted (no creation event).
      final events = await client.deposits.events(session.id);
      expect(events.first.fromStatus, DepositStatus.created);
      expect(events.first.toStatus, DepositStatus.quoted);
      expect(
        events.map((e) => e.toStatus).toList(),
        containsAllInOrder(const [
          DepositStatus.quoted,
          DepositStatus.prepared,
          DepositStatus.submitted,
          DepositStatus.destinationDetected,
          DepositStatus.credited,
        ]),
      );
    });

    test('re-quote is legal until prepared and replaces the quote', () async {
      final session = await createSession(userId: 'usr_requote');
      final first = await client.deposits.getQuote(session.id);
      final second = await client.deposits.getQuote(session.id);
      expect(second.status, DepositStatus.quoted);
      expect(second.quote, isNotNull);
      expect(second.quote!.expiresAt.isBefore(first.quote!.expiresAt), isFalse);
    });

    test('compliance_hold holds the credit, releases, then credits', () async {
      final session = await createSession(userId: 'usr_hold');
      await client.deposits.getQuote(session.id);
      await client.deposits.prepare(session.id);
      await client.deposits.sendMockEvent(session.id, 'submitted');
      await client.deposits.sendMockEvent(session.id, 'settle');

      final held =
          await client.deposits.sendMockEvent(session.id, 'compliance_hold');
      expect(held.status, DepositStatus.complianceHold);
      expect(held.riskStatus, 'hold');
      expect(held.ledgerTransactionId, isNull);
      // A hold is NOT terminal — watch keeps polling through it.
      expect(held.status.isTerminal, isFalse);

      // Mirrors the backend: releasing only flips risk_status; the status
      // stays compliance_hold until an explicit credit posts the ledger
      // credit.
      final released =
          await client.deposits.sendMockEvent(session.id, 'compliance_release');
      expect(released.status, DepositStatus.complianceHold);
      expect(released.riskStatus, 'released');

      final credited =
          await client.deposits.sendMockEvent(session.id, 'credit');
      expect(credited.status, DepositStatus.credited);
      expect(credited.creditedAt, isNotNull);
      expect(credited.ledgerTransactionId, isNotNull);

      final events = await client.deposits.events(session.id);
      expect(
        events.map((e) => e.toStatus).toList(),
        containsAllInOrder(const [
          DepositStatus.complianceHold,
          DepositStatus.credited,
        ]),
      );
    });

    test('watch streams distinct states through a mock-event progression',
        () async {
      final session = await createSession(userId: 'usr_watch');
      await client.deposits.getQuote(session.id);
      await client.deposits.prepare(session.id);

      final statuses = <DepositStatus>[];
      final done = client.deposits
          .watch(
            session.id,
            pollInterval: const Duration(milliseconds: 10),
            timeout: const Duration(seconds: 5),
          )
          .forEach((s) => statuses.add(s.status));

      for (final scenario in const [
        'submitted',
        'routing',
        'settle',
        'compliance_hold',
        'compliance_release', // risk released; status stays compliance_hold
        'credit',
      ]) {
        await client.deposits.sendMockEvent(session.id, scenario);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await done;

      expect(statuses.last, DepositStatus.credited);
      expect(statuses, contains(DepositStatus.complianceHold));
      // Each yielded state is distinct from its predecessor.
      for (var i = 1; i < statuses.length; i++) {
        expect(statuses[i], isNot(statuses[i - 1]));
      }
    });

    test('expired quote → prepare throws StaleQuoteException; re-quote heals',
        () async {
      final t0 = DateTime.utc(2026, 7, 17, 12);
      late String id;
      await withClock(Clock.fixed(t0), () async {
        final session = await createSession(userId: 'usr_expiry');
        id = session.id;
        final quoted = await client.deposits.getQuote(id);
        expect(quoted.quote!.isExpired(t0), isFalse);
      });
      // 5 minutes later the 2-minute fixture TTL has lapsed.
      await withClock(Clock.fixed(t0.add(const Duration(minutes: 5))),
          () async {
        await expectLater(
          client.deposits.prepare(id),
          throwsA(isA<StaleQuoteException>()),
        );
        // The session is still quotable — re-quote and prepare succeed.
        await client.deposits.getQuote(id);
        final prepared = await client.deposits.prepare(id);
        expect(prepared.session.status, DepositStatus.prepared);
      });
    });

    test('route_failed mock scenario is a terminal failure for watch',
        () async {
      final session = await createSession(userId: 'usr_rfail');
      await client.deposits.getQuote(session.id);
      await client.deposits.prepare(session.id);
      await client.deposits.sendMockEvent(session.id, 'submitted');
      final failed =
          await client.deposits.sendMockEvent(session.id, 'route_failed');
      expect(failed.status, DepositStatus.routeFailed);
      expect(failed.status.isTerminal, isTrue);
      expect(failed.failureCode, 'route_failed');

      final seen = await client.deposits
          .watch(
            session.id,
            pollInterval: const Duration(milliseconds: 5),
            timeout: const Duration(seconds: 2),
          )
          .toList();
      expect(seen.last.status, DepositStatus.routeFailed);
    });

    test('list filters by user and pages newest first', () async {
      final a = await createSession(userId: 'usr_list');
      final b = await createSession(userId: 'usr_list');
      await createSession(userId: 'usr_other');

      final mine = await client.deposits.list(userId: 'usr_list');
      expect(mine, hasLength(2));
      expect(mine.map((s) => s.id), containsAll([a.id, b.id]));

      final firstPage =
          await client.deposits.list(userId: 'usr_list', limit: 1);
      expect(firstPage, hasLength(1));
      final secondPage = await client.deposits.list(
          userId: 'usr_list', limit: 1, startingAfter: firstPage.first.id);
      expect(secondPage, hasLength(1));
      expect(secondPage.first.id, isNot(firstPage.first.id));
    });

    test('same user gets the same deposit address across sessions', () async {
      final first = await createSession(userId: 'usr_addr');
      final second = await createSession(userId: 'usr_addr');
      final other = await createSession(userId: 'usr_addr2');
      expect(first.destinationAddress, second.destinationAddress);
      expect(first.destinationAddress, isNot(other.destinationAddress));
    });
  });

  group('DepositsResource malformed responses', () {
    // These used to assert a raw `FormatException` escaped the SDK. That
    // contradicted the documented contract on PuenteException ("SDK calls
    // never throw raw Exception ... or upstream package errors"), so a
    // caller who wrote `on PuenteException` crashed on any backend wire
    // change. The decode failure is now a DecodeException, which IS a
    // PuenteException — and still exposes the underlying error as `cause`.
    test('non-session 200 body throws DecodeException, not a raw error',
        () async {
      final resource = DepositsResource(_StaticTransport(const PuenteResponse(
        statusCode: 200,
        headers: <String, String>{'content-type': 'application/json'},
        body: '{"unexpected": true}',
      )));
      await expectLater(
        resource.retrieve('dep_x'),
        throwsA(isA<DecodeException>()
            .having((e) => e, 'is a PuenteException', isA<PuenteException>())
            .having((e) => e.target, 'target', 'DepositSession')
            .having((e) => e.cause, 'cause', isA<FormatException>())),
      );
    });

    test('prepare response without a transaction throws DecodeException',
        () async {
      final resource = DepositsResource(_StaticTransport(const PuenteResponse(
        statusCode: 200,
        headers: <String, String>{'content-type': 'application/json'},
        body: '{"id":"dep_x","status":"prepared","source_amount_minor":1,'
            '"created_at":"2026-07-17T12:00:00.000Z"}',
      )));
      await expectLater(
        resource.prepare('dep_x'),
        throwsA(isA<DecodeException>()
            .having((e) => e, 'is a PuenteException', isA<PuenteException>())
            .having((e) => e.target, 'target', 'PreparedDeposit')
            // A prepare failure must carry the key back: the POST may have
            // taken effect server-side even though the body did not decode.
            .having((e) => e.idempotencyKey, 'idempotencyKey', isNotNull)),
      );
    });
  });

  group('DepositsResource.deriveHopKey', () {
    test('derives stable per-hop keys from one base key', () {
      expect(DepositsResource.deriveHopKey('gesture-1', 'quote'),
          'gesture-1:quote');
      expect(DepositsResource.deriveHopKey('gesture-1', 'prepare'),
          'gesture-1:prepare');
    });
  });
}
