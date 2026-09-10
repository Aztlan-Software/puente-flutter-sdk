# Changelog

## 0.7.0 - 2026-09-06

**Didit verification handoff.** `KycSession` can now tell a client how to
launch verification, which it previously could not.

- `KycSession.verificationUrl` — the hosted verification page, present on the
  creation and resume responses only. Like `clientToken` it is excluded from
  `toJson()` and masked in `toString()`: both are live capabilities over one
  person's identity verification, and anyone holding the URL can submit their
  own document and selfie into that session. Always check the host before
  opening it.
- `KycVerificationSurface` (`hosted_url` | `native_sdk` | `none` | `unknown`)
  and `KycSession.verificationSurface`. Switch on this rather than on
  `provider` or on whether a string looks like a URL — presentation and vendor
  are different questions, one backend can serve both surfaces at once, and an
  unrecognised surface reports `launchable == false` rather than being guessed
  at.
- `KycSession.providerEnvironment` (`live` | `sandbox` | `mock`). Worth
  showing in the UI: for Didit the environment is a property of the API key's
  application rather than of any URL, and the vendor's management API does not
  report it, so a sandbox key in production is otherwise invisible.
- `provider` may now be `didit`.

All three fields are optional and tolerant of absence, so this build talks to
an older backend unchanged.

## 0.6.0 — 2026-08-27

**Full-audit hardening.** Security, correctness, and API-safety fixes from
an end-to-end audit of the SDK (architecture, API surface, error handling,
credential handling, financial-operation safety). No wire-contract changes:
the routes, request bodies, and response shapes are identical to 0.5.0.

### Security

- **Path identifiers can no longer retarget an authenticated request.**
  Dart's `Uri` resolves dot segments while assembling a path, so an
  identifier containing `..` silently redirected the request to a different
  endpoint *with the `Authorization` header still attached*.
  `clabe.lookup('../../v1/transfers')` issued an authenticated
  `GET /v1/transfers` — a value typed into a CLABE form field could redirect
  a lookup onto an unrelated endpoint — and
  `transfers.retrieve('../../../balances')` escaped the `/v1` prefix
  entirely. Every caller-supplied path identifier now passes through
  `ResourceBase.pathSegment`, which rejects separators, percent escapes,
  query/fragment delimiters, control characters, and dot segments before
  anything reaches the wire. Pre-encoded traversal (`%2e%2e`) is rejected
  too, since it normalizes back to `..`.
- **A cleartext `http://` base URL is refused** for any non-loopback host.
  `baseUrlOverride` exists for pointing at a local `puente-api`; nothing
  previously stopped it from carrying a production key to an arbitrary
  `http://` host, where the bearer token, the CLABE, the beneficiary name,
  and the raw SSN/ITIN/CURP submitted through `onboarding.updateProfile`
  would all travel in the clear. `http://127.0.0.1`, `http://localhost`,
  and every `https://` URL are unaffected.
- **Observers no longer receive key material.** The `Authorization` value
  is masked to `Bearer ***`; the previous masking emitted the last four
  characters of the secret into a sink that is commonly forwarded to Sentry
  or a log aggregator. `Idempotency-Key` keeps its head/tail masking — it
  is a correlator, not a credential.
- **Argument guards survive a release build.** The paired-field checks in
  `onboarding.updateProfile` were `assert`s, which Dart strips from release
  builds; in production a half-supplied pair was serialized as
  `{"type": "ssn", "value": null}` instead of failing locally. They are now
  runtime guards in every build mode.

### Correctness

- **An ambiguous outcome is now safely retryable.** `PuenteException` gains
  `idempotencyKey`, populated on every failure that carried one. A timeout
  on `transfers.create` does not mean the transfer did not happen; because
  the SDK mints the key internally, a caller previously had no way to retry
  except with a freshly minted key — which the server reads as a second,
  distinct transfer. Retry with `e.idempotencyKey` and the server replays
  the original outcome instead of executing again.
- **Side-effecting POSTs that lacked an idempotency key now send one.**
  The transport retries POSTs on 5xx and on transport errors, so
  `onboarding.submitConsents` (a consent record with legal weight) and
  `personalInfo.requestCorrection` (a reviewable ticket) could be applied
  twice by the SDK itself. `onboarding.updateProfile` and `accounts.update`
  gained keys as well, and all four accept an explicit `idempotencyKey`.
- **A decode failure is a `PuenteException`.** `PuenteException` is
  documented as the single catch-all for every SDK failure, but model
  constructors let raw `FormatException` / `TypeError` / `ArgumentError`
  escape on an unexpected wire shape — so a caller who wrote
  `on PuenteException` crashed on any backend wire change. Response
  decoding now runs through `ResourceBase.decode` / `decodeList` and
  surfaces the new `DecodeException`, which carries the target model, the
  originating `requestId`, and the underlying error as `cause`.
- **`StaleQuoteException` keeps its context.** A server-emitted
  `409 quote_expired` dropped `requestId` — on precisely the money-critical
  path where support correlation matters most. It now carries `requestId`
  and `idempotencyKey`, and reads timestamps from the ambient `clock`
  rather than `DateTime.now()`, matching the rest of the SDK and making
  `withClock` tests deterministic.

### API

- New `DecodeException` and `InvalidArgumentException`, both
  `PuenteException` subclasses, exported from
  `package:puente_railway/puente_railway.dart`.
- New `idempotencyKey` field on `PuenteException` and every subclass.
- `transfers.watch` and `deposits.watch` accept `throwOnTimeout`
  (default `false`, preserving existing behavior). By default a timed-out
  poll completes the stream normally, which is indistinguishable from
  settlement — a UI that renders `onDone` as success reports a
  still-in-flight transfer as finished. Opt in to receive a
  `TimeoutException` instead.
- New optional `idempotencyKey` parameters on `accounts.update`,
  `onboarding.updateProfile`, `onboarding.submitConsents`,
  `personalInfo.requestCorrection`, and `kyc.sendMockEvent`.

All additions are source-compatible with 0.5.0. The one behavior change a
caller can observe is that a malformed 2xx body now raises
`DecodeException` rather than a raw `FormatException`; code that caught
`PuenteException` gains coverage it did not have, and code that caught
`FormatException` explicitly should switch to `DecodeException` (the
original error remains available as `cause`).

## 0.5.0 — 2026-07-17

**External-wallet deposits client.** Typed surface for the Puente
deposits domain (`docs/deposits-external-wallet-design.md`,
`feature/external-wallet-deposits`): a user deposits a supported
stablecoin from their own wallet, Puente routes it (via a
provider-neutral meta-router) to native Circle USDC on Solana at a
user-specific deposit address, verifies settlement independently, and
credits the ledger exactly once. The SDK renders backend state and hands
signing requests to the external wallet — it is never the financial
source of truth: all amounts are integer minor units passed through
verbatim, and no fee/FX/slippage math exists client-side.

### New resources

- `client.deposits` (`DepositsResource`) — `getSupportedAssets` (the
  server-side source-asset allowlist), `createSession` (assigns the
  user's Solana deposit address), `retrieve`, `getQuote`
  (`POST …/quotes`; re-quote legal until prepared), `prepare` (returns a
  typed `PreparedDeposit` with the exact-amount approval + route
  transaction signing requests and the validated spender),
  `reportSubmission` (tx hash is a hint — the server verifies
  settlement independently), `events` (append-only transition audit),
  `list` (per-user, paged), `watch` (polling lifecycle stream with the
  `TransfersResource.watch` semantics — stops on terminal states,
  `compliance_hold` is emitted but non-terminal), and the dev-only
  `sendMockEvent` (drives the VENDOR_MODE=mock lifecycle; the route does
  not exist on live backends).
- Per-hop idempotency: every POST auto-generates a UUIDv4 key;
  `DepositsResource.deriveHopKey(key, 'quote')` derives stable
  `'$key:quote'`-style keys so one user gesture maps to replayable keys
  across the whole flow.
- Error mapping: server `409 quote_expired` surfaces as the existing
  `StaleQuoteException`; every other stable code (`unsupported_asset`,
  `deposits_disabled`, `capability_unavailable`, `deposit_not_found`,
  `quote_required`, `amount_below_minimum`, `amount_above_maximum`,
  `illegal_state`, …) rides `ApiException.code` untouched.

### New models

`SupportedDepositAsset`, `DepositSession` (full wire doc: quote
sub-object, destination fields, provider route id, signing handoff,
failure code/details, and the whole timestamp trail),
`DepositQuote` + `DepositFee` (integer minor-unit amounts; USD totals as
display-only decimal strings), `DepositDisplayEstimate` (regional
display block — FX is labeled `indicative`, no MXN liability exists
until an FX conversion actually executes), `DepositEvent`,
`PreparedDeposit`, and the unknown-tolerant `DepositStatus` enum
(`isSettled` / `isFailure` / `isTerminal`; sweep states are post-credit
internal and count as settled-terminal for `watch`). New Dart 3 sealed
union `PuenteSigningRequest` — `EvmTransactionSigningRequest`,
`EvmErc20ApprovalSigningRequest`, `SolanaTransactionSigningRequest`, and
the `UnknownSigningRequest` fallback (`fromJson` dispatches on `type`
and never throws on a new variant, so a new backend signing scheme can't
crash a deployed app; `switch` over the union stays compile-time
exhaustive). Malformed session payloads throw a typed `FormatException`
instead of a cast crash.

### Mock transport

`MockTransport` models the full deposit lifecycle with the design doc's
exact wire shapes and stable error codes (`deposit_not_found` 404,
`quote_expired` 409, `quote_required` 409, `illegal_state` 409,
`unsupported_asset` 400, `amount_below_minimum` / `amount_above_maximum`
400, `capability_unavailable` 503 for Solana-source,
`deposits_disabled` 503 via the new `depositsEnabled` toggle):
deterministic per-user deposit addresses, fixture route quotes
(documented as NOT production truth — $0.35 fixture fees netted with
integer math, 1% slippage floor, 2-minute TTL, labeled-indicative
display estimates), prepare with exact-amount approval + route
transaction payloads, and a `settlementLatency`-driven progression
`submitted → routing → destination_detected → credited` after
`reportSubmission` (synchronous at `Duration.zero`). Exceptional paths
move only via `POST /deposit-sessions/:id/mock-events` (`quote`,
`prepared`, `submitted`, `routing`, `settle`, `settle_finalized`,
`underpay`, `wrong_asset`, `route_failed`, `compliance_hold`,
`compliance_release`, `credit`, `sweep`, `quote_expired`) — the mock
never fails or settles on its own beyond the happy-path timers.
Idempotency replay covers all the new POSTs.

### Housekeeping

- `packageVersion` const synced with pubspec at `0.5.0`.
- 49 new tests (model round-trips incl. unknown-enum and sealed-union
  dispatch, resource flow, mock contract pins, integration demo flow);
  suite now 200.

### Companion Puente changes

`feature/external-wallet-deposits`: `crates/puente-deposits` (domain
state machine, `DepositRouteProvider` trait with Trustware live adapter
+ deterministic mock, per-user deposit addresses, RPC settlement
verification, atomic ledger credit, treasury sweep, reconciliation),
migration `0013_external_wallet_deposits.sql`, `/v1/deposit-*` routes in
`puente-api`, and worker loop functions. See
`docs/deposits-external-wallet-design.md` +
`docs/deposits-trustware-capabilities.md`.

## 0.4.0 — 2026-07-07

**Onboarding / KYC / Personal Information client.** Typed surface for the
Puente end-user KYC domain (backend migration 0012 + `kyc::router`,
`feature/puente-kyc-incode-scaffold`). The backend stays the sole KYC
authority — nothing in this SDK can set `kyc_status`/`kyc_tier`; clients
submit data and render backend state.

### New resources

- `client.onboarding` (`OnboardingResource`) — `createApplicant`
  (merchant-credential bootstrap; returns the one-time `pat_…` applicant
  bearer token), `getPolicy` (region-aware policy: allowed documents,
  identifier requirements incl. the US SSN/ITIN one-of group, versioned
  disclosures, manual-review flags, `requires_legal_review`/`mock_only`
  labels), `getProfile`, `updateProfile` (server-validated partial
  update), `submitConsents` (versioned; stale versions 409).
- `client.kyc` (`KycResource`) — `createSession` (duplicate-safe: an
  in-flight session is returned with `duplicate=true`), `currentSession`,
  `walletReadiness` (the ONLY wallet gate), and the dev-only
  `sendMockEvent` (drives the VENDOR_MODE=mock lifecycle; the route does
  not exist on live backends).
- `client.personalInfo` (`PersonalInfoResource`) — masked, region-aware
  Personal Information view + review-routed `requestCorrection`.

### New models

`ApplicantCredentials`, `RegionPolicy` (+`PolicyDocumentOption`,
`PolicyIdentifierRequirement`, `PolicyDisclosure`, `PolicyChoiceOption`,
`LegalReviewStatus`, `IdentifierRequirementLevel`), `OnboardingProfile`
(+`MaskedIdentifier`, `IdentityDocumentChoice`, `OnboardingAddress`,
`OnboardingConsent`), `KycSession`, `MockKycEventResult`,
`WalletReadiness`, `PersonalInfo` (+`VerificationSummary`),
`CorrectionRequestReceipt`, `KycStatus`, `VerificationSessionStatus`.
All status enums are unknown-tolerant (`.unknown` fallback) so an old app
never crashes on a new backend value.

### Security posture

- Applicant/session tokens are excluded from `toJson()` and masked in
  `toString()` — credentials never round-trip through caches or logs.
- Sensitive identifiers (SSN/ITIN/CURP) surface as type+last4
  `MaskedIdentifier` only; the raw value is submitted once and hashed
  server-side.
- Applicant-scoped auth rides the existing `PuenteConfig.tokenProvider`
  mechanism (no `sk_` keys in mobile code).

### Mock transport

`MockTransport` models the whole onboarding/KYC surface with the exact
backend wire shapes and error codes (`underage`, `identifier_not_allowed`,
`document_not_supported`, `stale_disclosure_version`, `profile_incomplete`,
`consent_required`, `terminal_state`, `already_approved`,
`profile_locked`, `no_session`, …), single-active-session semantics, the
mock-events state machine, and policy-flagged paths that route to manual
review even on provider approval. Deterministic; the mock never
self-approves.

### Housekeeping

- `packageVersion` const (was stale at `0.3.0`) synced with pubspec at
  `0.4.0`.
- 45 new tests (196 assertions across the KYC flow); suite now 151 tests.

### Companion Puente changes

`feature/puente-kyc-incode-scaffold`: migration `0012_kyc_onboarding.sql`,
`kyc::{router,policy,provider}`, applicant `pat_…` bearer auth in
`auth_middleware`, Incode Omni provider scaffold behind `VENDOR_MODE`.

## 0.3.1 — 2026-07-06

**Mock fee fixture: USD-anchored.** `MockTransport`'s cross-border flat
fee was `100` minor units of *whatever the source currency was*, so an
MXN-source quote (the region-change corridor) charged $1.00 MXN
(~US$0.05) instead of the backend's $1.00 USD default policy. The fixture
is now anchored to $1.00 USD and charged in the source currency at the
fixture rate: USD source → 100, MXN source → 1 973 (=$19.73 MXN), USDC
source → 1 000 000 (6-decimal minor units). Wire shape is unchanged —
fees stay denominated in the source currency per the backend contract.

- `crossBorderFlatFeeFixtureMinor` renamed to
  `crossBorderFlatFeeUsdFixtureMinor` (dev-only mock surface).
- New contract tests pin the MXN- and USDC-source fee equivalents.

## 0.3.0 — 2026-07-05

**Treasury & Profit Management alignment.** The SDK is now a pure typed
client of the Puente Rust backend: it never calculates fees, FX, totals,
or margins — it deserializes what the backend decided and exposes it
safely.

### New treasury models
- `FeeBreakdown` — itemized backend fees (`flat_fee_minor`,
  `fx_spread_fee_minor`, `vendor_fee_minor`, `total_fee_minor`,
  `currency`) as tagged `Money` values. Decode-only; the total is taken
  verbatim from the wire, never summed locally.
- `VendorCostBreakdown` — per-vendor settlement costs on receipts
  (`etherfuse_minor`, `network_minor`, `other_minor`). Decode-only.
- `TransferReceipt` + `ReceiptMetadata` — the settlement receipt from
  `GET /v1/transfers/{id}/receipt`, including the cNFT proof block
  (`folio`, `asset_id`, `metadata_uri`, `mint_signature`).
- `TransferIntent` — the typed `POST /v1/transfers` request body. The
  intent is the only thing a client submits; amounts and fees always
  come from the referenced backend quote.
- `CurrencyLeg` enum (`USDC` / `OUSD` / `CETES`, unknown-tolerant) and a
  new `Currency.ousd` value.

### Real-backend quote contract
- `Quote.fromJson` now also accepts the current backend shape
  (`quote_id`, `source_amount_minor` / `destination_amount_minor`,
  `fx_rate` decimal string, `total_fee_minor`, `total_cost_minor`,
  `transfer_type`, `currency_leg`, `fee_breakdown`) alongside the legacy
  shape. New optional fields: `Quote.feeBreakdown`, `Quote.currencyLeg`,
  `Quote.transferType`, `Quote.totalCost`. `exchangeRate` is documented
  display-only (parsed from the wire string).
- `Transfer` gains optional `feeBreakdown`, `quoteId`, and
  `transferType`, parsed when the server sends them.
- `QuotesResource.create` sends both the legacy body keys and the
  current backend keys (`source_amount_minor`, `destination_currency`)
  in one JSON object, plus an optional `beneficiaryCountry` parameter.

### Receipt endpoint + intents
- `TransfersResource.receipt(id)` — `GET /v1/transfers/{id}/receipt`,
  returns a `TransferReceipt` (409 `receipt_unavailable: …` until the
  transfer settles).
- `TransfersResource.createFromIntent(intent)` — execute a
  `TransferIntent` directly. `create` gains optional `senderUserId` /
  `receiverUserId` for P2P transfers.

### Mock stripped of financial computation
- `MockTransport` no longer computes fees or FX (the 50 bps fee math and
  net-of-fee conversion are gone). It now serves clearly documented
  **dev fixtures** mirroring backend defaults: same-currency quotes have
  a **zero** fee and `fx_rate "1"`; cross-currency quotes use a flat
  100-minor-unit fee fixture and a fixed fixture rate table. Real
  numbers ALWAYS come from the backend quote.
- Mock quotes are stored in-memory; mock transfers resolve the
  referenced quote and use its amounts **verbatim** — unknown
  `quote_id` → 404 `quote_not_found`, expired → 409 `quote_expired`.
- Mock now emits the full real-backend quote response shape alongside
  the legacy keys, and serves `GET /transfers/{id}/receipt` with a
  deterministic cNFT fixture.
- `PuenteClient` now **throws `StateError`** when
  `PuenteEnvironment.mock` is used in a release build
  (`dart.vm.product`).

### BREAKING: import moves
- `MockTransport` moved out of the main barrel to
  `package:puente_railway/testing.dart` (dev-only fixture adapter).
  `PuenteClient.mock()` keeps working unchanged.
- `WebhookVerifier` moved out of the main barrel to
  `package:puente_railway/server.dart` — webhook HMAC secrets must
  NEVER ship in a mobile app.

### Mobile-safe auth
- New `PuenteConfig.tokenProvider` (`Future<String> Function()`): when
  set, `HttpTransport` resolves the `Authorization` bearer fresh on
  every request attempt from your backend-minted short-lived session
  token. `apiKey` is now optional; `sk_` merchant keys are documented
  SERVER-SIDE ONLY. Config throws `ArgumentError` when neither source is
  provided (non-mock); `tokenProvider` wins when both are set.

### Housekeeping
- Dropped unused `json_annotation` / `json_serializable` /
  `build_runner` dependencies (models are hand-written; no `.g.dart`
  files exist).
- New GitHub Actions CI: format check, `dart analyze --fatal-infos`,
  `dart test` on pushes to `main` and PRs.

## 0.2.0 — 2026-06-11

**Production-grade rewrite.** Breaking API changes; existing 0.1.x
callers will need to update.

### Architecture
- New layered design: `PuenteClient` → `PuenteTransport` (abstract)
  → resources / models. Transport options are `HttpTransport` (real),
  `MockTransport` (in-memory, deterministic), and a swap-in slot for
  custom transports (golden tests, record/replay).
- New `PuenteRemittance` high-level facade for the
  `quote → transfer → watch` flow Pesito's demo uses.
- New `PuenteEnvironment` values: `mock`, `testnet`, `sandbox`,
  `production`. `PuenteClient.mock()` works fully offline.

### Money + currency
- `Currency` is now an `enum` with `decimals` and ISO-style `code`,
  mirroring `puente_core::Currency` in the Rust workspace.
- `Money` now uses `minorUnits` + `Currency` (was `cents` + `String`).
  Currency mismatch on arithmetic throws `StateError`. New
  `Money.fromMinor`, `Money.major`, `Money.fromDecimal` constructors;
  the decimal parser uses integer math (no floating-point loss).

### Webhooks
- `WebhookVerifier` now accepts **both** signature formats Puente
  emits: Stripe-style `t=…,v1=…` (product-shaped outbound) and raw
  hex `X-Signature` (Etherfuse-shaped inbound).
- **Security fix:** HMAC compare is now constant-time on the decoded
  byte arrays (was `!=` on hex strings — timing-attackable). Closes
  proposed issue `sdk-02-webhook-compare-timing`.
- Inject a `Clock` via `package:clock` for deterministic tests. The
  test suite uses `withClock(Clock.fixed(...))` so timestamp checks no
  longer flake.
- `WebhookException` now carries a typed `WebhookFailureReason` so
  callers can branch on `malformedHeader` / `staleTimestamp` /
  `signatureMismatch` / `invalidJson` / `misconfigured`.

### Resources + idempotency
- Every money-moving resource method (`quotes.create`,
  `transfers.create`, `transfers.cancel`, `accounts.create`) accepts
  an optional `idempotencyKey`. The SDK auto-generates a UUIDv4 when
  the caller doesn't supply one. Header is `Idempotency-Key`. Closes
  proposed issue `sdk-03-idempotency-key-support`.
- `transfers.watch(id)` streams lifecycle updates as a
  `Stream<Transfer>` until a terminal state — polling logic moves out
  of UI code.

### Errors
- `TransportException` is a new typed exception for "request never
  reached the server" (timeout, DNS, TLS). Distinct from
  `ApiException` (which is "server answered, status was bad"). UX can
  finally tell those two cases apart.
- `RetryInterceptor`'s silent exception swallow is gone; the new
  `HttpTransport` reports every retry attempt to a `PuenteObserver`
  and surfaces a `TransportException` after the retry budget is
  exhausted.

### Observability
- New `PuenteObserver` hook for `onRequest` / `onResponse` /
  `onRetry` / `onError`. Defaults to silent; pass a subclass to wire
  Sentry / OpenTelemetry / print logging.
- `Authorization` and `Idempotency-Key` are masked in observer events.

### Metadata fixes
- `pubspec.yaml` `homepage` / `repository` / `issue_tracker` now point
  at `github.com/Aztlan-Software/puente-flutter-sdk`. Closes proposed
  `sdk-04-pubspec-metadata-fix`.
- Dropped `flutter_test` for unit tests; the SDK now uses
  `package:test` so the core works in pure Dart (server, CLI). Flutter
  widget tests can still consume the package — they just go in the
  example app, not the SDK itself.
- Dropped the `json_serializable` build step. Models are hand-written
  with explicit `fromJson`/`toJson` — fewer moving parts at install
  time, generated `.g.dart` files no longer churn in PRs.

### Tests
- 62 unit + integration tests, all passing under `dart test`.
- Webhook verifier suite covers Stripe-style, raw-hex, tampered
  payloads, stale timestamps, malformed headers, constant-time
  compare, misconfiguration, and the `sdk-02` timing-attack regression.
- New `test/integration/demo_flow_test.dart` end-to-end test that
  walks the exact "CLABE lookup → quote → transfer → watch lifecycle
  → idempotent retry" flow Pesito's testnet demo will run.

### Companion Puente changes
- `Aztlan-Software/Puente` adds opt-in in-memory `/v1/{quotes,transfers,
  accounts,clabe}` routes behind `PUENTE_ENABLE_DEMO_ROUTES=1`. Lets
  the SDK's `HttpTransport` integration-test against a real
  `puente-api` binary while the production routes are still being
  built (Puente issues #9, #10, #11).

### Breaking changes summary
- `Money({cents, currency: String})` → `Money.fromMinor(int, Currency)`.
- `PuenteClient(apiKey: …, environment: …)` →
  `PuenteClient(config: PuenteConfig(...))`. A `PuenteClient.mock()`
  helper covers the common no-config case.
- `QuotesResource.create(sourceAmount, sourceCurrency, targetCurrency)`
  → `QuotesResource.create(sourceAmount, targetCurrency)`. The source
  currency now comes from `sourceAmount.currency` — eliminates the
  duplicate-source-currency footgun.

## 0.1.0

- Initial release
- QuotesResource: create
- TransfersResource: create, retrieve, list, cancel
- AccountsResource: create, retrieve, update
- ClabeResource: lookup
- WebhookVerifier with HMAC-SHA256
- Sandbox + production environments
- Exponential backoff retry
