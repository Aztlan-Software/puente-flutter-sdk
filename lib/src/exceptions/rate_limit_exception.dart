import 'api_exception.dart';

/// HTTP 429 — caller exceeded Puente Railway's per-key rate limit.
///
/// [retryAfter] reflects the server's `Retry-After` header when present
/// (in seconds, RFC 9110). The SDK's [RetryInterceptor] already honors
/// it under the hood; callers see this exception only after all retries
/// have been exhausted.
class RateLimitException extends ApiException {
  /// Server-recommended wait period before retrying. `null` when the
  /// server didn't send a `Retry-After` header.
  final Duration? retryAfter;

  /// Build a [RateLimitException].
  const RateLimitException(
    super.message, {
    required super.statusCode,
    this.retryAfter,
    super.code,
    super.body,
    super.requestId,
    super.idempotencyKey,
  });

  @override
  String toString() {
    final raPart =
        retryAfter == null ? '' : ' retry_after=${retryAfter!.inSeconds}s';
    return 'RateLimitException $statusCode: $message$raPart';
  }
}
