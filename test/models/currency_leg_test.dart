import 'package:puente_railway/puente_railway.dart';
import 'package:test/test.dart';

void main() {
  group('CurrencyLeg', () {
    test('fromWire parses every known leg', () {
      expect(CurrencyLeg.fromWire('USDC'), CurrencyLeg.usdc);
      expect(CurrencyLeg.fromWire('OUSD'), CurrencyLeg.ousd);
      expect(CurrencyLeg.fromWire('CETES'), CurrencyLeg.cetes);
    });

    test('unknown wire value falls back to unknown (forward-compatible)', () {
      expect(CurrencyLeg.fromWire('SOLBOND'), CurrencyLeg.unknown);
      expect(CurrencyLeg.fromWire(''), CurrencyLeg.unknown);
      expect(CurrencyLeg.fromWire(null), CurrencyLeg.unknown);
      // Wire values are case-sensitive UPPERCASE tickers.
      expect(CurrencyLeg.fromWire('usdc'), CurrencyLeg.unknown);
    });
  });

  group('Currency.ousd', () {
    test('is wired as OUSD with 6 decimals', () {
      expect(Currency.ousd.code, 'OUSD');
      expect(Currency.ousd.decimals, 6);
      expect(Currency.fromCode('OUSD'), Currency.ousd);
      expect(Currency.fromCode('ousd'), Currency.ousd);
    });
  });

  group('Currency.brl', () {
    test('is wired as BRL with 2 decimals', () {
      expect(Currency.brl.code, 'BRL');
      expect(Currency.brl.decimals, 2);
      expect(Currency.fromCode('BRL'), Currency.brl);
      expect(Currency.tryFromCode('brl'), Currency.brl);
    });
  });
}
