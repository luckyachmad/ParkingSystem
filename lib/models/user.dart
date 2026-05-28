enum Role { owner, attendant }

class User {
  final int? id;
  final String username;
  final String passwordHash;
  final Role role;
  final bool isLocked;
  final int failedAttempts;
  final DateTime createdAt;

  const User({
    this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    required this.isLocked,
    required this.failedAttempts,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'username': username,
      'password_hash': passwordHash,
      'role': role.name,
      'is_locked': isLocked ? 1 : 0,
      'failed_attempts': failedAttempts,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] as int?,
      username: map['username'] as String,
      passwordHash: map['password_hash'] as String,
      role: Role.values.byName(map['role'] as String),
      isLocked: (map['is_locked'] as int) != 0,
      failedAttempts: map['failed_attempts'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ),
    );
  }

  User copyWith({
    int? id,
    String? username,
    String? passwordHash,
    Role? role,
    bool? isLocked,
    int? failedAttempts,
    DateTime? createdAt,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      passwordHash: passwordHash ?? this.passwordHash,
      role: role ?? this.role,
      isLocked: isLocked ?? this.isLocked,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
