# Portal Migration — SDK Impact Assessment

**Verdict: this SDK requires ZERO code changes** for the Puente backend's Turnkey → Portal Enclave
MPC signing/wallet-provider migration.

**Date:** 2026-08-26. **Roadmap:** the phased plan lives in `pesito/plan.md` (workflow
`portal-cenote-2026-08-26`); backend design detail is in `Aztlan-Software/Puente` under
`docs/portal-migration/`.

## Why the SDK is unaffected

The migration swaps *who signs Solana transactions on the backend* (Turnkey → Portal). The SDK never
participates in signing and holds no key material, so a backend signer change is invisible to it.

Verified structural facts:

- **The SDK is a pure REST client with CI-enforced zero-custody.** `tool/no_secrets_audit.sh` runs
  as a gate job before the build and forbids secrets, credentials, fee/FX math, or direct vendor
  calls. `crypto ^3.0.3` is used *only* for webhook HMAC verification.
- **No signing, no keys, no balance API.** A grep of `lib/` for `privateKey|mnemonic|Keypair|
  secp256k1|ed25519|FlutterSecureStorage` returns nothing load-bearing; there is no `getBalance`, no
  `Wallet` model, and no signing method anywhere.
- **`PuenteSigningRequest` is a pass-through.** The sealed union (`evm_transaction |
  evm_erc20_approval | solana_transaction | unknown`) is built server-side and forwarded verbatim by
  the app's wallet connector; the SDK never constructs, mutates, or signs it. Whether the backend
  produced that request via Turnkey or Portal does not change its wire shape.
- **Auth is unchanged.** The SDK authenticates with a `tokenProvider` (user-scoped session /
  applicant `pat_` tokens) or an API key over TLS; the signer swap does not touch the auth surface,
  the base URLs, or any resource contract (`quotes`, `transfers`, `clabe`, `onboarding`, `kyc`,
  `personalInfo`, `deposits`, `remittance`).

## The one place a change *would* be required — and why it isn't happening

If the product ever moved to **per-user embedded wallets in the app** via Portal's client-side
Flutter SDK, that would touch this package (or a sibling) and reverse the standing "clients never
hold keys" rule. That is an explicit **non-goal** of this migration — Portal is used only as a
*backend* Enclave MPC provider. So the SDK stays a thin, zero-custody REST client.

## What this PR contains

- This impact note.
- A "superseded" banner on `docs/contract-status.md`, which was dated 2026-06-11 and wrongly claimed
  none of the SDK methods work against the live backend (the SDK is v0.5.0 and pesito consumes it).

No changes to `lib/`, `pubspec.yaml`, or the public API.
