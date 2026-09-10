import 'puente_exception.dart';

/// A non-2xx HTTP response from Puente Railway.
///
/// Use [statusCode] + [code] to disambiguate cases. The string [code] (if
/// present) is the stable machine-readable identifier returned in the
/// `{ "error": "<code>", "message": "...", ... }` JSON body — prefer it
/// over [message] for branching logic.
class ApiException extends PuenteException {
  /// HTTP status code returned by the server.
  final int statusCode;

  /// Stable machine-readable error code, e.g. `"quote_expired"`,
  /// `"insufficient_funds"`. `null` when the server didn't send one
  /// (typically on 5xx).
  final String? code;

  /// Full decoded response body when available; useful for logging and
  /// for unblocking unusual edge cases. May be `null` if the server
  /// returned non-JSON.
  final Map<String, dynamic>? body;

  /// Build an [ApiException].
  const ApiException(
    super.message, {
    required this.statusCode,
    this.code,
    this.body,
    super.requestId,
    super.idempotencyKey,
  });

  /// True for the conventional "retry would help" codes (429 + 5xx).
  bool get isRetryable =>
      statusCode == 429 || (statusCode >= 500 && statusCode < 600);

  @override
  String toString() {
    final cidPart = code == null ? '' : ' code=$code';
    final ridPart = requestId == null ? '' : ' request_id=$requestId';
    return 'ApiException $statusCode$cidPart: $message$ridPart';
  }
}
