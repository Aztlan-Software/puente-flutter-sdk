import '../models/personal_info.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// Personal Information surface (`/v1/me/personal-info`). Applicant-token
/// authenticated — a token can only ever read its own applicant's data.
///
/// Responses are masked server-side (sensitive identifiers as type+last4
/// only; raw SSN/ITIN/CURP never leave the backend) and each read is
/// audit-logged server-side. Do NOT cache this response on-device; fetch
/// fresh behind the app's local reauth gate instead.
class PersonalInfoResource extends ResourceBase {
  /// Build the resource. Normally accessed as `client.personalInfo`.
  PersonalInfoResource(super.transport);

  /// `GET /v1/me/personal-info`.
  Future<PersonalInfo> get() async {
    final response = await request(
      const PuenteRequest(method: 'GET', path: '/me/personal-info'),
    );
    return decode(response, PersonalInfo.fromJson, target: 'PersonalInfo');
  }

  /// `POST /v1/me/personal-info/correction-requests` — request a change
  /// to a KYC-locked field. Corrections are reviewed server-side; nothing
  /// is mutated directly. [field] is one of the backend's correctable
  /// field ids (`legal_name`, `date_of_birth`, `address`, `phone`,
  /// `email`, `document`, `sensitive_identifier`, `residence_country`,
  /// `other`).
  Future<CorrectionRequestReceipt> requestCorrection({
    required String field,
    String? note,
    String? idempotencyKey,
  }) async {
    // Filing a correction request creates a reviewable record. The transport
    // retries POSTs on 5xx and timeouts, so without a key a single tap could
    // open two tickets for the same change (H-14 / H-18).
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/me/personal-info/correction-requests',
      body: <String, dynamic>{
        'field': field,
        if (note != null) 'note': note,
      },
      idempotencyKey: key,
    ));
    return decode(response, CorrectionRequestReceipt.fromJson,
        target: 'CorrectionRequestReceipt', idempotencyKey: key);
  }
}
