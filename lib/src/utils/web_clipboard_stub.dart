// Stub implementation for non-web platforms
// This file is used when dart:html is not available

/// Data captured from a web paste event
class WebPasteEventData {
  const WebPasteEventData({
    required this.timestamp,
    this.plainText,
    this.html,
  });

  final String? plainText;
  final String? html;
  final DateTime timestamp;
}

/// Callback type for paste event handling
typedef WebPasteCallback = void Function(WebPasteEventData data);

/// Stub implementation that does nothing on non-web platforms
class WebClipboardListener {
  // ignore: avoid_unused_constructor_parameters
  WebClipboardListener(WebPasteCallback onPaste);

  /// Start listening - no-op on non-web platforms
  void startListening() {
    // No-op on non-web platforms
  }

  /// Stop listening - no-op on non-web platforms
  void stopListening() {
    // No-op on non-web platforms
  }

  /// Dispose resources - no-op on non-web platforms
  void dispose() {
    // No-op on non-web platforms
  }
}
