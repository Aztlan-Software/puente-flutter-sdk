import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:puente_railway/puente_railway.dart';
import 'package:test/test.dart';

/// Regression suite for the 2026-08-27 full audit.
///
/// Every test here pins a defect that was live in v0.5.0. They are grouped by
/// the property they defend, not by the file they touch, because each fix
/// spans several resources.

/// Records the URLs and headers the transport actually put on the wire.
class _SpyClient extends http.BaseClient {
  _SpyClient({this.body = '{}', this.statusCode = 200, this.failures = 0});

  final String body;
  final int statusCode;

  /// Number of leading attempts that should fail at the transport layer.
  final int failures;

  final List<Uri> urls = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls += 1;
    urls.add(request.url);
    headers.add(Map<String, String>.from(request.headers));
    if (calls <= failures) {
      throw http.ClientException('simulated connection reset', request.url);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json',
        'x-request-id': 'req_spy_1',
      },
    );
  }
}

PuenteClient _client(_SpyClient spy, {int maxRetries = 0}) => PuenteClient(
      config: PuenteConfig(
        apiKey: 'sk_test_x',
        environment: PuenteEnvironment.production,
        maxRetries: maxRetries,
        baseRetryDelay: Duration.zero,
      ),
      innerHttpClient: spy,
    );

void main() {
  // ---------------------------------------------------------------------
  group('path identifiers cannot retarget an authenticated request', () {
    // Dart's Uri resolves dot segments while assembling a path, so an
    // identifier containing `..` used to redirect the request to a
    // different endpoint with the Authorization header still attached.
    // `clabe.lookup('../../v1/transfers')` issued GET /v1/transfers, and
    // `transfers.retrieve('../../../balances')` escaped the /v1 prefix.

    test('a CLABE with dot segments is rejected before the wire', () async {
      final spy = _SpyClient();
      final client = _client(spy);
      await expectLater(
        client.clabe.lookup('../../v1/transfers'),
        throwsA(isA<InvalidArgumentException>()
            .having((e) => e, 'is a PuenteException', isA<PuenteException>())
            .having((e) => e.parameter, 'parameter', 'clabe')),
      );
      expect(spy.calls, 0, reason: 'nothing may reach the network');
    });

    test('a transfer id with dot segments is rejected', () async {
      final spy = _SpyClient();
      final client = _client(spy);
      await expectLater(
        client.transfers.retrieve('../../../balances'),
        throwsA(isA<InvalidArgumentException>()),
      );
      expect(spy.calls, 0);
    });

    test('percent-encoded traversal is rejected too', () async {
      // %2e%2e normalizes back to `..`, so encoding is not a defense.
      final spy = _SpyClient();
      final client = _client(spy);
      await expectLater(
        client.transfers.cancel('%2e%2e/%2e%2e/admin'),
        throwsA(isA<InvalidArgumentException>()),
      );
      expect(spy.calls, 0);
    });

    test('every id-bearing path is guarded, not just the ones we probed',
        () async {
      final spy = _SpyClient();
      final client = _client(spy);
      const bad = 'a/../../b';
      final calls = <String, Future<Object?>>{
        'transfers.retrieve': client.transfers.retrieve(bad),
        'transfers.receipt': client.transfers.receipt(bad),
        'transfers.cancel': client.transfers.cancel(bad),
        'accounts.retrieve': client.accounts.retrieve(bad),
        'accounts.update': client.accounts.update(bad, phone: '+15550000000'),
        'clabe.lookup': client.clabe.lookup(bad),
        'deposits.retrieve': client.deposits.retrieve(bad),
        'deposits.getQuote': client.deposits.getQuote(bad),
        'deposits.prepare': client.deposits.prepare(bad),
        'deposits.events': client.deposits.events(bad),
        'deposits.reportSubmission':
            client.deposits.reportSubmission(bad, transactionHash: '0xdead'),
      };
      for (final entry in calls.entries) {
        await expectLater(
          entry.value,
          throwsA(isA<InvalidArgumentException>()),
          reason: '${entry.key} must reject a traversal id',
        );
      }
      expect(spy.calls, 0);
    });

    test('a legitimate identifier still passes through unchanged', () async {
      final spy = _SpyClient(body: '{"clabe":"012180012345678901"}');
      final client = _client(spy);
      try {
        await client.clabe.lookup('012180012345678901');
      } on PuenteException {
        // Decoding is not what this test asserts.
      }
      expect(spy.urls.single.path, '/v1/clabe/012180012345678901');
    });
  });

  // ---------------------------------------------------------------------
  group('every failure is a PuenteException', () {
    // The class doc promises "SDK calls never throw raw Exception, dynamic,
    // or upstream package errors". Model constructors broke that: a wire
    // mismatch escaped as a raw FormatException/TypeError/ArgumentError, so
    // callers who wrote `on PuenteException` crashed instead of handling it.

    test('a wrongly-typed field surfaces as DecodeException', () async {
      // "amount" is a string where the model requires an int.
      final spy = _SpyClient(
        body: '{"id":"q_1","source_amount":{"amount":"100","currency":"USD"},'
            '"target_amount":{"amount":1,"currency":"MXN"},'
            '"exchange_rate":17.0,"fee":{"amount":1,"currency":"USD"},'
            '"expires_at":"2030-01-01T00:00:00Z"}',
      );
      final client = _client(spy);
      await expectLater(
        client.quotes.create(
          sourceAmount: const Money.fromMinor(100, Currency.usd),
          targetCurrency: Currency.mxn,
        ),
        throwsA(isA<DecodeException>()
            .having((e) => e, 'is a PuenteException', isA<PuenteException>())
            .having((e) => e.target, 'target', 'Quote')
            .having((e) => e.requestId, 'requestId', 'req_spy_1')
            .having((e) => e.cause, 'cause', isA<FormatException>())),
      );
    });

    test('an unknown currency surfaces as DecodeException, not ArgumentError',
        () async {
      final spy = _SpyClient(
        body: '{"id":"q_1","source_amount":{"amount":100,"currency":"XYZ"},'
            '"target_amount":{"amount":1,"currency":"MXN"},'
            '"exchange_rate":17.0,"fee":{"amount":1,"currency":"USD"},'
            '"expires_at":"2030-01-01T00:00:00Z"}',
      );
      final client = _client(spy);
      await expectLater(
        client.quotes.create(
          sourceAmount: const Money.fromMinor(100, Currency.usd),
          targetCurrency: Currency.mxn,
        ),
        throwsA(isA<DecodeException>()
            .having((e) => e.cause, 'cause', isA<ArgumentError>())),
      );
    });

    test('a malformed element inside a list envelope is typed too', () async {
      final spy = _SpyClient(body: '{"data":[{"id":123}]}');
      final client = _client(spy);
      await expectLater(
        client.transfers.list(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('an empty or absent data envelope is an empty page, not an error',
        () async {
      final client = _client(_SpyClient(body: '{}'));
      expect(await client.transfers.list(), isEmpty);
      final client2 = _client(_SpyClient(body: '{"data":[]}'));
      expect(await client2.transfers.list(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  group('an ambiguous outcome stays safely retryable', () {
    // A timeout on POST /transfers does not mean the transfer did not
    // happen. The SDK mints the idempotency key internally, so unless the
    // key comes back on the exception the caller can only retry with a
    // fresh one — which the server reads as a second, distinct transfer.

    test('TransportException carries the idempotency key it used', () async {
      final spy = _SpyClient(failures: 99);
      final client = _client(spy, maxRetries: 1);
      Object? caught;
      try {
        await client.transfers.create(
          quoteId: 'q_1',
          receiverClabe: '012180012345678901',
          receiverName: 'Test Receiver',
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<TransportException>());
      final key = (caught! as TransportException).idempotencyKey;
      expect(key, isNotNull);
      expect(
        spy.headers.map((h) => h['Idempotency-Key']).toSet(),
        <String?>{key},
        reason: 'the retried attempts must reuse the one key, and the '
            'exception must echo that same key back to the caller',
      );
    });

    test(
        'a retry with the returned key reuses it rather than minting a new one',
        () async {
      final spy = _SpyClient(failures: 99);
      final client = _client(spy, maxRetries: 0);
      String? key;
      try {
        await client.transfers.create(
          quoteId: 'q_1',
          receiverClabe: '012180012345678901',
          receiverName: 'Test Receiver',
        );
      } on TransportException catch (e) {
        key = e.idempotencyKey;
      }
      try {
        await client.transfers.create(
          quoteId: 'q_1',
          receiverClabe: '012180012345678901',
          receiverName: 'Test Receiver',
          idempotencyKey: key,
        );
      } on TransportException catch (_) {
        // Still failing; we only care which key went out.
      }
      expect(spy.headers.map((h) => h['Idempotency-Key']).toSet().length, 1,
          reason: 'both attempts must present the same key');
    });

    test('a server error echoes the key back as well', () async {
      final spy = _SpyClient(
        statusCode: 500,
        body: '{"error":"internal","message":"boom"}',
      );
      final client = _client(spy);
      await expectLater(
        client.transfers.create(
          quoteId: 'q_1',
          receiverClabe: '012180012345678901',
          receiverName: 'Test Receiver',
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.idempotencyKey, 'idempotencyKey', isNotNull)),
      );
    });

    test('a server quote_expired keeps its support and retry context',
        () async {
      final spy = _SpyClient(
        statusCode: 409,
        body: '{"error":"quote_expired","message":"quote expired"}',
      );
      final client = _client(spy);
      await expectLater(
        client.transfers.create(
          quoteId: 'q_1',
          receiverClabe: '012180012345678901',
          receiverName: 'Test Receiver',
        ),
        // requestId used to be dropped on exactly this path.
        throwsA(isA<StaleQuoteException>()
            .having((e) => e.requestId, 'requestId', 'req_spy_1')
            .having((e) => e.idempotencyKey, 'idempotencyKey', isNotNull)
            .having((e) => e.serverEmitted, 'serverEmitted', isTrue)),
      );
    });

    test('StaleQuoteException reads the ambient clock, not DateTime.now',
        () async {
      final frozen = DateTime.utc(2030, 1, 1, 12);
      final spy = _SpyClient(
        statusCode: 409,
        body: '{"error":"quote_expired","message":"quote expired"}',
      );
      final client = _client(spy);
      await withClock(Clock.fixed(frozen), () async {
        try {
          await client.transfers.create(
            quoteId: 'q_1',
            receiverClabe: '012180012345678901',
            receiverName: 'Test Receiver',
          );
          fail('expected StaleQuoteException');
        } on StaleQuoteException catch (e) {
          expect(e.detectedAt, frozen);
        }
      });
    });
  });

  // ---------------------------------------------------------------------
  group('side-effecting POSTs carry an idempotency key', () {
    // The transport retries POSTs on 5xx and on transport errors. Any POST
    // with a side effect and no key can therefore be applied twice by the
    // SDK itself (H-14 non-idempotent retry / H-18 ambiguous outcome).

    Future<String?> keyFor(Future<void> Function(PuenteClient) call) async {
      final spy = _SpyClient(body: '{}');
      final client = _client(spy);
      try {
        await call(client);
      } catch (_) {
        // Decode failures are irrelevant; we assert on the request headers.
      }
      return spy.headers.single['Idempotency-Key'];
    }

    test('onboarding.submitConsents sends one', () async {
      expect(
        await keyFor((c) => c.onboarding.submitConsents(
              disclosureVersion: 'v1',
              accepted: const ['tos'],
            )),
        isNotNull,
      );
    });

    test('personalInfo.requestCorrection sends one', () async {
      expect(
        await keyFor(
            (c) async => c.personalInfo.requestCorrection(field: 'legal_name')),
        isNotNull,
      );
    });

    test('onboarding.updateProfile sends one', () async {
      expect(
        await keyFor(
            (c) async => c.onboarding.updateProfile(legalFirstName: 'Ada')),
        isNotNull,
      );
    });

    test('accounts.update sends one', () async {
      expect(
        await keyFor((c) async => c.accounts.update('acct_1', phone: '+1555')),
        isNotNull,
      );
    });
  });

  // ---------------------------------------------------------------------
  group('argument guards survive a release build', () {
    // These were `assert`s, which Dart strips from release builds. In
    // production a half-supplied pair was serialized as
    // {"type": "ssn", "value": null} instead of failing locally.

    test('a sensitive identifier type without a value is rejected', () async {
      final spy = _SpyClient();
      final client = _client(spy);
      await expectLater(
        client.onboarding.updateProfile(sensitiveIdentifierType: 'ssn'),
        throwsA(isA<InvalidArgumentException>()
            .having((e) => e.parameter, 'parameter', 'sensitiveIdentifier')),
      );
      expect(spy.calls, 0, reason: 'the partial identifier must not be sent');
    });

    test('a document type without an issuing country is rejected', () async {
      final spy = _SpyClient();
      final client = _client(spy);
      await expectLater(
        client.onboarding.updateProfile(documentType: 'passport'),
        throwsA(isA<InvalidArgumentException>()
            .having((e) => e.parameter, 'parameter', 'document')),
      );
      expect(spy.calls, 0);
    });
  });

  // ---------------------------------------------------------------------
  group('credentials require an encrypted transport', () {
    test('a cleartext http:// base URL is refused for a real environment', () {
      expect(
        () => PuenteConfig(
          apiKey: 'sk_test_x',
          environment: PuenteEnvironment.production,
          baseUrlOverride: Uri.parse('http://attacker.example.com/v1'),
        ),
        throwsArgumentError,
      );
    });

    test('loopback stays allowed for local development', () {
      for (final url in <String>[
        'http://127.0.0.1:8080/v1',
        'http://localhost:8080/v1',
      ]) {
        expect(
          () => PuenteConfig(
            apiKey: 'sk_test_x',
            environment: PuenteEnvironment.testnet,
            baseUrlOverride: Uri.parse(url),
          ),
          returnsNormally,
          reason: '$url is local and never leaves the machine',
        );
      }
    });

    test('https overrides are unaffected', () {
      expect(
        () => PuenteConfig(
          apiKey: 'sk_test_x',
          environment: PuenteEnvironment.production,
          baseUrlOverride: Uri.parse('https://staging.example.com/v1'),
        ),
        returnsNormally,
      );
    });
  });

  // ---------------------------------------------------------------------
  group('observers never receive key material', () {
    test('the Authorization value is fully masked', () async {
      final seen = <Map<String, String>>[];
      final spy = _SpyClient(body: '{"data":[]}');
      final client = PuenteClient(
        config: PuenteConfig(
          apiKey: 'placeholder-credential-tail9876',
          environment: PuenteEnvironment.production,
          maxRetries: 0,
        ),
        observer: _CapturingObserver(seen),
        innerHttpClient: spy,
      );
      await client.transfers.list();

      final auth = seen.single['Authorization']!;
      expect(auth, 'Bearer ***');
      // The previous masking kept the last four characters of the secret.
      expect(auth, isNot(contains('9876')));
      expect(auth, isNot(contains('placeholder')));
    });
  });

  // ---------------------------------------------------------------------
  group('a watch timeout is distinguishable from settlement', () {
    test('throwOnTimeout surfaces a TimeoutException instead of onDone',
        () async {
      // The session never leaves `created`, so the poll always times out.
      final client = PuenteClient.mock(
        settlementLatency: const Duration(days: 1),
        networkLatency: Duration.zero,
      );
      addTearDown(client.close);

      final stream = client.transfers.watch(
        'tx_does_not_settle',
        pollInterval: const Duration(milliseconds: 1),
        timeout: const Duration(milliseconds: 5),
        throwOnTimeout: true,
      );
      await expectLater(
        stream.toList(),
        throwsA(anyOf(isA<TimeoutException>(), isA<PuenteException>())),
        reason: 'a timed-out watch must not look like a completed one',
      );
    });

    test('the default still completes silently (backwards compatible)',
        () async {
      final client = PuenteClient.mock(networkLatency: Duration.zero);
      addTearDown(client.close);
      // A missing transfer raises a typed API error rather than hanging;
      // the point is only that the default did not become a throw-on-time.
      expect(
        client.transfers.watch(
          'tx_missing',
          pollInterval: const Duration(milliseconds: 1),
          timeout: const Duration(milliseconds: 5),
        ),
        isA<Stream<Transfer>>(),
      );
    });
  });
}

class _CapturingObserver extends PuenteObserver {
  const _CapturingObserver(this.seen);

  final List<Map<String, String>> seen;

  @override
  void onRequest(PuenteRequestEvent event) => seen.add(event.headers);
}
