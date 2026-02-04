import 'package:dart_quill_delta/dart_quill_delta.dart';

/// Thrown when composing a [Delta] into a [Document] fails.
///
/// The [originalError] holds the underlying exception from the delta
/// composition or validation step.
class DocumentComposeException implements Exception {
  /// Creates a [DocumentComposeException] with an optional [message],
  /// the [delta] that was being applied, and the [originalError] that
  /// caused the failure.
  DocumentComposeException(
    this.message, {
    this.delta,
    this.originalError,
    this.stackTrace,
  });

  /// Human-readable description of the failure.
  final String message;

  /// The delta that was being composed when the failure occurred.
  final Delta? delta;

  /// The underlying exception, if any.
  final Object? originalError;

  /// Stack trace at the point the exception was thrown.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer('DocumentComposeException: $message');
    if (originalError != null) {
      buffer.write('\nCaused by: $originalError');
    }
    return buffer.toString();
  }
}
