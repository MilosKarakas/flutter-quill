import 'dart:async';
import 'dart:ui';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../models/documents/document.dart';
import '../../utils/delta.dart';
import '../../utils/platform.dart';
import '../editor.dart';

mixin RawEditorStateTextInputClientMixin on EditorState
    implements TextInputClient {
  TextInputConnection? _textInputConnection;
  TextEditingValue? _lastKnownRemoteTextEditingValue;

  // Track the last programmatically set selection to use when syncing with Safari
  // This prevents Safari's stale selection updates from overwriting our correct selection
  TextSelection? _lastProgrammaticSelection;
  int _programmaticSelectionId = 0;

  /// Counter to track pending connection operations for debouncing
  int _pendingConnectionOperationId = 0;

  /// Duration to wait for platform sync on mobile web
  /// This is necessary because Safari's text input system processes updates asynchronously
  static const Duration _mobileWebSyncDelay = Duration(milliseconds: 16);

  /// Stores the programmatic selection that was just set (from tap/gesture)
  /// This is used to override Safari's potentially stale selection when syncing
  /// Note: Not private because it's called from RawEditorState which uses this mixin
  void setProgrammaticSelection(TextSelection selection) {
    _lastProgrammaticSelection = selection;
    _programmaticSelectionId++;
  }

  /// Gets the selection to use when syncing with platform
  /// Prefers programmatic selection if it was set recently
  TextSelection getSelectionForSync() {
    // Always prefer the programmatic selection if we have one and it's recent
    // The programmaticSelectionId ensures we don't use stale selections
    if (_lastProgrammaticSelection != null && _programmaticSelectionId > 0) {
      return _lastProgrammaticSelection!;
    }
    // Fallback to controller selection
    return widget.controller.selection;
  }

  /// Clears the programmatic selection after it's been used
  void _clearProgrammaticSelection() {
    _lastProgrammaticSelection = null;
    _programmaticSelectionId = 0;
  }

  /// Whether to create an input connection with the platform for text editing
  /// or not.
  ///
  /// Read-only input fields do not need a connection with the platform since
  /// there's no need for text editing capabilities (e.g. virtual keyboard).
  ///
  /// On the web, we always need a connection because we want some browser
  /// functionalities to continue to work on read-only input fields like:
  ///
  /// - Relevant context menu.
  /// - cmd/ctrl+c shortcut to copy.
  /// - cmd/ctrl+a to select all.
  /// - Changing the selection using a physical keyboard.
  bool get shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  /// Returns `true` if there is open input connection.
  bool get hasConnection =>
      _textInputConnection != null && _textInputConnection!.attached;

  /// Opens or closes input connection based on the current state of
  /// [focusNode] and [value].
  void openOrCloseConnection() {
    final hasFocus = widget.focusNode.hasFocus;
    debugPrint(
        '[TextInput] openOrCloseConnection: hasFocus=$hasFocus, hasConnection=$hasConnection');

    // Simplified to match Flutter's EditableText pattern - no delays
    if (hasFocus && widget.focusNode.consumeKeyboardToken()) {
      debugPrint(
          '[TextInput] Has focus and consumed keyboard token, opening connection');
      openConnectionIfNeeded();
    } else if (!hasFocus) {
      debugPrint('[TextInput] No focus, closing connection');
      closeConnectionIfNeeded();
    } else {
      debugPrint(
          '[TextInput] Has focus but did not consume keyboard token, no action');
    }
  }

  void openConnectionIfNeeded() {
    debugPrint(
        '[TextInput] openConnectionIfNeeded: shouldCreate=$shouldCreateInputConnection, hasConnection=$hasConnection');

    if (!shouldCreateInputConnection) {
      debugPrint('[TextInput] Skipping - shouldCreateInputConnection is false');
      return;
    }

    if (!hasConnection) {
      debugPrint('[TextInput] Creating new TextInputConnection...');
      _textInputConnection = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: TextInputType.multiline,
          readOnly: widget.readOnly,
          inputAction: TextInputAction.newline,
          enableSuggestions: !widget.readOnly,
          keyboardAppearance: widget.keyboardAppearance,
          textCapitalization: widget.textCapitalization,
          allowedMimeTypes: widget.contentInsertionConfiguration == null
              ? const <String>[]
              : widget.contentInsertionConfiguration!.allowedMimeTypes,
        ),
      );

      _updateSizeAndTransform();
      //update IME position for Windows
      _updateComposingRectIfNeeded();
      //update IME position for Macos
      _updateCaretRectIfNeeded();

      // On mobile web (especially Safari), ensure selection has propagated before
      // setting initial editing state. This prevents cursor from jumping to end.
      if (isMobileWeb()) {
        _syncEditingStateForMobileWeb(isNewConnection: true);
      } else {
        _lastKnownRemoteTextEditingValue = textEditingValue;
        _textInputConnection!
            .setEditingState(_lastKnownRemoteTextEditingValue!);
        _safeShowConnection();
        debugPrint('[TextInput] New connection created and shown');
      }
    } else {
      debugPrint('[TextInput] Connection exists, just showing keyboard');
      // Connection already exists, just show keyboard
      if (isMobileWeb()) {
        _syncEditingStateForMobileWeb(isNewConnection: false);
      } else {
        _safeShowConnection();
      }
    }
    debugPrint(
        '[TextInput] openConnectionIfNeeded completed, hasConnection=$hasConnection');
  }

  /// Synchronizes editing state for mobile web platforms (Safari, Chrome mobile).
  ///
  /// Mobile web browsers have asynchronous text input systems that may not
  /// immediately reflect Flutter's selection state. This method uses a
  /// debounced post-frame callback to ensure proper synchronization.
  ///
  /// [isNewConnection] - Whether this is for a newly created connection
  void _syncEditingStateForMobileWeb({required bool isNewConnection}) {
    // Increment operation ID to invalidate any pending operations
    final currentOperationId = ++_pendingConnectionOperationId;

    // Wait for the frame to complete before syncing
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // Check if this operation is still valid (not superseded by a newer one)
      if (!mounted ||
          !hasConnection ||
          currentOperationId != _pendingConnectionOperationId) {
        return;
      }

      // Use a microtask-based approach instead of fixed delays
      // This allows the browser's event loop to process pending updates
      Future.delayed(_mobileWebSyncDelay, () {
        // Re-check validity after delay
        if (!mounted ||
            !hasConnection ||
            currentOperationId != _pendingConnectionOperationId) {
          return;
        }

        final currentSelection = getSelectionForSync();
        final currentText = widget.controller.document.toPlainText();
        final currentValue = TextEditingValue(
          text: currentText,
          selection: currentSelection,
        );

        // Only update if value has changed or this is a new connection
        if (isNewConnection ||
            _lastKnownRemoteTextEditingValue != currentValue) {
          _lastKnownRemoteTextEditingValue = currentValue;
          _textInputConnection!.setEditingState(currentValue);
        }
        _safeShowConnection();

        // Clear programmatic selection after it's been applied
        _clearProgrammaticSelection();
      });
    });
  }

  void _updateComposingRectIfNeeded() {
    final composingRange = _lastKnownRemoteTextEditingValue?.composing ??
        textEditingValue.composing;
    if (hasConnection) {
      assert(mounted);
      final offset = composingRange.isValid ? composingRange.start : 0;
      final composingRect =
          renderEditor.getLocalRectForCaret(TextPosition(offset: offset));
      _textInputConnection!.setComposingRect(composingRect);
      SchedulerBinding.instance
          .addPostFrameCallback((_) => _updateComposingRectIfNeeded());
    }
  }

  void _updateCaretRectIfNeeded() {
    if (hasConnection) {
      if (!dirty &&
          renderEditor.selection.isValid &&
          renderEditor.selection.isCollapsed) {
        final currentTextPosition =
            TextPosition(offset: renderEditor.selection.baseOffset);
        final caretRect =
            renderEditor.getLocalRectForCaret(currentTextPosition);
        _textInputConnection!.setCaretRect(caretRect);
      }
      SchedulerBinding.instance
          .addPostFrameCallback((_) => _updateCaretRectIfNeeded());
    }
  }

  /// Safely shows the text input connection with error handling.
  /// On Flutter Web, showing the connection can fail if the view is disposed
  /// or not ready. This wraps the call in a try-catch to prevent crashes.
  void _safeShowConnection() {
    if (!hasConnection) {
      debugPrint('[TextInput] _safeShowConnection: No connection to show');
      return;
    }
    if (!mounted) {
      debugPrint(
          '[TextInput] _safeShowConnection: Widget not mounted, skipping');
      return;
    }
    try {
      _textInputConnection!.show();
    } catch (e) {
      // On Flutter Web, this can fail with "Could not find View with id 0"
      // if the view is disposed or navigation happened during async operation
      debugPrint(
          '[TextInput] _safeShowConnection: Error showing connection: $e');
      // Close the broken connection so it can be recreated
      _textInputConnection?.close();
      _textInputConnection = null;
      _lastKnownRemoteTextEditingValue = null;
    }
  }

  /// Closes input connection if it's currently open. Otherwise does nothing.
  void closeConnectionIfNeeded() {
    debugPrint(
        '[TextInput] closeConnectionIfNeeded: hasConnection=$hasConnection');
    if (!hasConnection) {
      debugPrint('[TextInput] No connection to close');
      return;
    }

    debugPrint('[TextInput] Closing connection...');
    _textInputConnection!.close();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;
    debugPrint('[TextInput] Connection closed, hasConnection=$hasConnection');
  }

  /// Force closes the connection (used during dispose)
  void forceCloseConnection() {
    if (!hasConnection) {
      return;
    }
    _textInputConnection!.close();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;
  }

  /// Updates remote value based on current state of [document] and
  /// [selection].
  ///
  /// This method may not actually send an update to native side if it thinks
  /// remote value is up to date or identical.
  void updateRemoteValueIfNeeded() {
    if (!hasConnection) {
      return;
    }

    // Get the current selection, preferring programmatic selection on mobile web
    // to handle platform-specific async timing issues
    final selection =
        isMobileWeb() ? getSelectionForSync() : textEditingValue.selection;
    final text = widget.controller.document.toPlainText();
    final value = TextEditingValue(
      text: text,
      selection: selection,
      composing: textEditingValue.composing,
    );

    // Since we don't keep track of the composing range in value provided
    // by the Controller we need to add it here manually before comparing
    // with the last known remote value.
    // It is important to prevent excessive remote updates as it can cause
    // race conditions.
    final actualValue = value.copyWith(
      composing: _lastKnownRemoteTextEditingValue!.composing,
    );

    if (actualValue == _lastKnownRemoteTextEditingValue) {
      return;
    }

    _lastKnownRemoteTextEditingValue = actualValue;
    _textInputConnection!.setEditingState(
      // Set composing to (-1, -1), otherwise an exception will be thrown if
      // the values are different.
      actualValue.copyWith(composing: const TextRange(start: -1, end: -1)),
    );
  }

  // Start TextInputClient implementation
  @override
  TextEditingValue? get currentTextEditingValue =>
      _lastKnownRemoteTextEditingValue;

  // autofill is not needed
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!shouldCreateInputConnection) {
      return;
    }

    if (_lastKnownRemoteTextEditingValue == value) {
      // There is no difference between this value and the last known value.
      return;
    }

    // Check if only composing range changed.
    if (_lastKnownRemoteTextEditingValue!.text == value.text &&
        _lastKnownRemoteTextEditingValue!.selection == value.selection) {
      // This update only modifies composing range. Since we don't keep track
      // of composing range we just need to update last known value here.
      // This check fixes an issue on Android when it sends
      // composing updates separately from regular changes for text and
      // selection.
      _lastKnownRemoteTextEditingValue = value;
      return;
    }

    final effectiveLastKnownValue = _lastKnownRemoteTextEditingValue!;
    _lastKnownRemoteTextEditingValue = value;
    final oldText = effectiveLastKnownValue.text;
    final text = value.text;
    final cursorPosition = value.selection.extentOffset;
    final diff = getDiff(oldText, text, cursorPosition);

    // Determine which selection to use
    TextSelection selectionToUse = value.selection;

    // On mobile web, handle stale selection updates from platform
    // If we have a programmatic selection that's more recent, prefer it
    if (isMobileWeb() && _lastProgrammaticSelection != null) {
      final programmaticOffset = _lastProgrammaticSelection!.extentOffset;
      final incomingOffset = value.selection.extentOffset;

      // If incoming selection differs significantly from our programmatic one,
      // it's likely a stale update from the platform - use ours instead
      if ((programmaticOffset - incomingOffset).abs() > 5) {
        selectionToUse = _lastProgrammaticSelection!;
      }

      // Clear programmatic selection after handling this update
      // This ensures we don't keep overriding future legitimate platform updates
      _clearProgrammaticSelection();
    }

    if (diff.deleted.isEmpty && diff.inserted.isEmpty) {
      widget.controller.updateSelection(selectionToUse, ChangeSource.LOCAL);
    } else {
      widget.controller.replaceText(
          diff.start, diff.deleted.length, diff.inserted, selectionToUse);
    }
  }

  @override
  void performAction(TextInputAction action) {
    // no-op
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // no-op
  }

  // The time it takes for the floating cursor to snap to the text aligned
  // cursor position after the user has finished placing it.
  static const Duration _floatingCursorResetTime = Duration(milliseconds: 125);

  // The original position of the caret on FloatingCursorDragState.start.
  Rect? _startCaretRect;

  // The most recent text position as determined by the location of the floating
  // cursor.
  TextPosition? _lastTextPosition;

  // The offset of the floating cursor as determined from the start call.
  Offset? _pointOffsetOrigin;

  // The most recent position of the floating cursor.
  Offset? _lastBoundedOffset;

  // Because the center of the cursor is preferredLineHeight / 2 below the touch
  // origin, but the touch origin is used to determine which line the cursor is
  // on, we need this offset to correctly render and move the cursor.
  Offset _floatingCursorOffset(TextPosition textPosition) =>
      Offset(0, renderEditor.preferredLineHeight(textPosition) / 2);

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
        if (floatingCursorResetController.isAnimating) {
          floatingCursorResetController.stop();
          onFloatingCursorResetTick();
        }
        // We want to send in points that are centered around a (0,0) origin, so
        // we cache the position.
        _pointOffsetOrigin = point.offset;

        // Determine the starting position and whether to reset origin
        late final Offset startCaretCenter;
        late final TextPosition currentTextPosition;
        final bool shouldResetOrigin;

        // Only non-null when starting a floating cursor via long press
        if (point.startLocation != null) {
          shouldResetOrigin = false;
          final location = point.startLocation!;
          startCaretCenter = location.$1;
          currentTextPosition = location.$2;
        } else {
          shouldResetOrigin = true;
          currentTextPosition = TextPosition(
            offset: renderEditor.selection.baseOffset,
            affinity: renderEditor.selection.affinity,
          );
          startCaretCenter =
              renderEditor.getLocalRectForCaret(currentTextPosition).center;
        }

        _startCaretRect = Rect.fromCenter(
          center: startCaretCenter,
          width: 0,
          height: renderEditor.preferredLineHeight(currentTextPosition),
        );

        _lastBoundedOffset = renderEditor.calculateBoundedFloatingCursorOffset(
          startCaretCenter - _floatingCursorOffset(currentTextPosition),
          shouldResetOrigin: shouldResetOrigin,
        );
        _lastTextPosition = currentTextPosition;
        renderEditor.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
        break;
      case FloatingCursorDragState.Update:
        assert(_lastTextPosition != null, 'Last text position was not set');
        final floatingCursorOffset = _floatingCursorOffset(_lastTextPosition!);
        final centeredPoint = point.offset! - _pointOffsetOrigin!;
        final rawCursorOffset =
            _startCaretRect!.center + centeredPoint - floatingCursorOffset;

        _lastBoundedOffset = renderEditor.calculateBoundedFloatingCursorOffset(
          rawCursorOffset,
        );
        _lastTextPosition = renderEditor.getPositionForOffset(renderEditor
            .localToGlobal(_lastBoundedOffset! + floatingCursorOffset));
        renderEditor.setFloatingCursor(
            point.state, _lastBoundedOffset!, _lastTextPosition!);
        // NOTE: Selection is NOT updated during drag, matching Flutter's EditableText.
        // Selection will be updated once when the animation completes in onFloatingCursorResetTick.
        break;
      case FloatingCursorDragState.End:
        // We skip animation if no update has happened.
        if (_lastTextPosition != null && _lastBoundedOffset != null) {
          floatingCursorResetController
            ..value = 0.0
            ..animateTo(1,
                duration: _floatingCursorResetTime, curve: Curves.decelerate);
        }
        break;
    }
  }

  /// Specifies the floating cursor dimensions and position based
  /// the animation controller value.
  /// The floating cursor is resized
  /// (see [RenderAbstractEditor.setFloatingCursor])
  /// and repositioned (linear interpolation between position of floating cursor
  /// and current position of background cursor)
  void onFloatingCursorResetTick() {
    final finalPosition =
        renderEditor.getLocalRectForCaret(_lastTextPosition!).centerLeft -
            _floatingCursorOffset(_lastTextPosition!);
    if (floatingCursorResetController.isCompleted) {
      renderEditor.setFloatingCursor(
          FloatingCursorDragState.End, finalPosition, _lastTextPosition!);

      // During a floating cursor's move gesture (1 finger), the cursor is
      // animated only visually, without actually updating the selection.
      // Only after the move gesture is complete, we update the selection
      // to the new cursor location with zero selection length.
      //
      // However, during a floating cursor's selection gesture (2 fingers),
      // the selection is constantly updated by the engine throughout the gesture.
      // Thus when the gesture is complete, we should not update the selection
      // to the cursor location with zero selection length, because that would
      // overwrite the selection made by floating cursor selection.
      //
      // Here we use `isCollapsed` to distinguish between floating cursor's
      // move gesture (1 finger) vs selection gesture (2 fingers).
      if (renderEditor.selection.isCollapsed) {
        // Update selection to final cursor position
        // This matches Flutter's EditableText behavior
        renderEditor.onSelectionChanged(
          TextSelection.fromPosition(_lastTextPosition!),
          SelectionChangedCause.forcePress,
        );
      }

      _startCaretRect = null;
      _lastTextPosition = null;
      _pointOffsetOrigin = null;
      _lastBoundedOffset = null;
    } else {
      final lerpValue = floatingCursorResetController.value;
      final lerpX =
          lerpDouble(_lastBoundedOffset!.dx, finalPosition.dx, lerpValue)!;
      final lerpY =
          lerpDouble(_lastBoundedOffset!.dy, finalPosition.dy, lerpValue)!;

      renderEditor.setFloatingCursor(FloatingCursorDragState.Update,
          Offset(lerpX, lerpY), _lastTextPosition!,
          resetLerpValue: lerpValue);
    }
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // this is called VERY OFTEN when editing a document, no longer throw
    // an exception
  }

  @override
  void connectionClosed() {
    if (!hasConnection) {
      return;
    }
    _textInputConnection!.connectionClosedReceived();
    _textInputConnection = null;
    _lastKnownRemoteTextEditingValue = null;
  }

  void _updateSizeAndTransform() {
    if (hasConnection) {
      // Asking for renderEditor.size here can cause errors if layout hasn't
      // occurred yet. So we schedule a post frame callback instead.
      final size = renderEditor.size;
      final transform = renderEditor.getTransformTo(null);
      _textInputConnection?.setEditableSizeAndTransform(size, transform);
      SchedulerBinding.instance
          .addPostFrameCallback((_) => _updateSizeAndTransform());
    }
  }
}
