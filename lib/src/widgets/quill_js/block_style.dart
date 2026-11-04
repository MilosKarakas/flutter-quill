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
  return <BlockStyleChoice>[
    BlockStyleChoice.paragraph,
    ..._headings,
    if (enabledFormats.contains('code-block')) BlockStyleChoice.preformatted,
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
