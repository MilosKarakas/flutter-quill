// Web implementation using package:web
// This file is used when dart.library.js_interop is available

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/structs/copy_data.dart';

/// Suppresses native text selection and context menu on web.
///
/// Intended for mobile web to prevent the browser's native selection UI
/// from interfering with the editor's custom selection controls.
class WebNativeSelectionSuppressor {
  WebNativeSelectionSuppressor({required bool Function() shouldSuppress})
      : _shouldSuppress = shouldSuppress;

  final bool Function() _shouldSuppress;
  web.EventListener? _contextMenuListener;
  web.EventListener? _selectStartListener;

  /// Start listening to selection-related events on the document.
  void startListening() {
    stopListening();
    _contextMenuListener = _handleEvent.toJS;
    _selectStartListener = _handleEvent.toJS;
    web.document.addEventListener('contextmenu', _contextMenuListener);
    web.document.addEventListener('selectstart', _selectStartListener);
  }

  /// Stop listening to selection-related events.
  void stopListening() {
    if (_contextMenuListener != null) {
      web.document.removeEventListener('contextmenu', _contextMenuListener);
      _contextMenuListener = null;
    }
    if (_selectStartListener != null) {
      web.document.removeEventListener('selectstart', _selectStartListener);
      _selectStartListener = null;
    }
  }

  /// Dispose resources.
  void dispose() {
    stopListening();
  }

  void _handleEvent(web.Event event) {
    if (!_shouldSuppress()) {
      return;
    }
    if (!_isFlutterTextEditingElement(web.document.activeElement)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
  }

  bool _isFlutterTextEditingElement(web.Element? element) {
    if (element == null) return false;
    if (element is! web.HTMLElement) return false;

    if (element.getAttribute('data-flt-text-editing') != null) {
      return true;
    }

    // Fallback for older Flutter web builds.
    if (element.classList.contains('flt-text-editing')) {
      return true;
    }

    return false;
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

/// Callback type for copy/cut event handling.
/// Called when a copy or cut event occurs, should return the data to write
/// to clipboard. If null is returned, the event proceeds with default
/// browser behavior.
typedef WebCopyCallback = CopyClipboardData? Function();

/// Web implementation that intercepts browser copy and cut events
/// to write rich content.
class WebClipboardCopyListener {
  WebClipboardCopyListener(this._onCopy);

  final WebCopyCallback _onCopy;
  web.EventListener? _copyListener;
  web.EventListener? _cutListener;

  /// Start listening to copy and cut events on the document
  void startListening() {
    stopListening();
    _copyListener = _handleCopyOrCut.toJS;
    _cutListener = _handleCopyOrCut.toJS;
    web.document.addEventListener('copy', _copyListener);
    web.document.addEventListener('cut', _cutListener);
  }

  /// Stop listening to copy and cut events
  void stopListening() {
    if (_copyListener != null) {
      web.document.removeEventListener('copy', _copyListener);
      _copyListener = null;
    }
    if (_cutListener != null) {
      web.document.removeEventListener('cut', _cutListener);
      _cutListener = null;
    }
  }

  /// Dispose resources
  void dispose() {
    stopListening();
  }

  void _handleCopyOrCut(web.Event event) {
    final data = _onCopy();
    if (data == null) return;

    final clipboardEvent = event as web.ClipboardEvent;
    final clipboardData = clipboardEvent.clipboardData;
    if (clipboardData == null) return;

    // Prevent default to take control of clipboard content
    event.preventDefault();

    // Set both plain text and HTML on the clipboard
    clipboardData.setData('text/plain', data.plainText);
    if (data.html != null) {
      clipboardData.setData('text/html', data.html!);
    }
  }
}
