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

/// Track when we lost focus to allow clipboard events shortly after.
/// The browser context menu steals focus, so we need a grace period.
DateTime? _lastLostFocusTime;

/// Whether we had a selection when we lost focus (indicates context menu scenario)
bool _hadSelectionWhenLostFocus = false;

/// Window of time (ms) after losing focus where we still handle clipboard events.
/// Set to 30 seconds to allow users time to read context menu options.
const _focusGraceWindowMs = 30000;

/// Call this whenever the editor gains focus.
void notifyEditorHasFocus() {
  // Clear the lost focus tracking since we have focus again
  _lastLostFocusTime = null;
  _hadSelectionWhenLostFocus = false;
  debugPrint('$_kLogTag notifyEditorHasFocus: cleared lost focus state');
}

/// Call this when the editor loses focus to start the grace window.
void notifyEditorLostFocus({required bool hasSelection}) {
  _lastLostFocusTime = DateTime.now();
  _hadSelectionWhenLostFocus = hasSelection;
  debugPrint(
      '$_kLogTag notifyEditorLostFocus: hasSelection=$hasSelection, started grace window');
}

/// Checks if we should handle clipboard events.
/// Returns true if we have focus OR if we recently lost focus with a selection (context menu case).
bool _shouldHandleClipboardEvent() {
  final hasFocus = _hasFocus?.call() ?? false;
  if (hasFocus) {
    debugPrint('$_kLogTag shouldHandle: true (has focus)');
    return true;
  }

  // Check if we recently lost focus AND had a selection (context menu scenario)
  if (_lastLostFocusTime != null && _hadSelectionWhenLostFocus) {
    final elapsed =
        DateTime.now().difference(_lastLostFocusTime!).inMilliseconds;
    if (elapsed < _focusGraceWindowMs) {
      debugPrint(
          '$_kLogTag shouldHandle: true (lost focus ${elapsed}ms ago with selection, within grace window)');
      return true;
    }
    debugPrint(
        '$_kLogTag shouldHandle: false (lost focus ${elapsed}ms ago, outside grace window)');
  } else if (_lastLostFocusTime != null && !_hadSelectionWhenLostFocus) {
    debugPrint(
        '$_kLogTag shouldHandle: false (lost focus but had no selection)');
  } else {
    debugPrint('$_kLogTag shouldHandle: false (no focus history)');
  }
  return false;
}

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

  // Check if we should handle this event (has focus or recently had focus)
  if (!_shouldHandleClipboardEvent()) {
    debugPrint('$_kLogTag Ignoring copy - not our event');
    return;
  }
  if (_onCopy == null || _getSelectedText == null) {
    debugPrint('$_kLogTag Ignoring copy - callbacks not set');
    return;
  }

  final selectedText = _getSelectedText!();
  if (selectedText.isEmpty) {
    debugPrint('$_kLogTag Copy: No text selected, skipping');
    return;
  }

  // CRITICAL: Prevent the browser's default copy behavior.
  // Without this, the browser tries to copy from the DOM (which is empty
  // for Flutter canvas), potentially overwriting our clipboard data.
  final clipboardEvent = event as web.ClipboardEvent;
  clipboardEvent.preventDefault();

  // Use the async Clipboard API to write directly to system clipboard.
  debugPrint(
      '$_kLogTag Copy: Writing ${selectedText.length} chars to clipboard via API');

  final onCopyCallback = _onCopy!;
  web.window.navigator.clipboard.writeText(selectedText).toDart.then((_) {
    debugPrint(
        '$_kLogTag Copy: Successfully wrote to clipboard, calling onCopy');
    onCopyCallback();
  }).catchError((e) {
    debugPrint('$_kLogTag Copy: Failed to write to clipboard: $e');
    // Still call onCopy for focus restoration even if clipboard failed
    onCopyCallback();
  });
}

/// Handles browser cut event
void _handleCut(web.Event event) {
  debugPrint('$_kLogTag _handleCut triggered');

  // Check if we should handle this event (has focus or recently had focus)
  if (!_shouldHandleClipboardEvent()) {
    debugPrint('$_kLogTag Ignoring cut - not our event');
    return;
  }
  if (_onCut == null || _getSelectedText == null) {
    debugPrint('$_kLogTag Ignoring cut - callbacks not set');
    return;
  }

  final selectedText = _getSelectedText!();
  if (selectedText.isEmpty) {
    debugPrint('$_kLogTag Cut: No text selected, skipping');
    return;
  }

  // CRITICAL: Prevent the browser's default cut behavior.
  final clipboardEvent = event as web.ClipboardEvent;
  clipboardEvent.preventDefault();

  // Use the async Clipboard API to write directly to system clipboard.
  debugPrint(
      '$_kLogTag Cut: Writing ${selectedText.length} chars to clipboard via API');

  final onCutCallback = _onCut!;
  web.window.navigator.clipboard.writeText(selectedText).toDart.then((_) {
    debugPrint('$_kLogTag Cut: Successfully wrote to clipboard, calling onCut');
    onCutCallback();
  }).catchError((e) {
    debugPrint('$_kLogTag Cut: Failed to write to clipboard: $e');
    // Still call onCut for deletion even if clipboard failed
    onCutCallback();
  });
}

/// Handles browser paste event
void _handlePaste(web.Event event) {
  debugPrint('$_kLogTag _handlePaste triggered');

  // Check if we should handle this event (has focus or recently had focus)
  if (!_shouldHandleClipboardEvent()) {
    debugPrint('$_kLogTag Ignoring paste - not our event');
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
