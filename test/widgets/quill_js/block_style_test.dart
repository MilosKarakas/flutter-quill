import 'package:flutter_quill/src/widgets/quill_js/block_style.dart';
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
      expect(blockStyleIsMixed(const {'header': [1, 1]}), isTrue);
      expect(blockStyleIsMixed(const {'code-block': [true, false]}), isTrue);
      expect(blockStyleIsMixed(const {'code-block': [true, true]}), isFalse);
    });
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
}
