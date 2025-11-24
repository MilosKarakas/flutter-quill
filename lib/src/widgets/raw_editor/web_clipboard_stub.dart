/// Stub implementation for non-web platforms.
/// These functions do nothing on native platforms.

/// Sets up clipboard event listeners (no-op on non-web platforms)
void setupWebClipboardListeners({
  required String Function() getSelectedText,
  required void Function() onCopy,
  required void Function() onCut,
  required void Function(String text) onPaste,
  required bool Function() hasFocus,
}) {
  // No-op on non-web platforms
}

/// Removes clipboard event listeners (no-op on non-web platforms)
void removeWebClipboardListeners() {
  // No-op on non-web platforms
}
