import 'dart:js_interop';
import 'package:web/web.dart' as web;

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
  // Only handle if our editor has focus
  if (_hasFocus == null || !_hasFocus!()) return;
  if (_getSelectedText == null || _onCopy == null) return;

  final clipboardEvent = event as web.ClipboardEvent;
  final selectedText = _getSelectedText!();

  if (selectedText.isNotEmpty) {
    // Prevent default browser copy and use our text
    clipboardEvent.preventDefault();
    clipboardEvent.clipboardData?.setData('text/plain', selectedText);
    _onCopy!();
  }
}

/// Handles browser cut event
void _handleCut(web.Event event) {
  // Only handle if our editor has focus
  if (_hasFocus == null || !_hasFocus!()) return;
  if (_getSelectedText == null || _onCut == null) return;

  final clipboardEvent = event as web.ClipboardEvent;
  final selectedText = _getSelectedText!();

  if (selectedText.isNotEmpty) {
    // Prevent default browser cut and use our text
    clipboardEvent.preventDefault();
    clipboardEvent.clipboardData?.setData('text/plain', selectedText);
    _onCut!();
  }
}

/// Handles browser paste event
void _handlePaste(web.Event event) {
  // Only handle if our editor has focus
  if (_hasFocus == null || !_hasFocus!()) return;
  if (_onPaste == null) return;

  final clipboardEvent = event as web.ClipboardEvent;
  final text = clipboardEvent.clipboardData?.getData('text/plain');

  if (text != null && text.isNotEmpty) {
    // Prevent default browser paste and handle it ourselves
    clipboardEvent.preventDefault();
    _onPaste!(text);
  }
}
