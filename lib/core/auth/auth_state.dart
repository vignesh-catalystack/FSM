import 'user_role.dart';

class AuthState {
  final bool isAuthenticated;
  final UserRole? role;
  final String? token;

  const AuthState({
    required this.isAuthenticated,
    this.role,
    this.token,
  });

  const AuthState.unauthenticated()
      : isAuthenticated = false,
        role = null,
        token = null;

  const AuthState.authenticated(
    UserRole role, {
    String? token,
  })
      : isAuthenticated = true,
        role = role,
        token = token;
}
