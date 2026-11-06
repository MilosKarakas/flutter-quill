/// JavaScript injected into the Quill iframe when `code-block` is enabled.
///
/// The bundled Quill is the full build, whose syntax module replaces the
/// `code-block` format with one that reports the line's language, or
/// `"plain"` when it has none. This editor records Preformatted as
/// `code-block: true`, so the registered format reports `true` for every
/// code line. A loaded line with a language string still displays as
/// Preformatted and is reported as `true`.
String plainCodeBlockIframeScript() => r'''
function registerPlainCodeBlock(Quill) {
  var CodeBlock = Quill.import('formats/code-block');
  if (!CodeBlock || CodeBlock.__reportsTrue) return;
  class PlainCodeBlock extends CodeBlock {
    static formats() {
      return true;
    }

    // The syntax block writes a truthy value to data-language, so applying
    // Preformatted to a code line would export <pre data-language="true">.
    // A line that is already a code block needs no change for a truthy value.
    format(name, value) {
      if (name === this.statics.blotName && value) return;
      super.format(name, value);
    }
  }
  PlainCodeBlock.blotName = 'code-block';
  PlainCodeBlock.__reportsTrue = true;
  Quill.register(PlainCodeBlock, true);
}
''';
