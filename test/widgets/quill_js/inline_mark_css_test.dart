import 'package:flutter/material.dart';
import 'package:flutter_quill/src/widgets/default_styles.dart';
import 'package:flutter_quill/src/widgets/quill_js/inline_mark_css.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildQuillJsInlineMarkCss', () {
    test('does not let italic style reset bold weight', () {
      const styles = DefaultStyles(
        bold: TextStyle(
          fontWeight: FontWeight.w700,
          fontStyle: FontStyle.normal,
          fontVariations: [FontVariation('wght', 700)],
        ),
        italic: TextStyle(
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w400,
          fontVariations: [
            FontVariation('wght', 400),
            FontVariation('wdth', 95),
          ],
        ),
      );

      final css = buildQuillJsInlineMarkCss(styles);
      final strongRule = _extractRule(css, '.ql-editor strong');
      final emRule = _extractRule(css, '.ql-editor em');

      expect(strongRule, contains('font-weight: 700;'));
      expect(strongRule, contains('"wght" 700.0'));
      expect(strongRule, isNot(contains('font-style:')));
      expect(emRule, contains('font-style: italic;'));
      expect(emRule, isNot(contains('font-weight:')));
      expect(emRule, isNot(contains('"wght"')));
      expect(emRule, contains('"wdth" 95.0'));
    });

    test('marks inside headings keep the heading size and line height', () {
      const styles = DefaultStyles(
        bold: TextStyle(fontSize: 16, height: 1.5, fontWeight: FontWeight.bold),
        italic: TextStyle(fontSize: 16, height: 1.5, fontStyle: FontStyle.italic),
      );
      final css = buildQuillJsInlineMarkCss(styles);
      expect(_extractRule(css, '.ql-editor strong'), contains('font-size: 16.0px;'));
      expect(
        css,
        contains(
          '.ql-editor :is(h1, h2, h3, h4, h5, h6, li[data-list-block]) '
          ':is(strong, em) { font-size: inherit; line-height: inherit; }',
        ),
      );
    });

    test('adds no heading rule when the marks set no size', () {
      const styles = DefaultStyles(
        bold: TextStyle(fontWeight: FontWeight.bold),
      );
      expect(buildQuillJsInlineMarkCss(styles), isNot(contains(':is(')));
    });

    test('keeps non-conflicting inline properties', () {
      const styles = DefaultStyles(
        italic: TextStyle(
          fontStyle: FontStyle.italic,
          color: Colors.red,
          letterSpacing: 0.5,
          decoration: TextDecoration.underline,
        ),
      );

      final css = buildQuillJsInlineMarkCss(styles);
      final emRule = _extractRule(css, '.ql-editor em');

      expect(emRule, contains('font-style: italic;'));
      expect(emRule, contains('letter-spacing: 0.5px;'));
      expect(emRule, contains('color: rgba('));
      expect(emRule, contains('text-decoration: underline;'));
    });
  });
}

String _extractRule(String css, String selector) {
  final match = RegExp(
    '${RegExp.escape(selector)} \\{([^}]*)\\}',
  ).firstMatch(css);
  expect(match, isNotNull, reason: 'Missing selector: $selector');
  return match!.group(1)!;
}
