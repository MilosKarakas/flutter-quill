import '../documents/document.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';

class DocChange {
  DocChange(
    this.before,
    this.change,
    this.source,
  );

  /// Document state before [change].
  final Delta before;

  /// Change delta applied to the document.
  final Delta change;

  /// The source of this change.
  final ChangeSource source;
}
