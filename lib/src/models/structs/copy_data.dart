import '../../../quill_delta.dart';

/// Data to be placed on the clipboard during a copy operation.
///
/// Used with [CopyInterceptor] to provide both plain text and HTML content
/// for rich text clipboard operations.
class CopyClipboardData {
  const CopyClipboardData({required this.plainText, this.html});

  /// The plain text content to place on the clipboard.
  final String plainText;

  /// Optional HTML content to place on the clipboard.
  /// When provided, applications that support rich text paste will use this.
  final String? html;
}

/// Callback type for intercepting copy operations.
///
/// Called during copy with the selected content. The callback can:
/// - Return [CopyClipboardData] with the data to write to clipboard
///   (used on web where the copy event handler writes the data)
/// - Return `null` to indicate the callback handled clipboard writing itself
///   (used on mobile where native clipboard APIs are used directly)
///
/// Parameters:
/// - [plainText]: The selected plain text being copied
/// - [delta]: The Delta representation of the selection (for HTML conversion)
///
/// Example usage:
/// ```dart
/// QuillEditor(
///   onCopyInterceptor: (plainText, delta) {
///     final html = convertDeltaToHtml(delta);
///     if (kIsWeb) {
///       // Web: return data for the copy event handler
///       return CopyClipboardData(plainText: plainText, html: html);
///     } else {
///       // Mobile: write to clipboard using native APIs
///       myNativeClipboard.setData(plainText: plainText, html: html);
///       return null; // Indicates we handled it
///     }
///   },
/// )
/// ```
typedef CopyInterceptor = CopyClipboardData? Function(
    String plainText, Delta delta);
