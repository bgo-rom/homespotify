/// Utilisateur authentifié tel que renvoyé par l'API (jamais de champ sensible).
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.isActive,
    required this.mustChangePassword,
    this.lastLoginAt,
    this.createdAt,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as int,
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      role: json['role'] as String,
      isActive: json['isActive'] as bool? ?? true,
      mustChangePassword: json['mustChangePassword'] as bool? ?? false,
      lastLoginAt: json['lastLoginAt'] as String?,
      createdAt: json['createdAt'] as String?,
    );
  }

  final int id;
  final String username;
  final String displayName;
  final String role;
  final bool isActive;
  final bool mustChangePassword;
  final String? lastLoginAt;
  final String? createdAt;

  bool get isOwner => role == 'OWNER';
}
