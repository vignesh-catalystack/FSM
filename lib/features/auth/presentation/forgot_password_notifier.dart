import 'package:flutter_riverpod/flutter_riverpod.dart';
import './../data/auth_api_service.dart';

class ForgotPasswordState {
  final bool loading;
  final String? message;
  final String? error;

  const ForgotPasswordState({
    this.loading = false,
    this.message,
    this.error,
  });
}

class ForgotPasswordNotifier extends StateNotifier<ForgotPasswordState> {
  ForgotPasswordNotifier() : super(const ForgotPasswordState());

  final _authApi = AuthApiService();

  Future<String?> sendReset(String email) async {
    // ✅ Validate before calling API
    if (email.isEmpty) {
      state = const ForgotPasswordState(error: "Email is required");
      return null;
    }
    if (!email.contains('@')) {
      state = const ForgotPasswordState(error: "Enter a valid email");
      return null;
    }

    state = const ForgotPasswordState(loading: true);

    try {
      final token = await _authApi.forgotPassword(email);
      state = const ForgotPasswordState(message: "Reset link generated");
      return token;
    } catch (e) {
      // ✅ Show REAL error not generic message
      state = ForgotPasswordState(
        error: e.toString().replaceAll('Exception: ', ''),
      );
      return null;
    }
  }
}

final forgotPasswordProvider =
    StateNotifierProvider<ForgotPasswordNotifier, ForgotPasswordState>(
  (ref) => ForgotPasswordNotifier(),
);