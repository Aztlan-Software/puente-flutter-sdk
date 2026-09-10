import '../models/kyc_session.dart';
import '../models/wallet_readiness.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// Identity-verification sessions and the wallet-readiness gate
/// (`/v1/kyc/*`, `/v1/wallet/readiness`). Applicant-token authenticated.
///
/// The backend is the sole KYC authority: verification outcomes arrive
/// from the provider (webhooks) or — in local mock mode only — from
/// [sendMockEvent]. Nothing in this resource can approve an applicant.
class KycResource extends ResourceBase {
  /// Build the resource. Normally accessed as `client.kyc`.
  KycResource(super.transport);

  /// `POST /v1/kyc/sessions` — start (or resume) a verification session.
  ///
  /// Requires a complete profile and a current consent (422
  /// `profile_incomplete` / `consent_required` otherwise). When an
  /// in-flight session already exists it is returned with
  /// `duplicate == true` instead of creating a second one. The response's
  /// [KycSession.clientToken] is the one-time provider handoff token.
  Future<KycSession> createSession({String? idempotencyKey}) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/kyc/sessions',
      body: const <String, dynamic>{},
      idempotencyKey: key,
    ));
    return decode(response, KycSession.fromJson,
        target: 'KycSession', idempotencyKey: key);
  }

  /// `GET /v1/kyc/sessions/current` — the latest session (any state).
  /// Throws `ApiException(code: 'no_session')` (404) before the first
  /// session exists. Sessions past their expiry are lazily marked
  /// `expired` by this call.
  Future<KycSession> currentSession() async {
    final response = await request(
      const PuenteRequest(method: 'GET', path: '/kyc/sessions/current'),
    );
    return decode(response, KycSession.fromJson, target: 'KycSession');
  }

  /// `POST /v1/kyc/sessions/{id}/mock-events` — drive the MOCK
  /// verification lifecycle. LOCAL/TEST ONLY: the route exists solely in
  /// `VENDOR_MODE=mock` backends (404 in live — which is itself refused
  /// on staging/prod).
  ///
  /// Scenarios: `document_captured | selfie_captured | processing |
  /// approve | reject | manual_review | expire | error`. Terminal
  /// sessions reject further events (409 `terminal_state`) — retry via a
  /// new [createSession].
  Future<MockKycEventResult> sendMockEvent({
    required String sessionId,
    required String scenario,
    String? reason,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/kyc/sessions/${pathSegment(sessionId, 'sessionId')}/mock-events',
      body: <String, dynamic>{
        'scenario': scenario,
        if (reason != null) 'reason': reason,
      },
      idempotencyKey: key,
    ));
    return decode(response, MockKycEventResult.fromJson,
        target: 'MockKycEventResult', idempotencyKey: key);
  }

  /// `GET /v1/wallet/readiness` — the backend-authoritative wallet gate.
  /// Gate every wallet feature on [WalletReadiness.ready]; local state can
  /// never unlock the wallet.
  Future<WalletReadiness> walletReadiness() async {
    final response = await request(
      const PuenteRequest(method: 'GET', path: '/wallet/readiness'),
    );
    return decode(response, WalletReadiness.fromJson,
        target: 'WalletReadiness');
  }
}
