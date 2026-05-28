enum RateType { hourly, flat }

class PricingRule {
  final int? id;
  final String name;
  final RateType rateType;
  final double rateAmount; // stored as INTEGER cents in DB
  final int gracePeriodMinutes; // 0 = no grace period
  final double? dailyMaxCap; // null = no cap; stored as INTEGER cents
  final bool isActive;
  final bool isDefault;

  const PricingRule({
    this.id,
    required this.name,
    required this.rateType,
    required this.rateAmount,
    required this.gracePeriodMinutes,
    this.dailyMaxCap,
    required this.isActive,
    required this.isDefault,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'rate_type': rateType.name,
      'rate_amount_cents': (rateAmount * 100).round(),
      'grace_period_minutes': gracePeriodMinutes,
      'daily_max_cap_cents':
          dailyMaxCap != null ? (dailyMaxCap! * 100).round() : null,
      'is_active': isActive ? 1 : 0,
      'is_default': isDefault ? 1 : 0,
    };
  }

  factory PricingRule.fromMap(Map<String, dynamic> map) {
    return PricingRule(
      id: map['id'] as int?,
      name: map['name'] as String,
      rateType: RateType.values.byName(map['rate_type'] as String),
      rateAmount: (map['rate_amount_cents'] as int) / 100.0,
      gracePeriodMinutes: map['grace_period_minutes'] as int,
      dailyMaxCap: map['daily_max_cap_cents'] != null
          ? (map['daily_max_cap_cents'] as int) / 100.0
          : null,
      isActive: (map['is_active'] as int) != 0,
      isDefault: (map['is_default'] as int) != 0,
    );
  }

  PricingRule copyWith({
    int? id,
    String? name,
    RateType? rateType,
    double? rateAmount,
    int? gracePeriodMinutes,
    Object? dailyMaxCap = _sentinel,
    bool? isActive,
    bool? isDefault,
  }) {
    return PricingRule(
      id: id ?? this.id,
      name: name ?? this.name,
      rateType: rateType ?? this.rateType,
      rateAmount: rateAmount ?? this.rateAmount,
      gracePeriodMinutes: gracePeriodMinutes ?? this.gracePeriodMinutes,
      dailyMaxCap: identical(dailyMaxCap, _sentinel)
          ? this.dailyMaxCap
          : dailyMaxCap as double?,
      isActive: isActive ?? this.isActive,
      isDefault: isDefault ?? this.isDefault,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();
