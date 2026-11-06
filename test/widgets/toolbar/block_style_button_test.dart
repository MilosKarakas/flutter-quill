import 'dart:io';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/src/widgets/toolbar/select_block_style_button.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  const labels = <String>[
    'Insert image',
    'Insert video',
    'Paragraph',
    'Heading 1',
    'Heading 2',
    'Heading 3',
    'Heading 4',
    'Heading 5',
    'Heading 6',
    'Preformatted',
  ];

  test('every locale map defines the block-style labels', () {
    final source =
        File('lib/src/translations/toolbar.i18n.dart').readAsStringSync();
    for (final label in labels) {
      expect(
        RegExp("'${RegExp.escape(label)}': ").allMatches(source).length,
        35,
      );
    }
    expect(
      RegExp("'Insert image': 'Insert image'").allMatches(source).length,
      2,
    );
    expect(
      RegExp("'Insert image': 'Bild einfügen'").allMatches(source).length,
      1,
    );
  });

  Future<void> pumpToolbar(
    WidgetTester tester, {
    QuillController? controller,
    QuillJsEditorController? quillJsController,
    bool showHeaderStyle = true,
    List<String>? enabledFormats,
    Map<ToolbarButtons, String>? tooltips,
    VoidCallback? afterButtonPressed,
    Locale? locale,
  }) {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        locale: locale,
        home: Scaffold(
          body: QuillToolbar.basic(
            controller: controller,
            quillJsController: quillJsController,
            showHeaderStyle: showHeaderStyle,
            enabledFormats:
                enabledFormats ?? QuillJsEditorConfiguration.defaultFormats,
            tooltips: tooltips,
            afterButtonPressed: afterButtonPressed,
            locale: locale,
          ),
        ),
      ),
    );
  }

  void attach(
    QuillJsEditorController controller,
    bool Function(BlockStyleChoice choice) apply, {
    void Function(bool ignoring)? setEditorIgnoresPointers,
  }) {
    controller.attachCallbacks(
      toggleBold: () {},
      toggleItalic: () {},
      toggleUnderline: () {},
      toggleOrderedList: () {},
      toggleBulletList: () {},
      requestLink: () async {},
      getContents: () => Delta()..insert('\n'),
      setContents: (_) {},
      scrollToEnd: () {},
      ensureSelectionVisible: () {},
      clear: () {},
      setSelection: (_, _) {},
      insertText: (_, _, _) {},
      replaceText: (_, _, _) {},
      insertTextAtCursor: (_) {},
      focus: () {},
      blur: () {},
      applyBlockStyle: apply,
      setEditorIgnoresPointers: setEditorIgnoresPointers,
    );
  }

  testWidgets('keeps the classic H1 buttons and hides the web menu', (tester) async {
    await pumpToolbar(tester, controller: QuillController.basic());
    expect(find.text('H1'), findsOneWidget);
    expect(find.text('Paragraph'), findsNothing);
  });

  testWidgets('keeps the classic H1 buttons when both controllers are given and the web menu is off', (tester) async {
    await pumpToolbar(
      tester,
      controller: QuillController.basic(),
      quillJsController: QuillJsEditorController(),
    );
    expect(find.text('H1'), findsOneWidget);
    expect(find.text('Paragraph'), findsNothing);
  });

  testWidgets('the web menu replaces the classic H1 buttons when both controllers are given', (tester) async {
    await pumpToolbar(
      tester,
      controller: QuillController.basic(),
      quillJsController: QuillJsEditorController(),
      enabledFormats: const [...QuillJsEditorConfiguration.defaultFormats, 'header'],
    );
    expect(find.text('H1'), findsNothing);
    expect(find.text('Paragraph'), findsOneWidget);
  });

  testWidgets('hides both header controls on the default web toolbar', (tester) async {
    await pumpToolbar(tester, quillJsController: QuillJsEditorController());
    expect(find.text('Paragraph'), findsNothing);
    expect(find.text('H1'), findsNothing);
  });

  testWidgets('shows headings without Preformatted until code-block is enabled', (tester) async {
    final controller = QuillJsEditorController();
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
    );
    expect(find.byTooltip('Header style'), findsOneWidget);
    expect(find.text('H1'), findsNothing);
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    expect(find.text('Heading 1'), findsOneWidget);
    expect(find.text('Heading 6'), findsOneWidget);
    expect(find.text('Preformatted'), findsNothing);
  });

  testWidgets('shows only Preformatted when only code-block is enabled', (tester) async {
    await pumpToolbar(
      tester,
      quillJsController: QuillJsEditorController(),
      enabledFormats: [
        ...QuillJsEditorConfiguration.defaultFormats,
        'code-block',
      ],
    );
    expect(find.byTooltip('Header style'), findsOneWidget);
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    expect(find.text('Heading 1'), findsNothing);
    expect(find.text('Preformatted'), findsOneWidget);
  });

  testWidgets('shows Preformatted when code-block is enabled', (tester) async {
    await pumpToolbar(
      tester,
      quillJsController: QuillJsEditorController(),
      enabledFormats: [
        ...QuillJsEditorConfiguration.defaultFormats,
        'header',
        'code-block',
      ],
    );
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    expect(find.text('Preformatted'), findsOneWidget);
  });

  testWidgets('hides the menu when header style is off', (tester) async {
    await pumpToolbar(
      tester,
      quillJsController: QuillJsEditorController(),
      showHeaderStyle: false,
      enabledFormats: [
        ...QuillJsEditorConfiguration.defaultFormats,
        'header',
        'code-block',
      ],
    );
    expect(find.text('Paragraph'), findsNothing);
  });

  testWidgets('uses Header style when a custom tooltip map omits it', (tester) async {
    await pumpToolbar(
      tester,
      quillJsController: QuillJsEditorController(),
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
      tooltips: const {ToolbarButtons.bold: 'Bold'},
    );
    expect(find.byTooltip('Header style'), findsOneWidget);
  });

  testWidgets('the closed label follows the format state', (tester) async {
    final controller = QuillJsEditorController();
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [
        ...QuillJsEditorConfiguration.defaultFormats,
        'header',
        'code-block',
      ],
    );
    controller.updateFormatState(
      const QuillJsFormatState(blockStyle: BlockStyleChoice.heading3),
    );
    await tester.pump();
    expect(find.text('Heading 3'), findsOneWidget);
  });

  testWidgets('a mixed selection shows no current style', (tester) async {
    final controller = QuillJsEditorController();
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
    );
    controller.updateFormatState(
      const QuillJsFormatState(
        blockStyle: BlockStyleChoice.heading2,
        blockStyleMixed: true,
      ),
    );
    await tester.pump();
    expect(find.text('Heading 2'), findsNothing);
    expect(find.text('Paragraph'), findsNothing);
  });

  testWidgets('marks the selected style in the open menu', (tester) async {
    final controller = QuillJsEditorController();
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
    );
    controller.updateFormatState(
      const QuillJsFormatState(blockStyle: BlockStyleChoice.heading2),
    );
    await tester.pump();
    await tester.tap(find.text('Heading 2'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('widens the trigger for longer locale labels', (tester) async {
    await pumpToolbar(
      tester,
      quillJsController: QuillJsEditorController(),
      enabledFormats: [
        ...QuillJsEditorConfiguration.defaultFormats,
        'header',
        'code-block',
      ],
      locale: const Locale('de'),
    );
    final trigger = tester.widget<SizedBox>(
      find.ancestor(
        of: find.text('Absatz'),
        matching: find.byType(SizedBox),
      ).first,
    );
    expect(trigger.width, greaterThan(148));
    expect(trigger.width, lessThanOrEqualTo(220));
  });

  test('skips dropdown rebuild when blockStyle is unchanged', () {
    expect(
      blockStyleDropdownNeedsRebuild(
        BlockStyleChoice.paragraph,
        BlockStyleChoice.paragraph,
      ),
      isFalse,
    );
    expect(
      blockStyleDropdownNeedsRebuild(
        BlockStyleChoice.paragraph,
        BlockStyleChoice.heading1,
      ),
      isTrue,
    );
  });

  testWidgets('a choice calls applyBlockStyle and afterButtonPressed only when it applies', (tester) async {
    final controller = QuillJsEditorController();
    var applied = false;
    var pressed = 0;
    attach(controller, (choice) {
      expect(choice, BlockStyleChoice.heading1);
      return applied;
    });
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
      afterButtonPressed: () => pressed += 1,
    );
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heading 1').last);
    await tester.pumpAndSettle();
    expect(pressed, 0);

    applied = true;
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heading 1').last);
    await tester.pumpAndSettle();
    expect(pressed, 1);
    controller.dispose();
  });

  testWidgets('the open menu tells the editor iframe to ignore pointers', (tester) async {
    final controller = QuillJsEditorController();
    final events = <bool>[];
    attach(
      controller,
      (_) => true,
      setEditorIgnoresPointers: events.add,
    );
    await pumpToolbar(
      tester,
      quillJsController: controller,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'header'],
    );
    await tester.tap(find.text('Paragraph'));
    await tester.pumpAndSettle();
    expect(events, [true]);
    await tester.tap(find.text('Heading 1').last);
    await tester.pumpAndSettle();
    expect(events, [true, false]);
    controller.dispose();
  });
}
