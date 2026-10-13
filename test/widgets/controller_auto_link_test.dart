import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

List<LinkMatch> fakeMatcher(String text) => [
  for (final m in RegExp(
    r'(?:https?://|www\.)\S+|\b[a-z]+\.ch\b',
  ).allMatches(text))
    LinkMatch(
      start: m.start,
      end: m.end,
      url: m[0]!.startsWith('http') ? m[0]! : 'https://${m[0]}',
    ),
];

QuillController controllerWith(String text, {LinkMatcher? matcher}) {
  return QuillController(
    document: Document.fromDelta(Delta()..insert('$text\n')),
    selection: TextSelection.collapsed(offset: text.length),
  )..linkMatcher = matcher;
}

void typeText(QuillController c, String text) {
  for (final char in text.split('')) {
    final i = c.selection.baseOffset;
    c.replaceText(i, 0, char, TextSelection.collapsed(offset: i + 1));
  }
}

void backspace(QuillController c) {
  final i = c.selection.baseOffset;
  c.replaceText(i - 1, 1, '', TextSelection.collapsed(offset: i - 1));
}

Object? linkAt(QuillController c, int index) =>
    c.document.collectStyle(index, 1).attributes[Attribute.link.key]?.value;

void main() {
  group('typing', () {
    test('space links the word before it', () {
      final c = controllerWith('see klapp.ch', matcher: fakeMatcher);
      typeText(c, ' ');
      expect(linkAt(c, 4), 'https://klapp.ch');
      expect(linkAt(c, 11), 'https://klapp.ch');
      expect(linkAt(c, 3), isNull);
      expect(linkAt(c, 12), isNull);
      expect(c.document.toPlainText(), 'see klapp.ch \n');
    });

    test('enter and tab also trigger', () {
      final enter = controllerWith('klapp.ch', matcher: fakeMatcher);
      typeText(enter, '\n');
      expect(linkAt(enter, 0), 'https://klapp.ch');
      final tab = controllerWith('klapp.ch', matcher: fakeMatcher);
      typeText(tab, '\t');
      expect(linkAt(tab, 0), 'https://klapp.ch');
    });

    test('built-in auto-link rules are off when a matcher is set', () {
      final c = controllerWith('', matcher: (_) => const []);
      typeText(c, 'https://a.com ');
      for (var i = 0; i < 13; i++) {
        expect(linkAt(c, i), isNull);
      }
    });

    test('without a matcher the built-in rules still link', () {
      final c = controllerWith('');
      typeText(c, 'https://a.com ');
      expect(linkAt(c, 0), isNotNull);
    });

    test('matcher survives a document replacement', () {
      final c = controllerWith('', matcher: fakeMatcher)
        ..document = Document.fromDelta(Delta()..insert('klapp.ch\n'));
      c.updateSelection(
        const TextSelection.collapsed(offset: 8),
        ChangeSource.LOCAL,
      );
      typeText(c, ' ');
      expect(linkAt(c, 0), 'https://klapp.ch');
    });
  });

  group('backspace after auto-link', () {
    test('first backspace removes the link only, second deletes', () {
      final c = controllerWith('see klapp.ch', matcher: fakeMatcher);
      typeText(c, ' ');
      backspace(c);
      expect(c.document.toPlainText(), 'see klapp.ch \n');
      expect(linkAt(c, 4), isNull);
      expect(c.selection, const TextSelection.collapsed(offset: 13));
      backspace(c);
      expect(c.document.toPlainText(), 'see klapp.ch\n');
    });

    test('any other edit forgets the auto-link', () {
      final c = controllerWith('see klapp.ch', matcher: fakeMatcher);
      typeText(c, ' x');
      backspace(c);
      expect(c.document.toPlainText(), 'see klapp.ch \n');
      expect(linkAt(c, 4), 'https://klapp.ch');
    });

    test('a selection change forgets the auto-link', () {
      final c = controllerWith('see klapp.ch', matcher: fakeMatcher);
      typeText(c, ' ');
      c
        ..updateSelection(
          const TextSelection.collapsed(offset: 2),
          ChangeSource.LOCAL,
        )
        ..updateSelection(
          const TextSelection.collapsed(offset: 13),
          ChangeSource.LOCAL,
        );
      backspace(c);
      expect(c.document.toPlainText(), 'see klapp.ch\n');
      expect(linkAt(c, 4), 'https://klapp.ch');
    });
  });

  group('paste', () {
    test('multi-character insert links urls in the inserted range', () {
      final c = controllerWith('', matcher: fakeMatcher);
      c.replaceText(
        0,
        0,
        'go to https://x.ch now',
        const TextSelection.collapsed(offset: 22),
      );
      expect(linkAt(c, 6), 'https://x.ch');
      expect(linkAt(c, 0), isNull);
    });

    test('url pasted over a selection links the selection', () {
      final c = controllerWith('the calendar', matcher: fakeMatcher)
        ..updateSelection(
          const TextSelection(baseOffset: 4, extentOffset: 12),
          ChangeSource.LOCAL,
        );
      c.replaceText(
        4,
        8,
        'https://x.ch/cal',
        const TextSelection.collapsed(offset: 20),
      );
      expect(c.document.toPlainText(), 'the calendar\n');
      expect(linkAt(c, 4), 'https://x.ch/cal');
      expect(c.selection, const TextSelection.collapsed(offset: 12));
    });

    test('linkSelectionWithPastedText', () {
      final c = controllerWith('the calendar', matcher: fakeMatcher)
        ..updateSelection(
          const TextSelection(baseOffset: 4, extentOffset: 12),
          ChangeSource.LOCAL,
        );
      expect(c.linkSelectionWithPastedText(' https://x.ch/cal '), isTrue);
      expect(linkAt(c, 4), 'https://x.ch/cal');
      expect(c.linkSelectionWithPastedText('not a url'), isFalse);
    });

    test('autoLinkRange links only inside the range', () {
      final c = controllerWith('klapp.ch and www.b.ch', matcher: fakeMatcher)
        ..autoLinkRange(9, 21);
      expect(linkAt(c, 0), isNull);
      expect(linkAt(c, 13), 'https://www.b.ch');
    });
  });
}
