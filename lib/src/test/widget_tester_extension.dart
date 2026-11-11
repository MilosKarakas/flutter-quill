import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widgets/editor.dart';

/// Extends
extension QuillEnterText on WidgetTester {
  /// Give the QuillEditor widget specified by [finder] the focus.
  Future<void> quillGiveFocus(Finder finder) {
    return TestAsyncUtils.guard(() async {
      final editor = state<QuillEditorState>(
        find.descendant(of: finder, matching: find.byType(QuillEditor, skipOffstage: finder.skipOffstage), matchRoot: true),
      );
      editor.widget.focusNode.requestFocus();
      await pump();
      // Make sure the text input connection is open even if the editor was
      // still dirty when focus arrived (needed for real-device integration
      // tests); done here so production focus handling stays untouched.
      editor.editableTextKey.currentState?.requestKeyboard();
      await pump();
      expect(editor.widget.focusNode.hasFocus, isTrue);
    });
  }

  /// Give the QuillEditor widget specified by [finder] the focus and update its
  /// editing value with [text], as if it had been provided by the onscreen
  /// keyboard.
  ///
  /// The widget specified by [finder] must be a [QuillEditor] or have a
  /// [QuillEditor] descendant. For example `find.byType(QuillEditor)`.
  Future<void> quillEnterText(Finder finder, String text) async {
    return TestAsyncUtils.guard(() async {
      await quillGiveFocus(finder);
      await pumpAndSettle(const Duration(milliseconds: 500));
      await quillUpdateEditingValue(finder, text);
      await idle();
    });
  }

  /// Update the text editing value of the QuillEditor widget specified by
  /// [finder] with [text], as if it had been provided by the onscreen keyboard.
  ///
  /// The widget specified by [finder] must already have focus and be a
  /// [QuillEditor] or have a [QuillEditor] descendant. For example
  /// `find.byType(QuillEditor)`.
  Future<void> quillUpdateEditingValue(Finder finder, String text) async {
    return TestAsyncUtils.guard(() async {
      final editor = state<QuillEditorState>(
        find.descendant(
            of: finder,
            matching: find.byType(QuillEditor, skipOffstage: finder.skipOffstage),
            matchRoot: true),
      );

      editor.widget.controller.clear();
      // The platform-side editing value of a Quill document always ends with
      // the document's trailing '\n'. Mirror that here so the editor computes
      // a pure insertion diff against the cleared document ('\n').
      final effectiveText = text.endsWith('\n') ? text : '$text\n';
      final offset = text.endsWith('\n') ? text.length - 1 : text.length;
      testTextInput.updateEditingValue(TextEditingValue(
        text: effectiveText,
        selection: TextSelection.collapsed(offset: offset),
      ));
      await idle();
    });
  }

  Future<void> quillUpdateEditingValueWithSelection(
      Finder finder, String text, TextSelection selection) async {
    expect(selection.isValid, isTrue,
        reason:
        'The TextSelection passed is not valid to be used for text editing values');
    return TestAsyncUtils.guard(() async {
      testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: selection,
        ),
      );
      await idle();
    });
  }

  Future<void> quillReplaceTextWithSelection(
      Finder finder, String replacement, TextSelection selection) async {
    final editor = findRawEditor(finder: finder);
    expect(selection.isValid, isTrue,
        reason: 'The selection in the editor is not valid');
    final effectivePlainText = editor.widget.controller.document
        .toPlainText()
        .replaceRange(
        selection.baseOffset, selection.extentOffset, replacement);
    return TestAsyncUtils.guard(() async {
      await quillGiveFocus(finder);
      await quillUpdateEditingValueWithSelection(
        finder,
        effectivePlainText,
        TextSelection.collapsed(
          offset: selection.baseOffset + replacement.length,
        ),
      );
      await idle();
    });
  }

  Future<void> quillReplaceText(Finder finder, String replacement) async {
    final editor = findRawEditor(finder: finder);
    final selection = editor.widget.controller.selection;
    expect(selection.isValid, isTrue,
        reason: 'The selection in the editor is not valid');
    final effectivePlainText = editor.widget.controller.document
        .toPlainText()
        .replaceRange(
        selection.baseOffset, selection.extentOffset, replacement);
    return TestAsyncUtils.guard(() async {
      await quillGiveFocus(finder);
      await quillUpdateEditingValueWithSelection(
        finder,
        effectivePlainText,
        TextSelection.collapsed(
          offset: selection.baseOffset + replacement.length,
        ),
      );
      await idle();
    });
  }

  QuillEditorState findRawEditor({required Finder finder}) {
    return state<QuillEditorState>(
      find.descendant(
          of: finder,
          matching: find.byType(QuillEditor, skipOffstage: finder.skipOffstage),
          matchRoot: true),
    );
  }
}
