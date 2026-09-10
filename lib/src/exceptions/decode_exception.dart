import 'puente_exception.dart';

/// The server answered 2xx but the body did not match the shape this SDK
/// version expects, so a model could not be built.
///
/// Raised instead of letting a raw `FormatException`, `TypeError`, or
/// `ArgumentError` escape: [PuenteException] is documented as the single
/// catch-all for every SDK failure, and a decode failure is a failure like
/// any other. Callers that only wrote `on PuenteException` used to miss this
/// case entirely and crash.
///
/// Typical causes: the backend shipped a wire change ahead of the SDK, a
/// proxy rewrote the body, or an unknown currency/enum arrived from a newer
/// deployment.
///
/// **This is not a retry signal.** The request already succeeded server-side
/// — retrying re-executes it. Report [requestId] to Puente support instead.
class DecodeException extends PuenteException {
  /// The model or field that failed to decode (`'Quote'`, `'Money.amount'`).
  final String target;

  /// The underlying decode error, preserved for debugging. Never branch on
  /// it — the concrete type is not part of the public API.
  final Object? cause;

  /// Build a [DecodeException].
  const DecodeException(
    super.message, {
    required this.target,
    this.cause,
    super.requestId,
    super.idempotencyKey,
  });

  @override
  String toString() {
    final ridPart = requestId == null ? '' : ' request_id=$requestId';
    return 'DecodeException($target): $message$ridPart'
        '${cause == null ? '' : ' (cause: $cause)'}';
  }
}
