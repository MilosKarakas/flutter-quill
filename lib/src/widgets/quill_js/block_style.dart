enum BlockStyleChoice {
  paragraph,
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  preformatted,
}

extension BlockStyleChoiceLabel on BlockStyleChoice {
  String get label {
    switch (this) {
      case BlockStyleChoice.paragraph:
        return 'Paragraph';
      case BlockStyleChoice.heading1:
        return 'Heading 1';
      case BlockStyleChoice.heading2:
        return 'Heading 2';
      case BlockStyleChoice.heading3:
        return 'Heading 3';
      case BlockStyleChoice.heading4:
        return 'Heading 4';
      case BlockStyleChoice.heading5:
        return 'Heading 5';
      case BlockStyleChoice.heading6:
        return 'Heading 6';
      case BlockStyleChoice.preformatted:
        return 'Preformatted';
    }
  }
}

class BlockStyleCommand {
  const BlockStyleCommand(this.name, this.value);

  final String name;
  final Object value;

  @override
  bool operator ==(Object other) =>
      other is BlockStyleCommand && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

const List<BlockStyleChoice> _headings = <BlockStyleChoice>[
  BlockStyleChoice.heading1,
  BlockStyleChoice.heading2,
  BlockStyleChoice.heading3,
  BlockStyleChoice.heading4,
  BlockStyleChoice.heading5,
  BlockStyleChoice.heading6,
];

bool _listHasDifferingValues(List<dynamic> values) {
  if (values.length <= 1) return false;
  final first = values.first;
  for (var i = 1; i < values.length; i++) {
    if (values[i] != first) return true;
  }
  return false;
}

/// Whether Quill [format] represents a mixed block-style selection.
bool blockStyleIsMixed(Map<String, dynamic>? format) {
  if (format == null) return false;
  final header = format['header'];
  if (header is List && _listHasDifferingValues(header)) return true;
  final code = format['code-block'];
  if (code is List && _listHasDifferingValues(code)) return true;
  return false;
}

/// The block style of a selection from the formats of each text line in it.
///
/// Quill's range `getFormat` keeps only formats present on every line, so a
/// heading plus a plain line reports no `header` at all. Reading each line
/// shows the mix. Lines that are block embeds (an image or a video) carry
/// no block style and should not be passed in.
///
/// Returns `null` when [lineFormats] is empty, so the caller can fall back to
/// the range format.
({BlockStyleChoice style, bool mixed})? blockStyleForLines(
  Iterable<Map<String, dynamic>?> lineFormats,
) {
  BlockStyleChoice? first;
  for (final format in lineFormats) {
    final style = blockStyleFromFormat(format);
    if (first == null) {
      first = style;
    } else if (style != first) {
      return (style: BlockStyleChoice.paragraph, mixed: true);
    }
  }
  if (first == null) return null;
  return (style: first, mixed: false);
}

BlockStyleChoice blockStyleFromFormat(Map<String, dynamic>? format) {
  if (format == null) return BlockStyleChoice.paragraph;
  final code = format['code-block'];
  if (code != null && code != false) return BlockStyleChoice.preformatted;
  // A list item that is also a heading or Preformatted (`<li><h2>`).
  final listBlock = format['list-block'];
  if (listBlock is String && format['list'] != null) {
    if (listBlock == 'pre') return BlockStyleChoice.preformatted;
    final level = listBlock.startsWith('h')
        ? int.tryParse(listBlock.substring(1))
        : null;
    if (level != null && level >= 1 && level <= 6) {
      return _headings[level - 1];
    }
  }
  var header = format['header'];
  // Quill lists the values of a mixed range; equal values are one style.
  if (header is List && header.isNotEmpty && !_listHasDifferingValues(header)) {
    header = header.first;
  }
  if (header is num) {
    final level = header.round();
    if (header == level && level >= 1 && level <= 6) {
      return _headings[level - 1];
    }
  }
  return BlockStyleChoice.paragraph;
}

List<BlockStyleChoice> blockStyleMenu(List<String> enabledFormats) {
  final header = enabledFormats.contains('header');
  final code = enabledFormats.contains('code-block');
  return <BlockStyleChoice>[
    BlockStyleChoice.paragraph,
    if (header) ..._headings,
    if (code) BlockStyleChoice.preformatted,
  ];
}

/// The line attributes that apply [choice] to one line, or `null` when the
/// choice changes nothing there.
///
/// A list line keeps its bullet and records the style in `list-block`, so
/// it is saved as `<li><hN>` or `<li><pre>` the way the TinyMCE editor
/// writes it; Paragraph clears that style. Any other line takes `header`
/// or `code-block` as before. Requires `list` in [enabledFormats] for the
/// list behaviour, plus `header` for headings and `code-block` for
/// Preformatted.
Map<String, dynamic>? blockStyleLineAttributes({
  required BlockStyleChoice choice,
  required bool isListLine,
  required bool readOnly,
  required List<String> enabledFormats,
}) {
  if (readOnly) return null;
  final header = enabledFormats.contains('header');
  final code = enabledFormats.contains('code-block');
  final level = _headings.indexOf(choice) + 1;
  if (isListLine && enabledFormats.contains('list')) {
    switch (choice) {
      case BlockStyleChoice.paragraph:
        return const <String, dynamic>{'list-block': null};
      case BlockStyleChoice.preformatted:
        return code ? const <String, dynamic>{'list-block': 'pre'} : null;
      case BlockStyleChoice.heading1:
      case BlockStyleChoice.heading2:
      case BlockStyleChoice.heading3:
      case BlockStyleChoice.heading4:
      case BlockStyleChoice.heading5:
      case BlockStyleChoice.heading6:
        return header ? <String, dynamic>{'list-block': 'h$level'} : null;
    }
  }
  // Keys are applied in order, so a style is cleared before the new one is
  // set.
  switch (choice) {
    case BlockStyleChoice.paragraph:
      if (!header && !code) return null;
      return <String, dynamic>{
        if (header) 'header': null,
        if (code) 'code-block': null,
      };
    case BlockStyleChoice.preformatted:
      if (!code) return null;
      return <String, dynamic>{
        if (header) 'header': null,
        'code-block': true,
      };
    case BlockStyleChoice.heading1:
    case BlockStyleChoice.heading2:
    case BlockStyleChoice.heading3:
    case BlockStyleChoice.heading4:
    case BlockStyleChoice.heading5:
    case BlockStyleChoice.heading6:
      if (!header) return null;
      return <String, dynamic>{
        if (code) 'code-block': null,
        'header': level,
      };
  }
}

/// The format commands that apply [choice] to a line that is not a list
/// item, or an empty list when the choice is not available.
///
/// The editor applies styles per line with [blockStyleLineAttributes],
/// which keeps a list item's bullet; this list still says whether a choice
/// is available at all.
List<BlockStyleCommand> blockStyleCommands({
  required BlockStyleChoice choice,
  required bool readOnly,
  required List<String> enabledFormats,
}) {
  if (readOnly) return const <BlockStyleCommand>[];
  final header = enabledFormats.contains('header');
  final code = enabledFormats.contains('code-block');
  final list = enabledFormats.contains('list');
  switch (choice) {
    case BlockStyleChoice.paragraph:
      return <BlockStyleCommand>[
        if (header) const BlockStyleCommand('header', false),
        if (code) const BlockStyleCommand('code-block', false),
      ];
    case BlockStyleChoice.heading1:
    case BlockStyleChoice.heading2:
    case BlockStyleChoice.heading3:
    case BlockStyleChoice.heading4:
    case BlockStyleChoice.heading5:
    case BlockStyleChoice.heading6:
      if (!header) return const <BlockStyleCommand>[];
      final level = _headings.indexOf(choice) + 1;
      return <BlockStyleCommand>[
        if (code) const BlockStyleCommand('code-block', false),
        if (list) const BlockStyleCommand('list', false),
        BlockStyleCommand('header', level),
      ];
    case BlockStyleChoice.preformatted:
      if (!code) return const <BlockStyleCommand>[];
      return <BlockStyleCommand>[
        if (header) const BlockStyleCommand('header', false),
        if (list) const BlockStyleCommand('list', false),
        const BlockStyleCommand('code-block', true),
      ];
  }
}
