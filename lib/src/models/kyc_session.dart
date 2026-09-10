import 'package:equatable/equatable.dart';

import 'kyc_status.dart';

/// A verification session (`POST /v1/kyc/sessions`,
/// `GET /v1/kyc/sessions/current`).
///
/// [clientToken] and [verificationUrl] are present ONLY on the creation and
/// resume responses. Neither is persisted server-side and neither is ever
/// returned from `GET /v1/kyc/sessions/current`; treat both as ephemeral.
///
/// That is a security property, not an implementation detail: both are live
/// capabilities over one person's identity verification. Anyone holding the
/// URL can submit their own document and selfie into that session and be
/// approved as that applicant, so neither value may be written to disk, put
/// in a log, or round-tripped through a JSON cache. [toJson] omits both and
/// [toString] masks them.
class KycSession extends Equatable {
  final String sessionId;

  /// `mock` | `incode` | `didit`.
  final String provider;

  /// Opaque provider ref (Incode interviewId / mock ref).
  final String? providerSessionRef;
  final VerificationSessionStatus status;
  final String? failureReason;
  final KycStatus kycStatus;
  final DateTime expiresAt;

  /// True when an in-flight session already existed and was returned
  /// instead of creating a duplicate.
  final bool duplicate;

  /// Creation/resume only. The token a provider's NATIVE SDK initializes with
  /// (Incode's `/omni/start` JWT, Didit's 12-character `session_token`).
  final String? clientToken;

  /// Creation/resume only. The hosted verification page to open in a browser.
  ///
  /// Always check the host before launching it — see
  /// `KycLauncher.isTrustedVerificationUrl` in the app. A URL is a capability
  /// here, and an unexpected origin must never be opened just because the
  /// backend said so.
  final String? verificationUrl;

  /// Which of the two above the client should actually use. Switch on this
  /// rather than on [provider] or on the shape of a string.
  final KycVerificationSurface verificationSurface;

  /// `live` | `sandbox` | `mock`, when the provider reports it.
  ///
  /// Worth surfacing in the UI. For Didit the environment is a property of
  /// the API key's application rather than of any URL, and the vendor's
  /// management API does not report it — so a sandbox key in production is
  /// otherwise invisible until it starts approving everyone against mocks.
  final String? providerEnvironment;

  const KycSession({
    required this.sessionId,
    required this.provider,
    required this.status,
    required this.kycStatus,
    required this.expiresAt,
    required this.duplicate,
    this.providerSessionRef,
    this.failureReason,
    this.clientToken,
    this.verificationUrl,
    this.verificationSurface = KycVerificationSurface.unknown,
    this.providerEnvironment,
  });

  factory KycSession.fromJson(Map<String, dynamic> json) => KycSession(
        sessionId: json['session_id'] as String,
        provider: json['provider'] as String? ?? 'unknown',
        providerSessionRef: json['provider_session_ref'] as String?,
        status: VerificationSessionStatus.fromWire(json['status'] as String?),
        failureReason: json['failure_reason'] as String?,
        kycStatus: KycStatus.fromWire(json['kyc_status'] as String?),
        expiresAt: json['expires_at'] is String
            ? DateTime.parse(json['expires_at'] as String).toUtc()
            : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        duplicate: json['duplicate'] as bool? ?? false,
        clientToken: json['client_token'] as String?,
        verificationUrl: json['verification_url'] as String?,
        verificationSurface: KycVerificationSurface.fromWire(
            json['verification_surface'] as String?),
        providerEnvironment: json['provider_environment'] as String?,
      );

  /// Deliberately EXCLUDES `clientToken` and `verificationUrl` — both are
  /// live capabilities over this applicant's verification and must not
  /// round-trip through JSON caches or logs. `verificationSurface` and
  /// `providerEnvironment` are safe: they describe the session, they do not
  /// grant access to it.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'session_id': sessionId,
        'provider': provider,
        if (providerSessionRef != null)
          'provider_session_ref': providerSessionRef,
        'status': status.wire,
        if (failureReason != null) 'failure_reason': failureReason,
        'kyc_status': kycStatus.wire,
        'expires_at': expiresAt.toIso8601String(),
        'duplicate': duplicate,
        'verification_surface': verificationSurface.wire,
        if (providerEnvironment != null)
          'provider_environment': providerEnvironment,
      };

  @override
  String toString() => 'KycSession($sessionId, $provider, ${status.wire}, '
      'surface: ${verificationSurface.wire}, token: ****, url: ****)';

  @override
  List<Object?> get props => [
        sessionId,
        provider,
        providerSessionRef,
        status,
        failureReason,
        kycStatus,
        expiresAt,
        duplicate,
        clientToken,
        verificationUrl,
        verificationSurface,
        providerEnvironment,
      ];
}

/// Result of driving the MOCK verification lifecycle
/// (`POST /v1/kyc/sessions/{id}/mock-events` — VENDOR_MODE=mock only; the
/// route does not exist in live mode).
class MockKycEventResult extends Equatable {
  final String sessionId;
  final VerificationSessionStatus status;
  final KycStatus kycStatus;

  const MockKycEventResult({
    required this.sessionId,
    required this.status,
    required this.kycStatus,
  });

  factory MockKycEventResult.fromJson(Map<String, dynamic> json) =>
      MockKycEventResult(
        sessionId: json['session_id'] as String,
        status: VerificationSessionStatus.fromWire(json['status'] as String?),
        kycStatus: KycStatus.fromWire(json['kyc_status'] as String?),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'session_id': sessionId,
        'status': status.wire,
        'kyc_status': kycStatus.wire,
      };

  @override
  List<Object?> get props => [sessionId, status, kycStatus];
}
