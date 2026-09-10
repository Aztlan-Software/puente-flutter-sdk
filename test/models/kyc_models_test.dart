import 'package:puente_railway/puente_railway.dart';
import 'package:test/test.dart';

void main() {
  group('KycStatus', () {
    test('parses every wire value', () {
      expect(KycStatus.fromWire('not_started'), KycStatus.notStarted);
      expect(KycStatus.fromWire('in_progress'), KycStatus.inProgress);
      expect(KycStatus.fromWire('processing'), KycStatus.processing);
      expect(KycStatus.fromWire('approved'), KycStatus.approved);
      expect(KycStatus.fromWire('rejected'), KycStatus.rejected);
      expect(KycStatus.fromWire('manual_review'), KycStatus.manualReview);
      expect(KycStatus.fromWire('expired'), KycStatus.expired);
    });

    test('unknown wire values degrade to unknown, never crash', () {
      expect(KycStatus.fromWire('brand_new_status'), KycStatus.unknown);
      expect(KycStatus.fromWire(null), KycStatus.unknown);
      expect(KycStatus.unknown.isApproved, isFalse);
    });
  });

  group('VerificationSessionStatus', () {
    test('active/terminal partitions', () {
      expect(VerificationSessionStatus.sessionCreated.isActive, isTrue);
      expect(VerificationSessionStatus.processing.isActive, isTrue);
      expect(VerificationSessionStatus.approved.isTerminal, isTrue);
      expect(VerificationSessionStatus.error.isTerminal, isTrue);
      expect(VerificationSessionStatus.approved.isActive, isFalse);
      expect(VerificationSessionStatus.fromWire('document_capture_started'),
          VerificationSessionStatus.documentCaptureStarted);
      expect(VerificationSessionStatus.fromWire('nonsense'),
          VerificationSessionStatus.unknown);
    });
  });

  group('RegionPolicy', () {
    final json = <String, dynamic>{
      'policy_version': '2026-07-07.1',
      'supported': true,
      'residence_country': 'US',
      'region': 'us',
      'min_age': 18,
      'corridors': ['us_mx'],
      'document_options': [
        {
          'document_type': 'mexican_passport',
          'issuing_countries': ['MX'],
          'legal_review_status': 'requires_legal_review',
          'manual_review_required': true,
        },
      ],
      'identifier_requirements': [
        {
          'identifier_type': 'itin',
          'requirement': 'required_one_of',
          'reason_key': 'kycWhyTaxId',
          'legal_review_status': 'requires_legal_review',
        },
      ],
      'disclosure_version': '2026-07-07.1',
      'disclosures': [
        {
          'id': 'terms_of_service',
          'version': '2026-07-07.1',
          'required': true,
          'url_placeholder': '/legal/terms',
        },
        {
          'id': 'optional_marketing',
          'version': '2026-07-07.1',
          'required': false,
          'url_placeholder': '/legal/marketing',
        },
      ],
      'intended_use_options': [
        {'id': 'business', 'manual_review': true},
      ],
      'source_of_funds_options': ['employment'],
      'expected_volume_bands': [
        {'id': 'over_10000', 'manual_review': true},
      ],
    };

    test('round-trips and exposes flags', () {
      final policy = RegionPolicy.fromJson(json);
      expect(policy.supported, isTrue);
      expect(policy.region, 'us');
      expect(policy.documentOptions.single.legalReviewStatus,
          LegalReviewStatus.requiresLegalReview);
      expect(policy.documentOptions.single.manualReviewRequired, isTrue);
      expect(policy.identifierRequirements.single.requirement,
          IdentifierRequirementLevel.requiredOneOf);
      expect(policy.requiredDisclosureIds, ['terms_of_service']);
      expect(RegionPolicy.fromJson(policy.toJson()), policy);
    });

    test('unsupported policy parses calmly with empty lists', () {
      final policy = RegionPolicy.fromJson(<String, dynamic>{
        'policy_version': '2026-07-07.1',
        'supported': false,
        'unsupported_reason': 'region_not_supported',
        'residence_country': 'BR',
        'min_age': 18,
        'corridors': <String>[],
        'document_options': <dynamic>[],
        'identifier_requirements': <dynamic>[],
        'disclosure_version': '2026-07-07.1',
        'disclosures': <dynamic>[],
        'intended_use_options': <dynamic>[],
        'source_of_funds_options': <String>[],
        'expected_volume_bands': <dynamic>[],
      });
      expect(policy.supported, isFalse);
      expect(policy.unsupportedReason, 'region_not_supported');
      expect(policy.region, isNull);
      expect(policy.documentOptions, isEmpty);
    });

    test('unknown legal review statuses degrade to unknown', () {
      expect(LegalReviewStatus.fromWire('surprise'), LegalReviewStatus.unknown);
      expect(IdentifierRequirementLevel.fromWire('surprise'),
          IdentifierRequirementLevel.unknown);
    });
  });

  group('ApplicantCredentials', () {
    test('never serializes or prints the token', () {
      final creds = ApplicantCredentials.fromJson(<String, dynamic>{
        'applicant_id': 'apl_1',
        'applicant_token': 'pat_secret_token_value',
        'kyc_status': 'not_started',
        'kyc_tier': 'none',
        'created': true,
      });
      expect(creds.applicantToken, 'pat_secret_token_value');
      expect(creds.toJson().containsKey('applicant_token'), isFalse);
      expect(creds.toString(), isNot(contains('pat_secret_token_value')));
    });
  });

  group('KycSession', () {
    final json = <String, dynamic>{
      'session_id': 'ksn_1',
      'provider': 'mock',
      'provider_session_ref': 'abc123',
      'status': 'session_created',
      'failure_reason': null,
      'kyc_status': 'in_progress',
      'expires_at': '2026-07-07T20:00:00Z',
      'duplicate': false,
      'client_token': 'mock_session_token_abc123',
    };

    test('parses the creation response including the one-time token', () {
      final session = KycSession.fromJson(json);
      expect(session.status, VerificationSessionStatus.sessionCreated);
      expect(session.kycStatus, KycStatus.inProgress);
      expect(session.clientToken, 'mock_session_token_abc123');
      expect(session.duplicate, isFalse);
    });

    test('never serializes or prints the client token', () {
      final session = KycSession.fromJson(json);
      expect(session.toJson().containsKey('client_token'), isFalse);
      expect(session.toString(), isNot(contains('mock_session_token')));
    });
  });

  group('MaskedIdentifier / OnboardingProfile', () {
    test('masked identifier renders last4 only', () {
      const masked = MaskedIdentifier(type: 'ssn', last4: '6789');
      expect(masked.masked, '•••• 6789');
      expect(MaskedIdentifier.fromJson(masked.toJson()), masked);
    });

    test('profile parses the nested backend view', () {
      final profile = OnboardingProfile.fromJson(<String, dynamic>{
        'applicant_id': 'apl_1',
        'external_user_id': 'firebase-uid-1',
        'kyc_status': 'approved',
        'kyc_tier': 'tier1',
        'requires_manual_review': false,
        'contact': {'phone': '+15095550100', 'email': 'a@b.co'},
        'profile': {
          'legal_first_name': 'María José',
          'legal_last_name': 'Hernández',
          'date_of_birth': '1990-04-12',
          'address': {
            'line1': '500 Yakima Ave',
            'city': 'Yakima',
            'state': 'WA',
            'postal_code': '98901',
            'country': 'US',
          },
          'residence_country': 'US',
          'region': 'us',
          'transfer_corridor': 'us_mx',
          'intended_use': 'family_support',
          'source_of_funds': 'employment',
          'expected_volume_band': '500_2000',
        },
        'sensitive_identifier': {'type': 'ssn', 'last4': '6789'},
        'document': {'type': 'us_drivers_license', 'issuing_country': 'US'},
        'consent': {
          'disclosure_version': '2026-07-07.1',
          'consent_at': '2026-07-07T18:00:00Z',
          'current': true,
        },
        'policy_version': '2026-07-07.1',
        'field_editability': 'review_required',
        'complete': true,
        'missing': <String>[],
        'updated_at': '2026-07-07T18:05:00Z',
      });
      expect(profile.legalFirstName, 'María José');
      expect(profile.kycStatus, KycStatus.approved);
      expect(profile.sensitiveIdentifier?.last4, '6789');
      expect(profile.document?.type, 'us_drivers_license');
      expect(profile.address.city, 'Yakima');
      expect(profile.consent.current, isTrue);
      expect(profile.isLocked, isTrue);
      expect(profile.complete, isTrue);
    });

    test('minimal profile parses with safe defaults', () {
      final profile = OnboardingProfile.fromJson(<String, dynamic>{
        'applicant_id': 'apl_2',
        'kyc_status': 'not_started',
        'kyc_tier': 'none',
      });
      expect(profile.kycStatus, KycStatus.notStarted);
      expect(profile.sensitiveIdentifier, isNull);
      expect(profile.document, isNull);
      expect(profile.complete, isFalse);
      expect(profile.isLocked, isFalse);
    });
  });

  group('WalletReadiness', () {
    test('parses and defaults to not-ready', () {
      final ready = WalletReadiness.fromJson(<String, dynamic>{
        'ready': true,
        'kyc_status': 'approved',
        'kyc_tier': 'tier1',
        'missing': <String>[],
      });
      expect(ready.ready, isTrue);
      expect(
          WalletReadiness.fromJson(const <String, dynamic>{}).ready, isFalse);
    });
  });

  group('PersonalInfo', () {
    test('parses profile + verification + manual review', () {
      final info = PersonalInfo.fromJson(<String, dynamic>{
        'applicant_id': 'apl_1',
        'kyc_status': 'manual_review',
        'kyc_tier': 'none',
        'verification': {
          'status': 'manual_review',
          'provider': 'mock',
          'failure_reason': null,
        },
        'manual_review': {'required': true, 'pending': true},
      });
      expect(info.profile.kycStatus, KycStatus.manualReview);
      expect(info.verification?.status, VerificationSessionStatus.manualReview);
      expect(info.manualReviewRequired, isTrue);
      expect(info.manualReviewPending, isTrue);
    });
  });
  group('KycSession launch handoff', () {
    Map<String, dynamic> creation() => <String, dynamic>{
          'session_id': 'sess-1',
          'provider': 'didit',
          'provider_session_ref': 'didit-ref-1',
          'status': 'session_created',
          'kyc_status': 'in_progress',
          'expires_at': '2026-09-13T00:00:00Z',
          'duplicate': false,
          'client_token': 'tok_abc123',
          'verification_url': 'https://verify.didit.me/u/abc',
          'verification_surface': 'hosted_url',
          'provider_environment': 'sandbox',
        };

    test('parses the surface, url and environment', () {
      final s = KycSession.fromJson(creation());
      expect(s.provider, 'didit');
      expect(s.verificationUrl, 'https://verify.didit.me/u/abc');
      expect(s.verificationSurface, KycVerificationSurface.hostedUrl);
      expect(s.verificationSurface.launchable, isTrue);
      expect(s.providerEnvironment, 'sandbox');
    });

    test('never serializes either capability', () {
      // Both grant the ability to complete someone else's verification, so
      // neither may reach a JSON cache, a log, or a crash report.
      final json = KycSession.fromJson(creation()).toJson();
      expect(json.containsKey('client_token'), isFalse);
      expect(json.containsKey('verification_url'), isFalse);
      expect(json['verification_surface'], 'hosted_url');
      expect(json['provider_environment'], 'sandbox');

      final printed = KycSession.fromJson(creation()).toString();
      expect(printed, isNot(contains('tok_abc123')));
      expect(printed, isNot(contains('verify.didit.me')));
      expect(printed, contains('****'));
    });

    test('an older backend that sends none of it still parses', () {
      final legacy = creation()
        ..remove('verification_url')
        ..remove('verification_surface')
        ..remove('provider_environment');
      final s = KycSession.fromJson(legacy);
      expect(s.verificationUrl, isNull);
      expect(s.providerEnvironment, isNull);
      expect(s.verificationSurface, KycVerificationSurface.unknown);
      expect(s.verificationSurface.launchable, isFalse,
          reason: 'an unknown surface must not be guessed at');
    });

    test('a surface this build does not know is not launchable', () {
      final future = creation()..['verification_surface'] = 'holographic_kiosk';
      expect(KycSession.fromJson(future).verificationSurface,
          KycVerificationSurface.unknown);
      expect(KycVerificationSurface.none.launchable, isFalse);
      expect(KycVerificationSurface.nativeSdk.launchable, isTrue);
    });
  });
}
