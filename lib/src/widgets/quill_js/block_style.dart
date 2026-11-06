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
  if (header is List) {
    if (_listHasDifferingValues(header)) return true;
    return header.isNotEmpty;
  }
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
  final header = format['header'];
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
