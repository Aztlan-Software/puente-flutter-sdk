import '../models/clabe_info.dart';
import '../transport/puente_request.dart';
import 'resource_base.dart';

/// `GET /v1/clabe/:clabe` — validate + look up bank metadata for a
/// Mexican CLABE.
///
/// Use before creating a transfer to surface "wrong bank, check the
/// CLABE" errors at form time instead of at settlement time.
class ClabeResource extends ResourceBase {
  /// Build a [ClabeResource].
  ClabeResource(super.transport);

  /// Look up a CLABE.
  ///
  /// Returns a [ClabeInfo] even when the value is invalid — check
  /// [ClabeInfo.valid] before using it for a transfer. The
  /// [ClabeInfo.bankName] is "Unknown Bank" when the prefix wasn't in
  /// the server's registry.
  Future<ClabeInfo> lookup(String clabe) async {
    final response = await request(PuenteRequest(
      method: 'GET',
      path: '/clabe/${pathSegment(clabe, 'clabe')}',
    ));
    return decode(response, ClabeInfo.fromJson, target: 'ClabeInfo');
  }
}
