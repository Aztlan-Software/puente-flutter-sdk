/// Which Puente Railway deployment the SDK should talk to.
///
/// * [mock] — no network. All requests are served by an in-memory
///   [MockTransport]. Use for unit tests and offline demos.
/// * [testnet] — Puente devnet target. The on-chain leg hits Solana devnet
///   via Helius; fiat off-ramp hits Etherfuse sandbox.
/// * [sandbox] — staging environment, hosted somewhere stable (no real
///   funds, but a real database + real Etherfuse sandbox).
/// * [production] — real money, real CETES, real SPEI.
enum PuenteEnvironment {
  /// In-memory mock. No HTTP traffic. Default for `PuenteClient.mock()`.
  /// Dev/test-only — `PuenteClient` refuses it in release builds.
  mock,

  /// Puente devnet (`https://api-testnet.puenterailway.com/v1`).
  testnet,

  /// Sandbox (`https://api-sandbox.puenterailway.com/v1`).
  sandbox,

  /// Production (`https://api.puenterailway.com/v1`).
  production,
}

/// Asynchronous per-request bearer-token source.
///
/// Return a fresh, short-lived user-session token minted by your backend.
/// See [PuenteConfig.tokenProvider].
typedef PuenteTokenProvider = Future<String> Function();

/// Immutable configuration for a [PuenteClient].
///
/// Construct via [PuenteConfig.new] when you want to set every option, or
/// the [PuenteConfig.testnet] / [PuenteConfig.sandbox] / [PuenteConfig.production]
/// helpers for the common cases.
///
/// ## Choosing an auth source
///
/// Exactly one credential source is expected:
///
/// * **Server / CLI** — pass [apiKey]. `sk_` merchant keys are
///   **SERVER-SIDE ONLY** and must never be embedded in mobile builds
///   (anyone can extract strings from an app bundle).
/// * **Mobile / Flutter** — pass [tokenProvider]. The SDK asks it for a
///   fresh short-lived user-session token (minted by your backend) on
///   every request.
///
/// If both are supplied, [tokenProvider] wins — this eases migration from
/// key-based to token-based auth. Supplying neither (outside
/// [PuenteEnvironment.mock]) throws [ArgumentError].
class PuenteConfig {
  /// API key Puente issued to this merchant. Sent as
  /// `Authorization: Bearer <key>` on every authenticated request when no
  /// [tokenProvider] is configured.
  ///
  /// **`sk_` merchant keys are SERVER-SIDE ONLY** — never embed one in a
  /// mobile build; use [tokenProvider] there instead. May be empty in
  /// [PuenteEnvironment.mock].
  final String apiKey;

  /// Per-request bearer-token source for mobile-safe auth.
  ///
  /// When set, `HttpTransport` awaits it on **every request attempt** and
  /// sends `Authorization: Bearer <token>` — so short-lived user-session
  /// tokens (minted by your backend) stay fresh across retries. Takes
  /// precedence over [apiKey] when both are configured.
  final PuenteTokenProvider? tokenProvider;

  /// Optional merchant identifier. When set, sent as
  /// `X-Puente-Merchant-Id` so the server can scope rate limits and
  /// audit logs per merchant.
  final String? merchantId;

  /// Which deployment to target. Drives [baseUrl].
  final PuenteEnvironment environment;

  /// Override the resolved base URL. Useful for pointing at a local
  /// `puente-api` during development (`http://127.0.0.1:8080/v1`).
  ///
  /// When `null`, the URL is derived from [environment].
  final Uri? baseUrlOverride;

  /// Per-request timeout. Applied to the entire request — connect +
  /// send + receive.
  final Duration timeout;

  /// Maximum retry attempts on a transport error or `429` / `5xx`
  /// response. `0` disables retries. Defaults to 3.
  final int maxRetries;

  /// Base delay for exponential backoff between retries. Actual delay is
  /// `baseRetryDelay * 2^(attempt - 1) ± jitter`.
  final Duration baseRetryDelay;

  /// Maximum delay between retries (caps the exponential growth).
  final Duration maxRetryDelay;

  /// SDK identifier echoed in the `User-Agent` and `X-SDK-Version`
  /// headers. Defaults to the package version.
  final String userAgent;

  /// Build a [PuenteConfig] with explicit values.
  ///
  /// Throws [ArgumentError] when neither [apiKey] nor [tokenProvider] is
  /// provided for a non-mock environment — every real deployment needs
  /// exactly one auth source ([tokenProvider] wins when both are set).
  PuenteConfig({
    this.apiKey = '',
    this.tokenProvider,
    required this.environment,
    this.merchantId,
    this.baseUrlOverride,
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.baseRetryDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 10),
    this.userAgent = 'puente_railway/$packageVersion',
  }) {
    if (environment != PuenteEnvironment.mock &&
        apiKey.isEmpty &&
        tokenProvider == null) {
      throw ArgumentError(
        'PuenteConfig: an auth source is required — pass apiKey '
        '(server-side sk_ keys only) or tokenProvider (mobile-safe '
        'short-lived session tokens).',
      );
    }
    _assertTransportIsEncrypted();
  }

  /// Refuse a cleartext base URL for anything that is not a local backend.
  ///
  /// [baseUrlOverride] exists so a developer can point at a local
  /// `puente-api` over `http://127.0.0.1:8080/v1`. Nothing previously
  /// stopped that same override from carrying a production `sk_` key to an
  /// arbitrary `http://` host, where the bearer token, the CLABE, the
  /// beneficiary name, and the raw SSN/ITIN/CURP submitted through
  /// `onboarding.updateProfile` all travel in the clear and are trivially
  /// modifiable in transit.
  ///
  /// Loopback stays allowed — it does not leave the machine — as do the
  /// `mock` environment and any non-HTTP scheme (the mock sentinel).
  void _assertTransportIsEncrypted() {
    if (environment == PuenteEnvironment.mock) return;
    final url = baseUrl;
    if (url.scheme != 'http') return;
    if (_isLoopback(url.host)) return;
    throw ArgumentError.value(
      url.toString(),
      'baseUrlOverride',
      'refusing a cleartext http:// base URL for a non-loopback host — '
          'credentials and PII would be sent unencrypted. Use https://, or '
          'point at localhost for local development.',
    );
  }

  static bool _isLoopback(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
    // Any 127.0.0.0/8 address.
    final v4 = h.split('.');
    if (v4.length == 4 && v4[0] == '127') {
      return v4.every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255;
      });
    }
    return false;
  }

  /// Convenience for an in-memory mock client.
  factory PuenteConfig.mock({
    String apiKey = 'sk_mock',
    String? merchantId,
  }) =>
      PuenteConfig(
        apiKey: apiKey,
        merchantId: merchantId,
        environment: PuenteEnvironment.mock,
      );

  /// Convenience for the Puente devnet (testnet).
  ///
  /// Pass [apiKey] server-side or [tokenProvider] in mobile builds.
  factory PuenteConfig.testnet({
    String apiKey = '',
    PuenteTokenProvider? tokenProvider,
    String? merchantId,
    Uri? baseUrlOverride,
  }) =>
      PuenteConfig(
        apiKey: apiKey,
        tokenProvider: tokenProvider,
        merchantId: merchantId,
        environment: PuenteEnvironment.testnet,
        baseUrlOverride: baseUrlOverride,
      );

  /// Convenience for the sandbox environment.
  ///
  /// Pass [apiKey] server-side or [tokenProvider] in mobile builds.
  factory PuenteConfig.sandbox({
    String apiKey = '',
    PuenteTokenProvider? tokenProvider,
    String? merchantId,
  }) =>
      PuenteConfig(
        apiKey: apiKey,
        tokenProvider: tokenProvider,
        merchantId: merchantId,
        environment: PuenteEnvironment.sandbox,
      );

  /// Convenience for the production environment.
  ///
  /// Pass [apiKey] server-side or [tokenProvider] in mobile builds.
  factory PuenteConfig.production({
    String apiKey = '',
    PuenteTokenProvider? tokenProvider,
    String? merchantId,
  }) =>
      PuenteConfig(
        apiKey: apiKey,
        tokenProvider: tokenProvider,
        merchantId: merchantId,
        environment: PuenteEnvironment.production,
      );

  /// Effective base URL the HTTP transport should hit.
  ///
  /// Order of resolution: [baseUrlOverride] wins if set; otherwise we
  /// derive from [environment]. [PuenteEnvironment.mock] returns a
  /// sentinel value that the [HttpTransport] never uses (the mock
  /// transport doesn't hit the network).
  Uri get baseUrl {
    if (baseUrlOverride != null) return baseUrlOverride!;
    switch (environment) {
      case PuenteEnvironment.mock:
        return Uri.parse('mock://puente');
      case PuenteEnvironment.testnet:
        return Uri.parse('https://api-testnet.puenterailway.com/v1');
      case PuenteEnvironment.sandbox:
        return Uri.parse('https://api-sandbox.puenterailway.com/v1');
      case PuenteEnvironment.production:
        return Uri.parse('https://api.puenterailway.com/v1');
    }
  }
}

/// Current SDK package version, mirrored from pubspec.yaml. Bump on
/// release; CI checks the two are in sync.
const String packageVersion = '0.6.0';
