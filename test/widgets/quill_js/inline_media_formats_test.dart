import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default formats exclude image and video', () {
    expect(QuillJsEditorConfiguration.defaultFormats, [
      'bold',
      'italic',
      'underline',
      'list',
      'link',
      'indent',
    ]);
    expect(const QuillJsEditorConfiguration().effectiveFormats, QuillJsEditorConfiguration.defaultFormats);
  });

  test('a custom format list is kept in order', () {
    final formats = [...QuillJsEditorConfiguration.defaultFormats, 'image', 'video'];
    final configuration = QuillJsEditorConfiguration(formats: formats);
    expect(configuration.effectiveFormats, formats);
  });

  test('request methods do nothing before the editor attaches', () async {
    final controller = QuillJsEditorController();
    await controller.requestImageEmbed();
    await controller.requestVideoEmbed();
    expect(controller.isAttached, isFalse);
  });
}
