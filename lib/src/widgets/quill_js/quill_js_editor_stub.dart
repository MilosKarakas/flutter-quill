// Stub implementation for non-web platforms.
// The Quill.js editor is only available on Flutter web.

import 'package:flutter/material.dart';

import 'quill_js_configurations.dart';

/// Stub implementation of [QuillJsEditorView] for non-web platforms.
///
/// Displays a message indicating that the Quill.js editor is only available
/// on the web. On non-web platforms, use the standard [QuillEditor] instead.
class QuillJsEditorView extends StatelessWidget {
  final QuillJsEditorConfiguration configuration;
  final QuillJsEditorController controller;
  final FocusNode? focusNode;

  const QuillJsEditorView({
    super.key,
    required this.configuration,
    required this.controller,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'QuillJsEditorView is only available on Flutter web.\n'
          'Use QuillEditor for non-web platforms.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}
