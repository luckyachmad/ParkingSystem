import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/result.dart';
import '../../models/pricing_rule.dart';
import '../auth/auth_provider.dart';
import 'pricing_provider.dart';

// ---------------------------------------------------------------------------
// PricingScreen
// ---------------------------------------------------------------------------

/// Pricing Management screen — lists active pricing rules and allows the
/// owner to add, edit, deactivate, and set a default rule.
///
/// Requirements: 6.1, 6.2, 6.3, 6.5, 6.6, 6.7
class PricingScreen extends ConsumerStatefulWidget {
  const PricingScreen({super.key});

  @override
  ConsumerState<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends ConsumerState<PricingScreen> {
  // Tracks the last error shown as a snackbar so we don't re-show it.
  AppError? _lastSnackbarError;

  @override
  void initState() {
    super.initState();
    // Load rules after the first frame so the widget tree is fully built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pricingProvider.notifier).loadRules();
    });
  }

  // ---------------------------------------------------------------------------
  // _logout
  // ---------------------------------------------------------------------------

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
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
  // _openAddForm
  // ---------------------------------------------------------------------------

  void _openAddForm() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PricingRuleForm(
        rule: null,
        onSubmit: (rule) async {
          await ref.read(pricingProvider.notifier).addRule(rule);
          // Check for error after the operation.
          final error = ref.read(pricingProvider).error;
          if (error != null && mounted) {
            _showSnackbar(_errorMessage(error));
          }
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // _openEditForm
  // ---------------------------------------------------------------------------

  void _openEditForm(PricingRule rule) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PricingRuleForm(
        rule: rule,
        onSubmit: (updated) async {
          await ref.read(pricingProvider.notifier).updateRule(updated);
          final error = ref.read(pricingProvider).error;
          if (error != null && mounted) {
            _showSnackbar(_errorMessage(error));
          }
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // _confirmDeactivate
  // ---------------------------------------------------------------------------

  Future<void> _confirmDeactivate(PricingRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deactivate Rule'),
        content: Text(
          'Are you sure you want to deactivate "${rule.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );

    if (confirmed == true && rule.id != null) {
      await ref.read(pricingProvider.notifier).deactivateRule(rule.id!);
    }
  }

  // ---------------------------------------------------------------------------
  // _setDefault
  // ---------------------------------------------------------------------------

  Future<void> _setDefault(PricingRule rule) async {
    if (rule.id != null) {
      await ref.read(pricingProvider.notifier).setDefault(rule.id!);
    }
  }

  // ---------------------------------------------------------------------------
  // _errorMessage
  // ---------------------------------------------------------------------------

  String _errorMessage(AppError error) {
    return switch (error) {
      ValidationError(:final message) => message,
      BusinessError(:final message) => message,
      DatabaseError(:final message) => 'Database error: $message',
      SessionError(:final message) => message,
    };
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pricingState = ref.watch(pricingProvider);

    // Show errors as snackbars (only once per error instance).
    final error = pricingState.error;
    if (error != null && !identical(error, _lastSnackbarError)) {
      _lastSnackbarError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showSnackbar(_errorMessage(error));
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pricing Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: _buildBody(pricingState),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddForm,
        tooltip: 'Add pricing rule',
        child: const Icon(Icons.add),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // _buildBody
  // ---------------------------------------------------------------------------

  Widget _buildBody(PricingState state) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.rules.isEmpty) {
      return const Center(
        child: Text(
          'No pricing rules found',
          style: TextStyle(fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      itemCount: state.rules.length,
      itemBuilder: (context, index) {
        final rule = state.rules[index];
        return _PricingRuleCard(
          rule: rule,
          onEdit: () => _openEditForm(rule),
          onDeactivate: () => _confirmDeactivate(rule),
          onSetDefault: () => _setDefault(rule),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _PricingRuleCard
// ---------------------------------------------------------------------------

/// A card displaying a single pricing rule with a popup menu for actions.
class _PricingRuleCard extends StatelessWidget {
  final PricingRule rule;
  final VoidCallback onEdit;
  final VoidCallback onDeactivate;
  final VoidCallback onSetDefault;

  const _PricingRuleCard({
    required this.rule,
    required this.onEdit,
    required this.onDeactivate,
    required this.onSetDefault,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rateLabel = rule.rateType == RateType.hourly ? 'Hourly' : 'Flat';
    // rateAmount is stored as dollars (double); convert to cents for Money.
    final rateCents = (rule.rateAmount * 100).round();
    final rateDisplay = Money(rateCents).toDisplay();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Rule details ───────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + Default chip
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          rule.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (rule.isDefault) ...[
                        const SizedBox(width: 8),
                        Chip(
                          label: const Text('Default'),
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onPrimary,
                          ),
                          backgroundColor: theme.colorScheme.primary,
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Rate type + amount
                  Text(
                    '$rateLabel · $rateDisplay',
                    style: theme.textTheme.bodyMedium,
                  ),

                  // Grace period (if set)
                  if (rule.gracePeriodMinutes > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Grace: ${rule.gracePeriodMinutes}m',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],

                  // Daily cap (if set)
                  if (rule.dailyMaxCap != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Cap: ${Money((rule.dailyMaxCap! * 100).round()).toDisplay()}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Popup menu ─────────────────────────────────────────────────
            PopupMenuButton<_RuleAction>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Options',
              onSelected: (action) {
                switch (action) {
                  case _RuleAction.edit:
                    onEdit();
                  case _RuleAction.setDefault:
                    onSetDefault();
                  case _RuleAction.deactivate:
                    onDeactivate();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _RuleAction.edit,
                  child: Text('Edit'),
                ),
                if (!rule.isDefault)
                  const PopupMenuItem(
                    value: _RuleAction.setDefault,
                    child: Text('Set as Default'),
                  ),
                const PopupMenuItem(
                  value: _RuleAction.deactivate,
                  child: Text('Deactivate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Actions available in the rule popup menu.
enum _RuleAction { edit, setDefault, deactivate }

// ---------------------------------------------------------------------------
// _PricingRuleForm
// ---------------------------------------------------------------------------

/// Modal bottom sheet form for adding or editing a pricing rule.
///
/// Pass [rule] = null for add mode; pass an existing [PricingRule] for edit
/// mode. [onSubmit] is called with the constructed rule on valid submission.
class _PricingRuleForm extends StatefulWidget {
  final PricingRule? rule;
  final Future<void> Function(PricingRule rule) onSubmit;

  const _PricingRuleForm({
    required this.rule,
    required this.onSubmit,
  });

  @override
  State<_PricingRuleForm> createState() => _PricingRuleFormState();
}

class _PricingRuleFormState extends State<_PricingRuleForm> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _rateController;
  late final TextEditingController _graceController;
  late final TextEditingController _capController;

  late RateType _selectedRateType;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    // Display rate as dollars (2 decimal places).
    _rateController = TextEditingController(
      text: rule != null ? rule.rateAmount.toStringAsFixed(2) : '',
    );
    _graceController = TextEditingController(
      text: rule != null && rule.gracePeriodMinutes > 0
          ? rule.gracePeriodMinutes.toString()
          : '',
    );
    _capController = TextEditingController(
      text: rule?.dailyMaxCap != null
          ? rule!.dailyMaxCap!.toStringAsFixed(2)
          : '',
    );
    _selectedRateType = rule?.rateType ?? RateType.hourly;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rateController.dispose();
    _graceController.dispose();
    _capController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _submit
  // ---------------------------------------------------------------------------

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSubmitting = true);

    // Parse rate amount (dollars → stored as double dollars in model).
    final rateAmount = double.parse(_rateController.text.trim());

    // Parse optional grace period.
    final graceText = _graceController.text.trim();
    final gracePeriodMinutes =
        graceText.isNotEmpty ? int.parse(graceText) : 0;

    // Parse optional daily cap (dollars → stored as double dollars in model).
    final capText = _capController.text.trim();
    final dailyMaxCap =
        capText.isNotEmpty ? double.parse(capText) : null;

    final existing = widget.rule;
    final rule = PricingRule(
      id: existing?.id,
      name: _nameController.text.trim(),
      rateType: _selectedRateType,
      rateAmount: rateAmount,
      gracePeriodMinutes: gracePeriodMinutes,
      dailyMaxCap: dailyMaxCap,
      isActive: existing?.isActive ?? true,
      isDefault: existing?.isDefault ?? false,
    );

    await widget.onSubmit(rule);

    if (mounted) {
      setState(() => _isSubmitting = false);
      Navigator.of(context).pop();
    }
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.rule != null;
    final theme = Theme.of(context);

    return Padding(
      // Shift form up when keyboard is visible.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Title ──────────────────────────────────────────────────
              Text(
                isEdit ? 'Edit Pricing Rule' : 'Add Pricing Rule',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),

              // ── Name ───────────────────────────────────────────────────
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Rule Name',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Rule name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Rate type ──────────────────────────────────────────────
              DropdownButtonFormField<RateType>(
                initialValue: _selectedRateType,
                decoration: const InputDecoration(
                  labelText: 'Rate Type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: RateType.hourly,
                    child: Text('Hourly'),
                  ),
                  DropdownMenuItem(
                    value: RateType.flat,
                    child: Text('Flat'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedRateType = value);
                  }
                },
              ),
              const SizedBox(height: 16),

              // ── Rate amount ────────────────────────────────────────────
              TextFormField(
                controller: _rateController,
                decoration: const InputDecoration(
                  labelText: 'Rate Amount (\$)',
                  border: OutlineInputBorder(),
                  prefixText: '\$ ',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Rate amount is required';
                  }
                  final parsed = double.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid positive amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Grace period (optional) ────────────────────────────────
              TextFormField(
                controller: _graceController,
                decoration: const InputDecoration(
                  labelText: 'Grace Period (minutes, optional)',
                  border: OutlineInputBorder(),
                  suffixText: 'min',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final parsed = int.tryParse(value.trim());
                  if (parsed == null || parsed < 0) {
                    return 'Enter a valid number of minutes';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── Daily cap (optional) ───────────────────────────────────
              TextFormField(
                controller: _capController,
                decoration: const InputDecoration(
                  labelText: 'Daily Cap (\$, optional)',
                  border: OutlineInputBorder(),
                  prefixText: '\$ ',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                ],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) =>
                    _isSubmitting ? null : _submit(),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  final parsed = double.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid positive amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // ── Submit button ──────────────────────────────────────────
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(isEdit ? 'Save Changes' : 'Add Rule'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
