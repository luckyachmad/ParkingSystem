// Value type representing a monetary amount stored as integer cents.
// All arithmetic in the service layer uses cents to avoid floating-point errors.
// Convert to a display string only at the UI layer.

class Money {
  /// The amount in integer cents (e.g. 1250 = $12.50).
  final int cents;

  const Money(this.cents);

  /// Returns a display string formatted to 2 decimal places with a currency
  /// symbol, e.g. "$12.50".
  String toDisplay({String symbol = '\$'}) {
    final dollars = cents ~/ 100;
    final remainder = (cents % 100).abs();
    return '$symbol$dollars.${remainder.toString().padLeft(2, '0')}';
  }

  /// Convenience: the amount as a double (dollars).
  double get amount => cents / 100.0;

  @override
  bool operator ==(Object other) => other is Money && other.cents == cents;

  @override
  int get hashCode => cents.hashCode;

  @override
  String toString() => 'Money($cents cents)';
}
