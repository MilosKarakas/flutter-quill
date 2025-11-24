import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

const _kLogTag = '[WebClipboard]';

/// Callbacks for clipboard operations
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
  required String Function()
      getSelectedText, // Kept for API compatibility, not used
  required void Function() onCopy,
  required void Function() onCut,
  required void Function(String text) onPaste,
  required bool Function() hasFocus,
}) {
  // Note: getSelectedText is no longer used - we let browser handle copy/cut natively
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
  if (_onCopy == null) {
    debugPrint('$_kLogTag Ignoring copy - callback not set');
    return;
  }

  // DON'T preventDefault() - let the browser handle the actual clipboard copy
  // from Flutter's hidden input element. We just need to know it happened
  // so we can restore focus afterwards.
  debugPrint(
      '$_kLogTag Copy: Letting browser handle copy, calling onCopy callback');
  _onCopy!();
}

/// Handles browser cut event
void _handleCut(web.Event event) {
  debugPrint('$_kLogTag _handleCut triggered');

  // Check if we should handle this event (has focus or recently had focus)
  if (!_shouldHandleClipboardEvent()) {
    debugPrint('$_kLogTag Ignoring cut - not our event');
    return;
  }
  if (_onCut == null) {
    debugPrint('$_kLogTag Ignoring cut - callback not set');
    return;
  }

  // DON'T preventDefault() - let the browser handle the actual clipboard cut
  // from Flutter's hidden input element. The browser will also delete the
  // selected text from the hidden element, but Flutter's document model
  // needs to be updated too via the onCut callback.
  debugPrint(
      '$_kLogTag Cut: Letting browser handle cut, calling onCut callback');
  _onCut!();
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
