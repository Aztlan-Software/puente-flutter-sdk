import '../exceptions/decode_exception.dart';
import '../models/currency.dart';
import '../models/money.dart';
import '../models/quote.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// `POST /v1/quotes` — get a short-lived FX + fee quote for a
/// cross-currency send.
///
/// Quotes are stateless and free; create as many as you like. To convert
/// a quote into a real movement, pass [Quote.id] to
/// `TransfersResource.create`.
class QuotesResource extends ResourceBase {
  /// Build a [QuotesResource].
  QuotesResource(super.transport);

  /// Create a quote.
  ///
  /// [sourceAmount] is what the sender will be debited; the server
  /// returns a [Quote] with the matching [Quote.targetAmount] and
  /// [Quote.fee] in the source currency. All FX, fee, and total math is
  /// done by the backend — the SDK only relays the request and
  /// deserializes the answer.
  ///
  /// [feeInclusive] makes [sourceAmount] the TOTAL cost instead: the
  /// server takes its fee out of it first and converts what is left, so
  /// [Quote.totalCost] equals [sourceAmount], [Quote.sourceAmount] is
  /// that total less [Quote.fee], and [Quote.targetAmount] is what the
  /// remainder converts to. It is for moving a whole balance (a wallet
  /// changing currency), where nothing exists to pay a fee on top. Sent
  /// as `fee_inclusive: true`. A server that ignores the flag would
  /// answer with the fee on top; that quote is refused with a
  /// [DecodeException] rather than handed back with the other meaning.
  ///
  /// [beneficiaryCountry] is the optional ISO country of the beneficiary
  /// (e.g. `"MX"`), forwarded as `beneficiary_country`.
  ///
  /// The request body carries both the current backend keys
  /// (`source_amount_minor`, `destination_currency`) and the legacy keys
  /// (`source_amount`, `target_currency`) in one object — the axum
  /// backend ignores unknown fields, so one wire shape serves both server
  /// generations.
  ///
  /// Pass [idempotencyKey] to dedup repeated quote requests for the
  /// same UX gesture (e.g. tapping "preview" twice). The SDK generates
  /// one automatically if you don't.
  Future<Quote> create({
    required Money sourceAmount,
    required Currency targetCurrency,
    bool feeInclusive = false,
    String? beneficiaryCountry,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/quotes',
      body: <String, dynamic>{
        // Legacy shape (older servers + stored fixtures).
        'source_amount': sourceAmount.toJson(),
        'source_currency': sourceAmount.currency.code,
        'target_currency': targetCurrency.code,
        // Current backend shape (POST /v1/quotes).
        'source_amount_minor': sourceAmount.minorUnits,
        'destination_currency': targetCurrency.code,
        if (feeInclusive) 'fee_inclusive': true,
        if (beneficiaryCountry != null)
          'beneficiary_country': beneficiaryCountry,
      },
      idempotencyKey: key,
    ));
    final quote =
        decode(response, Quote.fromJson, target: 'Quote', idempotencyKey: key);
    // Because unknown fields are ignored, a backend without fee-inclusive
    // pricing answers as if the flag were absent. Its total then differs
    // from the amount asked for whenever there is a fee.
    if (feeInclusive && quote.totalCost != sourceAmount) {
      throw DecodeException(
        'fee_inclusive quote came back with total_cost '
        '${quote.totalCost?.minorUnits} for a requested total of '
        '${sourceAmount.minorUnits}; the server did not honour the flag',
        target: 'Quote.totalCost',
        requestId: response.requestId,
        idempotencyKey: key,
      );
    }
    return quote;
  }
}
