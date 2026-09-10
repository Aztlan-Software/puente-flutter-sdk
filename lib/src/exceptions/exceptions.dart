/// Typed exception hierarchy thrown by the Puente Railway SDK.
///
/// Every SDK call's failure path produces a subclass of [PuenteException];
/// catching that root type guarantees you won't miss an error case as new
/// subclasses are added.
library;

export 'api_exception.dart';
export 'auth_exception.dart';
export 'decode_exception.dart';
export 'invalid_argument_exception.dart';
export 'puente_exception.dart';
export 'rate_limit_exception.dart';
export 'stale_quote_exception.dart';
export 'transport_exception.dart';
export 'validation_exception.dart';
export 'webhook_exception.dart';
