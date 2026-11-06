import 'package:flutter_quill/src/widgets/quill_js/code_block_iframe.dart';
import 'package:flutter_quill/src/widgets/quill_js/inline_media_iframe.dart';
import 'package:flutter_test/flutter_test.dart';

// These tests only check that the injected scripts contain the expected
// wiring. They cannot run the JavaScript; the behaviour is checked in a real
// browser by tool/quill_js_browser_checks (see its README).
void main() {
  test('the script registers both blots and the drop and resize hooks', () {
    final script = inlineMediaIframeScript();
    expect(script, contains('formats/image'));
    expect(script, contains('formats/video'));
    expect(script, contains('registerInlineMedia'));
    expect(script, contains('dragover'));
    expect(script, contains('__inlineMediaResize'));
    expect(script, contains('createImageBitmap'));
    expect(script, contains('canvas.toBlob'));
    expect(script, contains('finishDrag'));
    expect(script, contains('ResizeObserver'));
    expect(script, contains('stopImmediatePropagation'));
    expect(script, contains("e.key === 'Backspace' || e.key === 'Delete'"));
    expect(script, contains("quill.on('editor-change'"));
    expect(
      script,
      contains(
        'if (state.overlay && !selectionIsOnEmbed(first, state.index)) hideResizeOverlay()',
      ),
    );
    expect(script, contains('repairCaretAtEmbed(first)'));
    expect(script, contains('showDropCaret(idx)'));
    expect(script, contains("root.addEventListener('drop', endFileDrag, true)"));
    expect(
      script,
      contains("doc.addEventListener('selectionchange', scheduleCaretRepair)"),
    );
    expect(script, contains('.ql-media-selected { caret-color: transparent; }'));
    expect(script, contains('changeEditsContent(first)'));
    expect(script, contains("root.addEventListener('pointerdown'"));
    expect(script, contains("if (!nextLineEmpty) quill.insertText(index + 1, '\\n', 'user')"));
    expect(script, contains('blots/block/embed'));
    expect(script, contains('class CustomImageBlot extends BlockEmbed'));
    expect(script, contains("if (isHttpVideoSource(value)) node.setAttribute('src', value)"));
    expect(script, contains('data-src'));
    expect(script, contains('blob:'));
    expect(script, contains('ql-media-editing'));
    expect(script, contains('if (!blot) return'));
    expect(script, contains('window.setTimeout(onLoad, 0)'));
    expect(script, contains('function indexFromPointNode'));
    expect(script, contains('node.childNodes[offset]'));
    expect(script, contains('getBoundingClientRect'));
    expect(script, contains('embedFromEvent(e)'));
    expect(script, isNot(contains('selectionTouches')));
    expect(script, isNot(contains('node = embedNodeAtIndex(index)')));
    expect(script, contains("if (handle === 'n' || handle === 's')"));
    expect(script, contains('function editingLocked()'));
    expect(script, contains('quill.isEnabled && !quill.isEnabled()'));
    expect(script, contains('__inlineMediaSetReadOnly'));
    expect(script, contains('quill.scroll.batchStart'));
    expect(script, contains('touchAction'));
    expect(script, contains("quill.setSelection(hit.index, 0, 'user')"));
    expect(script, contains('if (editingLocked()) return'));
    expect(script.contains('__inlineMediaApplyAttributes'), isFalse);
    expect(script.contains('toDataURL'), isFalse);
  });

  test('the script hands processed images to Dart as a Blob, not a URL', () {
    final script = inlineMediaIframeScript();
    // A URL made in the iframe is revoked when that editor unloads.
    expect(script, isNot(contains('URL.createObjectURL(result.blob)')));
    expect(script, contains('blob: result.blob'));
    expect(script, contains('image.blob,'));
  });

  test('the paste rule is wired to visibleHtmlText', () {
    final script = inlineMediaIframeScript();
    expect(script, contains('function visibleHtmlText(html)'));
    expect(script, contains('? !visibleHtmlText(html)'));
  });

  test('onResize is called with the previewed size', () {
    final script = inlineMediaIframeScript();
    expect(script, contains('options.onResize(d.index, size.width, size.height)'));
  });

  test('the video sandbox is wired to needsStrictVideoSandbox', () {
    final script = inlineMediaIframeScript();
    expect(script, contains('function needsStrictVideoSandbox(value)'));
    expect(script, contains("(needsStrictVideoSandbox(value) ? '' : ' allow-same-origin')"));
  });

  test('the code-block script registers a format reporting true', () {
    final script = plainCodeBlockIframeScript();
    expect(script, contains('function registerPlainCodeBlock(Quill)'));
    expect(script, contains("Quill.import('formats/code-block')"));
    expect(script, contains('return true;'));
  });

  test('installation follows the enabled formats', () {
    expect(inlineMediaInstallsFor(['bold', 'link']), isFalse);
    expect(inlineMediaInstallsFor(['bold', 'image']), isTrue);
    expect(inlineMediaInstallsFor(['video']), isTrue);
  });
}
