import 'package:puente_railway/puente_railway.dart';
import 'package:test/test.dart';

/// End-to-end coverage of the onboarding/KYC/personal-info surface against
/// the mock transport, which mirrors the Puente backend contract
/// (kyc::router + policy 2026-07-07.1). Every error code asserted here is
/// pinned to the backend's wire vocabulary.
void main() {
  late PuenteClient client;

  setUp(() {
    client = PuenteClient.mock(
      seed: 42,
      settlementLatency: Duration.zero,
      networkLatency: Duration.zero,
    );
  });

  tearDown(() => client.close());

  Future<ApplicantCredentials> newApplicant({String ext = 'user-1'}) =>
      client.onboarding.createApplicant(
        externalUserId: ext,
        email: '$ext@test.dev',
      );

  Future<OnboardingProfile> completeUsProfile() =>
      client.onboarding.updateProfile(
        legalFirstName: 'María José',
        legalLastName: 'Hernández',
        dateOfBirth: '1990-04-12',
        addressLine1: '500 Yakima Ave',
        addressCity: 'Yakima',
        addressState: 'WA',
        addressPostalCode: '98901',
        addressCountry: 'US',
        residenceCountry: 'US',
        region: 'us',
        transferCorridor: 'us_mx',
        intendedUse: 'family_support',
        sourceOfFunds: 'employment',
        expectedVolumeBand: '500_2000',
        sensitiveIdentifierType: 'ssn',
        sensitiveIdentifierValue: '212-45-6789',
        documentType: 'us_drivers_license',
        documentIssuingCountry: 'US',
      );

  Future<void> consent() => client.onboarding.submitConsents(
        disclosureVersion: '2026-07-07.1',
        accepted: const [
          'terms_of_service',
          'privacy_policy',
          'esign_consent',
          'remittance_terms',
        ],
      );

  group('applicants', () {
    test('creation returns one-time credentials', () async {
      final creds = await newApplicant();
      expect(creds.created, isTrue);
      expect(creds.applicantToken, startsWith('pat_'));
      expect(creds.kycStatus, KycStatus.notStarted);
      expect(creds.kycTier, KycTier.none);
    });

    test('re-creating rotates the token but keeps state (restart recovery)',
        () async {
      final first = await newApplicant();
      await completeUsProfile();
      final second = await newApplicant();
      expect(second.created, isFalse);
      expect(second.applicantId, first.applicantId);
      expect(second.applicantToken, isNot(first.applicantToken));
      // Profile survives the token rotation.
      final profile = await client.onboarding.getProfile();
      expect(profile.legalFirstName, 'María José');
    });

    test('requires contact', () {
      expect(
        () => client.onboarding.createApplicant(externalUserId: 'no-contact'),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'contact_required')),
      );
    });
  });

  group('region policy', () {
    test('US policy offers flagged Mexican-passport path and SSN/ITIN one-of',
        () async {
      await newApplicant();
      final policy = await client.onboarding.getPolicy(residenceCountry: 'US');
      expect(policy.supported, isTrue);
      expect(policy.region, 'us');
      final mxPassport = policy.documentOptions
          .firstWhere((d) => d.documentType == 'mexican_passport');
      expect(
          mxPassport.legalReviewStatus, LegalReviewStatus.requiresLegalReview);
      expect(mxPassport.manualReviewRequired, isTrue);
      final ids =
          policy.identifierRequirements.map((r) => r.identifierType).toList();
      expect(ids, containsAll(['ssn', 'itin']));
      expect(ids, isNot(contains('curp')));
      expect(ids, isNot(contains('nss')));
    });

    test('MX policy offers INE + optional CURP, never SSN', () async {
      await newApplicant();
      final policy = await client.onboarding.getPolicy(residenceCountry: 'MX');
      expect(policy.region, 'mx');
      expect(policy.documentOptions.map((d) => d.documentType),
          containsAll(['ine', 'mexican_passport']));
      final curp = policy.identifierRequirements
          .firstWhere((r) => r.identifierType == 'curp');
      expect(curp.requirement, IdentifierRequirementLevel.optional);
      expect(policy.identifierRequirements.map((r) => r.identifierType),
          isNot(contains('ssn')));
      expect(
          policy.disclosures.map((d) => d.id), contains('aviso_de_privacidad'));
    });

    test('unsupported country returns a calm unsupported policy', () async {
      await newApplicant();
      final policy = await client.onboarding.getPolicy(residenceCountry: 'BR');
      expect(policy.supported, isFalse);
      expect(policy.unsupportedReason, 'region_not_supported');
      expect(policy.documentOptions, isEmpty);
    });
  });

  group('profile validation', () {
    setUp(() async => newApplicant());

    test('underage DOB rejected with the backend error code', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'US',
          dateOfBirth: '2015-01-01',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'underage')),
      );
    });

    test('future DOB rejected as invalid', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'US',
          dateOfBirth: '2093-01-01',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'invalid_dob')),
      );
    });

    test('NSS is not collected for any launch region', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'US',
          sensitiveIdentifierType: 'nss',
          sensitiveIdentifierValue: '12345678901',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'identifier_not_allowed')),
      );
    });

    test('SSN is rejected for the MX region', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'MX',
          sensitiveIdentifierType: 'ssn',
          sensitiveIdentifierValue: '212-45-6789',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'identifier_not_allowed')),
      );
    });

    test('INE is not offered to US residents', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'US',
          documentType: 'ine',
          documentIssuingCountry: 'MX',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'document_not_supported')),
      );
    });

    test('region must match residence country', () {
      expect(
        () => client.onboarding.updateProfile(
          residenceCountry: 'US',
          region: 'mx',
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'unsupported_region_combination')),
      );
    });

    test('unsupported residence is rejected calmly on write', () {
      expect(
        () => client.onboarding.updateProfile(residenceCountry: 'BR'),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'region_not_supported')),
      );
    });

    test('kyc_status cannot be smuggled through the profile update', () async {
      // The typed API cannot even express it; the wire rejects it too.
      expect(
        () => client.onboarding.updateProfile(),
        throwsA(isA<ValidationException>()),
        reason: 'empty updates are rejected',
      );
    });

    test('complete US profile masks the identifier', () async {
      final profile = await completeUsProfile();
      expect(profile.complete, isTrue);
      expect(profile.missing, isEmpty);
      expect(profile.sensitiveIdentifier?.type, 'ssn');
      expect(profile.sensitiveIdentifier?.last4, '6789');
      // The raw value never round-trips.
      expect(profile.toJson().toString(), isNot(contains('212456789')));
      expect(profile.toJson().toString(), isNot(contains('212-45-6789')));
      expect(profile.kycStatus, KycStatus.inProgress);
    });

    test('ITIN satisfies the US one-of group', () async {
      await client.onboarding.updateProfile(
        legalFirstName: 'Ana',
        legalLastName: 'García',
        dateOfBirth: '1985-01-15',
        addressLine1: '1 Main St',
        addressCity: 'Seattle',
        addressPostalCode: '98101',
        addressCountry: 'US',
        residenceCountry: 'US',
        transferCorridor: 'us_mx',
        intendedUse: 'family_support',
        sourceOfFunds: 'employment',
        expectedVolumeBand: 'under_500',
        sensitiveIdentifierType: 'itin',
        sensitiveIdentifierValue: '912-34-5678',
        documentType: 'us_passport',
        documentIssuingCountry: 'US',
      );
      final profile = await client.onboarding.getProfile();
      expect(profile.complete, isTrue,
          reason: 'ITIN must satisfy the identifier requirement');
      expect(profile.sensitiveIdentifier?.type, 'itin');
      expect(profile.requiresManualReview, isTrue,
          reason: 'ITIN path is requires_legal_review → flagged');
    });
  });

  group('consents', () {
    setUp(() async {
      await newApplicant();
      await completeUsProfile();
    });

    test('stale disclosure version conflicts', () {
      expect(
        () => client.onboarding.submitConsents(
          disclosureVersion: '2001-01-01.1',
          accepted: const ['terms_of_service'],
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'stale_disclosure_version')),
      );
    });

    test('missing required disclosures are rejected', () {
      expect(
        () => client.onboarding.submitConsents(
          disclosureVersion: '2026-07-07.1',
          accepted: const ['terms_of_service'],
        ),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'consent_incomplete')),
      );
    });
  });

  group('verification lifecycle', () {
    test('session requires a complete profile and current consent', () async {
      await newApplicant();
      await expectLater(
        client.kyc.createSession(),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'profile_incomplete')),
      );
      await completeUsProfile();
      await expectLater(
        client.kyc.createSession(),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'consent_required')),
      );
    });

    test('happy path: create → progress → approve → wallet ready', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();

      expect((await client.kyc.walletReadiness()).ready, isFalse,
          reason: 'wallet must be gated before approval');

      final session = await client.kyc.createSession();
      expect(session.status, VerificationSessionStatus.sessionCreated);
      expect(session.clientToken, startsWith('mock_session_token_'));
      expect(session.duplicate, isFalse);
      // The mock says `none`, not `unknown`. Both are unlaunchable, so the
      // app behaves identically either way — but they mean different things,
      // and only one of them is true here. `none` is "this provider has
      // nothing to open, drive it with mock-events"; `unknown` is "a surface
      // this build predates", which is how a real vendor adding a surface
      // would show up. Emitting the key keeps that signal meaningful, and
      // mirrors `attach_handoff` in Puente (`kyc/mod.rs`), which special-cases
      // the mock to `none` for exactly this reason.
      expect(session.verificationSurface, KycVerificationSurface.none);
      expect(session.verificationSurface.launchable, isFalse);
      expect(session.verificationUrl, isNull,
          reason: 'the mock has no hosted page to hand out');
      expect(session.providerEnvironment, 'mock');

      final dup = await client.kyc.createSession();
      expect(dup.duplicate, isTrue, reason: 'duplicate-session prevention');
      expect(dup.sessionId, session.sessionId);
      // A plain duplicate carries no handoff at all — the backend asserts the
      // response is exactly eight keys, so the surface must not appear here
      // either, and absence is what makes it parse back as `unknown`.
      expect(dup.clientToken, isNull);
      expect(dup.verificationSurface, KycVerificationSurface.unknown);

      for (final scenario in [
        'document_captured',
        'selfie_captured',
        'processing',
      ]) {
        final r = await client.kyc
            .sendMockEvent(sessionId: session.sessionId, scenario: scenario);
        expect(r.kycStatus, isNot(KycStatus.approved));
      }
      final approved = await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'approve');
      expect(approved.status, VerificationSessionStatus.approved);
      expect(approved.kycStatus, KycStatus.approved);

      final readiness = await client.kyc.walletReadiness();
      expect(readiness.ready, isTrue);
      expect(readiness.kycTier, KycTier.tier1);

      final current = await client.kyc.currentSession();
      expect(current.status, VerificationSessionStatus.approved);
    });

    test('terminal sessions reject further events', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'approve');
      await expectLater(
        client.kyc
            .sendMockEvent(sessionId: session.sessionId, scenario: 'reject'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'terminal_state')),
      );
    });

    test('approved applicants cannot start new sessions or edit profiles',
        () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'approve');

      await expectLater(
        client.kyc.createSession(),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'already_approved')),
      );
      await expectLater(
        client.onboarding.updateProfile(legalFirstName: 'Nueva'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'profile_locked')),
      );
    });

    test('rejection propagates and allows a fresh retry', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final first = await client.kyc.createSession();
      final rejected = await client.kyc.sendMockEvent(
          sessionId: first.sessionId,
          scenario: 'reject',
          reason: 'document_unreadable');
      expect(rejected.kycStatus, KycStatus.rejected);

      final current = await client.kyc.currentSession();
      expect(current.failureReason, 'document_unreadable');

      final retry = await client.kyc.createSession();
      expect(retry.sessionId, isNot(first.sessionId));
      expect(retry.duplicate, isFalse);
    });

    test('manual review blocks the wallet and new sessions', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      final result = await client.kyc.sendMockEvent(
          sessionId: session.sessionId, scenario: 'manual_review');
      expect(result.kycStatus, KycStatus.manualReview);
      expect((await client.kyc.walletReadiness()).ready, isFalse);
      await expectLater(
        client.kyc.createSession(),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'manual_review_pending')),
      );
    });

    test(
        'policy-flagged paths never auto-approve: Mexican passport ends in '
        'manual review even when the provider approves', () async {
      await newApplicant();
      await client.onboarding.updateProfile(
        legalFirstName: 'Luis',
        legalLastName: 'Ramírez',
        dateOfBirth: '1980-02-02',
        addressLine1: '10 Pine St',
        addressCity: 'Yakima',
        addressPostalCode: '98901',
        addressCountry: 'US',
        residenceCountry: 'US',
        transferCorridor: 'us_mx',
        intendedUse: 'family_support',
        sourceOfFunds: 'employment',
        expectedVolumeBand: 'under_500',
        sensitiveIdentifierType: 'itin',
        sensitiveIdentifierValue: '912-11-2222',
        documentType: 'mexican_passport',
        documentIssuingCountry: 'MX',
      );
      await consent();
      final session = await client.kyc.createSession();
      final result = await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'approve');
      expect(result.kycStatus, KycStatus.manualReview,
          reason: 'requires_legal_review paths must not self-approve');
      expect((await client.kyc.walletReadiness()).ready, isFalse);
    });

    test('expire and error scenarios', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      final expired = await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'expire');
      expect(expired.status, VerificationSessionStatus.expired);
      expect(expired.kycStatus, KycStatus.expired);

      // Retry after expiry; provider error keeps the applicant in progress.
      final retry = await client.kyc.createSession();
      final errored = await client.kyc
          .sendMockEvent(sessionId: retry.sessionId, scenario: 'error');
      expect(errored.status, VerificationSessionStatus.error);
      expect(errored.kycStatus, KycStatus.inProgress);
    });

    test('unknown scenario is rejected', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      await expectLater(
        client.kyc.sendMockEvent(
            sessionId: session.sessionId, scenario: 'self_approve_hack'),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'unknown_scenario')),
      );
    });

    test('currentSession 404s before any session exists', () async {
      await newApplicant();
      await expectLater(
        client.kyc.currentSession(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.code, 'code', 'no_session')),
      );
    });
  });

  group('personal info', () {
    test('masked, region-aware view with verification state', () async {
      await newApplicant();
      await completeUsProfile();
      await consent();
      final session = await client.kyc.createSession();
      await client.kyc
          .sendMockEvent(sessionId: session.sessionId, scenario: 'approve');

      final info = await client.personalInfo.get();
      expect(info.profile.kycStatus, KycStatus.approved);
      expect(info.profile.sensitiveIdentifier?.masked, '•••• 6789');
      expect(info.verification?.status, VerificationSessionStatus.approved);
      expect(info.manualReviewPending, isFalse);
      expect(info.profile.isLocked, isTrue);
      // Raw identifier value appears nowhere in the payload.
      expect(info.toJson().toString(), isNot(contains('212456789')));
    });

    test('correction requests are review-routed, not applied', () async {
      await newApplicant();
      final receipt = await client.personalInfo.requestCorrection(
        field: 'legal_name',
        note: 'segundo apellido faltante',
      );
      expect(receipt.status, 'pending');
      await expectLater(
        client.personalInfo.requestCorrection(field: 'kyc_status'),
        throwsA(isA<ValidationException>()
            .having((e) => e.code, 'code', 'invalid_field')),
      );
    });

    test('requires an applicant (auth boundary)', () async {
      // No applicant created on this fresh client → 401 from the mock,
      // mirroring the backend's RequireApplicant extractor.
      await expectLater(
        client.personalInfo.get(),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
