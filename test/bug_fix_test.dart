import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/flutter_quill_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Bug fix', () {
    group('1266 - QuillToolbar.basic() custom buttons do not have correct fill'
        'color set', () {
      testWidgets('fillColor of custom buttons and builtin buttons match', (
        tester,
      ) async {
        const tooltip = 'custom button';

        await tester.pumpWidget(
          MaterialApp(
            home: QuillToolbar.basic(
              showRedo: false,
              controller: QuillController.basic(),
              customButtons: [const QuillCustomButton(tooltip: tooltip)],
            ),
          ),
        );

        final builtinFinder = find.descendant(
          of: find.byType(HistoryButton),
          matching: find.byType(QuillIconButton),
          matchRoot: true,
        );
        expect(builtinFinder, findsOneWidget);
        final builtinButton =
            builtinFinder.evaluate().first.widget as QuillIconButton;

        final customFinder = find.descendant(
          of: find.byType(QuillToolbar),
          matching: find.byWidgetPredicate(
            (widget) => widget is QuillIconButton && widget.tooltip == tooltip,
          ),
          matchRoot: true,
        );
        expect(customFinder, findsOneWidget);
        final customButton =
            customFinder.evaluate().first.widget as QuillIconButton;

        expect(customButton.fillColor, equals(builtinButton.fillColor));
      });
    });

    group('Toolbar semantics identifiers', () {
      Finder semanticsIdentifierFinder(String identifier) {
        return find.byWidgetPredicate((widget) {
          if (widget is! Semantics) return false;
          return widget.properties.identifier == identifier;
        });
      }

      testWidgets('applies identifiers to configured toolbar buttons', (
        tester,
      ) async {
        const boldIdentifier = 'message-rich-text-bold-button';
        const italicIdentifier = 'message-rich-text-italic-button';
        const underlineIdentifier = 'message-rich-text-underline-button';
        const orderedListIdentifier = 'message-rich-text-ordered-list-button';
        const bulletListIdentifier = 'message-rich-text-bullet-list-button';
        const linkIdentifier = 'message-rich-text-link-button';

        await tester.pumpWidget(
          MaterialApp(
            home: QuillToolbar.basic(
              controller: QuillController.basic(),
              showUndo: false,
              showRedo: false,
              showFontFamily: false,
              showFontSize: false,
              showSmallButton: false,
              showStrikeThrough: false,
              showInlineCode: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showClearFormat: false,
              showAlignmentButtons: false,
              showHeaderStyle: false,
              showListCheck: false,
              showCodeBlock: false,
              showQuote: false,
              showIndent: false,
              showSearchButton: false,
              showSubscript: false,
              showSuperscript: false,
              semanticsIdentifiers: const {
                ToolbarButtons.bold: boldIdentifier,
                ToolbarButtons.italic: italicIdentifier,
                ToolbarButtons.underline: underlineIdentifier,
                ToolbarButtons.listNumbers: orderedListIdentifier,
                ToolbarButtons.listBullets: bulletListIdentifier,
                ToolbarButtons.link: linkIdentifier,
              },
            ),
          ),
        );

        expect(semanticsIdentifierFinder(boldIdentifier), findsOneWidget);
        expect(semanticsIdentifierFinder(italicIdentifier), findsOneWidget);
        expect(semanticsIdentifierFinder(underlineIdentifier), findsOneWidget);
        expect(
          semanticsIdentifierFinder(orderedListIdentifier),
          findsOneWidget,
        );
        expect(semanticsIdentifierFinder(bulletListIdentifier), findsOneWidget);
        expect(semanticsIdentifierFinder(linkIdentifier), findsOneWidget);
      });

      testWidgets('does not add identifiers when map is not provided', (
        tester,
      ) async {
        const boldIdentifier = 'message-rich-text-bold-button';

        await tester.pumpWidget(
          MaterialApp(
            home: QuillToolbar.basic(
              controller: QuillController.basic(),
              showUndo: false,
              showRedo: false,
              showSearchButton: false,
            ),
          ),
        );

        expect(semanticsIdentifierFinder(boldIdentifier), findsNothing);
      });
    });

    group('1189 - The provided text position is not in the current node', () {
      late QuillController controller;
      late QuillEditor editor;

      setUp(() {
        controller = QuillController.basic();
        editor = QuillEditor.basic(controller: controller, readOnly: false);
      });

      tearDown(() {
        controller.dispose();
      });

      testWidgets('Refocus editor after controller clears document', (
        tester,
      ) async {
        await tester.pumpWidget(MaterialApp(home: Column(children: [editor])));
        await tester.quillEnterText(find.byType(QuillEditor), 'test\n');

        editor.focusNode.unfocus();
        await tester.pump();
        controller.clear();
        editor.focusNode.requestFocus();
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('Refocus editor after removing block attribute', (
        tester,
      ) async {
        await tester.pumpWidget(MaterialApp(home: Column(children: [editor])));
        await tester.quillEnterText(find.byType(QuillEditor), 'test\n');

        controller.formatSelection(Attribute.ul);
        editor.focusNode.unfocus();
        await tester.pump();
        controller.formatSelection(const ListAttribute(null));
        editor.focusNode.requestFocus();
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('Tap checkbox in unfocused editor', (tester) async {
        await tester.pumpWidget(MaterialApp(home: Column(children: [editor])));
        await tester.quillEnterText(find.byType(QuillEditor), 'test\n');

        controller.formatSelection(Attribute.unchecked);
        editor.focusNode.unfocus();
        await tester.pump();
        await tester.tap(find.byType(CheckboxPoint));
        expect(tester.takeException(), isNull);
      });
    });
  });
}
