import '../exceptions/invalid_argument_exception.dart';
import '../models/onboarding_profile.dart';
import '../models/region_policy.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// Onboarding surface: applicant creation, region policy, profile, and
/// consents (`/v1/onboarding/*`).
///
/// ## Auth model
///
/// * [createApplicant] is the ONLY merchant-credential call here — in
///   production it belongs behind your server (the app should never hold
///   an `sk_` key; testnet demos use the dart-define key as a documented
///   compromise). It returns the applicant bearer token exactly once.
/// * Every other method authenticates as the APPLICANT: build the client
///   with `PuenteConfig(tokenProvider: () async => applicantToken, …)` so
///   the `pat_…` token rides the standard Authorization header.
///
/// ## Authority model
///
/// The backend owns all policy: which documents/identifiers a region
/// allows, age limits, disclosure versions. The app renders what
/// [getPolicy] returns and the backend re-validates every submission —
/// a modified client cannot unlock unsupported paths.
class OnboardingResource extends ResourceBase {
  /// Build the resource. Normally accessed as `client.onboarding`.
  OnboardingResource(super.transport);

  /// `POST /v1/onboarding/applicants` — create (or recover) the applicant
  /// for [externalUserId] and mint its bearer token.
  ///
  /// Re-calling with the same [externalUserId] ROTATES the token (the
  /// deliberate app-restart / lost-secure-storage recovery path). At least
  /// one of [phone] / [email] is required.
  Future<ApplicantCredentials> createApplicant({
    required String externalUserId,
    String? phone,
    String? email,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/onboarding/applicants',
      body: <String, dynamic>{
        'external_user_id': externalUserId,
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
      },
      idempotencyKey: key,
    ));
    return decode(response, ApplicantCredentials.fromJson,
        target: 'ApplicantCredentials', idempotencyKey: key);
  }

  /// `GET /v1/onboarding/policy` — the region policy for
  /// [residenceCountry] (or the profile's stored residence when omitted).
  ///
  /// Unsupported countries return a calm `supported == false` policy, not
  /// an error — render a "not available yet" state.
  Future<RegionPolicy> getPolicy({String? residenceCountry}) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/onboarding/policy',
      query: <String, String>{
        if (residenceCountry != null) 'residence_country': residenceCountry,
      },
    ));
    return decode(response, RegionPolicy.fromJson, target: 'RegionPolicy');
  }

  /// `GET /v1/onboarding/profile`.
  Future<OnboardingProfile> getProfile() async {
    final response = await request(
      const PuenteRequest(method: 'GET', path: '/onboarding/profile'),
    );
    return decode(response, OnboardingProfile.fromJson,
        target: 'OnboardingProfile');
  }

  /// `PUT /v1/onboarding/profile` — partial update; only the fields you
  /// pass are touched. The backend validates every field against the
  /// region policy (underage DOB → 422 `underage`, region-mismatched
  /// documents/identifiers → 422, locked profiles → 409 `profile_locked`).
  ///
  /// [sensitiveIdentifierType]/[sensitiveIdentifierValue] submit an
  /// identifier (e.g. `ssn` / `itin` / `curp`). The raw value is hashed
  /// server-side and NEVER returned or stored in plaintext — responses
  /// carry a [MaskedIdentifier] only. Do not cache the raw value locally.
  Future<OnboardingProfile> updateProfile({
    String? legalFirstName,
    String? legalMiddleName,
    String? legalLastName,

    /// ISO date `YYYY-MM-DD`.
    String? dateOfBirth,
    String? addressLine1,
    String? addressLine2,
    String? addressCity,
    String? addressState,
    String? addressPostalCode,
    String? addressCountry,
    String? residenceCountry,
    String? region,
    String? transferCorridor,
    String? intendedUse,
    String? sourceOfFunds,
    String? expectedVolumeBand,
    String? sensitiveIdentifierType,
    String? sensitiveIdentifierValue,
    String? documentType,
    String? documentIssuingCountry,
    String? idempotencyKey,
  }) async {
    // These were `assert`s. Dart strips asserts from release builds, so in
    // production a half-supplied pair was silently serialized as
    // `{"type": "ssn", "value": null}` — the exact shape the backend rejects
    // with an opaque 422, and the one case where the caller most needs a
    // clear local error. Enforce them at runtime in every build mode.
    if ((sensitiveIdentifierType == null) !=
        (sensitiveIdentifierValue == null)) {
      throw InvalidArgumentException(
        'sensitive identifier type and value must be provided together',
        parameter: 'sensitiveIdentifier',
        value: sensitiveIdentifierType ?? '<null type>',
      );
    }
    if ((documentType == null) != (documentIssuingCountry == null)) {
      throw InvalidArgumentException(
        'document type and issuing country must be provided together',
        parameter: 'document',
        value: documentType ?? '<null type>',
      );
    }
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'PUT',
      path: '/onboarding/profile',
      body: <String, dynamic>{
        if (legalFirstName != null) 'legal_first_name': legalFirstName,
        if (legalMiddleName != null) 'legal_middle_name': legalMiddleName,
        if (legalLastName != null) 'legal_last_name': legalLastName,
        if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
        if (addressLine1 != null) 'address_line1': addressLine1,
        if (addressLine2 != null) 'address_line2': addressLine2,
        if (addressCity != null) 'address_city': addressCity,
        if (addressState != null) 'address_state': addressState,
        if (addressPostalCode != null) 'address_postal_code': addressPostalCode,
        if (addressCountry != null) 'address_country': addressCountry,
        if (residenceCountry != null) 'residence_country': residenceCountry,
        if (region != null) 'region': region,
        if (transferCorridor != null) 'transfer_corridor': transferCorridor,
        if (intendedUse != null) 'intended_use': intendedUse,
        if (sourceOfFunds != null) 'source_of_funds': sourceOfFunds,
        if (expectedVolumeBand != null)
          'expected_volume_band': expectedVolumeBand,
        if (sensitiveIdentifierType != null)
          'sensitive_identifier': <String, dynamic>{
            'type': sensitiveIdentifierType,
            'value': sensitiveIdentifierValue,
          },
        if (documentType != null)
          'document': <String, dynamic>{
            'type': documentType,
            'issuing_country': documentIssuingCountry,
          },
      },
      idempotencyKey: key,
    ));
    return decode(response, OnboardingProfile.fromJson,
        target: 'OnboardingProfile', idempotencyKey: key);
  }

  /// `POST /v1/onboarding/consents` — record acceptance of the CURRENT
  /// disclosure version. Throws `ApiException(code: 'stale_disclosure_
  /// version')` (409) when the policy moved on — refetch [getPolicy] and
  /// re-present. [accepted] must include every required disclosure id.
  Future<void> submitConsents({
    required String disclosureVersion,
    required List<String> accepted,
    String? idempotencyKey,
  }) async {
    // Recording a consent is a side effect with legal weight, and the
    // transport retries POSTs on 5xx and timeouts. Without a key, one
    // retried call could record the acceptance twice (H-14 / H-18).
    await request(PuenteRequest(
      method: 'POST',
      path: '/onboarding/consents',
      body: <String, dynamic>{
        'disclosure_version': disclosureVersion,
        'accepted': accepted,
      },
      idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
    ));
  }
}
