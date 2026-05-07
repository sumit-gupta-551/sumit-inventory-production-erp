import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a passcode dialog. Returns true only if user enters [expected].
/// Default passcode is 0056.
Future<bool> requirePasscode(
  BuildContext context, {
  String expected = '0056',
  String title = 'Enter Passcode',
  String action = 'Unlock',
}) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          labelText: 'Passcode',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action)),
      ],
    ),
  );
  if (ok != true) return false;
  final entered = ctrl.text.trim();
  if (entered == expected) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wrong passcode.')));
  }
  return false;
}
