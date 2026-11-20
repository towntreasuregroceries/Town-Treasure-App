import 'package:flutter/material.dart';

/// Allocates [TextEditingController] instances for the lifetime of a dialog or
/// bottom sheet and disposes them only after its exit transition completes.
class ScopedTextControllers extends StatefulWidget {
  const ScopedTextControllers({
    super.key,
    required this.initialTexts,
    required this.builder,
  });

  final List<String> initialTexts;
  final Widget Function(
    BuildContext context,
    List<TextEditingController> controllers,
  ) builder;

  @override
  State<ScopedTextControllers> createState() => _ScopedTextControllersState();
}

class _ScopedTextControllersState extends State<ScopedTextControllers> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = widget.initialTexts
        .map((t) => TextEditingController(text: t))
        .toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _controllers);
  }
}
