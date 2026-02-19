import 'dart:ui' show Color;

import 'package:flutter/material.dart';

import '../default_styles.dart';

/// Builds CSS for inline mark tags that avoids cross-mark overrides.
///
/// - `strong` keeps bold-related styling but excludes `font-style`
/// - `em` keeps italic-related styling but excludes `font-weight`
///
/// This prevents a custom italic style from resetting bold when text has both
/// `bold` and `italic` attributes (and vice versa).
String buildQuillJsInlineMarkCss(DefaultStyles styles) {
  final sb = StringBuffer();

  final strongCss = _inlineMarkTextStyleToCss(
    styles.bold,
    includeFontWeight: true,
    includeFontStyle: false,
  );
  if (strongCss.isNotEmpty) {
    sb.writeln('.ql-editor strong { $strongCss }');
  }

  final emCss = _inlineMarkTextStyleToCss(
    styles.italic,
    includeFontWeight: false,
    includeFontStyle: true,
  );
  if (emCss.isNotEmpty) {
    sb.writeln('.ql-editor em { $emCss }');
  }

  return sb.toString();
}

String _inlineMarkTextStyleToCss(
  TextStyle? style, {
  required bool includeFontWeight,
  required bool includeFontStyle,
}) {
  if (style == null) {
    return '';
  }

  final css = StringBuffer();
  final fontFamily = _fontFamilyToCss(style);
  if (fontFamily != null) {
    css.write('font-family: $fontFamily;');
  }

  final variationSettings = _fontVariationSettingsToCss(style);
  if (variationSettings != null) {
    css.write('font-variation-settings: $variationSettings;');
  }

  if (style.fontSize != null) {
    css.write('font-size: ${style.fontSize}px;');
  }

  if (includeFontWeight && style.fontWeight != null) {
    final w = style.fontWeight!;
    css.write('font-weight: ${(w.index + 1) * 100};');
  }

  if (includeFontStyle && style.fontStyle != null) {
    css.write(
      'font-style: ${style.fontStyle == FontStyle.italic ? 'italic' : 'normal'};',
    );
  }

  if (style.height != null) {
    css.write('line-height: ${style.height};');
  }

  if (style.letterSpacing != null) {
    css.write('letter-spacing: ${style.letterSpacing}px;');
  }

  if (style.color != null) {
    css.write('color: ${_colorToCss(style.color!)};');
  }

  if (style.decoration != null && style.decoration != TextDecoration.none) {
    if (style.decoration!.contains(TextDecoration.underline)) {
      css.write('text-decoration: underline;');
    } else if (style.decoration!.contains(TextDecoration.lineThrough)) {
      css.write('text-decoration: line-through;');
    }
  }

  return css.toString();
}

String _colorToCss(Color c) {
  final a = (c.alpha / 255).toStringAsFixed(3);
  return 'rgba(${c.red}, ${c.green}, ${c.blue}, $a)';
}

String _cssSingleQuoted(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('\'', r"\'");
  return '\'${escaped.trim()}\'';
}

String _cssDoubleQuoted(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

const _genericFontFamilies = <String>{
  'serif',
  'sans-serif',
  'monospace',
  'cursive',
  'fantasy',
  'system-ui',
  'ui-serif',
  'ui-sans-serif',
  'ui-monospace',
  'ui-rounded',
  'emoji',
  'math',
  'fangsong',
};

String _fontFamilyTokenToCss(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  if (_genericFontFamilies.contains(trimmed.toLowerCase())) {
    return trimmed.toLowerCase();
  }
  return _cssSingleQuoted(trimmed);
}

String? _fontFamilyToCss(TextStyle style) {
  final families = <String>[];
  final family = style.fontFamily;
  if (family != null && family.trim().isNotEmpty) {
    families.add(_fontFamilyTokenToCss(family));
  }
  final fallbacks = style.fontFamilyFallback;
  if (fallbacks != null) {
    for (final fallback in fallbacks) {
      final familyToken = _fontFamilyTokenToCss(fallback);
      if (familyToken.isNotEmpty) {
        families.add(familyToken);
      }
    }
  }
  if (families.isEmpty) {
    return null;
  }
  return families.join(', ');
}

String? _fontVariationSettingsToCss(TextStyle style) {
  final fontVariations = style.fontVariations;
  if (fontVariations == null || fontVariations.isEmpty) {
    return null;
  }
  return fontVariations
      .map(
        (variation) => '${_cssDoubleQuoted(variation.axis)} ${variation.value}',
      )
      .join(', ');
}
