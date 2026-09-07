import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import '../models/currency.dart';
import '../models/money.dart';
import 'puente_request.dart';
import 'puente_response.dart';
import 'puente_transport.dart';

/// In-memory transport that serves canned responses for every route the
/// SDK calls. **Dev/test-only** — import it from
/// `package:puente_railway/testing.dart`, never ship it in a release
/// build (`PuenteClient` refuses `PuenteEnvironment.mock` in release
/// mode).
///
/// This is the SDK's `PuenteEnvironment.mock` backend and also the
/// default for unit tests. It is deterministic given a fixed seed, so
/// the same demo flow produces the same ids across runs.
///
/// ## Fixture policy (NOT production truth)
///
/// The mock performs **no financial computation of its own** beyond
/// emitting fixtures that mirror the backend's default policy:
///
/// * Same-currency quotes → `p2p_same_region`, `fx_rate "1"`, destination
///   equals source, and a **zero** total fee (the backend's default
///   same-region policy).
/// * Cross-currency quotes → `cross_border`, a flat fee anchored to
///   $1.00 USD ([crossBorderFlatFeeUsdFixtureMinor]) charged in minor
///   units of the source currency at the fixture rate
///   (fx-spread and vendor fixtures are 0), and a destination amount
///   converted at the fixed [_fixtureRates] table.
/// * Transfers always take their amounts and fees **verbatim from the
///   stored quote** they reference — the mock never recomputes them.
///
/// Real fees, FX rates, totals, and margins ALWAYS come from the Puente
/// backend quote; these fixtures exist only so offline demos and unit
/// tests exercise the same wire shapes the backend serves.
///
/// What's modelled:
/// * `POST /quotes` (alias `/quote`) — returns a quote in the current
///   backend shape (`quote_id`, `*_minor`, `fx_rate`, `fee_breakdown`, …)
///   plus the legacy keys, so old and new parsers both work.
/// * `POST /transfers` — accepts a `quote_id`, resolves the stored quote
///   (404 `quote_not_found` when unknown, 409 `quote_expired` when past
///   `expires_at`), and stores a [Transfer]-shaped doc.
/// * `GET /transfers/:id` — returns the stored doc. Advances the status
///   from `pending` → `processing` → `settled` over [settlementLatency]
///   so demos see a real lifecycle.
/// * `GET /transfers/:id/receipt` — the settlement receipt (409-shaped
///   `receipt_unavailable: …` until settled), with a deterministic cNFT
///   fixture.
/// * `GET /transfers` — returns the full list, newest first.
/// * `POST /transfers/:id/cancel` — flips to `cancelled` unless already
///   terminal.
/// * `POST /accounts`, `GET /accounts/:id`, `PATCH /accounts/:id`.
/// * `GET /clabe/:clabe` — returns a plausible bank-name lookup. CLABEs
///   ending in `00` are reported as `valid=false` for negative-path
///   testing.
/// * Onboarding/KYC (`/onboarding/*`, `/kyc/*`, `/wallet/readiness`,
///   `/me/personal-info*`) — mirrors the Puente KYC surface (migration
///   0012 + `kyc::router`): region policy (US/MX; unsupported countries
///   come back calm with `supported=false`), profile validation
///   (underage → 422 `underage`, region-mismatched identifiers/documents
///   → 422, approved profiles → 409 `profile_locked`), versioned
///   consents, one-active-session semantics (`duplicate=true`), the mock
///   verification lifecycle driven by `POST /kyc/sessions/:id/mock-events`
///   (scenarios `document_captured | selfie_captured | processing |
///   approve | reject | manual_review | expire | error`; terminal → 409
///   `terminal_state`), backend-authoritative wallet readiness, and a
///   masked personal-info view (identifiers as type+last4, raw values
///   never echoed). Single-applicant semantics: the most recently created
///   applicant is "the" authenticated user; re-creating the same
///   `external_user_id` rotates the token (restart recovery). The mock
///   NEVER approves on its own — outcomes only move via mock-events.
/// * External-wallet deposits (`/deposit-assets`, `/deposit-sessions*`,
///   `/deposits`) — mirrors the Puente deposits wire contract
///   (`docs/deposits-external-wallet-design.md`): server-side asset
///   allowlist fixtures, per-user deterministic deposit addresses,
///   fixture route quotes (integer minor units; labeled NOT production
///   truth), prepare with exact-amount approval + route transaction
///   signing requests, submission acknowledgement, and a
///   [settlementLatency]-driven progression
///   `submitted → routing → destination_detected → credited`. Exceptional
///   paths are driven via `POST /deposit-sessions/:id/mock-events`
///   (scenarios `quote | prepared | submitted | routing | settle |
///   settle_finalized | underpay | wrong_asset | route_failed |
///   compliance_hold | compliance_release | credit | sweep |
///   quote_expired`), mirroring the VENDOR_MODE=mock backend. Error codes
///   are the design doc's stable vocabulary (`deposit_not_found`,
///   `quote_expired`, `quote_required`, `unsupported_asset`,
///   `capability_unavailable`, `amount_below_minimum`,
///   `amount_above_maximum`, `deposits_disabled`, `illegal_state`).
/// * Idempotency: requests with the same `Idempotency-Key` on `POST`
///   return the same stored response.
///
/// What's NOT modelled (and would mean the demo isn't testing the real
/// thing): rate limits, network jitter, server-side validation beyond
/// shape, real CETES / USDC ledger movement. For those, use the live
/// Puente backend.
class MockTransport implements PuenteTransport {
  /// Build a [MockTransport]. Pass [seed] for deterministic ids.
  MockTransport({
    int seed = 0,
    this.settlementLatency = const Duration(seconds: 2),
    this.networkLatency = const Duration(milliseconds: 80),
    Map<String, double>? exchangeRates,
  })  : _random = math.Random(seed),
        _uuid = const Uuid(),
        _rates = Map.unmodifiable(exchangeRates ?? _fixtureRates);

  /// Wall-clock delay between `pending` → `processing` → `settled`. The
  /// transport schedules a [Timer] when a transfer is created so reads
  /// after the latency reflect the next state.
  final Duration settlementLatency;

  /// Simulated per-request latency. Set to [Duration.zero] in unit tests
  /// for snappier runs.
  final Duration networkLatency;

  final Map<String, double> _rates;
  final math.Random _random;
  final Uuid _uuid;

  // In-memory stores keyed by id.
  final Map<String, Map<String, dynamic>> _quotes = {};
  final Map<String, Map<String, dynamic>> _transfers = {};
  final Map<String, Map<String, dynamic>> _accounts = {};
  final Map<String, Map<String, dynamic>> _applicants = {};
  final Map<String, String> _applicantIdByExternalId = {};
  final Map<String, Map<String, dynamic>> _kycSessions = {};
  final Map<String, Map<String, dynamic>> _deposits = {};
  final Map<String, List<Map<String, dynamic>>> _depositEvents = {};
  final Map<String, String> _depositAddressByUser = {};

  /// Dev toggle for the deposits master flag. Set `false` to make every
  /// deposit endpoint answer `503 deposits_disabled` — mirrors
  /// `DEPOSITS_ENABLED=false` on the backend.
  bool depositsEnabled = true;

  /// The applicant the mock treats as "the authenticated user" — the most
  /// recently created one (single-applicant semantics; see class doc).
  String? _currentApplicantId;

  // Idempotency map: idempotency-key → already-returned response body.
  final Map<String, _CachedResponse> _idempotencyCache = {};

  /// Quote ids that have already been used to create a transfer, so a
  /// second POST /transfers referencing the same quote returns
  /// 409 `quote_already_used` (mirrors the DB-enforced backend contract).
  final Set<String> _consumedQuotes = <String>{};

  // Timers we own; cancelled on close().
  final List<Timer> _timers = [];

  /// Dev fixture rates — the real rate ALWAYS comes from the backend
  /// quote. Fixed (never market-driven) so tests and demos are
  /// deterministic.
  static const Map<String, double> _fixtureRates = <String, double>{
    'USD->MXN': 19.73,
    'MXN->USD': 1 / 19.73,
    'USD->USDC': 1.0,
    'USDC->USD': 1.0,
    'USDC->MXN': 19.73,
    'MXN->USDC': 1 / 19.73,
  };

  /// Dev fixture: cross-border flat fee, anchored to **$1.00 USD** — the
  /// backend's default cross-border policy (`100` = one dollar in USD
  /// minor units). The fee stays *denominated* in the source currency on
  /// the wire (matching the backend's `fee_breakdown.currency` contract),
  /// so non-USD-source quotes charge the $1.00-USD equivalent at the
  /// fixture rate: an MXN-source quote charges ~$19.73 MXN, never
  /// $1.00 MXN. Mirrors the backend's *default* policy shape only — the
  /// real fee ALWAYS comes from the backend quote.
  static const int crossBorderFlatFeeUsdFixtureMinor = 100;

  /// How long a mock quote stays valid. Mirrors the backend default.
  static const Duration _quoteTtl = Duration(minutes: 2);

  @override
  Future<PuenteResponse> send(PuenteRequest request) async {
    await Future<void>.delayed(networkLatency);

    final method = request.method.toUpperCase();
    final path = request.path;

    // Idempotent replay for unsafe methods. Keyed on (method, path,
    // idempotency-key) — the real backend keys on request body hash + key,
    // so a single logical retry replays; a naive key-only cache would
    // mean a POST /transfers with the same key as an earlier POST /quotes
    // silently returns the quote response (a real bug the reviewer
    // caught).
    final key = request.idempotencyKey;
    String? cacheKey;
    if (key != null && (method == 'POST' || method == 'PUT')) {
      cacheKey = '$method $path $key';
      final cached = _idempotencyCache[cacheKey];
      if (cached != null) return cached.response;
    }

    try {
      final response = await _route(method, path, request);
      if (cacheKey != null) {
        _idempotencyCache[cacheKey] = _CachedResponse(response, clock.now());
      }
      return response;
    } on _MockError catch (e) {
      return _jsonResponse(e.statusCode, {
        'error': e.code,
        'message': e.message,
      });
    }
  }

  Future<PuenteResponse> _route(
      String method, String path, PuenteRequest request) async {
    // /quotes (the backend also serves the /quote alias).
    if (method == 'POST' && (path == '/quotes' || path == '/quote')) {
      return _createQuote(request);
    }

    // /transfers + /transfers/:id (+ /cancel, /receipt)
    if (method == 'POST' && path == '/transfers') {
      return _createTransfer(request);
    }
    if (method == 'GET' && path == '/transfers') return _listTransfers(request);
    final transferIdMatch = RegExp(r'^/transfers/([^/]+)$').firstMatch(path);
    if (transferIdMatch != null) {
      if (method == 'GET') return _getTransfer(transferIdMatch.group(1)!);
    }
    final receiptMatch =
        RegExp(r'^/transfers/([^/]+)/receipt$').firstMatch(path);
    if (receiptMatch != null && method == 'GET') {
      return _transferReceipt(receiptMatch.group(1)!);
    }
    final cancelMatch = RegExp(r'^/transfers/([^/]+)/cancel$').firstMatch(path);
    if (cancelMatch != null && method == 'POST') {
      return _cancelTransfer(cancelMatch.group(1)!);
    }

    // /accounts
    if (method == 'POST' && path == '/accounts') return _createAccount(request);
    final accountIdMatch = RegExp(r'^/accounts/([^/]+)$').firstMatch(path);
    if (accountIdMatch != null) {
      final id = accountIdMatch.group(1)!;
      if (method == 'GET') return _getAccount(id);
      if (method == 'PATCH') return _updateAccount(id, request);
    }

    // /clabe/:clabe
    final clabeMatch = RegExp(r'^/clabe/([0-9]+)$').firstMatch(path);
    if (clabeMatch != null && method == 'GET') {
      return _lookupClabe(clabeMatch.group(1)!);
    }

    // Onboarding / KYC surface (mirrors Puente kyc::router).
    if (method == 'POST' && path == '/onboarding/applicants') {
      return _createApplicant(request);
    }
    if (method == 'GET' && path == '/onboarding/policy') {
      return _getPolicy(request);
    }
    if (path == '/onboarding/profile') {
      if (method == 'GET') return _getOnboardingProfile();
      if (method == 'PUT') return _updateOnboardingProfile(request);
    }
    if (method == 'POST' && path == '/onboarding/consents') {
      return _submitConsents(request);
    }
    if (method == 'POST' && path == '/kyc/sessions') {
      return _createKycSession();
    }
    if (method == 'GET' && path == '/kyc/sessions/current') {
      return _currentKycSession();
    }
    final mockEventMatch =
        RegExp(r'^/kyc/sessions/([^/]+)/mock-events$').firstMatch(path);
    if (mockEventMatch != null && method == 'POST') {
      return _kycMockEvent(mockEventMatch.group(1)!, request);
    }
    if (method == 'GET' && path == '/wallet/readiness') {
      return _walletReadiness();
    }
    if (method == 'GET' && path == '/me/personal-info') {
      return _personalInfo();
    }
    if (method == 'POST' && path == '/me/personal-info/correction-requests') {
      return _correctionRequest(request);
    }

    // External-wallet deposits surface (mirrors Puente deposits router).
    if (path == '/deposit-assets' ||
        path == '/deposits' ||
        path.startsWith('/deposit-sessions')) {
      return _routeDeposits(method, path, request);
    }

    return _jsonResponse(404, {
      'error': 'route_not_found',
      'message': 'mock transport has no handler for $method $path',
    });
  }

  // ---------------------------------------------------------------- quotes
  PuenteResponse _createQuote(PuenteRequest request) {
    final body = _decodeBody(request);

    // Prefer the current backend keys; fall back to the legacy SDK shape.
    final Money src;
    if (body['source_amount_minor'] is int &&
        body['source_currency'] is String) {
      src = Money.fromMinor(
        body['source_amount_minor'] as int,
        Currency.fromCode(body['source_currency'] as String),
      );
    } else {
      src = _readMoney(body, 'source_amount');
    }
    final tgtCode =
        (body['destination_currency'] ?? body['target_currency']) as String?;
    if (tgtCode == null) {
      throw const _MockError(
          422, 'invalid_request', 'destination_currency required');
    }
    final tgtCurrency = Currency.fromCode(tgtCode);

    // Fixture policy — mirrors the backend's DEFAULTS, documented above.
    // Not production truth: the real backend decides fees, FX, and legs.
    final int destinationMinor;
    final String fxRate;
    final int flatFeeMinor;
    final String transferType;
    final String currencyLeg;
    if (src.currency == tgtCurrency) {
      // Same-region P2P fixture: zero fee, rate "1", destination == source.
      destinationMinor = src.minorUnits;
      fxRate = '1';
      flatFeeMinor = 0;
      transferType = 'p2p_same_region';
      currencyLeg = 'USDC';
    } else {
      final pair = '${src.currency.code}->${tgtCurrency.code}';
      final rate = _rates[pair];
      if (rate == null) {
        throw _MockError(
          422,
          'unsupported_pair',
          'mock transport has no fixture rate for $pair',
        );
      }
      destinationMinor =
          (src.minorUnits * tgtCurrency.scale * rate ~/ src.currency.scale)
              .toInt();
      fxRate = rate.toString();
      flatFeeMinor = _usdAnchoredFlatFeeMinor(src.currency);
      transferType = 'cross_border';
      currencyLeg = tgtCurrency == Currency.mxn ? 'CETES' : 'USDC';
    }
    // Fixture components: fx-spread and vendor are always 0 in the mock.
    const fxSpreadFeeMinor = 0;
    const vendorFeeMinor = 0;
    final totalFeeMinor = flatFeeMinor + fxSpreadFeeMinor + vendorFeeMinor;

    final id = 'qt_${_uuid.v4().replaceAll('-', '').substring(0, 12)}';
    final now = clock.now();
    final tgt = Money.fromMinor(destinationMinor, tgtCurrency);
    final quote = <String, dynamic>{
      // Current backend shape (POST /v1/quotes response).
      'quote_id': id,
      'source_amount_minor': src.minorUnits,
      'source_currency': src.currency.code,
      'destination_amount_minor': destinationMinor,
      'destination_currency': tgtCurrency.code,
      'fx_rate': fxRate,
      'total_fee_minor': totalFeeMinor,
      'total_cost_minor': src.minorUnits + totalFeeMinor,
      'expires_at': now.add(_quoteTtl).toUtc().toIso8601String(),
      'transfer_type': transferType,
      'currency_leg': currencyLeg,
      'fee_breakdown': <String, dynamic>{
        'flat_fee_minor': flatFeeMinor,
        'fx_spread_fee_minor': fxSpreadFeeMinor,
        'vendor_fee_minor': vendorFeeMinor,
        'total_fee_minor': totalFeeMinor,
        'currency': src.currency.code,
      },
      // Legacy shape, kept alongside so older parsers keep working.
      'id': id,
      'source_amount': src.toJson(),
      'target_amount': tgt.toJson(),
      'exchange_rate': double.parse(fxRate),
      'fee': Money.fromMinor(totalFeeMinor, src.currency).toJson(),
      'created_at': now.toUtc().toIso8601String(),
    };
    _quotes[id] = quote;
    return _jsonResponse(200, quote);
  }

  /// [crossBorderFlatFeeUsdFixtureMinor] ($1.00 USD) expressed in [source]
  /// minor units at the fixture rate, floored the same way destination
  /// amounts are. Keeps the wire denomination in the source currency while
  /// anchoring the fee's VALUE to the USD policy.
  int _usdAnchoredFlatFeeMinor(Currency source) {
    if (source == Currency.usd) return crossBorderFlatFeeUsdFixtureMinor;
    final rate = _rates['USD->${source.code}'];
    if (rate == null) {
      throw _MockError(
        422,
        'unsupported_pair',
        'mock transport has no USD fixture rate for ${source.code}',
      );
    }
    return (crossBorderFlatFeeUsdFixtureMinor *
            source.scale *
            rate ~/
            Currency.usd.scale)
        .toInt();
  }

  // ------------------------------------------------------------- transfers
  PuenteResponse _createTransfer(PuenteRequest request) {
    final body = _decodeBody(request);
    final quoteId = body['quote_id'] as String?;
    if (quoteId == null) {
      throw const _MockError(422, 'invalid_request', 'quote_id required');
    }

    // Resolve the referenced quote — amounts and fees come from it
    // verbatim; the mock NEVER recomputes them.
    final quote = _quotes[quoteId];
    if (quote == null) {
      throw _MockError(404, 'quote_not_found', 'quote $quoteId not found');
    }
    final expiresAt = DateTime.parse(quote['expires_at'] as String);
    if (!clock.now().toUtc().isBefore(expiresAt)) {
      throw _MockError(
          409, 'quote_expired', 'quote $quoteId expired at $expiresAt');
    }
    // Single-use quotes match the real backend contract (DB-enforced by
    // the unique index on external_transfers.metadata->>quote_id).
    // Marking on first consumption; any subsequent transfer against the
    // same quote_id gets a 409 quote_already_used just like the server.
    if (_consumedQuotes.contains(quoteId)) {
      throw _MockError(
          409, 'quote_already_used', 'quote $quoteId was already consumed');
    }

    final receiverName = body['receiver_name'] as String?;
    if (receiverName == null || receiverName.trim().isEmpty) {
      throw const _MockError(422, 'invalid_request', 'receiver_name required');
    }
    final receiverClabe = body['receiver_clabe'] as String?;
    final memo = body['memo'] as String?;
    final transferType = quote['transfer_type'] as String;
    if (transferType == 'cross_border') {
      if (receiverClabe == null || receiverClabe.length != 18) {
        throw const _MockError(
            422, 'invalid_request', 'receiver_clabe must be 18 digits');
      }
    } else {
      // P2P mirrors the backend contract: both user ids are required.
      if (body['sender_user_id'] is! String ||
          body['receiver_user_id'] is! String) {
        throw const _MockError(422, 'invalid_request',
            'sender_user_id and receiver_user_id required for p2p transfers');
      }
    }

    final id = 'tx_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    final now = clock.now();
    final stored = <String, dynamic>{
      'id': id,
      'status': 'pending',
      // Verbatim from the quote — never recomputed here.
      'source_amount': <String, dynamic>{
        'amount': quote['source_amount_minor'],
        'currency': quote['source_currency'],
      },
      'target_amount': <String, dynamic>{
        'amount': quote['destination_amount_minor'],
        'currency': quote['destination_currency'],
      },
      if (receiverClabe != null) 'receiver_clabe': receiverClabe,
      'receiver_name': receiverName,
      if (memo != null) 'memo': memo,
      'created_at': now.toUtc().toIso8601String(),
      'updated_at': now.toUtc().toIso8601String(),
      'reference': null,
      'quote_id': quoteId,
      'transfer_type': transferType,
      'fee_breakdown': quote['fee_breakdown'],
      // Carried for the receipt route (harmless extra keys on the wire).
      'currency_leg': quote['currency_leg'],
      'fx_rate': quote['fx_rate'],
    };
    _consumedQuotes.add(quoteId);
    _transfers[id] = stored;

    // Advance status over real time so polling demos see a lifecycle.
    if (settlementLatency > Duration.zero) {
      _timers.add(Timer(settlementLatency ~/ 2, () {
        final doc = _transfers[id];
        if (doc == null || doc['status'] != 'pending') return;
        doc['status'] = 'processing';
        doc['updated_at'] = clock.now().toUtc().toIso8601String();
      }));
      _timers.add(Timer(settlementLatency, () {
        final doc = _transfers[id];
        if (doc == null || doc['status'] != 'processing') return;
        final settledAt = clock.now().toUtc().toIso8601String();
        doc['status'] = 'settled';
        doc['updated_at'] = settledAt;
        doc['settled_at'] = settledAt;
        doc['reference'] =
            'SPEI-${_random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
      }));
    } else {
      // No latency configured (unit tests) — settle synchronously.
      stored['status'] = 'settled';
      stored['settled_at'] = now.toUtc().toIso8601String();
      stored['reference'] = 'SPEI-MOCK';
    }

    return _jsonResponse(201, stored);
  }

  PuenteResponse _getTransfer(String id) {
    final doc = _transfers[id];
    if (doc == null) {
      throw _MockError(404, 'not_found', 'transfer $id not found');
    }
    return _jsonResponse(200, doc);
  }

  PuenteResponse _transferReceipt(String id) {
    final doc = _transfers[id];
    if (doc == null) {
      throw _MockError(404, 'not_found', 'transfer $id not found');
    }
    final status = doc['status'] as String;
    if (status != 'settled') {
      // 409 with the backend's `receipt_unavailable: …` error shape.
      throw _MockError(
        409,
        'receipt_unavailable: transfer $id is $status',
        'receipt unavailable: transfer $id is $status',
      );
    }
    final sourceCurrency = (doc['source_amount'] as Map)['currency'] as String;
    final suffix = id.length > 6 ? id.substring(id.length - 6) : id;
    return _jsonResponse(200, <String, dynamic>{
      'transaction_id': id,
      'status': 'settled',
      'transfer_type': doc['transfer_type'],
      'currency_leg': doc['currency_leg'],
      'source_amount': doc['source_amount'],
      'target_amount': doc['target_amount'],
      'fx_rate': doc['fx_rate'],
      'fee_breakdown': doc['fee_breakdown'],
      // Vendor-cost fixture: all zeros — real costs come from the backend.
      'vendor_costs': <String, dynamic>{
        'etherfuse_minor': 0,
        'network_minor': 0,
        'other_minor': 0,
        'currency': sourceCurrency,
      },
      'reference': doc['reference'],
      'memo': doc['memo'],
      'receiver_name': doc['receiver_name'],
      'created_at': doc['created_at'],
      'settled_at': doc['settled_at'] ?? doc['updated_at'],
      // Deterministic cNFT fixture.
      'cnft': <String, dynamic>{
        'folio': 'PES-${suffix.toUpperCase()}',
        'asset_id': null,
        'metadata_uri': 'mock://receipts/$id',
        'mint_signature': null,
      },
    });
  }

  PuenteResponse _listTransfers(PuenteRequest request) {
    final limit = int.tryParse(request.query['limit'] ?? '20') ?? 20;
    final docs = _transfers.values.toList()
      ..sort((a, b) {
        final ai = a['created_at'] as String? ?? '';
        final bi = b['created_at'] as String? ?? '';
        return bi.compareTo(ai);
      });
    final slice = docs.take(limit).toList();
    return _jsonResponse(200, <String, dynamic>{'data': slice});
  }

  PuenteResponse _cancelTransfer(String id) {
    final doc = _transfers[id];
    if (doc == null) {
      throw _MockError(404, 'not_found', 'transfer $id not found');
    }
    final status = doc['status'] as String;
    if (status == 'settled' || status == 'failed' || status == 'cancelled') {
      throw _MockError(409, 'terminal_state', 'transfer $id is $status');
    }
    doc['status'] = 'cancelled';
    doc['updated_at'] = clock.now().toUtc().toIso8601String();
    return _jsonResponse(200, doc);
  }

  // -------------------------------------------------------------- accounts
  PuenteResponse _createAccount(PuenteRequest request) {
    final body = _decodeBody(request);
    final firstName = body['first_name'] as String?;
    final lastName = body['last_name'] as String?;
    final email = body['email'] as String?;
    final phone = body['phone'] as String?;
    if (firstName == null ||
        lastName == null ||
        email == null ||
        phone == null) {
      throw const _MockError(422, 'invalid_request',
          'first_name, last_name, email, phone required');
    }
    final id = 'acct_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    final now = clock.now();
    final stored = <String, dynamic>{
      'id': id,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'kyc_tier': 'none',
      'created_at': now.toUtc().toIso8601String(),
    };
    _accounts[id] = stored;
    return _jsonResponse(201, stored);
  }

  PuenteResponse _getAccount(String id) {
    final doc = _accounts[id];
    if (doc == null) {
      throw _MockError(404, 'not_found', 'account $id not found');
    }
    return _jsonResponse(200, doc);
  }

  PuenteResponse _updateAccount(String id, PuenteRequest request) {
    final doc = _accounts[id];
    if (doc == null) {
      throw _MockError(404, 'not_found', 'account $id not found');
    }
    final body = _decodeBody(request);
    if (body['phone'] is String) doc['phone'] = body['phone'];
    return _jsonResponse(200, doc);
  }

  // ----------------------------------------------------------------- clabe
  PuenteResponse _lookupClabe(String clabe) {
    if (clabe.length != 18) {
      throw const _MockError(422, 'invalid_request', 'clabe must be 18 digits');
    }
    final prefix = clabe.substring(0, 3);
    final banks = <String, String>{
      '012': 'BBVA México',
      '014': 'Santander',
      '021': 'HSBC',
      '044': 'Scotiabank',
      '072': 'Banorte',
      '646': 'STP',
    };
    final bankName = banks[prefix] ?? 'Unknown Bank';
    // Suffix `00` flips invalid for negative-path testing.
    final valid = !clabe.endsWith('00') && banks.containsKey(prefix);
    return _jsonResponse(200, <String, dynamic>{
      'clabe': clabe,
      'bank_name': bankName,
      'bank_code': prefix,
      'valid': valid,
    });
  }

  // -------------------------------------------------- onboarding / kyc ----
  //
  // Fixture policy: mirrors the Puente backend DEFAULTS (kyc::policy
  // POLICY_VERSION 2026-07-07.1) — same error codes, same wire shapes,
  // same state machine. The mock never approves on its own; outcomes are
  // driven exclusively through /kyc/sessions/:id/mock-events, exactly like
  // the VENDOR_MODE=mock backend.

  /// Mirrors `kyc::policy::POLICY_VERSION`.
  static const String kycPolicyVersion = '2026-07-07.1';

  /// Mirrors `kyc::policy::DISCLOSURE_VERSION`.
  static const String kycDisclosureVersion = '2026-07-07.1';

  static const List<String> _activeSessionStatuses = <String>[
    'session_created',
    'document_capture_started',
    'selfie_started',
    'processing',
  ];

  static const List<String> _lockedKycStatuses = <String>[
    'processing',
    'approved',
    'manual_review',
  ];

  Map<String, dynamic> _policyFixture(String residence) {
    final upper = residence.toUpperCase();
    final base = <String, dynamic>{
      'policy_version': kycPolicyVersion,
      'residence_country': upper,
      'min_age': 18,
      'disclosure_version': kycDisclosureVersion,
      'intended_use_options': <Map<String, dynamic>>[
        {'id': 'family_support', 'manual_review': false},
        {'id': 'personal_expenses', 'manual_review': false},
        {'id': 'education', 'manual_review': false},
        {'id': 'medical', 'manual_review': false},
        {'id': 'business', 'manual_review': true},
        {'id': 'other', 'manual_review': false},
      ],
      'source_of_funds_options': <String>[
        'employment',
        'savings',
        'business_income',
        'family_gift',
        'government_benefits',
        'other',
      ],
      'expected_volume_bands': <Map<String, dynamic>>[
        {'id': 'under_500', 'manual_review': false},
        {'id': '500_2000', 'manual_review': false},
        {'id': '2000_10000', 'manual_review': false},
        {'id': 'over_10000', 'manual_review': true},
      ],
    };
    switch (upper) {
      case 'US':
        return <String, dynamic>{
          ...base,
          'supported': true,
          'region': 'us',
          'corridors': <String>['us_mx'],
          'document_options': <Map<String, dynamic>>[
            {
              'document_type': 'us_drivers_license',
              'issuing_countries': ['US'],
              'legal_review_status': 'approved_policy',
              'manual_review_required': false,
            },
            {
              'document_type': 'us_state_id',
              'issuing_countries': ['US'],
              'legal_review_status': 'approved_policy',
              'manual_review_required': false,
            },
            {
              'document_type': 'us_passport',
              'issuing_countries': ['US'],
              'legal_review_status': 'approved_policy',
              'manual_review_required': false,
            },
            {
              'document_type': 'mexican_passport',
              'issuing_countries': ['MX'],
              'legal_review_status': 'requires_legal_review',
              'manual_review_required': true,
            },
            {
              'document_type': 'foreign_passport',
              'issuing_countries': <String>[],
              'legal_review_status': 'requires_legal_review',
              'manual_review_required': true,
            },
            {
              'document_type': 'consular_id',
              'issuing_countries': ['MX'],
              'legal_review_status': 'mock_only',
              'manual_review_required': true,
            },
          ],
          'identifier_requirements': <Map<String, dynamic>>[
            {
              'identifier_type': 'ssn',
              'requirement': 'required_one_of',
              'reason_key': 'kycWhyTaxId',
              'legal_review_status': 'approved_policy',
            },
            {
              'identifier_type': 'itin',
              'requirement': 'required_one_of',
              'reason_key': 'kycWhyTaxId',
              'legal_review_status': 'requires_legal_review',
            },
          ],
          'disclosures': <Map<String, dynamic>>[
            _disclosure('terms_of_service', '/legal/terms'),
            _disclosure('privacy_policy', '/legal/privacy'),
            _disclosure('esign_consent', '/legal/esign'),
            _disclosure('remittance_terms', '/legal/remittance-terms'),
          ],
        };
      case 'MX':
        return <String, dynamic>{
          ...base,
          'supported': true,
          'region': 'mx',
          'corridors': <String>['mx_us', 'us_mx'],
          'document_options': <Map<String, dynamic>>[
            {
              'document_type': 'ine',
              'issuing_countries': ['MX'],
              'legal_review_status': 'approved_policy',
              'manual_review_required': false,
            },
            {
              'document_type': 'mexican_passport',
              'issuing_countries': ['MX'],
              'legal_review_status': 'approved_policy',
              'manual_review_required': false,
            },
          ],
          'identifier_requirements': <Map<String, dynamic>>[
            {
              'identifier_type': 'curp',
              'requirement': 'optional',
              'reason_key': 'kycWhyCurp',
              'legal_review_status': 'requires_legal_review',
            },
          ],
          'disclosures': <Map<String, dynamic>>[
            _disclosure('terms_of_service', '/legal/terms'),
            _disclosure('aviso_de_privacidad', '/legal/aviso-de-privacidad'),
          ],
        };
      default:
        return <String, dynamic>{
          ...base,
          'supported': false,
          'unsupported_reason': 'region_not_supported',
          'corridors': <String>[],
          'document_options': <Map<String, dynamic>>[],
          'identifier_requirements': <Map<String, dynamic>>[],
          'disclosures': <Map<String, dynamic>>[],
          'intended_use_options': <Map<String, dynamic>>[],
          'source_of_funds_options': <String>[],
          'expected_volume_bands': <Map<String, dynamic>>[],
        };
    }
  }

  static Map<String, dynamic> _disclosure(String id, String url) =>
      <String, dynamic>{
        'id': id,
        'version': kycDisclosureVersion,
        'required': true,
        'url_placeholder': url,
      };

  Map<String, dynamic> _requireApplicant() {
    final id = _currentApplicantId;
    final doc = id == null ? null : _applicants[id];
    if (doc == null) {
      throw const _MockError(
          401, 'applicant_auth_required', 'applicant auth required');
    }
    return doc;
  }

  PuenteResponse _createApplicant(PuenteRequest request) {
    final body = _decodeBody(request);
    final externalUserId = (body['external_user_id'] as String?)?.trim();
    if (externalUserId == null || externalUserId.isEmpty) {
      throw const _MockError(
          422, 'invalid_request', 'external_user_id must not be empty');
    }
    final phone = body['phone'] as String?;
    final email = body['email'] as String?;
    if (phone == null && email == null) {
      throw const _MockError(422, 'contact_required', 'provide phone or email');
    }

    final existingId = _applicantIdByExternalId[externalUserId];
    final token = 'pat_mock_${_uuid.v4().replaceAll('-', '')}'.substring(0, 40);
    final now = clock.now().toUtc().toIso8601String();
    if (existingId != null) {
      // Token rotation — the restart-recovery path, mirroring the backend
      // ON CONFLICT upsert.
      final doc = _applicants[existingId]!;
      doc['applicant_token'] = token;
      doc['phone'] = phone ?? doc['phone'];
      doc['email'] = email ?? doc['email'];
      doc['updated_at'] = now;
      _currentApplicantId = existingId;
      return _jsonResponse(201, <String, dynamic>{
        'applicant_id': existingId,
        'applicant_token': token,
        'kyc_status': doc['kyc_status'],
        'kyc_tier': doc['kyc_tier'],
        'created': false,
      });
    }

    final id = 'apl_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    _applicants[id] = <String, dynamic>{
      'id': id,
      'external_user_id': externalUserId,
      'applicant_token': token,
      'phone': phone,
      'email': email,
      'kyc_status': 'not_started',
      'kyc_tier': 'none',
      'requires_manual_review': false,
      'manual_review_reason': null,
      'profile': <String, dynamic>{},
      'sensitive_identifier': null, // {'type','last4'} — raw NEVER stored
      'document': null,
      'policy_version': null,
      'disclosure_version': null,
      'consent_at': null,
      'created_at': now,
      'updated_at': now,
    };
    _applicantIdByExternalId[externalUserId] = id;
    _currentApplicantId = id;
    return _jsonResponse(201, <String, dynamic>{
      'applicant_id': id,
      'applicant_token': token,
      'kyc_status': 'not_started',
      'kyc_tier': 'none',
      'created': true,
    });
  }

  PuenteResponse _getPolicy(PuenteRequest request) {
    var residence = request.query['residence_country'];
    if (residence == null) {
      final doc = _requireApplicant();
      residence = (doc['profile'] as Map<String, dynamic>)['residence_country']
          as String?;
      if (residence == null) {
        throw const _MockError(422, 'residence_country_required',
            'pass ?residence_country= or set it on the profile');
      }
    }
    if (residence.length != 2) {
      throw const _MockError(
          422, 'invalid_request', 'country must be a 2-letter ISO code');
    }
    return _jsonResponse(200, _policyFixture(residence));
  }

  PuenteResponse _updateOnboardingProfile(PuenteRequest request) {
    final doc = _requireApplicant();
    if (_lockedKycStatuses.contains(doc['kyc_status'] as String)) {
      throw const _MockError(409, 'profile_locked',
          'identity fields need review to change — submit a correction request');
    }

    final body = _decodeBody(request);
    const allowed = <String>{
      'legal_first_name', 'legal_middle_name', 'legal_last_name',
      'date_of_birth', 'address_line1', 'address_line2', 'address_city',
      'address_state', 'address_postal_code', 'address_country',
      'residence_country', 'region', 'transfer_corridor', 'intended_use',
      'source_of_funds', 'expected_volume_band', 'sensitive_identifier',
      'document', //
    };
    for (final key in body.keys) {
      if (!allowed.contains(key)) {
        // deny_unknown_fields — kyc_status/kyc_tier can't be smuggled in.
        throw _MockError(422, 'invalid_request', 'unknown field: $key');
      }
    }
    if (body.isEmpty) {
      throw const _MockError(422, 'empty_update', 'empty_update');
    }

    final profile = doc['profile'] as Map<String, dynamic>;
    final residence = (body['residence_country'] as String?)?.toUpperCase() ??
        profile['residence_country'] as String?;
    final needsPolicy = body.keys.any((k) => k != 'legal_middle_name');
    Map<String, dynamic>? policy;
    if (needsPolicy && residence != null) {
      policy = _policyFixture(residence);
      if (policy['supported'] != true) {
        throw const _MockError(422, 'region_not_supported',
            'Pesito is not available for this residence country yet');
      }
    }

    final reviewReasons = <String>[];

    if (body['date_of_birth'] is String) {
      final dob = DateTime.tryParse(body['date_of_birth'] as String);
      if (dob == null) {
        throw const _MockError(422, 'invalid_dob', 'expected YYYY-MM-DD');
      }
      final today = clock.now().toUtc();
      if (dob.isAfter(today)) {
        throw const _MockError(422, 'invalid_dob', 'invalid_dob');
      }
      var years = today.year - dob.year;
      if (today.month < dob.month ||
          (today.month == dob.month && today.day < dob.day)) {
        years -= 1;
      }
      if (years > 120) {
        throw const _MockError(422, 'invalid_dob', 'invalid_dob');
      }
      if (years < 18) {
        throw const _MockError(422, 'underage',
            'applicants must meet the minimum age for this region');
      }
    }

    if (body['region'] is String) {
      final expected = policy?['region'];
      if (expected == null || body['region'] != expected) {
        throw const _MockError(422, 'unsupported_region_combination',
            'region must match residence country');
      }
    }
    if (body['transfer_corridor'] is String) {
      final corridors =
          (policy?['corridors'] as List<dynamic>? ?? const <dynamic>[])
              .cast<String>();
      if (!corridors.contains(body['transfer_corridor'])) {
        throw const _MockError(422, 'invalid_corridor', 'invalid_corridor');
      }
    }
    void checkChoice(String field, String listKey) {
      final raw = body[field];
      if (raw is! String) return;
      final options = (policy?[listKey] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>();
      final match = options.where((o) => o['id'] == raw).toList();
      if (match.isEmpty) {
        throw _MockError(422, 'invalid_choice', 'invalid_choice: $field');
      }
      if (match.first['manual_review'] == true) {
        reviewReasons.add('${field}_review');
      }
    }

    checkChoice('intended_use', 'intended_use_options');
    checkChoice('expected_volume_band', 'expected_volume_bands');
    if (body['source_of_funds'] is String) {
      final options = (policy?['source_of_funds_options'] as List<dynamic>? ??
              const <dynamic>[])
          .cast<String>();
      if (!options.contains(body['source_of_funds'])) {
        throw const _MockError(
            422, 'invalid_choice', 'invalid_choice: source_of_funds');
      }
    }

    Map<String, dynamic>? maskedIdentifier;
    if (body['sensitive_identifier'] is Map) {
      final input =
          (body['sensitive_identifier'] as Map).cast<String, dynamic>();
      final type = input['type'] as String?;
      final value =
          (input['value'] as String?)?.replaceAll(RegExp(r'[\s-]'), '') ?? '';
      final requirements =
          (policy?['identifier_requirements'] as List<dynamic>? ??
                  const <dynamic>[])
              .cast<Map<String, dynamic>>();
      final req =
          requirements.where((r) => r['identifier_type'] == type).toList();
      if (req.isEmpty) {
        throw const _MockError(422, 'identifier_not_allowed',
            'this identifier is not collected for your region');
      }
      if (value.length < 4) {
        throw const _MockError(
            422, 'invalid_identifier_value', 'invalid_identifier_value');
      }
      if (req.first['legal_review_status'] == 'requires_legal_review') {
        reviewReasons.add('identifier_review');
      }
      // Raw value discarded here — only type + last4 are ever stored,
      // mirroring the backend's hash+last4 contract.
      maskedIdentifier = <String, dynamic>{
        'type': type,
        'last4': value.substring(value.length - 4),
      };
    }

    Map<String, dynamic>? document;
    if (body['document'] is Map) {
      final input = (body['document'] as Map).cast<String, dynamic>();
      final type = input['type'] as String?;
      final issuing = (input['issuing_country'] as String?)?.toUpperCase();
      final options =
          (policy?['document_options'] as List<dynamic>? ?? const <dynamic>[])
              .cast<Map<String, dynamic>>();
      final match = options.where((o) {
        if (o['document_type'] != type) return false;
        final countries =
            (o['issuing_countries'] as List<dynamic>).cast<String>();
        return countries.isEmpty || countries.contains(issuing);
      }).toList();
      if (match.isEmpty) {
        throw const _MockError(422, 'document_not_supported',
            'not an accepted ID for your region yet');
      }
      if (match.first['manual_review_required'] == true) {
        reviewReasons.add('document_review');
      }
      document = <String, dynamic>{'type': type, 'issuing_country': issuing};
    }

    // All validation passed — apply.
    for (final key in const <String>[
      'legal_first_name', 'legal_middle_name', 'legal_last_name',
      'date_of_birth', 'address_line1', 'address_line2', 'address_city',
      'address_state', 'address_postal_code', 'address_country',
      'transfer_corridor', 'intended_use', 'source_of_funds',
      'expected_volume_band', //
    ]) {
      if (body[key] is String) profile[key] = body[key];
    }
    if (residence != null && needsPolicy) {
      profile['residence_country'] = residence;
      profile['region'] = policy?['region'];
      doc['policy_version'] = kycPolicyVersion;
    }
    if (maskedIdentifier != null) {
      doc['sensitive_identifier'] = maskedIdentifier;
    }
    if (document != null) doc['document'] = document;
    if (reviewReasons.isNotEmpty) {
      doc['requires_manual_review'] = true;
      doc['manual_review_reason'] = reviewReasons.join(',');
    }
    if (doc['kyc_status'] == 'not_started') {
      doc['kyc_status'] = 'in_progress';
    }
    doc['updated_at'] = clock.now().toUtc().toIso8601String();
    return _jsonResponse(200, _profileView(doc));
  }

  PuenteResponse _getOnboardingProfile() =>
      _jsonResponse(200, _profileView(_requireApplicant()));

  List<String> _profileMissing(Map<String, dynamic> doc) {
    final profile = doc['profile'] as Map<String, dynamic>;
    final missing = <String>[];
    for (final field in const <String>[
      'legal_first_name', 'legal_last_name', 'date_of_birth',
      'address_line1', 'address_city', 'address_postal_code',
      'address_country', 'residence_country', 'region', 'transfer_corridor',
      'intended_use', 'source_of_funds', 'expected_volume_band', //
    ]) {
      if (profile[field] == null) missing.add(field);
    }
    if (doc['document'] == null) missing.add('document');
    final residence = profile['residence_country'] as String?;
    if (residence != null) {
      final policy = _policyFixture(residence);
      final requirements = (policy['identifier_requirements'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final oneOf = requirements
          .where((r) => r['requirement'] == 'required_one_of')
          .map((r) => r['identifier_type'])
          .toList();
      final provided =
          (doc['sensitive_identifier'] as Map<String, dynamic>?)?['type'];
      if (oneOf.isNotEmpty && !oneOf.contains(provided)) {
        missing.add('sensitive_identifier');
      }
    }
    return missing;
  }

  bool _consentCurrent(Map<String, dynamic> doc) =>
      doc['consent_at'] != null &&
      doc['disclosure_version'] == kycDisclosureVersion;

  Map<String, dynamic> _profileView(Map<String, dynamic> doc) {
    final profile = doc['profile'] as Map<String, dynamic>;
    final missing = _profileMissing(doc);
    final locked = _lockedKycStatuses.contains(doc['kyc_status'] as String);
    return <String, dynamic>{
      'applicant_id': doc['id'],
      'external_user_id': doc['external_user_id'],
      'kyc_status': doc['kyc_status'],
      'kyc_tier': doc['kyc_tier'],
      'requires_manual_review': doc['requires_manual_review'],
      'contact': <String, dynamic>{
        'phone': doc['phone'],
        'email': doc['email'],
      },
      'profile': <String, dynamic>{
        'legal_first_name': profile['legal_first_name'],
        'legal_middle_name': profile['legal_middle_name'],
        'legal_last_name': profile['legal_last_name'],
        'date_of_birth': profile['date_of_birth'],
        'address': <String, dynamic>{
          'line1': profile['address_line1'],
          'line2': profile['address_line2'],
          'city': profile['address_city'],
          'state': profile['address_state'],
          'postal_code': profile['address_postal_code'],
          'country': profile['address_country'],
        },
        'residence_country': profile['residence_country'],
        'region': profile['region'],
        'transfer_corridor': profile['transfer_corridor'],
        'intended_use': profile['intended_use'],
        'source_of_funds': profile['source_of_funds'],
        'expected_volume_band': profile['expected_volume_band'],
      },
      if (doc['sensitive_identifier'] != null)
        'sensitive_identifier': doc['sensitive_identifier'],
      if (doc['document'] != null) 'document': doc['document'],
      'consent': <String, dynamic>{
        'disclosure_version': doc['disclosure_version'],
        'consent_at': doc['consent_at'],
        'current': _consentCurrent(doc),
      },
      'policy_version': doc['policy_version'],
      'field_editability': locked ? 'review_required' : 'editable',
      'complete': missing.isEmpty,
      'missing': missing,
      'updated_at': doc['updated_at'],
    };
  }

  PuenteResponse _submitConsents(PuenteRequest request) {
    final body = _decodeBody(request);
    final version = body['disclosure_version'] as String?;
    if (version != kycDisclosureVersion) {
      throw const _MockError(409, 'stale_disclosure_version',
          'refresh the policy and re-present disclosures');
    }
    final doc = _requireApplicant();
    final residence = (doc['profile']
        as Map<String, dynamic>)['residence_country'] as String?;
    if (residence == null) {
      throw const _MockError(422, 'residence_country_required',
          'set the profile region before consenting');
    }
    final accepted = (body['accepted'] as List<dynamic>? ?? const <dynamic>[])
        .cast<String>();
    final required = (_policyFixture(residence)['disclosures'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((d) => d['required'] == true)
        .map((d) => d['id'] as String);
    final missing = required.where((id) => !accepted.contains(id)).toList();
    if (missing.isNotEmpty) {
      throw _MockError(422, 'consent_incomplete',
          'consent_incomplete: missing ${missing.join(",")}');
    }
    doc['disclosure_version'] = version;
    doc['consent_at'] = clock.now().toUtc().toIso8601String();
    doc['updated_at'] = doc['consent_at'];
    return _jsonResponse(200, <String, dynamic>{
      'disclosure_version': version,
      'consent_captured': true,
    });
  }

  Map<String, dynamic>? _activeSessionFor(String applicantId) {
    for (final s in _kycSessions.values) {
      if (s['applicant_id'] == applicantId &&
          _activeSessionStatuses.contains(s['status'] as String)) {
        return s;
      }
    }
    return null;
  }

  Map<String, dynamic> _sessionResponse(
    Map<String, dynamic> session,
    String kycStatus, {
    required bool duplicate,
    String? clientToken,
  }) =>
      <String, dynamic>{
        'session_id': session['id'],
        'provider': session['provider'],
        'provider_session_ref': session['provider_session_ref'],
        'status': session['status'],
        'failure_reason': session['failure_reason'],
        'kyc_status': kycStatus,
        'expires_at': session['expires_at'],
        'duplicate': duplicate,
        // The handoff fields travel together or not at all, mirroring
        // `attach_handoff` in Puente (`kyc/mod.rs`): a plain duplicate carries
        // exactly the eight keys above, so clients never see a null where they
        // do not expect a key.
        if (clientToken != null) ...<String, dynamic>{
          'client_token': clientToken,
          // The mock has a token but nothing to open with it — its lifecycle
          // advances through POST /kyc/sessions/{id}/mock-events. The backend
          // says `none` here for exactly this reason, and saying so beats
          // omitting the key and having the client read `unknown`, which means
          // "a surface this build predates" and would mask a real vendor change.
          'verification_surface': 'none',
          'provider_environment': 'mock',
        },
      };

  PuenteResponse _createKycSession() {
    final doc = _requireApplicant();
    final status = doc['kyc_status'] as String;
    if (status == 'approved') {
      throw const _MockError(409, 'already_approved', 'already_approved');
    }
    if (status == 'manual_review') {
      throw const _MockError(409, 'manual_review_pending',
          'verification is being reviewed — no new session needed');
    }
    final missing = _profileMissing(doc);
    if (missing.isNotEmpty) {
      throw _MockError(422, 'profile_incomplete',
          'profile_incomplete: missing ${missing.join(",")}');
    }
    if (!_consentCurrent(doc)) {
      throw const _MockError(
          422, 'consent_required', 'accept the current disclosures first');
    }
    final existing = _activeSessionFor(doc['id'] as String);
    if (existing != null) {
      return _jsonResponse(
          200, _sessionResponse(existing, status, duplicate: true));
    }
    final id = 'ksn_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    final ref = _uuid.v4().replaceAll('-', '').substring(0, 24);
    final now = clock.now().toUtc();
    final session = <String, dynamic>{
      'id': id,
      'applicant_id': doc['id'],
      'provider': 'mock',
      'provider_session_ref': ref,
      'status': 'session_created',
      'failure_reason': null,
      'expires_at': now.add(const Duration(minutes: 30)).toIso8601String(),
      'created_at': now.toIso8601String(),
    };
    _kycSessions[id] = session;
    doc['kyc_status'] = 'in_progress';
    return _jsonResponse(
      201,
      _sessionResponse(
        session,
        'in_progress',
        duplicate: false,
        clientToken: 'mock_session_token_$ref',
      ),
    );
  }

  PuenteResponse _currentKycSession() {
    final doc = _requireApplicant();
    Map<String, dynamic>? latest;
    for (final s in _kycSessions.values) {
      if (s['applicant_id'] != doc['id']) continue;
      if (latest == null ||
          (s['created_at'] as String)
                  .compareTo(latest['created_at'] as String) >
              0) {
        latest = s;
      }
    }
    if (latest == null) {
      throw const _MockError(404, 'no_session', 'no_session');
    }
    // Lazy expiry, mirroring the backend.
    if (_activeSessionStatuses.contains(latest['status'] as String) &&
        DateTime.parse(latest['expires_at'] as String)
            .isBefore(clock.now().toUtc())) {
      latest['status'] = 'expired';
      if (doc['kyc_status'] == 'in_progress' ||
          doc['kyc_status'] == 'processing') {
        doc['kyc_status'] = 'expired';
      }
    }
    return _jsonResponse(
        200,
        _sessionResponse(latest, doc['kyc_status'] as String,
            duplicate: false));
  }

  PuenteResponse _kycMockEvent(String sessionId, PuenteRequest request) {
    final doc = _requireApplicant();
    final session = _kycSessions[sessionId];
    if (session == null || session['applicant_id'] != doc['id']) {
      throw const _MockError(404, 'not_found', 'session not found');
    }
    final body = _decodeBody(request);
    final scenario = body['scenario'] as String?;
    const transitions = <String, String>{
      'document_captured': 'document_capture_started',
      'selfie_captured': 'selfie_started',
      'processing': 'processing',
      'approve': 'approved',
      'reject': 'rejected',
      'manual_review': 'manual_review',
      'expire': 'expired',
      'error': 'error',
    };
    final next = transitions[scenario];
    if (next == null) {
      throw const _MockError(422, 'unknown_scenario', 'unknown_scenario');
    }
    if (!_activeSessionStatuses.contains(session['status'] as String)) {
      throw const _MockError(409, 'terminal_state',
          'session already finished — create a new session to retry');
    }
    session['status'] = next;
    if (next == 'rejected') {
      session['failure_reason'] = body['reason'] as String? ?? 'mock_rejected';
    } else if (next == 'error') {
      session['failure_reason'] =
          body['reason'] as String? ?? 'mock_provider_error';
    }

    // Applicant-level consequence — identical to the backend's
    // applicant_status_after: policy-flagged paths NEVER auto-approve.
    final requiresReview = doc['requires_manual_review'] == true;
    String kycStatus;
    var tier = 'none';
    switch (next) {
      case 'approved':
        if (requiresReview) {
          kycStatus = 'manual_review';
        } else {
          kycStatus = 'approved';
          tier = 'tier1';
        }
      case 'rejected':
        kycStatus = 'rejected';
      case 'manual_review':
        kycStatus = 'manual_review';
      case 'expired':
        kycStatus = 'expired';
      case 'processing':
        kycStatus = 'processing';
      default:
        kycStatus = 'in_progress';
    }
    doc['kyc_status'] = kycStatus;
    doc['kyc_tier'] = tier;
    doc['updated_at'] = clock.now().toUtc().toIso8601String();

    return _jsonResponse(200, <String, dynamic>{
      'session_id': session['id'],
      'status': next,
      'kyc_status': kycStatus,
    });
  }

  PuenteResponse _walletReadiness() {
    final doc = _requireApplicant();
    final missing = <String>[];
    if (_profileMissing(doc).isNotEmpty) missing.add('profile_incomplete');
    if (!_consentCurrent(doc)) missing.add('consent_required');
    if (doc['kyc_status'] != 'approved') missing.add('kyc_not_approved');
    return _jsonResponse(200, <String, dynamic>{
      'ready': missing.isEmpty,
      'kyc_status': doc['kyc_status'],
      'kyc_tier': doc['kyc_tier'],
      'missing': missing,
    });
  }

  PuenteResponse _personalInfo() {
    final doc = _requireApplicant();
    Map<String, dynamic>? latest;
    for (final s in _kycSessions.values) {
      if (s['applicant_id'] != doc['id']) continue;
      if (latest == null ||
          (s['created_at'] as String)
                  .compareTo(latest['created_at'] as String) >
              0) {
        latest = s;
      }
    }
    final view = _profileView(doc);
    view['verification'] = latest == null
        ? null
        : <String, dynamic>{
            'status': latest['status'],
            'provider': latest['provider'],
            'failure_reason': latest['failure_reason'],
          };
    view['manual_review'] = <String, dynamic>{
      'required': doc['requires_manual_review'],
      'pending': doc['kyc_status'] == 'manual_review',
    };
    return _jsonResponse(200, view);
  }

  PuenteResponse _correctionRequest(PuenteRequest request) {
    _requireApplicant();
    final body = _decodeBody(request);
    const correctable = <String>{
      'legal_name', 'date_of_birth', 'address', 'phone', 'email',
      'document', 'sensitive_identifier', 'residence_country', 'other', //
    };
    final field = body['field'] as String?;
    if (field == null || !correctable.contains(field)) {
      throw const _MockError(422, 'invalid_field', 'invalid_field');
    }
    final id = 'cor_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    return _jsonResponse(201, <String, dynamic>{'id': id, 'status': 'pending'});
  }

  // ------------------------------------------------- deposits (external) --
  //
  // Fixture policy: mirrors the Puente deposits backend DEFAULTS
  // (`docs/deposits-external-wallet-design.md`) — same wire shapes, same
  // stable error codes, same state machine. Every number below is a dev
  // FIXTURE and NOT production truth: real quotes, fees, and settlement
  // amounts ALWAYS come from the Puente backend. Amounts are integer
  // minor units end to end; the only doubles are display-only estimate
  // strings, mirroring the backend's labeled-indicative display block.

  /// Fixture: provider gas-receiver fee on a deposit route, in 6-decimal
  /// USDC minor units ($0.18) — mirrors the backend `MockDepositProvider`
  /// (`crates/puente-deposits/src/mock.rs`). NOT production truth.
  static const int depositGasFeeUsdcFixtureMinor = 180000;

  /// Fixture: provider service fee in basis points of the source amount
  /// (0.4%) — mirrors the backend `MockDepositProvider`. NOT production
  /// truth.
  static const int depositServiceFeeBpsFixture = 40;

  /// Fixture: settled amounts at/above this go to `compliance_hold`
  /// instead of crediting — mirrors the backend default
  /// `DEPOSIT_COMPLIANCE_HOLD_THRESHOLD_USDC_MINOR` (5 000 USDC).
  static const int depositComplianceHoldThresholdFixtureMinor = 5000000000;

  /// Fixture: mainnet native Circle USDC mint used as the deposit
  /// destination (verified constant, but the address assignment is mock).
  static const String depositUsdcMintFixture =
      'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';

  /// Fixture: the "route provider contract" spender echoed by prepare.
  /// Clearly fake — a real spender is validated server-side per route.
  static const String depositSpenderFixture =
      '0x1111111111111111111111111111111111111111';

  /// Server-side source-asset allowlist fixture — mirrors the design
  /// doc's `DEPOSIT_ALLOWED_SOURCE_ASSETS` default (USDC on Base and
  /// Ethereum, 1–10 000 USDC bounds).
  static const List<Map<String, dynamic>> depositAssetFixtures =
      <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'base:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
      'network': 'base',
      'chain_id': '8453',
      'symbol': 'USDC',
      'name': 'USDC',
      'decimals': 6,
      'min_amount_minor': 1000000,
      'max_amount_minor': 10000000000,
      'enabled': true,
    },
    <String, dynamic>{
      'id': 'ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      'network': 'ethereum',
      'chain_id': '1',
      'symbol': 'USDC',
      'name': 'USDC',
      'decimals': 6,
      'min_amount_minor': 1000000,
      'max_amount_minor': 10000000000,
      'enabled': true,
    },
  ];

  Future<PuenteResponse> _routeDeposits(
      String method, String path, PuenteRequest request) async {
    // Master flag — mirrors DEPOSITS_ENABLED=false → 503 on every route.
    if (!depositsEnabled) {
      throw const _MockError(503, 'deposits_disabled', 'deposits are disabled');
    }

    // Idempotency middleware parity: every POST requires an
    // Idempotency-Key. The real backend answers 400 with a PLAIN-TEXT
    // body (not the JSON error envelope) — mirror that exactly.
    if (method == 'POST' && request.idempotencyKey == null) {
      return const PuenteResponse(
        statusCode: 400,
        headers: <String, String>{'content-type': 'text/plain'},
        body: 'Missing Idempotency-Key',
      );
    }

    if (method == 'GET' && path == '/deposit-assets') {
      return _jsonResponse(
          200, <String, dynamic>{'data': depositAssetFixtures});
    }
    if (method == 'POST' && path == '/deposit-sessions') {
      return _createDepositSession(request);
    }
    if (method == 'GET' && path == '/deposits') {
      return _listDeposits(request);
    }
    final idMatch = RegExp(r'^/deposit-sessions/([^/]+)$').firstMatch(path);
    if (idMatch != null && method == 'GET') {
      return _jsonResponse(200, _requireDeposit(idMatch.group(1)!));
    }
    final subMatch =
        RegExp(r'^/deposit-sessions/([^/]+)/([a-z-]+)$').firstMatch(path);
    if (subMatch != null) {
      final id = subMatch.group(1)!;
      final action = subMatch.group(2)!;
      if (method == 'POST' && action == 'quotes') {
        return _quoteDepositSession(id);
      }
      if (method == 'POST' && action == 'prepare') {
        return _prepareDepositSession(id);
      }
      if (method == 'POST' && action == 'submission') {
        return _depositSubmission(id, request);
      }
      if (method == 'GET' && action == 'events') {
        _requireDeposit(id);
        return _jsonResponse(200, <String, dynamic>{
          'data': _depositEvents[id] ?? const <Map<String, dynamic>>[],
        });
      }
      if (method == 'POST' && action == 'mock-events') {
        return _depositMockEvent(id, request);
      }
    }
    return _jsonResponse(404, <String, dynamic>{
      'error': 'route_not_found',
      'message': 'mock transport has no deposit handler for $method $path',
    });
  }

  Map<String, dynamic> _requireDeposit(String id) {
    final doc = _deposits[id];
    if (doc == null) {
      throw _MockError(404, 'deposit_not_found', 'deposit $id not found');
    }
    return doc;
  }

  /// Deterministic fake Solana deposit address per user — mirrors
  /// `MockDepositAddresses` on the backend (base58-alphabet, stable for
  /// the same user across calls, obviously not a real keypair).
  String _mockDepositAddress(String userId) =>
      _depositAddressByUser.putIfAbsent(userId, () {
        const alphabet =
            '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
        // FNV-1a 32-bit over the user id → seed a local PRNG so the
        // address is stable per user (and across runs).
        var h = 0x811c9dc5;
        for (final c in userId.codeUnits) {
          h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
        }
        final rng = math.Random(h);
        final buf = StringBuffer();
        for (var i = 0; i < 44; i++) {
          buf.write(alphabet[rng.nextInt(alphabet.length)]);
        }
        return buf.toString();
      });

  void _depositTransition(
    Map<String, dynamic> doc,
    String? from,
    String to, {
    Map<String, dynamic>? detail,
  }) {
    final now = clock.now().toUtc().toIso8601String();
    doc['status'] = to;
    doc['updated_at'] = now;
    // Event shape mirrors `GET …/events` on the real backend exactly:
    // {from_status, to_status, detail, created_at} — no `actor` key, and
    // no event is recorded for session creation (the first event is
    // created → quoted).
    if (from == null) return;
    _depositEvents
        .putIfAbsent(doc['id'] as String, () => <Map<String, dynamic>>[])
        .add(<String, dynamic>{
      'from_status': from,
      'to_status': to,
      'detail': detail,
      'created_at': now,
    });
  }

  PuenteResponse _createDepositSession(PuenteRequest request) {
    final body = _decodeBody(request);
    final userId = body['user_id'] as String?;
    final sourceNetwork = body['source_network'] as String?;
    final sourceAssetId = body['source_asset_id'] as String?;
    final sourceWalletAddress = body['source_wallet_address'] as String?;
    final sourceAmountMinor = body['source_amount_minor'];
    if (userId == null ||
        userId.trim().isEmpty ||
        sourceNetwork == null ||
        sourceAssetId == null ||
        sourceWalletAddress == null ||
        sourceWalletAddress.trim().isEmpty ||
        sourceAmountMinor is! int) {
      throw const _MockError(
          422,
          'invalid_request',
          'user_id, source_network, source_asset_id, source_wallet_address, '
              'source_amount_minor required');
    }
    // Allowlist resolution mirrors the backend `resolve_asset`: unknown
    // network → 422 unsupported_network; known network but unlisted
    // asset → 422 unsupported_asset.
    final networkKnown =
        depositAssetFixtures.any((a) => a['network'] == sourceNetwork);
    if (!networkKnown) {
      throw _MockError(422, 'unsupported_network',
          'network $sourceNetwork is not supported');
    }
    final asset = depositAssetFixtures
        .where((a) =>
            a['network'] == sourceNetwork &&
            a['id'] == sourceAssetId &&
            a['enabled'] == true)
        .toList();
    if (asset.isEmpty) {
      throw _MockError(422, 'unsupported_asset',
          'asset $sourceAssetId on $sourceNetwork is not supported');
    }
    final minMinor = asset.first['min_amount_minor'] as int;
    final maxMinor = asset.first['max_amount_minor'] as int;
    if (sourceAmountMinor < minMinor) {
      throw _MockError(422, 'amount_below_minimum',
          'minimum deposit is $minMinor minor units');
    }
    if (sourceAmountMinor > maxMinor) {
      throw _MockError(422, 'amount_above_maximum',
          'maximum deposit is $maxMinor minor units');
    }
    // EVM wallet shape gate, mirroring the backend's per-family check.
    final hex = sourceWalletAddress.startsWith('0x')
        ? sourceWalletAddress.substring(2)
        : null;
    if (hex == null ||
        hex.length != 40 ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      throw const _MockError(422, 'invalid_request',
          'source_wallet_address is not valid for the source network');
    }
    final displayCurrency = body['display_currency'] as String?;
    if (displayCurrency != null &&
        displayCurrency != 'USD' &&
        displayCurrency != 'MXN') {
      throw const _MockError(
          422, 'invalid_request', 'display_currency must be USD or MXN');
    }

    final id = 'dep_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    final now = clock.now().toUtc().toIso8601String();
    // `source_asset_id` is `{network}:{contract}` — echo the contract.
    final token = sourceAssetId.contains(':')
        ? sourceAssetId.substring(sourceAssetId.indexOf(':') + 1)
        : sourceAssetId;
    final doc = <String, dynamic>{
      'object': 'deposit_session',
      'id': id,
      'user_id': userId,
      'status': 'created',
      'provider': 'mock',
      'risk_status': 'none',
      'source_network': sourceNetwork,
      'source_asset_id': sourceAssetId,
      'source_token': token,
      'source_token_decimals': asset.first['decimals'],
      'source_wallet_address': sourceWalletAddress,
      'source_amount_minor': sourceAmountMinor,
      'destination_network': 'solana',
      'destination_mint': depositUsdcMintFixture,
      'destination_address': _mockDepositAddress(userId),
      'destination_event_index': null,
      'expected_destination_minor': null,
      'minimum_destination_minor': null,
      'actual_destination_minor': null,
      'ledger_transaction_id': null,
      'quote': null,
      'provider_route_id': null,
      'spender': null,
      'approval': null,
      'transaction': null,
      'source_tx_hash': null,
      'destination_tx_signature': null,
      'failure_code': null,
      'failure_details': null,
      'display_currency': displayCurrency,
      'display_estimate': null,
      'created_at': now,
      'updated_at': now,
      'submitted_at': null,
      'detected_at': null,
      'confirmed_at': null,
      'credited_at': null,
      'swept_at': null,
    };
    _deposits[id] = doc;
    return _jsonResponse(201, doc);
  }

  /// Fixture quote math mirroring the backend `MockDepositProvider`
  /// (labeled — NOT production truth): service fee = 0.4% of source, gas
  /// receiver fee = $0.18, destination = source − fees, minimum = 99% of
  /// expected (1% slippage), TTL mirrors `DEPOSIT_QUOTE_TTL_SECS` (2 min).
  /// All integer arithmetic on minor units.
  PuenteResponse _quoteDepositSession(String id) {
    final doc = _requireDeposit(id);
    final status = doc['status'] as String;
    if (status != 'created' && status != 'quoted') {
      // quoted → quoted (re-quote) is legal until prepared; nothing else.
      throw _MockError(409, 'illegal_state', 'cannot quote a $status deposit');
    }
    final src = doc['source_amount_minor'] as int;
    final serviceFee = src * depositServiceFeeBpsFixture ~/ 10000;
    const gasFee = depositGasFeeUsdcFixtureMinor;
    final totalFeesMinor = serviceFee + gasFee;
    final expected = src - totalFeesMinor;
    final minimum = expected * 99 ~/ 100;
    final now = clock.now();
    final expiresAt = now.add(_quoteTtl).toUtc().toIso8601String();

    final display =
        _depositDisplayFixture(doc['display_currency'] as String?, expected);
    // Fee `kind` is the vendor string verbatim (kind == label on the real
    // wire); `amount_usd` is a 6-decimal display string.
    final quote = <String, dynamic>{
      'source_amount_minor': src,
      'expected_destination_minor': expected,
      'minimum_destination_minor': minimum,
      'fees': <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'Service fee',
          'label': 'Service fee',
          'amount_minor': serviceFee,
          'amount_usd': _usdMinorToDecimalString(serviceFee),
        },
        <String, dynamic>{
          'kind': 'Gas receiver fee',
          'label': 'Gas receiver fee',
          'amount_minor': gasFee,
          'amount_usd': _usdMinorToDecimalString(gasFee),
        },
      ],
      'total_fees_usd': _usdMinorToDecimalString(totalFeesMinor),
      'expires_at': expiresAt,
      'display': display,
    };
    doc['quote'] = quote;
    doc['expected_destination_minor'] = expected;
    doc['minimum_destination_minor'] = minimum;
    doc['display_estimate'] = display;
    _depositTransition(doc, status, 'quoted', detail: <String, dynamic>{
      'expected_destination_minor': expected,
      'minimum_destination_minor': minimum,
      'expires_at': expiresAt,
    });
    return _jsonResponse(200, doc);
  }

  /// Display-only estimate block — mirrors the backend `display_estimate`
  /// exactly: USD is 1:1 with the expected USDC credit
  /// (`estimated_credit_minor` int, `fx_rate` `"1"`); MXN carries NO
  /// estimate and NO rate in this MVP (`null`s, labeled `indicative`) —
  /// no FX liability exists until a conversion actually executes.
  Map<String, dynamic> _depositDisplayFixture(
      String? currency, int expectedUsdcMinor) {
    if (currency == 'MXN') {
      return <String, dynamic>{
        'currency': 'MXN',
        'estimated_credit_minor': null,
        'fx_rate': null,
        'fx_type': 'indicative',
      };
    }
    return <String, dynamic>{
      'currency': 'USD',
      'estimated_credit_minor': expectedUsdcMinor,
      'fx_rate': '1',
      'fx_type': 'indicative',
    };
  }

  /// 6-decimal USD minor units → 6-decimal display string
  /// (`493827` → `"0.493827"`) — mirrors the backend
  /// `minor_to_decimal_string(…, 6)`.
  String _usdMinorToDecimalString(int minor) {
    final whole = minor ~/ 1000000;
    final frac = (minor % 1000000).toString().padLeft(6, '0');
    return '$whole.$frac';
  }

  PuenteResponse _prepareDepositSession(String id) {
    final doc = _requireDeposit(id);
    final status = doc['status'] as String;
    if (status == 'created') {
      throw const _MockError(
          409, 'quote_required', 'request a quote before preparing');
    }
    if (status != 'quoted') {
      throw _MockError(
          409, 'illegal_state', 'cannot prepare a $status deposit');
    }
    final quote = (doc['quote'] as Map).cast<String, dynamic>();
    final expiresAt = DateTime.parse(quote['expires_at'] as String);
    if (!clock.now().toUtc().isBefore(expiresAt)) {
      // The session stays quoted — the client re-quotes and retries.
      throw _MockError(
          409, 'quote_expired', 'deposit quote expired at $expiresAt');
    }

    final chainId = doc['source_network'] == 'base' ? 8453 : 1;
    final token = doc['source_token'] as String;
    final from = doc['source_wallet_address'] as String;
    final amount = doc['source_amount_minor'] as int;
    doc['provider_route_id'] = _uuid.v4();
    doc['spender'] = depositSpenderFixture;
    // Exact-amount approval (never unlimited) + route transaction. The
    // calldata below is an obviously-fake fixture payload.
    doc['approval'] = <String, dynamic>{
      'type': 'evm_erc20_approval',
      'chain_id': chainId,
      'token': token,
      'spender': depositSpenderFixture,
      'amount_minor': amount.toString(),
      'from': from,
      'to': token,
      'data': '0x095ea7b3${'0' * 128}',
      'value': '0',
    };
    doc['transaction'] = <String, dynamic>{
      'type': 'evm_transaction',
      'chain_id': chainId,
      'from': from,
      'to': depositSpenderFixture,
      'data': '0x38ed1739${'0' * 192}',
      'value': '0',
      'gas_limit': '250000',
      'max_fee_per_gas': null,
      'max_priority_fee_per_gas': null,
    };
    _depositTransition(doc, status, 'prepared', detail: <String, dynamic>{
      'provider_route_id': doc['provider_route_id'],
      'spender': doc['spender'],
    });
    return _jsonResponse(200, doc);
  }

  PuenteResponse _depositSubmission(String id, PuenteRequest request) {
    final doc = _requireDeposit(id);
    final status = doc['status'] as String;
    if (status != 'prepared') {
      throw _MockError(409, 'illegal_state',
          'cannot report a submission on a $status deposit');
    }
    final body = _decodeBody(request);
    final hash = body['transaction_hash'] as String?;
    if (hash == null || hash.trim().isEmpty) {
      throw const _MockError(
          422, 'invalid_request', 'transaction_hash required');
    }
    doc['source_tx_hash'] = hash;
    doc['submitted_at'] = clock.now().toUtc().toIso8601String();
    _depositTransition(doc, status, 'submitted',
        detail: <String, dynamic>{'source_tx_hash': hash});

    // Mirror the real backend: the session STAYS `submitted` — nothing
    // settles on its own. Progression is driven through the mock-events
    // scenarios (`settle`, `settle_finalized`, …), exactly like
    // `VENDOR_MODE=mock` on the server (smoke.sh precedent).
    return _jsonResponse(200, doc);
  }

  void _detectDepositSettlement(Map<String, dynamic> doc) {
    doc['detected_at'] = clock.now().toUtc().toIso8601String();
    doc['destination_tx_signature'] ??= 'mock${_uuid.v4().replaceAll('-', '')}';
    doc['destination_event_index'] ??= 0;
    _depositTransition(doc, doc['status'] as String, 'destination_detected',
        detail: <String, dynamic>{
          'tx_signature': doc['destination_tx_signature'],
          'event_index': doc['destination_event_index'],
        });
  }

  /// Ledger-credit attempt, mirroring the backend `finalize_and_credit`
  /// gates: a settled amount at/above the compliance threshold parks in
  /// `compliance_hold` (risk_status `hold`, NO ledger credit) until an
  /// explicit `compliance_release` + `credit`.
  void _creditDeposit(Map<String, dynamic> doc) {
    final now = clock.now().toUtc().toIso8601String();
    doc['detected_at'] ??= now;
    doc['confirmed_at'] = now;
    doc['destination_tx_signature'] ??= 'mock${_uuid.v4().replaceAll('-', '')}';
    doc['destination_event_index'] ??= 0;
    // The ledger credits the ACTUAL settled amount. The mock settles
    // exactly the expected fixture amount (source verbatim when never
    // quoted — mock-events can credit an unquoted session).
    final amount = (doc['expected_destination_minor'] ??
        doc['source_amount_minor']) as int;
    final held = amount >= depositComplianceHoldThresholdFixtureMinor &&
        doc['risk_status'] != 'released';
    if (held) {
      doc['risk_status'] = 'hold';
      _depositTransition(doc, doc['status'] as String, 'compliance_hold',
          detail: <String, dynamic>{'amount_minor': amount});
      return;
    }
    doc['actual_destination_minor'] = amount;
    doc['credited_at'] = now;
    doc['ledger_transaction_id'] = _uuid.v4();
    _depositTransition(doc, doc['status'] as String, 'credited',
        detail: <String, dynamic>{'amount_minor': amount});
  }

  void _failDeposit(Map<String, dynamic> doc, String code, String details) {
    doc['failure_code'] = code;
    doc['failure_details'] = details;
    _depositTransition(doc, doc['status'] as String, code);
  }

  static const Set<String> _terminalDepositStatuses = <String>{
    'swept', 'reconciled', 'cancelled', 'quote_expired', 'user_rejected',
    'source_failed', 'route_failed', 'wrong_asset', 'wrong_destination',
    'amount_mismatch', 'compliance_rejected', 'manual_review', //
  };

  /// Mock-events lifecycle driver — mirrors the backend's
  /// `VENDOR_MODE=mock` scenario vocabulary verbatim
  /// (`puente-api/src/deposits.rs`): `quote | prepared | submitted |
  /// routing | settle | settle_finalized | underpay | wrong_asset |
  /// route_failed | compliance_hold | compliance_release | credit |
  /// sweep`. Unknown scenarios answer `400 invalid_request: unknown
  /// scenario "…"` exactly like the server.
  PuenteResponse _depositMockEvent(String id, PuenteRequest request) {
    final doc = _requireDeposit(id);
    final body = _decodeBody(request);
    final scenario = body['scenario'] as String?;
    final status = doc['status'] as String;

    bool preCredit() =>
        status != 'credited' && !_terminalDepositStatuses.contains(status);

    switch (scenario) {
      case 'quote':
        return _quoteDepositSession(id);
      case 'prepared':
        return _prepareDepositSession(id);
      case 'submitted':
        if (status != 'prepared') {
          throw _MockError(
              409, 'illegal_state', 'cannot submit a $status deposit');
        }
        doc['source_tx_hash'] ??= 'mocktx${_uuid.v4().replaceAll('-', '')}';
        doc['submitted_at'] = clock.now().toUtc().toIso8601String();
        _depositTransition(doc, status, 'submitted',
            detail: <String, dynamic>{'source_tx_hash': doc['source_tx_hash']});
      case 'routing':
        if (status != 'submitted') {
          throw _MockError(
              409, 'illegal_state', 'cannot route a $status deposit');
        }
        _depositTransition(doc, status, 'routing');
      case 'settle':
        // Settlement at `confirmed` commitment: detected, not credited
        // (the default finalized policy waits for settle_finalized).
        if (status == 'credited') return _jsonResponse(200, doc);
        if (status != 'submitted' && status != 'routing') {
          throw _MockError(
              409, 'illegal_state', 'cannot settle a $status deposit');
        }
        _detectDepositSettlement(doc);
      case 'settle_finalized':
        // Re-finalizing a credited deposit is a no-op on the real
        // backend (the credit posts exactly once) — mirror the 200.
        if (status == 'credited') return _jsonResponse(200, doc);
        if (status != 'submitted' &&
            status != 'routing' &&
            status != 'destination_detected') {
          throw _MockError(
              409, 'illegal_state', 'cannot finalize a $status deposit');
        }
        if (status != 'destination_detected') _detectDepositSettlement(doc);
        _creditDeposit(doc);
      case 'compliance_hold':
        if (!preCredit()) {
          throw _MockError(
              409, 'illegal_state', 'cannot hold a $status deposit');
        }
        doc['risk_status'] = 'hold';
        _depositTransition(doc, status, 'compliance_hold');
      case 'compliance_release':
        // Mirrors the backend: releasing only flips risk_status to
        // `released` — the status STAYS compliance_hold until an explicit
        // `credit` scenario posts the ledger credit.
        if (status != 'compliance_hold') {
          throw _MockError(409, 'illegal_state', 'deposit $id is not on hold');
        }
        doc['risk_status'] = 'released';
        doc['updated_at'] = clock.now().toUtc().toIso8601String();
      case 'credit':
        if (status == 'credited') return _jsonResponse(200, doc);
        if (status != 'destination_detected' &&
            !(status == 'compliance_hold' &&
                doc['risk_status'] == 'released')) {
          throw _MockError(
              409, 'illegal_state', 'cannot credit a $status deposit');
        }
        _creditDeposit(doc);
      case 'sweep':
        // The backend sweep scenario sweeps whatever has credited and
        // returns 200 either way — an uncredited session is a no-op.
        if (status == 'credited') {
          doc['swept_at'] = clock.now().toUtc().toIso8601String();
          _depositTransition(doc, status, 'swept');
        }
      case 'underpay':
        if (!preCredit()) {
          throw _MockError(
              409, 'illegal_state', 'cannot underpay a $status deposit');
        }
        doc['detected_at'] ??= clock.now().toUtc().toIso8601String();
        _failDeposit(doc, 'amount_mismatch', 'settled below quoted minimum');
      case 'wrong_asset':
        if (!preCredit()) {
          throw _MockError(
              409, 'illegal_state', 'cannot mis-asset a $status deposit');
        }
        doc['detected_at'] ??= clock.now().toUtc().toIso8601String();
        _failDeposit(doc, 'wrong_asset', 'unexpected asset received');
      case 'route_failed':
        if (!preCredit()) {
          throw _MockError(
              409, 'illegal_state', 'cannot fail a $status deposit');
        }
        _failDeposit(doc, 'route_failed', 'provider route failed');
      default:
        // Backend shape verbatim: 400 {"error":"invalid_request: unknown
        // scenario \"x\""} — the SDK strips at ':' → code invalid_request.
        throw _MockError(400, 'invalid_request: unknown scenario "$scenario"',
            'unknown scenario');
    }
    return _jsonResponse(200, doc);
  }

  PuenteResponse _listDeposits(PuenteRequest request) {
    final userId = request.query['user_id'];
    final limit = int.tryParse(request.query['limit'] ?? '20') ?? 20;
    final startingAfter = request.query['starting_after'];
    var docs = _deposits.values
        .where((d) => userId == null || d['user_id'] == userId)
        .toList()
      ..sort((a, b) {
        final ai = a['created_at'] as String? ?? '';
        final bi = b['created_at'] as String? ?? '';
        final byDate = bi.compareTo(ai);
        // Stable tiebreak so paging is deterministic at equal timestamps.
        return byDate != 0
            ? byDate
            : (b['id'] as String).compareTo(a['id'] as String);
      });
    if (startingAfter != null) {
      final idx = docs.indexWhere((d) => d['id'] == startingAfter);
      docs = idx < 0 ? <Map<String, dynamic>>[] : docs.sublist(idx + 1);
    }
    return _jsonResponse(
        200, <String, dynamic>{'data': docs.take(limit).toList()});
  }

  // ------------------------------------------------------------- internals
  PuenteResponse _jsonResponse(int status, Object body) {
    final encoded = jsonEncode(body);
    final requestId = 'req_${_uuid.v4().replaceAll('-', '').substring(0, 16)}';
    return PuenteResponse(
      statusCode: status,
      headers: <String, String>{
        'content-type': 'application/json',
        'x-request-id': requestId,
      },
      body: encoded,
    );
  }

  Map<String, dynamic> _decodeBody(PuenteRequest request) {
    final body = request.body;
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return body.cast<String, dynamic>();
    final encoded = request.encodedBody();
    if (encoded.isEmpty) return const <String, dynamic>{};
    return (jsonDecode(encoded) as Map).cast<String, dynamic>();
  }

  Money _readMoney(Map<String, dynamic> body, String key) {
    final raw = body[key];
    if (raw is! Map) {
      throw _MockError(422, 'invalid_request', '$key must be an object');
    }
    return Money.fromJson(raw.cast<String, dynamic>());
  }

  @override
  void close() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _quotes.clear();
    _transfers.clear();
    _accounts.clear();
    _idempotencyCache.clear();
    _consumedQuotes.clear();
    _applicants.clear();
    _applicantIdByExternalId.clear();
    _kycSessions.clear();
    _currentApplicantId = null;
    _deposits.clear();
    _depositEvents.clear();
    _depositAddressByUser.clear();
  }
}

class _MockError implements Exception {
  final int statusCode;
  final String code;
  final String message;
  const _MockError(this.statusCode, this.code, this.message);
}

class _CachedResponse {
  final PuenteResponse response;
  final DateTime cachedAt;
  const _CachedResponse(this.response, this.cachedAt);
}
