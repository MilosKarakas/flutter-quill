import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('block style defaults to paragraph and participates in equality', () {
    const plain = QuillJsFormatState();
    const heading = QuillJsFormatState(blockStyle: BlockStyleChoice.heading2);
    expect(plain.blockStyle, BlockStyleChoice.paragraph);
    expect(plain == heading, isFalse);
    expect(heading.blockStyle, BlockStyleChoice.heading2);
  });

  test('applyBlockStyle is a no-op before the editor attaches', () {
    final controller = QuillJsEditorController();
    expect(controller.applyBlockStyle(BlockStyleChoice.heading1), isFalse);
  });
}
