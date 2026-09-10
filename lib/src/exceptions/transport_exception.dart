import 'puente_exception.dart';

/// The HTTP request never completed — timeout, DNS failure, TLS handshake
/// error, dropped connection.
///
/// Distinct from [ApiException] (which means the server answered with a
/// status code we didn't like). [TransportException] is the "we never heard
/// back" case — UX should distinguish "the server is unreachable" from
/// "the server said no."
///
/// [cause] preserves the underlying error for debugging; never compare
/// against it for branching logic.
class TransportException extends PuenteException {
  /// Underlying error if available (e.g. `TimeoutException`,
  /// `SocketException`, `HandshakeException`).
  final Object? cause;

  /// Build a [TransportException].
  const TransportException(
    super.message, {
    this.cause,
    super.requestId,
    super.idempotencyKey,
  });

  @override
  String toString() => 'TransportException: $message'
      '${cause == null ? '' : ' (cause: $cause)'}';
}
