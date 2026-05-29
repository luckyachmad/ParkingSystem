import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/result.dart';
import '../../core/router.dart';
import '../../models/user.dart';
import 'auth_provider.dart';

// ---------------------------------------------------------------------------
// RegistrationScreen
// ---------------------------------------------------------------------------

/// Registration screen — allows a parking owner to create a new user account.
///
/// Presents username, password, and role fields. On successful registration
/// the user is navigated to [AppRoutes.login] with a success snackbar.
///
/// Requirements: 1.1, 1.2, 1.3, 1.4, 1.5
class RegistrationScreen extends ConsumerWidget {
  const RegistrationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Registration'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: _RegistrationForm(),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _RegistrationForm — internal stateful form widget
// ---------------------------------------------------------------------------

/// Stateful form that owns the text controllers, loading state, selected role,
/// and any inline validation error messages.
class _RegistrationForm extends ConsumerStatefulWidget {
  @override
  ConsumerState<_RegistrationForm> createState() => _RegistrationFormState();
}

class _RegistrationFormState extends ConsumerState<_RegistrationForm> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;
  Role? _selectedRole;

  /// Inline error message shown below the relevant field on [ValidationError].
  String? _inlineError;

  /// Which field the inline error belongs to ('username' or 'password').
  String? _inlineErrorField;

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
    // Clear any previous inline error before re-validating.
    setState(() {
      _inlineError = null;
      _inlineErrorField = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isLoading = true);

    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final role = _selectedRole!;

    final result = await ref
        .read(authProvider.notifier)
        .register(username, password, role);

    if (!mounted) return;

    setState(() => _isLoading = false);

    switch (result) {
      case Success<void>():
        // Navigate to login and show success snackbar.
        context.go(AppRoutes.login);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Account created successfully. Please sign in.'),
              behavior: SnackBarBehavior.floating,
            ),
          );

      case Failure<void>(:final error):
        _handleError(error);
    }
  }

  // ---------------------------------------------------------------------------
  // _handleError
  // ---------------------------------------------------------------------------

  void _handleError(AppError error) {
    switch (error) {
      case ValidationError(:final field, :final message):
        // Display inline error below the relevant field.
        setState(() {
          _inlineError = message;
          _inlineErrorField = field;
        });

      case BusinessError(:final message):
        _showSnackbar(message);

      default:
        _showSnackbar('An unexpected error occurred. Please try again.');
    }
  }

  // ---------------------------------------------------------------------------
  // _showSnackbar
  // ---------------------------------------------------------------------------

  void _showSnackbar(String message) {
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
          // ── Header ────────────────────────────────────────────────────────
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
            'Create a new account',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 40),

          // ── Username field ─────────────────────────────────────────────────
          TextFormField(
            controller: _usernameController,
            decoration: InputDecoration(
              labelText: 'Username',
              prefixIcon: const Icon(Icons.person_outline),
              border: const OutlineInputBorder(),
              // Show inline error for username field if present.
              errorText: _inlineErrorField == 'username' ? _inlineError : null,
            ),
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) {
              // Clear inline error when the user starts editing.
              if (_inlineErrorField == 'username' && _inlineError != null) {
                setState(() {
                  _inlineError = null;
                  _inlineErrorField = null;
                });
              }
            },
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
              // Show inline error for password field if present.
              errorText: _inlineErrorField == 'password' ? _inlineError : null,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              ),
            ),
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.next,
            onChanged: (_) {
              // Clear inline error when the user starts editing.
              if (_inlineErrorField == 'password' && _inlineError != null) {
                setState(() {
                  _inlineError = null;
                  _inlineErrorField = null;
                });
              }
            },
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Password is required';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          // ── Role dropdown ──────────────────────────────────────────────────
          DropdownButtonFormField<Role>(
            initialValue: _selectedRole,
            decoration: const InputDecoration(
              labelText: 'Role',
              prefixIcon: Icon(Icons.badge_outlined),
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: Role.owner,
                child: Text('Owner'),
              ),
              DropdownMenuItem(
                value: Role.attendant,
                child: Text('Attendant'),
              ),
            ],
            onChanged: (role) => setState(() => _selectedRole = role),
            validator: (value) {
              if (value == null) {
                return 'Role is required';
              }
              return null;
            },
          ),
          const SizedBox(height: 24),

          // ── Register button ────────────────────────────────────────────────
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
                : const Text('Create Account'),
          ),
          const SizedBox(height: 16),

          // ── Back to login link ─────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Already have an account? ',
                style: theme.textTheme.bodyMedium,
              ),
              TextButton(
                onPressed: () => context.go(AppRoutes.login),
                child: const Text('Sign In'),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
