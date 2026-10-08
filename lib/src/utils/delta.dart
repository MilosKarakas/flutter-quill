import 'dart:math' as math;
import 'dart:ui';

import '../models/documents/attribute.dart';
import '../models/documents/nodes/node.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';

// Diff between two texts - old text and new text
class Diff {
  Diff(this.start, this.deleted, this.inserted);

  // Start index in old text at which changes begin.
  final int start;

  /// The deleted text
  final String deleted;

  // The inserted text
  final String inserted;

  @override
  String toString() {
    return 'Diff[$start, "$deleted", "$inserted"]';
  }
}

/* Get diff operation between old text and new text */
Diff getDiff(String oldText, String newText, int cursorPosition) {
  var end = oldText.length;
  final delta = newText.length - end;
  for (
    final limit = math.max(0, cursorPosition - delta);
    end > limit && oldText[end - 1] == newText[end + delta - 1];
    end--
  ) {}
  var start = 0;
  for (
    final startLimit = cursorPosition - math.max(0, delta);
    start < startLimit && oldText[start] == newText[start];
    start++
  ) {}
  final deleted = (start >= end) ? '' : oldText.substring(start, end);
  final inserted = newText.substring(start, end + delta);
  return Diff(start, deleted, inserted);
}

int getPositionDelta(Delta user, Delta actual) {
  if (actual.isEmpty) {
    return 0;
  }

  final userItr = DeltaIterator(user);
  final actualItr = DeltaIterator(actual);
  var diff = 0;
  while (userItr.hasNext || actualItr.hasNext) {
    final length = math.min(userItr.peekLength(), actualItr.peekLength());
    final userOperation = userItr.next(length);
    final actualOperation = actualItr.next(length);
    if (userOperation.length != actualOperation.length) {
      throw 'userOp ${userOperation.length} does not match actualOp '
          '${actualOperation.length}';
    }
    if (userOperation.key == actualOperation.key) {
      continue;
    } else if (userOperation.isInsert && actualOperation.isRetain) {
      diff -= userOperation.length!;
    } else if (userOperation.isDelete && actualOperation.isRetain) {
      diff += userOperation.length!;
    } else if (userOperation.isRetain && actualOperation.isInsert) {
      String? operationTxt = '';
      if (actualOperation.data is String) {
        operationTxt = actualOperation.data as String?;
      }
      if (operationTxt!.startsWith('\n')) {
        continue;
      }
      diff += actualOperation.length!;
    }
  }
  return diff;
}

/// Returns the part of [document] between [start] and [end] for copying.
///
/// Block formats (lists, headers, ...) are stored on the newline that ends a
/// line, so a multi-line selection that stops before the last line's newline
/// would lose that line's block format. In that case the newline is appended
/// with the line's block attributes. Single-line selections are left as-is.
Delta sliceDeltaForCopy(Delta document, int start, int end) {
  final slice = document.slice(start, end);
  final ops = slice.toList();
  if (ops.isEmpty) {
    return slice;
  }

  final lastData = ops.last.data;
  if (lastData is String && lastData.endsWith('\n')) {
    return slice;
  }
  final spansLines = ops.any(
    (op) => op.data is String && (op.data as String).contains('\n'),
  );
  if (!spansLines) {
    return slice;
  }

  Map<String, dynamic>? lineAttributes;
  for (final op in document.slice(end).toList()) {
    final data = op.data;
    if (data is String && data.contains('\n')) {
      lineAttributes = op.attributes;
      break;
    }
  }

  final blockAttributes = <String, dynamic>{
    for (final entry in (lineAttributes ?? const {}).entries)
      if (Attribute.blockKeys.contains(entry.key)) entry.key: entry.value,
  };
  if (blockAttributes.isEmpty) {
    return slice;
  }
  return slice..insert('\n', blockAttributes);
}

TextDirection getDirectionOfNode(Node node) {
  final direction = node.style.attributes[Attribute.direction.key];
  if (direction == Attribute.rtl) {
    return TextDirection.rtl;
  }
  return TextDirection.ltr;
}
