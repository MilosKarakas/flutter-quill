import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpToolbar(
    WidgetTester tester, {
    bool showImage = false,
    bool showVideo = false,
    List<String>? enabledFormats,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuillToolbar.basic(
            quillJsController: QuillJsEditorController(),
            showImage: showImage,
            showVideo: showVideo,
            enabledFormats: enabledFormats ?? QuillJsEditorConfiguration.defaultFormats,
          ),
        ),
      ),
    );
  }

  testWidgets('hides both buttons by default', (tester) async {
    await pumpToolbar(tester, showImage: true, showVideo: true);
    expect(find.byTooltip('Insert image'), findsNothing);
    expect(find.byTooltip('Insert video'), findsNothing);
  });

  testWidgets('shows a button only when its flag and format are set', (tester) async {
    await pumpToolbar(
      tester,
      showImage: true,
      showVideo: false,
      enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'image', 'video'],
    );
    expect(find.byTooltip('Insert image'), findsOneWidget);
    expect(find.byTooltip('Insert video'), findsNothing);
  });

  testWidgets('uses the default tooltip when a custom map omits the media keys', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuillToolbar.basic(
            quillJsController: QuillJsEditorController(),
            showImage: true,
            showVideo: true,
            enabledFormats: [...QuillJsEditorConfiguration.defaultFormats, 'image', 'video'],
            tooltips: const {ToolbarButtons.bold: 'Bold'},
          ),
        ),
      ),
    );
    expect(find.byTooltip('Insert image'), findsOneWidget);
    expect(find.byTooltip('Insert video'), findsOneWidget);
  });
}
