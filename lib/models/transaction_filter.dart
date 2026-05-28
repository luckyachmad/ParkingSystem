import 'parking_transaction.dart';

class TransactionFilter {
  final DateTime? fromDate;
  final DateTime? toDate;
  final String? plateSubstring;
  final PaymentStatus? paymentStatus;

  const TransactionFilter({
    this.fromDate,
    this.toDate,
    this.plateSubstring,
    this.paymentStatus,
  });

  TransactionFilter copyWith({
    Object? fromDate = _sentinel,
    Object? toDate = _sentinel,
    Object? plateSubstring = _sentinel,
    Object? paymentStatus = _sentinel,
  }) {
    return TransactionFilter(
      fromDate: identical(fromDate, _sentinel)
          ? this.fromDate
          : fromDate as DateTime?,
      toDate:
          identical(toDate, _sentinel) ? this.toDate : toDate as DateTime?,
      plateSubstring: identical(plateSubstring, _sentinel)
          ? this.plateSubstring
          : plateSubstring as String?,
      paymentStatus: identical(paymentStatus, _sentinel)
          ? this.paymentStatus
          : paymentStatus as PaymentStatus?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();
