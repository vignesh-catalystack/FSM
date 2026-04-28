import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_notifier.dart';
import '../../../core/auth/user_role.dart';
import '../../auth/data/auth_api_service.dart';

class LoginState {
  final bool loading;
  final String? error;
  final String? emailError;
  final String? passwordError;

  const LoginState({
    this.loading = false,
    this.error,
    this.emailError,
    this.passwordError,
  });
}

class LoginNotifier extends StateNotifier<LoginState> {
  LoginNotifier(this.ref) : super(const LoginState());

  final Ref ref;

  final _authApi = AuthApiService();

  void clearErrors() {
    if (state.error == null &&
        state.emailError == null &&
        state.passwordError == null) {
      return;
    }
    state = LoginState(loading: state.loading);
  }

  String? _normalizeToken(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.toLowerCase().startsWith('bearer ')) {
      final withoutPrefix = trimmed.substring(7).trim();
      return withoutPrefix.isEmpty ? null : withoutPrefix;
    }

    return trimmed;
  }

  String? _extractToken(Map<String, dynamic> response) {
    const keys = [
      'token',
      'access_token',
      'jwt',
      'debug_token',
      'auth_token',
      'api_token',
      'bearer_token',
      'authorization_header',
      'authorization',
      'Authorization',
    ];

    final mapCandidates = <Map<String, dynamic>>[
      response,
      if (response['data'] is Map<String, dynamic>)
        response['data'] as Map<String, dynamic>,
      if (response['user'] is Map<String, dynamic>)
        response['user'] as Map<String, dynamic>,
      if (response['result'] is Map<String, dynamic>)
        response['result'] as Map<String, dynamic>,
    ];

    for (final map in mapCandidates) {
      for (final key in keys) {
        final normalized = _normalizeToken(map[key]?.toString());
        if (normalized != null) {
          return normalized;
        }
      }
    }

    return null;
  }

  String? _extractRoleString(Map<String, dynamic> response) {
    const keys = [
      'role',
      'user_role',
      'account_type',
      'type',
    ];

    final mapCandidates = <Map<String, dynamic>>[
      response,
      if (response['data'] is Map<String, dynamic>)
        response['data'] as Map<String, dynamic>,
      if (response['user'] is Map<String, dynamic>)
        response['user'] as Map<String, dynamic>,
      if (response['result'] is Map<String, dynamic>)
        response['result'] as Map<String, dynamic>,
    ];

    for (final map in mapCandidates) {
      for (final key in keys) {
        final value = map[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }

    return null;
  }

  UserRole? _parseRole(String rawRole) {
    final normalized =
        rawRole.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
    if (normalized.contains('technician')) return UserRole.technician;
    if (normalized.contains('manager')) return UserRole.manager;
    if (normalized.contains('admin')) return UserRole.admin;
    if (normalized.contains('user') || normalized.contains('customer')) {
      return UserRole.user;
    }
    return null;
  }

  String _cleanError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.isEmpty) return 'Login failed. Please try again.';

    final lower = message.toLowerCase();
    if (lower.contains('request timed out') ||
        lower.contains('unable to reach backend')) {
      return 'We could not connect to the server right now. Check your internet connection and try again.';
    }
    if (lower.contains('api returned html')) {
      return 'The server is responding incorrectly right now. Please try again shortly.';
    }

    return message;
  }

  bool _looksLikeCredentialError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('invalid password') ||
        lower.contains('wrong password') ||
        lower.contains('incorrect password') ||
        lower.contains('invalid credentials') ||
        lower.contains('invalid email or password') ||
        lower.contains('email or password') ||
        lower.contains('user not found') ||
        lower.contains('invalid user') ||
        lower.contains('invalid email') ||
        lower.contains('unauthorized') ||
        lower.contains('login failed');
  }

  Future<void> login(String email, String password) async {
    final trimmedEmail = email.trim();
    final trimmedPassword = password.trim();

    if (trimmedEmail.isEmpty || trimmedPassword.isEmpty) {
      state = LoginState(
        emailError: trimmedEmail.isEmpty ? 'Enter your email' : null,
        passwordError: trimmedPassword.isEmpty ? 'Enter your password' : null,
      );
      return;
    }

    state = const LoginState(loading: true);

    try {
      final response = await _authApi.login(
        email: trimmedEmail,
        password: trimmedPassword,
      );

      final roleString = _extractRoleString(response);
      if (roleString == null) {
        throw Exception('Login succeeded but no user role was returned.');
      }

      final role = _parseRole(roleString);
      if (role == null) {
        throw Exception('Unsupported user role: $roleString');
      }

      final token = _extractToken(response);

      ref.read(authProvider.notifier).login(role, token: token);

      state = const LoginState();
    } catch (e) {
      final message = _cleanError(e);
      final lower = message.toLowerCase();
      final isCredentialError = _looksLikeCredentialError(message);
      state = LoginState(
        error: isCredentialError ? null : message,
        emailError: isCredentialError &&
                (lower.contains('user not found') ||
                    lower.contains('invalid user') ||
                    lower.contains('invalid email'))
            ? 'Email address was not recognized.'
            : null,
        passwordError: isCredentialError &&
                !(lower.contains('user not found') ||
                    lower.contains('invalid user') ||
                    lower.contains('invalid email'))
            ? 'Wrong email or password. Please try again.'
            : null,
      );
    }
  }
}

final loginProvider =
    StateNotifierProvider<LoginNotifier, LoginState>(
  (ref) => LoginNotifier(ref),
);
