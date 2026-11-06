import 'package:flutter_quill/src/widgets/quill_js/block_style.dart';
import 'package:flutter_quill/src/widgets/quill_js/list_block_iframe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blockStyleFromFormat', () {
    test('uses paragraph when there is no block', () {
      expect(blockStyleFromFormat(null), BlockStyleChoice.paragraph);
      expect(blockStyleFromFormat(const {}), BlockStyleChoice.paragraph);
      expect(
        blockStyleFromFormat(const {'list': 'bullet'}),
        BlockStyleChoice.paragraph,
      );
      expect(blockStyleFromFormat(const {'header': 0}), BlockStyleChoice.paragraph);
      expect(blockStyleFromFormat(const {'header': 7}), BlockStyleChoice.paragraph);
      expect(blockStyleFromFormat(const {'header': 1.5}), BlockStyleChoice.paragraph);
      expect(blockStyleFromFormat(const {'header': '1'}), BlockStyleChoice.paragraph);
      expect(
        blockStyleFromFormat(const {'code-block': false}),
        BlockStyleChoice.paragraph,
      );
    });

    test('reads a numeric heading and lets code-block win', () {
      expect(blockStyleFromFormat(const {'header': 1}), BlockStyleChoice.heading1);
      expect(blockStyleFromFormat(const {'header': 1.0}), BlockStyleChoice.heading1);
      expect(blockStyleFromFormat(const {'header': 6}), BlockStyleChoice.heading6);
      expect(
        blockStyleFromFormat(const {'code-block': true}),
        BlockStyleChoice.preformatted,
      );
      expect(
        blockStyleFromFormat(const {'code-block': 'plain'}),
        BlockStyleChoice.preformatted,
      );
      expect(
        blockStyleFromFormat(const {'code-block': true, 'header': 2}),
        BlockStyleChoice.preformatted,
      );
    });
  });

  group('blockStyleMenu', () {
    test('filters items by enabled header and code-block formats', () {
      expect(
        blockStyleMenu(const ['header']),
        [
          BlockStyleChoice.paragraph,
          BlockStyleChoice.heading1,
          BlockStyleChoice.heading2,
          BlockStyleChoice.heading3,
          BlockStyleChoice.heading4,
          BlockStyleChoice.heading5,
          BlockStyleChoice.heading6,
        ],
      );
      expect(
        blockStyleMenu(const ['code-block']),
        [BlockStyleChoice.paragraph, BlockStyleChoice.preformatted],
      );
      expect(
        blockStyleMenu(const ['header', 'code-block']).last,
        BlockStyleChoice.preformatted,
      );
    });
  });

  group('blockStyleIsMixed', () {
    test('detects mixed header and code-block selections', () {
      expect(blockStyleIsMixed(null), isFalse);
      expect(blockStyleIsMixed(const {'header': 1}), isFalse);
      expect(blockStyleIsMixed(const {'header': [1, 2]}), isTrue);
      expect(blockStyleIsMixed(const {'header': [1, 1]}), isFalse);
      expect(blockStyleIsMixed(const {'code-block': [true, false]}), isTrue);
      expect(blockStyleIsMixed(const {'code-block': [true, true]}), isFalse);
    });
  });

  test('an equal-valued header list reads as that heading', () {
    expect(
      blockStyleFromFormat(const {'header': [2, 2]}),
      BlockStyleChoice.heading2,
    );
    expect(
      blockStyleFromFormat(const {'header': [1, 2]}),
      BlockStyleChoice.paragraph,
    );
  });

  group('blockStyleForLines', () {
    test('is null for no text lines, so the caller keeps the range format', () {
      expect(blockStyleForLines(const []), isNull);
    });

    test('lines with one style report it and are not mixed', () {
      final result = blockStyleForLines(const [
        {'header': 2},
        {'header': 2, 'indent': 1},
      ]);
      expect(result!.style, BlockStyleChoice.heading2);
      expect(result.mixed, isFalse);
    });

    test('a heading with a plain line is mixed', () {
      final result = blockStyleForLines(const [
        {'header': 1},
        null,
      ]);
      expect(result!.mixed, isTrue);
      expect(result.style, BlockStyleChoice.paragraph);
    });

    test('a heading with Preformatted is mixed', () {
      final result = blockStyleForLines(const [
        {'header': 3},
        {'code-block': true},
      ]);
      expect(result!.mixed, isTrue);
    });

    test('a list line and a plain line are both Paragraph', () {
      final result = blockStyleForLines(const [
        {'list': 'bullet'},
        <String, dynamic>{},
      ]);
      expect(result!.style, BlockStyleChoice.paragraph);
      expect(result.mixed, isFalse);
    });

    test('code lines reported as a language string are Preformatted', () {
      final result = blockStyleForLines(const [
        {'code-block': 'plain'},
        {'code-block': true},
      ]);
      expect(result!.style, BlockStyleChoice.preformatted);
      expect(result.mixed, isFalse);
    });
  });

  group('blockStyleCommands', () {
    const enabled = ['header', 'code-block', 'list'];

    test('a heading sets that level and clears code-block and list', () {
      const choices = <int, BlockStyleChoice>{
        1: BlockStyleChoice.heading1,
        2: BlockStyleChoice.heading2,
        3: BlockStyleChoice.heading3,
        4: BlockStyleChoice.heading4,
        5: BlockStyleChoice.heading5,
        6: BlockStyleChoice.heading6,
      };
      for (final entry in choices.entries) {
        expect(
          blockStyleCommands(
            choice: entry.value,
            readOnly: false,
            enabledFormats: enabled,
          ),
          [
            const BlockStyleCommand('code-block', false),
            const BlockStyleCommand('list', false),
            BlockStyleCommand('header', entry.key),
          ],
        );
      }
    });

    test('preformatted writes code-block true and clears header and list', () {
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.preformatted,
          readOnly: false,
          enabledFormats: enabled,
        ),
        const [
          BlockStyleCommand('header', false),
          BlockStyleCommand('list', false),
          BlockStyleCommand('code-block', true),
        ],
      );
    });

    test('paragraph clears header and code-block and leaves list', () {
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.paragraph,
          readOnly: false,
          enabledFormats: enabled,
        ),
        const [
          BlockStyleCommand('header', false),
          BlockStyleCommand('code-block', false),
        ],
      );
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.paragraph,
          readOnly: false,
          enabledFormats: const ['header', 'list'],
        ),
        const [BlockStyleCommand('header', false)],
      );
    });

    test('a missing primary format or a read-only editor changes nothing', () {
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.heading4,
          readOnly: false,
          enabledFormats: const ['code-block', 'list'],
        ),
        isEmpty,
      );
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.preformatted,
          readOnly: false,
          enabledFormats: const ['header', 'list'],
        ),
        isEmpty,
      );
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.heading1,
          readOnly: true,
          enabledFormats: enabled,
        ),
        isEmpty,
      );
    });

    test('a heading skips a block format that is not enabled', () {
      expect(
        blockStyleCommands(
          choice: BlockStyleChoice.heading2,
          readOnly: false,
          enabledFormats: const ['header', 'code-block'],
        ),
        const [
          BlockStyleCommand('code-block', false),
          BlockStyleCommand('header', 2),
        ],
      );
    });
  });

  group('list items with a block style', () {
    const all = ['list', 'header', 'code-block'];

    test('a list item with list-block reads as that style', () {
      expect(
        blockStyleFromFormat(const {'list': 'bullet', 'list-block': 'h2'}),
        BlockStyleChoice.heading2,
      );
      expect(
        blockStyleFromFormat(const {'list': 'ordered', 'list-block': 'pre'}),
        BlockStyleChoice.preformatted,
      );
      expect(
        blockStyleFromFormat(const {'list': 'bullet'}),
        BlockStyleChoice.paragraph,
      );
      // Only on a list line.
      expect(
        blockStyleFromFormat(const {'list-block': 'h2'}),
        BlockStyleChoice.paragraph,
      );
    });

    test('on a list line the choice keeps the bullet', () {
      Map<String, dynamic>? attrs(BlockStyleChoice c) =>
          blockStyleLineAttributes(
            choice: c,
            isListLine: true,
            readOnly: false,
            enabledFormats: all,
          );
      expect(attrs(BlockStyleChoice.heading3), {'list-block': 'h3'});
      expect(attrs(BlockStyleChoice.preformatted), {'list-block': 'pre'});
      expect(attrs(BlockStyleChoice.paragraph), {'list-block': null});
    });

    test('on any other line the choice is header or code-block', () {
      Map<String, dynamic>? attrs(BlockStyleChoice c) =>
          blockStyleLineAttributes(
            choice: c,
            isListLine: false,
            readOnly: false,
            enabledFormats: all,
          );
      expect(attrs(BlockStyleChoice.heading1), {'code-block': null, 'header': 1});
      expect(attrs(BlockStyleChoice.preformatted), {'header': null, 'code-block': true});
      expect(attrs(BlockStyleChoice.paragraph), {'header': null, 'code-block': null});
    });

    test('a missing format or a read-only editor changes nothing', () {
      expect(
        blockStyleLineAttributes(
          choice: BlockStyleChoice.preformatted,
          isListLine: true,
          readOnly: false,
          enabledFormats: const ['list', 'header'],
        ),
        isNull,
      );
      expect(
        blockStyleLineAttributes(
          choice: BlockStyleChoice.heading2,
          isListLine: true,
          readOnly: true,
          enabledFormats: all,
        ),
        isNull,
      );
    });

    test('list-block values follow the enabled formats', () {
      expect(listBlockValuesFor(const ['header']), isEmpty);
      expect(listBlockValuesFor(const ['list']), isEmpty);
      expect(listBlockValuesFor(const ['list', 'code-block']), ['pre']);
      expect(
        listBlockValuesFor(const ['list', 'header', 'code-block']),
        ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre'],
      );
    });

    test('list-block CSS keeps the list indent and marker of a plain item', () {
      final css = listBlockCss(markerFontFamily: 'Helvetica');
      // Padding and marker are in em of the item, so they are divided by
      // the item's scale: an h1 item (2em) pads 0.75em = 1.5em of the list.
      expect(css, contains('li[data-list-block="h1"] { font-size: 2em; }'));
      expect(css, contains('li[data-list-block="h1"] { padding-left: 0.75em; }'));
      expect(css, contains('li[data-list-block="h1"] > .ql-ui { font-size: 0.5em; }'));
      expect(
        css,
        contains('li[data-list-block="h1"].ql-indent-1:not(.ql-direction-rtl) '
            '{ padding-left: 2.25em; }'),
      );
      expect(css, contains('position: static'));
      expect(css, contains('font-family: Helvetica;'));
      expect(css, isNot(contains('li[data-list-block="pre"] { font-size')));
    });

    test('the list-block script registers the format and its bindings', () {
      final script = listBlockIframeScript();
      expect(script, contains('function registerListBlock(Quill, values)'));
      expect(script, contains('function installListBlock(quill)'));
      expect(script, contains("addMatcher('ol, ul'"));
    });
  });
}
