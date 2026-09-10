# Contract Status — `puente_railway` SDK ↔ Puente backend

> **⚠️ SUPERSEDED (2026-08-26).** The snapshot below is from 2026-06-11 and
> describes the v0.1.0 era. It is **out of date**: the SDK is now v0.5.0, the
> `/v1` quotes/transfers/beneficiaries/onboarding/KYC/wallet-readiness routes
> are live on Puente `main`, the deposits surface ships on
> `feature/external-wallet-deposits` behind `DEPOSITS_ENABLED`, and
> `test/integration/deposits_live_backend_test.dart` walks the full deposit
> flow against a running `puente-api`. pesito consumes this package (git-pinned
> to `a089c4d`). Do not treat the "none of the methods work" TL;DR or the
> ❌-heavy route table below as current; they are retained only as history.
> See [`portal-migration-impact.md`](portal-migration-impact.md) for the SDK's
> (nil) impact under the Turnkey → Portal backend signer migration.

Authoritative snapshot of how the SDK lines up against the
`Aztlan-Software/Puente` Rust workspace, as of 2026-06-11. This file is
the dedup target — if you're about to write an issue about the SDK being
broken, check here first.

## TL;DR (2026-06-11 — superseded, see banner above)

This SDK was authored against an API surface the Puente backend has not
yet implemented. **None of the resource methods (`quotes`, `transfers`,
`accounts`, `clabe`) work against the live `puente-api` binary.** The
webhook verifier expects a Stripe-style signature format that Puente's
outbound webhook handler — also not implemented — has not committed to.

## Route table

| SDK call | Live Puente route? |
|---|---|
| `client.quotes.create(...)` → `POST /quotes` | ❌ |
| `client.transfers.create(...)` → `POST /transfers` | ❌ |
| `client.transfers.retrieve(id)` → `GET /transfers/:id` | ❌ |
| `client.transfers.list(...)` → `GET /transfers` | ❌ |
| `client.transfers.cancel(id)` → `POST /transfers/:id/cancel` | ❌ |
| `client.accounts.create(...)` → `POST /accounts` | ❌ |
| `client.accounts.retrieve(id)` → `GET /accounts/:id` | ❌ |
| `client.accounts.update(id, ...)` → `PATCH /accounts/:id` | ❌ |
| `client.clabe.lookup(clabe)` → `GET /clabe/:clabe` | ❌ |
| n/a (server only) | `GET /health` ✅, `GET /balances` ✅, `POST /webhooks/etherfuse` ✅ |

Puente issue #14 commits to publishing an OpenAPI 3.1 spec; once the
v1 routes land (Puente #9, #10, #11), this SDK will need to be either
regenerated from the spec or updated by hand and re-released.

## Webhook signature format

| Property | This SDK (`lib/src/webhooks/webhook_verifier.dart`) | Puente inbound (`crates/puente-offramp/src/webhook.rs`) |
|---|---|---|
| Header | argument | `X-Signature` |
| Format | `t=<unix_seconds>,v1=<hex_hmac_sha256>` | bare hex or `sha256=<hex>` |
| Signed bytes | `"<t>.<payload>"` (UTF-8 encoded) | raw request body |
| Tolerance | ±5 min | none (Etherfuse-driven) |
| Constant-time compare | **No** (`!=` on hex strings) — vulnerable | Yes (`subtle::ConstantTimeEq`) |
| Event vocabulary | `WebhookEventType.transferSettled`, `transferFailed`, `accountUpdated` (etc.) — product-shaped | `order_updated`, `swap_updated`, `customer_updated`, `bank_account_updated`, `kyc_updated` — Etherfuse-shaped |

The two are different protocols. Puente's *outbound* merchant webhooks
(separate from the *inbound* Etherfuse webhooks) are tracked in Puente
issue #13 but have no agreed format yet.

## Base URLs

| Environment | SDK config | DNS resolves? | Service deployed? |
|---|---|---|---|
| `PuenteEnvironment.sandbox` | `https://sandbox.api.puenterailway.com/v1` | not verified | no |
| `PuenteEnvironment.production` | `https://api.puenterailway.com/v1` | not verified | no |

`puente-api` listens on `0.0.0.0:8080` locally and has no Cloud Run /
production deploy yet (Puente issue #19).

## What is real today inside this SDK

The non-contract pieces work and are worth keeping:

- HTTP client wrapper with timeout, JSON decode, request-id propagation.
- Exception hierarchy (`AuthException`, `ValidationException`,
  `RateLimitException`, `ApiException`, `PuenteException`).
- `RetryInterceptor` (429 + 5xx, exponential backoff with jitter).
- `AuthInterceptor` (Bearer header + `X-SDK-Version`).
- `json_serializable`-based model layer.
- Test scaffolding (`flutter_test` + `mockito`).

## Recommended rewrites once the contract lands

1. Replace `lib/src/resources/*` with bindings generated from
   Puente's `/v1/openapi.json` (Puente issue #14).
2. Replace the timestamp + hex string compare in `WebhookVerifier`
   with a `subtle`-style constant-time compare in pure Dart, and
   refactor it to read the header(s) Puente actually emits — proposed
   issues `sdk-01-webhook-format-mismatch` and
   `sdk-02-webhook-compare-timing`.
3. Add an `Idempotency-Key` opt-in on `transfers.create` (and any
   other money-moving methods) — `sdk-03-idempotency-key-support`.
4. Pin a real GitHub repo + homepage in `pubspec.yaml`; the current
   URLs (`https://github.com/puente-railway/puente_railway_flutter`)
   point at a non-existent organization — `sdk-04-pubspec-metadata-fix`.

## Existing SDK-side test gaps

- `WebhookVerifier` tests at `test/webhook_verifier_test.dart` use
  `DateTime.now()`, so they're flaky if the system clock drifts during
  the test run. Inject a clock — `sdk-05-deterministic-clock-in-tests`.
- No tests for `RetryInterceptor`'s exception swallow path (lines 32–34
  in `retry_interceptor.dart`). A 5xx that arrives only on attempt N
  with all earlier attempts throwing is silently masked.
