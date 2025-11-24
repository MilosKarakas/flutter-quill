import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

const _kLogTag = '[WebClipboard]';

/// Callbacks for clipboard operations
String Function()? _getSelectedText;
void Function()? _onCopy;
void Function()? _onCut;
void Function(String text)? _onPaste;
bool Function()? _hasFocus;

/// Event listener references for cleanup
web.EventListener? _copyListener;
web.EventListener? _cutListener;
web.EventListener? _pasteListener;

/// Sets up clipboard event listeners on the document.
/// This intercepts browser copy/cut/paste events and handles them through Flutter.
void setupWebClipboardListeners({
  required String Function() getSelectedText,
  required void Function() onCopy,
  required void Function() onCut,
  required void Function(String text) onPaste,
  required bool Function() hasFocus,
}) {
  _getSelectedText = getSelectedText;
  _onCopy = onCopy;
  _onCut = onCut;
  _onPaste = onPaste;
  _hasFocus = hasFocus;

  // Create event listeners
  _copyListener = _handleCopy.toJS;
  _cutListener = _handleCut.toJS;
  _pasteListener = _handlePaste.toJS;

  // Add listeners to document
  web.document.addEventListener('copy', _copyListener);
  web.document.addEventListener('cut', _cutListener);
  web.document.addEventListener('paste', _pasteListener);
}

/// Removes clipboard event listeners from the document.
void removeWebClipboardListeners() {
  if (_copyListener != null) {
    web.document.removeEventListener('copy', _copyListener);
  }
  if (_cutListener != null) {
    web.document.removeEventListener('cut', _cutListener);
  }
  if (_pasteListener != null) {
    web.document.removeEventListener('paste', _pasteListener);
  }

  _copyListener = null;
  _cutListener = null;
  _pasteListener = null;
  _getSelectedText = null;
  _onCopy = null;
  _onCut = null;
  _onPaste = null;
  _hasFocus = null;
}

/// Handles browser copy event
void _handleCopy(web.Event event) {
  debugPrint('$_kLogTag _handleCopy triggered');

  // Only handle if our editor has focus
  final hasFocus = _hasFocus?.call() ?? false;
  debugPrint('$_kLogTag hasFocus=$hasFocus');

  if (!hasFocus) {
    debugPrint('$_kLogTag Ignoring copy - editor does not have focus');
    return;
  }
  if (_getSelectedText == null || _onCopy == null) {
    debugPrint('$_kLogTag Ignoring copy - callbacks not set');
    return;
  }

  final clipboardEvent = event as web.ClipboardEvent;
  final selectedText = _getSelectedText!();
  debugPrint('$_kLogTag Selected text length: ${selectedText.length}');

  if (selectedText.isNotEmpty) {
    // Prevent default browser copy and use our text
    clipboardEvent.preventDefault();
    clipboardEvent.clipboardData?.setData('text/plain', selectedText);
    debugPrint('$_kLogTag Copy: Set clipboard data, calling onCopy callback');
    _onCopy!();
  } else {
    debugPrint('$_kLogTag Copy: No text selected, skipping');
  }
}

/// Handles browser cut event
void _handleCut(web.Event event) {
  debugPrint('$_kLogTag _handleCut triggered');

  final hasFocus = _hasFocus?.call() ?? false;
  debugPrint('$_kLogTag hasFocus=$hasFocus');

  if (!hasFocus) {
    debugPrint('$_kLogTag Ignoring cut - editor does not have focus');
    return;
  }
  if (_getSelectedText == null || _onCut == null) {
    debugPrint('$_kLogTag Ignoring cut - callbacks not set');
    return;
  }

  final clipboardEvent = event as web.ClipboardEvent;
  final selectedText = _getSelectedText!();
  debugPrint('$_kLogTag Selected text length: ${selectedText.length}');

  if (selectedText.isNotEmpty) {
    clipboardEvent.preventDefault();
    clipboardEvent.clipboardData?.setData('text/plain', selectedText);
    debugPrint('$_kLogTag Cut: Set clipboard data, calling onCut callback');
    _onCut!();
  } else {
    debugPrint('$_kLogTag Cut: No text selected, skipping');
  }
}

/// Handles browser paste event
void _handlePaste(web.Event event) {
  debugPrint('$_kLogTag _handlePaste triggered');

  final hasFocus = _hasFocus?.call() ?? false;
  debugPrint('$_kLogTag hasFocus=$hasFocus');

  if (!hasFocus) {
    debugPrint('$_kLogTag Ignoring paste - editor does not have focus');
    return;
  }
  if (_onPaste == null) {
    debugPrint('$_kLogTag Ignoring paste - callback not set');
    return;
  }

  final clipboardEvent = event as web.ClipboardEvent;
  final text = clipboardEvent.clipboardData?.getData('text/plain');
  debugPrint('$_kLogTag Paste text length: ${text?.length ?? 0}');

  if (text != null && text.isNotEmpty) {
    clipboardEvent.preventDefault();
    debugPrint('$_kLogTag Paste: Calling onPaste callback with text');
    _onPaste!(text);
  } else {
    debugPrint('$_kLogTag Paste: No text in clipboard, skipping');
  }
}
