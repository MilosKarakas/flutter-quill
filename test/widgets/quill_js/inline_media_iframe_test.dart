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

  test('installation follows the enabled formats', () {
    expect(inlineMediaInstallsFor(['bold', 'link']), isFalse);
    expect(inlineMediaInstallsFor(['bold', 'image']), isTrue);
    expect(inlineMediaInstallsFor(['video']), isTrue);
  });
}
