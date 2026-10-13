import 'package:dart_quill_delta/dart_quill_delta.dart';

/// A URL found in plain text by a [LinkMatcher].
class LinkMatch {
  const LinkMatch({required this.start, required this.end, required this.url});

  final int start;

  /// Exclusive.
  final int end;

  /// The address the link points to.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is LinkMatch &&
      other.start == start &&
      other.end == end &&
      other.url == url;

  @override
  int get hashCode => Object.hash(start, end, url);

  @override
  String toString() => 'LinkMatch($start, $end, $url)';
}

/// Finds the URLs in [text] that should become links.
typedef LinkMatcher = List<LinkMatch> Function(String text);

/// Typed characters that end a word and trigger auto-linking.
const Set<String> autoLinkTriggers = {' ', '\n', '\t'};

const String _embed = '\uFFFC';

/// Returns whether the character at a document index carries a link.
bool Function(int index) linkedIndexTester(Delta document) {
  final ranges = <({int start, int end})>[];
  var offset = 0;
  for (final op in document.toList()) {
    if (!op.isInsert) continue;
    final length = op.length!;
    if (op.attributes?['link'] != null) {
      ranges.add((start: offset, end: offset + length));
    }
    offset += length;
  }
  return (index) => ranges.any((r) => index >= r.start && index < r.end);
}

/// Unlinked matches in the word that ends at [triggerOffset].
List<LinkMatch> linkBeforeTrigger(
  String text,
  int triggerOffset,
  LinkMatcher matcher,
  bool Function(int index) isLinked,
) {
  var start = triggerOffset;
  while (start > 0 && !_endsWord(text[start - 1])) {
    start--;
  }
  if (start == triggerOffset) return const [];
  return _unlinked(
    matcher(text.substring(start, triggerOffset)),
    start,
    isLinked,
  );
}

/// Unlinked matches that lie fully inside [start, end).
List<LinkMatch> linksInRange(
  String text,
  int start,
  int end,
  LinkMatcher matcher,
  bool Function(int index) isLinked,
) {
  if (start >= end) return const [];
  return _unlinked(matcher(text.substring(start, end)), start, isLinked);
}

/// The URL to put on [selectedText] instead of replacing it, or null when the
/// paste should behave normally.
String? linkForPasteOverSelection(
  String pastedText,
  String selectedText,
  LinkMatcher matcher,
) {
  if (selectedText.trim().isEmpty || selectedText.contains('\n')) return null;
  final url = _singleUrl(pastedText.trim(), matcher);
  if (url == null) return null;
  if (_singleUrl(selectedText.trim(), matcher) != null) return null;
  return url;
}

bool _endsWord(String char) =>
    autoLinkTriggers.contains(char) || char == _embed;

String? _singleUrl(String text, LinkMatcher matcher) {
  if (text.isEmpty) return null;
  final matches = matcher(text);
  if (matches.length != 1) return null;
  final match = matches.single;
  return match.start == 0 && match.end == text.length ? match.url : null;
}

List<LinkMatch> _unlinked(
  List<LinkMatch> matches,
  int offset,
  bool Function(int index) isLinked,
) {
  return [
    for (final match in matches)
      if (!_anyLinked(match.start + offset, match.end + offset, isLinked))
        LinkMatch(
          start: match.start + offset,
          end: match.end + offset,
          url: match.url,
        ),
  ];
}

bool _anyLinked(int start, int end, bool Function(int index) isLinked) {
  for (var i = start; i < end; i++) {
    if (isLinked(i)) return true;
  }
  return false;
}
