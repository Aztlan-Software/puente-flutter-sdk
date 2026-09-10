import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../client/puente_config.dart';
import '../exceptions/invalid_argument_exception.dart';
import '../exceptions/transport_exception.dart';
import '../observability/puente_observer.dart';
import 'puente_request.dart';
import 'puente_response.dart';
import 'puente_transport.dart';

/// Transport that talks to a real Puente Railway server over HTTPS.
///
/// Adds:
/// * `Authorization: Bearer <token>` — resolved fresh from
///   [PuenteConfig.tokenProvider] on **every attempt** when configured
///   (mobile-safe short-lived session tokens), otherwise the static
///   [PuenteConfig.apiKey] (server-side `sk_` keys only; omitted when
///   empty in mock mode).
/// * `Content-Type` + `Accept` (`application/json`).
/// * `User-Agent` + `X-SDK-Version` (from [PuenteConfig.userAgent]).
/// * `X-Puente-Merchant-Id` when [PuenteConfig.merchantId] is set.
/// * `Idempotency-Key` when the [PuenteRequest] carries one.
///
/// Handles:
/// * Exponential backoff with jitter on retryable status codes (429,
///   500–599) and transport errors.
/// * `Retry-After` header — server-recommended wait wins when present.
/// * Distinct [TransportException] (no response) vs [PuenteResponse]
///   with a non-2xx status (server answered).
///
/// Does NOT translate non-2xx into typed exceptions. That's the resource
/// layer's job; transport just delivers bytes.
class HttpTransport implements PuenteTransport {
  /// Build a real HTTP transport.
  HttpTransport({
    required this.config,
    PuenteObserver? observer,
    http.Client? inner,
    math.Random? random,
  })  : _client = inner ?? http.Client(),
        _observer = observer ?? const PuenteObserver.silent(),
        _random = random ?? math.Random();

  /// SDK config (base URL, headers, retry policy).
  final PuenteConfig config;

  final http.Client _client;
  final PuenteObserver _observer;
  final math.Random _random;

  @override
  Future<PuenteResponse> send(PuenteRequest request) async {
    final url = _buildUri(request);

    var attempt = 0;
    while (true) {
      attempt += 1;
      // Re-merged per attempt: a tokenProvider mints a fresh short-lived
      // token for every try, so a retry never replays an expired bearer.
      // A tokenProvider failure must not escape as a raw exception (the
      // SDK's contract is that transport errors surface as
      // TransportException) — wrap and rethrow.
      final Map<String, String> mergedHeaders;
      try {
        mergedHeaders = await _mergeHeaders(request);
      } catch (e) {
        // A tokenProvider failure must not escape as a raw exception:
        // the SDK's contract is that transport-time failures surface as
        // TransportException so callers only need one catch site.
        throw TransportException(
          'tokenProvider failed: $e',
          cause: e,
          idempotencyKey: request.idempotencyKey,
        );
      }
      final started = clock.now();

      _observer.onRequest(PuenteRequestEvent(
        method: request.method,
        url: url,
        headers: _maskSensitive(mergedHeaders),
        attempt: attempt,
        idempotencyKey: request.idempotencyKey,
      ));

      PuenteResponse? response;
      Object? transportError;
      StackTrace? transportStack;

      try {
        final httpResponse = await _sendOnce(request, url, mergedHeaders);
        response = PuenteResponse(
          statusCode: httpResponse.statusCode,
          headers: _lowercaseKeys(httpResponse.headers),
          body: httpResponse.body,
        );
      } on TimeoutException catch (e, s) {
        transportError = e;
        transportStack = s;
      } on http.ClientException catch (e, s) {
        transportError = e;
        transportStack = s;
      } catch (e, s) {
        transportError = e;
        transportStack = s;
      }

      if (response != null) {
        _observer.onResponse(PuenteResponseEvent(
          method: request.method,
          url: url,
          statusCode: response.statusCode,
          requestId: response.requestId,
          elapsed: clock.now().difference(started),
          attempt: attempt,
        ));
      }

      // Decide whether to retry.
      final shouldRetry = attempt <= config.maxRetries &&
          (transportError != null || _isRetryableStatus(response?.statusCode));
      if (!shouldRetry) {
        if (response != null) return response;
        // Out of retries on a transport error — translate now.
        final cause = transportError ?? const _UnknownTransportError();
        final stack = transportStack ?? StackTrace.current;
        // Echo the idempotency key back. This is the ambiguous-outcome
        // case (H-18): the request may have taken effect server-side even
        // though we never saw a response. Without the key the caller can
        // only retry with a freshly minted one, which the server reads as a
        // second, distinct operation — a double-send.
        final ex = TransportException(
          'HTTP transport failed after $attempt attempt${attempt == 1 ? '' : 's'}: $cause',
          cause: cause,
          idempotencyKey: request.idempotencyKey,
        );
        _observer.onError(PuenteErrorEvent(
          method: request.method,
          url: url,
          error: ex,
          stackTrace: stack,
        ));
        throw ex;
      }

      // Compute backoff and notify observer.
      final delay = _backoff(
        attempt: attempt,
        retryAfterHeader: response?.headers['retry-after'],
      );
      _observer.onRetry(PuenteRetryEvent(
        method: request.method,
        url: url,
        reason: response != null
            ? 'status ${response.statusCode}'
            : 'transport ${transportError.runtimeType}',
        delay: delay,
        attempt: attempt,
      ));
      await Future<void>.delayed(delay);
    }
  }

  Future<http.Response> _sendOnce(
    PuenteRequest request,
    Uri url,
    Map<String, String> headers,
  ) async {
    final method = request.method.toUpperCase();
    Future<http.Response> future;
    switch (method) {
      case 'GET':
        future = _client.get(url, headers: headers);
      case 'DELETE':
        future = _client.delete(url, headers: headers);
      case 'HEAD':
        future = _client.head(url, headers: headers);
      case 'POST':
        future =
            _client.post(url, headers: headers, body: request.encodedBody());
      case 'PUT':
        future =
            _client.put(url, headers: headers, body: request.encodedBody());
      case 'PATCH':
        future =
            _client.patch(url, headers: headers, body: request.encodedBody());
      default:
        throw InvalidArgumentException(
          'unsupported HTTP method',
          parameter: 'method',
          value: method,
        );
    }
    return future.timeout(config.timeout);
  }

  Uri _buildUri(PuenteRequest request) {
    final base = config.baseUrl;
    final path =
        request.path.startsWith('/') ? request.path : '/${request.path}';
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final url = base.replace(
      path: '$basePath$path',
      queryParameters: request.query.isEmpty ? null : request.query,
    );
    return url;
  }

  Future<Map<String, String>> _mergeHeaders(PuenteRequest request) async {
    final out = <String, String>{
      'Accept': 'application/json',
      'User-Agent': config.userAgent,
      'X-SDK-Version': packageVersion,
    };
    if (request.body != null) out['Content-Type'] = 'application/json';
    final tokenProvider = config.tokenProvider;
    if (tokenProvider != null) {
      // Mobile-safe path: a fresh user-session token per request. Errors
      // from the provider propagate to the caller — auth can't be
      // silently skipped.
      out['Authorization'] = 'Bearer ${await tokenProvider()}';
    } else if (config.apiKey.isNotEmpty) {
      out['Authorization'] = 'Bearer ${config.apiKey}';
    }
    if (config.merchantId != null && config.merchantId!.isNotEmpty) {
      out['X-Puente-Merchant-Id'] = config.merchantId!;
    }
    if (request.idempotencyKey != null) {
      out['Idempotency-Key'] = request.idempotencyKey!;
    }
    // Caller-supplied headers win — let merchants override anything for
    // testing without modifying the SDK.
    out.addAll(request.headers);
    return out;
  }

  Map<String, String> _maskSensitive(Map<String, String> headers) {
    final masked = <String, String>{};
    headers.forEach((k, v) {
      final lower = k.toLowerCase();
      if (lower == 'authorization') {
        masked[k] = _maskCredential(v);
      } else if (lower == 'idempotency-key') {
        masked[k] = _maskCorrelator(v);
      } else {
        masked[k] = v;
      }
    });
    return masked;
  }

  /// Mask a credential so **no byte of the secret** reaches an observer.
  ///
  /// Observers commonly forward to Sentry or a log aggregator, so anything
  /// emitted here should be assumed to be retained. The previous masking
  /// kept the last four characters of the bearer value; that is a real (if
  /// small) leak of key material into a lower-trust sink for zero
  /// operational benefit — `Idempotency-Key` and `X-Request-Id` are the
  /// correlators, not the credential. The scheme is preserved because it
  /// distinguishes a missing header from a malformed one.
  String _maskCredential(String v) {
    final space = v.indexOf(' ');
    if (space > 0) return '${v.substring(0, space)} ***';
    return '***';
  }

  /// An idempotency key is a correlator, not a secret — keep enough of it
  /// to line a log line up with a server-side record.
  String _maskCorrelator(String v) {
    if (v.length <= 8) return '***';
    return '${v.substring(0, 4)}…${v.substring(v.length - 4)}';
  }

  Map<String, String> _lowercaseKeys(Map<String, String> headers) {
    final out = <String, String>{};
    headers.forEach((k, v) => out[k.toLowerCase()] = v);
    return out;
  }

  bool _isRetryableStatus(int? status) {
    if (status == null) return false;
    if (status == 429) return true;
    if (status >= 500 && status < 600) return true;
    return false;
  }

  Duration _backoff({required int attempt, String? retryAfterHeader}) {
    // Server-recommended wait wins.
    final fromHeader = _parseRetryAfter(retryAfterHeader);
    if (fromHeader != null) {
      return _capDelay(fromHeader);
    }
    final base = config.baseRetryDelay.inMilliseconds;
    final exp = base * math.pow(2, attempt - 1);
    final jitter = (_random.nextDouble() - 0.5) * 2 * base / 4;
    final ms = (exp + jitter).clamp(0, 1 << 30).toInt();
    return _capDelay(Duration(milliseconds: ms));
  }

  Duration _capDelay(Duration d) =>
      d > config.maxRetryDelay ? config.maxRetryDelay : d;

  Duration? _parseRetryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    // RFC 9110 also allows an HTTP-date. We'll parse later if needed.
    return null;
  }

  @override
  void close() => _client.close();
}

/// Sentinel for the rare case where retry loop exits with no recorded
/// error.
class _UnknownTransportError implements Exception {
  const _UnknownTransportError();

  @override
  String toString() => 'unknown transport error';
}
