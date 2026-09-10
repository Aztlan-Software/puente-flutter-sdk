import 'puente_exception.dart';

/// A client-side argument guard rejected a value **before** it reached the
/// wire.
///
/// Distinct from [ValidationException] (HTTP 422 — the *server* rejected a
/// payload): nothing was sent when this is thrown, so no money moved and no
/// idempotency key was consumed. Retrying with the same argument will always
/// fail; fix the input instead.
///
/// The SDK raises this for arguments that are unsafe to place on the wire —
/// most importantly path identifiers containing separators or dot segments,
/// which would silently redirect an authenticated request to a different
/// endpoint (see `ResourceBase.pathSegment`).
class InvalidArgumentException extends PuenteException {
  /// Name of the offending parameter (`'clabe'`, `'id'`, …).
  final String parameter;

  /// The rejected value, echoed for debugging. Never contains a credential —
  /// this guard only ever runs on path identifiers and enum-like fields.
  final String value;

  /// Build an [InvalidArgumentException].
  const InvalidArgumentException(
    super.message, {
    required this.parameter,
    required this.value,
  });

  @override
  String toString() =>
      'InvalidArgumentException($parameter): $message (got "$value")';
}
