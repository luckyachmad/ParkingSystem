import 'pricing_rule.dart';

class Ticket {
  final int? id;
  final String plateNumber;
  final DateTime entryTime; // UTC
  final DateTime? exitTime; // UTC; null = open ticket
  final int pricingRuleId;
  // Snapshot fields — copied from PricingRule at entry time
  final String pricingRuleName;
  final RateType rateType;
  final double rateAmount;
  final int gracePeriodMinutes;
  final double? dailyMaxCap;
  final String createdBy; // username of attendant
  final String? closedBy; // username of attendant who processed exit

  const Ticket({
    this.id,
    required this.plateNumber,
    required this.entryTime,
    this.exitTime,
    required this.pricingRuleId,
    required this.pricingRuleName,
    required this.rateType,
    required this.rateAmount,
    required this.gracePeriodMinutes,
    this.dailyMaxCap,
    required this.createdBy,
    this.closedBy,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'plate_number': plateNumber,
      'entry_time': entryTime.millisecondsSinceEpoch,
      'exit_time': exitTime?.millisecondsSinceEpoch,
      'pricing_rule_id': pricingRuleId,
      'pricing_rule_name': pricingRuleName,
      'rate_type': rateType.name,
      'rate_amount_cents': (rateAmount * 100).round(),
      'grace_period_minutes': gracePeriodMinutes,
      'daily_max_cap_cents':
          dailyMaxCap != null ? (dailyMaxCap! * 100).round() : null,
      'created_by': createdBy,
      'closed_by': closedBy,
    };
  }

  factory Ticket.fromMap(Map<String, dynamic> map) {
    return Ticket(
      id: map['id'] as int?,
      plateNumber: map['plate_number'] as String,
      entryTime: DateTime.fromMillisecondsSinceEpoch(
        map['entry_time'] as int,
        isUtc: true,
      ),
      exitTime: map['exit_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['exit_time'] as int,
              isUtc: true,
            )
          : null,
      pricingRuleId: map['pricing_rule_id'] as int,
      pricingRuleName: map['pricing_rule_name'] as String,
      rateType: RateType.values.byName(map['rate_type'] as String),
      rateAmount: (map['rate_amount_cents'] as int) / 100.0,
      gracePeriodMinutes: map['grace_period_minutes'] as int,
      dailyMaxCap: map['daily_max_cap_cents'] != null
          ? (map['daily_max_cap_cents'] as int) / 100.0
          : null,
      createdBy: map['created_by'] as String,
      closedBy: map['closed_by'] as String?,
    );
  }

  Ticket copyWith({
    int? id,
    String? plateNumber,
    DateTime? entryTime,
    Object? exitTime = _sentinel,
    int? pricingRuleId,
    String? pricingRuleName,
    RateType? rateType,
    double? rateAmount,
    int? gracePeriodMinutes,
    Object? dailyMaxCap = _sentinel,
    String? createdBy,
    Object? closedBy = _sentinel,
  }) {
    return Ticket(
      id: id ?? this.id,
      plateNumber: plateNumber ?? this.plateNumber,
      entryTime: entryTime ?? this.entryTime,
      exitTime:
          identical(exitTime, _sentinel) ? this.exitTime : exitTime as DateTime?,
      pricingRuleId: pricingRuleId ?? this.pricingRuleId,
      pricingRuleName: pricingRuleName ?? this.pricingRuleName,
      rateType: rateType ?? this.rateType,
      rateAmount: rateAmount ?? this.rateAmount,
      gracePeriodMinutes: gracePeriodMinutes ?? this.gracePeriodMinutes,
      dailyMaxCap: identical(dailyMaxCap, _sentinel)
          ? this.dailyMaxCap
          : dailyMaxCap as double?,
      createdBy: createdBy ?? this.createdBy,
      closedBy:
          identical(closedBy, _sentinel) ? this.closedBy : closedBy as String?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();
