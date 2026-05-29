import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/result.dart';
import '../../core/router.dart';
import '../../models/user.dart';
import 'auth_provider.dart';

// ---------------------------------------------------------------------------
// LoginScreen
// ---------------------------------------------------------------------------

/// Login screen — entry point for all users.
///
/// Presents username and password fields, a login button, and a link to the
/// registration screen. On successful authentication the user is navigated to
/// the appropriate home screen based on their role:
///   - [Role.owner]     → [AppRoutes.dashboard]
///   - [Role.attendant] → [AppRoutes.vehicleEntry]
///
/// On failure an inline snackbar is shown with a generic error message so
/// that no field-level information is disclosed (Requirement 2.2).
///
/// Requirements: 2.1, 2.2, 2.5
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: _LoginForm(),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _LoginForm — internal stateful form widget
// ---------------------------------------------------------------------------

/// Stateful form that owns the text controllers and loading state.
///
/// Using [StatefulWidget] here is appropriate because the form has local
/// mutable state (controllers, loading flag) that does not need to be shared
/// outside this widget.
class _LoginForm extends ConsumerStatefulWidget {
  @override
  ConsumerState<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends ConsumerState<_LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isLoading = true);

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    final result = await ref
        .read(authProvider.notifier)
        .login(username, password);

    if (!mounted) return;

    setState(() => _isLoading = false);

    switch (result) {
      case Success<void>():
        // Navigate based on role — read the updated auth state.
        final authState = ref.read(authProvider);
        if (authState is Authenticated) {
          final destination = authState.role == Role.owner
              ? AppRoutes.dashboard
              : AppRoutes.vehicleEntry;
          context.go(destination);
        }

      case Failure<void>(:final error):
        _showErrorSnackbar(context, error);
    }
  }

  // ---------------------------------------------------------------------------
  // _showErrorSnackbar
  // ---------------------------------------------------------------------------

  void _showErrorSnackbar(BuildContext context, AppError error) {
    // Generic message — never disclose which field was incorrect (Req 2.2).
    final message = switch (error) {
      SessionError(:final message) => message,
      _ => 'Invalid username or password. Please try again.',
    };

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── App title / logo area ──────────────────────────────────────────
          const SizedBox(height: 48),
          Icon(
            Icons.local_parking_rounded,
            size: 72,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Parking System',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in to continue',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 40),

          // ── Username field ─────────────────────────────────────────────────
          TextFormField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Username is required';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // ── Password field ─────────────────────────────────────────────────
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility
                      : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              ),
            ),
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _isLoading ? null : _submit(),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Password is required';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // ── Login button ───────────────────────────────────────────────────
          FilledButton(
            onPressed: _isLoading ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Sign In'),
          ),
          const SizedBox(height: 16),

          // ── Register link ──────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Don't have an account? ",
                style: theme.textTheme.bodyMedium,
              ),
              TextButton(
                onPressed: () => context.push(AppRoutes.register),
                child: const Text('Register'),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
