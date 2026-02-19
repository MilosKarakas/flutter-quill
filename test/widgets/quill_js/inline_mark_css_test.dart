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
        ),
        italic: TextStyle(
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w400,
        ),
      );

      final css = buildQuillJsInlineMarkCss(styles);
      final strongRule = _extractRule(css, '.ql-editor strong');
      final emRule = _extractRule(css, '.ql-editor em');

      expect(strongRule, contains('font-weight: 700;'));
      expect(strongRule, isNot(contains('font-style:')));
      expect(emRule, contains('font-style: italic;'));
      expect(emRule, isNot(contains('font-weight:')));
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
