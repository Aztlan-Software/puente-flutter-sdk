/// Applicant-level KYC status — backend-authoritative.
///
/// Mirrors `kyc_applicants.kyc_status` in Puente (migration 0012). Clients
/// RENDER this state; nothing a client sends can set it directly (approval
/// only ever comes from a provider result or backend review).
enum KycStatus {
  notStarted('not_started'),
  inProgress('in_progress'),
  processing('processing'),
  approved('approved'),
  rejected('rejected'),
  manualReview('manual_review'),
  expired('expired'),

  /// Forward-compatibility fallback: an unrecognized wire value must never
  /// crash a deployed app (old app ↔ new backend). Treat as "not approved".
  unknown('unknown');

  final String wire;
  const KycStatus(this.wire);

  static KycStatus fromWire(String? value) {
    if (value == null) return KycStatus.unknown;
    for (final s in KycStatus.values) {
      if (s.wire == value) return s;
    }
    return KycStatus.unknown;
  }

  /// The ONLY state in which wallet features may unlock — and even then the
  /// app must gate on `WalletReadiness.ready`, not on this enum alone.
  bool get isApproved => this == KycStatus.approved;
}

/// How the applicant is meant to reach the provider's verification UI.
///
/// The client switches on THIS, not on [KycSession.provider] and not on
/// whether some string happens to look like a URL. Presentation and vendor are
/// different questions: one backend can serve both surfaces at once, and
/// turning on a native arm later should cost a build flag rather than a wire
/// change plus a coordinated app release.
enum KycVerificationSurface {
  /// Open [KycSession.verificationUrl] in a browser. Verify the host first.
  hostedUrl('hosted_url'),

  /// Hand [KycSession.clientToken] to the provider's native SDK.
  nativeSdk('native_sdk'),

  /// Nothing to launch — the mock provider advances through
  /// `POST /v1/kyc/sessions/{id}/mock-events` instead.
  none('none'),

  /// Forward-compatibility fallback. A surface this build does not know how
  /// to present is NOT launchable: guessing would send someone about to
  /// upload a government ID somewhere we cannot reason about.
  unknown('unknown');

  final String wire;
  const KycVerificationSurface(this.wire);

  static KycVerificationSurface fromWire(String? value) {
    if (value == null) return KycVerificationSurface.unknown;
    for (final s in KycVerificationSurface.values) {
      if (s.wire == value) return s;
    }
    return KycVerificationSurface.unknown;
  }

  /// Whether this build can actually present this surface.
  bool get launchable =>
      this == KycVerificationSurface.hostedUrl ||
      this == KycVerificationSurface.nativeSdk;
}

/// Verification-session lifecycle (provider-side progress).
///
/// Mirrors `kyc_sessions.status`. The mock provider walks these states via
/// `POST /v1/kyc/sessions/{id}/mock-events`; Incode Omni maps its
/// `onboardingStatus` webhook values onto the same vocabulary server-side.
enum VerificationSessionStatus {
  /// No session exists yet (client-side synthetic state — never on the wire
  /// for an existing session).
  notStarted('not_started'),
  sessionCreated('session_created'),
  documentCaptureStarted('document_capture_started'),
  selfieStarted('selfie_started'),
  processing('processing'),
  approved('approved'),
  rejected('rejected'),
  manualReview('manual_review'),
  expired('expired'),
  error('error'),
  unknown('unknown');

  final String wire;
  const VerificationSessionStatus(this.wire);

  static VerificationSessionStatus fromWire(String? value) {
    if (value == null) return VerificationSessionStatus.unknown;
    for (final s in VerificationSessionStatus.values) {
      if (s.wire == value) return s;
    }
    return VerificationSessionStatus.unknown;
  }

  /// Whether the session can still advance (mirrors the backend's
  /// active-session set — terminal sessions need a NEW session to retry).
  bool get isActive =>
      this == VerificationSessionStatus.sessionCreated ||
      this == VerificationSessionStatus.documentCaptureStarted ||
      this == VerificationSessionStatus.selfieStarted ||
      this == VerificationSessionStatus.processing;

  bool get isTerminal =>
      this == VerificationSessionStatus.approved ||
      this == VerificationSessionStatus.rejected ||
      this == VerificationSessionStatus.manualReview ||
      this == VerificationSessionStatus.expired ||
      this == VerificationSessionStatus.error;
}
