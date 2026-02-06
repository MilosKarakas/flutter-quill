// Stub implementation for non-web platforms
// This file is used when dart:html is not available

import '../models/structs/copy_data.dart';

/// Stub implementation for native selection suppression on non-web platforms.
class WebNativeSelectionSuppressor {
  // ignore: avoid_unused_constructor_parameters
  WebNativeSelectionSuppressor({required bool Function() shouldSuppress});

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

/// Callback type for copy/cut event handling.
typedef WebCopyCallback = CopyClipboardData? Function();

/// Stub implementation that does nothing on non-web platforms.
/// On web, this listens to both copy and cut events.
class WebClipboardCopyListener {
  // ignore: avoid_unused_constructor_parameters
  WebClipboardCopyListener(WebCopyCallback onCopy);

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
