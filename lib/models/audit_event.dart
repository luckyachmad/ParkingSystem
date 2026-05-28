enum AuditEventType {
  login,
  logout,
  loginFailed,
  userCreated,
  ticketCreated,
  ticketClosed,
}

class AuditEvent {
  final int? id;
  final AuditEventType eventType;
  final String username;
  final DateTime timestamp; // UTC
  final String? details;

  const AuditEvent({
    this.id,
    required this.eventType,
    required this.username,
    required this.timestamp,
    this.details,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'event_type': eventType.name,
      'username': username,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'details': details,
    };
  }

  factory AuditEvent.fromMap(Map<String, dynamic> map) {
    return AuditEvent(
      id: map['id'] as int?,
      eventType: AuditEventType.values.byName(map['event_type'] as String),
      username: map['username'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestamp'] as int,
        isUtc: true,
      ),
      details: map['details'] as String?,
    );
  }

  AuditEvent copyWith({
    int? id,
    AuditEventType? eventType,
    String? username,
    DateTime? timestamp,
    Object? details = _sentinel,
  }) {
    return AuditEvent(
      id: id ?? this.id,
      eventType: eventType ?? this.eventType,
      username: username ?? this.username,
      timestamp: timestamp ?? this.timestamp,
      details:
          identical(details, _sentinel) ? this.details : details as String?,
    );
  }
}

// Sentinel object used to distinguish "not provided" from explicit null in copyWith.
const Object _sentinel = Object();
