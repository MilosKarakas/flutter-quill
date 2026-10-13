import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/src/models/auto_link.dart';
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

bool notLinked(int _) => false;

void main() {
  group('linkBeforeTrigger', () {
    test('links the word before the trigger', () {
      const text = 'see klapp.ch ';
      expect(linkBeforeTrigger(text, 12, fakeMatcher, notLinked), [
        const LinkMatch(start: 4, end: 12, url: 'https://klapp.ch'),
      ]);
    });

    test('word starts after newline, tab or embed', () {
      expect(
        linkBeforeTrigger('a\nklapp.ch ', 10, fakeMatcher, notLinked).single,
        const LinkMatch(start: 2, end: 10, url: 'https://klapp.ch'),
      );
      expect(
        linkBeforeTrigger('\uFFFCklapp.ch ', 9, fakeMatcher, notLinked).single,
        const LinkMatch(start: 1, end: 9, url: 'https://klapp.ch'),
      );
    });

    test('returns nothing for an empty word or no match', () {
      expect(linkBeforeTrigger('a  ', 2, fakeMatcher, notLinked), isEmpty);
      expect(linkBeforeTrigger('hello ', 5, fakeMatcher, notLinked), isEmpty);
    });

    test('skips matches that already carry a link', () {
      expect(
        linkBeforeTrigger('see klapp.ch ', 12, fakeMatcher, (i) => i == 6),
        isEmpty,
      );
    });
  });

  group('linksInRange', () {
    test('links every unlinked match inside the range, with offsets', () {
      const text = 'x go https://a.ch and www.b.ch y';
      expect(linksInRange(text, 2, 30, fakeMatcher, notLinked), [
        const LinkMatch(start: 5, end: 17, url: 'https://a.ch'),
        const LinkMatch(start: 22, end: 30, url: 'https://www.b.ch'),
      ]);
    });

    test('ignores text outside the range', () {
      expect(
        linksInRange('klapp.ch hi', 8, 11, fakeMatcher, notLinked),
        isEmpty,
      );
    });
  });

  group('linkForPasteOverSelection', () {
    test('returns the url when the pasted text is exactly one url', () {
      expect(
        linkForPasteOverSelection(
          ' https://a.ch/x \n',
          'calendar',
          fakeMatcher,
        ),
        'https://a.ch/x',
      );
    });

    test('null when the paste is not exactly one url', () {
      expect(
        linkForPasteOverSelection('see https://a.ch', 'cal', fakeMatcher),
        isNull,
      );
      expect(
        linkForPasteOverSelection(
          'https://a.ch https://b.ch',
          'cal',
          fakeMatcher,
        ),
        isNull,
      );
    });

    test('null for empty, blank, multi-line or url selections', () {
      expect(
        linkForPasteOverSelection('https://a.ch', '', fakeMatcher),
        isNull,
      );
      expect(
        linkForPasteOverSelection('https://a.ch', '  ', fakeMatcher),
        isNull,
      );
      expect(
        linkForPasteOverSelection('https://a.ch', 'a\nb', fakeMatcher),
        isNull,
      );
      expect(
        linkForPasteOverSelection('https://a.ch', 'klapp.ch', fakeMatcher),
        isNull,
      );
    });
  });

  test('linkedIndexTester reports linked characters', () {
    final delta = Delta()
      ..insert('ab')
      ..insert('cd', {'link': 'https://x.ch'})
      ..insert('e\n');
    final isLinked = linkedIndexTester(delta);
    expect(
      [for (var i = 0; i < 6; i++) isLinked(i)],
      [false, false, true, true, false, false],
    );
  });
}
