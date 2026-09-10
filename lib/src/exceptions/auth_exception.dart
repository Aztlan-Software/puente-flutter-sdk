import 'api_exception.dart';

/// HTTP 401 / 403 — the SDK's API key or merchant credentials were rejected.
///
/// Common causes:
/// * Wrong environment for the key (sandbox key against prod URL or vice
///   versa).
/// * Rotated key not yet propagated.
/// * Key revoked by an operator.
///
/// Distinct subclass so callers can show the "check your credentials"
/// path without parsing the status code.
class AuthException extends ApiException {
  /// Build an [AuthException].
  const AuthException(
    super.message, {
    required super.statusCode,
    super.code,
    super.body,
    super.requestId,
    super.idempotencyKey,
  });
}
