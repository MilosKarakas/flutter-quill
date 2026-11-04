import 'package:flutter_quill/src/widgets/quill_js/inline_media_iframe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the script registers both blots and the drop and resize hooks', () {
    final script = inlineMediaIframeScript();
    expect(script, contains('formats/image'));
    expect(script, contains('formats/video'));
    expect(script, contains('registerInlineMedia'));
    expect(script, contains('dragover'));
    expect(script, contains('__inlineMediaResize'));
    expect(script, contains('__inlineMediaApplyAttributes'));
    expect(script, contains('toDataURL'));
    expect(script, contains('stopImmediatePropagation'));
    expect(script, contains("e.key !== 'Backspace' && e.key !== 'Delete'"));
    expect(script, contains('blots/block/embed'));
    expect(script, contains('class CustomImageBlot extends BlockEmbed'));
    expect(script, contains("if (isHttpVideoSource(value)) node.setAttribute('src', value)"));
    expect(script, contains('isSvgImageSource(value) ? \'//:0\''));
    expect(script, contains('if (!blot) return'));
    expect(script, contains('window.setTimeout(onLoad, 0)'));
    expect(script, contains('function indexFromPointNode'));
    expect(script, contains('node.childNodes[offset]'));
    expect(script, contains('getBoundingClientRect'));
    expect(script, contains('embedFromEvent(e)'));
    expect(script, contains('if (!collapsed && !exactEmbed) return'));
    expect(script, contains("if (handle === 'n' || handle === 's')"));
    expect(script, contains('function editingLocked()'));
    expect(script, contains('quill.isEnabled && !quill.isEnabled()'));
    expect(script, contains('__inlineMediaSetReadOnly'));
    expect(script, contains('quill.scroll.batchStart'));
    expect(script, contains('if (editingLocked()) return'));
  });

  test('installation follows the enabled formats', () {
    expect(inlineMediaInstallsFor(['bold', 'link']), isFalse);
    expect(inlineMediaInstallsFor(['bold', 'image']), isTrue);
    expect(inlineMediaInstallsFor(['video']), isTrue);
  });
}
