enum PaymentStatus { paid, unpaid, cancelled }

class ParkingTransaction {
  final int? id;
  final int ticketId;
  final String plateNumber;
  final DateTime entryTime;
  final DateTime exitTime;
  final int durationMinutes;
  final double fee; // stored as INTEGER cents in DB
  final PaymentStatus paymentStatus;
  final String pricingRuleName; // denormalized for audit readability

  const ParkingTransaction({
    this.id,
    required this.ticketId,
    required this.plateNumber,
    required this.entryTime,
    required this.exitTime,
    required this.durationMinutes,
    required this.fee,
    required this.paymentStatus,
    required this.pricingRuleName,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'ticket_id': ticketId,
      'plate_number': plateNumber,
      'entry_time': entryTime.millisecondsSinceEpoch,
      'exit_time': exitTime.millisecondsSinceEpoch,
      'duration_minutes': durationMinutes,
      'fee_cents': (fee * 100).round(),
      'payment_status': paymentStatus.name,
      'pricing_rule_name': pricingRuleName,
    };
  }

  factory ParkingTransaction.fromMap(Map<String, dynamic> map) {
    return ParkingTransaction(
      id: map['id'] as int?,
      ticketId: map['ticket_id'] as int,
      plateNumber: map['plate_number'] as String,
      entryTime: DateTime.fromMillisecondsSinceEpoch(
        map['entry_time'] as int,
        isUtc: true,
      ),
      exitTime: DateTime.fromMillisecondsSinceEpoch(
        map['exit_time'] as int,
        isUtc: true,
      ),
      durationMinutes: map['duration_minutes'] as int,
      fee: (map['fee_cents'] as int) / 100.0,
      paymentStatus:
          PaymentStatus.values.byName(map['payment_status'] as String),
      pricingRuleName: map['pricing_rule_name'] as String,
    );
  }

  ParkingTransaction copyWith({
    int? id,
    int? ticketId,
    String? plateNumber,
    DateTime? entryTime,
    DateTime? exitTime,
    int? durationMinutes,
    double? fee,
    PaymentStatus? paymentStatus,
    String? pricingRuleName,
  }) {
    return ParkingTransaction(
      id: id ?? this.id,
      ticketId: ticketId ?? this.ticketId,
      plateNumber: plateNumber ?? this.plateNumber,
      entryTime: entryTime ?? this.entryTime,
      exitTime: exitTime ?? this.exitTime,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      fee: fee ?? this.fee,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      pricingRuleName: pricingRuleName ?? this.pricingRuleName,
    );
  }
}
