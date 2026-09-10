import '../models/account.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// `POST /v1/accounts` — register a sender or recipient.
/// `GET /v1/accounts/:id` — retrieve.
/// `PATCH /v1/accounts/:id` — partial update.
///
/// Accounts must be created before any transfer that references them.
/// For US senders, KYC tier matters: [KycTier.tier1] suffices for small
/// amounts; [KycTier.tier2] (full document verification) is required
/// over a per-month threshold.
class AccountsResource extends ResourceBase {
  /// Build an [AccountsResource].
  AccountsResource(super.transport);

  /// Create a new account.
  ///
  /// [dateOfBirth] is sent as an ISO-8601 date-only string (`YYYY-MM-DD`).
  Future<Account> create({
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    DateTime? dateOfBirth,
    String? addressLine1,
    String? city,
    String? state,
    String? postalCode,
    String? country,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'POST',
      path: '/accounts',
      body: <String, dynamic>{
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'phone': phone,
        if (dateOfBirth != null) 'date_of_birth': _isoDate(dateOfBirth),
        if (addressLine1 != null) 'address_line_1': addressLine1,
        if (city != null) 'city': city,
        if (state != null) 'state': state,
        if (postalCode != null) 'postal_code': postalCode,
        if (country != null) 'country': country,
      },
      idempotencyKey: key,
    ));
    return decode(response, Account.fromJson,
        target: 'Account', idempotencyKey: key);
  }

  /// Retrieve an account by id.
  Future<Account> retrieve(String id) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/accounts/${pathSegment(id, 'id')}',
    ));
    return decode(response, Account.fromJson, target: 'Account');
  }

  /// Partial update (only fields the server allows merchants to
  /// mutate). KYC tier is never client-writable.
  Future<Account> update(
    String id, {
    String? phone,
    String? email,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey();
    final response = await request(PuenteRequest(
      method: 'PATCH',
      path: '/accounts/${pathSegment(id, 'id')}',
      body: <String, dynamic>{
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
      },
      idempotencyKey: key,
    ));
    return decode(response, Account.fromJson,
        target: 'Account', idempotencyKey: key);
  }

  String _isoDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
