import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../models/documents/document.dart';
import '../../models/documents/nodes/embeddable.dart';
import '../../models/documents/nodes/leaf.dart';
import '../../models/documents/style.dart';
import '../../utils/delta.dart';
import '../editor.dart';

mixin RawEditorStateSelectionDelegateMixin on EditorState
    implements TextSelectionDelegate {
  @override
  TextEditingValue get textEditingValue {
    return widget.controller.plainTextEditingValue;
  }

  set textEditingValue(TextEditingValue value) {
    final cursorPosition = value.selection.extentOffset;
    final oldText = widget.controller.document.toPlainText();
    final newText = value.text;
    final diff = getDiff(oldText, newText, cursorPosition);
    if (diff.deleted == '' && diff.inserted == '') {
      // Only changing selection range
      widget.controller.updateSelection(value.selection, ChangeSource.LOCAL);
      return;
    }

    var insertedText = diff.inserted;
    final containsEmbed =
        insertedText.codeUnits.contains(Embed.kObjectReplacementInt);
    insertedText =
        containsEmbed ? _adjustInsertedText(diff.inserted) : diff.inserted;

    widget.controller.replaceText(
        diff.start, diff.deleted.length, insertedText, value.selection);

    _applyPasteStyleAndEmbed(insertedText, diff.start, containsEmbed);
  }

  void _applyPasteStyleAndEmbed(
      String insertedText, int start, bool containsEmbed) {
    if (insertedText == pastePlainText && pastePlainText != '' ||
        containsEmbed) {
      final pos = start;
      for (var i = 0; i < pasteStyleAndEmbed.length; i++) {
        final offset = pasteStyleAndEmbed[i].offset;
        final styleAndEmbed = pasteStyleAndEmbed[i].value;

        final local = pos + offset;
        if (styleAndEmbed is Embeddable) {
          widget.controller.replaceText(local, 0, styleAndEmbed, null);
        } else {
          final style = styleAndEmbed as Style;
          if (style.isInline) {
            widget.controller
                .formatTextStyle(local, pasteStyleAndEmbed[i].length!, style);
          } else if (style.isBlock) {
            final node = widget.controller.document.queryChild(local).node;
            if (node != null &&
                pasteStyleAndEmbed[i].length == node.length - 1) {
              style.values.forEach((attribute) {
                widget.controller.document.format(local, 0, attribute);
              });
            }
          }
        }
      }
    }
  }

  String _adjustInsertedText(String text) {
    final sb = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == Embed.kObjectReplacementInt) {
        continue;
      }
      sb.write(text[i]);
    }
    return sb.toString();
  }

  @override
  void bringIntoView(TextPosition position) {
    // Ignore errors if position is invalid (i.e. paste on iOS when editor
    // has no content and user pasted from toolbar)
    try {
      final localRect = renderEditor.getLocalRectForCaret(position);
      final targetOffset = _getOffsetToRevealCaret(localRect, position);

      if (scrollController.hasClients) {
        scrollController.jumpTo(targetOffset.offset);
      }
      renderEditor.showOnScreen(rect: targetOffset.rect);
    } catch (_) {}
  }

  // Finds the closest scroll offset to the current scroll offset that fully
  // reveals the given caret rect. If the given rect's main axis extent is too
  // large to be fully revealed in `renderEditable`, it will be centered along
  // the main axis.
  //
  // If this is a multiline EditableText (which means the Editable can only
  // scroll vertically), the given rect's height will first be extended to match
  // `renderEditable.preferredLineHeight`, before the target scroll offset is
  // calculated.
  RevealedOffset _getOffsetToRevealCaret(Rect rect, TextPosition position) {
    // Make sure scrollController is attached
    if (!scrollController.hasClients) {
      return RevealedOffset(offset: 0, rect: rect);
    }

    if (!scrollController.position.allowImplicitScrolling) {
      return RevealedOffset(offset: scrollController.offset, rect: rect);
    }

    // Use viewport dimension, not renderEditor.size (which is document size)
    final viewportHeight = scrollController.position.viewportDimension;
    final currentScrollOffset = scrollController.offset;

    // The caret is vertically centered within the line. Expand the caret's
    // height so that it spans the line because we're going to ensure that the
    // entire expanded caret is scrolled into view.
    final expandedRect = Rect.fromCenter(
      center: rect.center,
      width: rect.width,
      height: math.max(rect.height, renderEditor.preferredLineHeight(position)),
    );

    // Calculate target scroll offset based on caret position relative to viewport
    final caretTop = expandedRect.top;
    final caretBottom = expandedRect.bottom;
    final visibleTop = currentScrollOffset;
    final visibleBottom = currentScrollOffset + viewportHeight;

    var targetOffset = currentScrollOffset;

    if (expandedRect.height >= viewportHeight) {
      // Caret is taller than viewport, center it
      targetOffset = expandedRect.center.dy - viewportHeight / 2;
    } else if (caretBottom > visibleBottom) {
      // Caret is below visible area, scroll down to bring caret bottom to viewport bottom
      targetOffset = caretBottom - viewportHeight;
    } else if (caretTop < visibleTop) {
      // Caret is above visible area, scroll up to bring caret top to viewport top
      targetOffset = caretTop;
    }

    // Clamp to valid scroll range
    targetOffset = targetOffset.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );

    final offsetDelta = currentScrollOffset - targetOffset;
    return RevealedOffset(
        rect: rect.shift(Offset(0, offsetDelta)), offset: targetOffset);
  }

  @override
  void hideToolbar([bool hideHandles = true]) {
    // If the toolbar is currently visible.
    if (selectionOverlay?.toolbar != null) {
      hideHandles ? selectionOverlay?.hide() : selectionOverlay?.hideToolbar();
    }
  }

  @override
  void userUpdateTextEditingValue(
      TextEditingValue value, SelectionChangedCause cause) {
    textEditingValue = value;
  }

  @override
  bool get cutEnabled => widget.contextMenuBuilder != null && !widget.readOnly;

  @override
  bool get copyEnabled => widget.contextMenuBuilder != null;

  @override
  bool get pasteEnabled =>
      widget.contextMenuBuilder != null && !widget.readOnly;

  @override
  bool get selectAllEnabled => widget.contextMenuBuilder != null;
}
