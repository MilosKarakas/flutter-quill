import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/src/utils/placeholder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodePlaceholderEscapes', () {
    test('keeps a real newline', () {
      expect(decodePlaceholderEscapes('Hello\nWorld'), 'Hello\nWorld');
    });

    test('decodes a backslash-n sequence to a newline', () {
      expect(decodePlaceholderEscapes(r'Hello\nWorld'), 'Hello\nWorld');
    });

    test('keeps a real tab and decodes a backslash-t sequence', () {
      expect(decodePlaceholderEscapes('Hello\tWorld'), 'Hello\tWorld');
      expect(decodePlaceholderEscapes(r'Hello\tWorld'), 'Hello\tWorld');
    });

    test('keeps a real CR and decodes a backslash-r sequence', () {
      expect(decodePlaceholderEscapes('Hello\rWorld'), 'Hello\rWorld');
      expect(decodePlaceholderEscapes(r'Hello\rWorld'), 'Hello\rWorld');
    });

    test('decodes escaped quotes and backslashes', () {
      expect(decodePlaceholderEscapes(r'Say \"hi\"'), 'Say "hi"');
      expect(decodePlaceholderEscapes(r'C:\\path'), r'C:\path');
    });

    test('leaves unknown escapes intact', () {
      expect(decodePlaceholderEscapes(r'Hello\xWorld'), r'Hello\xWorld');
    });

    test('decodes mixed real and escaped newlines', () {
      expect(decodePlaceholderEscapes('a\nb\\nc'), 'a\nb\nc');
    });

    test('leaves a trailing lone backslash intact', () {
      expect(decodePlaceholderEscapes(r'Hello\'), r'Hello\');
    });
  });

  group('documentFromPlaceholder', () {
    test('builds a placeholder document from a real newline', () {
      final doc = documentFromPlaceholder('Hello\nWorld');
      expect(doc.toPlainText(), 'Hello\nWorld\n');
      expect(
        doc.toDelta().first.attributes?[Attribute.placeholder.key],
        isTrue,
      );
    });

    test('builds the same document from a backslash-n sequence', () {
      final fromEscape = documentFromPlaceholder(r'Hello\nWorld');
      final fromNewline = documentFromPlaceholder('Hello\nWorld');
      expect(fromEscape.toPlainText(), fromNewline.toPlainText());
      expect(fromEscape.toDelta().toJson(), fromNewline.toDelta().toJson());
    });

    test('always ends the insert with a newline', () {
      expect(
        documentFromPlaceholder('Add content').toPlainText(),
        'Add content\n',
      );
    });

    test('empty placeholder is a single newline marked as placeholder', () {
      final doc = documentFromPlaceholder('');
      expect(doc.toPlainText(), '\n');
      expect(
        doc.toDelta().first.attributes?[Attribute.placeholder.key],
        isTrue,
      );
    });
  });
}
