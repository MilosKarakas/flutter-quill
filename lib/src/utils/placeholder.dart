import 'package:dart_quill_delta/dart_quill_delta.dart';

import '../models/documents/attribute.dart';
import '../models/documents/document.dart';

/// JSON-style escapes that callers may send either already-decoded (`\n`)
/// or as a two-character sequence (`\\n`).
const _placeholderEscapes = <String, String>{
  'n': '\n',
  'r': '\r',
  't': '\t',
  r'\': r'\',
  '"': '"',
};

/// Interprets JSON-style backslash escapes in [value].
///
/// A real newline (or tab / CR) is kept as-is. The two-character sequences
/// `\n`, `\t`, `\r`, `\\`, and `\"` are decoded to the same characters so
/// both forms produce identical placeholder text.
String decodePlaceholderEscapes(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (ch != r'\' || i + 1 >= value.length) {
      out.write(ch);
      continue;
    }
    final decoded = _placeholderEscapes[value[i + 1]];
    if (decoded == null) {
      out.write(ch);
      continue;
    }
    out.write(decoded);
    i++;
  }
  return out.toString();
}

/// Builds the display-only document used when the editor is empty.
Document documentFromPlaceholder(String placeholder) {
  return Document.fromDelta(
    Delta()..insert(
      '${decodePlaceholderEscapes(placeholder)}\n',
      <String, dynamic>{Attribute.placeholder.key: true},
    ),
  );
}
