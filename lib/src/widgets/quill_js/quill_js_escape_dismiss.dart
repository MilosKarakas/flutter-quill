import 'dart:async';

import 'package:flutter/foundation.dart';

/// Durable Escape dismiss for [QuillJsEditorView].
///
/// Marks the blur as user-initiated, blurs the editor, and optionally
/// notifies the host. Never re-requests editor focus. Never calls nextFocus.
void applyQuillJsEscapeDismiss({
  required VoidCallback markExplicitDismiss,
  required VoidCallback blurEditor,
  VoidCallback? onEscapePressed,
}) {
  markExplicitDismiss();
  blurEditor();
  if (onEscapePressed != null) {
    scheduleMicrotask(onEscapePressed);
  }
}
