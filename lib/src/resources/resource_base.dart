import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../exceptions/api_exception.dart';
import '../exceptions/auth_exception.dart';
import '../exceptions/decode_exception.dart';
import '../exceptions/invalid_argument_exception.dart';
import '../exceptions/puente_exception.dart';
import '../exceptions/rate_limit_exception.dart';
import '../exceptions/stale_quote_exception.dart';
import '../exceptions/validation_exception.dart';
import '../transport/puente_request.dart';
import '../transport/puente_response.dart';
import '../transport/puente_transport.dart';

/// Shared plumbing every resource (`QuotesResource`, `TransfersResource`,
/// …) builds on top of. Handles:
///
/// * Sending the request through the transport.
/// * Translating non-2xx responses into the typed exception hierarchy.
/// * Generating idempotency keys for unsafe HTTP methods when the
///   caller didn't provide one, and echoing the key back on every failure
///   so an ambiguous outcome stays safely retryable.
/// * Validating caller-supplied path identifiers ([pathSegment]) before
///   they are interpolated into a URL.
/// * Decoding response bodies through [decode] / [decodeList] so a wire
///   mismatch surfaces as a typed [DecodeException] instead of a raw
///   `FormatException`.
abstract class ResourceBase {
  /// Build a resource against a [PuenteTransport].
  ResourceBase(this.transport, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Underlying transport. Tests may pass a [MockTransport].
  final PuenteTransport transport;

  final Uuid _uuid;

  /// Generate a fresh UUIDv4 — the SDK's default idempotency key for
  /// money-moving requests that don't supply one.
  String newIdempotencyKey() => _uuid.v4();

  /// Reject a caller-supplied value that is about to be interpolated into
  /// a URL path.
  ///
  /// **This guard is load-bearing, not cosmetic.** Dart's `Uri` resolves
  /// dot segments when a path is assembled, so an identifier containing
  /// `..` silently *retargets the request while keeping the `Authorization`
  /// header attached*. Before this check existed,
  /// `clabe.lookup('../../v1/transfers')` issued an authenticated
  /// `GET /v1/transfers` — a form field could redirect a lookup onto an
  /// unrelated endpoint — and `transfers.retrieve('../../../balances')`
  /// escaped the `/v1` prefix entirely.
  ///
  /// Identifiers the backend issues (`tx_…`, `dep_…`, an 18-digit CLABE)
  /// never contain a separator, a percent escape, or a dot segment, so
  /// rejecting them costs nothing and closes the hole. Pre-encoded values
  /// are rejected too: `%2e%2e` normalizes back to `..`.
  ///
  /// Throws [InvalidArgumentException] — a [PuenteException], raised before
  /// anything reaches the wire, so no request was sent and no idempotency
  /// key was consumed.
  @protected
  String pathSegment(String value, String parameter) {
    if (value.isEmpty) {
      throw InvalidArgumentException(
        'must not be empty',
        parameter: parameter,
        value: value,
      );
    }
    if (value == '.' || value == '..') {
      throw InvalidArgumentException(
        'must not be a dot segment',
        parameter: parameter,
        value: value,
      );
    }
    for (final unit in value.codeUnits) {
      // Separators, the percent escape, the query/fragment delimiters, and
      // any control character (which would also enable header and log
      // injection downstream).
      if (unit == 0x2f || // solidus
          unit == 0x5c || // reverse solidus
          unit == 0x25 || // percent
          unit == 0x3f || // question mark
          unit == 0x23 || // number sign
          unit <= 0x1f ||
          unit == 0x7f) {
        throw InvalidArgumentException(
          'must not contain a path separator, a percent escape, a query or '
          'fragment delimiter, or a control character',
          parameter: parameter,
          value: value,
        );
      }
    }
    return value;
  }

  /// Build a model from a successful [response], converting any decode
  /// failure into a typed [DecodeException].
  ///
  /// Model constructors throw raw `FormatException` / `TypeError` /
  /// `ArgumentError` on an unexpected wire shape. Those are not
  /// [PuenteException]s, so callers following the documented
  /// `on PuenteException` contract used to crash on a backend wire change.
  @protected
  T decode<T>(
    PuenteResponse response,
    T Function(Map<String, dynamic>) parse, {
    required String target,
    String? idempotencyKey,
  }) {
    try {
      return parse(response.jsonObject);
    } on PuenteException {
      rethrow;
    } catch (e) {
      throw DecodeException(
        'could not decode a $target from the response body',
        target: target,
        cause: e,
        requestId: response.requestId,
        idempotencyKey: idempotencyKey,
      );
    }
  }

  /// [decode] for an envelope of the form `{"data": [ … ]}`.
  ///
  /// A non-list (or absent) `data` yields an empty list — that shape is a
  /// legitimate empty page. Only a malformed *element* is an error.
  @protected
  List<T> decodeList<T>(
    PuenteResponse response,
    T Function(Map<String, dynamic>) parse, {
    required String target,
  }) {
    final data = response.jsonObject['data'];
    if (data is! List) return const [];
    try {
      return data
          .whereType<Map<String, dynamic>>()
          .map(parse)
          .toList(growable: false);
    } on PuenteException {
      rethrow;
    } catch (e) {
      throw DecodeException(
        'could not decode a list of $target from the response body',
        target: target,
        cause: e,
        requestId: response.requestId,
      );
    }
  }

  /// Send [request] and assert a successful response. Translates
  /// non-2xx into typed exceptions before returning.
  Future<PuenteResponse> request(PuenteRequest request) async {
    final response = await transport.send(request);
    if (response.isSuccessful) return response;
    throw _exceptionFor(response, request.idempotencyKey);
  }

  Exception _exceptionFor(PuenteResponse response, String? idempotencyKey) {
    final body = response.jsonObject;
    final message = (body['message'] as String?) ??
        (body['error'] as String?) ??
        'HTTP ${response.statusCode}';
    // Backend `error` strings for money-critical rejections are stable
    // token-prefixed identifiers (`quote_expired`, `quote_already_used`,
    // `beneficiary_not_registered: …`, `insufficient_funds`, …). Strip
    // the trailing ": <detail>" so `ApiException.code` is the stable
    // machine-readable identifier callers can branch on.
    final rawCode = body['error'] as String?;
    final code = rawCode == null
        ? null
        : (rawCode.contains(':')
            ? rawCode.substring(0, rawCode.indexOf(':'))
            : rawCode);
    final requestId = response.requestId;

    // Server-emitted quote_expired 409 maps to the same typed exception
    // the client-side createFromQuote guard raises — callers catch one
    // type regardless of which side detected the staleness.
    if (response.statusCode == 409 && code == 'quote_expired') {
      return StaleQuoteException(
        message,
        requestId: requestId,
        idempotencyKey: idempotencyKey,
      );
    }

    switch (response.statusCode) {
      case 401:
      case 403:
        return AuthException(
          message,
          statusCode: response.statusCode,
          code: code,
          body: body,
          requestId: requestId,
          idempotencyKey: idempotencyKey,
        );
      case 422:
        final raw = body['errors'] ?? body['field_errors'];
        final fieldErrors = <String, String>{};
        if (raw is Map) {
          raw.forEach((k, v) {
            if (k is String) {
              fieldErrors[k] = v?.toString() ?? '';
            }
          });
        }
        return ValidationException(
          message,
          statusCode: response.statusCode,
          fieldErrors: fieldErrors,
          code: code,
          body: body,
          requestId: requestId,
          idempotencyKey: idempotencyKey,
        );
      case 429:
        final retryAfter = _parseRetryAfter(response.headers['retry-after']);
        return RateLimitException(
          message,
          statusCode: response.statusCode,
          retryAfter: retryAfter,
          code: code,
          body: body,
          requestId: requestId,
          idempotencyKey: idempotencyKey,
        );
      default:
        return ApiException(
          message,
          statusCode: response.statusCode,
          code: code,
          body: body,
          requestId: requestId,
          idempotencyKey: idempotencyKey,
        );
    }
  }

  Duration? _parseRetryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }
}
