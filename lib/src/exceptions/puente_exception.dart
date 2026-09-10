/// Root exception type for everything the Puente Railway SDK can throw.
///
/// All other exceptions in the SDK (`ApiException`, `AuthException`,
/// `RateLimitException`, `ValidationException`, `TransportException`,
/// `WebhookException`) extend [PuenteException], so a single
/// `on PuenteException catch (e)` handler covers every SDK failure mode.
///
/// SDK calls **never** throw raw `Exception`, `dynamic`, or upstream package
/// errors — anything we catch internally is rewrapped as a [PuenteException]
/// subclass with a stable shape.
class PuenteException implements Exception {
  /// Human-readable message. Stable in shape but not part of the public
  /// API — don't string-match against this; use the typed subclass.
  final String message;

  /// Optional Puente-server request id (`X-Request-Id`). Surface this to
  /// users in support flows so a human can correlate a complaint with the
  /// server log.
  final String? requestId;

  /// The `Idempotency-Key` the failed request carried, when it had one.
  ///
  /// **This is the field that makes a money-moving failure recoverable.**
  /// The SDK generates a key automatically for every unsafe method, so
  /// before this existed a caller who saw a [TransportException] on
  /// `transfers.create` had no way to retry safely: a second call minted a
  /// *new* key and the server treated it as a second, distinct transfer.
  ///
  /// On an ambiguous outcome (timeout, connection reset, 5xx after retries)
  /// the operation may or may not have taken effect server-side. Retry with
  /// this exact key and the server replays the original outcome instead of
  /// executing again:
  ///
  /// ```dart
  /// try {
  ///   return await puente.transfers.create(/* … */);
  /// } on TransportException catch (e) {
  ///   // Same key — replays, never double-sends.
  ///   return await puente.transfers.create(/* … */, idempotencyKey: e.idempotencyKey);
  /// }
  /// ```
  ///
  /// `null` for safe methods (GET) and for failures raised before a request
  /// was built.
  final String? idempotencyKey;

  /// Build a [PuenteException].
  const PuenteException(this.message, {this.requestId, this.idempotencyKey});

  @override
  String toString() {
    final ridPart = requestId == null ? '' : ' (request_id: $requestId)';
    return '$runtimeType: $message$ridPart';
  }
}
