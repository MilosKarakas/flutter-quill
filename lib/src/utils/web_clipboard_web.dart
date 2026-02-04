// Web implementation using package:web
// This file is used when dart.library.js_interop is available

import 'dart:js_interop';

import 'package:web/web.dart' as web;

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

/// Web implementation that listens to browser paste events
class WebClipboardListener {
  WebClipboardListener(this._onPaste);

  final WebPasteCallback _onPaste;
  web.EventListener? _listener;

  /// Start listening to paste events on the document
  void startListening() {
    stopListening();
    _listener = _handlePaste.toJS;
    web.document.addEventListener('paste', _listener);
  }

  /// Stop listening to paste events
  void stopListening() {
    if (_listener != null) {
      web.document.removeEventListener('paste', _listener);
      _listener = null;
    }
  }

  /// Dispose resources
  void dispose() {
    stopListening();
  }

  void _handlePaste(web.Event event) {
    final clipboardEvent = event as web.ClipboardEvent;
    final clipboardData = clipboardEvent.clipboardData;
    if (clipboardData == null) return;

    // Extract plain text and HTML from clipboard
    final plainText = clipboardData.getData('text/plain');
    final htmlContent = clipboardData.getData('text/html');

    // Create event data with timestamp
    final data = WebPasteEventData(
      plainText: plainText.isNotEmpty ? plainText : null,
      html: htmlContent.isNotEmpty ? htmlContent : null,
      timestamp: DateTime.now(),
    );

    _onPaste(data);
  }
}
