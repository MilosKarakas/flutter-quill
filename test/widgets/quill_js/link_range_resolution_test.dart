import 'package:flutter_quill/src/widgets/quill_js/link_range_resolution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveQuillJsTappedLinkRange', () {
    test('prefers anchor-derived range when href matches', () {
      const anchorRange = (index: 20, length: 4);
      const selectionRange = (index: 5, length: 4);
      const hrefFallbackRange = (index: 1, length: 4);

      final resolved = resolveQuillJsTappedLinkRange(
        tappedHref: 'https://same.url',
        rangeFromAnchor: anchorRange,
        hrefFromAnchorRange: 'https://same.url',
        rangeFromSelection: selectionRange,
        hrefFromSelectionRange: 'https://same.url',
        rangeFromHrefFallback: hrefFallbackRange,
      );

      expect(resolved, anchorRange);
    });

    test('uses selection-derived range when anchor range href mismatches', () {
      const anchorRange = (index: 20, length: 4);
      const selectionRange = (index: 5, length: 4);
      const hrefFallbackRange = (index: 1, length: 4);

      final resolved = resolveQuillJsTappedLinkRange(
        tappedHref: 'https://target.url',
        rangeFromAnchor: anchorRange,
        hrefFromAnchorRange: 'https://other.url',
        rangeFromSelection: selectionRange,
        hrefFromSelectionRange: 'https://target.url',
        rangeFromHrefFallback: hrefFallbackRange,
      );

      expect(resolved, selectionRange);
    });

    test('falls back to href search when anchor and selection are invalid', () {
      const hrefFallbackRange = (index: 1, length: 4);

      final resolved = resolveQuillJsTappedLinkRange(
        tappedHref: 'https://target.url',
        rangeFromAnchor: null,
        hrefFromAnchorRange: null,
        rangeFromSelection: (index: 5, length: 4),
        hrefFromSelectionRange: 'https://other.url',
        rangeFromHrefFallback: hrefFallbackRange,
      );

      expect(resolved, hrefFallbackRange);
    });
  });
}
