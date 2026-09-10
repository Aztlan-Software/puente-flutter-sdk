import 'dart:async';

import 'package:clock/clock.dart';

import '../models/deposit_event.dart';
import '../models/deposit_session.dart';
import '../models/deposit_status.dart';
import '../models/prepared_deposit.dart';
import '../models/supported_deposit_asset.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// External-wallet deposits (`/v1/deposit-assets`, `/v1/deposit-sessions`,
/// `/v1/deposits`) — a user deposits a supported stablecoin from their own
/// wallet; Puente routes it to native Circle USDC on Solana at a
/// user-specific deposit address, verifies settlement independently, and
/// credits the ledger exactly once.
///
/// ## Authority model
///
/// The client renders backend state and hands signing requests to the
/// external wallet — it is never the financial source of truth. All
/// amounts are integer minor units passed through verbatim; the SDK
/// computes no fees, FX, or slippage.
///
/// ## Idempotency
///
/// Every POST carries an `Idempotency-Key`; the SDK generates a UUIDv4
/// when the caller doesn't pass one. A caller orchestrating the whole
/// flow from one user gesture should derive per-hop keys from a single
/// base key via [deriveHopKey] (`'$key:quote'`, `'$key:prepare'`,
/// `'$key:submission'`) so retries of each hop replay instead of
/// duplicating.
///
/// ## Error mapping (stable snake_case codes)
///
/// * `409 quote_expired` → [StaleQuoteException] — re-quote and retry.
/// * Everything else (`unsupported_asset`, `deposits_disabled`,
///   `capability_unavailable`, `deposit_not_found`, `illegal_state`,
///   `quote_required`, `amount_below_minimum`, `amount_above_maximum`,
///   `unsupported_network`, `route_unavailable`, `provider_unavailable`,
///   `compliance_hold`, …) → `ApiException` with `.code` preserved for
///   branching.
class DepositsResource extends ResourceBase {
  /// Build the resource. Normally accessed as `client.deposits`.
  DepositsResource(super.transport);

  /// Derive a per-hop idempotency key from one base key, so a single
  /// user gesture maps to stable keys for every hop of the flow:
  /// `deriveHopKey(key, 'quote')` → `'$key:quote'`.
  static String deriveHopKey(String baseKey, String hop) => '$baseKey:$hop';

  /// `GET /v1/deposit-assets` — the server-side allowlist of source
  /// assets deposits may originate from. Render [SupportedDepositAsset.enabled]
  /// honestly; never infer support from symbols client-side.
  Future<List<SupportedDepositAsset>> getSupportedAssets() async {
    final response = await request(const PuenteRequest(
      method: 'GET',
      path: '/deposit-assets',
    ));
    return decodeList(response, SupportedDepositAsset.fromJson,
        target: 'SupportedDepositAsset');
  }

  /// `POST /v1/deposit-sessions` — open a deposit session for [userId].
  ///
  /// The backend assigns (or reuses) the user's Solana deposit address
  /// and returns the session in status `created`. [sourceAmountMinor] is
  /// an integer in the source asset's minor units. Pass [displayCurrency]
  /// (`"USD"`/`"MXN"`) to receive a labeled indicative estimate.
  ///
  /// Rejections: `unsupported_asset`, `unsupported_network`,
  /// `capability_unavailable` (e.g. Solana-source in this MVP),
  /// `amount_below_minimum`, `amount_above_maximum`, `deposits_disabled`.
  Future<DepositSession> createSession({
    required String userId,
    required String sourceNetwork,
    required String sourceAssetId,
    required String sourceWalletAddress,
    required int sourceAmountMinor,
    String? displayCurrency,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/deposit-sessions',
      body: <String, dynamic>{
        'user_id': userId,
        'source_network': sourceNetwork,
        'source_asset_id': sourceAssetId,
        'source_wallet_address': sourceWalletAddress,
        'source_amount_minor': sourceAmountMinor,
        if (displayCurrency != null) 'display_currency': displayCurrency,
      },
      idempotencyKey: key,
    ));
    return decode(response, DepositSession.fromJson,
        target: 'DepositSession', idempotencyKey: key);
  }

  /// `GET /v1/deposit-sessions/{id}` — authoritative current state; the
  /// poll target behind [watch].
  Future<DepositSession> retrieve(String id) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/deposit-sessions/${pathSegment(id, 'id')}',
    ));
    return decode(response, DepositSession.fromJson, target: 'DepositSession');
  }

  /// `POST /v1/deposit-sessions/{id}/quotes` — attach (or refresh) a
  /// route quote. Legal until the session is prepared; re-quoting
  /// replaces the previous quote.
  ///
  /// The returned session carries [DepositSession.quote] with integer
  /// amounts and a hard [DepositQuote.expiresAt] — past it, `prepare`
  /// answers `409 quote_expired` ([StaleQuoteException]).
  Future<DepositSession> getQuote(String id, {String? idempotencyKey}) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/deposit-sessions/${pathSegment(id, 'id')}/quotes',
      body: const <String, dynamic>{},
      idempotencyKey: key,
    ));
    return decode(response, DepositSession.fromJson,
        target: 'DepositSession', idempotencyKey: key);
  }

  /// `POST /v1/deposit-sessions/{id}/prepare` — lock the route and build
  /// the signing handoff.
  ///
  /// Returns a typed [PreparedDeposit]: an optional exact-amount ERC-20
  /// [PreparedDeposit.approval], the route
  /// [PreparedDeposit.transaction], and the validated
  /// [PreparedDeposit.spender]. Throws [StaleQuoteException] on
  /// `409 quote_expired` (re-quote first) and `ApiException` with code
  /// `quote_required` when no quote exists yet.
  Future<PreparedDeposit> prepare(String id, {String? idempotencyKey}) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/deposit-sessions/${pathSegment(id, 'id')}/prepare',
      body: const <String, dynamic>{},
      idempotencyKey: key,
    ));
    return decode(response, PreparedDeposit.fromJson,
        target: 'PreparedDeposit', idempotencyKey: key);
  }

  /// `POST /v1/deposit-sessions/{id}/submission` — report that the wallet
  /// broadcast the source transaction.
  ///
  /// [transactionHash] is a **hint**: the backend verifies settlement
  /// independently on-chain, so a wrong or missing report delays but
  /// never corrupts the deposit.
  Future<DepositSession> reportSubmission(
    String id, {
    required String transactionHash,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/deposit-sessions/${pathSegment(id, 'id')}/submission',
      body: <String, dynamic>{'transaction_hash': transactionHash},
      idempotencyKey: key,
    ));
    return decode(response, DepositSession.fromJson,
        target: 'DepositSession', idempotencyKey: key);
  }

  /// `GET /v1/deposit-sessions/{id}/events` — the append-only transition
  /// audit trail, oldest first. For support/debug UIs.
  Future<List<DepositEvent>> events(String id) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/deposit-sessions/${pathSegment(id, 'id')}/events',
    ));
    return decodeList(response, DepositEvent.fromJson, target: 'DepositEvent');
  }

  /// `GET /v1/deposits` — list deposit sessions, newest first.
  ///
  /// Filter with [userId]; page with [startingAfter] (the last session id
  /// from the previous page). [limit] is capped server-side.
  Future<List<DepositSession>> list({
    String? userId,
    int limit = 20,
    String? startingAfter,
  }) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/deposits',
      query: <String, String>{
        if (userId != null) 'user_id': userId,
        'limit': limit.toString(),
        if (startingAfter != null) 'starting_after': startingAfter,
      },
    ));
    return decodeList(response, DepositSession.fromJson,
        target: 'DepositSession');
  }

  /// Stream the lifecycle of a deposit session by polling [retrieve] on a
  /// fixed cadence until a terminal state is reached (same semantics as
  /// `TransfersResource.watch`).
  ///
  /// Emits each distinct [DepositStatus] and completes when
  /// [DepositStatus.isTerminal] is true — settled ([DepositStatus.credited]
  /// or any post-credit sweep state), any failure terminal, or
  /// `manual_review`. `compliance_hold` is emitted but does NOT stop the
  /// stream (holds release). Also stops after [timeout] even if no
  /// terminal state was reached, so a stuck server doesn't leak a
  /// subscription.
  ///
  /// Like `TransfersResource.watch`, a timeout completes the stream
  /// normally by default — indistinguishable from settlement. Pass
  /// [throwOnTimeout] to receive a [TimeoutException] instead, and always
  /// confirm a credit with [retrieve] or a webhook before telling a user
  /// their funds arrived.
  Stream<DepositSession> watch(
    String id, {
    Duration pollInterval = const Duration(seconds: 1),
    Duration timeout = const Duration(minutes: 10),
    bool throwOnTimeout = false,
  }) async* {
    final deadline = clock.now().add(timeout);
    DepositStatus? lastStatus;
    while (clock.now().isBefore(deadline)) {
      final session = await retrieve(id);
      if (lastStatus != session.status) {
        yield session;
        lastStatus = session.status;
      }
      if (session.status.isTerminal) return;
      await Future<void>.delayed(pollInterval);
    }
    if (throwOnTimeout) {
      throw TimeoutException(
        'deposit $id did not reach a terminal state within '
        '${timeout.inSeconds}s (last observed: ${lastStatus?.name ?? 'none'})'
        ' — it may still credit; confirm with deposits.retrieve or a webhook',
        timeout,
      );
    }
  }

  /// `POST /v1/deposit-sessions/{id}/mock-events` — drive the MOCK
  /// deposit lifecycle. **LOCAL/TEST ONLY**: the route exists solely in
  /// `VENDOR_MODE=mock` backends (and `MockTransport`); it 403s
  /// (`mock_events_disabled`) on live.
  ///
  /// Scenarios (backend vocabulary, `puente-api/src/deposits.rs`):
  /// `quote | prepared | submitted | routing | settle | settle_finalized |
  /// underpay | wrong_asset | route_failed | compliance_hold |
  /// compliance_release | credit | sweep`. Unknown scenarios answer
  /// `400 invalid_request`; illegal transitions `409 illegal_state`.
  /// Returns the post-event session.
  Future<DepositSession> sendMockEvent(
    String id,
    String scenario, {
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/deposit-sessions/${pathSegment(id, 'id')}/mock-events',
      body: <String, dynamic>{'scenario': scenario},
      idempotencyKey: key,
    ));
    return decode(response, DepositSession.fromJson,
        target: 'DepositSession', idempotencyKey: key);
  }
}
