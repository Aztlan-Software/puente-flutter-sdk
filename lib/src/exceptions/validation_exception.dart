import 'api_exception.dart';

/// HTTP 422 — the request payload failed server-side validation.
///
/// [fieldErrors] carries per-field messages keyed by JSON field name
/// (e.g. `{"email": "must be a valid email", "phone": "invalid E.164"}`).
/// Surface these in a form to highlight which field needs attention.
class ValidationException extends ApiException {
  /// Per-field error messages. Empty when the server returned 422 without
  /// a structured body.
  final Map<String, String> fieldErrors;

  /// Build a [ValidationException].
  const ValidationException(
    super.message, {
    required super.statusCode,
    this.fieldErrors = const <String, String>{},
    super.code,
    super.body,
    super.requestId,
    super.idempotencyKey,
  });

  @override
  String toString() => 'ValidationException $statusCode: $message '
      '(${fieldErrors.length} field error${fieldErrors.length == 1 ? '' : 's'})';
}
